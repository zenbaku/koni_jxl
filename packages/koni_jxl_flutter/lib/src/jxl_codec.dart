import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/painting.dart'
    show ImageDecoderCallback, ImageProvider, MultiFrameImageStreamCompleter;
import 'package:koni_jxl/koni_jxl.dart';

// All CPU-heavy work goes through [compute]: a background isolate on native
// platforms (Isolate.run underneath, so result buffers are transferred
// rather than copied), and a plain call on the web — dart2js and dart2wasm
// have no isolates, and Isolate.run itself throws UnsupportedError there.

(Uint8List, int, int) _decodeRgba(Uint8List bytes) {
  final image = JxlDecoder.decode(bytes);
  return (image.toRgba8(), image.width, image.height);
}

/// Decodes JPEG XL [bytes] into a [ui.Image].
///
/// The CPU-heavy decode runs through [compute] (a background isolate on
/// native platforms, the calling thread on the web); only the final GPU
/// upload happens on the calling isolate.
Future<ui.Image> decodeJxlToUiImage(Uint8List bytes) async {
  final (pixels, width, height) = await compute(_decodeRgba, bytes);
  return _rgbaToUiImage(pixels, width, height);
}

/// Decodes JPEG XL [bytes] into a [ui.Codec], the shape Flutter's standard
/// [MultiFrameImageStreamCompleter] machinery consumes inside custom
/// [ImageProvider]s. A still image yields a single-frame codec; an animated
/// file yields all frames with their durations and loop count, so it plays
/// like any engine-decoded animation.
///
/// All frames are decoded up front (through [compute], see above);
/// [ui.Codec.getNextFrame] then hands out per-frame clones, which the image
/// stream machinery disposes as it consumes them. Disposing the codec
/// releases the retained frames.
Future<ui.Codec> decodeJxlToUiCodec(Uint8List bytes) async {
  // Header-only probe (cheap, no pixel work) to pick the single- vs
  // all-frames decode.
  if (JxlInfo.parse(bytes).isAnimated) {
    final anim = await decodeJxlAnimation(bytes);
    return _JxlUiCodec(anim.frames, anim.frameDurations, anim.numLoops);
  }
  final image = await decodeJxlToUiImage(bytes);
  return _JxlUiCodec([image], const [Duration.zero], 1);
}

/// The byte→codec seam for apps whose custom [ImageProvider]s render mixed
/// image formats from one byte source (files, archives, caches): JPEG XL
/// bytes — detected by content via [looksLikeJxl], never file extension —
/// decode through this package, anything else goes to the engine's [decode]
/// callback unchanged. Drop-in inside [ImageProvider.loadImage]:
///
/// ```dart
/// Future<ui.Codec> _loadCodec(ImageDecoderCallback decode) async {
///   final bytes = await _readBytes();
///   return jxlAwareDecode(bytes, decode);
/// }
/// ```
Future<ui.Codec> jxlAwareDecode(
    Uint8List bytes, ImageDecoderCallback decode) async {
  if (looksLikeJxl(bytes)) return decodeJxlToUiCodec(bytes);
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  return decode(buffer);
}

class _JxlUiCodec implements ui.Codec {
  _JxlUiCodec(this._frames, this._durations, int numLoops)
      // JXL counts total plays (0 = play forever); ui.Codec counts repeats
      // after the first play (-1 = repeat forever).
      : repetitionCount = numLoops == 0 ? -1 : numLoops - 1;

  final List<ui.Image> _frames;
  final List<Duration> _durations;
  int _next = 0;

  @override
  int get frameCount => _frames.length;

  @override
  final int repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final i = _next;
    _next = (_next + 1) % _frames.length;
    return _JxlFrameInfo(_frames[i].clone(), _durations[i]);
  }

  @override
  void dispose() {
    for (final f in _frames) {
      f.dispose();
    }
  }
}

class _JxlFrameInfo implements ui.FrameInfo {
  _JxlFrameInfo(this.image, this.duration);

  @override
  final ui.Image image;

