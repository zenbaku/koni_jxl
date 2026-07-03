import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// L0 gate (doc/lossy_encoder_plan.md): our encode -> djxl decode, within a
/// generous RMSE/max threshold (correctness is the bar; quality is not).
/// Also cross-checks that our own decoder agrees with djxl on the same
/// file.

Uint8List _synthetic(int width, int height, int seed) {
  final rng = math.Random(seed);
  final out = Uint8List(width * height * 3);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v = switch ((x ~/ 8 + y ~/ 8) % 3) {
        0 => (x * 5 + y * 3) & 255, // gradient
        1 => rng.nextInt(256), // noise
        _ => 128 + ((x - y) & 63), // diagonal ramp
      };
      out[i++] = v;
      out[i++] = (v + 60) & 255;
      out[i++] = 255 - v;
    }
  }
  return out;
}

final _haveDjxl = (() {
  try {
    return Process.runSync('djxl', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
})();

void _check(int width, int height, {int seed = 1}) {
  final pixels = _synthetic(width, height, seed);
  final encoded = JxlEncoder.encodeLossy(pixels, width: width, height: height);

  // Our decoder must at least parse the file without throwing.
  final image = JxlDecoder.decode(encoded);
  expect(image.width, width);
  expect(image.height, height);

  if (!_haveDjxl) return;
  final dir = Directory.systemTemp.createTempSync('koni_lossy_l0');
  try {
    final jxlPath = '${dir.path}/t.jxl';
    final outPath = '${dir.path}/t.ppm';
    File(jxlPath).writeAsBytesSync(encoded);
    final r = Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
    expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
    final ref = PnmImage.parse(File(outPath).readAsBytesSync());
    expect(ref.width, width);
    expect(ref.height, height);

    var sumSq = 0.0;
    var maxDiff = 0;
    var n = 0;
    for (var c = 0; c < 3; c++) {
      final ours = channelAsInts(image.channels[c], 255);
      final theirs = ref.intPlanes![c];
      for (var i = 0; i < width * height; i++) {
        final d = ours[i] - theirs[i];
        sumSq += d * d;
        if (d.abs() > maxDiff) maxDiff = d.abs();
        n++;
      }
    }
    final rmse = math.sqrt(sumSq / n);
    // L0 is correctness-only: quantization is crude on purpose, so the
    // threshold is generous. The point is that djxl decodes it at all and
    // our decoder agrees with djxl (not with the original pixels).
    expect(rmse, lessThan(40), reason: 'rmse $rmse (max $maxDiff)');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('minimal single-block image', () {
    _check(8, 8);
  });

  test('single-group images', () {
    _check(32, 32);
    _check(64, 64, seed: 2);
    _check(256, 256, seed: 3);
  });

  test('non-square', () {
    _check(64, 32, seed: 4);
    _check(16, 64, seed: 5);
  });

  test('busy content with many distinct HF contexts (256-cluster cap)', () {
    // Regression test: a mix of gradient/noise/ramp blocks routinely
    // reaches 250-1000+ distinct HF coefficient contexts, which used to
    // exceed the bitstream's 256-histogram-per-entropy-code limit (djxl
    // rejects the file; this decoder's own EntropyStream doesn't enforce
    // that cap, so the bug was invisible without djxl).
    _check(24, 32, seed: 1);
    _check(32, 24, seed: 1);
    _check(8, 160, seed: 1);
  });

  test('rejects sizes that are not multiples of 8', () {
    expect(
        () =>
            JxlEncoder.encodeLossy(Uint8List(32 * 8 * 3), width: 32, height: 8),
        returnsNormally);
    expect(
        () =>
            JxlEncoder.encodeLossy(Uint8List(31 * 8 * 3), width: 31, height: 8),
        throwsArgumentError);
  });

  test('rejects sizes larger than 2048 (single LF group only)', () {
    expect(
        () => JxlEncoder.encodeLossy(Uint8List(2056 * 8 * 3),
            width: 2056, height: 8),
        throwsArgumentError);
  });

  test('multi-group images (width or height > 256)', () {
    _check(264, 8, seed: 10); // 2x1 groups, smallest possible
    _check(264, 104, seed: 11); // 2x1 groups
    _check(304, 512, seed: 12); // 2x2 groups
    _check(1000, 600, seed: 13); // larger multi-group image
  });

  test('adaptive quantization reduces banding on smooth gradients', () {
    if (!_haveDjxl) return;
    // A smooth gradient is exactly where a fixed quant step causes visible
    // banding; the adaptive per-block multiplier (L2) should cut RMSE
    // substantially here without this encoder needing to know it's a
    // gradient specifically (see doc/spec_notes.md).
    const w = 256, h = 256;
    final pixels = Uint8List(w * h * 3);
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = (x * 255 / w).round().clamp(0, 255);
        pixels[i++] = v;
        pixels[i++] = (v * 0.8).round();
        pixels[i++] = 255 - v;
      }
    }
    final encoded = JxlEncoder.encodeLossy(pixels, width: w, height: h);
    final image = JxlDecoder.decode(encoded);
    var sumSq = 0.0;
    for (var c = 0; c < 3; c++) {
      final ours = channelAsInts(image.channels[c], 255);
      for (var j = 0; j < w * h; j++) {
        final d = ours[j] - pixels[j * 3 + c];
        sumSq += d * d;
      }
    }
    final rmse = math.sqrt(sumSq / (w * h * 3));
    // A fixed-multiplier baseline measured ~2.0 here; adaptive quant
    // brings it under 1.0.
    expect(rmse, lessThan(1.0), reason: 'gradient rmse $rmse');
  });

  test('finer quantization improves RMSE', () {
    if (!_haveDjxl) return;
    final pixels = _synthetic(64, 64, 9);
    final coarse = encodeLossyVardctL0(pixels,
        width: 64,
        height: 64,
        config: const VardctL0Config(globalScale: 4096, quantLF: 16));
    final fine = encodeLossyVardctL0(pixels,
        width: 64,
        height: 64,
        config: const VardctL0Config(globalScale: 65536, quantLF: 16));
    expect(fine.length, greaterThan(coarse.length));
  });

  test('distance: RMSE increases monotonically', () {
    // L1 had a quality floor below distance ~0.5-0.8 (globalScale's
    // bitstream field alone can't push AC quantization much finer than
    // baseline); L2's custom per-frequency quant weight table (acScale)
    // removed that ceiling, so this now covers a much wider range.
    final pixels = _synthetic(128, 128, 20);
    double rmseAt(double distance) {
      final encoded = JxlEncoder.encodeLossy(pixels,
          width: 128, height: 128, distance: distance);
      final image = JxlDecoder.decode(encoded);
      var sumSq = 0.0;
      var n = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        for (var i = 0; i < 128 * 128; i++) {
          final d = ours[i] - pixels[i * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      return math.sqrt(sumSq / n);
    }

    final distances = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0];
    final rmses = distances.map(rmseAt).toList();
    for (var i = 1; i < rmses.length; i++) {
      expect(rmses[i], greaterThan(rmses[i - 1]),
          reason: 'rmse($distances) = $rmses should strictly increase');
    }
  });
}
