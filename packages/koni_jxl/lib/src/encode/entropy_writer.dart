import 'dart:math' as math;

import '../entropy/hybrid_uint.dart';
import '../io/bit_writer.dart';
import '../util/math_helper.dart';
import 'ans_writer.dart';

/// Entropy encoding (prefix-code variant): the exact mirror of
/// `EntropyStream.read` with `use_prefix_code = 1` and no LZ77.

int _reverse32(int v) {
  v = ((v >> 1) & 0x55555555) | ((v & 0x55555555) << 1);
  v = ((v >> 2) & 0x33333333) | ((v & 0x33333333) << 2);
  v = ((v >> 4) & 0x0F0F0F0F) | ((v & 0x0F0F0F0F) << 4);
  v = ((v >> 8) & 0x00FF00FF) | ((v & 0x00FF00FF) << 8);
  return ((v >> 16) & 0xFFFF) | ((v & 0xFFFF) << 16);
}

/// Canonical LSB-first codes for the given lengths (0 = unused), matching
/// `VlcTable.canonical`: codes assigned in (length asc, symbol asc) order.
List<int> canonicalCodes(List<int> lengths) {
  final order = <int>[
    for (var s = 0; s < lengths.length; s++)
      if (lengths[s] > 0) s,
  ]..sort((a, b) => lengths[a] != lengths[b] ? lengths[a] - lengths[b] : a - b);
  final codes = List<int>.filled(lengths.length, 0);
  var code = 0;
  for (final s in order) {
    codes[s] = _reverse32(code) & ((1 << lengths[s]) - 1);
    code += 1 << (32 - lengths[s]);
  }
  // 0x100000000 (not `1 << 32`): a *computed* shift by exactly 32 silently
  // gives 0 on dart2js even though the value is exactly representable.
  assert(order.length <= 1 || code == 0x100000000,
      'canonical code lengths must satisfy Kraft exactly');
  return codes;
}

/// Length-limited Huffman code lengths with an exact Kraft sum (required
/// by the decoder), for at least two used symbols.
List<int> huffmanLengths(List<int> counts, int limit) {
  final n = counts.length;
  final used = <int>[
    for (var s = 0; s < n; s++)
      if (counts[s] > 0) s,
  ];
  assert(used.length >= 2);
  final lengths = List<int>.filled(n, 0);

  // Standard Huffman via repeated merging (small alphabets; simplicity
  // over speed).
  final nodeCount = <int>[for (final s in used) counts[s]];
  final nodeSyms = <List<int>>[
    for (final s in used) [s],
  ];
  while (nodeCount.length > 1) {
    var a = 0;
    for (var i = 1; i < nodeCount.length; i++) {
      if (nodeCount[i] < nodeCount[a]) a = i;
    }
    var b = a == 0 ? 1 : 0;
    for (var i = 0; i < nodeCount.length; i++) {
      if (i != a && nodeCount[i] < nodeCount[b]) b = i;
    }
    for (final s in nodeSyms[a]) {
      lengths[s]++;
    }
    for (final s in nodeSyms[b]) {
      lengths[s]++;
    }
    nodeCount[a] += nodeCount[b];
    nodeSyms[a] = [...nodeSyms[a], ...nodeSyms[b]];
    nodeCount.removeAt(b);
    nodeSyms.removeAt(b);
  }

  // Clamp to the limit, then repair the Kraft sum to be exact.
  final target = 1 << limit;
  int kraft() {
    var k = 0;
    for (final s in used) {
      k += 1 << (limit - lengths[s]);
    }
    return k;
  }

  for (final s in used) {
    if (lengths[s] > limit) lengths[s] = limit;
  }
  var k = kraft();
  while (k > target) {
    // Lengthen the cheapest lengthenable symbol.
    var pick = -1;
    for (final s in used) {
      if (lengths[s] < limit && (pick < 0 || counts[s] < counts[pick])) {
        pick = s;
      }
    }
    k -= 1 << (limit - lengths[pick] - 1);
    lengths[pick]++;
  }
  var improved = true;
  while (k < target && improved) {
    improved = false;
    // Shorten the most frequent symbol that still fits.
    var pick = -1;
    for (final s in used) {
      if (lengths[s] > 1 &&
          k + (1 << (limit - lengths[s])) <= target &&
          (pick < 0 || counts[s] > counts[pick])) {
        pick = s;
      }
    }
    if (pick >= 0) {
      k += 1 << (limit - lengths[pick]);
      lengths[pick]--;
      improved = true;
    }
  }
  assert(k == target, 'kraft repair failed: $k != $target');
  return lengths;
}

