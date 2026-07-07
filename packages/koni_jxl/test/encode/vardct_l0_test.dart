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

  test('perceptual-mask RD hfMult (opt-in) decodes correctly', () {
    if (!_haveDjxl) return;
    // The masking distortion term (VardctL0Config.perceptualMask, layered on
    // enableRdHfMult) uses acScale^2 lambda scaling and per-block masking
    // weights — a distinct code path from the plain RD search above. Gate it
    // for correctness across the same size shapes and at a coarse distance
    // (where acScale != 1, so the acScale^2 scaling is genuinely exercised),
    // plus a runtime maskParamsOverride. Correctness only — the shipped
    // default stays off pending multi-distance calibration
    // (tool/calibrate_perceptual_mask.dart).
    for (final (w, h, distance, spatial) in [
      (256, 256, 1.0, false),
      (264, 104, 1.0, false), // multi-group
      (2056, 8, 1.0, false), // multi-LF-group
      (256, 256, 4.0, false), // acScale != 1 -> exercises acScale^2 scaling
      (256, 256, 2.0, true), // spatial-blur masking signal
      (264, 104, 1.0, true), // spatial + multi-group (grid indexing)
    ]) {
      final pixels = _synthetic(w, h, 7);
      final base = VardctL0Config.fromDistance(distance);
      final encoded = encodeLossyVardctL0(pixels,
          width: w,
          height: h,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: false,
              enableRdHfMult: true,
              perceptualMask: true,
              spatialMask: spatial,
              maskParamsOverride: (
                hi: 8.0,
                knee: spatial ? 8.0 : 1.5,
                gamma: 2.0
              )));
      final image = JxlDecoder.decode(encoded);
      expect(image.width, w);
      expect(image.height, h);
      final dir = Directory.systemTemp.createTempSync('koni_mask');
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
            maxTransformSize: 32));
    final withoutIt = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            maxTransformSize: 16));
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

  test(
      'the full cascade (up to DCT 256x256) places, entropy-codes, and '
      'round-trips correctly when it genuinely wins', () {
    // Correctness coverage for 64x64/128x128/256x256 (the rest of Tranche
    // A, generalized from 32x32's proven architecture — see ROADMAP.md,
    // 2026-07-05: this is a completeness goal, not gated on real-manga
    // ROI, so this test only needs to prove each size works, not that it
    // helps). A 256x256-pixel candidate exactly fills one whole group (32
    // 8x8-cells square) — a footprint no smaller size gets close to — so
    // this specifically exercises HfMetadata placement/entropy-coding at
    // that edge case, not just the merge-decision arithmetic the identity
    // tests in vardct_forward_test.dart already cover in isolation. Found
    // empirically (jxl.encdebug) rather than assumed: a 256x256 canvas
    // (single group) with a smooth gradient at distance=64 is the minimal
    // config where the *entire* cascade (8x8->16x16->32x32->64x64->
    // 128x128->256x256) is the genuinely smallest, real-assembled
    // candidate — not just an intermediate one tried and discarded.
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
    final base = VardctL0Config.fromDistance(64.0);
    final encoded = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            maxTransformSize: 256));

    // Asserts the cascade actually engaged at this config, not just that
    // the feature is enabled — the test's name promises "when it genuinely
    // wins," and without this a future change that stopped anything past
    // 16x16 from ever winning here would stay green while silently
    // dropping the only coverage of the 256x256-fills-a-group placement
    // path (128x128 doesn't reach a full 32-cell group; only 256x256 does).
    final withoutCascade = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            maxTransformSize: 16));
    expect(encoded.length, lessThan(withoutCascade.length),
        reason: 'the cascade (${encoded.length}B) should beat '
            'level-1-only (${withoutCascade.length}B) at this config, '
            'confirming something past 16x16 genuinely won');

    final image = JxlDecoder.decode(encoded);
    expect(image.width, w);
    expect(image.height, h);

    if (!_haveDjxl) return;
    final dir = Directory.systemTemp.createTempSync('koni_lossy_t256');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(encoded);
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
      // Large-DCT content ("16x32 and larger") gets the looser threshold
      // this project's inherited decode-side deviation already documents
      // (doc/spec_notes.md) — same generous bound the 32x32 test above
      // uses, not a tighter 8x8/16x16 bar.
      expect(rmse, lessThan(40), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test(
      'DCT 16x8/8x16 (opt-in, Tranche B) genuinely wins on a mix of '
      'shapes and round-trips through both decoders', () {
    // The critical de-risking test for Tranche B's first pair, per the
    // design review before this landed: forward/inverse identity and
    // LLF-inversion unit tests (vardct_forward_test.dart) confirm the
    // math, but every bug that could actually bite lives in the
    // integration -- emission order (a wide block covers cells to its
    // right, a tall block covers cells below), flip=false placement (the
    // *first* non-transposed block this encoder ever emits -- every prior
    // type, square or the tall member of this very pair, is flip=true),
    // and the merge cascade's containment guard. A single-shape test
    // can't catch an emission-order desync between shapes; this one packs
    // 4 quadrants, each engineered to favor a different shape, into one
    // canvas so all of them coexist and interleave at their shared
    // boundaries: horizontal stripes (top-left, favors 8x16 -- constant
    // across one stripe's width), vertical stripes (top-right, favors
    // 16x8), a smooth gradient (bottom-left, favors square 16x16), and
    // noise (bottom-right, stays plain 8x8).
    //
    // Canvas size/stripe period/distance found empirically (jxl.encdebug
    // tallies), not guessed, matching this project's established
    // methodology (see the 256x256-fills-a-group test above): swept until
    // the *chosen*, real-assembled candidate contained rectangular shapes
    // alongside plain 8x8 and genuinely beat the square-only cascade, not
    // just the plain bootstrap. Re-swept to 64x64 (originally 32x32) after
    // the `customParamsByIndex` per-candidate-precision cleanup (see
    // doc/spec_notes.md): a custom weight table is a fixed one-time cost
    // that a 32x32 canvas's few blocks couldn't amortize, so the genuine
    // (but always thin) win from actually using DCT16x8/8x16 here got
    // entirely swamped by their own table's overhead once accounting
    // became byte-precise instead of approximate — not a regression in
    // the encoder, a more accurate measurement exposing how thin this
    // specific test's margin always was. 64x64 gives a solid, clearly
    // positive margin at this distance (tally={DCT 8x16: 20, DCT 16x8: 8,
    // DCT 8x8: 8}).
    const size = 64, period = 10;
    final pixels = Uint8List(size * size * 3);
    final rng = math.Random(7);
    var i = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final qy = y < size ~/ 2 ? 0 : 1, qx = x < size ~/ 2 ? 0 : 1;
        final int v;
        if (qy == 0 && qx == 0) {
          v = (y ~/ period).isEven ? 30 : 220; // horizontal stripes
        } else if (qy == 0 && qx == 1) {
          v = (x ~/ period).isEven ? 30 : 220; // vertical stripes
        } else if (qy == 1 && qx == 0) {
          v = (x * 255 / (size ~/ 2)).round().clamp(0, 255); // gradient
        } else {
          v = rng.nextInt(256); // noise
        }
        pixels[i++] = v;
        pixels[i++] = v;
        pixels[i++] = v;
      }
    }
    final base = VardctL0Config.fromDistance(2.0);
    final withRect = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableRectangularTransforms: true));
    final squareOnly = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableRectangularTransforms: false));
    expect(withRect.length, lessThan(squareOnly.length),
        reason: 'rectangular transforms (${withRect.length}B) should beat '
            'square-only (${squareOnly.length}B) on this mixed-shape '
            'content, confirming 16x8/8x16 genuinely won somewhere');

    // Decode-vs-*original* RMSE, not just decode-vs-djxl: a semantic
    // coefficient-scan error in the flip branch (_scanChannelValues,
    // _rdoqBlockChannel) would still leave our decoder and djxl agreeing
    // with EACH OTHER (both read the same, consistently-mis-scanned
    // bitstream the same way) while both reconstruct transposed garbage
    // relative to the source pixels — invisible to a decode-vs-djxl-only
    // check. DCT 8x16 (flip=false) is the first non-transposed block this
    // encoder has ever emitted (every prior type, square or 16x8, is
    // flip=true), so nothing before this test exercised that branch at
    // all. A relative bound (rectangular no worse than ~2x square-only)
    // sidesteps picking an absolute threshold while still failing loudly
    // if flip is wrong (which would blow this up by an order of magnitude
    // or more, not by a small margin).
    double rmseVsOriginal(Uint8List encoded) {
      final decoded = JxlDecoder.decode(encoded).toRgba8();
      var sumSq = 0.0;
      var n = 0;
      for (var p = 0; p < size * size; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      return math.sqrt(sumSq / n);
    }

    final rectRmse = rmseVsOriginal(withRect);
    final squareRmse = rmseVsOriginal(squareOnly);
    expect(rectRmse, lessThan(squareRmse * 2 + 1),
        reason: 'rectangular RMSE-vs-original ($rectRmse) should be in the '
            'same ballpark as square-only ($squareRmse), not blown up by a '
            'coefficient-scan/flip error');

    final image = JxlDecoder.decode(withRect);
    expect(image.width, size);
    expect(image.height, size);

    if (!_haveDjxl) return;
    final dir = Directory.systemTemp.createTempSync('koni_lossy_rect');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(withRect);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
      final ref = PnmImage.parse(File(outPath).readAsBytesSync());
      expect(ref.width, size);
      expect(ref.height, size);

      var sumSq = 0.0;
      var n = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        final theirs = ref.intPlanes![c];
        for (var j = 0; j < size * size; j++) {
          final d = ours[j] - theirs[j];
          sumSq += d * d;
          n++;
        }
      }
      final rmse = math.sqrt(sumSq / n);
      // 16x8/8x16 are NOT in the documented "DCT 16x32 and larger"
      // large-DCT deviation bucket (doc/spec_notes.md) that justifies the
      // looser <40 bound the 32x32/256x256 tests above use — this is
      // small enough to hold this project's standard lossy gate
      // (measured ~0.48 at this exact config; CLAUDE.md's documented
      // standard is rmse < 2.0).
      expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test(
      'DCT 16x8/8x16 blocks near a 32-block group boundary in a '
      'multi-group image round-trip correctly', () {
    // NOT a test that a block can straddle a group boundary -- by the
    // merge cascade's own `by % strideY == 0 && bx % strideX == 0`
    // alignment check, and every Tranche-B dctSelect dimension here (1, 2)
    // dividing 32, straddling is already algebraically impossible. What
    // this exercises concretely (rather than trusting that algebra alone)
    // is `_finishEncode`'s group-bucketing (256x256-pixel groups keyed
    // purely by block origin) with real rectangular blocks landing
    // immediately adjacent to a group boundary on both sides: a
    // multi-group canvas (512 pixels wide = 2 groups of 32 blocks) with
    // uniform horizontal-stripe content (favoring 8x16) spanning the
    // group-0/group-1 boundary at block-column 32, djxl round-tripped.
    const w = 512, h = 32, period = 10;
    final pixels = Uint8List(w * h * 3);
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = (y ~/ period).isEven ? 30 : 220;
        pixels[i++] = v;
        pixels[i++] = v;
        pixels[i++] = v;
      }
    }
    final base = VardctL0Config.fromDistance(2.0);
    final encoded = encodeLossyVardctL0(pixels,
        width: w,
        height: h,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableRectangularTransforms: true));

    final image = JxlDecoder.decode(encoded);
    expect(image.width, w);
    expect(image.height, h);

    if (!_haveDjxl) return;
    final dir = Directory.systemTemp.createTempSync('koni_lossy_rectgroup');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(encoded);
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
      // Not in the "DCT 16x32 and larger" large-DCT deviation bucket
      // either (measured ~0.44 at this exact config) -- see the previous
      // test's comment.
      expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test(
      'the rest of Tranche B (32x8/8x32 through 256x128/128x256) places, '
      'entropy-codes, and round-trips correctly across tiers', () {
    // Correctness coverage for the remaining 10 rectangular types (the
    // "4:1 line" case 32x8/8x32, and the "2:1 pair" at each of the four
    // higher cascade tiers) - mechanically fanned out from 16x8/8x16's
    // proven tryMergeLevel architecture, per ROADMAP.md/spec_notes.md:
    // this only needs to prove each size places and round-trips
    // correctly, not that it helps (existence is a completeness goal,
    // independent of manga ROI). A single config exercising two
    // different tiers at once (16x16 alongside 32x8) catches a class of
    // bug a single-tier test can't: cross-tier interaction, e.g. the
    // 32-tier's rectangular pre-pass incorrectly assuming the 16-tier
    // hasn't already committed something in its way.
    //
    // Config found empirically (jxl.encdebug tallies), not guessed: a
    // 128x128 vertical gradient at distance=16 was swept until the
    // *chosen* candidate contained DCT 32x8 (the 4:1 line case) sharing
    // the layout with DCT 16x16 blocks.
    const size = 128;
    final pixels = Uint8List(size * size * 3);
    var i = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = (y * 255 / size).round().clamp(0, 255);
        pixels[i++] = v;
        pixels[i++] = (v * 0.8).round();
        pixels[i++] = 255 - v;
      }
    }
    final base = VardctL0Config.fromDistance(16.0);
    final withRect = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableRectangularTransforms: true));
    final squareOnly = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableRectangularTransforms: false));

    // NOT a "genuinely wins vs. square-only" assertion here (unlike the
    // mixed-shape test above): with the rectangular pre-pass now running
    // before every square level, not just the 16x16 one, "square-only"
    // is no longer guaranteed to be beaten -- see VardctL0Config.
    // enableRectangularTransforms's doc comment on why the guarantee is
    // "vs. plain 8x8/bootstrap," not "vs. square-only." This config
    // happens to still round-trip correctly either way; the point of
    // this test is placement/entropy-coding correctness across tiers,
    // not a compression win.
    double decodeVsOriginal(Uint8List encoded) {
      final decoded = JxlDecoder.decode(encoded).toRgba8();
      var sumSq = 0.0;
      var n = 0;
      for (var p = 0; p < size * size; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      return math.sqrt(sumSq / n);
    }

    final rectRmse = decodeVsOriginal(withRect);
    final squareRmse = decodeVsOriginal(squareOnly);
    expect(rectRmse, lessThan(squareRmse * 2 + 1),
        reason: 'rectangular RMSE-vs-original ($rectRmse) should be in the '
            'same ballpark as square-only ($squareRmse), not blown up by a '
            'coefficient-scan/flip error at any of the new sizes');

    final image = JxlDecoder.decode(withRect);
    expect(image.width, size);
    expect(image.height, size);

    if (!_haveDjxl) return;
    final dir = Directory.systemTemp.createTempSync('koni_lossy_rectfanout');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(withRect);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
      final ref = PnmImage.parse(File(outPath).readAsBytesSync());
      expect(ref.width, size);
      expect(ref.height, size);

      var sumSq = 0.0;
      var n = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        final theirs = ref.intPlanes![c];
        for (var j = 0; j < size * size; j++) {
          final d = ours[j] - theirs[j];
          sumSq += d * d;
          n++;
        }
      }
      final rmse = math.sqrt(sumSq / n);
      expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test(
      'DCT 256x128/128x256 (the largest rectangular pair) genuinely wins '
      'and round-trips correctly', () {
    // Mirrors the 16x8/8x16 "genuinely wins" test at the opposite end of
    // Tranche B's size range -- proves the fan-out to the largest pair
    // isn't just non-crashing but a real, real-assembled winner too, not
    // just tried-and-discarded. Config found empirically: a 256x256
    // single-group vertical gradient at distance=32 with maxTransformSize
    // 256, swept until the chosen candidate was DCT 256x128 outright.
    const size = 256;
    final pixels = Uint8List(size * size * 3);
    var i = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = (y * 255 / size).round().clamp(0, 255);
        pixels[i++] = v;
        pixels[i++] = (v * 0.8).round();
        pixels[i++] = 255 - v;
      }
    }
    final base = VardctL0Config.fromDistance(32.0);
    final withRect = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            maxTransformSize: 256,
            enableRectangularTransforms: true));
    final squareOnly = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            maxTransformSize: 256,
            enableRectangularTransforms: false));
    expect(withRect.length, lessThan(squareOnly.length),
        reason: 'DCT 256x128 (${withRect.length}B) should beat square-only '
            '(${squareOnly.length}B) at this config');

    double decodeVsOriginal(Uint8List encoded) {
      final decoded = JxlDecoder.decode(encoded).toRgba8();
      var sumSq = 0.0;
      var n = 0;
      for (var p = 0; p < size * size; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      return math.sqrt(sumSq / n);
    }

    final rectRmse = decodeVsOriginal(withRect);
    final squareRmse = decodeVsOriginal(squareOnly);
    expect(rectRmse, lessThan(squareRmse * 2 + 1),
        reason: 'rectangular RMSE-vs-original ($rectRmse) should be in the '
            'same ballpark as square-only ($squareRmse)');

    final image = JxlDecoder.decode(withRect);
    expect(image.width, size);
    expect(image.height, size);

    if (!_haveDjxl) return;
    final dir = Directory.systemTemp.createTempSync('koni_lossy_rect256128');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(withRect);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
      final ref = PnmImage.parse(File(outPath).readAsBytesSync());
      expect(ref.width, size);
      expect(ref.height, size);

      var sumSq = 0.0;
      var n = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        final theirs = ref.intPlanes![c];
        for (var j = 0; j < size * size; j++) {
          final d = ours[j] - theirs[j];
          sumSq += d * d;
          n++;
        }
      }
      final rmse = math.sqrt(sumSq / n);
      expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test(
      'DCT 128x256 (the largest flip=false rectangular type) genuinely '
      'wins and round-trips correctly', () {
    // Mirrors the 256x128 test above with the orientation flipped: every
    // other "genuinely wins" test in this tranche (16x8, the cross-tier
    // 32x8 test, 256x128) happens to land on a *tall* (flip=true) winner,
    // since they all use vertical gradients. flip=false is only proven
    // once, at the smallest size (8x16, from the first-slice test) --
    // _scanChannelValues/_rdoqBlockChannel's flip=false branch is
    // exercised at every size in between only by the identity/LLF tests
    // in vardct_forward_test.dart, which never touch that scan path at
    // all. A horizontal gradient here favors wide (flip=false) blocks,
    // proving DCT 128x256 specifically -- the largest flip=false type --
    // closing that gap at the opposite size extreme from 8x16. Config
    // found empirically: a 256x256 single-group horizontal gradient at
    // distance=32 with maxTransformSize 256, swept until the chosen
    // candidate was DCT 128x256 outright.
    const size = 256;
    final pixels = Uint8List(size * size * 3);
    var i = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = (x * 255 / size).round().clamp(0, 255);
        pixels[i++] = v;
        pixels[i++] = (v * 0.8).round();
        pixels[i++] = 255 - v;
      }
    }
    final base = VardctL0Config.fromDistance(32.0);
    final withRect = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            maxTransformSize: 256,
            enableRectangularTransforms: true));
    final squareOnly = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            maxTransformSize: 256,
            enableRectangularTransforms: false));
    expect(withRect.length, lessThan(squareOnly.length),
        reason: 'DCT 128x256 (${withRect.length}B) should beat square-only '
            '(${squareOnly.length}B) at this config');

    double decodeVsOriginal(Uint8List encoded) {
      final decoded = JxlDecoder.decode(encoded).toRgba8();
      var sumSq = 0.0;
      var n = 0;
      for (var p = 0; p < size * size; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      return math.sqrt(sumSq / n);
    }

    final rectRmse = decodeVsOriginal(withRect);
    final squareRmse = decodeVsOriginal(squareOnly);
    expect(rectRmse, lessThan(squareRmse * 2 + 1),
        reason: 'rectangular RMSE-vs-original ($rectRmse) should be in the '
            'same ballpark as square-only ($squareRmse), not blown up by a '
            'flip=false coefficient-scan error');

    final image = JxlDecoder.decode(withRect);
    expect(image.width, size);
    expect(image.height, size);

    if (!_haveDjxl) return;
    final dir = Directory.systemTemp.createTempSync('koni_lossy_rect128256');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(withRect);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
      final ref = PnmImage.parse(File(outPath).readAsBytesSync());
      expect(ref.width, size);
      expect(ref.height, size);

      var sumSq = 0.0;
      var n = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        final theirs = ref.intPlanes![c];
        for (var j = 0; j < size * size; j++) {
          final d = ours[j] - theirs[j];
          sumSq += d * d;
          n++;
        }
      }
      final rmse = math.sqrt(sumSq / n);
      expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  // Tranche C (ROADMAP.md/spec_notes.md), first slice: DCT4x4 -- unlike
  // Tranche A/B (plain DCTs, differing only in dctSelect footprint), this
  // is the first "bespoke" transform type (no shared plain-DCT machinery).
  // Config found empirically (jxl.encdebug tallies), not guessed: a 32x32
  // canvas with a 4x4-quadrant checkerboard (period 4, so DC jumps sharply
  // every 4 pixels in both axes) makes every block choose DCT4x4 over
  // plain DCT8x8 -- the per-quadrant DC term captures the level jump
  // directly, which an 8x8 DCT can only approximate via AC ringing.
  //
  // Looped over distances spanning the normal range (0.5 to 4.0), NOT just
  // the default 1.0 -- deliberately, per this project's own RDOQ/hfMult
  // lambda-scaling history (see doc/spec_notes.md): `usesCustomWeights`
  // (and therefore the whole per-mode weight-table/bitstream-write
  // dispatch this slice added -- see VardctL0Config.enableBespokeTransforms
  // and _writeHfGlobalAndPass) is dead code at distance=1.0
  // (acScale==1.0), so a suite that only tested there would pass even if
  // that plumbing were completely broken. This same config was confirmed
  // (via the encdebug tally) to make DCT4x4 win outright at every one of
  // these four distances, not just one.
  for (final distance in [0.5, 1.0, 2.0, 4.0]) {
    test(
        'DCT4x4 (Tranche C, opt-in) genuinely wins on a 4x4-quadrant '
        'checkerboard and round-trips correctly at distance=$distance', () {
      const size = 32;
      final pixels = Uint8List(size * size * 3);
      var i = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final qy = y ~/ 4, qx = x ~/ 4;
          final v = (qy + qx).isEven ? 40 : 210;
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final withBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));
      final withoutBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: false));
      expect(withBespoke.length, lessThan(withoutBespoke.length),
          reason: 'DCT4x4 (${withBespoke.length}B) should beat plain 8x8 '
              '(${withoutBespoke.length}B) at this config');

      double decodeVsOriginal(Uint8List encoded) {
        final decoded = JxlDecoder.decode(encoded).toRgba8();
        var sumSq = 0.0;
        var n = 0;
        for (var p = 0; p < size * size; p++) {
          for (var c = 0; c < 3; c++) {
            final d = decoded[p * 4 + c] - pixels[p * 3 + c];
            sumSq += d * d;
            n++;
          }
        }
        return math.sqrt(sumSq / n);
      }

      final bespokeRmse = decodeVsOriginal(withBespoke);
      final plainRmse = decodeVsOriginal(withoutBespoke);
      expect(bespokeRmse, lessThan(plainRmse * 2 + 1),
          reason: 'DCT4x4 RMSE-vs-original ($bespokeRmse) should be in the '
              'same ballpark as plain 8x8 ($plainRmse), not blown up by a '
              'forward-transform or quant-weight/bitstream-mode error');

      final image = JxlDecoder.decode(withBespoke);
      expect(image.width, size);
      expect(image.height, size);

      if (!_haveDjxl) return;
      final dir = Directory.systemTemp.createTempSync('koni_lossy_dct4x4');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(withBespoke);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, size);
        expect(ref.height, size);

        var sumSq = 0.0;
        var n = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < size * size; j++) {
            final d = ours[j] - theirs[j];
            sumSq += d * d;
            n++;
          }
        }
        final rmse = math.sqrt(sumSq / n);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

  // Every test above forces a UNIFORM tally (every 8x8 cell picks DCT4x4),
  // so the block-info stream never actually interleaves transform-type IDs
  // {0 (DCT8x8), 3 (DCT4x4), 4 (DCT16x16)} in one bitstream, and
  // tryMergeLevel's 16x16 merge pass never sees a DCT4x4 leaf next to a
  // plain 8x8 leaf. That is exactly the kind of tier-interaction gap this
  // project got burned by once already (Tranche B's flip=false blind spot)
  // and the *self-consistent-but-wrong* decoder bug earlier in this same
  // round -- both were invisible to single-transform-type tests. This test
  // forces a genuine mix: left half a 4x4-quadrant checkerboard (favors
  // DCT4x4), right half a smooth gradient (favors DCT8x8/merged DCT16x16).
  // Confirmed via the jxl.encdebug tally at these exact distances:
  //   0.5 -> {DCT 4x4: 32, DCT 16x16: 6, DCT 8x8: 8}  (all three types)
  //   1.0 -> {DCT 4x4: 32, DCT 16x16: 8}
  //   2.0 -> {DCT 4x4: 32, DCT 8x8: 32}
  //   4.0 -> {DCT 4x4: 32, DCT 8x8: 32}
  for (final distance in [0.5, 1.0, 2.0, 4.0]) {
    test(
        'DCT4x4 (Tranche C, opt-in) round-trips correctly in a MIXED layout '
        'alongside plain DCT8x8/DCT16x16 at distance=$distance', () {
      const size = 64;
      final pixels = Uint8List(size * size * 3);
      var i = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          int v;
          if (x < size ~/ 2) {
            final qy = y ~/ 4, qx = x ~/ 4;
            v = (qy + qx).isEven ? 40 : 210;
          } else {
            v = (y * 200 / size).round().clamp(0, 255);
          }
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final encoded = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));

      final image = JxlDecoder.decode(encoded);
      expect(image.width, size);
      expect(image.height, size);

      var sumSq = 0.0;
      var n = 0;
      final decoded = image.toRgba8();
      for (var p = 0; p < size * size; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      expect(math.sqrt(sumSq / n), lessThan(30.0),
          reason: 'decode-vs-original RMSE should stay bounded in a mixed '
              'layout, not just in the all-DCT4x4 case');

      if (!_haveDjxl) return;
      final dir = Directory.systemTemp.createTempSync('koni_lossy_dct4x4_mix');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, size);
        expect(ref.height, size);

        var dSumSq = 0.0;
        var dn = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < size * size; j++) {
            final d = ours[j] - theirs[j];
            dSumSq += d * d;
            dn++;
          }
        }
        final rmse = math.sqrt(dSumSq / dn);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

  // Tranche C, second/third slices: Hornuss and DCT2x2. Both share DCT4x4's
  // verified single-stage butterfly for their own DC combination (Hornuss
  // directly, DCT2x2 only insofar as its 3-stage cascade is built from the
  // same H4 unit) but needed independent forward derivations, each verified
  // by basis injection against the real decoder logic before being trusted
  // (0.0 deviation -- see doc/spec_notes.md and vardct_forward_test.dart's
  // permanent identity tests). `tryMergeLevel` is called for both (plus
  // DCT4x4) in sequence at the bootstrap tier, still gated by the single
  // `enableBespokeTransforms` flag -- no new flag per type, matching
  // [VardctL0Config.enableBespokeTransforms]'s own stated intent.
  //
  // Config found empirically (jxl.encdebug tallies), not guessed: a 32x32
  // canvas with a 4x4-quadrant checkerboard of amplitude 12 (period 4,
  // +-12 around a mid-gray base -- deliberately gentler than DCT4x4's own
  // +-85 checkerboard, which stays a DCT4x4 win at this amplitude) makes
  // some bespoke type win outright over plain 8x8 across the whole
  // standard distance range, though which one wins varies by distance —
  // a real, content-dependent effect, not one type dominating everywhere.
  // Re-confirmed via the encdebug tally after round 18's joint-argmin
  // rewrite of `decideLevel0` (`_decideTransformLayout`'s doc comment):
  // {Hornuss: 16} at distance=0.5, {DCT 4x4: 16} at 1.0/2.0/4.0 — the
  // true per-cell argmin picks DCT4x4 at the three higher distances here,
  // not DCT2x2 as an earlier (order-dependent, pre-round-18) measurement
  // of this same content found; this test only asserts bespoke-beats-
  // plain, not which specific type wins, so the assertion itself didn't
  // need to change.
  for (final distance in [0.5, 1.0, 2.0, 4.0]) {
    test(
        'Hornuss/DCT2x2 (Tranche C, opt-in) genuinely win on a gentle '
        'checkerboard and round-trip correctly at distance=$distance', () {
      const size = 32;
      final pixels = Uint8List(size * size * 3);
      var i = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final v = 128 + ((x ~/ 4 + y ~/ 4).isEven ? 12 : -12);
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final withBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));
      final withoutBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: false));
      expect(withBespoke.length, lessThan(withoutBespoke.length),
          reason: 'Hornuss/DCT2x2 (${withBespoke.length}B) should beat plain '
              '8x8/DCT4x4 (${withoutBespoke.length}B) at this config');

      double decodeVsOriginal(Uint8List encoded) {
        final decoded = JxlDecoder.decode(encoded).toRgba8();
        var sumSq = 0.0;
        var n = 0;
        for (var p = 0; p < size * size; p++) {
          for (var c = 0; c < 3; c++) {
            final d = decoded[p * 4 + c] - pixels[p * 3 + c];
            sumSq += d * d;
            n++;
          }
        }
        return math.sqrt(sumSq / n);
      }

      final bespokeRmse = decodeVsOriginal(withBespoke);
      final plainRmse = decodeVsOriginal(withoutBespoke);
      expect(bespokeRmse, lessThan(plainRmse * 2 + 1),
          reason: 'Hornuss/DCT2x2 RMSE-vs-original ($bespokeRmse) should be in '
              'the same ballpark as plain 8x8/DCT4x4 ($plainRmse), not '
              'blown up by a forward-transform or quant-weight/bitstream-'
              'mode error');

      final image = JxlDecoder.decode(withBespoke);
      expect(image.width, size);
      expect(image.height, size);

      if (!_haveDjxl) return;
      final dir =
          Directory.systemTemp.createTempSync('koni_lossy_hornuss_dct2');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(withBespoke);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, size);
        expect(ref.height, size);

        var sumSq = 0.0;
        var n = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < size * size; j++) {
            final d = ours[j] - theirs[j];
            sumSq += d * d;
            n++;
          }
        }
        final rmse = math.sqrt(sumSq / n);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

  // The checkerboard test above is period-4-aligned, so every 4x4 quadrant
  // it produces is perfectly FLAT -- great for demonstrating a genuine win,
  // but degenerate for exercising Hornuss/DCT2x2's own weight-table
  // positions: every AC coefficient in a flat quadrant is exactly zero, so
  // a `*64`-scaling bug on those positions (the same bug class DCT4x4's own
  // override reads had -- see `_setupDctParam`'s `TransformMode.dct4` case
  // and doc/spec_notes.md) would multiply zero by the wrong constant and
  // still get zero, silently passing. These two tests use genuinely
  // non-flat content instead (a smooth global gradient for Hornuss, random
  // per-pixel noise for DCT2x2 -- chosen so each type's own weight-table
  // positions see real, nonzero coefficients) and confirm via the encdebug
  // tally that the type under test is actually placed (not just that the
  // code path compiles), then round-trip through djxl: this is the actual
  // verification the advisor recommended over trusting the semantic
  // argument for why hornuss/dct2's existing `*64` read convention
  // (`_setupDctParam`) doesn't need dct4's fix. Both passed on the first
  // try -- the `*64` convention is correct as written for these two modes,
  // unlike dct4's genuine bug.
  test(
      'Hornuss weight-table override positions carry real signal and '
      'round-trip through djxl (distance=8.0, encdebug-confirmed pure '
      'Hornuss tally)', () {
    if (!_haveDjxl) return;
    const size = 32;
    final pixels = Uint8List(size * size * 3);
    var i = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = ((x + y) * 255 / (2 * size)).round().clamp(0, 255);
        pixels[i++] = v;
        pixels[i++] = v;
        pixels[i++] = v;
      }
    }
    const distance = 8.0;
    final base = VardctL0Config.fromDistance(distance);
    final encoded = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableBespokeTransforms: true));
    final image = JxlDecoder.decode(encoded);
    expect(image.width, size);
    expect(image.height, size);

    final dir = Directory.systemTemp.createTempSync('koni_lossy_hornuss_64');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(encoded);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
      final ref = PnmImage.parse(File(outPath).readAsBytesSync());
      var sumSq = 0.0;
      var n = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        final theirs = ref.intPlanes![c];
        for (var j = 0; j < size * size; j++) {
          final d = ours[j] - theirs[j];
          sumSq += d * d;
          n++;
        }
      }
      final rmse = math.sqrt(sumSq / n);
      expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test(
      'DCT2x2 weight-table ring positions carry real signal and round-trip '
      'through djxl (distance=4.0, encdebug-confirmed dominant DCT2x2 '
      'tally)', () {
    if (!_haveDjxl) return;
    const size = 32;
    final rng = math.Random(42);
    final pixels = Uint8List(size * size * 3);
    var i = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = (128 + rng.nextInt(11) - 5).clamp(0, 255);
        pixels[i++] = v;
        pixels[i++] = v;
        pixels[i++] = v;
      }
    }
    const distance = 4.0;
    final base = VardctL0Config.fromDistance(distance);
    final encoded = encodeLossyVardctL0(pixels,
        width: size,
        height: size,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableBespokeTransforms: true));
    final image = JxlDecoder.decode(encoded);
    expect(image.width, size);
    expect(image.height, size);

    final dir = Directory.systemTemp.createTempSync('koni_lossy_dct2x2_64');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath = '${dir.path}/t.ppm';
      File(jxlPath).writeAsBytesSync(encoded);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
      final ref = PnmImage.parse(File(outPath).readAsBytesSync());
      var sumSq = 0.0;
      var n = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        final theirs = ref.intPlanes![c];
        for (var j = 0; j < size * size; j++) {
          final d = ours[j] - theirs[j];
          sumSq += d * d;
          n++;
        }
      }
      final rmse = math.sqrt(sumSq / n);
      expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  // Tier-interaction mixed-layout test (the same class of gap DCT4x4's own
  // round found via advisor review, and Tranche B's flip=false gap before
  // that): a single bitstream that genuinely interleaves ALL FIVE transform
  // types now active (DCT8x8, Hornuss, DCT2x2, DCT4x4, DCT16x16), not just
  // one bespoke type at a time. A 64x64 canvas, quartered: top-left the
  // amp=12 checkerboard (favors Hornuss/DCT2x2), top-right flat+noise
  // (favors DCT2x2), bottom-left the original DCT4x4 test's high-amplitude
  // 4x4-quadrant checkerboard (favors DCT4x4), bottom-right a smooth
  // gradient (favors DCT8x8/merged DCT16x16). Confirmed via the encdebug
  // tally at distance=0.5 to place all five types in one bitstream at once
  // (`{Hornuss: 39, DCT 8x8: 6, DCT 4x4: 1, DCT 2x2: 2, DCT 16x16: 4}`);
  // the other three distances still mix a genuine subset (not the uniform
  // single-type tally every isolated-content test above produces).
  for (final distance in [0.5, 1.0, 2.0, 4.0]) {
    test(
        'Hornuss/DCT2x2/DCT4x4 (Tranche C, opt-in) round-trip correctly in '
        'a MIXED layout alongside plain DCT8x8/DCT16x16 at '
        'distance=$distance', () {
      const size = 64;
      final rng = math.Random(42);
      final pixels = Uint8List(size * size * 3);
      var i = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          int v;
          if (y < size ~/ 2 && x < size ~/ 2) {
            v = 128 + ((x ~/ 4 + y ~/ 4).isEven ? 12 : -12);
          } else if (y < size ~/ 2) {
            v = (128 + rng.nextInt(11) - 5).clamp(0, 255);
          } else if (x < size ~/ 2) {
            final qy = y ~/ 4, qx = x ~/ 4;
            v = (qy + qx).isEven ? 40 : 210;
          } else {
            v = (y * 200 / size).round().clamp(0, 255);
          }
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final encoded = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));

      final image = JxlDecoder.decode(encoded);
      expect(image.width, size);
      expect(image.height, size);

      var sumSq = 0.0;
      var n = 0;
      final decoded = image.toRgba8();
      for (var p = 0; p < size * size; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      expect(math.sqrt(sumSq / n), lessThan(30.0),
          reason: 'decode-vs-original RMSE should stay bounded in a mixed '
              'layout, not just in a uniform-tally case');

      if (!_haveDjxl) return;
      final dir = Directory.systemTemp.createTempSync('koni_lossy_bespoke_mix');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, size);
        expect(ref.height, size);

        var dSumSq = 0.0;
        var dn = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < size * size; j++) {
            final d = ours[j] - theirs[j];
            dSumSq += d * d;
            dn++;
          }
        }
        final rmse = math.sqrt(dSumSq / dn);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

  // Tranche C, fourth/fifth slices: DCT4x8 and DCT8x4 -- unlike
  // Hornuss/DCT2x2 (no real DCT machinery at all), these share DCT4x4's
  // "butterfly + sub-block IDCT" shape: a plain 2-point Hadamard combines
  // the block's 2 strips' own DC terms, each strip reconstructed via a
  // genuine (height=4,width=8) forward/inverse DCT pair (DCT8x4's strips
  // additionally use the same `transposed=true` handling DCT4x4's
  // per-quadrant case already established).
  //
  // Config found empirically (jxl.encdebug tallies): unlike DCT4x4 (which
  // wins on sharp period-4 checkerboards) or Hornuss/DCT2x2 (which win on
  // smooth/noisy content), DCT4x8/DCT8x4 need content where the block's 2
  // strips have both a genuine DC difference (a "step" between top/bottom,
  // or left/right) AND smooth AC structure within each strip (a gradient) --
  // a pure sine content was tried first and found DEGENERATE for this
  // purpose (a full-period sine sums to exactly zero, so both strips get
  // the identical DC and the override-affected coefficient below is
  // trivially zero regardless of any encoding bug -- the same "flat
  // checkerboard hides a *64 bug" trap Hornuss's own test avoided). The
  // step+gradient content below avoids that: a real per-strip DC
  // difference (`step`) plus a real per-strip gradient (`slope`), which
  // wins outright at distance=0.5 and 1.0 (encdebug-confirmed uniform
  // {DCT 4x8: 16} / {DCT 8x4: 16} tallies at both) — this SAME content
  // also verifies the override weight position (`getDct4x8QuantWeights`'s
  // `target[1][0]`, exactly the strips' DC-difference coefficient) isn't
  // just multiplied by zero, unlike the degenerate sine content would.
  for (final distance in [0.5, 1.0]) {
    test(
        'DCT4x8 (Tranche C, opt-in) genuinely wins on a step+gradient '
        'pattern and round-trips correctly at distance=$distance', () {
      const size = 32;
      final pixels = Uint8List(size * size * 3);
      var i = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final base = (y % 8) < 4 ? 170 : 130;
          final v = (base + 6 * (x % 8) - 24).clamp(0, 255);
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final withBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));
      final withoutBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: false));
      expect(withBespoke.length, lessThan(withoutBespoke.length),
          reason: 'DCT4x8 (${withBespoke.length}B) should beat plain '
              '8x8/other bespoke types (${withoutBespoke.length}B) at this '
              'config');

      double decodeVsOriginal(Uint8List encoded) {
        final decoded = JxlDecoder.decode(encoded).toRgba8();
        var sumSq = 0.0;
        var n = 0;
        for (var p = 0; p < size * size; p++) {
          for (var c = 0; c < 3; c++) {
            final d = decoded[p * 4 + c] - pixels[p * 3 + c];
            sumSq += d * d;
            n++;
          }
        }
        return math.sqrt(sumSq / n);
      }

      final bespokeRmse = decodeVsOriginal(withBespoke);
      final plainRmse = decodeVsOriginal(withoutBespoke);
      expect(bespokeRmse, lessThan(plainRmse * 2 + 1),
          reason: 'DCT4x8 RMSE-vs-original ($bespokeRmse) should be in the '
              'same ballpark as the alternative ($plainRmse), not blown up '
              'by a forward-transform or quant-weight/bitstream-mode error');

      final image = JxlDecoder.decode(withBespoke);
      expect(image.width, size);
      expect(image.height, size);

      if (!_haveDjxl) return;
      final dir = Directory.systemTemp.createTempSync('koni_lossy_dct4x8');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(withBespoke);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, size);
        expect(ref.height, size);

        var sumSq = 0.0;
        var n = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < size * size; j++) {
            final d = ours[j] - theirs[j];
            sumSq += d * d;
            n++;
          }
        }
        final rmse = math.sqrt(sumSq / n);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test(
        'DCT8x4 (Tranche C, opt-in) genuinely wins on a step+gradient '
        'pattern and round-trips correctly at distance=$distance', () {
      const size = 32;
      final pixels = Uint8List(size * size * 3);
      var i = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final base = (x % 8) < 4 ? 170 : 130;
          final v = (base + 6 * (y % 8) - 24).clamp(0, 255);
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final withBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));
      final withoutBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: false));
      expect(withBespoke.length, lessThan(withoutBespoke.length),
          reason: 'DCT8x4 (${withBespoke.length}B) should beat plain '
              '8x8/other bespoke types (${withoutBespoke.length}B) at this '
              'config');

      double decodeVsOriginal(Uint8List encoded) {
        final decoded = JxlDecoder.decode(encoded).toRgba8();
        var sumSq = 0.0;
        var n = 0;
        for (var p = 0; p < size * size; p++) {
          for (var c = 0; c < 3; c++) {
            final d = decoded[p * 4 + c] - pixels[p * 3 + c];
            sumSq += d * d;
            n++;
          }
        }
        return math.sqrt(sumSq / n);
      }

      final bespokeRmse = decodeVsOriginal(withBespoke);
      final plainRmse = decodeVsOriginal(withoutBespoke);
      expect(bespokeRmse, lessThan(plainRmse * 2 + 1),
          reason: 'DCT8x4 RMSE-vs-original ($bespokeRmse) should be in the '
              'same ballpark as the alternative ($plainRmse), not blown up '
              'by a forward-transform or quant-weight/bitstream-mode error');

      final image = JxlDecoder.decode(withBespoke);
      expect(image.width, size);
      expect(image.height, size);

      if (!_haveDjxl) return;
      final dir = Directory.systemTemp.createTempSync('koni_lossy_dct8x4');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(withBespoke);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, size);
        expect(ref.height, size);

        var sumSq = 0.0;
        var n = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < size * size; j++) {
            final d = ours[j] - theirs[j];
            sumSq += d * d;
            n++;
          }
        }
        final rmse = math.sqrt(sumSq / n);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

  // Tier-interaction mixed-layout test covering ALL SEVEN active transform
  // types at once (DCT8x8, Hornuss, DCT2x2, DCT4x4, DCT4x8, DCT8x4,
  // DCT16x16) -- the same class of gap DCT4x4's own round found via advisor
  // review, and Tranche B's flip=false gap before that. A 96x64 canvas, six
  // 32x32 regions: the amp=12 checkerboard (Hornuss/DCT2x2), flat+noise
  // (DCT2x2), the high-amplitude 4x4-quadrant checkerboard (DCT4x4), a
  // horizontal-split step+gradient (DCT4x8), a vertical-split step+gradient
  // (DCT8x4), and a smooth gradient (DCT8x8/merged DCT16x16). Confirmed via
  // the encdebug tally at distance=0.5 to place all seven types in one
  // bitstream at once (`{Hornuss: 38, DCT 8x8: 5, DCT 4x8: 17, DCT 4x4: 1,
  // DCT 8x4: 18, DCT 2x2: 1, DCT 16x16: 4}`); the other three distances
  // still mix a genuine (if smaller) subset.
  for (final distance in [0.5, 1.0, 2.0, 4.0]) {
    test(
        'all five bespoke types (Tranche C, opt-in) round-trip correctly '
        'in a MIXED layout alongside plain DCT8x8/DCT16x16 at '
        'distance=$distance', () {
      const width = 96, height = 64;
      final rng = math.Random(42);
      final pixels = Uint8List(width * height * 3);
      var i = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final col = x ~/ 32, row = y ~/ 32;
          int v;
          if (row == 0 && col == 0) {
            v = 128 + ((x ~/ 4 + y ~/ 4).isEven ? 12 : -12);
          } else if (row == 0 && col == 1) {
            v = (128 + rng.nextInt(11) - 5).clamp(0, 255);
          } else if (row == 0 && col == 2) {
            final qy = y ~/ 4, qx = x ~/ 4;
            v = (qy + qx).isEven ? 40 : 210;
          } else if (row == 1 && col == 0) {
            final rowBase = (y % 8) < 4 ? 170 : 130;
            v = (rowBase + 6 * (x % 8) - 24).clamp(0, 255);
          } else if (row == 1 && col == 1) {
            final colBase = (x % 8) < 4 ? 170 : 130;
            v = (colBase + 6 * (y % 8) - 24).clamp(0, 255);
          } else {
            v = (y * 200 / height).round().clamp(0, 255);
          }
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final encoded = encodeLossyVardctL0(pixels,
          width: width,
          height: height,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));

      final image = JxlDecoder.decode(encoded);
      expect(image.width, width);
      expect(image.height, height);

      var sumSq = 0.0;
      var n = 0;
      final decoded = image.toRgba8();
      for (var p = 0; p < width * height; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      expect(math.sqrt(sumSq / n), lessThan(30.0),
          reason: 'decode-vs-original RMSE should stay bounded in a mixed '
              'layout, not just in a uniform-tally case');

      if (!_haveDjxl) return;
      final dir = Directory.systemTemp.createTempSync('koni_lossy_all_mix');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, width);
        expect(ref.height, height);

        var dSumSq = 0.0;
        var dn = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < width * height; j++) {
            final d = ours[j] - theirs[j];
            dSumSq += d * d;
            dn++;
          }
        }
        final rmse = math.sqrt(dSumSq / dn);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

  // Tranche C, final slice: AFV0-3 -- the most complex bespoke type, and
  // the last one, completing Tranche C (all 27 transform types now exist).
  // Unlike every other bespoke type, AFV splits the 8x8 block into 3
  // DISJOINT regions (a 4x4 "AFV-basis" region using a fixed custom 16x16
  // matrix, not a DCT at all; a 4x4 transposed-DCT region; a 4x8 plain-DCT
  // region), with a 3x3 (not 4-point/2-point) linear system combining
  // their own DC-like terms. The decoder's own "SPEC: watch signs here"
  // comment (vardct_inverter.dart's _invertAFV) flags region 2's DC
  // combination (`c00+c10-c01`) specifically -- these tests exercise that
  // exact code path against djxl, not just against our own decoder (which
  // would agree even if that sign combination were wrong, the same
  // "self-consistent but wrong" signature DCT4x4's round already hit once).
  //
  // Config found empirically (jxl.encdebug tallies): a "flat corner plus a
  // gradient" pattern, one config per AFV variant, each placing its own
  // flat corner at a different position (found by trying all 4 corners,
  // not assumed by symmetry -- AFV1/2/3's actual winning corner didn't
  // match the naive flipY/flipX-implies-which-corner-wins guess, so this
  // was verified empirically per type, not derived). Each wins purely
  // (16/16 tally) at its own single distance.
  for (final (name, distance, cornerTest) in [
    ('AFV0', 1.0, (int lx, int ly) => lx < 4 && ly < 4),
    ('AFV1', 0.5, (int lx, int ly) => lx >= 4 && ly < 4),
    ('AFV2', 1.0, (int lx, int ly) => lx >= 4 && ly >= 4),
    ('AFV3', 1.0, (int lx, int ly) => lx < 4 && ly >= 4),
  ]) {
    test(
        '$name (Tranche C, opt-in) genuinely wins on a flat-corner+gradient '
        'pattern and round-trips correctly at distance=$distance', () {
      const size = 32;
      final pixels = Uint8List(size * size * 3);
      var i = 0;
      final gradSlope = name == 'AFV1' ? 10 : 5;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final lx = x % 8, ly = y % 8;
          final v = cornerTest(lx, ly)
              ? 200
              : (128 + (lx - ly) * gradSlope).clamp(0, 255);
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final withBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));
      final withoutBespoke = encodeLossyVardctL0(pixels,
          width: size,
          height: size,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: false));
      expect(withBespoke.length, lessThan(withoutBespoke.length),
          reason: '$name (${withBespoke.length}B) should beat plain '
              '8x8/other bespoke types (${withoutBespoke.length}B) at this '
              'config');

      double decodeVsOriginal(Uint8List encoded) {
        final decoded = JxlDecoder.decode(encoded).toRgba8();
        var sumSq = 0.0;
        var n = 0;
        for (var p = 0; p < size * size; p++) {
          for (var c = 0; c < 3; c++) {
            final d = decoded[p * 4 + c] - pixels[p * 3 + c];
            sumSq += d * d;
            n++;
          }
        }
        return math.sqrt(sumSq / n);
      }

      final bespokeRmse = decodeVsOriginal(withBespoke);
      final plainRmse = decodeVsOriginal(withoutBespoke);
      expect(bespokeRmse, lessThan(plainRmse * 2 + 1),
          reason: '$name RMSE-vs-original ($bespokeRmse) should be in the '
              'same ballpark as the alternative ($plainRmse), not blown up '
              'by a forward-transform or quant-weight/bitstream-mode error');

      final image = JxlDecoder.decode(withBespoke);
      expect(image.width, size);
      expect(image.height, size);

      if (!_haveDjxl) return;
      final dir = Directory.systemTemp.createTempSync('koni_lossy_afv');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(withBespoke);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, size);
        expect(ref.height, size);

        var sumSq = 0.0;
        var n = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < size * size; j++) {
            final d = ours[j] - theirs[j];
            sumSq += d * d;
            n++;
          }
        }
        final rmse = math.sqrt(sumSq / n);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

  // Tier-interaction mixed-layout test covering ALL NINE bespoke types plus
  // plain DCT8x8/DCT16x16 -- completes the same class of check every prior
  // slice in this tranche has run. A 128x64 canvas, eight 32x32 regions:
  // the six from round 13's own mixed test (amp=12 checkerboard, flat+
  // noise, high-amplitude checkerboard, and both step+gradient
  // orientations) plus AFV0-flavored and AFV1-flavored flat-corner content.
  // Confirmed via the encdebug tally at distance=0.5 to place ALL bespoke
  // types except DCT4x4 in one bitstream at once (`{Hornuss: 52, DCT 8x8:
  // 5, AFV0: 1, DCT 4x8: 16, AFV3: 2, AFV1: 17, DCT 8x4: 17, DCT 2x2: 1,
  // AFV2: 1, DCT 16x16: 4}`) -- DCT4x4 shows up in the other 3 distances
  // instead, so the tranche's full 9-bespoke-type roster is covered across
  // the 4 distances even though no single distance places all 9 at once.
  for (final distance in [0.5, 1.0, 2.0, 4.0]) {
    test(
        'all nine bespoke types (Tranche C, opt-in, now complete) '
        'round-trip correctly in a MIXED layout alongside plain '
        'DCT8x8/DCT16x16 at distance=$distance', () {
      const width = 128, height = 64;
      final rng = math.Random(42);
      final pixels = Uint8List(width * height * 3);
      var i = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final col = x ~/ 32, row = y ~/ 32;
          int v;
          if (row == 0 && col == 0) {
            v = 128 + ((x ~/ 4 + y ~/ 4).isEven ? 12 : -12);
          } else if (row == 0 && col == 1) {
            v = (128 + rng.nextInt(11) - 5).clamp(0, 255);
          } else if (row == 0 && col == 2) {
            final qy = y ~/ 4, qx = x ~/ 4;
            v = (qy + qx).isEven ? 40 : 210;
          } else if (row == 0 && col == 3) {
            final rowBase = (y % 8) < 4 ? 170 : 130;
            v = (rowBase + 6 * (x % 8) - 24).clamp(0, 255);
          } else if (row == 1 && col == 0) {
            final colBase = (x % 8) < 4 ? 170 : 130;
            v = (colBase + 6 * (y % 8) - 24).clamp(0, 255);
          } else if (row == 1 && col == 1) {
            final lx = x % 8, ly = y % 8;
            v = (lx < 4 && ly < 4) ? 200 : (128 + (lx - ly) * 5);
          } else if (row == 1 && col == 2) {
            final lx = x % 8, ly = y % 8;
            v = (lx >= 4 && ly < 4) ? 200 : (128 + (lx - ly) * 10);
          } else {
            v = (y * 200 / height).round().clamp(0, 255);
          }
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final encoded = encodeLossyVardctL0(pixels,
          width: width,
          height: height,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true));

      final image = JxlDecoder.decode(encoded);
      expect(image.width, width);
      expect(image.height, height);

      var sumSq = 0.0;
      var n = 0;
      final decoded = image.toRgba8();
      for (var p = 0; p < width * height; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      expect(math.sqrt(sumSq / n), lessThan(30.0),
          reason: 'decode-vs-original RMSE should stay bounded in a mixed '
              'layout, not just in a uniform-tally case');

      if (!_haveDjxl) return;
      final dir = Directory.systemTemp.createTempSync('koni_lossy_afv_mix');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, width);
        expect(ref.height, height);

        var dSumSq = 0.0;
        var dn = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < width * height; j++) {
            final d = ours[j] - theirs[j];
            dSumSq += d * d;
            dn++;
          }
        }
        final rmse = math.sqrt(dSumSq / dn);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

  // Round 18: `decideLevel0` replaced the old sequential bespoke pre-pass
  // (9 separate whole-image `tryMergeLevel` passes, each only comparing
  // against whatever the *previous* type's pass had already committed
  // nearby) with a true per-cell N-way argmin — see
  // `_decideTransformLayout`'s doc comment and doc/spec_notes.md's round
  // 18 entry. The defect the old design had: a cell's *rate* estimate
  // depends on its west/north neighbors' live-grid fill, which each
  // separate whole-image pass mutated as it went — so the same type at
  // the same cell could score differently purely because of list order,
  // not because of anything about the cell itself.
  //
  // This test places two ADJACENT cells, each engineered to favor a
  // *different* bespoke type — AFV0 (near the start of `decideLevel0`'s
  // internal type list) and AFV2 (near the end), reusing the exact
  // winning patterns the standalone AFV0/AFV2 tests above already
  // established — then checks the SAME total byte count results whether
  // AFV0 is on the west side and AFV2 on the east, or vice versa (an
  // exact-symmetry check, not just "both eventually get picked somehow":
  // confirmed empirically via the encdebug tally, `{AFV0: 1, AFV2: 1}`
  // either way, 92B both times). Under the old order-dependent design
  // this exact equality wasn't guaranteed (whichever type happened to be
  // tried first for a cell could commit before the true best type got a
  // fair, unbiased comparison); under the true joint argmin it holds by
  // construction, since each cell is scored once, against the same kind
  // of snapshot regardless of which side it's on.
  test(
      'decideLevel0 picks the true per-cell best regardless of which '
      'position favors which bespoke type (order/position invariance)', () {
    const width = 16, height = 8;
    Uint8List build({required bool afv0Left}) {
      final pixels = Uint8List(width * height * 3);
      var i = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final lx = x % 8, ly = y % 8;
          final isAfv0Cell = x < 8;
          final wantAfv0Corner = isAfv0Cell == afv0Left;
          final corner = wantAfv0Corner
              ? (lx < 4 && ly < 4) // AFV0's winning corner
              : (lx >= 4 && ly >= 4); // AFV2's winning corner
          final v = (corner ? 200 : (128 + (lx - ly) * 5)).clamp(0, 255);
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      return pixels;
    }

    final normal = build(afv0Left: true); // AFV0 west, AFV2 east
    final mirrored = build(afv0Left: false); // AFV2 west, AFV0 east
    final base = VardctL0Config.fromDistance(1.0);
    final config = VardctL0Config(
        quantLF: base.quantLF,
        acScale: base.acScale,
        enableVariableTransforms: true,
        enableBespokeTransforms: true);
    final encNormal = encodeLossyVardctL0(normal,
        width: width, height: height, config: config);
    final encMirrored = encodeLossyVardctL0(mirrored,
        width: width, height: height, config: config);
    expect(encNormal.length, encMirrored.length,
        reason: 'AFV0/AFV2 (${encNormal.length}B west/east) vs. AFV2/AFV0 '
            '(${encMirrored.length}B west/east) should encode to the exact '
            'same size — each cell\'s own best type shouldn\'t depend on '
            'which side of the image it happens to sit on');

    final withoutBespoke = encodeLossyVardctL0(normal,
        width: width,
        height: height,
        config: VardctL0Config(
            quantLF: base.quantLF,
            acScale: base.acScale,
            enableVariableTransforms: true,
            enableBespokeTransforms: false));
    expect(encNormal.length, lessThan(withoutBespoke.length),
        reason: 'both cells choosing their own genuine best bespoke type '
            '(${encNormal.length}B) should beat plain 8x8 '
            '(${withoutBespoke.length}B)');

    if (!_haveDjxl) return;
    for (final encoded in [encNormal, encMirrored]) {
      final dir = Directory.systemTemp.createTempSync('koni_lossy_l0_argmin');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        final image = JxlDecoder.decode(encoded);
        var sumSq = 0.0;
        var n = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < width * height; j++) {
            final d = ours[j] - theirs[j];
            sumSq += d * d;
            n++;
          }
        }
        expect(math.sqrt(sumSq / n), lessThan(2.0));
      } finally {
        dir.deleteSync(recursive: true);
      }
    }
  });

  // Round 18: the exact knob combination round 17's real per-page
  // regression involved (`enableBespokeTransforms` alone regressed one
  // real manga page by +4-5%; combining it with `enableRectangularTransforms`
  // masked that specific case under the *old* design) was previously
  // untested outside the standalone `tool/bench_manga_roi.dart` harness —
  // extends the existing "all nine bespoke types" mixed-layout content
  // (round 14) with `enableRectangularTransforms: true` alongside
  // `enableBespokeTransforms: true`, so both Level 0 (bespoke) and Level 1
  // (16x8/8x16 pairs, whole 16x16) get real, simultaneous exercise across
  // a mixed real layout, not just each flag in isolation.
  for (final distance in [0.5, 1.0, 2.0, 4.0]) {
    test(
        'bespoke + rectangular transforms combined round-trip correctly '
        'in the same mixed layout at distance=$distance', () {
      const width = 128, height = 64;
      final rng = math.Random(42);
      final pixels = Uint8List(width * height * 3);
      var i = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final col = x ~/ 32, row = y ~/ 32;
          int v;
          if (row == 0 && col == 0) {
            v = 128 + ((x ~/ 4 + y ~/ 4).isEven ? 12 : -12);
          } else if (row == 0 && col == 1) {
            v = (128 + rng.nextInt(11) - 5).clamp(0, 255);
          } else if (row == 0 && col == 2) {
            final qy = y ~/ 4, qx = x ~/ 4;
            v = (qy + qx).isEven ? 40 : 210;
          } else if (row == 0 && col == 3) {
            final rowBase = (y % 8) < 4 ? 170 : 130;
            v = (rowBase + 6 * (x % 8) - 24).clamp(0, 255);
          } else if (row == 1 && col == 0) {
            final colBase = (x % 8) < 4 ? 170 : 130;
            v = (colBase + 6 * (y % 8) - 24).clamp(0, 255);
          } else if (row == 1 && col == 1) {
            final lx = x % 8, ly = y % 8;
            v = (lx < 4 && ly < 4) ? 200 : (128 + (lx - ly) * 5);
          } else if (row == 1 && col == 2) {
            final lx = x % 8, ly = y % 8;
            v = (lx >= 4 && ly < 4) ? 200 : (128 + (lx - ly) * 10);
          } else {
            v = (y * 200 / height).round().clamp(0, 255);
          }
          pixels[i++] = v;
          pixels[i++] = v;
          pixels[i++] = v;
        }
      }
      final base = VardctL0Config.fromDistance(distance);
      final encoded = encodeLossyVardctL0(pixels,
          width: width,
          height: height,
          config: VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: true,
              enableBespokeTransforms: true,
              enableRectangularTransforms: true));

      final image = JxlDecoder.decode(encoded);
      expect(image.width, width);
      expect(image.height, height);

      var sumSq = 0.0;
      var n = 0;
      final decoded = image.toRgba8();
      for (var p = 0; p < width * height; p++) {
        for (var c = 0; c < 3; c++) {
          final d = decoded[p * 4 + c] - pixels[p * 3 + c];
          sumSq += d * d;
          n++;
        }
      }
      expect(math.sqrt(sumSq / n), lessThan(30.0),
          reason: 'decode-vs-original RMSE should stay bounded with both '
              'flags on together, not just each in isolation');

      if (!_haveDjxl) return;
      final dir =
          Directory.systemTemp.createTempSync('koni_lossy_rect_bespoke_mix');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.ppm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        expect(ref.width, width);
        expect(ref.height, height);

        var dSumSq = 0.0;
        var dn = 0;
        for (var c = 0; c < 3; c++) {
          final ours = channelAsInts(image.channels[c], 255);
          final theirs = ref.intPlanes![c];
          for (var j = 0; j < width * height; j++) {
            final d = ours[j] - theirs[j];
            dSumSq += d * d;
            dn++;
          }
        }
        final rmse = math.sqrt(dSumSq / dn);
        expect(rmse, lessThan(2.0), reason: 'rmse $rmse');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  }

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
