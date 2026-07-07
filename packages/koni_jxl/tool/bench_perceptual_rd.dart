import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';

/// Prototype + measurement for the **coarsen-baseline masking lever** — the
/// piece the refine-only `hfMult` search structurally lacks (see
/// doc/spec_notes.md's perceptual-mask write-up and `_maskWeight`).
///
/// Idea: `hfMult` can only make a block *finer* than the frame baseline, so on
/// its own it can never quantize a busy region *coarser* than baseline — which
/// is exactly the masking win `cjxl -e7` gets. This tool coarsens the AC
/// baseline (`acScale / K`, keeping `quantLF` fine since banding lives in LF)
/// and lets the mask-aware RD `hfMult` search refine smooth/banding-prone
/// blocks back up. Net: busy regions sit at the coarse baseline (bit savings),
/// smooth regions are refined (quality/banding preserved).
///
/// Measured on a **perceptual** axis (ssimulacra2, higher = better; and
/// butteraugli max-norm, lower = better) — NOT RMSE, because the whole point of
/// masking is to spend bits where RMSE doesn't reward but perception does, so
/// an RMSE curve systematically under-measures it.
///
/// Win condition: at a matched ssimulacra2, the coarsen-mask arm uses fewer
/// bytes than the heuristic baseline arm.
///
/// Usage: `dart run tool/bench_perceptual_rd.dart`
void main() {
  final contents = <String, (int, int, Uint8List)>{
    'mixedPhoto': (256, 256, _mixedPhoto(256, 256)),
    'lineArt': (256, 256, _lineArt(256, 256)),
  };
  // color_cover (corpus, ~5s/encode, smooth-dominated => pessimistic for
  // masking) added only if present, with a sparse curve.
  final cc = File('../../third_party/corpus/golden/color_cover_d0_e7.ppm');
  if (cc.existsSync()) {
    final (w, h, px) = _readPpm(cc.readAsBytesSync());
    contents['color_cover'] = (w, h, px);
  }

  for (final entry in contents.entries) {
    final name = entry.key;
    final (w, h, px) = entry.value;
    print('\n${'=' * 78}\n$name (${w}x$h)\n${'=' * 78}');

    final sparse = name == 'color_cover';
    final heurDistances = sparse
        ? <double>[0.75, 1.5, 3.0]
        : <double>[0.5, 0.75, 1.0, 1.5, 2.0, 3.0];

    print('-- heuristic baseline (sweep distance) --');
    print('  dist |    bytes | ssim2  | butteraugli');
    final heur = <(int bytes, double ss)>[];
    for (final d in heurDistances) {
      // enableVariableTransforms:false to isolate the quant lever from the
      // transform-layout decision — same isolation the coarsen-mask arm uses,
      // so neither arm has a tool the other lacks (round 3's confound lesson).
      final base = VardctL0Config.fromDistance(d);
      final r = _koni(
          px,
          w,
          h,
          VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: false));
      heur.add((r.bytes, r.ss));
      print('  ${_p(d, 4)} | ${_b(r.bytes)} | ${_f2(r.ss)} | ${_f3(r.ba)}');
    }

    print('-- coarsen-mask (baseline acScale/K + mask-RD refine) --');
    print('   K  dist  lam  hi |    bytes | ssim2  | butter | vs-heur@ssim2');
    // Coarsen factor K, at a target distance chosen so the coarse baseline
    // lands near the quality band we care about. lam in acScale^2 units.
    for (final K in <double>[1.5, 2.0, 3.0]) {
      for (final d
          in (sparse ? <double>[1.0, 2.0] : <double>[0.75, 1.5, 2.5])) {
        final r = _koni(px, w, h, _coarsenMask(d, K, lam: 0.08, hi: 8.0));
        final vs = _bytesAtSs(heur, r.ss);
        final tag = vs == null
            ? '(off-curve)'
            : '${_pct(r.bytes, vs)} (${_b(vs)}B heur)';
        print('  ${_p(K, 2)} ${_p(d, 4)} 0.08  8 | ${_b(r.bytes)} | '
            '${_f2(r.ss)} | ${_f3(r.ba)} | $tag');
      }
    }
  }
}