// Fixed level-0 code for level-1 code lengths (mirror of prefix.dart's
// _level0Table): symbol -> (LSB-first code, bits).
const _level0Codes = <int, (int, int)>{
  0: (0, 2),
  4: (1, 2),
  3: (2, 2),
  2: (3, 3),
  1: (7, 4),
  5: (15, 4),
};

const _codelenMap = [
  1,
  2,
  3,
  4,
  0,
  5,
  17,
  6,
  16,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15
];

/// Writes a Brotli-style prefix code for [lengths] (level-2 code lengths of
/// an alphabet), including the level-1 code-length code.
void _writeComplexPrefixCode(BitWriter w, List<int> lengths) {
  // Tokenize the length sequence with 16 (repeat prev) / 17 (zeros) RLE,
  // stopping after the last used symbol (the reader stops at full Kraft).
  var last = lengths.length - 1;
  while (lengths[last] == 0) {
    last--;
  }
  final tokens = <(int, int, int)>[]; // (symbol, extraValue, extraBits)
  var prev = 8;
  var i = 0;
  while (i <= last) {
    final len = lengths[i];
    var run = 1;
    while (i + run <= last && lengths[i + run] == len) {
      run++;
    }
    if (len == 0) {
      if (run < 3) {
        for (var j = 0; j < run; j++) {
          tokens.add((0, 0, 0));
        }
      } else {
        // Bijective base-8 digits of (run - 2), MSB first.
        var m = run - 2;
        final digits = <int>[];
        while (m > 0) {
          final d = (m - 1) % 8 + 1;
          digits.add(d);
          m = (m - d) ~/ 8;
        }
        for (final d in digits.reversed) {
          tokens.add((17, d - 1, 3));
        }
      }
    } else {
      var reps = run;
      if (len != prev) {
        tokens.add((len, 0, 0));
        prev = len;
        reps--;
      }
      if (reps < 3) {
        for (var j = 0; j < reps; j++) {
          tokens.add((len, 0, 0));
        }
      } else {
        var m = reps - 2;
        final digits = <int>[];
        while (m > 0) {
          final d = (m - 1) % 4 + 1;
          digits.add(d);
          m = (m - d) ~/ 4;
        }
        for (final d in digits.reversed) {
          tokens.add((16, d - 1, 2));
        }
      }
    }
    i += run;
  }

  // Level-1 code over the token kinds.
  final level1Counts = List<int>.filled(18, 0);
  for (final t in tokens) {
    level1Counts[t.$1]++;
  }
  final kinds = <int>[
    for (var s = 0; s < 18; s++)
      if (level1Counts[s] > 0) s,
  ];
  List<int> level1Lengths;
  List<int> level1Codes;
  if (kinds.length == 1) {
    // Single kind: the reader builds a zero-bit table.
    level1Lengths = List<int>.filled(18, 0);
    level1Lengths[kinds.single] = 1;
    level1Codes = List<int>.filled(18, 0);
  } else {
    level1Lengths = huffmanLengths(level1Counts, 5);
    level1Codes = canonicalCodes(level1Lengths);
  }

  w.writeBits(0, 2); // hskip = 0
  // The reader stops once the level-1 Kraft sum completes (unless only one
  // code exists); emit exactly the entries it will read.
  var totalCode = 0;
  for (var j = 0; j < 18; j++) {
    final len = level1Lengths[_codelenMap[j]];
    final (code, bits) = _level0Codes[len]!;
    w.writeBits(code, bits);
    if (len != 0 && kinds.length > 1) {
      totalCode += 32 >> len;
      if (totalCode >= 32) break;
    }
  }
  final emitPerToken = kinds.length > 1;
  for (final (sym, extra, extraBits) in tokens) {
    if (emitPerToken) {
      w.writeBits(level1Codes[sym], level1Lengths[sym]);
    }
    if (extraBits > 0) {
      w.writeBits(extra, extraBits);
    }
  }
}

