import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Real-manga ROI evaluation for the off-by-default transform-selection
/// knobs (`enableRectangularTransforms`, `enableBespokeTransforms`,
/// `maxTransformSize` beyond 16) — see ROADMAP.md's "Next phase" and
/// doc/BENCHMARKS.md's "Real-world manga chapters" section for why this
/// exists: round 7's DCT32x32 evaluation (synthetic corpus wins of
/// -7.6% to -16.7% collapsed to -0.0% to -0.6% on real pages) was a
/// one-off, undocumented process; this tool makes that check repeatable
/// for every knob, not just the one round 7 happened to test.
///
/// `manga_samples/*.cbz` (gitignored, copyrighted — never committed, no
/// fixtures derived from them belong in this repo) are zip archives of
/// `.jxl` files directly (not JPEG/PNG) — `doc/BENCHMARKS.md` already
/// established these decode within 1/255 max pixel diff vs `djxl` across
/// all 34 pages, so this tool trusts this package's own `JxlDecoder` for
/// source pixels (same pattern as `tool/reencode_lossless.dart`), needing
/// only `unzip` (already required, same shell-out spirit as `cjxl`/`djxl`)
/// to pull individual page bytes out of the archive — no PNG/JPEG decode,
/// no new dependency, no intermediate files.
///
/// Usage: `dart run tool/bench_manga_roi.dart [--pages=N] [cbz files...]`
/// (defaults to both `manga_samples/*.cbz` chapters, 6 pages each spread
/// across the chapter). AOT-compile for real timing numbers, same as
/// every other `bench_*` tool here:
/// `dart compile exe tool/bench_manga_roi.dart -o /tmp/bmr && /tmp/bmr`
void main(List<String> rawArgs) {
  var pages = 6;
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

  final grandTotals = {for (final c in _combos) c.name: 0};

  for (final cbzPath in cbzPaths) {
    if (!File(cbzPath).existsSync()) {
      stderr.writeln('skip (not found): $cbzPath');
      continue;
    }
    final entries = _listJxlEntries(cbzPath);
    if (entries.isEmpty) {
      stderr.writeln('skip (no .jxl entries): $cbzPath');
      continue;
    }
    final selected = _selectPages(entries, pages);
    print('\n=== $cbzPath (${entries.length} pages, using $pages) ===');

    for (final distance in [1.0, 4.0]) {
      print('\n-- distance $distance --');
      print('page                 combo              bytes    '
          'delta-vs-base   rmse');
      final chapterTotals = {for (final c in _combos) c.name: 0};
      var baselineTotal = 0;

      for (final entry in selected) {
        final bytes = _readZipEntry(cbzPath, entry);
        final image = JxlDecoder.decode(bytes);
        final rgba = image.toRgba8();
        final rgb = Uint8List(image.width * image.height * 3);
        for (var i = 0; i < image.width * image.height; i++) {
          rgb[i * 3] = rgba[i * 4];
          rgb[i * 3 + 1] = rgba[i * 4 + 1];
          rgb[i * 3 + 2] = rgba[i * 4 + 2];
        }

        var baselineBytes = 0;
        var baselineRmse = 0.0;
        for (final combo in _combos) {
          final config = combo.configFor(distance);
          final sw = Stopwatch()..start();
          final encoded = JxlEncoder.encodeLossy(rgb,
              width: image.width, height: image.height, config: config);
          sw.stop();
          final rmse = _decodeAndRmse(encoded, rgb, image.width, image.height);
          if (combo.name == 'baseline') {
            baselineBytes = encoded.length;
            baselineRmse = rmse;
          }
          final delta = (encoded.length - baselineBytes) / baselineBytes * 100;
          // Flag a combo only if it's a genuine *regression vs. this
          // page's own baseline RMSE* (the never-worse safety net's
          // promise is relative, not an absolute threshold — absolute
          // RMSE is expected to grow with distance regardless of combo,
          // see doc/BENCHMARKS.md's own gray_screentone numbers). This is
          // what would catch round 16's flagged gap (a combo-induced
          // RMSE jump), not ordinary distance-driven RMSE growth.
          final warn = rmse > baselineRmse * 1.05 + 0.05
              ? '  ** RMSE regression vs baseline (${baselineRmse.toStringAsFixed(2)}) **'
              : '';
          print('${entry.padRight(20)} ${combo.name.padRight(18)} '
              '${encoded.length.toString().padLeft(8)}  '
              '${(combo.name == 'baseline' ? '  (base)' : '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)}%').padLeft(13)}  '
              '${rmse.toStringAsFixed(2).padLeft(6)}'
              '$warn (${sw.elapsedMilliseconds}ms)');
          chapterTotals[combo.name] =
              chapterTotals[combo.name]! + encoded.length;
          if (combo.name == 'baseline') baselineTotal += encoded.length;
        }
      }

      print('-- chapter total (distance $distance) --');
      for (final combo in _combos) {
        final total = chapterTotals[combo.name]!;
        final delta = (total - baselineTotal) / baselineTotal * 100;
        print('  ${combo.name.padRight(18)} ${total.toString().padLeft(9)}  '
            '${combo.name == 'baseline' ? '(base)' : '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)}%'}');
        grandTotals[combo.name] = grandTotals[combo.name]! + total;
      }
    }
  }

  print('\n=== grand total across all chapters/distances ===');
  final baseGrand = grandTotals['baseline']!;
  for (final combo in _combos) {
    final total = grandTotals[combo.name]!;
    final delta = (total - baseGrand) / baseGrand * 100;
    print('  ${combo.name.padRight(18)} ${total.toString().padLeft(10)}  '
        '${combo.name == 'baseline' ? '(base)' : '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(2)}%'}');
  }
}

