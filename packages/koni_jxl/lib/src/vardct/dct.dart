import 'dart:math' as math;
import 'dart:typed_data';

import '../util/math_helper.dart';

/// 1D DCT engine using the JXL scaling convention:
///
///   IDCT_N(c)[j] = c[0] + sum_{n>=1} c[n] * sqrt(2) * cos(pi*n*(j+0.5)/N)
///   DCT_N(x)[k]  = (alpha(k)/N) * sum_j x[j] * cos(pi*k*(j+0.5)/N)
///
/// Small sizes (<= 8) use direct transposed-LUT evaluation; larger sizes use
/// Lee's O(N log N) recursion with the sqrt(2) factors folded into the
/// lifting steps, matching the naive evaluation to float precision.

const _invSqrt2 = 0.7071067811865476;
const _w4x0 = 0.76536686473017956;
const _w4x1 = 1.8477590650225733;
const _w8x0 = 0.72095982200694797;
const _w8x1 = 0.85043009476725651;
const _w8x2 = 1.2727585805728339;
const _w8x3 = 3.6245097854115502;

/// lutT[log2(s)][k][n]: cos basis, transposed so the inner (n) loop is
/// sequential. Entry n==0 is 1 (folded into the DC term by the caller
/// loops). Sizes up to 8 only; larger sizes use the recursion.
final List<List<Float32List>> _lutT = () {
  final root2 = math.sqrt(2.0);
  return List.generate(4, (l) {
    final s = 1 << l;
    return List.generate(s, (k) {
      final lut = Float32List(s);
      lut[0] = 1.0;
      for (var n = 1; n < s; n++) {
        lut[n] = root2 * math.cos(math.pi * n * (k + 0.5) / s);
      }
      return lut;
    });
  });
}();

/// twiddles[log2(N)][j] = sqrt(2) / (2 * cos(pi*(j+0.5)/N)) for j < N/2.
final List<Float32List> _twiddles = List.generate(9, (l) {
  final n = 1 << l;
  final h = n >> 1;
  final t = Float32List(h < 1 ? 1 : h);
  for (var j = 0; j < h; j++) {
    t[j] = math.sqrt2 / (2 * math.cos(math.pi * (j + 0.5) / n));
  }
  return t;
});

/// Per-isolate scratch for the recursions (max size 256 -> 2*256 floats per
/// working set; two independent regions for extraction and copies).
final Float32List _scratch = Float32List(1024);

void _idct2(Float32List src, int so, Float32List dest, int dOff) {
  final a = src[so];
  final b = src[so + 1];
  dest[dOff] = a + b;
  dest[dOff + 1] = a - b;
}

void _idct4(Float32List src, int so, Float32List dest, int dOff) {
  final c0 = src[so];
  final c1 = src[so + 1];
  final c2 = src[so + 2];
  final c3 = src[so + 3];
  final e0 = c0 + c2;
  final e1 = c0 - c2;
  final d1 = (c1 + c3) * _invSqrt2;
  final t0 = (c1 + d1) * _w4x0;
  final t1 = (c1 - d1) * _w4x1;
  dest[dOff] = e0 + t0;
  dest[dOff + 3] = e0 - t0;
  dest[dOff + 1] = e1 + t1;
  dest[dOff + 2] = e1 - t1;
}

void _idct8(Float32List src, int so, Float32List dest, int dOff) {
  final c0 = src[so];
  final c1 = src[so + 1];
  final c2 = src[so + 2];
  final c3 = src[so + 3];
  final c4 = src[so + 4];
  final c5 = src[so + 5];
  final c6 = src[so + 6];
  final c7 = src[so + 7];
  // E = idct4 of even coefficients.
  final ee0 = c0 + c4;
  final ee1 = c0 - c4;
  final ed1 = (c2 + c6) * _invSqrt2;
  final et0 = (c2 + ed1) * _w4x0;
  final et1 = (c2 - ed1) * _w4x1;
  final e0 = ee0 + et0;
  final e3 = ee0 - et0;
  final e1 = ee1 + et1;
  final e2 = ee1 - et1;
  // T = idct4 of the lifted odd sequence.
  final f1 = (c1 + c3) * _invSqrt2;
  final f2 = (c3 + c5) * _invSqrt2;
  final f3 = (c5 + c7) * _invSqrt2;
  final g0 = c1 + f2;
  final g1 = c1 - f2;
  final h1 = (f1 + f3) * _invSqrt2;
  final u0 = (f1 + h1) * _w4x0;
  final u1 = (f1 - h1) * _w4x1;
  final t0 = (g0 + u0) * _w8x0;
  final t3 = (g0 - u0) * _w8x3;
  final t1 = (g1 + u1) * _w8x1;
  final t2 = (g1 - u1) * _w8x2;
  dest[dOff] = e0 + t0;
  dest[dOff + 7] = e0 - t0;
  dest[dOff + 1] = e1 + t1;
  dest[dOff + 6] = e1 - t1;
  dest[dOff + 2] = e2 + t2;
  dest[dOff + 5] = e2 - t2;
  dest[dOff + 3] = e3 + t3;
  dest[dOff + 4] = e3 - t3;
}

