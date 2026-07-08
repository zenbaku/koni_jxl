import 'dart:math' as math;
import 'dart:typed_data';

import 'color_management.dart';

/// Applies a 3-component **matrix/TRC RGB** ICC profile as an output color
/// transform, converting koni's linear sRGB-primaries RGB (the state right
/// after the XYB inverse, before any transfer function) into the profile's
/// device-encoded values — the representation the JXL conformance reference
/// image (`ref.png` / `reference_image.npy`) uses for an ICC-tagged file.
///
/// Returns `null` from [tryParse] for any profile that is not a matrix/TRC RGB
/// profile — grayscale, CMYK, or LUT/CLUT (`A2B*`/`mAB `) profiles — in which
/// case the caller keeps its default (tagged/sRGB) transfer-function path.
///
/// **Derived and verified**, not fitted (see doc/spec_notes.md's ICC output
/// transform write-up). The conformance `progressive` case decodes, before its
/// transfer step, to linear light in sRGB primaries; the correct output is
/// `invTRC_profile(M · linear)`, where `M` maps sRGB-primary linear to the
/// profile's primary linear (identity when the profile's primaries are sRGB,
/// as `progressive`'s are — its only difference from sRGB is a parametric
/// gamma≈2.22 TRC). The transform was confirmed to reproduce `ref.png` exactly
/// at sampled points before this code was written.
class IccRgbOutputTransform {
  IccRgbOutputTransform._(this._m, this._trc);

  /// sRGB-primary linear → profile-primary linear (row-major 3x3).
  final List<List<double>> _m;

  /// Per-channel linear→device inverse-TRC LUTs (R, G, B).
  final List<Float32List> _trc;

  /// sRGB primaries → XYZ, Bradford-adapted to the D50 PCS (the standard sRGB
  /// v4 ICC colorants). Columns are the R/G/B colorant XYZ.
  static const _srgbD50 = [
    [0.436057, 0.385124, 0.143005],
    [0.222491, 0.716888, 0.060621],
    [0.013931, 0.097099, 0.713970],
  ];

  /// Parses [icc]; returns a transform for matrix/TRC RGB profiles, else null.
  static IccRgbOutputTransform? tryParse(Uint8List icc) {
    if (icc.length < 132) return null;
    int be32(int o) =>
        (icc[o] << 24) | (icc[o + 1] << 16) | (icc[o + 2] << 8) | icc[o + 3];
    // s15Fixed16 (signed): reinterpret the top bit.
    double fix16(int o) {
      final v = be32(o);
      return (v >= 0x80000000 ? v - 0x100000000 : v) / 65536.0;
    }

    String sig(int o) {
      if (o + 4 > icc.length) return '';
      return String.fromCharCodes(icc, o, o + 4);
    }

    // Data colour space must be RGB (bytes 16-19).
    if (sig(16) != 'RGB ') return null;
    final tagCount = be32(128);
    // Bound the tag table against the profile length (robustness contract).
    if (tagCount < 0 || 132 + tagCount * 12 > icc.length) return null;
    final tags = <String, (int off, int len)>{};
    for (var i = 0; i < tagCount; i++) {
      final e = 132 + i * 12;
      final off = be32(e + 4), len = be32(e + 8);
      if (off < 0 || len < 0 || off + len > icc.length) return null;
      tags[sig(e)] = (off, len);
    }
    // LUT-based profiles are out of scope — fall back to sRGB rather than
    // guess. (No conformance case exercises them; documented in spec_notes.)
    if (tags.containsKey('A2B0') || tags.containsKey('mAB ')) return null;
    for (final t in ['rXYZ', 'gXYZ', 'bXYZ', 'rTRC', 'gTRC', 'bTRC']) {
      if (!tags.containsKey(t)) return null;
    }

    List<double> colorant(String tag) {
      final (off, _) = tags[tag]!;
      // 'XYZ ' type: 8-byte header then one XYZNumber (3 x s15Fixed16).
      return [fix16(off + 8), fix16(off + 12), fix16(off + 16)];
    }

    // Profile RGB->XYZ(D50): columns are the r/g/b colorants.
    final r = colorant('rXYZ'), g = colorant('gXYZ'), b = colorant('bXYZ');
    final prof = [
      [r[0], g[0], b[0]],
      [r[1], g[1], b[1]],
      [r[2], g[2], b[2]],
    ];
    final profInv = invertMatrix3x3(prof);
    if (profInv == null) return null;
    // M = prof^-1 · sRGB_D50 : sRGB-linear -> profile-linear.
    final m = matrixMultiply3(profInv, _srgbD50);

    final trc = <Float32List>[];
    for (final tag in ['rTRC', 'gTRC', 'bTRC']) {
      final lut = _parseInverseTrc(icc, tags[tag]!.$1, be32, fix16, sig);
      if (lut == null) return null;
      trc.add(lut);
    }
    return IccRgbOutputTransform._(m, trc);
  }