  @override
  final Duration duration;
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

(List<Uint8List>, List<int>, int, int, int) _decodeAnimationRgba(
    Uint8List bytes) {
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
}

/// Decodes all frames of a (possibly animated) JPEG XL image.
Future<JxlUiAnimation> decodeJxlAnimation(Uint8List bytes) async {
  final (rgbaFrames, durations, width, height, numLoops) =
      await compute(_decodeAnimationRgba, bytes);
  final frames = <ui.Image>[];
  for (final pixels in rgbaFrames) {
    frames.add(await _rgbaToUiImage(pixels, width, height));
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

(Uint8List, int, int)? _decodePreviewRgba(Uint8List snapshot) {
  final d = JxlStreamingDecoder()..addBytes(snapshot);
  final p = d.decodePreview();
  if (p == null) return null;
  return (p.toRgba8(), p.width, p.height);
}

/// Progressively decodes a JPEG XL byte stream.
///
/// Emits at most two images: a 1:8 DC preview as soon as the stream
/// contains the DC sections (VarDCT images; progressive-DC files preview
/// after a few percent of the bytes), then the final image when the
/// stream completes. Pixel decoding runs through [compute] (background
/// isolates on native platforms); only cheap header/TOC probing happens
/// on the calling isolate.
Stream<ui.Image> decodeJxlProgressive(Stream<List<int>> chunks) async* {
  final session = JxlStreamingDecoder();
  final buffer = BytesBuilder(copy: true);
  var previewEmitted = false;
  await for (final chunk in chunks) {
    session.addBytes(chunk);
    buffer.add(chunk);
    if (!previewEmitted && session.state == JxlStreamState.dcReady) {
      previewEmitted = true;
      final decoded = await compute(_decodePreviewRgba, buffer.toBytes());
      if (decoded != null) {
        yield await _rgbaToUiImage(decoded.$1, decoded.$2, decoded.$3);
      }
    }
  }
  if (session.state != JxlStreamState.complete) {
    throw StateError('JXL stream ended before the file was complete '
        '(${(session.progress * 100).toStringAsFixed(0)}% received)');
  }
  final (pixels, width, height) =
      await compute(_decodeRgba, buffer.takeBytes());
  yield await _rgbaToUiImage(pixels, width, height);
}

Uint8List _encodeLossless((Uint8List, int, int) args) {
  final (rgba, width, height) = args;
  return JxlEncoder.encodeLossless(rgba,
      width: width, height: height, hasAlpha: true);
}

/// Losslessly encodes raw RGBA pixels to JPEG XL through [compute] (a
/// background isolate on native platforms).
Future<Uint8List> encodeJxlFromRgba(Uint8List rgba,
    {required int width, required int height}) {
  return compute(_encodeLossless, (rgba, width, height));
}

/// Losslessly encodes a [ui.Image] to JPEG XL (reads back RGBA, encodes
/// through [compute]).
Future<Uint8List> encodeJxlFromUiImage(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError('could not read pixels from the ui.Image');
  }
  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return compute(_encodeLossless, (rgba, image.width, image.height));
}

Uint8List _encodeLossy((Uint8List, int, int, double, VardctL0Config?) args) {
  final (rgb, width, height, distance, config) = args;
  return JxlEncoder.encodeLossy(rgb,
      width: width, height: height, distance: distance, config: config);
}

/// Lossily (VarDCT) encodes raw RGBA pixels to JPEG XL through [compute]
/// (a background isolate on native platforms). Alpha is dropped:
/// `JxlEncoder.encodeLossy` is RGB-only (see its doc comment) — use
/// [encodeJxlFromRgba] instead for content where transparency matters.
/// [distance] is a cjxl-like quality knob (larger = smaller/lower quality);
/// pass [config] instead for direct control over the quantizer knobs, e.g.
/// to opt into filters or variable transform size (both off by default —
/// see `VardctL0Config`'s doc comments for why: they help photographic
/// content but measurably hurt manga's screentone/line-art content).
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
  return compute(_encodeLossy, (rgb, width, height, distance, config));
}

/// Lossily (VarDCT) encodes a [ui.Image] to JPEG XL (reads back RGBA,
/// drops alpha, encodes through [compute]). See [encodeJxlLossyFromRgba]'s
/// doc comment for the alpha and [config] caveats.
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
