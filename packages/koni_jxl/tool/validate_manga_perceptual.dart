import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:koni_jxl/src/encode/vardct/vardct_l0_encoder.dart';

/// Real-manga **perceptual** validation for the coarsen-baseline + spatial-mask
/// lever — the honest prerequisite (spec_notes round 20) before any default
/// decision, since the synthetic line-art proxy showed the lever manga-neutral
/// while real screentone has more mid-frequency texture masking might exploit
/// differently (the DCT32/round-7 lesson: synthetic content ≠ real content).
///
/// Same envelope methodology as `tool/calibrate_coarsen_mask.dart` but sourced
/// from real `manga_samples/*.cbz` pages (gitignored, copyrighted — never
/// committed, no derived fixtures in the repo; this tool only *reads* them for
/// a local measurement). Source pixels come from this package's own
/// `JxlDecoder` (BENCHMARKS.md established these pages decode within 1/255 of
/// djxl), re-encoded lossily with the incumbent heuristic vs. the
/// coarsen-mask-spatial lever, scored on ssimulacra2/butteraugli.
///
/// Verdict question: at matched ssimulacra2, does the lever win, lose, or stay
/// neutral on *real* manga pages — like the photo proxy (big win) or the
/// synthetic line-art proxy (neutral-to-slight-loss)?
///
/// Usage: `dart run tool/validate_manga_perceptual.dart [--pages=N] [cbz...]`
void main(List<String> rawArgs) {
  var pages = 2;
  final cbzArgs = <String>[];
  for (final a in rawArgs) {
    if (a.startsWith('--pages=')) {
      pages = int.parse(a.substring('--pages='.length));
    } else {
      cbzArgs.add(a);
    }
  }
  final cbzPaths = cbzArgs.isNotEmpty
      ? cbzArgs
      : [
          '../../manga_samples/Naruto__Chapter_684.cbz',
          '../../manga_samples/One-Piece-Digital-Colored-Comics__Chapter_1041.cbz',
        ];

  const heurDistances = <double>[0.5, 0.75, 1.0, 1.5, 2.0, 3.0];
  const coarsenFactors = <double>[1.5, 2.0];
  const lambdas = <double>[0.04, 0.08, 0.15];
  const coarsenDistances = <double>[1.0, 1.5, 2.0];
  const hi = 8.0;
  const targets = <double>[85, 87, 89, 91, 93];

  // Aggregate save% per ss2 band across all pages (only bands where both arms
  // reach that quality on that page).
  final aggSave = {for (final t in targets) t: <double>[]};

  for (final cbzPath in cbzPaths) {
    if (!File(cbzPath).existsSync()) {
      stderr.writeln('skip (not found): $cbzPath');
      continue;
    }
    final entries = _listJxlEntries(cbzPath);
    if (entries.isEmpty) continue;
    final selected = _selectPages(entries, pages);
    print('\n${'=' * 78}\n$cbzPath (${entries.length} pages, using $pages)'
        '\n${'=' * 78}');

    for (final entry in selected) {
      final bytes = _readZipEntry(cbzPath, entry);
      final image = JxlDecoder.decode(bytes);
      final w = image.width, h = image.height;
      final rgba = image.toRgba8();
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < w * h; i++) {
        rgb[i * 3] = rgba[i * 4];
        rgb[i * 3 + 1] = rgba[i * 4 + 1];
        rgb[i * 3 + 2] = rgba[i * 4 + 2];
      }
      stdout.write('  $entry (${w}x$h): ');

      final heur = <_Pt>[];
      for (final d in heurDistances) {
        final base = VardctL0Config.fromDistance(d);
        heur.add(_encode(
            rgb,
            w,
            h,
            VardctL0Config(
                quantLF: base.quantLF,
                acScale: base.acScale,
                enableVariableTransforms: false),
            'd=$d'));
        stdout.write('h');
      }
      heur.sort((a, b) => a.ss.compareTo(b.ss));

      final coarsen = <_Pt>[];
      for (final K in coarsenFactors) {
        for (final lam in lambdas) {
          for (final d in coarsenDistances) {
            final base = VardctL0Config.fromDistance(d);
            coarsen.add(_encode(
                rgb,
                w,
                h,
                VardctL0Config(
                  quantLF: base.quantLF,
                  acScale: base.acScale / K,
                  enableVariableTransforms: false,
                  enableRdHfMult: true,
                  rdHfMultLambdaOverride: lam,
                  perceptualMask: true,
                  spatialMask: true,
                  maskParamsOverride: (hi: hi, knee: 8.0, gamma: 2.0),
                ),
                'K=$K lam=$lam d=$d'));
            stdout.write('c');
          }
        }
      }
      stdout.write('\n');

      print('    ssim2 | heur B | coarsen B (cfg)                  | save');
      for (final t in targets) {
        final hp = _bestAtLeast(heur, t);
        final cp = _bestAtLeast(coarsen, t);
        if (hp == null || cp == null) {
          print('    ${t.toStringAsFixed(0).padLeft(5)} | '
              '${hp == null ? 'n/a' : hp.bytes.toString()} | '
              '${cp == null ? 'neither/one arm reaches this quality' : cp.bytes.toString()}');
          continue;
        }
        final save = (cp.bytes - hp.bytes) / hp.bytes * 100;
        aggSave[t]!.add(save);
        final flag = save < -0.5 ? ' WIN' : (save > 0.5 ? ' loss' : ' ~');
        print('    ${t.toStringAsFixed(0).padLeft(5)} | '
            '${hp.bytes.toString().padLeft(7)} | '
            '${cp.bytes.toString().padLeft(7)} (${cp.label.padRight(18)}) | '
            '${save >= 0 ? '+' : ''}${save.toStringAsFixed(1)}%$flag');
      }
    }
  }

  print(
      '\n${'=' * 78}\nAGGREGATE — mean save% at matched ssim2 across all real '
      'pages\n${'=' * 78}');
  print(' ssim2 | n pages | mean save% | verdict');
  for (final t in targets) {
    final xs = aggSave[t]!;
    if (xs.isEmpty) {
      print(' ${t.toStringAsFixed(0).padLeft(5)} |       0 | (no pages reach '
          'this quality on both arms)');
      continue;
    }
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    final verdict = mean < -1
        ? 'WIN'
        : mean > 1
            ? 'LOSS'
            : 'neutral';
    final meanStr = '${mean >= 0 ? '+' : ''}${mean.toStringAsFixed(1)}%';
    print(' ${t.toStringAsFixed(0).padLeft(5)} | '
        '${xs.length.toString().padLeft(7)} | ${meanStr.padLeft(10)} | $verdict');
  }
}

