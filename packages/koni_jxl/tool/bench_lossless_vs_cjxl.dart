import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Benchmarks this package's lossless (modular) encoder against `cjxl` at
/// several efforts: file size and wall-clock encode time. Lossless is
/// bit-exact by definition, so (unlike `bench_lossy_vs_cjxl.dart`) there is
/// no RMSE column — instead this tool decodes its own output and asserts
/// it matches the source pixels exactly, so a correctness regression can't
/// silently masquerade as a size win.
///
/// Usage: `dart run tool/bench_lossless_vs_cjxl.dart [pnm/pam files...]`
/// (defaults to the corpus's `_d0_e7` goldens — the source pixels, since
/// lossless decode is bit-exact regardless of the effort used to produce
/// them — run `tool/gen_corpus.py` first).
///
/// The "vs koni_jxl" column is this encoder's size as a percentage of that
/// row's size: under 100% at a given cjxl effort means koni_jxl already
/// beats that effort; over 100% means cjxl is still smaller there.
///
/// `encode-ms` is a single cold call, not a warmed-up loop — for
/// apples-to-apples numbers across tools, AOT-compile first
/// (`dart compile exe tool/bench_lossless_vs_cjxl.dart -o /tmp/bl && /tmp/bl`).
/// Note this can come out *slower* than `dart run` here: the encoder's
/// hot inner loops run long enough within one call for the JIT to tier
/// them up mid-flight, while default `dart compile exe` has no
/// profile-guided optimization to draw on. See `doc/BENCHMARKS.md`.
void main(List<String> args) {
  final inputs = args.isNotEmpty ? args : _defaultGoldens();

  for (final path in inputs) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('skip (not found): $path');
      continue;
    }
    final pnm = _PnmImage.parse(file.readAsBytesSync());
    if (pnm.width * pnm.height < 100000) continue; // skip tiny edge cases

    final sw = Stopwatch()..start();
    final Uint8List encoded;
    if (pnm.maxValue > 255) {
      encoded = JxlEncoder.encodeLossless16(pnm.as16(),
          width: pnm.width, height: pnm.height, grayscale: pnm.channels == 1);
    } else {
      encoded = JxlEncoder.encodeLossless(pnm.as8(),
          width: pnm.width,
          height: pnm.height,
          grayscale: pnm.channels == 1,
          hasAlpha: pnm.channels == 4);
    }
    sw.stop();
    _assertBitExact(encoded, pnm, path);
    final ours = _Result(encoded.length, sw.elapsedMilliseconds);

    print('\n=== $path (${pnm.width}x${pnm.height}, ${pnm.channels}ch, '
        '${pnm.maxValue > 255 ? 16 : 8}-bit) ===');
    print('encoder     bytes   vs koni_jxl  encode-ms');
    void row(String name, _Result? r) {
      if (r == null) {
        print('  $name: (unavailable, is cjxl on PATH?)');
        return;
      }
      final pct = 100.0 * ours.bytes / r.bytes;
      print('  ${name.padRight(9)} ${r.bytes.toString().padLeft(7)}  '
          '${pct.toStringAsFixed(1).padLeft(9)}%  '
          '${r.encodeMs.toString().padLeft(7)}');
    }

    row('koni_jxl', ours);
    for (final effort in [1, 3, 7, 9]) {
      row('cjxl -e$effort', _runCjxl(path, effort: effort));
    }
  }
}

List<String> _defaultGoldens() {
  final dir = Directory('../../third_party/corpus/golden');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) =>
          (p.endsWith('.pgm') || p.endsWith('.ppm') || p.endsWith('.pam')) &&
          p.contains('_d0_') &&
          p.contains('_e7'))
      .toList()
    ..sort();
}

void _assertBitExact(Uint8List encoded, _PnmImage src, String path) {
  final image = JxlDecoder.decode(encoded);
  for (var c = 0; c < src.channels; c++) {
    final plane = image.channels[c];
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        final got =
            plane.isInt ? plane.intRows[y][x] : plane.floatRows[y][x].round();
        final want = src.planes[c][y * src.width + x];
        if (got != want) {
          throw StateError('$path: bit-exactness broken at channel $c, ($x,$y) '
              '(got $got, want $want)');
        }
      }
    }
  }
}

