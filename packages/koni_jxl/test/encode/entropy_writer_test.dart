import 'dart:math' as math;

import 'package:koni_jxl/src/encode/entropy_writer.dart';
import 'package:koni_jxl/src/entropy/entropy_stream.dart';
import 'package:koni_jxl/src/entropy/hybrid_uint.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/bit_writer.dart';
import 'package:test/test.dart';

void _roundTrip(int numContexts, List<(int, int)> tokens,
    {HybridIntegerConfig config = const HybridIntegerConfig(4, 1, 0)}) {
  final ew = EntropyWriter(numContexts, config: config);
  for (final (ctx, v) in tokens) {
    ew.write(ctx, v);
  }
  final w = BitWriter();
  ew.finalize(w);
  // Trailing sentinel bits ensure the reader never runs off the end.
  w.zeroPadToByte();
  w.writeBits(0xAA, 8);
  final reader = BitReader(w.toBytes());
  final stream = EntropyStream.read(reader, numContexts);
  for (var i = 0; i < tokens.length; i++) {
    final (ctx, v) = tokens[i];
    expect(stream.readSymbol(reader, ctx), v, reason: 'token $i');
  }
}

void main() {
  test('single context, few distinct values (simple codes)', () {
    _roundTrip(1, [for (var i = 0; i < 50; i++) (0, i % 3)]);
    _roundTrip(1, [for (var i = 0; i < 50; i++) (0, i % 2)]);
    _roundTrip(1, [for (var i = 0; i < 50; i++) (0, 7)]);
    _roundTrip(1, [(0, 0)]);
  });

  test('empty stream and empty contexts', () {
    _roundTrip(1, []);
    _roundTrip(3, [(1, 5), (1, 6), (1, 5), (1, 7), (1, 4)]);
  });

  test('wide value range (complex codes + hybrid extras)', () {
    _roundTrip(2, [
      for (var i = 0; i < 400; i++) (i % 2, (i * i * 31) % 70000),
      (0, 0),
      (1, 1 << 20),
      (0, 16),
      (1, 15),
    ]);
  });

  test('tokenBitLengths matches estimatedBits\' internal payload computation',
      () {
    // Verifies EntropyCodes.tokenBitLengths() (an auxiliary table for
    // cheap per-block rate estimation elsewhere) reproduces exactly the
    // same per-token bit lengths estimatedBits() computes internally —
    // both must come from the same real, length-limited Huffman
    // construction (huffmanLengths), not an approximation, per this
    // project's "never Shannon entropy" rule (see entropy_writer.dart's
    // estimatedBits doc comment).
    const config = HybridIntegerConfig(4, 1, 0);
    final rng = math.Random(42);
    final contexts = <int>[];
    final values = <int>[];
    // Context 0: heavily skewed (real Huffman code needed).
    for (var i = 0; i < 200; i++) {
      contexts.add(0);
      values.add(rng.nextInt(3) == 0 ? 5 : 0);
    }
    // Context 1: spread out (also a real, less-skewed code).
    for (var i = 0; i < 200; i++) {
      contexts.add(1);
      values.add(rng.nextInt(20));
    }
    // Context 2: never referenced -> a degenerate, all-zero cluster.
    final codes = EntropyCodes.build(3, contexts, values, config);
    final lens = codes.tokenBitLengths();
    expect(lens.length, 3);
    expect(lens[2], [0]); // unused context: degenerate 1-symbol alphabet

    var recomputedPayload = 0.0;
    for (var i = 0; i < contexts.length; i++) {
      final (token, extraBits, _) = tokenizeHybrid(config, values[i]);
      recomputedPayload += lens[contexts[i]][token] + extraBits;
    }
    var headerBits = 0.0;
    for (final hist in lens) {
      if (hist.any((l) => l > 0)) {
        headerBits += 8.0 * hist.length.clamp(4, 64) + 40;
      }
    }
    expect(
        recomputedPayload + headerBits, closeTo(codes.estimatedBits(), 1e-6));
  });

  test('fuzz: random tokens, contexts and configs round-trip', () {
    final rng = math.Random(1234);
    for (var iter = 0; iter < 200; iter++) {
      final numContexts = 1 + rng.nextInt(6);
      final split = 1 + rng.nextInt(8);
      final msb = rng.nextInt(split + 1).clamp(0, 2);
      final lsb = rng.nextInt(split - msb + 1).clamp(0, 2);
      final config = HybridIntegerConfig(split, msb, lsb);
      final n = rng.nextInt(300);
      final tokens = <(int, int)>[];
      for (var i = 0; i < n; i++) {
        final magnitude = rng.nextInt(4);
        final value = switch (magnitude) {
          0 => rng.nextInt(4),
          1 => rng.nextInt(64),
          2 => rng.nextInt(4096),
          _ => rng.nextInt(1 << 22),
        };
        tokens.add((rng.nextInt(numContexts), value));
      }
      _roundTrip(numContexts, tokens, config: config);
    }
  });
}
