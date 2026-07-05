import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/color/opsin_inverse.dart';
import 'package:koni_jxl/src/encode/vardct/xyb_forward.dart';
import 'package:koni_jxl/src/vardct/dct.dart';
import 'package:koni_jxl/src/vardct/transform_type.dart';
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

  test('forward DCT32x32 followed by inverse DCT32x32 is the identity', () {
    // Tranche A (ROADMAP.md's "full 27-transform-type support"): the first
    // size beyond 8x8/16x16 exercises forwardDCT2D/inverseDCT2D at a size
    // neither the original L0 encoder nor this file's other tests ever
    // used — both are already generic over any power-of-2 height/width
    // (dct.dart only special-cases 8x8 for a fused SIMD path), but that
    // genericity was previously only exercised by the *decoder*.
    const n = 32;
    final rng = math.Random(4);
    final src = List.generate(n, (_) => Float32List(n));
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        src[y][x] = rng.nextDouble() * 2 - 1;
      }
    }
    final coeffs = List.generate(n, (_) => Float32List(n));
    final scratch0 = List.generate(n, (_) => Float32List(n));
    final scratch1 = List.generate(n, (_) => Float32List(n));
    forwardDCT2D(src, coeffs, 0, 0, 0, 0, n, n, scratch0, scratch1);

    final recon = List.generate(n, (_) => Float32List(n));
    inverseDCT2D(coeffs, recon, 0, 0, 0, 0, n, n, scratch0, scratch1, false);

    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        expect(recon[y][x], closeTo(src[y][x], 1e-3), reason: 'pixel ($y, $x)');
      }
    }
  });

  test(
      'DCT32x32 LLF inversion recovers the DC plane through the decoder\'s '
      'own _finalizeLLF construction', () {
    // The encoder's DC/LLF inversion (quantizeCandidate) must be the exact
    // algebraic inverse of the decoder's _finalizeLLF (hf_coefficients.dart):
    // forwardDCT2D over the dctSelect grid, then multiply by tt.llfScale
    // elementwise. This test verifies that relationship directly, at the
    // 4x4 dctSelect grid DCT32x32 uses (vs. DCT16x16's trivial 2x2 case,
    // which the shipped hand-unrolled Hadamard-like formula already
    // covered) — before the encoder's real pipeline is trusted to rely on
    // the generalized (any-grid-size) form.
    final tt = TransformType.byType(5); // DCT 32x32
    expect(tt.pixelHeight, 32);
    expect(tt.dctSelectHeight, 4);
    expect(tt.dctSelectWidth, 4);

    final rng = math.Random(5);
    final dcPlane = List.generate(
        tt.dctSelectHeight, (_) => Float32List(tt.dctSelectWidth));
    for (var y = 0; y < tt.dctSelectHeight; y++) {
      for (var x = 0; x < tt.dctSelectWidth; x++) {
        dcPlane[y][x] = rng.nextDouble() * 2 - 1;
      }
    }

    // Mirrors _finalizeLLF exactly: forward DCT over the dctSelect grid,
    // then scale by tt.llfScale -- this is what a real decoder would see
    // as the block's LLF corner.
    final scratch0 = List.generate(
        tt.dctSelectHeight, (_) => Float32List(tt.dctSelectWidth));
    final scratch1 = List.generate(
        tt.dctSelectHeight, (_) => Float32List(tt.dctSelectWidth));
    final llfCorner = List.generate(
        tt.dctSelectHeight, (_) => Float32List(tt.dctSelectWidth));
    forwardDCT2D(dcPlane, llfCorner, 0, 0, 0, 0, tt.dctSelectHeight,
        tt.dctSelectWidth, scratch0, scratch1);
    for (var y = 0; y < tt.dctSelectHeight; y++) {
      for (var x = 0; x < tt.dctSelectWidth; x++) {
        llfCorner[y][x] *= tt.llfScale[y * tt.dctSelectWidth + x];
      }
    }

    // The encoder's inverse: divide by llfScale, then inverseDCT2D over the
    // same grid should recover the original dcPlane values.
    final unscaled = List.generate(
        tt.dctSelectHeight, (_) => Float32List(tt.dctSelectWidth));
    for (var y = 0; y < tt.dctSelectHeight; y++) {
      for (var x = 0; x < tt.dctSelectWidth; x++) {
        unscaled[y][x] =
            llfCorner[y][x] / tt.llfScale[y * tt.dctSelectWidth + x];
      }
    }
    final recovered = List.generate(
        tt.dctSelectHeight, (_) => Float32List(tt.dctSelectWidth));
    inverseDCT2D(unscaled, recovered, 0, 0, 0, 0, tt.dctSelectHeight,
        tt.dctSelectWidth, scratch0, scratch1, false);

    for (var y = 0; y < tt.dctSelectHeight; y++) {
      for (var x = 0; x < tt.dctSelectWidth; x++) {
        expect(recovered[y][x], closeTo(dcPlane[y][x], 1e-4),
            reason: 'DC plane ($y, $x)');
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
