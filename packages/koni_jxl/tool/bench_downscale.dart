import 'dart:io';

import 'package:koni_jxl/koni_jxl.dart';

/// Decode-speed comparison: full decode vs. `JxlDecoder.decode`'s
/// `targetWidth`/`targetHeight` reduced-resolution path, on given file(s).
///
/// Demonstrates the DC-only fast path's actual CPU saving on an oversized
/// image — the case it exists for (a page far larger than anything a reader
/// will ever display). For real, reproducible numbers, compile to AOT first:
///
///   dart compile exe tool/bench_downscale.dart -o /tmp/bench_downscale
///   /tmp/bench_downscale --target=512 file1.jxl file2.jxl ...
///
/// Flags: `--target=N` (target width/height box, default 512), `--reps=N`
/// (default 10), `--warmup=N` (default 3).
void main(List<String> args) {
  var reps = 10;
  var warmup = 3;
  var target = 512;
  final files = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--reps=')) {
      reps = int.parse(arg.substring('--reps='.length));
    } else if (arg.startsWith('--warmup=')) {
      warmup = int.parse(arg.substring('--warmup='.length));
    } else if (arg.startsWith('--target=')) {
      target = int.parse(arg.substring('--target='.length));
    } else {
      files.add(arg);
    }
  }

  if (files.isEmpty) {
    stderr.writeln('usage: bench_downscale [--target=N] file.jxl ...');
    exit(1);
  }

  print('warmup=$warmup reps=$reps target=${target}px (times are medians)');
  print('');
  print('file                                 dims        full ms   '
      'target ms   speedup');

  for (final path in files) {
    final bytes = File(path).readAsBytesSync();
    final info = JxlInfo.parse(bytes);

    final fullMs = _median(_timedRunsMs(() => JxlDecoder.decode(bytes),
        warmup: warmup, reps: reps));
    final targetMs = _median(_timedRunsMs(
        () =>
            JxlDecoder.decode(bytes, targetWidth: target, targetHeight: target),
        warmup: warmup,
        reps: reps));

    final name = path.split('/').last;
    final dims = '${info.width}x${info.height}';
    final row = StringBuffer()
      ..write(name.padRight(37))
      ..write(dims.padRight(12))
      ..write(fullMs.toStringAsFixed(1).padLeft(8))
      ..write('  ')
      ..write(targetMs.toStringAsFixed(1).padLeft(9))
      ..write('  ')
      ..write('${(fullMs / targetMs).toStringAsFixed(1)}x'.padLeft(8));
    print(row.toString());
  }
}

List<int> _timedRunsMs(void Function() body,
    {required int warmup, required int reps}) {
  for (var i = 0; i < warmup; i++) {
    body();
  }
  final micros = <int>[];
  for (var i = 0; i < reps; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    micros.add(sw.elapsedMicroseconds);
  }
  micros.sort();
  return micros;
}

double _median(List<int> sortedMicros) =>
    sortedMicros[sortedMicros.length ~/ 2] / 1000.0;
