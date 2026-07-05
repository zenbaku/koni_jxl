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

  // Tranche A (ROADMAP.md's "full 27-transform-type support"): every square
  // DCT size beyond 8x8/16x16 exercises forwardDCT2D/inverseDCT2D at sizes
  // neither the original L0 encoder nor this file's other tests ever used —
  // both are already generic over any power-of-2 height/width (dct.dart
  // only special-cases 8x8 for a fused SIMD path), but that genericity was
  // previously only exercised by the *decoder*. One parameterized group
  // covers all four (32, 64, 128, 256) rather than hand-copying a test per
  // size, matching `_decideTransformLayout`'s own generic cascade. Tranche
  // B (16x8/8x16 first, types 6/7; then the rest, types 8-11/19/20/22/23/
  // 25/26) reuses the same loop with independent height/width — the first
  // genuinely rectangular cases here, exercising the LLF-inversion
  // sub-test below at a non-square `dctSelectHeight != dctSelectWidth`
  // grid for the first time.
  for (final typeIndex in [
    5, 18, 21, 24, // Tranche A square sizes
    6, 7, // DCT 16x8/8x16 (2:1 pair)
    8, 9, // DCT 32x8/8x32 (4:1 line, the only such case in the format)
    10, 11, // DCT 32x16/16x32 (2:1 pair)
    19, 20, // DCT 64x32/32x64 (2:1 pair)
    22, 23, // DCT 128x64/64x128 (2:1 pair)
    25, 26, // DCT 256x128/128x256 (2:1 pair)
  ]) {
    final tt = TransformType.byType(typeIndex);
    final ph = tt.pixelHeight, pw = tt.pixelWidth;

    test(
        'forward DCT${ph}x$pw followed by inverse DCT${ph}x$pw is the '
        'identity', () {
      final rng = math.Random(4);
      final src = List.generate(ph, (_) => Float32List(pw));
      for (var y = 0; y < ph; y++) {
        for (var x = 0; x < pw; x++) {
          src[y][x] = rng.nextDouble() * 2 - 1;
        }
      }
      final coeffs = List.generate(ph, (_) => Float32List(pw));
      // Scratch must be sized to the larger dimension in both axes, not
      // (ph, pw) — dct.dart's transposeMatrixInto writes an intermediate
      // shaped (pw, ph) partway through, which overflows an (ph, pw)-sized
      // buffer for a genuinely rectangular type (found by this test
      // failing with a RangeError before this fix; mirrors production's
      // own oversized scratchA/scratchB and dct_test.dart's 256x256
      // scratch convention).
      final scratchSize = math.max(ph, pw);
      final scratch0 =
          List.generate(scratchSize, (_) => Float32List(scratchSize));
      final scratch1 =
          List.generate(scratchSize, (_) => Float32List(scratchSize));
      forwardDCT2D(src, coeffs, 0, 0, 0, 0, ph, pw, scratch0, scratch1);

      final recon = List.generate(ph, (_) => Float32List(pw));
      inverseDCT2D(
          coeffs, recon, 0, 0, 0, 0, ph, pw, scratch0, scratch1, false);

      for (var y = 0; y < ph; y++) {
        for (var x = 0; x < pw; x++) {
          expect(recon[y][x], closeTo(src[y][x], 1e-3),
              reason: 'pixel ($y, $x)');
        }
      }
    });

    test(
        'DCT${ph}x$pw LLF inversion recovers the DC plane through the '
        'decoder\'s own _finalizeLLF construction', () {
      // The encoder's DC/LLF inversion (quantizeCandidate) must be the exact
      // algebraic inverse of the decoder's _finalizeLLF
      // (hf_coefficients.dart): forwardDCT2D over the dctSelect grid, then
      // multiply by tt.llfScale elementwise. This test verifies that
      // relationship directly, at each size's own dctSelect grid (up to
      // 32x32 for DCT256x256 — DCT16x16's trivial 2x2 case is the only one
      // the shipped hand-unrolled Hadamard-like formula ever covered) —
      // before the encoder's real pipeline is trusted to rely on the
      // generalized (any-grid-size) form.
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
      // as the block's LLF corner. Scratch sized to the larger dimension in
      // both axes -- see the identity test above for why.
      final llfScratchSize = math.max(tt.dctSelectHeight, tt.dctSelectWidth);
      final scratch0 =
          List.generate(llfScratchSize, (_) => Float32List(llfScratchSize));
      final scratch1 =
          List.generate(llfScratchSize, (_) => Float32List(llfScratchSize));
      final llfCorner = List.generate(
          tt.dctSelectHeight, (_) => Float32List(tt.dctSelectWidth));
      forwardDCT2D(dcPlane, llfCorner, 0, 0, 0, 0, tt.dctSelectHeight,
          tt.dctSelectWidth, scratch0, scratch1);
      for (var y = 0; y < tt.dctSelectHeight; y++) {
        for (var x = 0; x < tt.dctSelectWidth; x++) {
          llfCorner[y][x] *= tt.llfScale[y * tt.dctSelectWidth + x];
        }
      }

      // The encoder's inverse: divide by llfScale, then inverseDCT2D over
      // the same grid should recover the original dcPlane values.
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
  }

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

  // Tranche C (ROADMAP.md/spec_notes.md): the first "bespoke" transform
  // type -- unlike Tranche A/B (plain separable DCTs, differing only in
  // dctSelect footprint), the decoder reconstructs DCT4x4
  // (vardct_inverter.dart's TransformMethod.dct4 case) via a hand-derived
  // formula: a single-stage Hadamard-type butterfly (`_auxDCT2`, s=2)
  // combining the 4 quadrants' DC terms, plus a real 4x4 IDCT per
  // quadrant. `_decodeDct4`/`_encodeDct4` below mirror that formula and
  // its verified forward inverse directly (the same "duplicate the
  // decoder's private arithmetic in test code" pattern the LLF-inversion
  // test above already uses for `_finalizeLLF`) -- this is the PERMANENT
  // form of a check first done numerically in Python during planning (a
  // 64x64 basis-injection matrix, M @ E == I to 4.4e-16; see
  // doc/spec_notes.md), not a new derivation.
  group('DCT4x4 (Tranche C, bespoke, first slice)', () {
    // Mirrors vardct_inverter.dart's TransformMethod.dct4 case exactly,
    // for a single isolated 8x8 block at the origin (ppgY=ppgX=ppfY=ppfX=0).
    List<Float32List> decodeDct4(List<Float32List> cc) {
      final (d00, d01, d10, d11) = _dct4Butterfly(cc[0][0].toDouble(),
          cc[0][1].toDouble(), cc[1][0].toDouble(), cc[1][1].toDouble());
      final quadDC = [
        Float32List.fromList([d00, d01]),
        Float32List.fromList([d10, d11]),
      ];
      final fb = List.generate(8, (_) => Float32List(8));
      final s0 = List.generate(4, (_) => Float32List(4));
      final s1 = List.generate(4, (_) => Float32List(4));
      final s2 = List.generate(4, (_) => Float32List(4));
      final s3 = List.generate(4, (_) => Float32List(4));
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
          s0[0][0] = quadDC[y][x];
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
              s0[iy][ix] = cc[y + iy * 2][x + ix * 2];
            }
          }
          inverseDCT2D(s0, s1, 0, 0, 0, 0, 4, 4, s2, s3, true);
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 4; ix++) {
              fb[4 * y + iy][4 * x + ix] = s1[iy][ix];
            }
          }
        }
      }
      return fb;
    }

    // Mirrors vardct_l0_encoder.dart's computeCoeffBuf TransformMethod.dct4
    // branch exactly (the production forward derivation under test).
    List<Float32List> encodeDct4(List<Float32List> pixels) {
      final cc = List.generate(8, (_) => Float32List(8));
      final quadDC = List.generate(2, (_) => Float32List(2));
      final quadTransposed = List.generate(4, (_) => Float32List(4));
      final quadCoeffs = List.generate(4, (_) => Float32List(4));
      final scratch0 = List.generate(4, (_) => Float32List(4));
      final scratch1 = List.generate(4, (_) => Float32List(4));
      for (var qy = 0; qy < 2; qy++) {
        for (var qx = 0; qx < 2; qx++) {
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 4; ix++) {
              quadTransposed[ix][iy] = pixels[qy * 4 + iy][qx * 4 + ix];
            }
          }
          forwardDCT2D(
              quadTransposed, quadCoeffs, 0, 0, 0, 0, 4, 4, scratch0, scratch1);
          quadDC[qy][qx] = quadCoeffs[0][0];
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 4; ix++) {
              if (iy == 0 && ix == 0) continue;
              cc[qy + iy * 2][qx + ix * 2] = quadCoeffs[iy][ix];
            }
          }
        }
      }
      final (e00, e01, e10, e11) = _dct4Butterfly(
          quadDC[0][0].toDouble(),
          quadDC[0][1].toDouble(),
          quadDC[1][0].toDouble(),
          quadDC[1][1].toDouble());
      cc[0][0] = e00 / 4;
      cc[0][1] = e01 / 4;
      cc[1][0] = e10 / 4;
      cc[1][1] = e11 / 4;
      return cc;
    }

    test(
        'forward derivation followed by the real decoder reconstruction '
        'is the identity, over random 8x8 blocks', () {
      final rng = math.Random(6);
      for (var trial = 0; trial < 50; trial++) {
        final pixels = List.generate(
            8,
            (_) => Float32List.fromList(
                List.generate(8, (_) => rng.nextDouble() * 10 - 5)));
        final cc = encodeDct4(pixels);
        final recon = decodeDct4(cc);
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            expect(recon[y][x], closeTo(pixels[y][x], 1e-3),
                reason: 'trial $trial, pixel ($y, $x)');
          }
        }
      }
    });
  });
}

/// The decoder's `_auxDCT2` (`vardct_inverter.dart`) single-stage (`s=2`,
/// `num=1`) 2x2 Hadamard-type butterfly — see
/// `vardct_l0_encoder.dart`'s `_dct4QuadrantButterfly` doc comment for the
/// verified self-inverse-up-to-4 property this relies on (and the warning
/// about NOT reusing it for DCT2x2's multi-stage cascade, where that
/// property does not hold).
(double, double, double, double) _dct4Butterfly(
        double c00, double c01, double c10, double c11) =>
    (
      c00 + c01 + c10 + c11,
      c00 + c01 - c10 - c11,
      c00 - c01 + c10 - c11,
      c00 - c01 - c10 + c11,
    );
