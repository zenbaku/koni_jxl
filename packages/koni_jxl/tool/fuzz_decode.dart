import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Mutation fuzzer for the decoder surfaces.
///
/// Contract under test: any input either decodes or throws a [JxlException].
/// Anything else (RangeError, StateError, TypeError, hangs, OOM) is a bug.
///
/// Usage: `fuzz_decode <baseSeed> <count> [--save-failures <dir>]`
/// Prints one line per failure: `FAIL <caseSeed> <api> <errorType>: <error>`.

late final List<Uint8List> seedFiles;

Uint8List mutate(math.Random rng, Uint8List src) {
  final kind = rng.nextInt(10);
  if (kind == 0) {
    // Pure garbage (occasionally with a valid signature prefix).
    final n = 16 + rng.nextInt(4096);
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = rng.nextInt(256);
    }
    if (rng.nextBool()) {
      out[0] = 0xFF;
      out[1] = 0x0A;
    }
    return out;
  }
  var data = Uint8List.fromList(src);
  if (kind <= 3) {
    // Truncate.
    data = Uint8List.sublistView(data, 0, 1 + rng.nextInt(data.length));
    if (kind == 1) return data; // truncation only
  }
  final mutations = 1 + rng.nextInt(24);
  for (var m = 0; m < mutations; m++) {
    switch (rng.nextInt(4)) {
      case 0: // bit flip
        final i = rng.nextInt(data.length);
        data[i] ^= 1 << rng.nextInt(8);
      case 1: // random byte
        data[rng.nextInt(data.length)] = rng.nextInt(256);
      case 2: // zero a short range
        final i = rng.nextInt(data.length);
        final end = math.min(data.length, i + 1 + rng.nextInt(32));
        data.fillRange(i, end, 0);
      case 3: // 0xFF a short range
        final i = rng.nextInt(data.length);
        final end = math.min(data.length, i + 1 + rng.nextInt(32));
        data.fillRange(i, end, 0xFF);
    }
  }
  return data;
}

final failures = <(int, String, Object)>[];

void tryApi(int caseSeed, String api, void Function() body) {
  try {
    body();
  } on JxlException {
    // Expected for malformed input.
  } catch (e, st) {
    failures.add((caseSeed, api, e));
    stdout.writeln('FAIL $caseSeed $api ${e.runtimeType}: '
        '${e.toString().split('\n').first}');
    if (Platform.environment['FUZZ_STACKS'] == '1') {
      stdout.writeln(st.toString().split('\n').take(6).join('\n'));
    }
  }
}

void runCase(int caseSeed) {
  final rng = math.Random(caseSeed);
  final data = mutate(rng, seedFiles[rng.nextInt(seedFiles.length)]);

  tryApi(caseSeed, 'info', () => JxlInfo.parse(data));
  tryApi(caseSeed, 'decode', () => JxlDecoder.decode(data));
  if (caseSeed % 4 == 0) {
    tryApi(caseSeed, 'animation', () => JxlDecoder.decodeAnimation(data));
  }
  tryApi(caseSeed, 'streaming', () {
    final dec = JxlStreamingDecoder();
    final chunk = 1 + rng.nextInt(4096);
    for (var off = 0; off < data.length; off += chunk) {
      dec.addBytes(
          Uint8List.sublistView(data, off, math.min(off + chunk, data.length)));
      dec.state;
      dec.progress;
      dec.info;
      if (dec.state.index >= JxlStreamState.dcReady.index) {
        dec.decodePreview();
      }
    }
    if (dec.state == JxlStreamState.complete) {
      dec.decodeFinal();
    }
  });
}

void main(List<String> args) {
  final baseSeed = int.parse(args[0]);
  final count = int.parse(args[1]);
  final saveDir = args.length > 3 && args[2] == '--save-failures'
      ? Directory(args[3])
      : null;

  final corpusDir = Directory('../../third_party/corpus/jxl');
  final conformanceDir = Directory('../../third_party/conformance/testcases');
  final paths = <String>[
    '${corpusDir.path}/screentone_256_d0_e5.jxl',
    '${corpusDir.path}/color_cover_d0_e2.jxl',
    '${corpusDir.path}/color_cover_d1.0_e7.jxl',
    '${corpusDir.path}/gray_screentone_d1.0_e5_progdc2.jxl',
    '${corpusDir.path}/anim_d0.jxl',
    '${corpusDir.path}/alpha_page_d0_e3.jxl',
    '${conformanceDir.path}/animation_spline/input.jxl',
    '${conformanceDir.path}/cafe/input.jxl',
    '${conformanceDir.path}/patches_lossless/input.jxl',
  ];
  seedFiles = [
    for (final p in paths)
      if (File(p).existsSync()) File(p).readAsBytesSync(),
  ];
  if (seedFiles.isEmpty) {
    stderr.writeln('no seed files found (generate the corpus first)');
    exit(2);
  }

  final markerPath = Platform.environment['FUZZ_MARKER'];
  final marker = markerPath != null ? File(markerPath) : null;
  for (var i = 0; i < count; i++) {
    final caseSeed = baseSeed + i;
    marker?.writeAsStringSync('$caseSeed');
    runCase(caseSeed);
    if (saveDir != null && failures.isNotEmpty) {
      saveDir.createSync(recursive: true);
      final rng = math.Random(caseSeed);
      final data = mutate(rng, seedFiles[rng.nextInt(seedFiles.length)]);
      File('${saveDir.path}/case_$caseSeed.jxl').writeAsBytesSync(data);
      failures.clear();
    }
  }
  stdout.writeln('done: $count cases');
}
