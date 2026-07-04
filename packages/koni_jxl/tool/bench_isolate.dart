import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Measures the overhead of moving a page decode onto a fresh isolate
/// (`Isolate.run`, what `compute()` uses on native under the hood) versus
/// decoding synchronously, and whether N concurrent decodes actually
/// scale across cores — informs whether a multi-page prefetch pool is
/// worth building for a manga-reader "decode next few pages ahead" UX.
Uint8List _decodeToRgba(Uint8List bytes) {
  final image = JxlDecoder.decode(bytes);
  return image.toRgba8();
}

void main(List<String> args) async {
  final path = args.isNotEmpty
      ? args[0]
      : 'third_party/corpus/jxl/color_cover_d1.0_e7.jxl';
  final bytes = File(path).readAsBytesSync();
  const reps = 8;

  // Warm up (JIT/AOT paths, file cache).
  _decodeToRgba(bytes);

  final syncSw = Stopwatch()..start();
  for (var i = 0; i < reps; i++) {
    _decodeToRgba(bytes);
  }
  syncSw.stop();
  final syncMs = syncSw.elapsedMilliseconds / reps;
  print('sync decode:            ${syncMs.toStringAsFixed(1)} ms/rep');

  final isoSw = Stopwatch()..start();
  for (var i = 0; i < reps; i++) {
    await Isolate.run(() => _decodeToRgba(bytes));
  }
  isoSw.stop();
  final isoMs = isoSw.elapsedMilliseconds / reps;
  print('Isolate.run decode:      ${isoMs.toStringAsFixed(1)} ms/rep '
      '(overhead: ${(isoMs - syncMs).toStringAsFixed(1)} ms/rep)');

  for (final n in [2, 3, 4, 6, 8]) {
    final parSw = Stopwatch()..start();
    await Future.wait(
        [for (var i = 0; i < n; i++) Isolate.run(() => _decodeToRgba(bytes))]);
    parSw.stop();
    final totalMs = parSw.elapsedMilliseconds;
    print('$n concurrent Isolate.run: ${totalMs}ms total '
        '(${(totalMs / n).toStringAsFixed(1)} ms/decode-equivalent, '
        'ideal ${isoMs.toStringAsFixed(0)}ms if perfectly parallel)');
  }

  print('CPU cores: ${Platform.numberOfProcessors}');
}
