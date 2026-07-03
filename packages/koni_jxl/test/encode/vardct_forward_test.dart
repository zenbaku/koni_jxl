import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/color/opsin_inverse.dart';
import 'package:koni_jxl/src/encode/vardct/xyb_forward.dart';
import 'package:koni_jxl/src/vardct/dct.dart';
import 'package:test/test.dart';

/// L0 verification strategy (doc/lossy_encoder_plan.md): forward-transform
/// unit tests before any bitstream work. Both transforms here have no
/// bitstream dependency, so their correctness is checked directly against
/// the decoder's real inverse implementations.

void main() {
  test('XYB forward is the exact inverse of OpsinInverseMatrix.invertXyb', () {
    final rng = math.Random(1);
    const n = 200;
    final r = Float32List(n);
    final g = Float32List(n);
    final b = Float32List(n);
    for (var i = 0; i < n; i++) {
      r[i] = rng.nextDouble();
      g[i] = rng.nextDouble();
      b[i] = rng.nextDouble();
    }
    // Keep the originals; forward() below overwrites r/g/b with X/Y/B.
    final origR = Float32List.fromList(r);
    final origG = Float32List.fromList(g);
    final origB = Float32List.fromList(b);

    XybForward().forward([r], [g], [b]);

    // r/g/b now hold X/Y/B; invertXyb overwrites them back to linear RGB.
    const matrix = OpsinInverseMatrix();
    matrix.invertXyb([r], [g], [b], 255.0);

    for (var i = 0; i < n; i++) {
      expect(r[i], closeTo(origR[i], 1e-4), reason: 'R at $i');
      expect(g[i], closeTo(origG[i], 1e-4), reason: 'G at $i');
      expect(b[i], closeTo(origB[i], 1e-4), reason: 'B at $i');
    }
  });

  test('XYB forward round-trips black, white and primaries', () {
    const matrix = OpsinInverseMatrix();
    for (final (rv, gv, bv) in [
      (0.0, 0.0, 0.0),
      (1.0, 1.0, 1.0),
      (1.0, 0.0, 0.0),
      (0.0, 1.0, 0.0),
      (0.0, 0.0, 1.0),
      (0.5, 0.5, 0.5),
    ]) {
      final r = Float32List.fromList([rv]);
      final g = Float32List.fromList([gv]);
      final b = Float32List.fromList([bv]);
      XybForward().forward([r], [g], [b]);
      matrix.invertXyb([r], [g], [b], 255.0);
      expect(r[0], closeTo(rv, 1e-4));
      expect(g[0], closeTo(gv, 1e-4));
      expect(b[0], closeTo(bv, 1e-4));
    }
  });

  test('forward DCT8x8 followed by inverse DCT8x8 is the identity', () {
    final rng = math.Random(2);
    final src = List.generate(8, (_) => Float32List(8));
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        src[y][x] = rng.nextDouble() * 2 - 1;
      }
    }
    final coeffs = List.generate(8, (_) => Float32List(8));
    final scratch0 = List.generate(8, (_) => Float32List(8));
    final scratch1 = List.generate(8, (_) => Float32List(8));
    forwardDCT2D(src, coeffs, 0, 0, 0, 0, 8, 8, scratch0, scratch1);

    final recon = List.generate(8, (_) => Float32List(8));
    inverseDCT2D(coeffs, recon, 0, 0, 0, 0, 8, 8, scratch0, scratch1, false);

    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        expect(recon[y][x], closeTo(src[y][x], 1e-4), reason: 'pixel ($y, $x)');
      }
    }
  });

  test('forward DCT8x8 DC coefficient is the block average', () {
    final src = List.generate(8, (_) => Float32List(8));
    var sum = 0.0;
    final rng = math.Random(3);
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final v = rng.nextDouble();
        src[y][x] = v;
        sum += v;
      }
    }
    final coeffs = List.generate(8, (_) => Float32List(8));
    final scratch0 = List.generate(8, (_) => Float32List(8));
    final scratch1 = List.generate(8, (_) => Float32List(8));
    forwardDCT2D(src, coeffs, 0, 0, 0, 0, 8, 8, scratch0, scratch1);
    expect(coeffs[0][0], closeTo(sum / 64, 1e-5));
  });

  test('forward DCT8x8 of a flat block has zero AC coefficients', () {
    final src = List.generate(8, (_) => Float32List(8)..fillRange(0, 8, 0.75));
    final coeffs = List.generate(8, (_) => Float32List(8));
    final scratch0 = List.generate(8, (_) => Float32List(8));
    final scratch1 = List.generate(8, (_) => Float32List(8));
    forwardDCT2D(src, coeffs, 0, 0, 0, 0, 8, 8, scratch0, scratch1);
    expect(coeffs[0][0], closeTo(0.75, 1e-6));
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        if (y == 0 && x == 0) continue;
        expect(coeffs[y][x], closeTo(0.0, 1e-6), reason: 'AC ($y, $x)');
      }
    }
  });
}
