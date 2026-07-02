import 'dart:typed_data';

import 'package:koni_jxl/src/util/image_buffer.dart';

/// Converts a decoded plane to integer samples the way djxl does when
/// writing PNM: ints are clamped to [0, maxValue]; floats are scaled,
/// rounded and clamped.
Int32List channelAsInts(ImageBuffer plane, int maxValue) {
  final n = plane.height * plane.width;
  final out = Int32List(n);
  var i = 0;
  if (plane.isInt) {
    for (final row in plane.intRows) {
      for (var x = 0; x < plane.width; x++) {
        final v = row[x];
        out[i++] = v < 0
            ? 0
            : v > maxValue
                ? maxValue
                : v;
      }
    }
  } else {
    for (final row in plane.floatRows) {
      for (var x = 0; x < plane.width; x++) {
        final v = (row[x] * maxValue + 0.5).truncate();
        out[i++] = v < 0
            ? 0
            : v > maxValue
                ? maxValue
                : v;
      }
    }
  }
  return out;
}
