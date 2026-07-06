import 'dart:typed_data';

import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';
import 'ans.dart';
import 'entropy_tables.dart';
import 'hybrid_uint.dart';
import 'prefix.dart';
import 'symbol_distribution.dart';

/// An entropy-coded symbol stream: clustered distributions (prefix or ANS),
/// hybrid-integer token expansion, and an optional LZ77 window.
final class EntropyStream {
  EntropyStream.read(BitReader reader, int numDists)
      : this._(reader, numDists, false);

  /// Shares the parsed distributions of [other] but with fresh LZ77/ANS
  /// decoding state (used when the same histograms apply to a new section).
  EntropyStream.clone(EntropyStream other)
      : usesLz77 = other.usesLz77,
        _lz77MinSymbol = other._lz77MinSymbol,
        _lz77MinLength = other._lz77MinLength,
        _lzLengthConfig = other._lzLengthConfig,
        _clusterMap = other._clusterMap,
        _dists = other._dists,
        _logAlphabetSize = other._logAlphabetSize {
    if (usesLz77) _window = Int32List(1 << 20);
  }

  EntropyStream._(BitReader reader, int numDists, bool disallowLz77) {
    if (numDists <= 0) {
      throw ArgumentError('numDists must be positive');
    }
    usesLz77 = reader.readBool();
    if (usesLz77) {
      if (disallowLz77) {
        throw const JxlInvalidBitstreamException(
            'nested distributions cannot use LZ77');
      }
      _lz77MinSymbol = reader.readU32(224, 0, 512, 0, 4096, 0, 8, 15);
      _lz77MinLength = reader.readU32(3, 0, 4, 0, 5, 2, 9, 8);
      numDists++;
      _lzLengthConfig = HybridIntegerConfig.read(reader, 8);
      _window = Int32List(1 << 20);
    }

    _clusterMap = Int32List(numDists);
    final numClusters = readClusterMap(reader, _clusterMap, numDists);

    final prefixCodes = reader.readBool();
    _logAlphabetSize = prefixCodes ? 15 : 5 + reader.readBits(2);
    final configs = List<HybridIntegerConfig>.generate(
        numClusters, (_) => HybridIntegerConfig.read(reader, _logAlphabetSize));

    if (prefixCodes) {
      final alphabetSizes = List<int>.generate(numClusters, (_) {
        if (!reader.readBool()) return 1;
        final n = reader.readBits(4);
        return 1 + (1 << n) + reader.readBits(n);
      });
      _dists = List<SymbolDistribution>.generate(numClusters,
          (i) => PrefixSymbolDistribution(reader, alphabetSizes[i]));
    } else {
      _dists = List<SymbolDistribution>.generate(
          numClusters, (_) => AnsSymbolDistribution(reader, _logAlphabetSize));
    }
    for (var i = 0; i < numClusters; i++) {
      _dists[i].config = configs[i];
    }
  }

  /// Reads a cluster map of `clusterMap.length` entries; returns the number
  /// of clusters.
  static int readClusterMap(
      BitReader reader, Int32List clusterMap, int maxClusters) {
    final numDists = clusterMap.length;
    if (numDists == 1) {
      clusterMap[0] = 0;
    } else if (reader.readBool()) {
      // Simple clustering.
      final nbits = reader.readBits(2);
      for (var i = 0; i < numDists; i++) {
        clusterMap[i] = reader.readBits(nbits);
      }
    } else {
      final useMtf = reader.readBool();
      final nested = EntropyStream._(reader, 1, numDists <= 2);
      for (var i = 0; i < numDists; i++) {
        clusterMap[i] = nested.readSymbol(reader, 0);
      }
      if (!nested.validateFinalState()) {
        throw const JxlInvalidBitstreamException(
            'nested cluster-map distribution');
      }
      if (useMtf) {
        final mtf = Int32List(256);
        for (var i = 0; i < 256; i++) {
          mtf[i] = i;
        }
        for (var i = 0; i < numDists; i++) {
          final index = clusterMap[i];
          if (index > 255) {
            throw const JxlInvalidBitstreamException('MTF index out of range');
          }
          clusterMap[i] = mtf[index];
          if (index != 0) {
            final value = mtf[index];
            for (var j = index; j > 0; j--) {
              mtf[j] = mtf[j - 1];
            }
            mtf[0] = value;
          }
        }
      }
    }
    var numClusters = 0;
    for (var i = 0; i < numDists; i++) {
      if (clusterMap[i] >= numClusters) numClusters = clusterMap[i] + 1;
    }
    if (numClusters > maxClusters) {
      throw const JxlInvalidBitstreamException('too many clusters');
    }
    return numClusters;
  }

