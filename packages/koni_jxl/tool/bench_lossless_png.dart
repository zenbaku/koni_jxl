import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Benchmarks this package's lossless (modular) encoder against the source
/// **PNG** and against `cjxl -e7`, on a directory of real PNG images — a
/// lossless-vs-lossless comparison on identical pixels (the fair test that
/// [bench_lossless_vs_cjxl.dart]'s cjxl-only comparison and, historically, a
/// blundered lossless-vs-lossy-JPEG comparison both lacked).
///
/// Reproduction, e.g. the public `test-images/png` 202105 set:
/// ```
/// git clone --depth 1 https://github.com/test-images/png.git
/// cd png/202105
/// for f in *.png; do magick "$f" "${f%.png}.ppm"; done   # or a Pillow loop
/// dart run tool/bench_lossless_png.dart <that-dir>
/// ```
/// Each `.ppm` is koni-encoded (and decoded back, asserted bit-exact); `cjxl`
/// runs on the same `.ppm`; the `.png` sibling supplies the source-PNG size.
/// Percentages are koni's size relative to each baseline: under 100% means
/// koni is smaller. AOT-compile for stable `encode-ms` (see the note in
/// [bench_lossless_vs_cjxl.dart]).
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: bench_lossless_png.dart <dir-with-.ppm-and-.png>');
    exitCode = 2;
    return;
  }
  final dir = Directory(args[0]);
  final ppms = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ppm'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (ppms.isEmpty) {
    stderr
        .writeln('no .ppm files in ${dir.path} (convert the .png files first)');
    return;
  }

  var totKoni = 0, totPng = 0, totCjxl = 0, rtFail = 0;
  stdout.writeln('image                       png     koni    cjxl-e7  '
      'koni/png  koni/cjxl');
  for (final f in ppms) {
    final name = f.path.split('/').last.replaceAll('.ppm', '');
    final pnm = _readPpm(f.readAsBytesSync());
    final koni =
        JxlEncoder.encodeLossless(pnm.$3, width: pnm.$1, height: pnm.$2);
    if (!_bitExactRt(koni, pnm)) {
      rtFail++;
    }
    final pngFile = File('${dir.path}/$name.png');
    final png = pngFile.existsSync() ? pngFile.lengthSync() : 0;
    final cjxl = _cjxl(f.path);
    totKoni += koni.length;
    totPng += png;
    totCjxl += cjxl;
    stdout.writeln('${name.padRight(22)} '
        '${png.toString().padLeft(8)} ${koni.length.toString().padLeft(8)} '
        '${cjxl.toString().padLeft(8)}  '
        '${_pct(koni.length, png).padLeft(7)}  ${_pct(koni.length, cjxl).padLeft(8)}');
  }
  stdout.writeln('${"TOTAL".padRight(22)} '
      '${totPng.toString().padLeft(8)} ${totKoni.toString().padLeft(8)} '
      '${totCjxl.toString().padLeft(8)}  '
      '${_pct(totKoni, totPng).padLeft(7)}  ${_pct(totKoni, totCjxl).padLeft(8)}');
  if (rtFail > 0) {
    stderr.writeln('WARNING: $rtFail images failed the bit-exact round-trip');
    exitCode = 1;
  }
}

String _pct(int a, int b) =>
    b == 0 ? '-' : '${(a / b * 100).toStringAsFixed(0)}%';

int _cjxl(String ppmPath) {
  final out = '${Directory.systemTemp.createTempSync('bl_png').path}/o.jxl';
  try {
    final r = Process.runSync(
        'cjxl', [ppmPath, out, '-d', '0', '-e', '7', '--num_threads', '0']);
    if (r.exitCode != 0) return 0;
    return File(out).lengthSync();
  } on ProcessException {
    return 0;
  }
}

bool _bitExactRt(Uint8List encoded, (int, int, Uint8List) pnm) {
  final decoded = JxlDecoder.decode(encoded).toRgba8();
  final n = pnm.$1 * pnm.$2;
  for (var p = 0; p < n; p++) {
    for (var c = 0; c < 3; c++) {
      if (decoded[p * 4 + c] != pnm.$3[p * 3 + c]) return false;
    }
  }
  return true;
}

(int, int, Uint8List) _readPpm(Uint8List d) {
  var i = 0;
  String tok() {
    while (d[i] == 32 || d[i] == 10 || d[i] == 13) {
      i++;
    }
    final s = i;
    while (d[i] != 32 && d[i] != 10 && d[i] != 13) {
      i++;
    }
    return String.fromCharCodes(d, s, i);
  }

  final magic = tok();
  if (magic != 'P6') throw FormatException('expected P6 PPM, got $magic');
  final w = int.parse(tok());
  final h = int.parse(tok());
  tok();
  i++;
  return (w, h, Uint8List.sublistView(d, i));
}