void _idctSmall(
    Float32List src, int srcOff, Float32List dest, int destOff, int n) {
  switch (n) {
    case 8:
      _idct8(src, srcOff, dest, destOff);
    case 4:
      _idct4(src, srcOff, dest, destOff);
    case 2:
      _idct2(src, srcOff, dest, destOff);
    default:
      dest[destOff] = src[srcOff];
  }
}

/// Recursive IDCT: input and output must not alias; scratch region
/// [so, so + 2n) is free for use.
void _idct(Float32List src, int srcOff, Float32List dest, int destOff, int n,
    int logN, int so) {
  if (n <= 8) {
    _idctSmall(src, srcOff, dest, destOff, n);
    return;
  }
  final h = n >> 1;
  final s = _scratch;
  // Extract even coefficients and the lifted odd sequence.
  for (var r = 0; r < h; r++) {
    s[so + r] = src[srcOff + 2 * r];
  }
  s[so + h] = src[srcOff + 1];
  for (var r = 1; r < h; r++) {
    s[so + h + r] =
        (src[srcOff + 2 * r - 1] + src[srcOff + 2 * r + 1]) * _invSqrt2;
  }
  // Recurse: E into dest lower half, T into dest upper half.
  _idct(s, so, dest, destOff, h, logN - 1, so + n);
  _idct(s, so + h, dest, destOff + h, h, logN - 1, so + n);
  // Save T (the upper half) before the butterfly overwrites it.
  for (var j = 0; j < h; j++) {
    s[so + j] = dest[destOff + h + j];
  }
  final w = _twiddles[logN];
  for (var j = 0; j < h; j++) {
    final e = dest[destOff + j];
    final o = w[j] * s[so + j];
    dest[destOff + j] = e + o;
    dest[destOff + n - 1 - j] = e - o;
  }
}

void _dctSmall(Float32List src, int srcOff, Float32List dest, int destOff,
    int logN, int n) {
  // G[k] = sum_j x[j] * alpha(k) * cos(pi*k*(j+0.5)/N); the table entry
  // _lutT[logN][j][k] is exactly alpha(k)*cos(pi*k*(j+0.5)/N), so accumulate
  // one source row at a time to keep the inner loop sequential.
  final lutJ = _lutT[logN];
  final x0 = src[srcOff];
  final lut0 = lutJ[0];
  for (var k = 0; k < n; k++) {
    dest[destOff + k] = x0 * lut0[k];
  }
  for (var j = 1; j < n; j++) {
    final xj = src[srcOff + j];
    final lut = lutJ[j];
    for (var k = 0; k < n; k++) {
      dest[destOff + k] += xj * lut[k];
    }
  }
}

/// Recursive unscaled forward transform G_N (caller divides by N).
void _dct(Float32List src, int srcOff, Float32List dest, int destOff, int n,
    int logN, int so) {
  if (n <= 8) {
    _dctSmall(src, srcOff, dest, destOff, logN, n);
    return;
  }
  final h = n >> 1;
  final s = _scratch;
  final w = _twiddles[logN];
  for (var j = 0; j < h; j++) {
    final a = src[srcOff + j];
    final b = src[srcOff + n - 1 - j];
    s[so + j] = a + b;
    s[so + h + j] = w[j] * (a - b);
  }
  _dct(s, so, dest, destOff, h, logN - 1, so + n);
  _dct(s, so + h, dest, destOff + h, h, logN - 1, so + n);
  // Copy Gu | Gv aside, then interleave with the lifting transpose.
  for (var j = 0; j < n; j++) {
    s[so + j] = dest[destOff + j];
  }
  for (var r = 0; r < h; r++) {
    dest[destOff + 2 * r] = s[so + r];
  }
  final gv = so + h;
  dest[destOff + 1] = s[gv] + (h > 1 ? s[gv + 1] * _invSqrt2 : 0);
  for (var r = 1; r < h; r++) {
    final next = r + 1 < h ? s[gv + r + 1] : 0.0;
    dest[destOff + 2 * r + 1] = (s[gv + r] + next) * _invSqrt2;
  }
}

/// One row of inverse DCT (DCT-III with jxl scaling).
void inverseDCTHorizontal(Float32List src, Float32List dest, int xStartIn,
    int xStartOut, int xLogLength, int xLength) {
  _idct(src, xStartIn, dest, xStartOut, xLength, xLogLength, 0);
}

