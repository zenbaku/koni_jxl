import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';

/// Calibrates `_kRdoqLambda` (the RDOQ coefficient-dropping pass's
/// rate/distortion trade-off constant, `VardctL0Config.enableRdoq`) by
/// sweeping it against real corpus content, manga-typical screentone
/// content, and the encoder's own synthetic regression-test patterns —
/// across the encoder's **full distance range** (0.5-8.0), not a single
/// point. This is a direct fix for how the previous attempt shipped: a
/// `distance=1.0`-only calibration found a constant that looked perfect,
/// but turned out to roughly double RMSE at `distance=8.0` because
/// `lambda`'s old `refStep^2` scaling grows in the *opposite* direction
/// from how RDOQ's own distortion metric scales with the dequant weight
/// table (see doc/spec_notes.md's "why it's off" section for the full
/// derivation). `lambda` now scales with `acScale^2` instead — verified
/// empirically (not just derived) to keep RDOQ's aggressiveness roughly
/// bounded across the full distance range rather than blowing up at
/// high distance — but a fresh calibration is still required since the
/// old constant (tuned for the old formula's units) does not transfer.
///
/// Bar to clear, at **every** tested distance:
///  (a) no regression vs the RDOQ-off baseline beyond a small, accepted
///      RMSE cost (a few percent) in exchange for a real size win;
///  (b) the gradient-banding regression test's RMSE stays comfortably
///      under its 1.0 gate;
///  (c) no regression on manga-typical screentone/line-art content.
///
/// Usage: `dart run tool/calibrate_rdoq_lambda.dart`
void main() {
  const corpusPath = '../../third_party/corpus/golden/color_cover_d0_e7.ppm';
  final corpusFile = File(corpusPath);
  if (!corpusFile.existsSync()) {
    stderr.writeln('corpus not found at $corpusPath -- run tool/gen_corpus.py');
    exit(1);
  }
  final (cw, ch, corpusPixels) = _readPpm(corpusFile.readAsBytesSync());
  final palette16File =
      File('../../third_party/corpus/golden/palette16_d0_e7.ppm');
  final (pw, ph, palettePixels) = palette16File.existsSync()
      ? _readPpm(palette16File.readAsBytesSync())
      : (0, 0, Uint8List(0));

  final distances = <double>[0.5, 1.0, 2.0, 4.0, 8.0];
  final candidates = <double>[0.01, 0.02, 0.03, 0.05, 0.08, 0.15];
  final gradient = _gradientPattern(256, 256);
  final screentone = _screentonePattern(256, 256);
  final lineArt = _lineArtPattern(256, 256);

  for (final distance in distances) {
    print('\n${'=' * 70}');
    print('distance = $distance');
    print('=' * 70);

    final base = VardctL0Config.fromDistance(distance);
    final corpusBase = _encodeAndMeasure(corpusPixels, cw, ch, base);
    print('color_cover  RDOQ off: ${corpusBase.bytes} bytes, '
        'rmse=${corpusBase.rmse.toStringAsFixed(3)}');
    final gradBase = _encodeAndMeasure(gradient, 256, 256, base);
    print('gradient     RDOQ off: ${gradBase.bytes} bytes, '
        'rmse=${gradBase.rmse.toStringAsFixed(3)}');
    _Measurement? paletteBase;
    if (pw > 0) {
      paletteBase = _encodeAndMeasure(palettePixels, pw, ph, base);
      print('palette16    RDOQ off: ${paletteBase.bytes} bytes, '
          'rmse=${paletteBase.rmse.toStringAsFixed(3)}');
    }

    print('\nkLambda   color_cover(B/rmse%)      gradient(B/rmse)   gate');
    for (final kLambda in candidates) {
      final cfg = base.withRdoq(lambda: kLambda);
      final r = _encodeAndMeasure(corpusPixels, cw, ch, cfg);
      final g = _encodeAndMeasure(gradient, 256, 256, cfg);
      final bytesDelta = (r.bytes - corpusBase.bytes) / corpusBase.bytes * 100;
      final rmseDelta = (r.rmse - corpusBase.rmse) / corpusBase.rmse * 100;
      final gate = g.rmse < 0.8
          ? 'OK'
          : g.rmse < 1.0
              ? 'MARGIN'
              : 'FAIL';
      print('${kLambda.toStringAsFixed(3).padLeft(7)}   '
          '${r.bytes.toString().padLeft(7)} (${bytesDelta.toStringAsFixed(1).padLeft(6)}% / '
          '${rmseDelta.toStringAsFixed(1).padLeft(6)}%)   '
          '${g.bytes.toString().padLeft(6)}B/${g.rmse.toStringAsFixed(3).padLeft(6)}   $gate');
    }

    print('\nManga-content sanity (screentone, line art):');
    for (final kLambda in candidates) {
      final cfg = base.withRdoq(lambda: kLambda);
      final rs = _encodeAndMeasure(screentone, 256, 256, cfg);
      final rl = _encodeAndMeasure(lineArt, 256, 256, cfg);
      print('kLambda=${kLambda.toStringAsFixed(3).padLeft(7)}: '
          'screentone ${rs.bytes}B/${rs.rmse.toStringAsFixed(2)}  '
          'lineArt ${rl.bytes}B/${rl.rmse.toStringAsFixed(2)}');
    }
  }
}

extension on VardctL0Config {
  VardctL0Config withRdoq({required double lambda}) => VardctL0Config(
      globalScale: globalScale,
      quantLF: quantLF,
      xqmScale: xqmScale,
      bqmScale: bqmScale,
      acScale: acScale,
      enableRdHfMult: enableRdHfMult,
      rdHfMultLambdaOverride: rdHfMultLambdaOverride,
      enableRdoq: true,
      rdoqLambdaOverride: lambda);
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