/// Writes the prefix code for a cluster histogram; returns per-symbol
/// (code, length) for the payload phase.
(List<int>, List<int>) writePrefixCode(
    BitWriter w, List<int> counts, int alphabetSize) {
  final logAlphabetSize = ceilLog1p(alphabetSize - 1);
  final used = <int>[
    for (var s = 0; s < alphabetSize; s++)
      if (counts[s] > 0) s,
  ];
  if (used.length <= 1) {
    // Simple code, nsym = 1 (alphabetSize > 1 here; size 1 handled by
    // the caller, which writes no code at all).
    w.writeBits(1, 2); // hskip == 1 -> simple
    w.writeBits(0, 2); // nsym - 1 = 0
    final sym = used.isEmpty ? 0 : used.single;
    w.writeBits(sym, logAlphabetSize);
    final codes = List<int>.filled(alphabetSize, 0);
    final lens = List<int>.filled(alphabetSize, 0);
    return (codes, lens); // zero-bit symbol
  }
  if (used.length <= 4) {
    w.writeBits(1, 2); // simple
    w.writeBits(used.length - 1, 2);
    final lens = List<int>.filled(alphabetSize, 0);
    switch (used.length) {
      case 2:
        for (final s in used) {
          w.writeBits(s, logAlphabetSize);
          lens[s] = 1;
        }
      case 3:
        // First listed symbol gets the 1-bit code: pick the most frequent.
        used.sort((a, b) => counts[b] - counts[a]);
        w.writeBits(used[0], logAlphabetSize);
        final rest = [used[1], used[2]]..sort();
        w.writeBits(rest[0], logAlphabetSize);
        w.writeBits(rest[1], logAlphabetSize);
        lens[used[0]] = 1;
        lens[rest[0]] = 2;
        lens[rest[1]] = 2;
      default:
        // Flat 2-bit code (tree-select variant not emitted).
        for (final s in used) {
          w.writeBits(s, logAlphabetSize);
          lens[s] = 2;
        }
        w.writeBool(false); // tree_select
    }
    return (canonicalCodes(lens), lens);
  }
  final lens = huffmanLengths(counts, 15);
  _writeComplexPrefixCode(w, lens);
  return (canonicalCodes(lens), lens);
}

/// Splits [value] per [config]; returns (token, extraBits, extraValue).
(int, int, int) tokenizeHybrid(HybridIntegerConfig config, int value) {
  final split = 1 << config.splitExponent;
  if (value < split) return (value, 0, 0);
  final lsb = config.lsbInToken;
  final msb = config.msbInToken;
  final low = value & ((1 << lsb) - 1);
  final high = value >> lsb;
  final n = high.bitLength - 1 - msb;
  final msbBits = (high >> n) & ((1 << msb) - 1);
  // n mirrors _readHybridInteger's decoder-side n, which can reach 32 for
  // large values: `(1 << n) - 1` would break on dart2js there (see
  // wideShl's doc), so build the mask via wideShl instead of a bare `<<`.
  final extra = high & (wideShl(1, n) - 1);
  final token = split +
      (((n - (config.splitExponent - msb - lsb)) << (msb + lsb)) |
          (msbBits << lsb) |
          low);
  return (token, n, extra);
}

