import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// Encoder gate: every encoded file must decode bit-exact through BOTH our
/// decoder and djxl.

Uint8List _synthetic(int width, int height, int channels, int seed) {
  final rng = math.Random(seed);
  final out = Uint8List(width * height * channels);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < channels; c++) {
        final v = switch ((x ~/ 16 + y ~/ 16 + c) % 4) {
          0 => (x * 3 + y * 7 + c * 31) & 255, // gradients
          1 => (x ^ y) & 1 == 0 ? 255 : 0, // screentone
          2 => rng.nextInt(256), // noise
          _ => 200, // flat
        };
        out[i++] = v;
      }
    }
  }
  return out;
}

final _haveDjxl = (() {
  try {
    return Process.runSync('djxl', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
})();

void _check(int width, int height,
    {bool grayscale = false, bool hasAlpha = false, int seed = 7}) {
  final channels = (grayscale ? 1 : 3) + (hasAlpha ? 1 : 0);
  final pixels = _synthetic(width, height, channels, seed);
  final encoded = JxlEncoder.encodeLossless(pixels,
      width: width, height: height, grayscale: grayscale, hasAlpha: hasAlpha);

  // Our decoder: bit-exact.
  final image = JxlDecoder.decode(encoded);
  expect(image.width, width);
  expect(image.height, height);
  for (var c = 0; c < channels; c++) {
    final ours = channelAsInts(image.channels[c], 255);
    for (var i = 0; i < width * height; i++) {
      if (ours[i] != pixels[i * channels + c]) {
        fail('our decoder mismatch at px $i channel $c: '
            '${ours[i]} != ${pixels[i * channels + c]}');
      }
    }
  }

  // djxl: bit-exact.
  if (_haveDjxl) {
    final dir = Directory.systemTemp.createTempSync('koni_enc');
    try {
      final jxlPath = '${dir.path}/t.jxl';
      final outPath =
          '${dir.path}/t.${hasAlpha ? 'pam' : (grayscale ? 'pgm' : 'ppm')}';
      File(jxlPath).writeAsBytesSync(encoded);
      final r =
          Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: 'djxl failed: ${r.stderr}');
      final ref = PnmImage.parse(File(outPath).readAsBytesSync());
      expect(ref.width, width);
      expect(ref.height, height);
      for (var c = 0; c < channels; c++) {
        final theirs = ref.intPlanes![c];
        for (var i = 0; i < width * height; i++) {
          if (theirs[i] != pixels[i * channels + c]) {
            fail('djxl mismatch at px $i channel $c: '
                '${theirs[i]} != ${pixels[i * channels + c]}');
          }
        }
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }
}

void main() {
  test('single-group images', () {
    _check(8, 8);
    _check(256, 256);
    _check(1, 1);
    _check(255, 3, grayscale: true);
  });

  test('multi-group images', () {
    _check(257, 100);
    _check(511, 300, grayscale: true);
    _check(300, 511);
    _check(1000, 600, seed: 42);
  });

  test('alpha', () {
    _check(100, 100, hasAlpha: true);
    _check(300, 300, hasAlpha: true);
  });
}
