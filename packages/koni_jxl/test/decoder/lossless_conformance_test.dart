import 'dart:io';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// M3 gate: lossless (modular, non-XYB) conformance testcases must decode
/// bit-exact against djxl output. Goldens are generated on the fly with the
/// local djxl binary; the whole group is skipped when the conformance corpus
/// or djxl are unavailable.
///
/// Excluded (tracked for later milestones): alpha_nonpremultiplied and
/// alpha_premultiplied (VarDCT, M5), grayscale_public_university (lossy
/// modular with gaborish, M6). lossless_pfm (float samples) has its own
/// test below, since its reference is a float PFM, not an int PNM/PAM.
final conformanceDir = Directory('../../third_party/conformance/testcases');

const cases = [
  'alpha_triangles',
  'delta_palette',
  'lz77_flower',
  'patches_lossless',
  'sunset_logo',
];

void main() {
  final haveConformance = conformanceDir.existsSync();
  final haveDjxl = Process.runSync('which', ['djxl']).exitCode == 0;

  group('lossless conformance vs djxl', () {
    if (!haveConformance || !haveDjxl) return;
    final tempDir = Directory.systemTemp.createTempSync('koni_jxl_conf');
    tearDownAll(() => tempDir.deleteSync(recursive: true));

    for (final tc in cases) {
      test(tc, () {
        final input = File('${conformanceDir.path}/$tc/input.jxl');
        final goldenPath = '${tempDir.path}/$tc.pam';
        final result =
            Process.runSync('djxl', [input.path, goldenPath, '--quiet']);
        expect(result.exitCode, 0, reason: 'djxl failed: ${result.stderr}');

        final image = JxlDecoder.decode(input.readAsBytesSync());
        final ref = PnmImage.parse(File(goldenPath).readAsBytesSync());
        expect(image.width, ref.width);
        expect(image.height, ref.height);
        for (var c = 0; c < ref.channels; c++) {
          final ours = channelAsInts(image.channels[c], ref.maxValue);
          final theirs = ref.intPlanes![c];
          for (var i = 0; i < ours.length; i++) {
            if (ours[i] != theirs[i]) {
              fail('$tc channel $c differs at '
                  '(${i % ref.width}, ${i ~/ ref.width}): '
                  'ours=${ours[i]} djxl=${theirs[i]}');
            }
          }
        }
      });
    }
  },
      skip: haveConformance && haveDjxl
          ? null
          : 'conformance corpus or djxl not available');

  group('lossless_pfm (float samples) vs conformance reference', () {
    if (!haveConformance) return;

    test('lossless_pfm', () {
      final tc = '${conformanceDir.path}/lossless_pfm';
      final image = JxlDecoder.decode(File('$tc/input.jxl').readAsBytesSync());
      final ref = PnmImage.parse(File('$tc/ref.pfm').readAsBytesSync());
      expect(image.width, ref.width);
      expect(image.height, ref.height);
      for (var c = 0; c < ref.channels; c++) {
        final ours = image.channels[c].floatRows;
        final theirs = ref.floatPlanes![c];
        for (var y = 0; y < ref.height; y++) {
          final row = ours[y];
          for (var x = 0; x < ref.width; x++) {
            final want = theirs[y * ref.width + x];
            if (row[x] != want) {
              fail('lossless_pfm channel $c differs at ($x, $y): '
                  'ours=${row[x]} ref=$want');
            }
          }
        }
      }
    });
  }, skip: haveConformance ? null : 'conformance corpus not available');
}
