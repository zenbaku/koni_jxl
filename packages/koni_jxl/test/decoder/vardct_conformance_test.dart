import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/png.dart';
import '../util/pnm.dart';

/// M5 gate: VarDCT/lossy conformance testcases decode within tolerance of
/// djxl. Excluded (skip list, tracked for later):
/// cafe + bench_oriented_brg (YCbCr/jbrd), upsampling (M6), noise (M6),
/// animation_* (multi-frame, gated in animation_test), cmyk_layers (CMYK),
/// lossless_pfm (float samples), blendmodes (extra-channel blending),
/// patches (alpha-blended VarDCT patches; jxlatte deviates identically —
/// see doc/spec_notes.md).
///
/// The ICC/spot cases (`grayscale`, `grayscale_public_university`,
/// `patches_lossless`, `progressive`, `spot`) are gated separately below
/// against the authoritative `ref.png`, NOT against djxl's PNM output: djxl
/// writes *linear* pixels to PNM for these ICC profiles, so the djxl-proxy
/// comparison used for the enum-colour cases is the wrong reference here (it
/// was why these were long skipped). `spot` additionally exercises spot-colour
/// compositing. See color/icc_transform.dart, decoder `_compositeSpotColors`,
/// and doc/spec_notes.md.
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

  // ICC-tagged cases, compared to the authoritative ref.png (see group doc
  // above for why not djxl). progressive exercises the real matrix/TRC output
  // transform (XYB + non-sRGB TRC); the others already decode correctly and
  // were only ever failing the wrong (djxl-PNM) reference.
  group('ICC/spot conformance vs ref.png', () {
    if (!haveConformance) return;
    for (final tc in [
      'grayscale',
      'grayscale_public_university',
      'patches_lossless',
      'progressive',
      'spot',
    ]) {
      test(tc, () {
        final dir = '${conformanceDir.path}/$tc';
        final refFile = File('$dir/ref.png');
        if (!refFile.existsSync()) {
          markTestSkipped('$tc: no ref.png');
          return;
        }
        final image =
            JxlDecoder.decode(File('$dir/input.jxl').readAsBytesSync());
        final ref = PngImage.parse(refFile.readAsBytesSync());
        expect(image.width, ref.width);
        expect(image.height, ref.height);
        final rgba = image.toRgba8();
        var sumSq = 0.0;
        var maxDiff = 0;
        var n = 0;
        for (var p = 0; p < ref.width * ref.height; p++) {
          for (var c = 0; c < ref.colorChannels; c++) {
            final d = rgba[p * 4 + c] - ref.planes[c][p];
            sumSq += d * d;
            if (d.abs() > maxDiff) maxDiff = d.abs();
            n++;
          }
        }
        final rmse = math.sqrt(sumSq / n);
        expect(rmse, lessThan(2.0),
            reason: '$tc rmse $rmse (max diff $maxDiff)');
        expect(maxDiff, lessThan(48), reason: '$tc max diff $maxDiff');
      }, timeout: const Timeout(Duration(minutes: 3)));
    }
  }, skip: haveConformance ? null : 'conformance corpus not present');

  test('progressive (LF frames) decodes to full size', () {
    final input = File('${conformanceDir.path}/progressive/input.jxl');
    final image =
        JxlDecoder.decode(Uint8List.fromList(input.readAsBytesSync()));
    expect(image.width, 4064);
    expect(image.height, 2704);
  },
      skip: conformanceDir.existsSync() ? false : 'conformance not available',
      timeout: const Timeout(Duration(minutes: 3)));
}
