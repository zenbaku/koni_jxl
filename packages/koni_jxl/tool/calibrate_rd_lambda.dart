import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';

/// Calibrates `_kRdLambda` (the RD-hfMult search's rate/distortion
/// trade-off constant, `VardctL0Config.enableRdHfMult`) by sweeping it
/// against real corpus content and the encoder's own synthetic
/// regression-test patterns (copied in, not imported from test code — see
/// `test/encode/vardct_l0_test.dart` for the canonical versions).
///
/// Bar to clear (doc/spec_notes.md's "investigated but not changed"
/// section and this session's compression-efficiency work):
///  (a) beat or Pareto-improve on the already-measured "hfMult forced to
///      1" data point on `color_cover` at distance 1.0 (114580 bytes,
///      RMSE 2.10) — and beat the *current* (default heuristic) result
///      too, since that's what RD search is meant to replace;
///  (b) keep the gradient-banding regression test's RMSE comfortably
///      under 1.0 (target < 0.7-0.8, not another 0.940-style near-miss).
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

  print('=== Reference points (uncalibrated / heuristic) ===');
  final heuristic =
      _encodeAndMeasure(corpusPixels, cw, ch, VardctL0Config.fromDistance(1.0));
  print('color_cover d=1.0, current heuristic: '
      '${heuristic.bytes} bytes, rmse=${heuristic.rmse.toStringAsFixed(3)}');
  final forcedMult1 = _encodeAndMeasure(
      corpusPixels,
      cw,
      ch,
      VardctL0Config(
          enableRdHfMult: true,
          rdHfMultLambdaOverride:
              1e12)); // effectively forces mult=1 everywhere
  print('color_cover d=1.0, RD w/ huge lambda (~= hfMult forced to 1): '
      '${forcedMult1.bytes} bytes, rmse=${forcedMult1.rmse.toStringAsFixed(3)}'
      ' (expect close to the known 114580B/RMSE 2.10 data point)');

  print('\n=== kLambda sweep on color_cover (distance=1.0) ===');
  print('kLambda      bytes   rmse    vs-heuristic-bytes  vs-heuristic-rmse');
  final candidates = <double>[
    500, 1000, 2000, 3000, 5000, 8000, 12000, 20000, 50000, //
  ];
  for (final kLambda in candidates) {
    final r = _encodeAndMeasure(
        corpusPixels,
        cw,
        ch,
        VardctL0Config.fromDistance(1.0)
            .withRd(enableRdHfMult: true, lambda: kLambda));
    final bytesDelta = (r.bytes - heuristic.bytes) / heuristic.bytes * 100;
    final rmseDelta = (r.rmse - heuristic.rmse) / heuristic.rmse * 100;
    print('${kLambda.toStringAsFixed(0).padLeft(8)}  '
        '${r.bytes.toString().padLeft(7)}  '
        '${r.rmse.toStringAsFixed(3).padLeft(6)}  '
        '${bytesDelta.toStringAsFixed(1).padLeft(10)}%  '
        '${rmseDelta.toStringAsFixed(1).padLeft(10)}%');
  }

  print('\n=== Gradient banding gate (must stay well under RMSE 1.0) ===');
  final gradient = _gradientPattern(256, 256);
  for (final kLambda in candidates) {
    final r = _encodeAndMeasure(
        gradient,
        256,
        256,
        VardctL0Config.fromDistance(1.0)
            .withRd(enableRdHfMult: true, lambda: kLambda));
    print('kLambda=${kLambda.toStringAsFixed(0).padLeft(8)}: '
        '${r.bytes} bytes, rmse=${r.rmse.toStringAsFixed(3)}'
        '${r.rmse < 0.8 ? '  OK' : r.rmse < 1.0 ? '  MARGIN' : '  FAIL'}');
  }

  print('\n=== Manga-content sanity (screentone, line art) ===');
  final screentone = _screentonePattern(256, 256);
  final lineArt = _lineArtPattern(256, 256);
  for (final kLambda in candidates) {
    final rs = _encodeAndMeasure(
        screentone,
        256,
        256,
        VardctL0Config.fromDistance(1.0)
            .withRd(enableRdHfMult: true, lambda: kLambda));
    final rl = _encodeAndMeasure(
        lineArt,
        256,
        256,
        VardctL0Config.fromDistance(1.0)
            .withRd(enableRdHfMult: true, lambda: kLambda));
    print('kLambda=${kLambda.toStringAsFixed(0).padLeft(8)}: '
        'screentone ${rs.bytes}B/${rs.rmse.toStringAsFixed(2)}  '
        'lineArt ${rl.bytes}B/${rl.rmse.toStringAsFixed(2)}');
  }
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
