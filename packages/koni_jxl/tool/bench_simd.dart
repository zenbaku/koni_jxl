// Viability benchmark for Float32x4 SIMD in the decoder hot paths.
// Rules honored: vectors live only in locals, storage is Float32x4List,
// no Int32x4, no vectors crossing non-inlined call boundaries.
import 'dart:typed_data';

import 'package:koni_jxl/src/util/image_buffer.dart';

const _is2 = 0.7071067811865476;
const _w40 = 0.76536686473017945;
const _w41 = 1.8477590650225735;
const _w80 = 0.72095982200694791;
const _w81 = 0.85043009476725644;
const _w82 = 1.2728041762558433;
const _w83 = 3.6245097854115502;

// ---------------- A: alignment probe ----------------
void alignmentProbe() {
  final rows = floatMatrix(4, 256);
  try {
    final v = Float32x4List.sublistView(rows[1]);
    v[0] += Float32x4.splat(0);
    print('A: Float32x4List.sublistView(Float32List row) works, '
        'len=${v.length}');
  } catch (e) {
    print('A: sublistView FAILED: $e');
  }
  // Offset view (8 floats in = 32 bytes)
  try {
    final v = Float32x4List.sublistView(rows[1], 2);
    v[0] += Float32x4.splat(0);
    print('A: offset sublistView(row, 2 vecs) works');
  } catch (e) {
    print('A: offset sublistView FAILED: $e');
  }
}

// ---------------- B: opsin-like kernel ----------------
double opsinScalar(List<Float32List> x, List<Float32List> y,
    List<Float32List> b, Float32List m) {
  final h = x.length;
  final w = x[0].length;
  for (var r = 0; r < h; r++) {
    final xr = x[r];
    final yr = y[r];
    final br = b[r];
    for (var i = 0; i < w; i++) {
      final gl = yr[i] + xr[i] - 0.0037930734;
      final gm = yr[i] - xr[i] - 0.0037930734;
      final gs = br[i] - 0.0037930734;
      final l = gl * gl * gl + 0.0037930734;
      final mm = gm * gm * gm + 0.0037930734;
      final s = gs * gs * gs + 0.0037930734;
      xr[i] = m[0] * l + m[1] * mm + m[2] * s;
      yr[i] = m[3] * l + m[4] * mm + m[5] * s;
      br[i] = m[6] * l + m[7] * mm + m[8] * s;
    }
  }
  return x[h ~/ 2][w ~/ 2];
}

double opsinSimd(List<Float32x4List> x, List<Float32x4List> y,
    List<Float32x4List> b, Float32List m) {
  final h = x.length;
  final w = x[0].length;
  final bias = Float32x4.splat(0.0037930734);
  final m0 = Float32x4.splat(m[0]);
  final m1 = Float32x4.splat(m[1]);
  final m2 = Float32x4.splat(m[2]);
  final m3 = Float32x4.splat(m[3]);
  final m4 = Float32x4.splat(m[4]);
  final m5 = Float32x4.splat(m[5]);
  final m6 = Float32x4.splat(m[6]);
  final m7 = Float32x4.splat(m[7]);
  final m8 = Float32x4.splat(m[8]);
  for (var r = 0; r < h; r++) {
    final xr = x[r];
    final yr = y[r];
    final br = b[r];
    for (var i = 0; i < w; i++) {
      final xv = xr[i];
      final yv = yr[i];
      final bv = br[i];
      final gl = yv + xv - bias;
      final gm = yv - xv - bias;
      final gs = bv - bias;
      final l = gl * gl * gl + bias;
      final mm = gm * gm * gm + bias;
      final s = gs * gs * gs + bias;
      xr[i] = m0 * l + m1 * mm + m2 * s;
      yr[i] = m3 * l + m4 * mm + m5 * s;
      br[i] = m6 * l + m7 * mm + m8 * s;
    }
  }
  return x[h ~/ 2][w ~/ 4].x;
}

