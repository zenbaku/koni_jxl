import 'dart:io';

import 'package:koni_jxl/koni_jxl.dart';

/// Decode-speed benchmark: this decoder vs. `djxl`, across the generated
/// corpus (or explicit files given on the command line).
///
/// For real, reproducible numbers, compile to AOT first — `dart run` uses
/// the JIT, which does not match the AOT figures quoted in the READMEs:
///
///   dart compile exe tool/bench_decode.dart -o /tmp/bench_decode
///   /tmp/bench_decode
///
/// Flags: `--reps=N` (default 10), `--warmup=N` (default 3), `--no-djxl`
/// (skip the djxl comparison column). Corpus files smaller than 0.1 MP
/// (the `odd_*` edge-case fixtures) are skipped — too small for a stable
/// throughput number.
///
/// The djxl column times `Process.runSync` end to end, which includes
/// process fork/exec and PPM file I/O — a fixed cost that is a larger
/// fraction of djxl's very fast decodes than of this decoder's, so the
/// ours/djxl ratio understates djxl's actual decode-only speed.
void main(List<String> args) {
  var reps = 10;
  var warmup = 3;
  var withDjxl = true;
  final files = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--reps=')) {
      reps = int.parse(arg.substring('--reps='.length));
    } else if (arg.startsWith('--warmup=')) {
      warmup = int.parse(arg.substring('--warmup='.length));
    } else if (arg == '--no-djxl') {
      withDjxl = false;
    } else {
      files.add(arg);
    }
  }

  if (files.isEmpty) {
    final corpusDir = Directory('../../third_party/corpus/jxl');
    if (!corpusDir.existsSync()) {
      stderr.writeln(
          'no files given and third_party/corpus not found; run tool/gen_corpus.py first');
      exit(1);
    }
    files.addAll(corpusDir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.endsWith('_e7.jxl'))
        .toList()
      ..sort());
  }

  if (withDjxl) {
    withDjxl = _haveDjxl();
    if (!withDjxl) stderr.writeln('djxl not on PATH, skipping comparison');
  }

  print('warmup=$warmup reps=$reps (times are medians)');
  print('');
  final header = withDjxl
      ? 'file                                 dims        MPix  mode      ours ms   ours MP/s  djxl ms  ours/djxl'
      : 'file                                 dims        MPix  mode      ours ms   ours MP/s';
  print(header);

  for (final path in files) {
    final bytes = File(path).readAsBytesSync();
    final info = JxlInfo.parse(bytes);
    final mpix = info.width * info.height / 1e6;
    if (mpix < 0.1) continue;
    final mode = path.contains('_d0_') || path.endsWith('_d0.jxl')
        ? 'lossless'
        : 'lossy';

    final oursMs = _median(_timedRunsMs(() => JxlDecoder.decode(bytes),
        warmup: warmup, reps: reps));
    final oursMps = mpix / (oursMs / 1000.0);

    final name = path.split('/').last;
    final dims = '${info.width}x${info.height}';
    final row = StringBuffer()
      ..write(name.padRight(37))
      ..write(dims.padRight(12))
      ..write(mpix.toStringAsFixed(2).padLeft(5))
      ..write('  ')
      ..write(mode.padRight(9))
      ..write(oursMs.toStringAsFixed(1).padLeft(8))
      ..write('  ')
      ..write(oursMps.toStringAsFixed(1).padLeft(9));

    if (withDjxl) {
      final djxlMs =
          _median(_timedDjxlRunsMs(path, warmup: warmup, reps: reps));
      row
        ..write('  ')
        ..write(djxlMs.toStringAsFixed(1).padLeft(7))
        ..write('  ')
        ..write((oursMs / djxlMs).toStringAsFixed(1).padLeft(9));
    }
    print(row.toString());
  }
}

bool _haveDjxl() {
  try {
    return Process.runSync('djxl', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
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

List<int> _timedDjxlRunsMs(String jxlPath,
    {required int warmup, required int reps}) {
  final dir = Directory.systemTemp.createTempSync('bench_djxl');
  try {
    // .pam handles any channel count/bit depth uniformly (RGB, gray, alpha,
    // 16-bit) so one code path covers the whole corpus.
    final outPath = '${dir.path}/out.pam';
    void run() {
      final r = Process.runSync(
          'djxl', [jxlPath, outPath, '--num_threads', '1'],
          runInShell: false);
      if (r.exitCode != 0) {
        throw ProcessException('djxl', [jxlPath], '${r.stderr}');
      }
    }

    return _timedRunsMs(run, warmup: warmup, reps: reps);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

double _median(List<int> sortedMicros) =>
    sortedMicros[sortedMicros.length ~/ 2] / 1000.0;
