import '../entropy/hybrid_uint.dart';
import '../io/bit_writer.dart';
import '../util/math_helper.dart';

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
  assert(order.length <= 1 || code == 1 << 32,
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
  final extra = high & ((1 << n) - 1);
  final token = split +
      (((n - (config.splitExponent - msb - lsb)) << (msb + lsb)) |
          (msbBits << lsb) |
          low);
  return (token, n, extra);
}

/// Built entropy codes: serializes the stream header once, then emits
/// tokens into any number of section writers (prefix codes are stateless).
final class EntropyCodes {
  EntropyCodes._(this.config, this._codes, this._lens, this._alphabetSizes,
      this._histograms, this.numContexts);

  final HybridIntegerConfig config;
  final int numContexts;
  final List<List<int>> _codes;
  final List<List<int>> _lens;
  final List<int> _alphabetSizes;
  final List<List<int>> _histograms;

  /// Builds histograms and prefix codes over all [contexts]/[values].
  factory EntropyCodes.build(int numContexts, List<int> contexts,
      List<int> values, HybridIntegerConfig config) {
    final maxToken = List<int>.filled(numContexts, -1);
    for (var i = 0; i < values.length; i++) {
      final (token, _, _) = tokenizeHybrid(config, values[i]);
      if (token > maxToken[contexts[i]]) maxToken[contexts[i]] = token;
    }
    final alphabetSizes = [
      for (var c = 0; c < numContexts; c++)
        maxToken[c] < 0 ? 1 : maxToken[c] + 1,
    ];
    final histograms = [
      for (var c = 0; c < numContexts; c++)
        List<int>.filled(alphabetSizes[c], 0),
    ];
    for (var i = 0; i < values.length; i++) {
      final (token, _, _) = tokenizeHybrid(config, values[i]);
      histograms[contexts[i]][token]++;
    }
    return EntropyCodes._(
        config,
        List.filled(numContexts, const []),
        List.filled(numContexts, const []),
        alphabetSizes,
        histograms,
        numContexts);
  }

  /// Writes the distribution header (mirror of `EntropyStream.read`).
  void writeHeader(BitWriter w) {
    w.writeBool(false); // lz77
    if (numContexts > 1) {
      w.writeBool(true); // simple cluster map
      final nbits = ceilLog1p(numContexts - 1);
      assert(nbits <= 3, 'simple cluster map supports up to 8 contexts');
      w.writeBits(nbits, 2);
      for (var i = 0; i < numContexts; i++) {
        w.writeBits(i, nbits);
      }
    }
    w.writeBool(true); // use_prefix_code
    for (var c = 0; c < numContexts; c++) {
      w.writeBits(config.splitExponent, ceilLog1p(15));
      if (config.splitExponent != 15) {
        w.writeBits(config.msbInToken, ceilLog1p(config.splitExponent));
        w.writeBits(config.lsbInToken,
            ceilLog1p(config.splitExponent - config.msbInToken));
      }
    }
    for (var c = 0; c < numContexts; c++) {
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
    for (var c = 0; c < numContexts; c++) {
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