// ---------------- C: idct8 butterfly over columns ----------------
// Scalar: one column at a time (like the fused kernel's column pass).
double idctColsScalar(Float32List t, Float32List out) {
  for (var x = 0; x < 256; x++) {
    final c0 = t[x];
    final c1 = t[256 + x];
    final c2 = t[512 + x];
    final c3 = t[768 + x];
    final c4 = t[1024 + x];
    final c5 = t[1280 + x];
    final c6 = t[1536 + x];
    final c7 = t[1792 + x];
    final ee0 = c0 + c4;
    final ee1 = c0 - c4;
    final ed1 = (c2 + c6) * _is2;
    final et0 = (c2 + ed1) * _w40;
    final et1 = (c2 - ed1) * _w41;
    final e0 = ee0 + et0;
    final e3 = ee0 - et0;
    final e1 = ee1 + et1;
    final e2 = ee1 - et1;
    final f1 = (c1 + c3) * _is2;
    final f2 = (c3 + c5) * _is2;
    final f3 = (c5 + c7) * _is2;
    final g0 = c1 + f2;
    final g1 = c1 - f2;
    final h1 = (f1 + f3) * _is2;
    final u0 = (f1 + h1) * _w40;
    final u1 = (f1 - h1) * _w41;
    final t0 = (g0 + u0) * _w80;
    final t3 = (g0 - u0) * _w83;
    final t1 = (g1 + u1) * _w81;
    final t2 = (g1 - u1) * _w82;
    out[x] = e0 + t0;
    out[1792 + x] = e0 - t0;
    out[256 + x] = e1 + t1;
    out[1536 + x] = e1 - t1;
    out[512 + x] = e2 + t2;
    out[1280 + x] = e2 - t2;
    out[768 + x] = e3 + t3;
    out[1024 + x] = e3 - t3;
  }
  return out[128];
}

// SIMD: 4 columns per vector.
double idctColsSimd(Float32x4List t, Float32x4List out) {
  final is2 = Float32x4.splat(_is2);
  final w40 = Float32x4.splat(_w40);
  final w41 = Float32x4.splat(_w41);
  final w80 = Float32x4.splat(_w80);
  final w81 = Float32x4.splat(_w81);
  final w82 = Float32x4.splat(_w82);
  final w83 = Float32x4.splat(_w83);
  for (var x = 0; x < 64; x++) {
    final c0 = t[x];
    final c1 = t[64 + x];
    final c2 = t[128 + x];
    final c3 = t[192 + x];
    final c4 = t[256 + x];
    final c5 = t[320 + x];
    final c6 = t[384 + x];
    final c7 = t[448 + x];
    final ee0 = c0 + c4;
    final ee1 = c0 - c4;
    final ed1 = (c2 + c6) * is2;
    final et0 = (c2 + ed1) * w40;
    final et1 = (c2 - ed1) * w41;
    final e0 = ee0 + et0;
    final e3 = ee0 - et0;
    final e1 = ee1 + et1;
    final e2 = ee1 - et1;
    final f1 = (c1 + c3) * is2;
    final f2 = (c3 + c5) * is2;
    final f3 = (c5 + c7) * is2;
    final g0 = c1 + f2;
    final g1 = c1 - f2;
    final h1 = (f1 + f3) * is2;
    final u0 = (f1 + h1) * w40;
    final u1 = (f1 - h1) * w41;
    final t0 = (g0 + u0) * w80;
    final t3 = (g0 - u0) * w83;
    final t1 = (g1 + u1) * w81;
    final t2 = (g1 - u1) * w82;
    out[x] = e0 + t0;
    out[448 + x] = e0 - t0;
    out[64 + x] = e1 + t1;
    out[384 + x] = e1 - t1;
    out[128 + x] = e2 + t2;
    out[320 + x] = e2 - t2;
    out[192 + x] = e3 + t3;
    out[256 + x] = e3 - t3;
  }
  return out[32].x;
}

// ---------------- D: EPF-like unconditional kernel ----------------
double epfScalar(
    List<Float32List> input, List<Float32List> output, int height, int width) {
  for (var y = 2; y < height - 2; y++) {
    final rM1 = input[y - 1];
    final r0 = input[y];
    final rP1 = input[y + 1];
    final out = output[y];
    for (var x = 4; x < width - 4; x++) {
      final c0 = r0[x];
      final cN = rM1[x];
      final cS = rP1[x];
      final cW = r0[x - 1];
      final cE = r0[x + 1];
      var sumW = 1.0;
      var sum = c0;
      var w = 1 - (c0 - cN).abs() * 20.0;
      if (w < 0) w = 0;
      sumW += w;
      sum += cN * w;
      w = 1 - (c0 - cS).abs() * 20.0;
      if (w < 0) w = 0;
      sumW += w;
      sum += cS * w;
      w = 1 - (c0 - cW).abs() * 20.0;
      if (w < 0) w = 0;
      sumW += w;
      sum += cW * w;
      w = 1 - (c0 - cE).abs() * 20.0;
      if (w < 0) w = 0;
      sumW += w;
      sum += cE * w;
      out[x] = sum / sumW;
    }
  }
  return output[height ~/ 2][width ~/ 2];
}

