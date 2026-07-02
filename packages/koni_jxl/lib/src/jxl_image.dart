import 'dart:typed_data';

import 'header/image_header.dart';
import 'util/image_buffer.dart';

/// A decoded JPEG XL image: per-channel planes (already oriented) plus the
/// image metadata.
final class JxlImage {
  JxlImage.internal(this._header, this.channels, this.iccProfile)
      : isPreview = false,
        _widthOverride = null,
        _heightOverride = null;

  JxlImage.preview(this._header, this.channels, this.iccProfile,
      int previewWidth, int previewHeight)
      : isPreview = true,
        _widthOverride = previewWidth,
        _heightOverride = previewHeight;

  /// True for reduced-resolution previews from [JxlStreamingDecoder].
  final bool isPreview;
  final int? _widthOverride;
  final int? _heightOverride;

  final ImageHeader _header;

  /// Decoded planes: color channels first, then extra channels.
  final List<ImageBuffer> channels;

  /// The decompressed ICC profile embedded in the codestream, if any.
  final Uint8List? iccProfile;

  int get width => _widthOverride ?? _header.orientedSize.width;
  int get height => _heightOverride ?? _header.orientedSize.height;
  bool get isGrayscale => _header.isGrayscale;
  bool get hasAlpha => _header.hasAlpha;
  int get bitsPerSample => _header.bitDepth.bitsPerSample;

  /// The parsed image header, for internal/advanced use.
  ImageHeader get header => _header;

  /// Converts to interleaved 8-bit RGBA in sRGB, top-left origin.
  Uint8List toRgba8() {
    final w = width;
    final h = height;
    final out = Uint8List(w * h * 4);
    final colors = _header.colorChannelCount;
    final maxValue = _header.bitDepth.maxValue;
    final alphaIndex =
        _header.alphaIndices.isNotEmpty ? _header.alphaIndices.first : -1;
    final alphaChannel = alphaIndex >= 0 ? channels[colors + alphaIndex] : null;
    final alphaMax = alphaIndex >= 0
        ? _header.extraChannels[alphaIndex].bitDepth.maxValue
        : 1;

    int scaleInt(int v, int max) {
      if (v < 0) v = 0;
      if (v > max) v = max;
      if (max == 255) return v;
      return (v * 255 + (max >> 1)) ~/ max;
    }

    int sample(ImageBuffer plane, int y, int x, int max) {
      if (plane.isInt) return scaleInt(plane.intRows[y][x], max);
      final f = plane.floatRows[y][x];
      final v = (f * 255 + 0.5).floor();
      return v < 0
          ? 0
          : v > 255
              ? 255
              : v;
    }

    final r = channels[0];
    final g = channels[colors > 1 ? 1 : 0];
    final b = channels[colors > 1 ? 2 : 0];
    var o = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out[o] = sample(r, y, x, maxValue);
        out[o + 1] = sample(g, y, x, maxValue);
        out[o + 2] = sample(b, y, x, maxValue);
        out[o + 3] =
            alphaChannel != null ? sample(alphaChannel, y, x, alphaMax) : 255;
        o += 4;
      }
    }
    return out;
  }
}

/// All visible frames of a decoded (possibly animated) JPEG XL image.
final class JxlAnimation {
  /// Internal: constructed by the decoder. Use [JxlDecoder.decodeAnimation].
  JxlAnimation.internal({
    required this.frames,
    required this.durations,
    required this.timecodes,
    required this.tpsNumerator,
    required this.tpsDenominator,
    required this.numLoops,
  });

  /// Finalized frames, in presentation order.
  final List<JxlImage> frames;

  /// Per-frame durations in ticks ([tpsNumerator] / [tpsDenominator] ticks
  /// per second). Zero for still images.
  final List<int> durations;

  /// Per-frame timecodes (only meaningful when the stream has timecodes).
  final List<int> timecodes;

  /// Numerator of the animation tick rate (ticks per second).
  final int tpsNumerator;

  /// Denominator of the animation tick rate (ticks per second).
  final int tpsDenominator;

  /// Number of animation loops; 0 means loop forever.
  final int numLoops;

  /// Whether this image has more than one frame.
  bool get isAnimated => frames.length > 1;

  /// Wall-clock duration of frame [index].
  Duration frameDuration(int index) {
    if (tpsNumerator == 0) return Duration.zero;
    return Duration(
        microseconds:
            durations[index] * tpsDenominator * 1000000 ~/ tpsNumerator);
  }
}