class _Combo {
  const _Combo(this.name,
      {this.rect = false, this.bespoke = false, this.maxSize = 16});
  final String name;
  final bool rect;
  final bool bespoke;
  final int maxSize;

  VardctL0Config configFor(double distance) {
    final base = VardctL0Config.fromDistance(distance);
    return VardctL0Config(
      quantLF: base.quantLF,
      acScale: base.acScale,
      enableRectangularTransforms: rect,
      enableBespokeTransforms: bespoke,
      maxTransformSize: maxSize,
    );
  }
}

const _combos = [
  _Combo('baseline'),
  _Combo('+rect', rect: true),
  _Combo('+bespoke', bespoke: true),
  _Combo('+rect+bespoke', rect: true, bespoke: true),
  _Combo('+32', maxSize: 32),
  _Combo('+32+rect+bespoke', rect: true, bespoke: true, maxSize: 32),
];

/// Lists `.jxl` entries in a CBZ (a plain zip archive) via `unzip -Z1`
/// (names only, one per line), sorted for deterministic page order.
List<String> _listJxlEntries(String cbzPath) {
  final r = Process.runSync('unzip', ['-Z1', cbzPath]);
  if (r.exitCode != 0) {
    throw ProcessException('unzip', ['-Z1', cbzPath], r.stderr.toString());
  }
  final names = (r.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.toLowerCase().endsWith('.jxl'))
      .toList()
    ..sort();
  return names;
}

/// Picks [count] entries evenly spread across the chapter (first to last
/// page inclusive), not just the front pages.
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

/// Reads one entry's raw bytes out of a zip archive via `unzip -p`
/// (streams the extracted file to stdout) — `stdoutEncoding: null` is
/// required so binary `.jxl` content isn't mangled through a text codec.
Uint8List _readZipEntry(String zipPath, String entry) {
  final r =
      Process.runSync('unzip', ['-p', zipPath, entry], stdoutEncoding: null);
  if (r.exitCode != 0) {
    throw ProcessException('unzip', ['-p', zipPath, entry], '$r');
  }
  return Uint8List.fromList(r.stdout as List<int>);
}

double _decodeAndRmse(
    Uint8List encoded, Uint8List original, int width, int height) {
  final dir = Directory.systemTemp.createTempSync('bench_manga_roi');
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

/// Minimal binary PPM (P6) reader, matching `bench_lossy_vs_cjxl.dart`'s.
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
  final width = int.parse(token());
  final height = int.parse(token());
  final maxValue = int.parse(token());
  i++; // single whitespace byte after maxValue
  if (magic != 'P6') throw FormatException('expected P6 PPM, got $magic');
  if (maxValue != 255) throw FormatException('expected 8-bit PPM');
  return (width, height, Uint8List.sublistView(data, i));
}
