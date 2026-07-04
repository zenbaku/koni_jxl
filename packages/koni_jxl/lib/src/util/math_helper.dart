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

/// 2^[n] for any non-negative [n], computed without ever needing a `<<`
/// by more than 31: dart2js's shift/bitwise operators (`<<`, `>>`, `>>>`,
/// `&`, `|`, `^`) all coerce through a 32-bit integer first (mirroring raw
/// JavaScript's `ToInt32`/`ToUint32`), so results - not just shift amounts
/// - above 2^32 silently get truncated there, unlike the VM's real 64-bit
/// `int`. Multiplication and division do not have this limitation (plain
/// double arithmetic, exact as long as the true result fits in 2^53), so
/// [wideShl]/[wideShr] are built on those instead of `<<`/`>>` wherever a
/// shift amount OR an intermediate value could reach 32 bits.
@pragma('vm:prefer-inline')
int _pow2(int n) => n < 32 ? (1 << n) : (1 << (n - 32)) * 0x100000000;

/// Left-shifts non-negative [value] by [n] bits (n may be >= 32, and
/// [value] itself may already need more than 32 bits) - safe on dart2js
/// where a bare `<<` is not. See [_pow2]. Results are only exact while the
/// true product stays within 2^53 - true 64-bit-scale values are already
/// beyond what a JS-double-backed `int` can represent exactly on any
/// platform.
@pragma('vm:prefer-inline')
int wideShl(int value, int n) => value * _pow2(n);

/// Right-shifts non-negative [value] by [n] bits, the division-based
/// counterpart to [wideShl] for the same reason (also safe when [value]
/// itself needs more than 32 bits, unlike a bare `>>`).
@pragma('vm:prefer-inline')
int wideShr(int value, int n) => value ~/ _pow2(n);

/// Arithmetic right-shift of [value] (which may be negative, unlike
/// [wideShr]) by [n] bits, matching `>>`'s floor-toward-negative-infinity
/// semantics - needed wherever the *value*, not just the shift amount,
/// can exceed 32 bits (e.g. fixed-point `(a * b) >> k` products), since
/// Dart's `~/` truncates toward zero rather than flooring.
@pragma('vm:prefer-inline')
int wideShrSigned(int value, int n) {
  final divisor = _pow2(n);
  final q = value ~/ divisor;
  return value < 0 && q * divisor != value ? q - 1 : q;
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
