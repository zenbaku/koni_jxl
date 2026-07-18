import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';

/// Calibrates the perceptual masking distortion term
/// ([VardctL0Config.perceptualMask], `_maskWeight`) that round 3 identified
/// as the missing piece for the RD-hfMult search (see `_chooseHfMultRd`'s
/// doc comment and doc/spec_notes.md).
///
/// The target is precise: round 3 found plain weighted-MSE RD, at a
/// photo-favorable `kLambda`, *already* beats the L2 heuristic on
/// `color_cover` (smaller AND better RMSE) — its ONLY failure was the
/// smooth-gradient banding gate (gradient RMSE ~0.94 vs the heuristic's safe
/// ~0.6). The masking term should recover that photo win while re-protecting
/// genuinely-smooth blocks (amplifying their distortion so the RD search
/// keeps their precision boost).
///
/// So this tool reports two views on the same content:
///   1. A `distance = 1.0` grid over (lambda, hi) with three arms —
///      `heuristic` (L2 3-bucket, `enableRdHfMult` off, the shipped default),
///      `plainRd` (round 3's config), and `maskRd` — for finding the winning
///      curve at manga's operating point.
///   2. A **multi-lambda × multi-distance** across-distance sweep (round 21):
///      %-vs-heuristic per content at distances 0.5-8.0, which exposes the
///      structural high-distance blowup (busy content balloons +24% to +45% at
///      distance 4+ *regardless of lambda*, because the `acScale^2` scaling that
///      keeps banding safe collapses the rate term — see doc/spec_notes.md's
///      round 21 entry). The tool previously only checked one across-distance
///      lambda (0.04, the wrong value), which hid the whole picture.
/// The win condition for `maskRd` vs `heuristic`: color_cover smaller (and
/// RMSE no worse) AND gradient gate comfortably safe AND no screentone/line-art
/// regression. Round 21's conclusion: `hi=8, lambda=0.08` is the Pareto sweet
/// spot at distance <= ~1.25 (a real never-worse win, incl. on real manga), but
/// no single lambda is safe across all distances, so the mask stays **opt-in**,
/// default off (`_kMaskRdLambda = 0.08` baked for the opt-in path).
///
/// Runs with `enableVariableTransforms: false` throughout, same isolation
/// rationale as `tool/calibrate_rd_lambda.dart` (avoids the degenerate
/// coarse-gradient transform-layout confound that made an earlier hfMult
/// sweep look kLambda-insensitive).
///
/// Usage: `dart run tool/calibrate_perceptual_mask.dart`
void main() {
  const corpusPath = '../../third_party/corpus/golden/color_cover_d0_e7.ppm';
  final corpusFile = File(corpusPath);
  if (!corpusFile.existsSync()) {
    stderr.writeln('corpus not found at $corpusPath -- run tool/gen_corpus.py');
    exit(1);
  }
  final (cw, ch, corpusPixels) = _readPpm(corpusFile.readAsBytesSync());

  final gradient = _gradientPattern(256, 256);
  final screentone = _screentonePattern(256, 256);
  final lineArt = _lineArtPattern(256, 256);

  // plainRd (round 3) reference lambda, in refStep^2 units (unchanged path).
  const plainLambda = 12000.0;

  // Mask-arm lambda in acScale^2 units (the mask path's scaling). At distance
  // 1.0, acScale=1 so lambda == kLambda; ~0.04 is plainRd's distance-1.0
  // operating point re-expressed in these units (12000 * refStep^2, refStep
  // ~0.0018). Line art (mixed content) is where masking's win lives, so it is
  // measured alongside color_cover here.
  const maskLambdas = <double>[0.02, 0.04, 0.08];
  const his = <double>[4.0, 8.0, 16.0];
  const knee = 1.5;
  const gamma = 2.0;

  print('${'=' * 78}\ndistance = 1.0 — grid (mask acScale^2 units, '
      'enableVariableTransforms:false)\n${'=' * 78}');
  final base1 = _isolatedBase(1.0);
  final ccHeur = _encodeAndMeasure(corpusPixels, cw, ch, base1);
  final gHeur1 = _encodeAndMeasure(gradient, 256, 256, base1);
  final lHeur1 = _encodeAndMeasure(lineArt, 256, 256, base1);
  print('heuristic : color_cover ${ccHeur.bytes}B/${_f(ccHeur.rmse)}   '
      'gradient ${gHeur1.bytes}B/${_f(gHeur1.rmse)}   '
      'lineArt ${lHeur1.bytes}B/${_f(lHeur1.rmse)}');
  final ccPlain =
      _encodeAndMeasure(corpusPixels, cw, ch, base1.plainRd(plainLambda));
  final lPlain =
      _encodeAndMeasure(lineArt, 256, 256, base1.plainRd(plainLambda));
  print('plainRd   : color_cover ${ccPlain.bytes}B/${_f(ccPlain.rmse)} '
      '(${_pct(ccPlain.bytes, ccHeur.bytes)})   '
      'lineArt ${lPlain.bytes}B/${_f(lPlain.rmse)} '
      '(${_pct(lPlain.bytes, lHeur1.bytes)})\n');

  print(
      '  lam    hi | color_cover  %vH  rmse | lineArt  %vH  rmse | grad rmse gate');
  print('  ${'-' * 72}');
  for (final lam in maskLambdas) {
    for (final hi in his) {
      final cfg = base1.maskRd(lam, hi: hi, knee: knee, gamma: gamma);
      final cc = _encodeAndMeasure(corpusPixels, cw, ch, cfg);
      final l = _encodeAndMeasure(lineArt, 256, 256, cfg);
      final g = _encodeAndMeasure(gradient, 256, 256, cfg);
      final gate = g.rmse <= gHeur1.rmse * 1.02
          ? 'OK'
          : g.rmse <= gHeur1.rmse * 1.15
              ? 'MARG'
              : 'FAIL';
      print('  ${_p(lam, 4)} ${_p(hi, 3)} | '
          '${cc.bytes.toString().padLeft(7)} ${_pct(cc.bytes, ccHeur.bytes).padLeft(6)} ${_f(cc.rmse)} | '
          '${l.bytes.toString().padLeft(6)} ${_pct(l.bytes, lHeur1.bytes).padLeft(6)} ${_f(l.rmse)} | '
          '${_f(g.rmse)} $gate');
    }
  }

  // Multi-lambda across-distance safety. The busy-content size blowup at high
  // distance is caused by lambda getting too SMALL (rate ~free -> RD over-
  // refines busy blocks); a HIGHER kLambda should suppress it, so sweep several.
  // Reports %-vs-heuristic per content so a single "safe everywhere AND wins at
  // d~1" lambda (if one exists) is visible. Positive % on busy content = a size
  // regression (bigger for quality the distance setting was discarding).
  const chkHi = _pickHi, chkKnee = _pickKnee;
  const dists = <double>[0.5, 1.0, 2.0, 4.0, 8.0];
  // Heuristic baselines per distance (cached — reused across every lambda).
  final baseByDist = {for (final d in dists) d: _isolatedBase(d)};
  final ccH = {
    for (final d in dists)
      d: _encodeAndMeasure(corpusPixels, cw, ch, baseByDist[d]!)
  };
  final gH = {
    for (final d in dists)
      d: _encodeAndMeasure(gradient, 256, 256, baseByDist[d]!)
  };
  final sH = {
    for (final d in dists)
      d: _encodeAndMeasure(screentone, 256, 256, baseByDist[d]!)
  };
  final lH = {
    for (final d in dists)
      d: _encodeAndMeasure(lineArt, 256, 256, baseByDist[d]!)
  };
  for (final lam in <double>[0.06, 0.08, 0.12, 0.16, 0.24]) {
    print('\n${'=' * 78}\nAcross-distance maskRd(lam=$lam, hi=$chkHi, '
        'knee=$chkKnee, gamma=$gamma) [acScale^2] — %-vs-heuristic\n${'=' * 78}');
    print('dist |  color_cover %vH rmse(h/m) | grad rmse(h/m) gate | '
        'screentone %vH | lineArt %vH rmse(h/m)');
    for (final d in dists) {
      final mask =
          baseByDist[d]!.maskRd(lam, hi: chkHi, knee: chkKnee, gamma: gamma);
      final ccM = _encodeAndMeasure(corpusPixels, cw, ch, mask);
      final gM = _encodeAndMeasure(gradient, 256, 256, mask);
      final sM = _encodeAndMeasure(screentone, 256, 256, mask);
      final lM = _encodeAndMeasure(lineArt, 256, 256, mask);
      final gate = gM.rmse <= gH[d]!.rmse * 1.02
          ? 'OK'
          : gM.rmse <= gH[d]!.rmse * 1.15
              ? 'MARG'
              : 'FAIL';
      print('${_p(d, 4)} | '
          '${_pct(ccM.bytes, ccH[d]!.bytes).padLeft(6)} '
          '${_f(ccH[d]!.rmse)}/${_f(ccM.rmse)} | '
          '${_f(gH[d]!.rmse)}/${_f(gM.rmse)} $gate | '
          '${_pct(sM.bytes, sH[d]!.bytes).padLeft(6)} | '
          '${_pct(lM.bytes, lH[d]!.bytes).padLeft(6)} '
          '${_f(lH[d]!.rmse)}/${_f(lM.rmse)}');
    }
  }
}

