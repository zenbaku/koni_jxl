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

/// A decoded JPEG XL animation ready for rendering.
final class JxlUiAnimation {
  JxlUiAnimation(this.frames, this.frameDurations, this.numLoops);

  /// Frames in presentation order (a still image yields one frame).
  final List<ui.Image> frames;

  /// Wall-clock duration of each frame; zero for still images.
  final List<Duration> frameDurations;

  /// Number of loops; 0 means loop forever.
  final int numLoops;

  bool get isAnimated => frames.length > 1;

  void dispose() {
    for (final f in frames) {
      f.dispose();
    }
  }
}

/// Decodes all frames of a (possibly animated) JPEG XL image.
Future<JxlUiAnimation> decodeJxlAnimation(Uint8List bytes) async {
  final (rgbaFrames, durations, width, height, numLoops) =
      await Isolate.run(() {
    final anim = JxlDecoder.decodeAnimation(bytes);
    return (
      [for (final f in anim.frames) f.toRgba8()],
      [
        for (var i = 0; i < anim.frames.length; i++)
          anim.frameDuration(i).inMicroseconds,
      ],
      anim.frames.first.width,
      anim.frames.first.height,
      anim.numLoops,
    );
  });
  final frames = <ui.Image>[];
  for (final pixels in rgbaFrames) {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    frames.add(frame.image);
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
  return JxlUiAnimation(
    frames,
    [for (final us in durations) Duration(microseconds: us)],
    numLoops,
  );
}