/// Interpolate the heuristic curve's byte count at a given ssimulacra2 (curve
/// is monotone: higher distance -> lower ss2, higher... i.e. bytes fall as ss2
/// falls). Returns null if `ss` is outside the measured range.
int? _bytesAtSs(List<(int, double)> pts, double ss) {
  final p = [...pts]..sort((a, b) => a.$2.compareTo(b.$2));
  for (var i = 0; i < p.length - 1; i++) {
    final (b0, s0) = p[i];
    final (b1, s1) = p[i + 1];
    if (ss >= s0 && ss <= s1) {
      final t = (ss - s0) / (s1 - s0);
      return (b0 + t * (b1 - b0)).round();
    }
  }
  return null;
}

VardctL0Config _coarsenMask(double dTarget, double K,
    {required double lam, required double hi}) {
  final base = VardctL0Config.fromDistance(dTarget);
  return VardctL0Config(
    quantLF: base.quantLF, // keep DC/LF fine (banding lives here)
    acScale: base.acScale / K, // coarsen the AC baseline
    enableVariableTransforms: false,
    enableRdHfMult: true,
    rdHfMultLambdaOverride: lam,
    perceptualMask: true,
    maskParamsOverride: (hi: hi, knee: 1.5, gamma: 2.0),
  );
}

class _R {
  _R(this.bytes, this.ss, this.ba);
  final int bytes;
  final double ss; // ssimulacra2 (higher better)
  final double ba; // butteraugli max-norm (lower better)
}

_R _koni(Uint8List px, int w, int h, VardctL0Config cfg) {
  final encoded = encodeLossyVardctL0(px, width: w, height: h, config: cfg);
  final (ss, ba) = _perceptual(encoded, px, w, h);
  return _R(encoded.length, ss, ba);
}

/// Decode via djxl, then score decoded-vs-original with ssimulacra2 and
/// butteraugli_main.
(double, double) _perceptual(
    Uint8List encoded, Uint8List original, int w, int h) {
  final dir = Directory.systemTemp.createTempSync('perc_rd');
  try {
    final jxl = '${dir.path}/t.jxl';
    final dec = '${dir.path}/dec.ppm';
    final orig = '${dir.path}/orig.ppm';
    File(jxl).writeAsBytesSync(encoded);
    File(orig).writeAsBytesSync(_writePpm(original, w, h));
    final d = Process.runSync('djxl', [jxl, dec, '--num_threads', '1']);
    if (d.exitCode != 0) return (double.nan, double.nan);
    final s = Process.runSync('ssimulacra2', [orig, dec]);
    final b = Process.runSync('butteraugli_main', [orig, dec]);
    final ss = double.tryParse(s.stdout.toString().trim()) ?? double.nan;
    final ba =
        double.tryParse(b.stdout.toString().trim().split('\n').first.trim()) ??
            double.nan;
    return (ss, ba);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

String _f2(double v) => v.isNaN ? '  NaN ' : v.toStringAsFixed(2).padLeft(6);
String _f3(double v) => v.isNaN ? ' NaN ' : v.toStringAsFixed(3).padLeft(5);
String _b(int v) => v.toString().padLeft(8);
String _p(double v, int w) =>
    v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1).padLeft(w);
String _pct(int a, int b) {
  final d = (a - b) / b * 100;
  return '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)}%';
}

/// Left half: smooth diagonal gradient (banding-prone). Right half:
/// high-frequency sinusoidal texture (busy, masking-friendly). The canonical
/// mixed-content masking test.
Uint8List _mixedPhoto(int w, int h) {
  final out = Uint8List(w * h * 3);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int r, g, b;
      if (x < w ~/ 2) {
        final v = ((x + y) * 255 / w).round().clamp(0, 255);
        r = v;
        g = (v * 0.7).round();
        b = 255 - v;
      } else {
        final t = (math.sin(x * 0.9) * math.cos(y * 0.8) * 60).round();
        final base = 128 + (x + y) % 40 - 20;
        r = (base + t).clamp(0, 255);
        g = (base - t).clamp(0, 255);
        b = (base + t ~/ 2).clamp(0, 255);
      }
      out[i++] = r;
      out[i++] = g;
      out[i++] = b;
    }
  }
  return out;
}

Uint8List _lineArt(int w, int h) {
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

Uint8List _writePpm(Uint8List rgb, int w, int h) {
  final header = 'P6\n$w $h\n255\n'.codeUnits;
  final out = Uint8List(header.length + rgb.length);
  out.setAll(0, header);
  out.setAll(header.length, rgb);
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