/// One row of forward DCT (DCT-II with jxl scaling).
void forwardDCTHorizontal(Float32List src, Float32List dest, int xStartIn,
    int xStartOut, int xLogLength, int xLength) {
  _dct(src, xStartIn, dest, xStartOut, xLength, xLogLength, 0);
  final invLength = 1.0 / xLength;
  for (var k = 0; k < xLength; k++) {
    dest[xStartOut + k] *= invLength;
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

/// Fused, transpose-free 8x8 inverse DCT (the dominant block size).
void _inverseDCT8x8(List<Float32List> src, List<Float32List> dest, int startInY,
    int startInX, int startOutY, int startOutX, bool transposed) {
  final t = _scratch;
  for (var k = 0; k < 8; k++) {
    _idct8(src[startInY + k], startInX, t, k << 3);
  }
  if (transposed) {
    for (var x = 0; x < 8; x++) {
      final c0 = t[x];
      final c1 = t[8 + x];
      final c2 = t[16 + x];
      final c3 = t[24 + x];
      final c4 = t[32 + x];
      final c5 = t[40 + x];
      final c6 = t[48 + x];
      final c7 = t[56 + x];
      final ee0 = c0 + c4;
      final ee1 = c0 - c4;
      final ed1 = (c2 + c6) * _invSqrt2;
      final et0 = (c2 + ed1) * _w4x0;
      final et1 = (c2 - ed1) * _w4x1;
      final e0 = ee0 + et0;
      final e3 = ee0 - et0;
      final e1 = ee1 + et1;
      final e2 = ee1 - et1;
      final f1 = (c1 + c3) * _invSqrt2;
      final f2 = (c3 + c5) * _invSqrt2;
      final f3 = (c5 + c7) * _invSqrt2;
      final g0 = c1 + f2;
      final g1 = c1 - f2;
      final h1 = (f1 + f3) * _invSqrt2;
      final u0 = (f1 + h1) * _w4x0;
      final u1 = (f1 - h1) * _w4x1;
      final t0 = (g0 + u0) * _w8x0;
      final t3 = (g0 - u0) * _w8x3;
      final t1 = (g1 + u1) * _w8x1;
      final t2 = (g1 - u1) * _w8x2;
      final dr = dest[startOutY + x];
      dr[startOutX] = e0 + t0;
      dr[startOutX + 7] = e0 - t0;
      dr[startOutX + 1] = e1 + t1;
      dr[startOutX + 6] = e1 - t1;
      dr[startOutX + 2] = e2 + t2;
      dr[startOutX + 5] = e2 - t2;
      dr[startOutX + 3] = e3 + t3;
      dr[startOutX + 4] = e3 - t3;
    }
    return;
  }
  final r0 = dest[startOutY];
  final r1 = dest[startOutY + 1];
  final r2 = dest[startOutY + 2];
  final r3 = dest[startOutY + 3];
  final r4 = dest[startOutY + 4];
  final r5 = dest[startOutY + 5];
  final r6 = dest[startOutY + 6];
  final r7 = dest[startOutY + 7];
  for (var x = 0; x < 8; x++) {
    final c0 = t[x];
    final c1 = t[8 + x];
    final c2 = t[16 + x];
    final c3 = t[24 + x];
    final c4 = t[32 + x];
    final c5 = t[40 + x];
    final c6 = t[48 + x];
    final c7 = t[56 + x];
    final ee0 = c0 + c4;
    final ee1 = c0 - c4;
    final ed1 = (c2 + c6) * _invSqrt2;
    final et0 = (c2 + ed1) * _w4x0;
    final et1 = (c2 - ed1) * _w4x1;
    final e0 = ee0 + et0;
    final e3 = ee0 - et0;
    final e1 = ee1 + et1;
    final e2 = ee1 - et1;
    final f1 = (c1 + c3) * _invSqrt2;
    final f2 = (c3 + c5) * _invSqrt2;
    final f3 = (c5 + c7) * _invSqrt2;
    final g0 = c1 + f2;
    final g1 = c1 - f2;
    final h1 = (f1 + f3) * _invSqrt2;
    final u0 = (f1 + h1) * _w4x0;
    final u1 = (f1 - h1) * _w4x1;
    final t0 = (g0 + u0) * _w8x0;
    final t3 = (g0 - u0) * _w8x3;
    final t1 = (g1 + u1) * _w8x1;
    final t2 = (g1 - u1) * _w8x2;
    final ox = startOutX + x;
    r0[ox] = e0 + t0;
    r7[ox] = e0 - t0;
    r1[ox] = e1 + t1;
    r6[ox] = e1 - t1;
    r2[ox] = e2 + t2;
    r5[ox] = e2 - t2;
    r3[ox] = e3 + t3;
    r4[ox] = e3 - t3;
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
  if (height == 8 && width == 8) {
    _inverseDCT8x8(
        src, dest, startInY, startInX, startOutY, startOutX, transposed);
    return;
  }
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
