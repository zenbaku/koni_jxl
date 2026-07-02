import 'dart:io';
import 'dart:math' as math;

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// M5 gate: VarDCT/lossy conformance testcases decode within tolerance of
/// djxl. Excluded (skip list, tracked for later):
/// cafe + bench_oriented_brg (YCbCr/jbrd), upsampling (M6), noise (M6),
/// progressive (LF frames), animation_* (multi-frame), cmyk_layers (CMYK),
/// spot (spot-color rendering), grayscale + grayscale_public_university
/// (output tagged by ICC profile only; we decode as sRGB),
/// lossless_pfm (float samples), blendmodes (extra-channel blending),
/// patches (alpha-blended VarDCT patches; jxlatte deviates identically —
/// see doc/spec_notes.md).
final conformanceDir = Directory('../../third_party/conformance/testcases');

const cases = [
  'opsin_inverse',
  'bicycles',
  'bike',
  'alpha_nonpremultiplied',
  'alpha_premultiplied',
  'noise',
  'cafe',
  'bench_oriented_brg',
  'upsampling',
];

void main() {
  final haveConformance = conformanceDir.existsSync();
  final haveDjxl = Process.runSync('which', ['djxl']).exitCode == 0;

  group('vardct conformance vs djxl', () {
    if (!haveConformance || !haveDjxl) return;
    final tempDir = Directory.systemTemp.createTempSync('koni_jxl_vardct');
    tearDownAll(() => tempDir.deleteSync(recursive: true));

    for (final tc in cases) {
      test(tc, () {
        final input = File('${conformanceDir.path}/$tc/input.jxl');
        final image = JxlDecoder.decode(input.readAsBytesSync());
        final ext =
            image.hasAlpha ? 'pam' : (image.isGrayscale ? 'pgm' : 'ppm');
        final goldenPath = '${tempDir.path}/$tc.$ext';
        final result =
            Process.runSync('djxl', [input.path, goldenPath, '--quiet']);
        expect(result.exitCode, 0, reason: 'djxl failed: ${result.stderr}');
        final ref = PnmImage.parse(File(goldenPath).readAsBytesSync());
        expect(image.width, ref.width);
        expect(image.height, ref.height);

        var sumSq = 0.0;
        var maxDiff = 0;
        var n = 0;
        for (var c = 0; c < ref.channels; c++) {
          // PAM channel order matches ours (colors then alpha).
          final ours = channelAsInts(image.channels[c], ref.maxValue);
          final theirs = ref.intPlanes![c];
          for (var i = 0; i < ours.length; i++) {
            final d = ours[i] - theirs[i];
            sumSq += d * d;
            if (d.abs() > maxDiff) maxDiff = d.abs();
            n++;
          }
        }
        final rmse = math.sqrt(sumSq / n) * 255.0 / ref.maxValue;
        expect(rmse, lessThan(2.0),
            reason: '$tc rmse $rmse (max diff $maxDiff/${ref.maxValue})');
        expect(maxDiff * 255.0 / ref.maxValue, lessThan(48),
            reason: '$tc max diff $maxDiff/${ref.maxValue} (rmse $rmse)');
      });
    }
  }, skip: haveConformance && haveDjxl ? null : 'corpus or djxl unavailable');
}