/// One LZ77-processed op stream: literals interleaved with
/// (length, distance) matches, ready for histogramming and emission.
final class Lz77Ops {
  final List<int> kinds = []; // 0 = literal, 1 = match
  final List<int> ctxs = []; // context of the pixel at this position
  final List<int> a = []; // literal value / match length
  final List<int> b = []; // unused / match distance
}

const lz77MinSymbol = 224;
const lz77MinLength = 3;
const lz77LengthConfig = HybridIntegerConfig(4, 0, 0);

/// Greedy hash-chain LZ77 over the token-value sequence of one section.
/// Distances are in value positions (the decoder's window semantics).
Lz77Ops lz77Compress(List<int> contexts, List<int> values) {
  final ops = Lz77Ops();
  final n = values.length;
  const hashBits = 15;
  const chainDepth = 24;
  final chains = List<int>.filled(1 << hashBits, -1);
  final prev = List<int>.filled(n < 1 ? 1 : n, -1);

  int hash(int i) {
    var h = values[i] * 0x9E3779B1;
    h ^= values[i + 1] * 0x85EBCA6B;
    h ^= values[i + 2] * 0xC2B2AE35;
    return (h ^ (h >>> 13)) & ((1 << hashBits) - 1);
  }

  void insert(int i) {
    if (i + 2 >= n) return;
    final h = hash(i);
    prev[i] = chains[h];
    chains[h] = i;
  }

  var i = 0;
  while (i < n) {
    var bestLen = 0;
    var bestDist = 0;
    if (i + lz77MinLength <= n && i + 2 < n) {
      var cand = chains[hash(i)];
      var depth = 0;
      while (cand >= 0 && depth < chainDepth) {
        final dist = i - cand;
        if (dist > (1 << 20) - 1) break;
        var len = 0;
        final maxLen = n - i;
        while (len < maxLen && values[cand + len] == values[i + len]) {
          len++;
        }
        if (len > bestLen) {
          bestLen = len;
          bestDist = dist;
          if (len >= 4096) break; // long enough
        }
        cand = prev[cand];
        depth++;
      }
    }
    if (bestLen >= lz77MinLength) {
      ops.kinds.add(1);
      ops.ctxs.add(contexts[i]);
      ops.a.add(bestLen);
      ops.b.add(bestDist);
      final end = i + bestLen;
      while (i < end) {
        insert(i);
        i++;
      }
    } else {
      ops.kinds.add(0);
      ops.ctxs.add(contexts[i]);
      ops.a.add(values[i]);
      ops.b.add(0);
      insert(i);
      i++;
    }
  }
  return ops;
}

/// Built entropy codes: serializes the stream header once, then emits
/// tokens into any number of section writers (prefix codes are stateless).
final class EntropyCodes {
  EntropyCodes._(this.config, this._codes, this._lens, this._alphabetSizes,
      this._histograms, this.numContexts);

  final HybridIntegerConfig config;

  /// Pixel contexts (excluding the LZ77 distance cluster, when present).
  final int numContexts;
  final List<List<int>> _codes;
  final List<List<int>> _lens;
  final List<int> _alphabetSizes;
  final List<List<int>> _histograms;

  int get _numClusters => usesLz77 ? numContexts + 1 : numContexts;

  /// Builds histograms and prefix codes over all [contexts]/[values].
  factory EntropyCodes.build(int numContexts, List<int> contexts,
      List<int> values, HybridIntegerConfig config) {
    final codes = EntropyCodes._(config, [], [], [], [], numContexts);
    for (var i = 0; i < values.length; i++) {
      final (token, nbits, _) = tokenizeHybrid(config, values[i]);
      codes._count(contexts[i], token, nbits);
    }
    codes._finishHistograms(numContexts);
    return codes;
  }