class _Result {
  _Result(this.bytes, this.encodeMs);
  final int bytes;
  final int encodeMs;
}

_Result? _runCjxl(String srcPath, {required int effort}) {
  final dir = Directory.systemTemp.createTempSync('bench_cjxl_lossless');
  try {
    final outPath = '${dir.path}/out.jxl';
    final sw = Stopwatch()..start();
    final r = Process.runSync('cjxl', [
      srcPath,
      outPath,
      '-d',
      '0',
      '-e',
      '$effort',
      '--num_threads',
      '1',
    ]);
    sw.stop();
    if (r.exitCode != 0) return null;
    final bytes = File(outPath).lengthSync();
    return _Result(bytes, sw.elapsedMilliseconds);
  } on ProcessException {
    return null;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Minimal PNM (P5/P6) + PAM (P7) reader, 8- or 16-bit — enough to cover
/// the corpus goldens used here.
class _PnmImage {
  _PnmImage(this.width, this.height, this.channels, this.maxValue, this.planes);

  final int width;
  final int height;
  final int channels;
  final int maxValue;
  final List<Int32List> planes;

  static _PnmImage parse(Uint8List data) {
    final magic = String.fromCharCodes(data, 0, 2);
    return switch (magic) {
      'P5' => _parseBinary(data, 1),
      'P6' => _parseBinary(data, 3),
      'P7' => _parsePam(data),
      _ => throw FormatException('unsupported PNM magic: $magic'),
    };
  }

  static _PnmImage _parseBinary(Uint8List data, int channels) {
    var i = 2;
    final tokens = <int>[];
    while (tokens.length < 3) {
      while (data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D) {
        i++;
      }
      var value = 0;
      while (data[i] >= 0x30 && data[i] <= 0x39) {
        value = value * 10 + (data[i] - 0x30);
        i++;
      }
      tokens.add(value);
    }
    i++; // single whitespace after maxval
    final [width, height, maxValue] = tokens;
    final wide = maxValue > 255;
    final planes = List.generate(channels, (_) => Int32List(width * height));
    var p = i;
    for (var px = 0; px < width * height; px++) {
      for (var c = 0; c < channels; c++) {
        planes[c][px] = wide ? (data[p] << 8) | data[p + 1] : data[p];
        p += wide ? 2 : 1;
      }
    }
    return _PnmImage(width, height, channels, maxValue, planes);
  }

  static _PnmImage _parsePam(Uint8List data) {
    var i = 0;
    var width = 0, height = 0, depth = 0, maxValue = 0;
    while (true) {
      var end = i;
      while (data[end] != 0x0A) {
        end++;
      }
      final line = String.fromCharCodes(data, i, end).trim();
      i = end + 1;
      if (line == 'ENDHDR') break;
      final parts = line.split(RegExp(r'\s+'));
      switch (parts[0]) {
        case 'WIDTH':
          width = int.parse(parts[1]);
        case 'HEIGHT':
          height = int.parse(parts[1]);
        case 'DEPTH':
          depth = int.parse(parts[1]);
        case 'MAXVAL':
          maxValue = int.parse(parts[1]);
      }
    }
    final wide = maxValue > 255;
    final planes = List.generate(depth, (_) => Int32List(width * height));
    var p = i;
    for (var px = 0; px < width * height; px++) {
      for (var c = 0; c < depth; c++) {
        planes[c][px] = wide ? (data[p] << 8) | data[p + 1] : data[p];
        p += wide ? 2 : 1;
      }
    }
    return _PnmImage(width, height, depth, maxValue, planes);
  }

  Uint8List as8() {
    final out = Uint8List(width * height * channels);
    for (var c = 0; c < channels; c++) {
      final plane = planes[c];
      for (var i = 0; i < plane.length; i++) {
        out[i * channels + c] = plane[i];
      }
    }
    return out;
  }

  Uint16List as16() {
    final out = Uint16List(width * height * channels);
    for (var c = 0; c < channels; c++) {
      final plane = planes[c];
      for (var i = 0; i < plane.length; i++) {
        out[i * channels + c] = plane[i];
      }
    }
    return out;
  }
}
