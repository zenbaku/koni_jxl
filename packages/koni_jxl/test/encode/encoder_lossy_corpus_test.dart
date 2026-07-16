@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// L4 gate: lossy VarDCT encoder over real (non-synthetic-test-pattern)
/// corpus content. `_d0_` goldens are lossless cjxl re-encodes, so their
/// pixels are the exact original source — this encoder re-encodes those
/// same pixels *lossily* at a few distances and checks the result decodes
/// through both our own decoder and djxl within a generous RMSE bound.
/// Complements test/encode/vardct_l0_test.dart's hand-written synthetic
/// patterns (gradients, screentone, line art) with whatever's actually in
/// the shared corpus.
final goldenDir = Directory('../../third_party/corpus/golden');

final _haveDjxl = (() {
  try {
    return Process.runSync('djxl', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
})();

void main() {
  final haveCorpus = goldenDir.existsSync();
  if (!haveCorpus) {
    test('corpus not generated', () {},
        skip: 'run tool/gen_corpus.py to enable the lossy encoder corpus '
            'gate');
    return;
  }
  // Only 8-bit goldens (RGB or grayscale — grayscale is replicated to RGB,
  // since this encoder doesn't support single-channel output); `_d0_`
  // (distance 0, lossless) pixels are the true original, and effort
  // doesn't affect decoded pixel content, so one effort level per source
  // is enough. Dimensions need not be multiples of 8 — this encoder pads
  // internally (see encodeLossyVardctL0's doc comment) — so this
  // deliberately includes the corpus's "odd" (non-block-aligned, down to
  // 1x1) sizes to exercise that directly against real corpus content.
  final goldens = goldenDir
      .listSync()
      .whereType<File>()
      .where((f) =>
          (f.path.endsWith('.ppm') || f.path.endsWith('.pgm')) &&
          f.path.contains('_d0_') &&
          f.path.contains('_e7'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final golden in goldens) {
    final stem = golden.uri.pathSegments.last;
    final ref = PnmImage.parse(golden.readAsBytesSync());
    if ((ref.channels != 3 && ref.channels != 1) || ref.maxValue != 255) {
      continue; // not a shape this encoder accepts.
    }
    final pixels = Uint8List(ref.width * ref.height * 3);
    for (var c = 0; c < 3; c++) {
      final plane = ref.intPlanes![ref.channels == 1 ? 0 : c];
      for (var i = 0; i < plane.length; i++) {
        pixels[i * 3 + c] = plane[i];
      }
    }

    for (final distance in [0.5, 1.0, 2.0, 4.0]) {
      test('lossy re-encode $stem at distance $distance', () {
        final encoded = JxlEncoder.encodeLossy(pixels,
            width: ref.width, height: ref.height, distance: distance);

        final image = JxlDecoder.decode(encoded);
        expect(image.width, ref.width);
        expect(image.height, ref.height);

        double rmseAgainst(List<Int32List> theirs) {
          var sumSq = 0.0;
          for (var c = 0; c < 3; c++) {
            final ours = channelAsInts(image.channels[c], 255);
            for (var i = 0; i < ref.width * ref.height; i++) {
              final d = ours[i] - theirs[c][i];
              sumSq += d * d;
            }
          }
          return math.sqrt(sumSq / (ref.width * ref.height * 3));
        }

        // Our own decoder vs. the true original pixels (replicated to RGB
        // for grayscale sources, matching how `pixels` was built above): a
        // correctness bar, not a quality bar (this encoder's quantization
        // is intentionally crude at low effort — see
        // doc/lossy_encoder_plan.md).
        final refPlanes = [
          for (var c = 0; c < 3; c++) ref.intPlanes![ref.channels == 1 ? 0 : c]
        ];
        expect(rmseAgainst(refPlanes), lessThan(40),
            reason: 'our decoder vs. original, distance $distance');

        if (!_haveDjxl) return;
        final dir = Directory.systemTemp.createTempSync('koni_lossy_corpus');
        try {
          final jxlPath = '${dir.path}/t.jxl';
          final outPath = '${dir.path}/t.ppm';
          File(jxlPath).writeAsBytesSync(encoded);
          final r =
              Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
          expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
          final theirs = PnmImage.parse(File(outPath).readAsBytesSync());
          expect(theirs.width, ref.width);
          expect(theirs.height, ref.height);
        } finally {
          dir.deleteSync(recursive: true);
        }
      });
    }
  }
}
