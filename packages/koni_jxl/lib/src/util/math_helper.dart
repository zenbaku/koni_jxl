/// Small integer math helpers shared across the decoder.
library;

import 'dart:math' as math;

/// JPEG XL `UnpackSigned`: maps an unsigned value to a signed one,
/// interleaving positives and negatives (0, -1, 1, -2, 2, ...).
@pragma('vm:prefer-inline')
int unpackSigned(int value) =>
    (value & 1) == 0 ? value >> 1 : -(value >> 1) - 1;

@pragma('vm:prefer-inline')
int ceilDiv(int numerator, int denominator) =>
    (numerator + denominator - 1) ~/ denominator;

/// ceil(log2(x + 1)); the bit length of x.
@pragma('vm:prefer-inline')
int ceilLog1p(int x) => x.bitLength;

/// ceil(log2(x)) for x >= 1.
@pragma('vm:prefer-inline')
int ceilLog2(int x) => (x - 1).bitLength;

/// floor(log2(x + 1)).
@pragma('vm:prefer-inline')
int floorLog1p(int x) {
  final c = x.bitLength;
  return (x + 1) & x != 0 ? c - 1 : c;
}

/// Reflects an out-of-range coordinate back into [0, size).
@pragma('vm:prefer-inline')
int mirrorCoordinate(int coordinate, int size) {
  while (coordinate < 0 || coordinate >= size) {
    final tc = ~coordinate;
    coordinate = tc >= 0 ? tc : (size << 1) + tc;
  }
  return coordinate;
}

/// Error function approximation (Numerical Recipes for |z| > 1e-4,
/// Abramowitz & Stegun otherwise), as used by jxlatte's spline renderer.
double erf(double z) {
  final az = z.abs();
  double absErf;
  if (az > 1e-4) {
    final t = 1.0 / (az * 0.5 + 1.0);
    final u = t *
            (t *
                    (t *
                            (t *
                                    (t *
                                            (t *
                                                    (t *
                                                            (t *
                                                                    (t * 0.17087277 -
                                                                        0.82215223) +
                                                                1.48851587) -
                                                        1.13520398) +
                                                0.27886807) -
                                        0.18628806) +
                                0.09678418) +
                        0.37409196) +
                1.00002368) -
        1.26551223;
    absErf = 1.0 - t * math.exp(-z * z + u);
  } else {
    final t = 1.0 / (az * 0.47047 + 1.0);
    final u = t * (t * (t * 0.7478556 - 0.0958798) + 0.3480242);
    absErf = 1.0 - u * math.exp(-z * z);
  }
  return z < 0 ? -absErf : absErf;
}
