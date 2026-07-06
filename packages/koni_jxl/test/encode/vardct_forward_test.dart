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

  // Tranche C, second/third slices (ROADMAP.md/spec_notes.md): Hornuss and
  // DCT2x2 share DCT4x4's verified single-stage butterfly for their own
  // cross-quadrant (Hornuss) or top-level (DCT2x2) DC combination, but each
  // needed its own independent forward derivation verified the same way —
  // by basis injection against the real decoder logic (0.0 deviation, see
  // doc/spec_notes.md), not by extrapolating DCT4x4's shape. These groups
  // are the permanent Dart form of that check (the "duplicate the decoder's
  // private arithmetic in test code" pattern the DCT4x4 group above already
  // uses) — they catch *port* errors (e.g. an index swap) that the Python
  // basis-injection proof, run once during planning, cannot.
  group('Hornuss (Tranche C, bespoke)', () {
    // Mirrors vardct_inverter.dart's TransformMethod.hornuss case exactly,
    // for a single isolated 8x8 block at the origin (ppgY=ppgX=ppfY=ppfX=0).
    List<Float32List> decodeHornuss(List<Float32List> cc) {
      final (b00, b01, b10, b11) = _dct4Butterfly(cc[0][0].toDouble(),
          cc[0][1].toDouble(), cc[1][0].toDouble(), cc[1][1].toDouble());
      final blockLF = [
        Float32List.fromList([b00, b01]),
        Float32List.fromList([b10, b11]),
      ];
      final fb = List.generate(8, (_) => Float32List(8));
      for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
          var residual = 0.0;
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 4; ix++) {
              if (iy == 0 && ix == 0) continue;
              residual += cc[y + iy * 2][x + ix * 2];
            }
          }
          final center = blockLF[y][x] - residual * 0.0625;
          fb[4 * y + 1][4 * x + 1] = center;
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 4; ix++) {
              if (ix == 1 && iy == 1) continue;
              fb[y * 4 + iy][x * 4 + ix] = cc[y + iy * 2][x + ix * 2] + center;
            }
          }
          fb[4 * y][4 * x] = cc[y + 2][x + 2] + center;
        }
      }
      return fb;
    }

    // Mirrors vardct_l0_encoder.dart's computeCoeffBuf TransformMethod
    // .hornuss branch exactly (the production forward derivation under
    // test).
    List<Float32List> encodeHornuss(List<Float32List> pixels) {
      final cc = List.generate(8, (_) => Float32List(8));
      final blockLF = List.generate(2, (_) => Float32List(2));
      for (var qy = 0; qy < 2; qy++) {
        for (var qx = 0; qx < 2; qx++) {
          var sum = 0.0;
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 4; ix++) {
              sum += pixels[qy * 4 + iy][qx * 4 + ix];
            }
          }
          blockLF[qy][qx] = sum * 0.0625;
          final center = pixels[qy * 4 + 1][qx * 4 + 1];
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 4; ix++) {
              if ((iy == 0 && ix == 0) || (iy == 1 && ix == 1)) continue;
              cc[qy + iy * 2][qx + ix * 2] =
                  pixels[qy * 4 + iy][qx * 4 + ix] - center;
            }
          }
          cc[qy + 2][qx + 2] = pixels[qy * 4][qx * 4] - center;
        }
      }
      final (e00, e01, e10, e11) = _dct4Butterfly(
          blockLF[0][0].toDouble(),
          blockLF[0][1].toDouble(),
          blockLF[1][0].toDouble(),
          blockLF[1][1].toDouble());
      cc[0][0] = e00 / 4;
      cc[0][1] = e01 / 4;
      cc[1][0] = e10 / 4;
      cc[1][1] = e11 / 4;
      return cc;
    }

    test(
        'forward derivation followed by the real decoder reconstruction '
        'is the identity, over random 8x8 blocks', () {
      final rng = math.Random(7);
      for (var trial = 0; trial < 50; trial++) {
        final pixels = List.generate(
            8,
            (_) => Float32List.fromList(
                List.generate(8, (_) => rng.nextDouble() * 10 - 5)));
        final cc = encodeHornuss(pixels);
        final recon = decodeHornuss(cc);
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            expect(recon[y][x], closeTo(pixels[y][x], 1e-3),
                reason: 'trial $trial, pixel ($y, $x)');
          }
        }
      }
    });
  });

  group('DCT2x2 (Tranche C, bespoke)', () {
    // Mirrors vardct_inverter.dart's private `_auxDCT2`, restricted to the
    // pY=pX=psY=psX=0 case TransformMethod.dct2's 3-stage cascade always
    // uses.
    void auxDCT2(List<Float32List> coeffs, List<Float32List> result, int s) {
      for (var y = 0; y < 8; y++) {
        result[y].setRange(0, 8, coeffs[y]);
      }
      final num = s ~/ 2;
      for (var iy = 0; iy < num; iy++) {
        for (var ix = 0; ix < num; ix++) {
          final c00 = coeffs[iy][ix];
          final c01 = coeffs[iy][ix + num];
          final c10 = coeffs[iy + num][ix];
          final c11 = coeffs[iy + num][ix + num];
          result[iy * 2][ix * 2] = c00 + c01 + c10 + c11;
          result[iy * 2][ix * 2 + 1] = c00 + c01 - c10 - c11;
          result[iy * 2 + 1][ix * 2] = c00 - c01 + c10 - c11;
          result[iy * 2 + 1][ix * 2 + 1] = c00 - c01 - c10 + c11;
        }
      }
    }

    // Mirrors vardct_inverter.dart's TransformMethod.dct2 case exactly, for
    // a single isolated 8x8 block at the origin.
    List<Float32List> decodeDct2(List<Float32List> cc) {
      final s0 = List.generate(8, (_) => Float32List(8));
      final s1 = List.generate(8, (_) => Float32List(8));
      final fb = List.generate(8, (_) => Float32List(8));
      auxDCT2(cc, s0, 2);
      auxDCT2(s0, s1, 4);
      auxDCT2(s1, fb, 8);
      return fb;
    }

    // Mirrors vardct_l0_encoder.dart's private `_auxDCT2Transposed` exactly
    // (see that function's doc comment for why the transpose has this
    // simple "same H4 formula, read/write roles swapped" closed form —
    // verified against the true matrix transpose by basis injection, not
    // assumed from the algebra alone).
    void auxDCT2Transposed(
        List<Float32List> coeffs, List<Float32List> result, int s) {
      for (var y = 0; y < 8; y++) {
        result[y].setRange(0, 8, coeffs[y]);
      }
      final num = s ~/ 2;
      for (var iy = 0; iy < num; iy++) {
        for (var ix = 0; ix < num; ix++) {
          final dA = coeffs[iy * 2][ix * 2];
          final dB = coeffs[iy * 2][ix * 2 + 1];
          final dC = coeffs[iy * 2 + 1][ix * 2];
          final dD = coeffs[iy * 2 + 1][ix * 2 + 1];
          result[iy][ix] = dA + dB + dC + dD;
          result[iy][ix + num] = dA + dB - dC - dD;
          result[iy + num][ix] = dA - dB + dC - dD;
          result[iy + num][ix + num] = dA - dB - dC + dD;
        }
      }
    }

    // Mirrors vardct_l0_encoder.dart's private `_dct2x2GramScale` exactly.
    double gramScale(int row, int col) {
      var scale = 4.0;
      if (row < 4 && col < 4) scale *= 4.0;
      if (row < 2 && col < 2) scale *= 4.0;
      return scale;
    }

    // Mirrors vardct_l0_encoder.dart's computeCoeffBuf TransformMethod.dct2
    // branch exactly (the production forward derivation under test).
    List<Float32List> encodeDct2(List<Float32List> pixels) {
      final s0 = List.generate(8, (_) => Float32List(8));
      final s1 = List.generate(8, (_) => Float32List(8));
      final cc = List.generate(8, (_) => Float32List(8));
      for (var y = 0; y < 8; y++) {
        cc[y].setRange(0, 8, pixels[y]);
      }
      auxDCT2Transposed(cc, s0, 8);
      auxDCT2Transposed(s0, s1, 4);
      auxDCT2Transposed(s1, cc, 2);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          cc[y][x] /= gramScale(y, x);
        }
      }
      return cc;
    }

    test(
        'forward derivation followed by the real decoder reconstruction '
        'is the identity, over random 8x8 blocks', () {
      final rng = math.Random(8);
      for (var trial = 0; trial < 50; trial++) {
        final pixels = List.generate(
            8,
            (_) => Float32List.fromList(
                List.generate(8, (_) => rng.nextDouble() * 10 - 5)));
        final cc = encodeDct2(pixels);
        final recon = decodeDct2(cc);
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            expect(recon[y][x], closeTo(pixels[y][x], 1e-3),
                reason: 'trial $trial, pixel ($y, $x)');
          }
        }
      }
    });
  });

  // Tranche C, fourth/fifth slices (ROADMAP.md/spec_notes.md): DCT4x8 and
  // DCT8x4 -- unlike Hornuss/DCT2x2 (a single-stage butterfly, no real DCT),
  // these share DCT4x4's "butterfly + sub-block IDCT" shape: a plain
  // 2-point Hadamard (sum/difference, the 1D analog of DCT4x4's 4-point
  // butterfly) combines the block's 2 strips' own DC terms, and each strip
  // is reconstructed via a genuine (height=4,width=8) forwardDCT2D/
  // inverseDCT2D pair -- DCT8x4's strips use `transposed=true`, the same
  // shape DCT4x4's own per-quadrant reconstruction already established and
  // verified. Both derivations verified by basis injection against the real
  // decoder logic to ~2e-15 deviation before writing any Dart (see
  // doc/spec_notes.md); these groups are the permanent form of that check.
  group('DCT4x8 (Tranche C, bespoke)', () {
    // Mirrors vardct_inverter.dart's TransformMethod.dct4x8 case exactly,
    // for a single isolated 8x8 block at the origin.
    List<Float32List> decodeDct4x8(List<Float32List> cc) {
      final coeff0 = cc[0][0].toDouble(), coeff1 = cc[1][0].toDouble();
      final lfs = [coeff0 + coeff1, coeff0 - coeff1];
      final fb = List.generate(8, (_) => Float32List(8));
      final s0 = List.generate(4, (_) => Float32List(8));
      final s1 = List.generate(4, (_) => Float32List(8));
      final scratch0 = List.generate(8, (_) => Float32List(8));
      final scratch1 = List.generate(8, (_) => Float32List(8));
      for (var y = 0; y < 2; y++) {
        s0[0][0] = lfs[y];
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = iy == 0 ? 1 : 0; ix < 8; ix++) {
            s0[iy][ix] = cc[y + iy * 2][ix];
          }
        }
        inverseDCT2D(s0, s1, 0, 0, 0, 0, 4, 8, scratch0, scratch1, false);
        for (var iy = 0; iy < 4; iy++) {
          fb[y * 4 + iy].setRange(0, 8, s1[iy]);
        }
      }
      return fb;
    }

    // Mirrors vardct_l0_encoder.dart's computeCoeffBuf TransformMethod
    // .dct4x8 branch exactly (the production forward derivation under
    // test).
    List<Float32List> encodeDct4x8(List<Float32List> pixels) {
      final cc = List.generate(8, (_) => Float32List(8));
      final strip = List.generate(4, (_) => Float32List(8));
      final stripCoeffs = List.generate(4, (_) => Float32List(8));
      final scratch0 = List.generate(8, (_) => Float32List(8));
      final scratch1 = List.generate(8, (_) => Float32List(8));
      final lf = Float32List(2);
      for (var y = 0; y < 2; y++) {
        for (var iy = 0; iy < 4; iy++) {
          strip[iy].setRange(0, 8, pixels[y * 4 + iy]);
        }
        forwardDCT2D(strip, stripCoeffs, 0, 0, 0, 0, 4, 8, scratch0, scratch1);
        lf[y] = stripCoeffs[0][0];
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = 0; ix < 8; ix++) {
            if (iy == 0 && ix == 0) continue;
            cc[y + iy * 2][ix] = stripCoeffs[iy][ix];
          }
        }
      }
      cc[0][0] = (lf[0] + lf[1]) / 2;
      cc[1][0] = (lf[0] - lf[1]) / 2;
      return cc;
    }

    test(
        'forward derivation followed by the real decoder reconstruction '
        'is the identity, over random 8x8 blocks', () {
      final rng = math.Random(9);
      for (var trial = 0; trial < 50; trial++) {
        final pixels = List.generate(
            8,
            (_) => Float32List.fromList(
                List.generate(8, (_) => rng.nextDouble() * 10 - 5)));
        final cc = encodeDct4x8(pixels);
        final recon = decodeDct4x8(cc);
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            expect(recon[y][x], closeTo(pixels[y][x], 1e-3),
                reason: 'trial $trial, pixel ($y, $x)');
          }
        }
      }
    });
  });

  group('DCT8x4 (Tranche C, bespoke)', () {
    // Mirrors vardct_inverter.dart's TransformMethod.dct8x4 case exactly,
    // for a single isolated 8x8 block at the origin.
    List<Float32List> decodeDct8x4(List<Float32List> cc) {
      final coeff0 = cc[0][0].toDouble(), coeff1 = cc[1][0].toDouble();
      final lfs = [coeff0 + coeff1, coeff0 - coeff1];
      final fb = List.generate(8, (_) => Float32List(8));
      final s0 = List.generate(4, (_) => Float32List(8));
      final scratch0 = List.generate(8, (_) => Float32List(8));
      final scratch1 = List.generate(8, (_) => Float32List(8));
      for (var x = 0; x < 2; x++) {
        s0[0][0] = lfs[x];
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = iy == 0 ? 1 : 0; ix < 8; ix++) {
            s0[iy][ix] = cc[x + iy * 2][ix];
          }
        }
        // transposed=true: inverseDCT2D(...,height=4,width=8,...) writes an
        // 8x4 (width x height) region directly into fb -- see
        // dct.dart's inverseDCT2D and vardct_inverter.dart's own
        // TransformMethod.dct8x4 case, which writes into fb the same way.
        inverseDCT2D(s0, fb, 0, 0, 0, x << 2, 4, 8, scratch0, scratch1, true);
      }
      return fb;
    }

    // Mirrors vardct_l0_encoder.dart's computeCoeffBuf TransformMethod
    // .dct8x4 branch exactly (the production forward derivation under
    // test).
    List<Float32List> encodeDct8x4(List<Float32List> pixels) {
      final cc = List.generate(8, (_) => Float32List(8));
      final stripT = List.generate(4, (_) => Float32List(8));
      final stripCoeffs = List.generate(4, (_) => Float32List(8));
      final scratch0 = List.generate(8, (_) => Float32List(8));
      final scratch1 = List.generate(8, (_) => Float32List(8));
      final lf = Float32List(2);
      for (var x = 0; x < 2; x++) {
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = 0; ix < 8; ix++) {
            stripT[iy][ix] = pixels[ix][x * 4 + iy];
          }
        }
        forwardDCT2D(stripT, stripCoeffs, 0, 0, 0, 0, 4, 8, scratch0, scratch1);
        lf[x] = stripCoeffs[0][0];
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = 0; ix < 8; ix++) {
            if (iy == 0 && ix == 0) continue;
            cc[x + iy * 2][ix] = stripCoeffs[iy][ix];
          }
        }
      }
      cc[0][0] = (lf[0] + lf[1]) / 2;
      cc[1][0] = (lf[0] - lf[1]) / 2;
      return cc;
    }

    test(
        'forward derivation followed by the real decoder reconstruction '
        'is the identity, over random 8x8 blocks', () {
      final rng = math.Random(10);
      for (var trial = 0; trial < 50; trial++) {
        final pixels = List.generate(
            8,
            (_) => Float32List.fromList(
                List.generate(8, (_) => rng.nextDouble() * 10 - 5)));
        final cc = encodeDct8x4(pixels);
        final recon = decodeDct8x4(cc);
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
