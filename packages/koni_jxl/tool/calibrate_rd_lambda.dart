import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';

/// Calibrates `_kRdLambda` (the RD-hfMult search's rate/distortion
/// trade-off constant, `VardctL0Config.enableRdHfMult`) by sweeping it
/// against real corpus content and the encoder's own synthetic
/// regression-test patterns, across the encoder's **full distance range**
/// (0.5-8.0), not a single point. Runs with
/// `enableVariableTransforms: false` throughout — see "a confound found
/// and corrected" below for why that matters.
///
/// This is the multi-distance check ROADMAP.md asks for before ever
/// revisiting hfMult's RD search: `_kRdLambda` shares `_kRdoqLambda`'s old,
/// buggy `refStep^2` scaling convention (the one that shipped a severe
/// distance-dependent regression for RDOQ — see `_kRdoqLambda`'s doc
/// comment) and was, before this tool, only ever calibrated at
/// `distance=1.0`.
///
/// **A confound found and corrected.** The first version of this sweep ran
/// with `enableVariableTransforms: true` (the encoder's actual default)
/// and found gradient RMSE identical across *every* `kLambda` from 500 to
/// 20000 at `distance=8.0` — which looked like hfMult's search saturating
/// regardless of lambda. It wasn't: `jxl.encdebug`'s histogram showed the
/// *committed* 16x16 layout at that distance has essentially zero AC left
/// (`bestBytes=2`), so every hfMult candidate scores near-identically and
/// the tiebreak trivially picks the same one — an artifact of
/// variable-transform layout selection on coarse gradients, not of the
/// hfMult search itself. Isolating with `enableVariableTransforms: false`
/// (below) gives a real, non-degenerate signal.
///
/// **Isolated finding: `refStep^2` scaling does have a real, RDOQ-like
/// distance-dependent regression — and `acScale^2` measurably helps.**
/// With `enableVariableTransforms: false`, at this file's own shipped
/// constant (`kLambda=3000`, `_kRdLambda`), gradient RMSE tracks the
/// heuristic closely at `distance=1.0` (0.935 vs. 0.938) but degrades as
/// distance grows: 1.119 at `distance=2.0` (heuristic: 0.992), 1.666 at
/// `distance=4.0` (heuristic: 1.043), 2.246 at `distance=8.0` (heuristic:
/// 1.513) — a real, monotonically-worsening regression, confirming
/// ROADMAP's suspicion. A one-off patch to `_chooseHfMultRd` swapping
/// `kLambda * refStep * refStep` for `kLambda * acScale * acScale` (not
/// shipped here — see doc/spec_notes.md for exact numbers and how to
/// reproduce) found the `distance=1.0`-equivalent `kLambda` (≈0.01 in
/// `acScale^2` units — confirmed equivalent: both give 0.935 at
/// `distance=1.0`) gives **1.007 at `distance=2.0`, 1.045 at
/// `distance=4.0`, 1.513 at `distance=8.0`** — the `distance>=4` cases
/// land within noise of the heuristic baseline instead of +60%/+48% over
/// it. `acScale^2` is a genuinely better-matched scaling for this search,
/// not a dead end — contrary to this file's own first (wrong,
/// pre-isolation) conclusion.
///
/// **What this doesn't fix**: `distance=2.0`'s 1.007 is still right at the
/// gate, and the original photo-vs-gradient trade-off `_kRdLambda`'s doc
/// comment documents at `distance=1.0` — no single constant both beats the
/// heuristic on photo content and stays clearly safe on gradients — is
/// unaffected by the scaling formula; `acScale^2` mainly stops the
/// problem from *compounding* at high distance, it doesn't resolve the
/// low-distance tension. `enableRdHfMult` stays off by default. Any
/// future attempt should start from `acScale^2` scaling (not `refStep^2`)
/// plus the still-needed banding-aware distortion term, and must be
/// verified across the full distance range from the start.
///
/// Usage: `dart run tool/calibrate_rd_lambda.dart`
void main() {
  const corpusPath = '../../third_party/corpus/golden/color_cover_d0_e7.ppm';
  final corpusFile = File(corpusPath);
  if (!corpusFile.existsSync()) {
    stderr.writeln('corpus not found at $corpusPath -- run tool/gen_corpus.py');
    exit(1);
  }
  final (cw, ch, corpusPixels) = _readPpm(corpusFile.readAsBytesSync());

  final distances = <double>[0.5, 1.0, 2.0, 4.0, 8.0];
  final candidates = <double>[500, 1000, 2000, 3000, 5000, 8000, 12000, 20000];
  final gradient = _gradientPattern(256, 256);
  final screentone = _screentonePattern(256, 256);
  final lineArt = _lineArtPattern(256, 256);

  for (final distance in distances) {
    print('\n${'=' * 70}');
    print('distance = $distance (enableVariableTransforms: false — see '
        'module doc for why this sweep isolates hfMult that way)');
    print('=' * 70);

    final base = _isolatedBase(distance);
    final corpusBase = _encodeAndMeasure(corpusPixels, cw, ch, base);
    print('color_cover  heuristic: ${corpusBase.bytes} bytes, '
        'rmse=${corpusBase.rmse.toStringAsFixed(3)}');
    final gradBase = _encodeAndMeasure(gradient, 256, 256, base);
    print('gradient     heuristic: ${gradBase.bytes} bytes, '
        'rmse=${gradBase.rmse.toStringAsFixed(3)}');

    print('\nkLambda      color_cover(B/rmse, %-vs-heuristic)      '
        'gradient(B/rmse)   gate');
    for (final kLambda in candidates) {
      final cfg = base.withRd(enableRdHfMult: true, lambda: kLambda);
      final r = _encodeAndMeasure(corpusPixels, cw, ch, cfg);
      final g = _encodeAndMeasure(gradient, 256, 256, cfg);
      final bytesDelta = (r.bytes - corpusBase.bytes) / corpusBase.bytes * 100;
      final rmseDelta = (r.rmse - corpusBase.rmse) / corpusBase.rmse * 100;
      final gate = g.rmse < 0.8
          ? 'OK'
          : g.rmse < 1.0
              ? 'MARGIN'
              : 'FAIL';
      print('${kLambda.toStringAsFixed(0).padLeft(8)}  '
          '${r.bytes.toString().padLeft(7)} (${bytesDelta.toStringAsFixed(1).padLeft(6)}% / '
          '${rmseDelta.toStringAsFixed(1).padLeft(6)}%)   '
          '${g.bytes.toString().padLeft(6)}B/${g.rmse.toStringAsFixed(3).padLeft(6)}   $gate');
    }

    print('\nManga-content sanity (screentone, line art):');
    for (final kLambda in candidates) {
      final cfg = base.withRd(enableRdHfMult: true, lambda: kLambda);
      final rs = _encodeAndMeasure(screentone, 256, 256, cfg);
      final rl = _encodeAndMeasure(lineArt, 256, 256, cfg);
      print('kLambda=${kLambda.toStringAsFixed(0).padLeft(8)}: '
          'screentone ${rs.bytes}B/${rs.rmse.toStringAsFixed(2)}  '
          'lineArt ${rl.bytes}B/${rl.rmse.toStringAsFixed(2)}');
    }
  }
}

