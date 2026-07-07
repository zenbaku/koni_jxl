import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';

/// Joint calibration of the coarsen-baseline masking lever (coarsen AC
/// baseline `acScale/K` + spatial-blur mask-RD `hfMult` refine) on the
/// **perceptual** axis (ssimulacra2). This is the gate for ever flipping a
/// default on: it builds the full RD *envelope* (bytes vs ssimulacra2) for
/// both the incumbent heuristic and the coarsen-mask lever over a joint
/// `(K, lambda, distance)` sweep, and reports the byte savings at matched
/// ssimulacra2 across quality bands — plus which `(K, lambda)` achieves each
/// envelope point, so a shippable rule can be read off.
///
/// Envelope rule (applied identically to both arms, so the comparison is
/// fair): the best achievable bytes at a target quality `ss*` is the minimum
/// bytes among all measured points with `ssim2 >= ss*` (you can always spend a
/// higher-quality point's bytes to get at-least `ss*`). The heuristic arm is a
/// clean monotone distance sweep; the coarsen-mask arm is a scatter over
/// `(K, lambda, distance)` whose lower envelope is what matters.
///
/// Both arms run `enableVariableTransforms: false` (round 3's confound lesson —
/// neither arm gets a tool the other lacks). Uses brew `ssimulacra2` /
/// `butteraugli_main`.
///
/// Usage: `dart run tool/calibrate_coarsen_mask.dart`
void main() {
  final contents = <String, (int, int, Uint8List)>{
    'lineArt': (256, 256, _lineArt(256, 256)), // manga proxy (fast)
  };
  final cc = File('../../third_party/corpus/golden/color_cover_d0_e7.ppm');
  if (cc.existsSync()) {
    final (w, h, px) = _readPpm(cc.readAsBytesSync());
    contents['color_cover'] = (w, h, px); // photo proxy (slow)
  }

  // Joint sweep grid for the coarsen-mask-spatial arm.
  const coarsenFactors = <double>[1.5, 2.0, 3.0];
  const lambdas = <double>[0.04, 0.08, 0.15];
  const hi = 8.0;
  const coarsenDistances = <double>[0.75, 1.0, 1.5, 2.0, 3.0];

  // Dense heuristic distance sweep -> the incumbent envelope.
  const heurDistances = <double>[
    0.5,
    0.6,
    0.75,
    0.9,
    1.0,
    1.25,
    1.5,
    2.0,
    2.5,
    3.0
  ];

  for (final entry in contents.entries) {
    final name = entry.key;
    final (w, h, px) = entry.value;
    print('\n${'=' * 78}\n$name (${w}x$h) — joint coarsen-mask calibration'
        '\n${'=' * 78}');

    // Heuristic envelope.
    final heur = <_Pt>[];
    for (final d in heurDistances) {
      final base = VardctL0Config.fromDistance(d);
      final r = _koni(
          px,
          w,
          h,
          VardctL0Config(
              quantLF: base.quantLF,
              acScale: base.acScale,
              enableVariableTransforms: false));
      heur.add(_Pt(r.bytes, r.ss, r.ba, 'd=$d'));
    }
    heur.sort((a, b) => a.ss.compareTo(b.ss));

    // Coarsen-mask-spatial scatter.
    final coarsen = <_Pt>[];
    for (final K in coarsenFactors) {
      for (final lam in lambdas) {
        for (final d in coarsenDistances) {
          final r = _koni(px, w, h, _coarsen(d, K, lam: lam, hi: hi));
          coarsen.add(_Pt(r.bytes, r.ss, r.ba, 'K=$K lam=$lam d=$d'));
        }
      }
    }

    // Envelope comparison across quality bands.
    print('\n ssim2 | heur bytes | coarsen bytes (best cfg)            | save');
    print(' ${'-' * 74}');
    final targets = <double>[85, 86, 87, 88, 89, 90, 91, 92];
    for (final t in targets) {
      final hB = _bestBytesAtLeast(heur, t);
      final cBest = _bestPtAtLeast(coarsen, t);
      if (hB == null || cBest == null) {
        print(' ${t.toStringAsFixed(0).padLeft(5)} | '
            '${(hB?.toString() ?? '   --').padLeft(10)} | '
            '${(cBest?.label ?? 'none at this quality').padRight(34)} | --');
        continue;
      }
      final save = (cBest.bytes - hB) / hB * 100;
      final flag = save < -0.5 ? ' WIN' : (save > 0.5 ? ' loss' : ' ~');
      print(
          ' ${t.toStringAsFixed(0).padLeft(5)} | ${hB.toString().padLeft(10)} | '
          '${cBest.bytes.toString().padLeft(7)} (${cBest.label.padRight(22)}) | '
          '${save >= 0 ? '+' : ''}${save.toStringAsFixed(1)}%$flag');
    }
  }
}

/// Best (fewest-bytes) point whose ssim2 >= target.
_Pt? _bestPtAtLeast(List<_Pt> pts, double target) {
  _Pt? best;
  for (final p in pts) {
    if (p.ss >= target && (best == null || p.bytes < best.bytes)) best = p;
  }
  return best;
}

int? _bestBytesAtLeast(List<_Pt> pts, double target) =>
    _bestPtAtLeast(pts, target)?.bytes;

VardctL0Config _coarsen(double dTarget, double K,
        {required double lam, required double hi}) =>
    VardctL0Config(
      quantLF: VardctL0Config.fromDistance(dTarget).quantLF,
      acScale: VardctL0Config.fromDistance(dTarget).acScale / K,
      enableVariableTransforms: false,
      enableRdHfMult: true,
      rdHfMultLambdaOverride: lam,
      perceptualMask: true,
      spatialMask: true,
      maskParamsOverride: (hi: hi, knee: 8.0, gamma: 2.0),
    );

class _Pt {
  _Pt(this.bytes, this.ss, this.ba, this.label);
  final int bytes;
  final double ss;
  final double ba;
  final String label;
}

class _R {
  _R(this.bytes, this.ss, this.ba);
  final int bytes;
  final double ss;
  final double ba;
}

_R _koni(Uint8List px, int w, int h, VardctL0Config cfg) {
  final encoded = encodeLossyVardctL0(px, width: w, height: h, config: cfg);
  final (ss, ba) = _perceptual(encoded, px, w, h);
  return _R(encoded.length, ss, ba);
}

(double, double) _perceptual(
    Uint8List encoded, Uint8List original, int w, int h) {
  final dir = Directory.systemTemp.createTempSync('calib_coarsen');
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
