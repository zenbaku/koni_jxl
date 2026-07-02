import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:koni_jxl/koni_jxl.dart';

/// Decodes JPEG XL [bytes] into a [ui.Image].
///
/// The CPU-heavy decode runs in a background isolate ([Isolate.run], with the
/// pixel buffer transferred rather than copied); only the final GPU upload
/// happens on the calling isolate.
Future<ui.Image> decodeJxlToUiImage(Uint8List bytes) async {
  final (pixels, width, height) = await Isolate.run(() {
    final image = JxlDecoder.decode(bytes);
    return (image.toRgba8(), image.width, image.height);
  });
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}