  /// Applies the transform in place: [r]/[g]/[b] rows hold linear light in
  /// sRGB primaries on entry and the profile's device values (0..1) on exit.
  void apply(List<Float32List> r, List<Float32List> g, List<Float32List> b) {
    final m00 = _m[0][0], m01 = _m[0][1], m02 = _m[0][2];
    final m10 = _m[1][0], m11 = _m[1][1], m12 = _m[1][2];
    final m20 = _m[2][0], m21 = _m[2][1], m22 = _m[2][2];
    final tr = _trc[0], tg = _trc[1], tb = _trc[2];
    for (var y = 0; y < r.length; y++) {
      final rr = r[y], gg = g[y], bb = b[y];
      for (var x = 0; x < rr.length; x++) {
        final rl = rr[x], gl = gg[x], bl = bb[x];
        rr[x] = _lookup(tr, m00 * rl + m01 * gl + m02 * bl);
        gg[x] = _lookup(tg, m10 * rl + m11 * gl + m12 * bl);
        bb[x] = _lookup(tb, m20 * rl + m21 * gl + m22 * bl);
      }
    }
  }

  static double _lookup(Float32List lut, double v) {
    final n = lut.length - 1;
    if (v <= 0) return lut[0];
    if (v >= 1) return lut[n];
    final f = v * n;
    final i = f.toInt();
    final t = f - i;
    return lut[i] * (1 - t) + lut[i + 1] * t;
  }

  /// Builds a [_lutSize]-entry inverse-TRC LUT (linear input in [0,1] →
  /// device output in [0,1]) by inverting the profile's device→linear curve.
  static Float32List? _parseInverseTrc(
      Uint8List icc,
      int off,
      int Function(int) be32,
      double Function(int) fix16,
      String Function(int) sig) {
    final type = sig(off);
    double Function(double) dev2lin;
    if (type == 'curv') {
      final count = be32(off + 8);
      if (count < 0 || off + 12 + count * 2 > icc.length) return null;
      if (count == 0) {
        dev2lin = (x) => x; // identity
      } else if (count == 1) {
        final g = ((icc[off + 12] << 8) | icc[off + 13]) / 256.0; // u8Fixed8
        dev2lin = (x) => math.pow(x < 0 ? 0 : x, g).toDouble();
      } else {
        final lut = Float64List(count);
        for (var k = 0; k < count; k++) {
          lut[k] =
              ((icc[off + 12 + k * 2] << 8) | icc[off + 13 + k * 2]) / 65535.0;
        }
        dev2lin = (x) {
          if (x <= 0) return lut[0];
          if (x >= 1) return lut[count - 1];
          final f = x * (count - 1);
          final i = f.toInt();
          return lut[i] + (lut[i + 1] - lut[i]) * (f - i);
        };
      }
    } else if (type == 'para') {
      final ft = (icc[off + 8] << 8) | icc[off + 9];
      final np = const {0: 1, 1: 3, 2: 4, 3: 5, 4: 7}[ft];
      if (np == null || off + 12 + np * 4 > icc.length) return null;
      final p = [for (var k = 0; k < np; k++) fix16(off + 12 + k * 4)];
      final g = p[0];
      double pw(double v) => math.pow(v < 0 ? 0 : v, g).toDouble();
      switch (ft) {
        case 0: // Y = X^g
          dev2lin = pw;
        case 1: // X>=-b/a: (aX+b)^g ; else 0
          dev2lin = (x) => x >= -p[2] / p[1] ? pw(p[1] * x + p[2]) : 0.0;
        case 2: // X>=-b/a: (aX+b)^g + c ; else c
          dev2lin =
              (x) => x >= -p[2] / p[1] ? pw(p[1] * x + p[2]) + p[3] : p[3];
        case 3: // X>=d: (aX+b)^g ; else cX
          dev2lin = (x) => x >= p[4] ? pw(p[1] * x + p[2]) : p[3] * x;
        default: // ft==4: X>=d: (aX+b)^g + c ; else cX + f
          dev2lin =
              (x) => x >= p[4] ? pw(p[1] * x + p[2]) + p[3] : p[3] * x + p[6];
      }
    } else {
      return null; // unknown TRC type
    }
    // Invert numerically: dev2lin is monotone non-decreasing on [0,1].
    const lutSize = 1024;
    final inv = Float32List(lutSize + 1);
    for (var k = 0; k <= lutSize; k++) {
      final targetLin = k / lutSize;
      var lo = 0.0, hi = 1.0;
      for (var it = 0; it < 30; it++) {
        final mid = (lo + hi) * 0.5;
        if (dev2lin(mid) < targetLin) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      inv[k] = (lo + hi) * 0.5;
    }
    return inv;
  }
}