double epfSimd(List<Float32x4List> input, List<Float32x4List> output,
    int height, int width4) {
  final one = Float32x4.splat(1.0);
  final zero = Float32x4.zero();
  final k = Float32x4.splat(20.0);
  for (var y = 2; y < height - 2; y++) {
    final rM1 = input[y - 1];
    final r0 = input[y];
    final rP1 = input[y + 1];
    final out = output[y];
    for (var i = 1; i < width4 - 1; i++) {
      final c0 = r0[i];
      final cN = rM1[i];
      final cS = rP1[i];
      final prev = r0[i - 1];
      final next = r0[i + 1];
      // shifted-by-one neighbors via shuffle + lane insert
      final cW = c0.shuffle(Float32x4.xxyz).withX(prev.w);
      final cE = c0.shuffle(Float32x4.yzww).withW(next.x);
      var sumW = one;
      var sum = c0;
      var w = (one - (c0 - cN).abs() * k).max(zero);
      sumW += w;
      sum += cN * w;
      w = (one - (c0 - cS).abs() * k).max(zero);
      sumW += w;
      sum += cS * w;
      w = (one - (c0 - cW).abs() * k).max(zero);
      sumW += w;
      sum += cW * w;
      w = (one - (c0 - cE).abs() * k).max(zero);
      sumW += w;
      sum += cE * w;
      out[i] = sum / sumW;
    }
  }
  return output[height ~/ 2][width4 ~/ 2].x;
}

void main() {
  alignmentProbe();

  // B
  const h = 1024, w = 2048;
  final ms = Float32List.fromList(
      [11.03, -9.87, -0.16, -3.25, 4.42, -0.16, -3.66, 2.71, 1.94]);
  List<List<Float32List>> mkScalar() => [
        floatMatrix(h, w),
        floatMatrix(h, w),
        floatMatrix(h, w),
      ];
  List<List<Float32x4List>> mkSimd() => [
        for (var c = 0; c < 3; c++)
          List.generate(h, (_) => Float32x4List(w ~/ 4), growable: false),
      ];
  final sc = mkScalar();
  final sv = mkSimd();
  for (var r = 0; r < h; r++) {
    for (var i = 0; i < w; i++) {
      final v = ((i * 31 + r * 17) & 255) / 255.0;
      for (var c = 0; c < 3; c++) {
        sc[c][r][i] = v;
        Float32List.view(sv[c][r].buffer)[i] = v;
      }
    }
  }
  for (var rep = 0; rep < 2; rep++) {
    var sw = Stopwatch()..start();
    final a = opsinScalar(sc[0], sc[1], sc[2], ms);
    print('B opsin scalar: ${sw.elapsedMilliseconds} ms ($a)');
    sw = Stopwatch()..start();
    final b = opsinSimd(sv[0], sv[1], sv[2], ms);
    print('B opsin simd:   ${sw.elapsedMilliseconds} ms ($b)');
  }

  // C
  final t = Float32List(2048);
  for (var i = 0; i < 2048; i++) {
    t[i] = ((i * 31) & 255) / 255.0;
  }
  final outS = Float32List(2048);
  final tV = Float32x4List(512);
  Float32List.view(tV.buffer).setAll(0, t);
  final outV = Float32x4List(512);
  const reps = 100000;
  for (var rep = 0; rep < 2; rep++) {
    var sw = Stopwatch()..start();
    var acc = 0.0;
    for (var i = 0; i < reps; i++) {
      acc += idctColsScalar(t, outS);
    }
    print('C idct-cols scalar: '
        '${(sw.elapsedMicroseconds / reps * 1000).toStringAsFixed(0)} ns/256cols ($acc)');
    sw = Stopwatch()..start();
    acc = 0.0;
    for (var i = 0; i < reps; i++) {
      acc += idctColsSimd(tV, outV);
    }
    print('C idct-cols simd:   '
        '${(sw.elapsedMicroseconds / reps * 1000).toStringAsFixed(0)} ns/256cols ($acc)');
  }

  // D
  final ein = floatMatrix(1536, 2208);
  final eout = floatMatrix(1536, 2208);
  final einV = List.generate(1536, (_) => Float32x4List(552), growable: false);
  final eoutV = List.generate(1536, (_) => Float32x4List(552), growable: false);
  for (var y = 0; y < 1536; y++) {
    for (var x = 0; x < 2208; x++) {
      final v = ((x * 31 + y * 17) & 255) / 255.0;
      ein[y][x] = v;
      Float32List.view(einV[y].buffer)[x] = v;
    }
  }
  for (var rep = 0; rep < 2; rep++) {
    var sw = Stopwatch()..start();
    final a = epfScalar(ein, eout, 1536, 2208);
    print('D epf scalar: ${sw.elapsedMilliseconds} ms ($a)');
    sw = Stopwatch()..start();
    final b = epfSimd(einV, eoutV, 1536, 552);
    print('D epf simd:   ${sw.elapsedMilliseconds} ms ($b)');
  }
}
