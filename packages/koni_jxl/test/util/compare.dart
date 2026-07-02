import 'dart:typed_data';

import 'package:koni_jxl/src/util/image_buffer.dart';

/// Converts a decoded plane to integer samples the way djxl does when
/// writing PNM: ints are clamped to [0, maxValue]; floats are scaled,
/// rounded and clamped.
Int32List channelAsInts(ImageBuffer plane, int maxValue) {
  final n = plane.height * plane.width;
  final out = Int32List(n);
  if (plane.isInt) {
    final b = plane.intBuffer;
    for (var i = 0; i < n; i++) {
      final v = b[i];
      out[i] = v < 0
          ? 0
          : v > maxValue
              ? maxValue
              : v;
    }
  } else {
    final b = plane.floatBuffer;
    for (var i = 0; i < n; i++) {
      final v = (b[i] * maxValue + 0.5).truncate();
      out[i] = v < 0
          ? 0
          : v > maxValue
              ? maxValue
              : v;
    }
  }
  return out;
}
