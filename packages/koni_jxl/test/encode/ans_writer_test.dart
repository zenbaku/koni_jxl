import 'dart:math' as math;

import 'package:koni_jxl/src/encode/ans_writer.dart';
import 'package:koni_jxl/src/encode/entropy_writer.dart';
import 'package:koni_jxl/src/entropy/entropy_stream.dart';
import 'package:koni_jxl/src/entropy/hybrid_uint.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/bit_writer.dart';
import 'package:koni_jxl/src/util/math_helper.dart';
import 'package:test/test.dart';

/// Builds a complete single-cluster ANS entropy stream (header + rANS
/// payload) and decodes it through the real [EntropyStream], asserting the
/// symbols round-trip. Symbols must be < 2^logAlphabetSize and the identity
/// hybrid config (split == logAlphabetSize) passes them through unchanged.
void _roundTrip(List<int> symbols, {int logAlphabetSize = 8}) {
  final alphabet = symbols.isEmpty ? 1 : symbols.reduce(math.max) + 1;
  final declared = alphabet < 3 ? 3 : alphabet;
  final counts = List<int>.filled(declared, 0);
  for (final s in symbols) {
    counts[s]++;
  }
  final freqs = normalizeFrequencies(counts, declared);
  final table = AnsAliasTable(freqs, logAlphabetSize);

  final w = BitWriter();
  w.writeBool(false); // lz77
  // numContexts == 1 -> no cluster map written.
  w.writeBool(false); // use_prefix_code = false (ANS)
  w.writeBits(logAlphabetSize - 5, 2);
  // Identity hybrid config: splitExponent == logAlphabetSize.
  w.writeBits(logAlphabetSize, ceilLog1p(logAlphabetSize));
  writeAnsDistribution(w, freqs);

  final enc = AnsEncoder([table]);
  for (final s in symbols) {
    enc.add(0, s);
  }
  enc.finish(w);
  // A trailing byte guards against the reader running past the payload.
  w
    ..zeroPadToByte()
    ..writeBits(0, 8);

  final reader = BitReader(w.toBytes());
  final stream = EntropyStream.read(reader, 1);
  for (var i = 0; i < symbols.length; i++) {
    expect(stream.readSymbol(reader, 0), symbols[i], reason: 'symbol $i');
  }
  expect(stream.validateFinalState(), isTrue);
}

/// Round-trips full values through ANS with a hybrid config that produces
/// raw extra bits, decoded via the real EntropyStream.
void _roundTripHybrid(List<int> values,
    {int logAlphabetSize = 8,
    HybridIntegerConfig config = const HybridIntegerConfig(4, 1, 0)}) {
  var maxToken = 0;
  for (final v in values) {
    final t = tokenizeHybrid(config, v).$1;
    if (t > maxToken) maxToken = t;
  }
  final declared = (maxToken + 1) < 3 ? 3 : maxToken + 1;
  final counts = List<int>.filled(declared, 0);
  for (final v in values) {
    counts[tokenizeHybrid(config, v).$1]++;
  }
  final freqs = normalizeFrequencies(counts, declared);
  final table = AnsAliasTable(freqs, logAlphabetSize);

  final w = BitWriter();
  w.writeBool(false);
  w.writeBool(false);
  w.writeBits(logAlphabetSize - 5, 2);
  w.writeBits(config.splitExponent, ceilLog1p(logAlphabetSize));
  if (config.splitExponent != logAlphabetSize) {
    w.writeBits(config.msbInToken, ceilLog1p(config.splitExponent));
    w.writeBits(
        config.lsbInToken, ceilLog1p(config.splitExponent - config.msbInToken));
  }
  writeAnsDistribution(w, freqs);

  final enc = AnsEncoder([table]);
  for (final v in values) {
    final (token, nbits, extra) = tokenizeHybrid(config, v);
    enc.add(0, token, extra: extra, extraBits: nbits);
  }
  enc.finish(w);
  w
    ..zeroPadToByte()
    ..writeBits(0, 32);

  final reader = BitReader(w.toBytes());
  final stream = EntropyStream.read(reader, 1);
  for (var i = 0; i < values.length; i++) {
    expect(stream.readSymbol(reader, 0), values[i], reason: 'value $i');
  }
  expect(stream.validateFinalState(), isTrue);
}

void main() {
  test('single symbol repeated', () {
    _roundTrip(List<int>.filled(100, 7));
  });

  test('two symbols', () {
    _roundTrip([for (var i = 0; i < 200; i++) i % 2]);
  });

  test('skewed histogram', () {
    final syms = <int>[];
    for (var i = 0; i < 1000; i++) {
      syms.add(i % 50 == 0 ? (i % 200) : 0);
    }
    _roundTrip(syms);
  });

  test('empty', () {
    _roundTrip([]);
  });

  test('hybrid values with extra bits round-trip', () {
    _roundTripHybrid([for (var i = 0; i < 300; i++) (i * i * 7) % 5000]);
    _roundTripHybrid([0, 1, 2, 100, 1000, 65535, 3, 3, 3]);
  });

  test('fuzz: hybrid values round-trip', () {
    final rng = math.Random(7);
    for (var iter = 0; iter < 200; iter++) {
      final n = rng.nextInt(300);
      final vals = <int>[
        for (var i = 0; i < n; i++)
          rng.nextInt(4) == 0 ? rng.nextInt(1 << 20) : rng.nextInt(16),
      ];
      _roundTripHybrid(vals);
    }
  });

  test('fuzz: random symbol streams round-trip', () {
    final rng = math.Random(99);
    for (var iter = 0; iter < 300; iter++) {
      final alpha = 1 + rng.nextInt(200);
      final n = rng.nextInt(500);
      // Zipf-ish: mostly small symbols, occasional large.
      final syms = <int>[
        for (var i = 0; i < n; i++)
          rng.nextInt(4) == 0
              ? rng.nextInt(alpha)
              : rng.nextInt(math.min(4, alpha)),
      ];
      _roundTrip(syms);
    }
  });
}
