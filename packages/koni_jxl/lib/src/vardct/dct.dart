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

/// Fully-SIMD fused 8x8 inverse DCT: rows-in-vector loads, two in-register
/// 8x8 transposes (quadrant shuffleMix), four vector butterfly passes.
/// Offsets are in Float32x4 units; callers guarantee 8-pixel alignment.
void inverseDCT8x8Simd(List<Float32x4List> src, List<Float32x4List> dest,
    int srcY, int srcVX, int destY, int destVX) {
  final vis2 = Float32x4.splat(_invSqrt2);
  final vw40 = Float32x4.splat(_w4x0);
  final vw41 = Float32x4.splat(_w4x1);
  final vw80 = Float32x4.splat(_w8x0);
  final vw81 = Float32x4.splat(_w8x1);
  final vw82 = Float32x4.splat(_w8x2);
  final vw83 = Float32x4.splat(_w8x3);
  final r0 = src[srcY + 0];
  final l0 = r0[srcVX];
  final h0 = r0[srcVX + 1];
  final r1 = src[srcY + 1];
  final l1 = r1[srcVX];
  final h1 = r1[srcVX + 1];
  final r2 = src[srcY + 2];
  final l2 = r2[srcVX];
  final h2 = r2[srcVX + 1];
  final r3 = src[srcY + 3];
  final l3 = r3[srcVX];
  final h3 = r3[srcVX + 1];
  final r4 = src[srcY + 4];
  final l4 = r4[srcVX];
  final h4 = r4[srcVX + 1];
  final r5 = src[srcY + 5];
  final l5 = r5[srcVX];
  final h5 = r5[srcVX + 1];
  final r6 = src[srcY + 6];
  final l6 = r6[srcVX];
  final h6 = r6[srcVX + 1];
  final r7 = src[srcY + 7];
  final l7 = r7[srcVX];
  final h7 = r7[srcVX + 1];
  {
    final tas0 = l0.shuffleMix(l1, Float32x4.xzxz);
    final tas1 = l0.shuffleMix(l1, Float32x4.ywyw);
    final tas2 = l2.shuffleMix(l3, Float32x4.xzxz);
    final tas3 = l2.shuffleMix(l3, Float32x4.ywyw);
    final a0 = tas0.shuffleMix(tas2, Float32x4.xzxz);
    final a1 = tas1.shuffleMix(tas3, Float32x4.xzxz);
    final a2 = tas0.shuffleMix(tas2, Float32x4.ywyw);
    final a3 = tas1.shuffleMix(tas3, Float32x4.ywyw);
    final tbs0 = h0.shuffleMix(h1, Float32x4.xzxz);
    final tbs1 = h0.shuffleMix(h1, Float32x4.ywyw);
    final tbs2 = h2.shuffleMix(h3, Float32x4.xzxz);
    final tbs3 = h2.shuffleMix(h3, Float32x4.ywyw);
    final a4 = tbs0.shuffleMix(tbs2, Float32x4.xzxz);
    final a5 = tbs1.shuffleMix(tbs3, Float32x4.xzxz);
    final a6 = tbs0.shuffleMix(tbs2, Float32x4.ywyw);
    final a7 = tbs1.shuffleMix(tbs3, Float32x4.ywyw);
    final tcs0 = l4.shuffleMix(l5, Float32x4.xzxz);
    final tcs1 = l4.shuffleMix(l5, Float32x4.ywyw);
    final tcs2 = l6.shuffleMix(l7, Float32x4.xzxz);
    final tcs3 = l6.shuffleMix(l7, Float32x4.ywyw);
    final b0 = tcs0.shuffleMix(tcs2, Float32x4.xzxz);
    final b1 = tcs1.shuffleMix(tcs3, Float32x4.xzxz);
    final b2 = tcs0.shuffleMix(tcs2, Float32x4.ywyw);
    final b3 = tcs1.shuffleMix(tcs3, Float32x4.ywyw);
    final tds0 = h4.shuffleMix(h5, Float32x4.xzxz);
    final tds1 = h4.shuffleMix(h5, Float32x4.ywyw);
    final tds2 = h6.shuffleMix(h7, Float32x4.xzxz);
    final tds3 = h6.shuffleMix(h7, Float32x4.ywyw);
    final b4 = tds0.shuffleMix(tds2, Float32x4.xzxz);
    final b5 = tds1.shuffleMix(tds3, Float32x4.xzxz);
    final b6 = tds0.shuffleMix(tds2, Float32x4.ywyw);
    final b7 = tds1.shuffleMix(tds3, Float32x4.ywyw);
    final paee0 = a0 + a4;
    final paee1 = a0 - a4;
    final paed1 = (a2 + a6) * vis2;
    final paet0 = (a2 + paed1) * vw40;
    final paet1 = (a2 - paed1) * vw41;
    final pae0 = paee0 + paet0;
    final pae3 = paee0 - paet0;
    final pae1 = paee1 + paet1;
    final pae2 = paee1 - paet1;
    final paf1 = (a1 + a3) * vis2;
    final paf2 = (a3 + a5) * vis2;
    final paf3 = (a5 + a7) * vis2;
    final pag0 = a1 + paf2;
    final pag1 = a1 - paf2;
    final pah1 = (paf1 + paf3) * vis2;
    final pau0 = (paf1 + pah1) * vw40;
    final pau1 = (paf1 - pah1) * vw41;
    final pat0 = (pag0 + pau0) * vw80;
    final pat3 = (pag0 - pau0) * vw83;
    final pat1 = (pag1 + pau1) * vw81;
    final pat2 = (pag1 - pau1) * vw82;
    final pa0 = pae0 + pat0;
    final pa7 = pae0 - pat0;
    final pa1 = pae1 + pat1;
    final pa6 = pae1 - pat1;
    final pa2 = pae2 + pat2;
    final pa5 = pae2 - pat2;
    final pa3 = pae3 + pat3;
    final pa4 = pae3 - pat3;
    final pbee0 = b0 + b4;
    final pbee1 = b0 - b4;
    final pbed1 = (b2 + b6) * vis2;
    final pbet0 = (b2 + pbed1) * vw40;
    final pbet1 = (b2 - pbed1) * vw41;
    final pbe0 = pbee0 + pbet0;
    final pbe3 = pbee0 - pbet0;
    final pbe1 = pbee1 + pbet1;
    final pbe2 = pbee1 - pbet1;
    final pbf1 = (b1 + b3) * vis2;
    final pbf2 = (b3 + b5) * vis2;
    final pbf3 = (b5 + b7) * vis2;
    final pbg0 = b1 + pbf2;
    final pbg1 = b1 - pbf2;
    final pbh1 = (pbf1 + pbf3) * vis2;
    final pbu0 = (pbf1 + pbh1) * vw40;
    final pbu1 = (pbf1 - pbh1) * vw41;
    final pbt0 = (pbg0 + pbu0) * vw80;
    final pbt3 = (pbg0 - pbu0) * vw83;
    final pbt1 = (pbg1 + pbu1) * vw81;
    final pbt2 = (pbg1 - pbu1) * vw82;
    final pb0 = pbe0 + pbt0;
    final pb7 = pbe0 - pbt0;
    final pb1 = pbe1 + pbt1;
    final pb6 = pbe1 - pbt1;
    final pb2 = pbe2 + pbt2;
    final pb5 = pbe2 - pbt2;
    final pb3 = pbe3 + pbt3;
    final pb4 = pbe3 - pbt3;
    final uas0 = pa0.shuffleMix(pa1, Float32x4.xzxz);
    final uas1 = pa0.shuffleMix(pa1, Float32x4.ywyw);
    final uas2 = pa2.shuffleMix(pa3, Float32x4.xzxz);
    final uas3 = pa2.shuffleMix(pa3, Float32x4.ywyw);
    final rl0 = uas0.shuffleMix(uas2, Float32x4.xzxz);
    final rl1 = uas1.shuffleMix(uas3, Float32x4.xzxz);
    final rl2 = uas0.shuffleMix(uas2, Float32x4.ywyw);
    final rl3 = uas1.shuffleMix(uas3, Float32x4.ywyw);
    final ubs0 = pa4.shuffleMix(pa5, Float32x4.xzxz);
    final ubs1 = pa4.shuffleMix(pa5, Float32x4.ywyw);
    final ubs2 = pa6.shuffleMix(pa7, Float32x4.xzxz);
    final ubs3 = pa6.shuffleMix(pa7, Float32x4.ywyw);
    final rh0 = ubs0.shuffleMix(ubs2, Float32x4.xzxz);
    final rh1 = ubs1.shuffleMix(ubs3, Float32x4.xzxz);
    final rh2 = ubs0.shuffleMix(ubs2, Float32x4.ywyw);
    final rh3 = ubs1.shuffleMix(ubs3, Float32x4.ywyw);
    final ucs0 = pb0.shuffleMix(pb1, Float32x4.xzxz);
    final ucs1 = pb0.shuffleMix(pb1, Float32x4.ywyw);
    final ucs2 = pb2.shuffleMix(pb3, Float32x4.xzxz);
    final ucs3 = pb2.shuffleMix(pb3, Float32x4.ywyw);
    final rl4 = ucs0.shuffleMix(ucs2, Float32x4.xzxz);
    final rl5 = ucs1.shuffleMix(ucs3, Float32x4.xzxz);
    final rl6 = ucs0.shuffleMix(ucs2, Float32x4.ywyw);
    final rl7 = ucs1.shuffleMix(ucs3, Float32x4.ywyw);
    final uds0 = pb4.shuffleMix(pb5, Float32x4.xzxz);
    final uds1 = pb4.shuffleMix(pb5, Float32x4.ywyw);
    final uds2 = pb6.shuffleMix(pb7, Float32x4.xzxz);
    final uds3 = pb6.shuffleMix(pb7, Float32x4.ywyw);
    final rh4 = uds0.shuffleMix(uds2, Float32x4.xzxz);
    final rh5 = uds1.shuffleMix(uds3, Float32x4.xzxz);
    final rh6 = uds0.shuffleMix(uds2, Float32x4.ywyw);
    final rh7 = uds1.shuffleMix(uds3, Float32x4.ywyw);
    final qaee0 = rl0 + rl4;
    final qaee1 = rl0 - rl4;
    final qaed1 = (rl2 + rl6) * vis2;
    final qaet0 = (rl2 + qaed1) * vw40;
    final qaet1 = (rl2 - qaed1) * vw41;
    final qae0 = qaee0 + qaet0;
    final qae3 = qaee0 - qaet0;
    final qae1 = qaee1 + qaet1;
    final qae2 = qaee1 - qaet1;
    final qaf1 = (rl1 + rl3) * vis2;
    final qaf2 = (rl3 + rl5) * vis2;
    final qaf3 = (rl5 + rl7) * vis2;
    final qag0 = rl1 + qaf2;
    final qag1 = rl1 - qaf2;
    final qah1 = (qaf1 + qaf3) * vis2;
    final qau0 = (qaf1 + qah1) * vw40;
    final qau1 = (qaf1 - qah1) * vw41;
    final qat0 = (qag0 + qau0) * vw80;
    final qat3 = (qag0 - qau0) * vw83;
    final qat1 = (qag1 + qau1) * vw81;
    final qat2 = (qag1 - qau1) * vw82;
    final ol0 = qae0 + qat0;
    final ol7 = qae0 - qat0;
    final ol1 = qae1 + qat1;
    final ol6 = qae1 - qat1;
    final ol2 = qae2 + qat2;
    final ol5 = qae2 - qat2;
    final ol3 = qae3 + qat3;
    final ol4 = qae3 - qat3;
    final qbee0 = rh0 + rh4;
    final qbee1 = rh0 - rh4;
    final qbed1 = (rh2 + rh6) * vis2;
    final qbet0 = (rh2 + qbed1) * vw40;
    final qbet1 = (rh2 - qbed1) * vw41;
    final qbe0 = qbee0 + qbet0;
    final qbe3 = qbee0 - qbet0;
    final qbe1 = qbee1 + qbet1;
    final qbe2 = qbee1 - qbet1;
    final qbf1 = (rh1 + rh3) * vis2;
    final qbf2 = (rh3 + rh5) * vis2;
    final qbf3 = (rh5 + rh7) * vis2;
    final qbg0 = rh1 + qbf2;
    final qbg1 = rh1 - qbf2;
    final qbh1 = (qbf1 + qbf3) * vis2;
    final qbu0 = (qbf1 + qbh1) * vw40;
    final qbu1 = (qbf1 - qbh1) * vw41;
    final qbt0 = (qbg0 + qbu0) * vw80;
    final qbt3 = (qbg0 - qbu0) * vw83;
    final qbt1 = (qbg1 + qbu1) * vw81;
    final qbt2 = (qbg1 - qbu1) * vw82;
    final oh0 = qbe0 + qbt0;
    final oh7 = qbe0 - qbt0;
    final oh1 = qbe1 + qbt1;
    final oh6 = qbe1 - qbt1;
    final oh2 = qbe2 + qbt2;
    final oh5 = qbe2 - qbt2;
    final oh3 = qbe3 + qbt3;
    final oh4 = qbe3 - qbt3;
    final d0 = dest[destY + 0];
    d0[destVX] = ol0;
    d0[destVX + 1] = oh0;
    final d1 = dest[destY + 1];
    d1[destVX] = ol1;
    d1[destVX + 1] = oh1;
    final d2 = dest[destY + 2];
    d2[destVX] = ol2;
    d2[destVX + 1] = oh2;
    final d3 = dest[destY + 3];
    d3[destVX] = ol3;
    d3[destVX + 1] = oh3;
    final d4 = dest[destY + 4];
    d4[destVX] = ol4;
    d4[destVX + 1] = oh4;
    final d5 = dest[destY + 5];
    d5[destVX] = ol5;
    d5[destVX + 1] = oh5;
    final d6 = dest[destY + 6];
    d6[destVX] = ol6;
    d6[destVX + 1] = oh6;
    final d7 = dest[destY + 7];
    d7[destVX] = ol7;
    d7[destVX + 1] = oh7;
  }
}
