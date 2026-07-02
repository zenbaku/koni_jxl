import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Decodes a `.jxl` file to RGBA, then losslessly re-encodes those pixels
/// back to JPEG XL.
///
/// Run: `dart run example/koni_jxl_example.dart input.jxl`
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: koni_jxl_example <input.jxl>');
    exit(2);
  }
  final bytes = File(args[0]).readAsBytesSync();

  // Cheap header inspection — reads only the first few hundred bytes.
  final info = JxlInfo.parse(bytes);
  print('${info.width}x${info.height}, ${info.bitsPerSample}-bit, '
      'grayscale=${info.isGrayscale}, alpha=${info.hasAlpha}, '
      'animated=${info.isAnimated}');

  // Full decode to interleaved RGBA.
  final image = JxlDecoder.decode(bytes);
  final Uint8List rgba = image.toRgba8();
  print('decoded ${rgba.length} RGBA bytes');

  // Re-encode losslessly (RGBA in, JPEG XL out).
  final reencoded = JxlEncoder.encodeLossless(
    rgba,
    width: image.width,
    height: image.height,
    hasAlpha: true,
  );
  File('${args[0]}.reencoded.jxl').writeAsBytesSync(reencoded);
  print('re-encoded to ${args[0]}.reencoded.jxl (${reencoded.length} bytes)');
}
