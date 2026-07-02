import 'dart:math' as math;
import 'dart:typed_data';

import '../util/math_helper.dart';

/// cosineLut[log2(s)][n - 1][k] = sqrt(2) * cos(pi * n * (k + 0.5) / s).
final List<List<Float32List>> _cosineLut = () {
  final root2 = math.sqrt(2.0);
  return List.generate(9, (l) {
    final s = 1 << l;
    return List.generate(s - 1, (n) {
      final lut = Float32List(s);
      for (var k = 0; k < s; k++) {
        lut[k] = root2 * math.cos(math.pi * (n + 1) * (k + 0.5) / s);
      }
      return lut;
    });
  });
}();

/// One row of inverse DCT (DCT-III with jxl scaling).
void inverseDCTHorizontal(Float32List src, Float32List dest, int xStartIn,
    int xStartOut, int xLogLength, int xLength) {
  dest.fillRange(xStartOut, xStartOut + xLength, src[xStartIn]);
  final lutX = _cosineLut[xLogLength];
  for (var n = 1; n < xLength; n++) {
    final lut = lutX[n - 1];
    final s2 = src[xStartIn + n];
    for (var k = 0; k < xLength; k++) {
      dest[xStartOut + k] += s2 * lut[k];
    }
  }
}

/// One row of forward DCT (DCT-II with jxl scaling).
void forwardDCTHorizontal(Float32List src, Float32List dest, int xStartIn,
    int xStartOut, int xLogLength, int xLength) {
  final invLength = 1.0 / xLength;
  var d2 = src[xStartIn];
  for (var x = 1; x < xLength; x++) {
    d2 += src[xStartIn + x];
  }
  dest[xStartOut] = d2 * invLength;
  for (var k = 1; k < xLength; k++) {
    final lut = _cosineLut[xLogLength][k - 1];
    d2 = src[xStartIn] * lut[0];
    for (var n = 1; n < xLength; n++) {
      d2 += src[xStartIn + n] * lut[n];
    }
    dest[xStartOut + k] = d2 * invLength;
  }
}

void transposeMatrixInto(
    List<Float32List> src,
    List<Float32List> dest,
    int srcStartY,
    int srcStartX,
    int destStartY,
    int destStartX,
    int srcHeight,
    int srcWidth) {
  for (var y = 0; y < srcHeight; y++) {
    final srcy = src[srcStartY + y];
    for (var x = 0; x < srcWidth; x++) {
      dest[destStartY + x][destStartX + y] = srcy[srcStartX + x];
    }
  }
}

/// 2D inverse DCT of a (height x width) block from src(startIn) into
/// dest(startOut). Scratch spaces must be at least max(dim) square.
void inverseDCT2D(
    List<Float32List> src,
    List<Float32List> dest,
    int startInY,
    int startInX,
    int startOutY,
    int startOutX,
    int height,
    int width,
    List<Float32List> scratch0,
    List<Float32List> scratch1,
    bool transposed) {
  final logHeight = ceilLog2(height);
  final logWidth = ceilLog2(width);
  if (transposed) {
    for (var y = 0; y < height; y++) {
      inverseDCTHorizontal(
          src[startInY + y], scratch1[y], startInX, 0, logWidth, width);
    }
    transposeMatrixInto(scratch1, scratch0, 0, 0, 0, 0, height, width);
    for (var y = 0; y < width; y++) {
      inverseDCTHorizontal(
          scratch0[y], dest[startOutY + y], 0, startOutX, logHeight, height);
    }
  } else {
    transposeMatrixInto(src, scratch0, startInY, startInX, 0, 0, height, width);
    for (var y = 0; y < width; y++) {
      inverseDCTHorizontal(scratch0[y], scratch1[y], 0, 0, logHeight, height);
    }
    transposeMatrixInto(scratch1, scratch0, 0, 0, 0, 0, width, height);
    for (var y = 0; y < height; y++) {
      inverseDCTHorizontal(
          scratch0[y], dest[startOutY + y], 0, startOutX, logWidth, width);
    }
  }
}

/// 2D forward DCT (used to produce LLF coefficients from LF values).
void forwardDCT2D(
    List<Float32List> src,
    List<Float32List> dest,
    int startInY,
    int startInX,
    int startOutY,
    int startOutX,
    int height,
    int width,
    List<Float32List> scratch0,
    List<Float32List> scratch1) {
  final yLogLength = ceilLog2(height);
  final xLogLength = ceilLog2(width);
  for (var y = 0; y < height; y++) {
    forwardDCTHorizontal(
        src[y + startInY], scratch0[y], startInX, 0, xLogLength, width);
  }
  transposeMatrixInto(scratch0, scratch1, 0, 0, 0, 0, height, width);
  for (var x = 0; x < width; x++) {
    forwardDCTHorizontal(scratch1[x], scratch0[x], 0, 0, yLogLength, height);
  }
  transposeMatrixInto(
      scratch0, dest, 0, 0, startOutY, startOutX, width, height);
}
