import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:koni_jxl/src/util/image_buffer.dart';
import 'package:koni_jxl/src/util/resample.dart';
import 'package:test/test.dart';

/// Gate for `JxlDecoder.decode`'s `targetWidth`/`targetHeight` reduced-
/// resolution path. Every case below must produce output close to a manual
/// box-downsample of the full decode, regardless of whether the DC-only fast
/// path or the full-decode-then-downsample fallback actually served it —
/// both are required to agree; which one ran is a performance detail
/// verified separately with `tool/profile_decode.dart`, not asserted here.
final corpusDir = Directory('../../third_party/corpus/jxl');
final conformanceDir = Directory('../../third_party/conformance/testcases');

Uint8List _read(String name) =>
    File('${corpusDir.path}/$name').readAsBytesSync();

/// RMSE between [downscaled] and a manual box-downsample of [full]'s RGBA —
/// the same comparison [streaming_test.dart] uses for the 1:8 preview.
double _rmseVsBoxDownsample(JxlImage full, JxlImage downscaled) {
  final fullRgba = full.toRgba8();
  final smallRgba = downscaled.toRgba8();
  final sx = full.width / downscaled.width;
  final sy = full.height / downscaled.height;
  var sq = 0.0;
  var n = 0;
  for (var y = 0; y < downscaled.height; y++) {
    final y0 = (y * sy).floor();
    final y1 = math.min(full.height, ((y + 1) * sy).ceil());
    for (var x = 0; x < downscaled.width; x++) {
      final x0 = (x * sx).floor();
      final x1 = math.min(full.width, ((x + 1) * sx).ceil());
      for (var c = 0; c < 3; c++) {
        var sum = 0;
        var cnt = 0;
        for (var fy = y0; fy < y1; fy++) {
          for (var fx = x0; fx < x1; fx++) {
            sum += fullRgba[(fy * full.width + fx) * 4 + c];
            cnt++;
          }
        }
        final d = smallRgba[(y * downscaled.width + x) * 4 + c] - sum / cnt;
        sq += d * d;
        n++;
      }
    }
  }
  return math.sqrt(sq / n);
}

