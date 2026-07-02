import '../frame/frame.dart';
import '../util/image_buffer.dart';
import '../util/math_helper.dart';

ImageBuffer _upsamplePlane(Frame frame, ImageBuffer ib, int c) {
  final color = frame.colorChannelCount;
  final k = c < color
      ? frame.header.upsampling
      : frame.header.ecUpsampling[c - color];
  if (k == 1) return ib;
  final metadata = frame.globalMetadata;
  final depth = c < color
      ? metadata.bitDepth.bitsPerSample
      : metadata.extraChannels[c - color].bitDepth.bitsPerSample;
  ib.castToFloat(depth);
  final rows = ib.floatRows;
  final height = ib.height;
  final width = ib.width;
  final l = ceilLog1p(k - 1) - 1;
  final upWeights = metadata.upWeights[l];
  final out = ImageBuffer.float32(height * k, width * k);
  final outRows = out.floatRows;
  for (var y = 0; y < height; y++) {
    for (var ky = 0; ky < k; ky++) {
      final outRow = outRows[y * k + ky];
      for (var x = 0; x < width; x++) {
        for (var kx = 0; kx < k; kx++) {
          final weights = upWeights[ky * k + kx];
          var total = 0.0;
          var min = double.maxFinite;
          var max = -double.maxFinite;
          for (var iy = 0; iy < 5; iy++) {
            final newY = mirrorCoordinate(y + iy - 2, height);
            final row = rows[newY];
            final wRow = weights[iy];
            for (var ix = 0; ix < 5; ix++) {
              final newX = mirrorCoordinate(x + ix - 2, width);
              final sample = row[newX];
              if (sample < min) min = sample;
              if (sample > max) max = sample;
              total += wRow[ix] * sample;
            }
          }
          outRow[x * k + kx] = total < min
              ? min
              : total > max
                  ? max
                  : total;
        }
      }
    }
  }
  return out;
}

/// Applies frame upsampling in place: scales all channel planes and the
/// frame bounds, and recomputes group geometry.
void upsampleFrame(Frame frame) {
  for (var c = 0; c < frame.buffer.length; c++) {
    frame.buffer[c] = _upsamplePlane(frame, frame.buffer[c], c);
  }
  final factor = frame.header.upsampling;
  frame.boundsWidth *= factor;
  frame.boundsHeight *= factor;
  frame.boundsX0 *= factor;
  frame.boundsY0 *= factor;
  frame.groupRowStride = ceilDiv(frame.boundsWidth, frame.header.groupDim);
  frame.lfGroupRowStride =
      ceilDiv(frame.boundsWidth, frame.header.groupDim << 3);
  frame.numGroups =
      frame.groupRowStride * ceilDiv(frame.boundsHeight, frame.header.groupDim);
  frame.numLfGroups = frame.lfGroupRowStride *
      ceilDiv(frame.boundsHeight, frame.header.groupDim << 3);
}
