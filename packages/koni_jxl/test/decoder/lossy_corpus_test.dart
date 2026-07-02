import 'dart:io';
import 'dart:math' as math;

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// M5 gate: every lossy (VarDCT) corpus file must decode within a small
/// RMSE of djxl's output. Goldens are produced on the fly with djxl.
///
/// Tolerances: the decoder matches jxlatte (its porting reference) to
/// within 1 LSB; jxlatte itself deviates from libjxl by up to ~26/255 on
/// isolated large-DCT blocks (float precision in quant-weight generation),
/// so per-pixel max is bounded loosely while RMSE is tight.
final corpusDir = Directory('../../third_party/corpus/jxl');

void main() {
  final haveCorpus = corpusDir.existsSync();
  final haveDjxl = Process.runSync('which', ['djxl']).exitCode == 0;

  group('lossy corpus vs djxl', () {
    if (!haveCorpus || !haveDjxl) return;
    final tempDir = Directory.systemTemp.createTempSync('koni_jxl_lossy');
    tearDownAll(() => tempDir.deleteSync(recursive: true));

    final files = corpusDir
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.jxl') &&
            RegExp(r'_d0\.5_|_d1\.0_|_d2\.0_').hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    test('corpus coverage', () {
      expect(files.length, greaterThanOrEqualTo(25));
    });

    for (final file in files) {
      final stem = file.uri.pathSegments.last.replaceAll('.jxl', '');
      test(stem, () {
        final image = JxlDecoder.decode(file.readAsBytesSync());
        final ext = image.isGrayscale ? 'pgm' : 'ppm';
        final goldenPath = '${tempDir.path}/$stem.$ext';
        final result =
            Process.runSync('djxl', [file.path, goldenPath, '--quiet']);
        expect(result.exitCode, 0, reason: 'djxl failed: ${result.stderr}');
        final ref = PnmImage.parse(File(goldenPath).readAsBytesSync());
        expect(image.width, ref.width);
        expect(image.height, ref.height);

        var sumSq = 0.0;
        var maxDiff = 0;
        var n = 0;
        for (var c = 0; c < ref.channels; c++) {
          final ours = channelAsInts(image.channels[c], ref.maxValue);
          final theirs = ref.intPlanes![c];
          for (var i = 0; i < ours.length; i++) {
            final d = ours[i] - theirs[i];
            sumSq += d * d;
            if (d.abs() > maxDiff) maxDiff = d.abs();
            n++;
          }
        }
        final rmse = math.sqrt(sumSq / n);
        expect(rmse, lessThan(2.0),
            reason: '$stem rmse $rmse (max diff $maxDiff)');
        expect(maxDiff, lessThan(48),
            reason: '$stem max diff $maxDiff (rmse $rmse)');
      });
    }
  }, skip: haveCorpus && haveDjxl ? null : 'corpus or djxl unavailable');
}
