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

Future<ui.Image> _rgbaToUiImage(Uint8List pixels, int width, int height) async {
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

/// Progressively decodes a JPEG XL byte stream.
///
/// Emits at most two images: a 1:8 DC preview as soon as the stream
/// contains the DC sections (VarDCT images; progressive-DC files preview
/// after a few percent of the bytes), then the final image when the
/// stream completes. Pixel decoding runs in background isolates; only
/// cheap header/TOC probing happens on the calling isolate.
Stream<ui.Image> decodeJxlProgressive(Stream<List<int>> chunks) async* {
  final session = JxlStreamingDecoder();
  final buffer = BytesBuilder(copy: true);
  var previewEmitted = false;
  await for (final chunk in chunks) {
    session.addBytes(chunk);
    buffer.add(chunk);
    if (!previewEmitted && session.state == JxlStreamState.dcReady) {
      previewEmitted = true;
      final snapshot = buffer.toBytes();
      final decoded = await Isolate.run(() {
        final d = JxlStreamingDecoder()..addBytes(snapshot);
        final p = d.decodePreview();
        if (p == null) return null;
        return (p.toRgba8(), p.width, p.height);
      });
      if (decoded != null) {
        yield await _rgbaToUiImage(decoded.$1, decoded.$2, decoded.$3);
      }
    }
  }
  if (session.state != JxlStreamState.complete) {
    throw StateError('JXL stream ended before the file was complete '
        '(${(session.progress * 100).toStringAsFixed(0)}% received)');
  }
  final bytes = buffer.takeBytes();
  final (pixels, width, height) = await Isolate.run(() {
    final image = JxlDecoder.decode(bytes);
    return (image.toRgba8(), image.width, image.height);
  });
  yield await _rgbaToUiImage(pixels, width, height);
}

/// Losslessly encodes raw RGBA pixels to JPEG XL in a background isolate.
Future<Uint8List> encodeJxlFromRgba(Uint8List rgba,
    {required int width, required int height}) {
  return Isolate.run(() => JxlEncoder.encodeLossless(rgba,
      width: width, height: height, hasAlpha: true));
}

/// Losslessly encodes a [ui.Image] to JPEG XL (reads back RGBA, encodes in
/// a background isolate).
Future<Uint8List> encodeJxlFromUiImage(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError('could not read pixels from the ui.Image');
  }
  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final width = image.width;
  final height = image.height;
  return Isolate.run(() => JxlEncoder.encodeLossless(rgba,
      width: width, height: height, hasAlpha: true));
}

/// Lossily (VarDCT) encodes raw RGBA pixels to JPEG XL in a background
/// isolate. Alpha is dropped: `JxlEncoder.encodeLossy` is RGB-only (see
/// its doc comment) — use [encodeJxlFromRgba] instead for content where
/// transparency matters. [distance] is a cjxl-like quality knob (larger =
/// smaller/lower quality); pass [config] instead for direct control over
/// the quantizer knobs, e.g. to opt into filters or variable transform
/// size (both off by default — see `VardctL0Config`'s doc comments for
/// why: they help photographic content but measurably hurt manga's
/// screentone/line-art content).
Future<Uint8List> encodeJxlLossyFromRgba(
  Uint8List rgba, {
  required int width,
  required int height,
  double distance = 1.0,
  VardctL0Config? config,
}) {
  final rgb = Uint8List(width * height * 3);
  for (var i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
    rgb[i] = rgba[j];
    rgb[i + 1] = rgba[j + 1];
    rgb[i + 2] = rgba[j + 2];
  }
  return Isolate.run(() => JxlEncoder.encodeLossy(rgb,
      width: width, height: height, distance: distance, config: config));
}

/// Lossily (VarDCT) encodes a [ui.Image] to JPEG XL (reads back RGBA,
/// drops alpha, encodes in a background isolate). See
/// [encodeJxlLossyFromRgba]'s doc comment for the alpha and [config]
/// caveats.
Future<Uint8List> encodeJxlLossyFromUiImage(
  ui.Image image, {
  double distance = 1.0,
  VardctL0Config? config,
}) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError('could not read pixels from the ui.Image');
  }
  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return encodeJxlLossyFromRgba(rgba,
      width: image.width,
      height: image.height,
      distance: distance,
      config: config);
}
