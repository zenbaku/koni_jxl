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
/// modular with gaborish, M6), lossless_pfm (float samples).
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
}
