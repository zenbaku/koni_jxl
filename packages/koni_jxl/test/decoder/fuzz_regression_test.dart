@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../../tool/fuzz_decode.dart' as fuzz;

/// Seeded mini fuzz campaign: every mutated input must either decode or
/// throw a JxlException — nothing else. The full campaign lives in
/// tool/fuzz_decode.dart; this keeps a fast regression net in CI.
final corpusDir = Directory('../../third_party/corpus/jxl');

void main() {
  final seeds = <Uint8List>[
    for (final name in [
      'screentone_256_d0_e5.jxl',
      'color_cover_d1.0_e7.jxl',
      'anim_d0.jxl',
      'alpha_page_d0_e3.jxl',
    ])
      if (File('${corpusDir.path}/$name').existsSync())
        File('${corpusDir.path}/$name').readAsBytesSync(),
  ];

  test('mutated inputs only ever throw JxlException', () {
    if (seeds.isEmpty) return;
    const cases = 2000;
    for (var caseSeed = 20000; caseSeed < 20000 + cases; caseSeed++) {
      final rng = math.Random(caseSeed);
      final data = fuzz.mutate(rng, seeds[rng.nextInt(seeds.length)]);
      for (final (api, body) in <(String, void Function())>[
        ('info', () => JxlInfo.parse(data)),
        ('decode', () => JxlDecoder.decode(data)),
        (
          'streaming',
          () {
            final dec = JxlStreamingDecoder()..addBytes(data);
            dec.state;
            dec.progress;
            dec.decodePreview();
            if (dec.state == JxlStreamState.complete) dec.decodeFinal();
          }
        ),
        ('reconstruct', () => JxlDecoder.reconstructJpeg(data)),
      ]) {
        try {
          body();
        } on JxlException {
          // The contract for malformed input.
        } catch (e, st) {
          fail('case $caseSeed $api threw ${e.runtimeType}: $e\n$st');
        }
      }
    }
  }, skip: seeds.isEmpty ? 'corpus not generated' : false);
}