// Chosen curve for the across-distance safety table (matches the shipped
// _kMaskHi/_kMaskKnee unless overridden here for exploration).
const _pickHi = 8.0;
const _pickKnee = 1.5;

String _f(double v) => v.toStringAsFixed(3);
String _p(double v, int w) =>
    v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1).padLeft(w);
String _pct(int a, int b) => '${((a - b) / b * 100).toStringAsFixed(1)}%';

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
  VardctL0Config plainRd(double lambda) => VardctL0Config(
      globalScale: globalScale,
      quantLF: quantLF,
      xqmScale: xqmScale,
      bqmScale: bqmScale,
      acScale: acScale,
      enableVariableTransforms: enableVariableTransforms,
      enableRdHfMult: true,
      rdHfMultLambdaOverride: lambda);

  VardctL0Config maskRd(double lambda,
          {required double hi, required double knee, required double gamma}) =>
      VardctL0Config(
          globalScale: globalScale,
          quantLF: quantLF,
          xqmScale: xqmScale,
          bqmScale: bqmScale,
          acScale: acScale,
          enableVariableTransforms: enableVariableTransforms,
          enableRdHfMult: true,
          rdHfMultLambdaOverride: lambda,
          perceptualMask: true,
          maskParamsOverride: (hi: hi, knee: knee, gamma: gamma));
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
  final dir = Directory.systemTemp.createTempSync('calib_mask');
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
