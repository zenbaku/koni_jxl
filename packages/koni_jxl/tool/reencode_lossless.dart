import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Decodes a (typically lossy) .jxl file and re-encodes it losslessly with
/// this package's own encoder — for stress-testing the decoder against
/// content with the encoder's own rich learned-context-tree output, rather
/// than only cjxl-produced corpus files.
void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final image = JxlDecoder.decode(bytes);
  final rgba = image.toRgba8();
  final rgb = Uint8List(image.width * image.height * 3);
  for (var i = 0; i < image.width * image.height; i++) {
    rgb[i * 3] = rgba[i * 4];
    rgb[i * 3 + 1] = rgba[i * 4 + 1];
    rgb[i * 3 + 2] = rgba[i * 4 + 2];
  }
  final out =
      JxlEncoder.encodeLossless(rgb, width: image.width, height: image.height);
  File(args[1]).writeAsBytesSync(out);
  print('${image.width}x${image.height} -> ${out.length} bytes');
}