/// [VardctL0Config.fromDistance] with `enableVariableTransforms: false` —
/// isolates hfMult from the transform-layout decision (see module doc's
/// "confound found and corrected").
VardctL0Config _isolatedBase(double distance) {
  final base = VardctL0Config.fromDistance(distance);
  return VardctL0Config(
      globalScale: base.globalScale,
      quantLF: base.quantLF,
      xqmScale: base.xqmScale,
      bqmScale: base.bqmScale,
      acScale: base.acScale,
      enableVariableTransforms: false);
}

extension on VardctL0Config {
  VardctL0Config withRd(
          {required bool enableRdHfMult, required double lambda}) =>
      VardctL0Config(
          globalScale: globalScale,
          quantLF: quantLF,
          xqmScale: xqmScale,
          bqmScale: bqmScale,
          acScale: acScale,
          enableFilters: enableFilters,
          enableVariableTransforms: enableVariableTransforms,
          enableRdHfMult: enableRdHfMult,
          rdHfMultLambdaOverride: lambda);
}

class _Measurement {
  _Measurement(this.bytes, this.rmse);
  final int bytes;
  final double rmse;
}

_Measurement _encodeAndMeasure(
    Uint8List pixels, int width, int height, VardctL0Config config) {
  final encoded =
      encodeLossyVardctL0(pixels, width: width, height: height, config: config);
  final rmse = _decodeAndRmse(encoded, pixels, width, height);
  return _Measurement(encoded.length, rmse);
}

double _decodeAndRmse(
    Uint8List encoded, Uint8List original, int width, int height) {
  final dir = Directory.systemTemp.createTempSync('calib_djxl');
  try {
    final jxlPath = '${dir.path}/t.jxl';
    final outPath = '${dir.path}/t.ppm';
    File(jxlPath).writeAsBytesSync(encoded);
    final r = Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
    if (r.exitCode != 0) return double.nan;
    final (_, _, decoded) = _readPpm(File(outPath).readAsBytesSync());
    var sumSq = 0.0;
    for (var i = 0; i < original.length; i++) {
      final d = decoded[i] - original[i];
      sumSq += d * d;
    }
    return math.sqrt(sumSq / original.length);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Mirrors vardct_l0_test.dart's "adaptive quantization reduces banding on
/// smooth gradients" test image.
Uint8List _gradientPattern(int w, int h) {
  final out = Uint8List(w * h * 3);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = (x * 255 / w).round().clamp(0, 255);
      out[i++] = v;
      out[i++] = (v * 0.8).round();
      out[i++] = 255 - v;
    }
  }
  return out;
}

/// Mirrors vardct_l0_test.dart's screentone regression pattern.
Uint8List _screentonePattern(int w, int h) {
  final out = Uint8List(w * h * 3);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dotX = x % 6, dotY = y % 6;
      final dist = math.sqrt(math.pow(dotX - 2.5, 2) + math.pow(dotY - 2.5, 2));
      final v = dist < 2.0 ? 30 : 220;
      out[i++] = v;
      out[i++] = v;
      out[i++] = v;
    }
  }
  return out;
}

/// Mirrors vardct_l0_test.dart's line-art regression pattern.
Uint8List _lineArtPattern(int w, int h) {
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

/// Minimal binary PPM (P6) reader — mirrors tool/bench_lossy_vs_cjxl.dart's.
(int, int, Uint8List) _readPpm(Uint8List data) {
  var i = 0;
  String token() {
    while (data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D) {
      i++;
    }
    final start = i;
    while (data[i] != 0x20 && data[i] != 0x0A && data[i] != 0x0D) {
      i++;
    }
    return String.fromCharCodes(data, start, i);
  }

  final magic = token();
  if (magic != 'P6') throw FormatException('expected P6 PPM, got $magic');
  final width = int.parse(token());
  final height = int.parse(token());
  final maxValue = int.parse(token());
  if (maxValue != 255) throw FormatException('expected 8-bit PPM');
  i++;
  return (width, height, Uint8List.sublistView(data, i));
}