  late final bool usesLz77;
  int _lz77MinSymbol = 0;
  int _lz77MinLength = 0;
  HybridIntegerConfig? _lzLengthConfig;
  late final Int32List _clusterMap;
  late final List<SymbolDistribution> _dists;
  late final int _logAlphabetSize;

  Int32List? _window;
  int _numToCopy = 0;
  int _copyPos = 0;
  int _numDecoded = 0;
  final AnsState _ansState = AnsState();

  void reset() {
    _numToCopy = 0;
    _ansState.reset();
  }

  /// After a section is fully read, the ANS state must sit at the canonical
  /// final value (or never have been initialized at all).
  bool validateFinalState() =>
      !_ansState.hasState || _ansState.state == 0x130000;

  int readSymbol(BitReader reader, int context, {int distanceMultiplier = 0}) {
    if (_numToCopy > 0) {
      final window = _window!;
      final hybridInt = window[_copyPos++ & 0xFFFFF];
      _numToCopy--;
      window[_numDecoded++ & 0xFFFFF] = hybridInt;
      return hybridInt;
    }

    if (context < 0 || context >= _clusterMap.length) {
      throw const JxlInvalidBitstreamException('entropy context out of range');
    }
    final cluster = _clusterMap[context];
    final dist = _dists[cluster];
    var token = dist.readSymbol(reader, _ansState);

    if (usesLz77 && token >= _lz77MinSymbol) {
      final lz77dist = _dists[_clusterMap[_clusterMap.length - 1]];
      _numToCopy = _lz77MinLength +
          _readHybridInteger(reader, _lzLengthConfig!, token - _lz77MinSymbol);
      token = lz77dist.readSymbol(reader, _ansState);
      var distance = _readHybridInteger(reader, lz77dist.config!, token);
      if (distanceMultiplier == 0) {
        distance++;
      } else if (distance < 120) {
        distance = specialDistances[distance * 2] +
            distanceMultiplier * specialDistances[distance * 2 + 1];
        if (distance < 1) distance = 1;
      } else {
        distance -= 119;
      }
      if (distance > 1 << 20) distance = 1 << 20;
      if (distance > _numDecoded) distance = _numDecoded;
      _copyPos = _numDecoded - distance;
      return readSymbol(reader, context,
          distanceMultiplier: distanceMultiplier);
    }

    final hybridInt = _readHybridInteger(reader, dist.config!, token);
    if (usesLz77) {
      _window![_numDecoded++ & 0xFFFFF] = hybridInt;
    }
    return hybridInt;
  }

  @pragma('vm:prefer-inline')
  int _readHybridInteger(
      BitReader reader, HybridIntegerConfig config, int token) {
    final split = 1 << config.splitExponent;
    if (token < split) return token;
    // libjxl (lib/jxl/dec_ans.h, ReadHybridUintConfig) masks this to 0-31
    // via `nbits &= 31u` -- NOT a "reject if too large" check. For n==32
    // specifically this means reading *zero* extra bits (32 & 31 == 0),
    // not 32 -- a real, confirmed divergence from the "if (n>32) throw"
    // shape jxlatte uses (and this code used to mirror), normally
    // unreachable for ordinary 8-16-bit samples, whose residuals never
    // push `n` anywhere near 32, but load-bearing for wide-range content
    // (e.g. float samples reinterpreted as packed 32-bit integers, see
    // ImageBuffer.reconstructFloatSamples) where it silently desyncs the
    // entropy stream instead of throwing.
    final n = (config.splitExponent -
            config.lsbInToken -
            config.msbInToken +
            ((token - split) >> (config.msbInToken + config.lsbInToken))) &
        31;
    final low = token & ((1 << config.lsbInToken) - 1);
    token >>= config.lsbInToken;
    token &= (1 << config.msbInToken) - 1;
    token |= 1 << config.msbInToken;
    // n is now always 0-31 (masked above), so a plain `token << n` would
    // be safe here too, but wideShl costs nothing extra and keeps this
    // consistent with the rest of this file's shift handling. The
    // hybrid-uint result is a 32-bit *unsigned* quantity by construction
    // (libjxl computes this via `size_t` then an explicit
    // `static_cast<uint32_t>` at the end, lib/jxl/dec_ans.h
    // ReadHybridUintConfig) -- masking once at the end reproduces that,
    // since truncation commutes with `<<`/`|` (unlike `+`/`*`, no carry
    // crosses the truncation boundary).
    return (((wideShl(token, n) | reader.readBits(n)) << config.lsbInToken) |
            low) &
        0xFFFFFFFF;
  }
}