_Pt? _bestAtLeast(List<_Pt> pts, double target) {
  _Pt? best;
  for (final p in pts) {
    if (p.ss >= target && (best == null || p.bytes < best.bytes)) best = p;
  }
  return best;
}

class _Pt {
  _Pt(this.bytes, this.ss, this.ba, this.label);
  final int bytes;
  final double ss;
  final double ba;
  final String label;
}

_Pt _encode(Uint8List rgb, int w, int h, VardctL0Config cfg, String label) {
  final encoded = encodeLossyVardctL0(rgb, width: w, height: h, config: cfg);
  final (ss, ba) = _perceptual(encoded, rgb, w, h);
  return _Pt(encoded.length, ss, ba, label);
}

(double, double) _perceptual(
    Uint8List encoded, Uint8List original, int w, int h) {
  final dir = Directory.systemTemp.createTempSync('validate_manga');
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

List<String> _listJxlEntries(String cbzPath) {
  final r = Process.runSync('unzip', ['-Z1', cbzPath]);
  if (r.exitCode != 0) {
    throw ProcessException('unzip', ['-Z1', cbzPath], r.stderr.toString());
  }
  return (r.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.toLowerCase().endsWith('.jxl'))
      .toList()
    ..sort();
}

List<String> _selectPages(List<String> entries, int count) {
  if (count >= entries.length) return entries;
  if (count <= 1) return [entries.first];
  final picked = <String>[];
  for (var i = 0; i < count; i++) {
    final idx = (i * (entries.length - 1) / (count - 1)).round();
    picked.add(entries[idx]);
  }
  return picked;
}

Uint8List _readZipEntry(String zipPath, String entry) {
  final r =
      Process.runSync('unzip', ['-p', zipPath, entry], stdoutEncoding: null);
  if (r.exitCode != 0) {
    throw ProcessException('unzip', ['-p', zipPath, entry], '$r');
  }
  return Uint8List.fromList(r.stdout as List<int>);
}

Uint8List _writePpm(Uint8List rgb, int w, int h) {
  final header = 'P6\n$w $h\n255\n'.codeUnits;
  final out = Uint8List(header.length + rgb.length);
  out.setAll(0, header);
  out.setAll(header.length, rgb);
  return out;
}