  /// Builds codes over LZ77 op streams: [numContexts] pixel contexts plus
  /// one distance cluster (the last).
  factory EntropyCodes.buildLz77(
      int numContexts, List<Lz77Ops> sections, HybridIntegerConfig config) {
    final codes = EntropyCodes._(config, [], [], [], [], numContexts)
      ..usesLz77 = true;
    for (final ops in sections) {
      for (var i = 0; i < ops.kinds.length; i++) {
        if (ops.kinds[i] == 0) {
          final (token, nbits, _) = tokenizeHybrid(config, ops.a[i]);
          assert(token < lz77MinSymbol,
              'literal token collides with LZ77 length symbols');
          codes._count(ops.ctxs[i], token, nbits);
        } else {
          final (lt, lnbits, _) =
              tokenizeHybrid(lz77LengthConfig, ops.a[i] - lz77MinLength);
          codes._count(ops.ctxs[i], lz77MinSymbol + lt, lnbits);
          final (dt, dnbits, _) = tokenizeHybrid(config, ops.b[i] + 119);
          codes._count(numContexts, dt, dnbits);
        }
      }
    }
    codes._finishHistograms(numContexts + 1);
    return codes;
  }

  final Map<int, Map<int, int>> _sparse = {};
  bool usesLz77 = false;
  double _extraBits = 0;

  void _count(int context, int token, [int extraBits = 0]) {
    final m = _sparse.putIfAbsent(context, () => {});
    m[token] = (m[token] ?? 0) + 1;
    _extraBits += extraBits;
  }

  /// Exact-code-length estimate of the payload size in bits: the actual
  /// Huffman lengths are computed per cluster, so the prefix-coding
  /// 1-bit-per-symbol floor is accounted for (Shannon entropy is not a
  /// safe proxy for highly skewed histograms).
  double estimatedBits() {
    var bits = _extraBits;
    for (final hist in _histograms) {
      final lens = _safeLengths(hist);
      if (lens == null) continue; // zero-bit symbols
      for (var s = 0; s < hist.length; s++) {
        bits += hist[s] * lens[s];
      }
      // Rough per-cluster header cost.
      bits += 8.0 * hist.length.clamp(4, 64) + 40;
    }
    return bits;
  }

  /// Per-cluster Huffman code length for every token (0 for unused/
  /// zero-bit-symbol clusters) — an auxiliary table for cheap rate
  /// estimation elsewhere (e.g. a per-block rate-distortion decision
  /// scoring several quantization candidates against an already-built,
  /// frozen histogram), not part of the real bitstream. Uses the exact
  /// same length-limited Huffman construction [estimatedBits] and the
  /// real prefix-code writer already use, so it inherits their
  /// 1-bit-per-symbol floor correctness (Shannon entropy is not safe
  /// here — see [estimatedBits]'s doc comment).
  List<List<int>> tokenBitLengths() => [
        for (final hist in _histograms)
          _safeLengths(hist) ?? List<int>.filled(hist.length, 0),
      ];

  /// Length-limited Huffman lengths for [hist], or null when the cluster
  /// has 0 or 1 used symbols (no real code needed — [estimatedBits] and
  /// [tokenBitLengths] both treat that as a zero-bit-per-symbol cluster).
  List<int>? _safeLengths(List<int> hist) {
    var used = 0;
    var total = 0;
    for (final count in hist) {
      if (count > 0) used++;
      total += count;
    }
    if (total == 0 || used <= 1) return null;
    return huffmanLengths(hist, 15);
  }

  // --- ANS (rANS) mode ---

  /// Whether every cluster's token alphabet fits in 2^8 = 256 symbols, the
  /// most an ANS distribution can address (logAlphabetSize <= 8).
  bool get ansViable {
    for (final size in _alphabetSizes) {
      if (size > 256) return false;
    }
    return true;
  }

  int get _ansLogAlphabetSize {
    var maxSize = 1;
    for (final size in _alphabetSizes) {
      if (size > maxSize) maxSize = size;
    }
    var log = 5;
    while ((1 << log) < maxSize) {
      log++;
    }
    return log;
  }

