import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// One-off check for `JxlPagePrefetcher`'s cancellation design: does
/// `Isolate.kill(priority: Isolate.immediate)` actually interrupt an
/// in-progress CPU-bound decode promptly, or does the isolate run to
/// completion regardless (the VM only checks for a kill at certain
/// safepoints, not continuously)? Spawns a decode of the largest available
/// file, waits a short delay, kills it, and times how long the kill
/// request takes to actually take effect (via the isolate's exit port)
/// versus how long the decode would have taken to finish on its own.
void _decodeEntryPoint((SendPort, Uint8List) args) {
  final (port, bytes) = args;
  final sw = Stopwatch()..start();
  final image = JxlDecoder.decode(bytes);
  image.toRgba8();
  port.send(sw.elapsedMilliseconds);
}

void main(List<String> args) async {
  final path = args.isNotEmpty
      ? args[0]
      : 'third_party/corpus/jxl/gray_screentone_d0.5_e1.jxl';
  final bytes = File(path).readAsBytesSync();

  // Baseline: how long does an uninterrupted decode actually take?
  final baselineSw = Stopwatch()..start();
  JxlDecoder.decode(bytes).toRgba8();
  baselineSw.stop();
  print('uninterrupted decode: ${baselineSw.elapsedMilliseconds} ms');

  for (final killDelayMs in [1, 5, 20, 50]) {
    final resultPort = ReceivePort();
    final exitPort = ReceivePort();
    var exited = false;
    var completedNormally = false;
    exitPort.listen((_) => exited = true);
    resultPort.listen((_) => completedNormally = true);

    final spawnSw = Stopwatch()..start();
    final isolate = await Isolate.spawn(
      _decodeEntryPoint,
      (resultPort.sendPort, bytes),
      onExit: exitPort.sendPort,
    );
    await Future<void>.delayed(Duration(milliseconds: killDelayMs));
    final killSw = Stopwatch()..start();
    isolate.kill(priority: Isolate.immediate);
    while (!exited &&
        killSw.elapsedMilliseconds < baselineSw.elapsedMilliseconds * 3) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    killSw.stop();
    spawnSw.stop();
    resultPort.close();
    exitPort.close();
    print('kill after ${killDelayMs}ms in-flight: isolate died '
        '${killSw.elapsedMilliseconds}ms after kill() '
        '(completedNormally=$completedNormally, total wall '
        '${spawnSw.elapsedMilliseconds}ms vs uninterrupted '
        '${baselineSw.elapsedMilliseconds}ms)');
  }
}
