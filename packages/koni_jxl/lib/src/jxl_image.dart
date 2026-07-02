import 'dart:typed_data';

import 'header/image_header.dart';
import 'util/image_buffer.dart';

/// A decoded JPEG XL image: per-channel planes (already oriented) plus the
/// image metadata.
final class JxlImage {
  JxlImage.internal(this._header, this.channels, this.iccProfile);

  final ImageHeader _header;

  /// Decoded planes: color channels first, then extra channels.
  final List<ImageBuffer> channels;

  /// The decompressed ICC profile embedded in the codestream, if any.
  final Uint8List? iccProfile;

  int get width => _header.orientedSize.width;
  int get height => _header.orientedSize.height;
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

    int sample(ImageBuffer plane, int i, int max) {
      if (plane.isInt) return scaleInt(plane.intBuffer[i], max);
      final f = plane.floatBuffer[i];
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
    final n = w * h;
    for (var i = 0; i < n; i++) {
      final o = i << 2;
      out[o] = sample(r, i, maxValue);
      out[o + 1] = sample(g, i, maxValue);
      out[o + 2] = sample(b, i, maxValue);
      out[o + 3] =
          alphaChannel != null ? sample(alphaChannel, i, alphaMax) : 255;
    }
    return out;
  }
}