  /// Coded-size estimate for the ANS path: fractional bits per token
  /// (the whole point of ANS) plus the extra bits and a header estimate.
  double ansEstimatedBits() {
    var bits = _extraBits;
    for (final hist in _histograms) {
      var total = 0;
      for (final count in hist) {
        total += count;
      }
      if (total == 0) continue;
      final freqs = normalizeFrequencies(hist, hist.length);
      for (var s = 0; s < hist.length; s++) {
        if (hist[s] > 0) {
          bits += hist[s] * (math.log(4096 / freqs[s]) / math.ln2);
        }
      }
      bits += 12.0 * hist.length + 40; // distribution header
    }
    return bits;
  }

  List<AnsAliasTable>? _ansTables;
  int _ansLog = 8;

  /// Writes the ANS distribution header and prepares the alias tables.
  void writeAnsHeader(BitWriter w) {
    _ansLog = _ansLogAlphabetSize;
    final clusters = _numClusters;
    w.writeBool(usesLz77);
    if (usesLz77) {
      w.writeU32(lz77MinSymbol, 224, 0, 512, 0, 4096, 0, 8, 15);
      w.writeU32(lz77MinLength, 3, 0, 4, 0, 5, 2, 9, 8);
      w.writeBits(lz77LengthConfig.splitExponent, ceilLog1p(8));
      if (lz77LengthConfig.splitExponent != 8) {
        w.writeBits(lz77LengthConfig.msbInToken,
            ceilLog1p(lz77LengthConfig.splitExponent));
        w.writeBits(
            lz77LengthConfig.lsbInToken,
            ceilLog1p(
                lz77LengthConfig.splitExponent - lz77LengthConfig.msbInToken));
      }
    }
    _writeClusterMap(w, clusters);
    w.writeBool(false); // use_prefix_code = false (ANS)
    w.writeBits(_ansLog - 5, 2);
    for (var c = 0; c < clusters; c++) {
      w.writeBits(config.splitExponent, ceilLog1p(_ansLog));
      if (config.splitExponent != _ansLog) {
        w.writeBits(config.msbInToken, ceilLog1p(config.splitExponent));
        w.writeBits(config.lsbInToken,
            ceilLog1p(config.splitExponent - config.msbInToken));
      }
    }
    _ansTables = [];
    for (var c = 0; c < clusters; c++) {
      final declared = _histograms[c].length < 3 ? 3 : _histograms[c].length;
      final counts = List<int>.filled(declared, 0);
      for (var s = 0; s < _histograms[c].length; s++) {
        counts[s] = _histograms[c][s];
      }
      final freqs = normalizeFrequencies(counts, declared);
      writeAnsDistribution(w, freqs);
      _ansTables!.add(AnsAliasTable(freqs, _ansLog));
    }
  }

  /// Encodes one section as a fresh rANS stream over the shared tables.
  void encodeAnsSection(BitWriter w, List<int> contexts, List<int> values) {
    final enc = AnsEncoder(_ansTables!);
    for (var i = 0; i < values.length; i++) {
      final (token, nbits, extra) = tokenizeHybrid(config, values[i]);
      enc.add(contexts[i], token, extra: extra, extraBits: nbits);
    }
    enc.finish(w);
  }