void main() {
  final haveCorpus = corpusDir.existsSync();
  final haveConformance = conformanceDir.existsSync();

  group('resolveTargetSize', () {
    test('fits within a box, preserving aspect ratio', () {
      final r = resolveTargetSize(4000, 2000, targetWidth: 1000);
      expect(r.width, 1000);
      expect(r.height, 500);
    });

    test('never upscales', () {
      final r =
          resolveTargetSize(100, 50, targetWidth: 1000, targetHeight: 1000);
      expect(r, (width: 100, height: 50));
    });

    test('binds to the tighter of width/height', () {
      // Width alone would ask for 0.5x; height alone would ask for 0.25x —
      // the box must honor the tighter constraint.
      final r =
          resolveTargetSize(4000, 4000, targetWidth: 2000, targetHeight: 1000);
      expect(r, (width: 1000, height: 1000));
    });
  });

  group('boxDownsample', () {
    test('averages a uniform block correctly', () {
      final src = ImageBuffer.int32(4, 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          src.intRows[y][x] = y * 4 + x;
        }
      }
      final dst = boxDownsample(src, 2, 2);
      // Top-left 2x2 block average: (0+1+4+5)/4 = 2.5 -> rounds to 3 (round
      // half to even is not required; .round() rounds half away from zero).
      expect(dst.intRows[0][0], 3);
    });

    test('is a no-op at the same size', () {
      final src = ImageBuffer.int32(3, 3);
      final dst = boxDownsample(src, 3, 3);
      expect(identical(src, dst), isTrue);
    });
  });

  group('JxlDecoder.decode with a target size', () {
    if (!haveCorpus) return;

    test('never upscales past native size', () {
      final bytes = _read('gray_screentone_d0_e7.jxl');
      final native = JxlDecoder.decode(bytes);
      final requested = JxlDecoder.decode(bytes,
          targetWidth: native.width * 4, targetHeight: native.height * 4);
      expect(requested.width, native.width);
      expect(requested.height, native.height);
    });

    test('plain lossy image: deep downscale (below 1:8 — DC-only eligible)',
        () {
      final bytes = _read('color_cover_d1.0_e7.jxl');
      final full = JxlDecoder.decode(bytes);
      final target = (full.width / 16).ceil();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, lessThanOrEqualTo(target));
      expect(small.isPreview, isFalse,
          reason: 'a requested downscale is a real result, not a preview');
      expect(_rmseVsBoxDownsample(full, small), lessThan(16.0));
    });

    test('plain lossy image: shallow downscale (above 1:8 — needs fallback)',
        () {
      final bytes = _read('color_cover_d1.0_e7.jxl');
      final full = JxlDecoder.decode(bytes);
      final target = (full.width * 3 / 4).round();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, target);
      expect(_rmseVsBoxDownsample(full, small), lessThan(8.0));
    });

    test(
        'plain (non-responsive) lossless (Modular) image falls back but still '
        'downscales correctly', () {
      // Not a Squeeze frame, so the low-res Squeeze path bails after the cheap
      // LfGlobal probe (`usesSqueeze` is false) and the full-decode fallback
      // serves it.
      final bytes = _read('screentone_256_d0_e7.jxl');
      final full = JxlDecoder.decode(bytes);
      final target = (full.width / 8).ceil();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, target);
      expect(_rmseVsBoxDownsample(full, small), lessThan(8.0));
    });

    test(
        'responsive (Squeeze) lossless image takes the low-res Squeeze path '
        '(at 1:8) and downscales correctly', () {
      // Large enough (1024x1536) that its high-frequency Squeeze residuals are
      // stored in pass groups, which the low-res path skips (decoding only the
      // vshift/hshift>=3 low-frequency pyramid) — see decoder
      // _modularLowResImageFor. Present only after tool/gen_corpus.py runs.
      final file = File('${corpusDir.path}/color_cover_d0_e5_responsive.jxl');
      if (!file.existsSync()) return;
      final bytes = file.readAsBytesSync();
      final full = JxlDecoder.decode(bytes);
      final target = (full.width / 8).ceil();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, target);
      expect(_rmseVsBoxDownsample(full, small), lessThan(8.0));
    });

    test(
        'small responsive (Squeeze) lossless image downscales correctly '
        '(whole pyramid in the global section, no pass groups to skip)', () {
      final bytes = _read('screentone_256_d0_e5_responsive.jxl');
      final full = JxlDecoder.decode(bytes);
      final target = (full.width / 8).ceil();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, target);
      expect(_rmseVsBoxDownsample(full, small), lessThan(8.0));
    });

    test('noise-flagged lossy image falls back but still downscales correctly',
        () {
      final bytes = _read('color_cover_d1_e7_noise.jxl');
      final full = JxlDecoder.decode(bytes);
      final target = (full.width / 16).ceil();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, target);
      expect(_rmseVsBoxDownsample(full, small), lessThan(16.0));
    });

    test(
        'progressive-DC (separate LF frame) lossy image takes the DC-only '
        'path (below 1:8) and downscales correctly', () {
      // The DC lives in a separate level-1 LF frame; the fast path decodes only
      // that (small) frame and skips the main frame's AC. As with every case
      // here, this asserts correctness vs a box-downsample of the full decode —
      // that the cheap path (not the fallback) served it is a timing detail.
      final bytes = _read('color_cover_d1.0_e5_progdc1.jxl');
      final full = JxlDecoder.decode(bytes);
      final target = (full.width / 16).ceil();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, target);
      expect(_rmseVsBoxDownsample(full, small), lessThan(16.0));
    });

    test('animated image falls back to the first frame, downscaled', () {
      final bytes = _read('anim_d0.jxl');
      final full = JxlDecoder.decode(bytes);
      final target = (full.width / 4).ceil();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, target);
      expect(_rmseVsBoxDownsample(full, small), lessThan(8.0));
    });
  }, skip: haveCorpus ? null : 'corpus unavailable');

  group('JxlDecoder.decode with a target size — conformance', () {
    if (!haveConformance) return;

    test('patches image falls back but still downscales correctly', () {
      final bytes =
          File('${conformanceDir.path}/patches/input.jxl').readAsBytesSync();
      final full = JxlDecoder.decode(bytes);
      final target = (full.width / 16).ceil();
      final small = JxlDecoder.decode(bytes, targetWidth: target);
      expect(small.width, target);
      // Looser tolerance: patches content is intentionally sharp repeated
      // detail, and this only needs to prove the fallback path is correct,
      // not match a jxlatte-precision reference (see spec_notes.md).
      expect(_rmseVsBoxDownsample(full, small), lessThan(24.0));
    });
  }, skip: haveConformance ? null : 'conformance testcases unavailable');
}
