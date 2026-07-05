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

  test('non-multiple-of-8 sizes are padded internally, not rejected', () {
    // VarDCT always operates on an 8-block-aligned canvas internally; a
    // size that isn't already a multiple of 8 gets edge-replicated up to
    // the next one, but the *true* (unpadded) size is what's written to
    // the header and what decoders report/crop to — _check already
    // verifies image.width/height match the requested (unpadded) size.
    _check(31, 8, seed: 30);
    _check(8, 31, seed: 31);
    _check(31, 31, seed: 32);
    _check(1, 1, seed: 33); // smallest possible: pads up to a full 8x8.
  });

  test('rejects non-positive sizes', () {
    expect(() => JxlEncoder.encodeLossy(Uint8List(0), width: 0, height: 8),
        throwsArgumentError);
    expect(() => JxlEncoder.encodeLossy(Uint8List(0), width: 8, height: -1),
        throwsArgumentError);
  });

  test('multi-LF-group images (width or height > 2048)', () {
    // LF groups are 2048x2048 pixels; these exercise 2 LF groups in one
    // dimension, 2 in the other, and 2x2 (four) LF groups respectively,
    // including a non-2048-aligned edge (a partial, clamped LF group).
    _check(2056, 8, seed: 20);
    _check(8, 2056, seed: 21);
    _check(2056, 2056, seed: 22);
  });

  test('multi-group images (width or height > 256)', () {
    _check(264, 8, seed: 10); // 2x1 groups, smallest possible
    _check(264, 104, seed: 11); // 2x1 groups
    _check(304, 512, seed: 12); // 2x2 groups
    _check(1000, 600, seed: 13); // larger multi-group image
  });

  // Per-distance RMSE ceilings for the banding test below (an absolute
  // bound, not a reduction-vs-baseline check — this test doesn't compare
  // against a fixed-multiplier baseline, only asserts adaptive quant keeps
  // RMSE bounded). RMSE is *supposed* to grow with distance (that's the
  // quality knob doing its job), so a single flat threshold checked only
  // at the implicit default (distance=1.0) missed a real gap at
  // distance=8.0, where this heuristic's RMSE is legitimately higher —
  // see ROADMAP.md's "gradient banding-protection test's own gate gap"
  // and doc/spec_notes.md. Each threshold leaves >=15% margin over the
  // value measured with production defaults (RDOQ + variable transforms
  // both on, this encoder's actual shipped configuration): 0.5->0.38,
  // 1.0->0.87, 2.0->0.83, 4.0->0.77, 8.0->1.31.
  final gradientBandingThresholds = {
    0.5: 0.6,
    1.0: 1.0,
    2.0: 1.0,
    4.0: 1.0,
    8.0: 1.6,
  };
  for (final MapEntry(key: distance, value: threshold)
      in gradientBandingThresholds.entries) {
    test(
        'adaptive quantization keeps smooth-gradient banding bounded '
        'at distance $distance', () {
      if (!_haveDjxl) return;
      // A smooth gradient is exactly where a fixed quant step causes
      // visible banding; the adaptive per-block multiplier (L2) should cut
      // RMSE substantially here without this encoder needing to know it's
      // a gradient specifically (see doc/spec_notes.md).
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
      final encoded = JxlEncoder.encodeLossy(pixels,
          width: w, height: h, distance: distance);
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
      expect(rmse, lessThan(threshold), reason: 'gradient rmse $rmse');
    });
  }

  test('DC gradient prediction shrinks smooth-content file size', () {
    if (!_haveDjxl) return;
    // Regression guard for _gradientResiduals (DC/LF coefficients use
    // predictor 5, clamped gradient, instead of predictor 0/no
    // prediction). DC dominates file size on smooth content since almost
    // no AC survives quantization there — measured 7295 bytes with
    // predictor 0 (the previous behavior) vs 3115 bytes with predictor 5
    // for this exact image. A silent regression back to no prediction
    // would roughly double this file's size without failing any
    // correctness check (both are valid, djxl-decodable bitstreams — see
    // doc/spec_notes.md).
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
    expect(encoded.length, lessThan(5000),
        reason: 'gradient file size ${encoded.length}');
  });

  test('per-region chroma-from-luma helps spatially-varying color content', () {
    if (!_haveDjxl) return;
    // A single global CfL slope is a poor compromise when different parts
    // of the image have genuinely different color relationships (e.g. a
    // reddish region next to a bluish one); per-region CfL (HfMetadata's
    // xFromY/bFromY) should noticeably improve on the global-only fit
    // here. Measured ~26% RMSE reduction (3.261 -> 2.403) at roughly the
    // same file size when this was implemented — see doc/spec_notes.md.
    const w = 256, h = 256;
    final pixels = Uint8List(w * h * 3);
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final texture = (x * 7 + y * 3) & 63;
        final left = x < w / 2;
        final r = left ? 200 + texture ~/ 4 : 40 + texture ~/ 2;
        final g = 80 + texture ~/ 3;
        final b = left ? 40 + texture ~/ 2 : 200 + texture ~/ 4;
        pixels[i++] = r.clamp(0, 255);
        pixels[i++] = g.clamp(0, 255);
        pixels[i++] = b.clamp(0, 255);
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
    expect(rmse, lessThan(3.0), reason: 'split-color rmse $rmse');
  });

  test('filters default off: line art and screentone RMSE stays low', () {
    if (!_haveDjxl) return;
    // Regression guard for the enableFilters default. Gaborish/EPF are
    // smoothing filters: they measurably help smooth/photographic content
    // but catastrophically hurt manga's two dominant content types (both
    // ~13x worse RMSE in testing when filters were on) since they blur
    // exactly the sharp edges and regular high-frequency detail those are
    // made of — see VardctL0Config.enableFilters's doc comment. This
    // checks the *default* (filters off) stays good on that content;
    // encoder_roundtrip-style tests elsewhere don't exercise line-art-like
    // high-contrast edges at these dimensions.
    const w = 256, h = 256;
    Uint8List lineArt() {
      final out = Uint8List(w * h * 3);
      var i = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final onLine = (x % 40 < 3) || (y % 40 < 3) || ((x + y) % 60 < 3);
          final v = onLine ? 20 : 250;
          out[i++] = v;
          out[i++] = v;
          out[i++] = v;
        }
      }
      return out;
    }

    final pixels = lineArt();
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
    // Measured ~1.3 with filters off, ~17 with filters on.
    expect(rmse, lessThan(5.0), reason: 'line art rmse $rmse');
  });

  test('variable transforms (16x16) decode correctly when enabled', () {
    if (!_haveDjxl) return;
    // Exercises the adaptive 8x8/16x16 placement/context-model machinery
    // end to end: a non-multiple-of-16 dimension forces a mix of paired
    // (16x16) and leftover single (8x8) blocks in the same image, plus a
    // multi-group size to check blocks are correctly bucketed by group.
    for (final (w, h) in [(256, 256), (264, 264), (528, 264)]) {
      final pixels = _synthetic(w, h, 4);
      final encoded = encodeLossyVardctL0(pixels,
          width: w,
          height: h,
          config: const VardctL0Config(enableVariableTransforms: true));
      final image = JxlDecoder.decode(encoded);
      expect(image.width, w);
      expect(image.height, h);
      final dir = Directory.systemTemp.createTempSync('koni_vt');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed for ${w}x$h: ${r.stderr}');
      } finally {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test('RD hfMult search (opt-in) decodes correctly', () {
    if (!_haveDjxl) return;
    // Phase 1 gate (doc/spec_notes.md): correctness only, not yet a
    // quality/size claim (kLambda is uncalibrated — see
    // tool/calibrate_rd_lambda.dart). Exercises the bootstrap pass, the
    // per-block candidate scoring, and the commit path across single-
    // group, multi-group and multi-LF-group sizes, plus combination with
    // 16x16 blocks (enableVariableTransforms) to check the two opt-in
    // features don't interact badly even though RD search doesn't yet
    // choose between transform sizes itself.
    for (final (w, h, variableTransforms) in [
      (256, 256, false),
      (264, 104, false), // multi-group
      (2056, 8, false), // multi-LF-group
      (264, 264, true), // + 16x16 blocks
    ]) {
      final pixels = _synthetic(w, h, 7);
      final encoded = encodeLossyVardctL0(pixels,
          width: w,
          height: h,
          config: VardctL0Config(
              enableRdHfMult: true,
              enableVariableTransforms: variableTransforms));
      final image = JxlDecoder.decode(encoded);
      expect(image.width, w);
      expect(image.height, h);
      final dir = Directory.systemTemp.createTempSync('koni_rd');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed for ${w}x$h: ${r.stderr}');
      } finally {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test('RDOQ coefficient dropping (opt-in) decodes correctly', () {
    if (!_haveDjxl) return;
    // Phase 1 gate (doc/spec_notes.md): correctness only, not yet a
    // quality/size claim (kRdoqLambda is uncalibrated — see
    // tool/calibrate_rdoq_lambda.dart). Same matrix as the RD-hfMult
    // test, plus one case combining both optional passes to confirm they
    // compose without corrupting each other's state. Every block-channel
    // RDOQ actually drops a coefficient in also exercises the encoder's
    // internal debug-only differential rate-accounting self-check
    // (`_rdoqBlockChannel`'s `assert` block) — `dart test` runs with
    // assertions enabled, so this is the real correctness gate for the
    // live/frozen remaining/prev accounting, not just a round-trip check
    // (a round-trip decode alone can't distinguish an internally
    // consistent RD estimate from a buggy one, since the real bitstream
    // is always rebuilt fresh from whatever final coefficients result).
    for (final (w, h, variableTransforms, alsoRdHfMult) in [
      (256, 256, false, false),
      (264, 104, false, false), // multi-group
      (2056, 8, false, false), // multi-LF-group
      (264, 264, true, false), // + 16x16 blocks
      (256, 256, false, true), // + RD hfMult search combined
    ]) {
      final pixels = _synthetic(w, h, 11);
      final encoded = encodeLossyVardctL0(pixels,
          width: w,
          height: h,
          config: VardctL0Config(
              enableRdoq: true,
              enableRdHfMult: alsoRdHfMult,
              enableVariableTransforms: variableTransforms));
      final image = JxlDecoder.decode(encoded);
      expect(image.width, w);
      expect(image.height, h);
      final dir = Directory.systemTemp.createTempSync('koni_rdoq');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed for ${w}x$h: ${r.stderr}');
      } finally {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test('RDOQ can drop every AC coefficient in a channel', () {
    if (!_haveDjxl) return;
    // Edge case: a flat (constant-color) image has zero true AC energy in
    // every block, so RDOQ should be able (in principle) to zero whatever
    // the quantizer produced without hitting an unhandled countNonZero==0
    // state either inside the walk or downstream in token emission.
    const w = 64, h = 64;
    final pixels = Uint8List(w * h * 3);
    for (var i = 0; i < pixels.length; i += 3) {
      pixels[i] = 128;
      pixels[i + 1] = 128;
      pixels[i + 2] = 128;
    }
    final encoded = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config:
            const VardctL0Config(enableRdoq: true, rdoqLambdaOverride: 1e7));
    final image = JxlDecoder.decode(encoded);
    expect(image.width, w);
    expect(image.height, h);
    final dir = Directory.systemTemp.createTempSync('koni_rdoq_flat');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(encoded);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test(
      'variable transforms (default on) no longer regresses manga-like '
      'content', () {
    if (!_haveDjxl) return;
    // Regression guard for the enableVariableTransforms default, updated
    // when the default flipped from false to true. The *old* 8x8-vs-16x16
    // decision was a crude pre-quantization bit-cost proxy with no
    // visibility into the real context-adaptive entropy cost: it picked
    // 16x16 100% of the time on a screentone test pattern, yet real
    // end-to-end output was both larger *and* worse RMSE than plain 8x8
    // there (and +31% size on line art) — that's what justified defaulting
    // it off. `_decideTransformLayout` replaced that proxy with a real
    // bootstrap-frozen bit-rate estimate (see its doc comment and
    // doc/spec_notes.md), calibrated via `tool/calibrate_transform_lambda.
    // dart` across the full distance range and confirmed to no longer
    // regress on exactly these two content types — this test guards that.
    // A whole-image real-assembly safety net (`encodeLossyVardctL0`
    // assembles a real body for both the all-8x8 and decided-mixed
    // layouts and keeps whichever is smaller) makes this an *exact*
    // guarantee, not just "close": the "off" candidate is byte-identical
    // to `enableVariableTransforms: false`, so `withVt <= withoutVt`
    // always holds, with no tolerance needed.
    const w = 256, h = 256;
    Uint8List screentone() {
      final out = Uint8List(w * h * 3);
      var i = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final dotX = x % 6, dotY = y % 6;
          final dist =
              math.sqrt(math.pow(dotX - 2.5, 2) + math.pow(dotY - 2.5, 2));
          final v = dist < 2.0 ? 30 : 220;
          out[i++] = v;
          out[i++] = v;
          out[i++] = v;
        }
      }
      return out;
    }

    Uint8List lineArt() {
      final out = Uint8List(w * h * 3);
      var i = 0;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final onLine = (x % 40 < 3) || (y % 40 < 3) || ((x + y) % 60 < 3);
          final v = onLine ? 20 : 250;
          out[i++] = v;
          out[i++] = v;
          out[i++] = v;
        }
      }
      return out;
    }

    for (final MapEntry(key: name, value: pixels) in {
      'screentone': screentone(),
      'line art': lineArt(),
    }.entries) {
      final withVt = encodeLossyVardctL0(pixels,
          width: w,
          height: h,
          config: const VardctL0Config(enableVariableTransforms: true));
      final withoutVt = encodeLossyVardctL0(pixels,
          width: w,
          height: h,
          config: const VardctL0Config(enableVariableTransforms: false));
      expect(withVt.length, lessThanOrEqualTo(withoutVt.length),
          reason: 'variable transforms (${withVt.length}B) should never '
              'be larger than off (${withoutVt.length}B) on $name — the '
              'whole-image safety net makes this an exact guarantee');
    }
  });

  test('variable transforms (default on) genuinely wins on smooth content', () {
    if (!_haveDjxl) return;
    // The never-worse guard above only checks "not larger" — it would
    // stay green even if a future change made 16x16 never win and the
    // safety net silently fell back to "off" on every input. This locks
    // in the other half: on content 16x16 genuinely helps (a smooth
    // gradient, mirroring the "adaptive quantization" test above and
    // tool/calibrate_transform_lambda.dart's own measured win there —
    // at `distance=2.0` specifically, where the sweep found a comfortable
    // -18.2% win; the plain default config's implicit distance~1.0
    // happens to land on a rarer tie for this exact pattern), variable
    // transforms must produce a strictly smaller file, not just a tied one.
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
    final base = VardctL0Config.fromDistance(2.0);
    final withVt = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true));
    final withoutVt = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: false));
    expect(withVt.length, lessThan(withoutVt.length),
        reason: 'variable transforms (${withVt.length}B) should beat '
            'off (${withoutVt.length}B) on a smooth gradient');
  });

  test(
      'DCT 32x32 (default on) genuinely wins on large smooth content and '
      'round-trips through both decoders', () {
    // Locks in the *capability*, not just the never-worse safety net: on
    // content this feature is precisely designed for (a large low-frequency
    // gradient, mirroring the enableVariableTransforms test above one level
    // up), a silent regression to 16x16/8x8-only output would stay within
    // every correctness gate (RMSE) and every other test in this file,
    // since a 16x16-mix body is a valid fallback, not an invalid one.
    // Size (512x512) and distance (4.0) match
    // tool/calibrate_transform32_lambda.dart's own gradient sweep, which
    // measured a comfortable -8.8% win here — the plain default config's
    // implicit distance~1.0 lands on a tie for this pattern at 256x256 (see
    // the analogous enableVariableTransforms comment above for the same
    // gotcha one level down).
    const w = 512, h = 512;
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
    final base = VardctL0Config.fromDistance(4.0);
    final withIt = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableTransform32: true));
    final withoutIt = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableTransform32: false));
    expect(withIt.length, lessThan(withoutIt.length),
        reason: 'DCT 32x32 (${withIt.length}B) should beat 16x16-mix-only '
            '(${withoutIt.length}B) on a large smooth gradient');

    final image = JxlDecoder.decode(withIt);
    expect(image.width, w);
    expect(image.height, h);

    if (!_haveDjxl) return;
    final dir = Directory.systemTemp.createTempSync('koni_lossy_t32');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(withIt);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
      final ref = PnmImage.parse(File(outPath).readAsBytesSync());
      expect(ref.width, w);
      expect(ref.height, h);

      var sumSq = 0.0;
      var n = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        final theirs = ref.intPlanes![c];
        for (var j = 0; j < w * h; j++) {
          final d = ours[j] - theirs[j];
          sumSq += d * d;
          n++;
        }
      }
      final rmse = math.sqrt(sumSq / n);
      expect(rmse, lessThan(40), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
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