  /// Encodes one LZ77 op stream as a fresh rANS stream. A match emits a
  /// length symbol (in its pixel cluster, offset by [lz77MinSymbol]) then a
  /// distance symbol (in the distance cluster), each with its raw extra
  /// bits — the exact read order in EntropyStream.readSymbol.
  void encodeAnsLz77Section(BitWriter w, Lz77Ops ops) {
    final enc = AnsEncoder(_ansTables!);
    for (var i = 0; i < ops.kinds.length; i++) {
      if (ops.kinds[i] == 0) {
        final (token, nbits, extra) = tokenizeHybrid(config, ops.a[i]);
        enc.add(ops.ctxs[i], token, extra: extra, extraBits: nbits);
      } else {
        final (lt, lnbits, lextra) =
            tokenizeHybrid(lz77LengthConfig, ops.a[i] - lz77MinLength);
        enc.add(ops.ctxs[i], lz77MinSymbol + lt,
            extra: lextra, extraBits: lnbits);
        final (dt, dnbits, dextra) = tokenizeHybrid(config, ops.b[i] + 119);
        enc.add(numContexts, dt, extra: dextra, extraBits: dnbits);
      }
    }
    enc.finish(w);
  }

  void _finishHistograms(int clusters) {
    for (var c = 0; c < clusters; c++) {
      final m = _sparse[c];
      var maxToken = -1;
      if (m != null) {
        for (final t in m.keys) {
          if (t > maxToken) maxToken = t;
        }
      }
      final size = maxToken < 0 ? 1 : maxToken + 1;
      _alphabetSizes.add(size);
      final hist = List<int>.filled(size, 0);
      m?.forEach((t, count) => hist[t] = count);
      _histograms.add(hist);
      _codes.add(const []);
      _lens.add(const []);
    }
  }

  /// Writes an identity cluster map for [clusters] contexts: the simple
  /// fixed-width form for up to 8 clusters, otherwise a nested entropy
  /// stream over the cluster ids (the decoder's complex path, no MTF).
  static void _writeClusterMap(BitWriter w, int clusters) {
    if (clusters <= 1) return;
    final nbits = ceilLog1p(clusters - 1);
    if (nbits <= 3) {
      w.writeBool(true); // simple
      w.writeBits(nbits, 2);
      for (var i = 0; i < clusters; i++) {
        w.writeBits(i, nbits);
      }
      return;
    }
    w.writeBool(false); // complex
    w.writeBool(false); // use_mtf = false
    final nested = EntropyWriter(1);
    for (var i = 0; i < clusters; i++) {
      nested.write(0, i);
    }
    nested.finalize(w);
  }

  /// Writes a general cluster map: `clusterMap[i]` is the output cluster
  /// for input context id `i` (need not be identity, and need not use
  /// every input id — unreachable ids can map anywhere). Mirrors the
  /// decoder's `EntropyStream.readClusterMap`'s two encodings: the
  /// fixed-width "simple" form when `numClusters <= 8`, otherwise a nested
  /// entropy stream over the per-entry cluster ids (which Huffman-codes
  /// away the cost of ids that repeat a lot, e.g. every unreachable
  /// context id sharing one arbitrary fallback cluster).
  static void _writeGeneralClusterMap(
      BitWriter w, List<int> clusterMap, int numClusters) {
    if (clusterMap.length <= 1) return;
    final nbits = ceilLog1p(numClusters - 1);
    if (nbits <= 3) {
      w.writeBool(true); // simple
      w.writeBits(nbits, 2);
      for (final c in clusterMap) {
        w.writeBits(c, nbits);
      }
      return;
    }
    w.writeBool(false); // complex
    w.writeBool(false); // use_mtf = false
    final nested = EntropyWriter(1);
    for (final c in clusterMap) {
      nested.write(0, c);
    }
    nested.finalize(w);
  }

