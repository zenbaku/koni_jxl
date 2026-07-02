import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:koni_jxl/src/util/image_buffer.dart';

/// Decodes a .jxl file to PGM/PPM/PAM (chosen by channel layout), with an
/// optional `--time` flag that reports decode wall time.
void main(List<String> args) {
  final time = args.contains('--time');
  final paths = args.where((a) => !a.startsWith('--')).toList();
  if (paths.isEmpty || paths.length > 2) {
    stderr
        .writeln('usage: jxl_dec [--time] <input.jxl> [output.(pgm|ppm|pam)]');
    exit(2);
  }
  final bytes = File(paths[0]).readAsBytesSync();

  final sw = Stopwatch()..start();
  final image = JxlDecoder.decode(bytes);
  sw.stop();
  if (time) {
    // Decode twice more for a steadier number.
    final sw2 = Stopwatch()..start();
    JxlDecoder.decode(bytes);
    JxlDecoder.decode(bytes);
    sw2.stop();
    stderr.writeln('decode: first ${sw.elapsedMilliseconds} ms, '
        'warm ${(sw2.elapsedMilliseconds / 2).toStringAsFixed(1)} ms '
        '(${image.width}x${image.height})');
  }
  if (paths.length < 2) return;

  final out = File(paths[1]);
  final maxValue = (1 << image.bitsPerSample) - 1;
  final colors = image.isGrayscale ? 1 : 3;
  final planes = <Int32List>[];
  for (var c = 0; c < colors; c++) {
    planes.add(_asInts(image.channels[c], maxValue));
  }
  final alphaIndex = image.header.alphaIndices.isNotEmpty
      ? colors + image.header.alphaIndices.first
      : -1;
  if (alphaIndex >= 0) {
    final alphaMax = image.header.extraChannels[image.header.alphaIndices.first]
        .bitDepth.maxValue;
    planes.add(_asInts(image.channels[alphaIndex], alphaMax));
  }
  final wide = maxValue > 255;
  final b = BytesBuilder();
  if (alphaIndex >= 0) {
    b.add('P7\nWIDTH ${image.width}\nHEIGHT ${image.height}\n'
            'DEPTH ${planes.length}\nMAXVAL $maxValue\nTUPLTYPE '
            '${colors == 1 ? 'GRAYSCALE_ALPHA' : 'RGB_ALPHA'}\nENDHDR\n'
        .codeUnits);
  } else {
    b.add('${colors == 1 ? 'P5' : 'P6'}\n${image.width} ${image.height}\n'
            '$maxValue\n'
        .codeUnits);
  }
  for (var i = 0; i < image.width * image.height; i++) {
    for (final plane in planes) {
      if (wide) b.addByte(plane[i] >> 8);
      b.addByte(plane[i] & 0xFF);
    }
  }
  out.writeAsBytesSync(b.toBytes());
}

Int32List _asInts(ImageBuffer plane, int maxValue) {
  final n = plane.height * plane.width;
  final out = Int32List(n);
  if (plane.isInt) {
    final buf = plane.intBuffer;
    for (var i = 0; i < n; i++) {
      out[i] = buf[i] < 0
          ? 0
          : buf[i] > maxValue
              ? maxValue
              : buf[i];
    }
  } else {
    final buf = plane.floatBuffer;
    for (var i = 0; i < n; i++) {
      final v = (buf[i] * maxValue + 0.5).truncate();
      out[i] = v < 0
          ? 0
          : v > maxValue
              ? maxValue
              : v;
    }
  }
  return out;
}
