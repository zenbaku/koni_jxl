@TestOn('vm')
library;

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

void _check16(int width, int height,
    {bool grayscale = false, bool hasAlpha = false, int seed = 3}) {
  final channels = (grayscale ? 1 : 3) + (hasAlpha ? 1 : 0);
  final rng = math.Random(seed);
  final pixels = Uint16List(width * height * channels);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = switch (i % 3) {
      0 => (i * 977) & 0xFFFF,
      1 => rng.nextInt(1 << 16),
      _ => 65535,
    };
  }
  final encoded = JxlEncoder.encodeLossless16(pixels,
      width: width, height: height, grayscale: grayscale, hasAlpha: hasAlpha);
  final image = JxlDecoder.decode(encoded);
  for (var c = 0; c < channels; c++) {
    final ours = channelAsInts(image.channels[c], 65535);
    for (var i = 0; i < width * height; i++) {
      if (ours[i] != pixels[i * channels + c]) {
        fail('16-bit mismatch at px $i channel $c');
      }
    }
  }
}

Uint8List _flatColors(int width, int height, int colors) {
  final out = Uint8List(width * height * 3);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final k = ((x ~/ 13) + (y ~/ 11) * 3) % colors;
      out[i++] = (k * 37) & 255;
      out[i++] = (k * 91 + 13) & 255;
      out[i++] = (k * 151 + 7) & 255;
    }
  }
  return out;
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

  test('palette (few distinct colors, incl. >256)', () {
    // >256-color cases exercise the palette path that `_encodeModular`'s
    // try-both-keep-smaller decision opened up (the old hard cap was 256, so
    // flat UI graphics with a few hundred to a few thousand colours — the
    // web-booking case — got no palette and coded ~2x larger). The format's
    // nb_colors field goes to 5376+, and djxl round-trips these, confirming
    // the >256 palette bitstream is spec-legal, not just self-consistent.
    // Sizes are chosen so (w/13)*(h/11) >= colors, i.e. all `colors` distinct
    // values actually appear.
    for (final (w, h, colors) in [
      (100, 80, 4),
      (400, 300, 17),
      (300, 400, 256),
      (400, 300, 512),
      (500, 400, 1000),
    ]) {
      final pixels = _flatColors(w, h, colors);
      final encoded = JxlEncoder.encodeLossless(pixels, width: w, height: h);
      final image = JxlDecoder.decode(encoded);
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(image.channels[c], 255);
        for (var i = 0; i < w * h; i++) {
          if (ours[i] != pixels[i * 3 + c]) {
            fail('palette mismatch at px $i channel $c ($colors colors)');
          }
        }
      }
      if (_haveDjxl) {
        final dir = Directory.systemTemp.createTempSync('koni_enc');
        try {
          final jxlPath = '${dir.path}/t.jxl';
          final outPath = '${dir.path}/t.ppm';
          File(jxlPath).writeAsBytesSync(encoded);
          final r =
              Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
          expect(r.exitCode, 0, reason: 'djxl: ${r.stderr}');
          final ref = PnmImage.parse(File(outPath).readAsBytesSync());
          for (var c = 0; c < 3; c++) {
            final theirs = ref.intPlanes![c];
            for (var i = 0; i < w * h; i++) {
              if (theirs[i] != pixels[i * 3 + c]) {
                fail('djxl palette mismatch at px $i channel $c');
              }
            }
          }
        } finally {
          dir.deleteSync(recursive: true);
        }
      }
    }
  });

  test('grayscale palette (sparse few-value single channel)', () {
    // Bilevel / few-value grayscale (fractals, line art) used to skip palette
    // entirely and code raw 0/255 values, whose gradient residuals are ±255
    // tokens; the single-channel (num_c=1) palette remaps them to a dense index
    // whose residuals are ±1. Each layout below is *sparse* (few distinct values
    // spread across 0..255) so `_grayPaletteWorthTrying` fires; the round-trip
    // proves the num_c=1 palette bitstream is spec-legal (djxl) and self-exact.
    for (final (w, h, values) in [
      (200, 160, [0, 255]), // bilevel — the sierpinski/dla case
      (200, 160, [0, 64, 128, 255]),
      (300, 200, [for (var i = 0; i < 30; i++) i * 8]), // 30 sparse values
    ]) {
      final pixels = Uint8List(w * h);
      for (var i = 0; i < pixels.length; i++) {
        // Structured (not pure noise) so gradient prediction leaves the sparse
        // structure a palette can exploit, matching the real content.
        final idx = ((i ~/ w) ~/ 3 + (i % w) ~/ 5) % values.length;
        pixels[i] = values[idx];
      }
      final encoded = JxlEncoder.encodeLossless(pixels,
          width: w, height: h, grayscale: true);

      final image = JxlDecoder.decode(encoded);
      final ours = channelAsInts(image.channels[0], 255);
      for (var i = 0; i < w * h; i++) {
        if (ours[i] != pixels[i]) {
          fail('gray-palette our-decoder mismatch at px $i '
              '(${values.length} values)');
        }
      }
      if (_haveDjxl) {
        final dir = Directory.systemTemp.createTempSync('koni_enc');
        try {
          final jxlPath = '${dir.path}/t.jxl';
          final outPath = '${dir.path}/t.pgm';
          File(jxlPath).writeAsBytesSync(encoded);
          final r =
              Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
          expect(r.exitCode, 0, reason: 'djxl: ${r.stderr}');
          final ref = PnmImage.parse(File(outPath).readAsBytesSync());
          final theirs = ref.intPlanes![0];
          for (var i = 0; i < w * h; i++) {
            if (theirs[i] != pixels[i]) {
              fail('gray-palette djxl mismatch at px $i '
                  '(${values.length} values)');
            }
          }
        } finally {
          dir.deleteSync(recursive: true);
        }
      }
    }
  });

  test('16-bit', () {
    _check16(64, 48);
    _check16(300, 260, grayscale: true);
    _check16(100, 100, hasAlpha: true);
  });

  test('alpha', () {
    _check(100, 100, hasAlpha: true);
    _check(300, 300, hasAlpha: true);
  });

  // Photographic content, where the weighted predictor wins or ties the
  // gradient predictor — the golden corpus is entirely gradient-winning, so
  // this is the only test that exercises the encoder's weighted-predictor
  // Pass B / finish path and its trainingBits-based predictor selection's
  // "finish both, keep smaller" near-tie branch. Decoded from a lossy
  // conformance image (real photo statistics) and re-encoded losslessly.
  test('photographic content round-trips (weighted-predictor path)', () {
    final input =
        File('../../third_party/conformance/testcases/opsin_inverse/input.jxl');
    if (!input.existsSync()) {
      markTestSkipped('conformance corpus not present');
      return;
    }
    final src = JxlDecoder.decode(input.readAsBytesSync());
    final w = src.width, h = src.height;
    final rgba = src.toRgba8();
    final pixels = Uint8List(w * h * 3);
    for (var i = 0; i < w * h; i++) {
      pixels[i * 3] = rgba[i * 4];
      pixels[i * 3 + 1] = rgba[i * 4 + 1];
      pixels[i * 3 + 2] = rgba[i * 4 + 2];
    }
    final encoded = JxlEncoder.encodeLossless(pixels, width: w, height: h);
    final image = JxlDecoder.decode(encoded);
    expect(image.width, w);
    expect(image.height, h);
    for (var c = 0; c < 3; c++) {
      final ours = channelAsInts(image.channels[c], 255);
      for (var i = 0; i < w * h; i++) {
        if (ours[i] != pixels[i * 3 + c]) {
          fail('weighted-predictor round-trip mismatch at px $i channel $c');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  // Per-leaf predictor selection: the top half is periodic texture (the
  // self-correcting weighted predictor wins) and the bottom half is smooth
  // gradients broken by edges (the clamped-gradient predictor wins), so the one
  // learned tree carries BOTH predictors across its leaves (measured: ~15
  // gradient leaves beside ~49 weighted-predictor leaves). This locks in that a
  // mixed-predictor tree round-trips bit-exact through our decoder and djxl —
  // the corpus's gray_screentone also produces a mixed tree, but that gate
  // auto-skips without the corpus, whereas this synthetic case always runs.
  // (The test only asserts round-trip correctness, so it stays valid even if a
  // platform's sin/round yields content that happens not to mix.)
  test('mixed per-leaf predictors round-trip', () {
    const w = 384, h = 384;
    final pixels = Uint8List(w * h);
    final rng = math.Random(11);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final int v;
        if (y < h ~/ 2) {
          final base =
              128 + (80 * math.sin(x * 1.7) * math.cos(y * 1.3)).round();
          v = (base + rng.nextInt(9) - 4).clamp(0, 255);
        } else {
          final band = x ~/ 48;
          v = ((x * 2 + y * 3 + band * 20) + rng.nextInt(5) - 2).clamp(0, 255) &
              255;
        }
        pixels[y * w + x] = v;
      }
    }
    final encoded =
        JxlEncoder.encodeLossless(pixels, width: w, height: h, grayscale: true);
    final image = JxlDecoder.decode(encoded);
    final ours = channelAsInts(image.channels[0], 255);
    for (var i = 0; i < w * h; i++) {
      if (ours[i] != pixels[i]) {
        fail('mixed-predictor round-trip mismatch at px $i');
      }
    }
    if (_haveDjxl) {
      final dir = Directory.systemTemp.createTempSync('koni_enc');
      try {
        final jxlPath = '${dir.path}/t.jxl';
        final outPath = '${dir.path}/t.pgm';
        File(jxlPath).writeAsBytesSync(encoded);
        final r =
            Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
        expect(r.exitCode, 0, reason: 'djxl: ${r.stderr}');
        final ref = PnmImage.parse(File(outPath).readAsBytesSync());
        final theirs = ref.intPlanes![0];
        for (var i = 0; i < w * h; i++) {
          if (theirs[i] != pixels[i]) {
            fail('djxl mixed-predictor mismatch at px $i');
          }
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    }
  });
}
