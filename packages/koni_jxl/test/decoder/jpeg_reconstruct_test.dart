@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:koni_jxl/src/jpeg/jbrd_decoder.dart';
import 'package:test/test.dart';

/// JPEG bitstream reconstruction gate (phase 1: baseline grayscale).
///
/// Round-trip: cjpeg -> a baseline grayscale JPEG -> cjxl --lossless_jpeg ->
/// koni `reconstructJpeg` must reproduce the original JPEG byte-for-byte.
/// Skips when the JPEG XL / libjpeg CLI tools are absent.

bool _have(String tool, List<String> versionArgs) {
  try {
    return Process.runSync(tool, versionArgs).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

final _tools = _have('cjxl', ['--version']) &&
    _have('cjpeg', ['-version']) &&
    _have('djxl', ['--version']);

Uint8List _grayPgm(int w, int h, int seed) {
  final out = BytesBuilder();
  out.add('P5\n$w $h\n255\n'.codeUnits);
  final data = Uint8List(w * h);
  var i = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      data[i++] = (x * 7 + y * 13 + (x ^ y) + seed * 3) & 0xFF;
    }
  }
  out.add(data);
  return out.toBytes();
}

void main() {
  group('JPEG reconstruction (grayscale baseline)', () {
    // (width, height, quality, restartMcuBlocks). >2048px cases cross an LF
    // group boundary (exercising the capture's LF-group offset); restart != 0
    // exercises the restart-marker / DC-reset path.
    for (final (w, h, quality, restart) in const [
      (16, 16, 50, 0),
      (16, 16, 85, 0),
      (103, 67, 85, 0),
      (257, 129, 50, 0),
      (320, 200, 85, 0),
      (8, 8, 50, 0),
      (1, 1, 85, 0),
      (2176, 64, 80, 0), // horizontal multi-LF-group
      (64, 2176, 80, 0), // vertical multi-LF-group
      (257, 129, 80, 7), // restart every 7 blocks
      (600, 400, 80, 20), // restart every 20 blocks
    ]) {
      final label = restart == 0 ? '${w}x$h q$quality' : '${w}x$h rst$restart';
      test('$label byte-exact', () {
        final dir = Directory.systemTemp.createTempSync('koni_jbr');
        try {
          final pgm = '${dir.path}/s.pgm';
          final jpg = '${dir.path}/s.jpg';
          final jxl = '${dir.path}/s.jxl';
          File(pgm).writeAsBytesSync(_grayPgm(w, h, quality));

          final cjpegArgs = ['-grayscale', '-quality', '$quality'];
          if (restart != 0) cjpegArgs.addAll(['-restart', '${restart}B']);
          cjpegArgs.addAll(['-outfile', jpg, pgm]);
          final c = Process.runSync('cjpeg', cjpegArgs);
          expect(c.exitCode, 0, reason: 'cjpeg: ${c.stderr}');
          final t = Process.runSync(
              'cjxl', [jpg, jxl, '--lossless_jpeg=1', '-q', '100']);
          expect(t.exitCode, 0, reason: 'cjxl: ${t.stderr}');

          final original = File(jpg).readAsBytesSync();
          final rebuilt =
              JxlDecoder.reconstructJpeg(File(jxl).readAsBytesSync());
          expect(rebuilt, isNotNull, reason: 'no jbrd surfaced');
          expect(rebuilt, orderedEquals(original),
              reason: 'reconstruction not byte-exact');
        } finally {
          dir.deleteSync(recursive: true);
        }
      }, skip: _tools ? false : 'cjxl/cjpeg/djxl not available');
    }

    test('returns null for a non-transcode JXL', () {
      // A plain lossless-encoded image carries no jbrd box.
      final pixels =
          Uint8List.fromList(List.generate(32 * 32, (i) => (i * 5) & 0xFF));
      final encoded = JxlEncoder.encodeLossless(pixels,
          width: 32, height: 32, grayscale: true);
      expect(JxlDecoder.reconstructJpeg(encoded), isNull);
    });

    test('jbrd parser only throws JxlException on crafted input', () {
      // Robustness contract: bitstream-controlled counts/sizes must never
      // trigger unbounded allocation or non-JxlException errors. Small crafted
      // payloads can declare huge marker/tail sizes; parsing must bound them.
      final rng = math.Random(1234);
      for (var iter = 0; iter < 2000; iter++) {
        final len = 4 + rng.nextInt(60);
        final payload =
            Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
        try {
          decodeJbrd(payload);
        } on JxlException {
          // Acceptable.
        }
      }
    });
  });
}