  /// Writes the distribution header (mirror of `EntropyStream.read`).
  ///
  /// [clusterMap], when given, writes a general (possibly non-identity)
  /// cluster map via [_writeGeneralClusterMap] instead of the default
  /// identity map; `clusterMap[i]` must be a valid cluster index for every
  /// input context id `i` this stream's decoder-side domain size expects.
  void writeHeader(BitWriter w, {List<int>? clusterMap}) {
    w.writeBool(usesLz77);
    if (usesLz77) {
      w.writeU32(lz77MinSymbol, 224, 0, 512, 0, 4096, 0, 8, 15);
      w.writeU32(lz77MinLength, 3, 0, 4, 0, 5, 2, 9, 8);
      // lz_length_config, read with logAlphabetSize 8.
      w.writeBits(lz77LengthConfig.splitExponent, ceilLog1p(8));
      if (lz77LengthConfig.splitExponent != 8) {
        w.writeBits(lz77LengthConfig.msbInToken,
            ceilLog1p(lz77LengthConfig.splitExponent));
        w.writeBits(
            lz77LengthConfig.lsbInToken,
            ceilLog1p(
                lz77LengthConfig.splitExponent - lz77LengthConfig.msbInToken));
      }
    }
    final clusters = _numClusters;
    if (clusterMap != null) {
      _writeGeneralClusterMap(w, clusterMap, clusters);
    } else {
      _writeClusterMap(w, clusters);
    }
    w.writeBool(true); // use_prefix_code
    for (var c = 0; c < clusters; c++) {
      w.writeBits(config.splitExponent, ceilLog1p(15));
      if (config.splitExponent != 15) {
        w.writeBits(config.msbInToken, ceilLog1p(config.splitExponent));
        w.writeBits(config.lsbInToken,
            ceilLog1p(config.splitExponent - config.msbInToken));
      }
    }
    for (var c = 0; c < clusters; c++) {
      final size = _alphabetSizes[c];
      if (size == 1) {
        w.writeBool(false);
      } else {
        w.writeBool(true);
        final n = (size - 1).bitLength - 1;
        w.writeBits(n, 4);
        w.writeBits(size - 1 - (1 << n), n);
      }
    }
    for (var c = 0; c < clusters; c++) {
      if (_alphabetSizes[c] == 1) {
        _codes[c] = const [0];
        _lens[c] = const [0];
        continue;
      }
      final (cc, ll) = writePrefixCode(w, _histograms[c], _alphabetSizes[c]);
      _codes[c] = cc;
      _lens[c] = ll;
    }
  }

  /// Emits one LZ77 op stream.
  void writeOps(BitWriter w, Lz77Ops ops) {
    assert(usesLz77);
    for (var i = 0; i < ops.kinds.length; i++) {
      if (ops.kinds[i] == 0) {
        writeToken(w, ops.ctxs[i], ops.a[i]);
      } else {
        final (t, nbits, extra) =
            tokenizeHybrid(lz77LengthConfig, ops.a[i] - lz77MinLength);
        final sym = lz77MinSymbol + t;
        w.writeBits(_codes[ops.ctxs[i]][sym], _lens[ops.ctxs[i]][sym]);
        if (nbits > 0) w.writeBits(extra, nbits);
        writeToken(w, numContexts, ops.b[i] + 119);
      }
    }
  }

  /// Emits one value (must be called only after [writeHeader]).
  void writeToken(BitWriter w, int context, int value) {
    final (token, extraBits, extra) = tokenizeHybrid(config, value);
    w.writeBits(_codes[context][token], _lens[context][token]);
    if (extraBits > 0) {
      w.writeBits(extra, extraBits);
    }
  }
}

/// Buffers (context, value) tokens and serializes header + payload into a
/// single writer (convenience over [EntropyCodes]).
final class EntropyWriter {
  EntropyWriter(this.numContexts,
      {this.config = const HybridIntegerConfig(4, 1, 0)});

  final int numContexts;
  final HybridIntegerConfig config;
  final List<int> _contexts = [];
  final List<int> _values = [];

  void write(int context, int value) {
    assert(context >= 0 && context < numContexts);
    assert(value >= 0);
    _contexts.add(context);
    _values.add(value);
  }

  void finalize(BitWriter w) {
    final codes = EntropyCodes.build(numContexts, _contexts, _values, config);
    codes.writeHeader(w);
    for (var i = 0; i < _values.length; i++) {
      codes.writeToken(w, _contexts[i], _values[i]);
    }
  }
}
