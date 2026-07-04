import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';

/// Calibrates `_kTransformRdLambda` (the 8x8-vs-16x16 layout decision's
/// rate/distortion trade-off constant, `VardctL0Config.
/// enableVariableTransforms`'s `_decideTransformLayout`) by sweeping it
/// against real corpus content, manga-typical screentone/line-art content,
/// and the encoder's own synthetic regression-test patterns — across the
/// encoder's **full distance range** (0.5-8.0), not a single point. This is
/// the same lesson RDOQ's calibration learned the hard way (see
/// `calibrate_rdoq_lambda.dart`'s doc comment): a single-distance
/// calibration can look perfect at that one point and still regress badly
/// elsewhere.
///
/// Unlike RDOQ/RD-hfMult, this decision replaces a proxy that was already
/// measured to *regress* manga content (`_should16x16`, removed) — so the
/// bar here is stricter:
///  (a) at every tested distance, `enableVariableTransforms: true` must not
///      be meaningfully larger than `false` on screentone/line-art (the
///      whole point of this fix);
///  (b) it should be smaller on photographic/gradient content where
///      16x16 genuinely helps;
///  (c) RMSE must not regress alongside any size win.
///
/// Usage: `dart run tool/calibrate_transform_lambda.dart`
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
  final candidates = <double>[100, 300, 1000, 3000, 10000, 30000, 100000];
  final gradient = _gradientPattern(256, 256);
  final screentone = _screentonePattern(256, 256);
  final lineArt = _lineArtPattern(256, 256);

  for (final distance in distances) {
    print('\n${'=' * 78}');
    print('distance = $distance');
    print('=' * 78);

    final base = VardctL0Config.fromDistance(distance);
    final corpusOff = _encodeAndMeasure(corpusPixels, cw, ch, base);
    final gradOff = _encodeAndMeasure(gradient, 256, 256, base);
    final screenOff = _encodeAndMeasure(screentone, 256, 256, base);
    final lineOff = _encodeAndMeasure(lineArt, 256, 256, base);
    _Measurement? paletteOff;
    if (pw > 0) paletteOff = _encodeAndMeasure(palettePixels, pw, ph, base);
    print(
        'vt=off  color_cover ${corpusOff.bytes}B/${corpusOff.rmse.toStringAsFixed(3)}  '
        'gradient ${gradOff.bytes}B/${gradOff.rmse.toStringAsFixed(3)}  '
        'screentone ${screenOff.bytes}B/${screenOff.rmse.toStringAsFixed(3)}  '
        'lineArt ${lineOff.bytes}B/${lineOff.rmse.toStringAsFixed(3)}'
        '${paletteOff == null ? '' : '  palette16 ${paletteOff.bytes}B/${paletteOff.rmse.toStringAsFixed(3)}'}');

    print('\nkLambda     color_cover(B,%,rmse%)      gradient(B,%)   '
        'screentone(B,%)   lineArt(B,%)   manga-gate');
    for (final kLambda in candidates) {
      final cfg = base.withTransform(lambda: kLambda);
      final r = _encodeAndMeasure(corpusPixels, cw, ch, cfg);
      final g = _encodeAndMeasure(gradient, 256, 256, cfg);
      final s = _encodeAndMeasure(screentone, 256, 256, cfg);
      final l = _encodeAndMeasure(lineArt, 256, 256, cfg);
      final rBytesD = (r.bytes - corpusOff.bytes) / corpusOff.bytes * 100;
      final rRmseD = (r.rmse - corpusOff.rmse) / corpusOff.rmse * 100;
      final gBytesD = (g.bytes - gradOff.bytes) / gradOff.bytes * 100;
      final sBytesD = (s.bytes - screenOff.bytes) / screenOff.bytes * 100;
      final lBytesD = (l.bytes - lineOff.bytes) / lineOff.bytes * 100;
      final mangaGate = (sBytesD < 2.0 &&
              lBytesD < 2.0 &&
              s.rmse <= screenOff.rmse * 1.05 &&
              l.rmse <= lineOff.rmse * 1.05)
          ? 'OK'
          : 'FAIL';
      print('${kLambda.toStringAsFixed(0).padLeft(8)}   '
          '${r.bytes.toString().padLeft(7)} (${rBytesD.toStringAsFixed(1).padLeft(6)}% / '
          '${rRmseD.toStringAsFixed(1).padLeft(6)}%)   '
          '${g.bytes.toString().padLeft(6)} (${gBytesD.toStringAsFixed(1).padLeft(6)}%)   '
          '${s.bytes.toString().padLeft(6)} (${sBytesD.toStringAsFixed(1).padLeft(6)}%)   '
          '${l.bytes.toString().padLeft(6)} (${lBytesD.toStringAsFixed(1).padLeft(6)}%)   '
          '$mangaGate');
    }
  }
}

extension on VardctL0Config {
  VardctL0Config withTransform({required double lambda}) => VardctL0Config(
      globalScale: globalScale,
      quantLF: quantLF,
      xqmScale: xqmScale,
      bqmScale: bqmScale,
      acScale: acScale,
      enableVariableTransforms: true,
      transformRdLambdaOverride: lambda,
      enableRdHfMult: enableRdHfMult,
      rdHfMultLambdaOverride: rdHfMultLambdaOverride,
      enableRdoq: enableRdoq,
      rdoqLambdaOverride: rdoqLambdaOverride);
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
