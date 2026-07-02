import 'dart:math' as math;

import 'package:koni_jxl/src/util/image_buffer.dart';
import 'package:koni_jxl/src/vardct/dct.dart';
import 'package:test/test.dart';

/// Naive O(n^2) IDCT matching the jxl convention:
/// out[k] = src[0] + sum_{n>=1} src[n] * sqrt(2) * cos(pi*n*(k+0.5)/s).
List<double> naiveIdct1d(List<double> src) {
  final s = src.length;
  return List.generate(s, (k) {
    var total = src[0];
    for (var n = 1; n < s; n++) {
      total += src[n] * math.sqrt2 * math.cos(math.pi * n * (k + 0.5) / s);
    }
    return total;
  });
}

void main() {
  final rng = math.Random(42);

  for (final (h, w) in [
    (8, 8),
    (16, 16),
    (32, 32),
    (64, 64),
    (16, 32),
    (32, 16),
    (4, 8),
    (8, 4)
  ]) {
    test('inverseDCT2D matches naive reference for ${h}x$w', () {
      final coeffs = floatMatrix(h, w);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          coeffs[y][x] = rng.nextDouble() * 2 - 1;
        }
      }
      final dest = floatMatrix(h, w);
      final s0 = floatMatrix(256, 256);
      final s1 = floatMatrix(256, 256);
      inverseDCT2D(coeffs, dest, 0, 0, 0, 0, h, w, s0, s1, false);

      // Naive: rows of coeffs are IDCT'd along... follow the same data flow:
      // transpose -> idct columns (height) -> transpose -> idct rows (width).
      final m =
          List.generate(h, (y) => List.generate(w, (x) => coeffs[y][x] + 0.0));
      // idct vertically
      for (var x = 0; x < w; x++) {
        final col = naiveIdct1d([for (var y = 0; y < h; y++) m[y][x]]);
        for (var y = 0; y < h; y++) {
          m[y][x] = col[y];
        }
      }
      // idct horizontally
      for (var y = 0; y < h; y++) {
        m[y] = naiveIdct1d(m[y]);
      }
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          expect(dest[y][x], closeTo(m[y][x], 1e-3),
              reason: 'mismatch at ($y, $x)');
        }
      }
    });

    test('forward then inverse round-trips for ${h}x$w', () {
      final src = floatMatrix(h, w);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          src[y][x] = rng.nextDouble() * 2 - 1;
        }
      }
      final coeffs = floatMatrix(h, w);
      final dest = floatMatrix(h, w);
      final s0 = floatMatrix(256, 256);
      final s1 = floatMatrix(256, 256);
      forwardDCT2D(src, coeffs, 0, 0, 0, 0, h, w, s0, s1);
      inverseDCT2D(coeffs, dest, 0, 0, 0, 0, h, w, s0, s1, false);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          expect(dest[y][x], closeTo(src[y][x], 1e-3),
              reason: 'roundtrip mismatch at ($y, $x)');
        }
      }
    });
  }

  test('inverseDCT8x8Simd matches the scalar 8x8 path', () {
    final src = floatMatrix(16, 16);
    final destScalar = floatMatrix(16, 16);
    final destSimd = floatMatrix(16, 16);
    final rng = math.Random(42);
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        src[y][x] = rng.nextDouble() * 2 - 1;
      }
    }
    final s0 = floatMatrix(8, 8);
    final s1 = floatMatrix(8, 8);
    inverseDCT2D(src, destScalar, 8, 8, 8, 8, 8, 8, s0, s1, false);
    inverseDCT8x8Simd(
        rowVectorViews(src), rowVectorViews(destSimd), 8, 2, 8, 2);
    for (var y = 8; y < 16; y++) {
      for (var x = 8; x < 16; x++) {
        expect(destSimd[y][x], closeTo(destScalar[y][x], 1e-4),
            reason: 'y=$y x=$x');
      }
    }
  });
}
