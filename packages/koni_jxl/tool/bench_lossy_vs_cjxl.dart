import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Benchmarks this package's lossy (VarDCT) encoder against `cjxl` at
/// matched `distance` values: file size, RMSE (both decoded via `djxl`
/// and compared to the true source pixels), and wall-clock encode time.
///
/// This encoder has no rate-distortion search (no mode decisions beyond
/// the adaptive quantization/CfL/transform-size heuristics already
/// documented in doc/spec_notes.md) — cjxl's low-effort settings (`-e 1`)
/// are the closer comparison point; higher efforts show how much
/// headroom a real RD search leaves on the table.
///
/// Usage: `dart run tool/bench_lossy_vs_cjxl.dart [ppm files...]`
/// (defaults to the corpus's two RGB `_d0_` goldens if none are given —
/// run `tool/gen_corpus.py` first).
void main(List<String> args) {
  final inputs = args.isNotEmpty
      ? args
      : [
          '../../third_party/corpus/golden/color_cover_d0_e7.ppm',
          '../../third_party/corpus/golden/palette16_d0_e7.ppm',
        ];

  for (final path in inputs) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('skip (not found): $path');
      continue;
    }
    final (width, height, pixels) = _readPpm(file.readAsBytesSync());
    print('\n=== $path (${width}x$height) ===');
    print('distance  encoder    bytes   size-ratio  rmse    encode-ms');
    for (final distance in [0.5, 1.0, 2.0, 4.0, 8.0]) {
      final ours = _runOurs(pixels, width, height, distance);
      final cjxlE1 = _runCjxl(path, width, height, pixels, distance, effort: 1);
      final cjxlE7 = _runCjxl(path, width, height, pixels, distance, effort: 7);
      final baseline = cjxlE1?.bytes ?? ours.bytes;
      void row(String name, _Result? r) {
        if (r == null) {
          print('  $distance    $name: (unavailable, is cjxl/djxl on PATH?)');
          return;
        }
        final ratio = r.bytes / baseline;
        print('  ${distance.toString().padRight(6)}  '
            '${name.padRight(9)} ${r.bytes.toString().padLeft(7)}  '
            '${ratio.toStringAsFixed(2).padLeft(8)}x  '
            '${r.rmse.toStringAsFixed(2).padLeft(6)}  '
            '${r.encodeMs.toString().padLeft(7)}');
      }

      row('koni_jxl', ours);
      row('cjxl -e1', cjxlE1);
      row('cjxl -e7', cjxlE7);
    }
  }
}

class _Result {
  _Result(this.bytes, this.rmse, this.encodeMs);
  final int bytes;
  final double rmse;
  final int encodeMs;
}

_Result _runOurs(Uint8List pixels, int width, int height, double distance) {
  final sw = Stopwatch()..start();
  final encoded = JxlEncoder.encodeLossy(pixels,
      width: width, height: height, distance: distance);
  sw.stop();
  final rmse = _decodeAndRmse(encoded, pixels, width, height);
  return _Result(encoded.length, rmse, sw.elapsedMilliseconds);
}

_Result? _runCjxl(
    String srcPath, int width, int height, Uint8List pixels, double distance,
    {required int effort}) {
  final dir = Directory.systemTemp.createTempSync('bench_cjxl');
  try {
    final outPath = '${dir.path}/out.jxl';
    final sw = Stopwatch()..start();
    final r = Process.runSync('cjxl', [
      srcPath,
      outPath,
      '-d',
      '$distance',
      '-e',
      '$effort',
      '--num_threads',
      '1',
    ]);
    sw.stop();
    if (r.exitCode != 0) return null;
    final encoded = File(outPath).readAsBytesSync();
    final rmse = _decodeAndRmse(encoded, pixels, width, height);
    return _Result(encoded.length, rmse, sw.elapsedMilliseconds);
  } on ProcessException {
    return null;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

double _decodeAndRmse(
    Uint8List encoded, Uint8List original, int width, int height) {
  final dir = Directory.systemTemp.createTempSync('bench_djxl');
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

/// Minimal binary PPM (P6) reader — just enough for this benchmark's
/// self-generated inputs (comment-free, single-byte-per-sample headers).
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
  i++; // single whitespace byte after maxValue
  return (width, height, Uint8List.sublistView(data, i));
}
