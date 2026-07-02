import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Losslessly encodes a binary PGM (P5) or PPM (P6) file to JPEG XL.
void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: jxl_enc <input.pgm|ppm> <output.jxl>');
    exit(2);
  }
  final data = File(args[0]).readAsBytesSync();
  final magic = String.fromCharCodes(data, 0, 2);
  if (magic != 'P5' && magic != 'P6') {
    stderr.writeln('only binary PGM/PPM input is supported');
    exit(2);
  }
  // Header: magic, width, height, maxval, single whitespace, then samples.
  final fields = <int>[];
  var i = 2;
  while (fields.length < 3) {
    while (data[i] == 0x20 ||
        data[i] == 0x0A ||
        data[i] == 0x0D ||
        data[i] == 0x09) {
      i++;
    }
    if (data[i] == 0x23) {
      while (data[i] != 0x0A) {
        i++;
      }
      continue;
    }
    var v = 0;
    while (data[i] >= 0x30 && data[i] <= 0x39) {
      v = v * 10 + (data[i++] - 0x30);
    }
    fields.add(v);
  }
  i++; // single whitespace after maxval
  final (width, height, maxval) = (fields[0], fields[1], fields[2]);
  if (maxval != 255) {
    stderr.writeln('only 8-bit input is supported');
    exit(2);
  }
  final gray = magic == 'P5';
  final pixels = Uint8List.sublistView(data, i);
  final sw = Stopwatch()..start();
  final encoded = JxlEncoder.encodeLossless(pixels,
      width: width, height: height, grayscale: gray);
  stderr.writeln('encoded ${width}x$height in ${sw.elapsedMilliseconds} ms: '
      '${encoded.length} bytes');
  File(args[1]).writeAsBytesSync(encoded);
}
