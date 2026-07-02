import 'dart:typed_data';

import 'afv_basis.dart';
import 'dct.dart';
import 'hf_coefficients.dart';
import 'transform_type.dart';

void _layBlock(List<Float32List> block, List<Float32List> buffer, int inY,
    int inX, int outY, int outX, int height, int width) {
  for (var y = 0; y < height; y++) {
    buffer[y + outY].setRange(outX, outX + width, block[y + inY], inX);
  }
}

void _invertAFV(
    List<Float32List> coeffs,
    List<Float32List> buffer,
    TransformType tt,
    int ppgY,
    int ppgX,
    int ppfY,
    int ppfX,
    List<Float32List> s0,
    List<Float32List> s1,
    List<Float32List> s2,
    List<Float32List> s3) {
  s0[0][0] =
      (coeffs[ppgY][ppgX] + coeffs[ppgY + 1][ppgX] + coeffs[ppgY][ppgX + 1]) *
          4.0;
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
      s0[iy][ix] = coeffs[ppgY + iy * 2][ppgX + ix * 2];
    }
  }
  final flipY = tt.type == 16 || tt.type == 17 ? 1 : 0; // AFV2, AFV3
  final flipX = tt.type == 15 || tt.type == 17 ? 1 : 0; // AFV1, AFV3

  for (var iy = 0; iy < 4; iy++) {
    for (var ix = 0; ix < 4; ix++) {
      var sample = 0.0;
      for (var j = 0; j < 16; j++) {
        final jy = j >> 2;
        final jx = j & 3;
        sample += s0[jy][jx] * afvBasis[j * 16 + iy * 4 + ix];
      }
      s1[iy][ix] = sample;
    }
  }
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = 0; ix < 4; ix++) {
      buffer[ppfY + flipY * 4 + iy][ppfX + flipX * 4 + ix] =
          s1[flipY == 1 ? 3 - iy : iy][flipX == 1 ? 3 - ix : ix];
    }
  }
  // SPEC: watch signs here.
  s0[0][0] =
      coeffs[ppgY][ppgX] + coeffs[ppgY + 1][ppgX] - coeffs[ppgY][ppgX + 1];
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
      s0[iy][ix] = coeffs[ppgY + iy * 2][ppgX + ix * 2 + 1];
    }
  }
  inverseDCT2D(s0, s1, 0, 0, 0, 0, 4, 4, s2, s3, false);
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = 0; ix < 4; ix++) {
      // Transposed intentionally.
      buffer[ppfY + flipY * 4 + iy][ppfX + (flipX == 1 ? 0 : 4) + ix] =
          s1[ix][iy];
    }
  }
  s0[0][0] = coeffs[ppgY][ppgX] - coeffs[ppgY + 1][ppgX];
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = iy == 0 ? 1 : 0; ix < 8; ix++) {
      s0[iy][ix] = coeffs[ppgY + 1 + iy * 2][ppgX + ix];
    }
  }
  inverseDCT2D(s0, s1, 0, 0, 0, 0, 4, 8, s2, s3, false);
  for (var iy = 0; iy < 4; iy++) {
    for (var ix = 0; ix < 8; ix++) {
      buffer[ppfY + (flipY == 1 ? 0 : 4) + iy][ppfX + ix] = s1[iy][ix];
    }
  }
}

void _auxDCT2(List<Float32List> coeffs, List<Float32List> result, int pY,
    int pX, int psY, int psX, int s) {
  _layBlock(coeffs, result, pY, pX, psY, psX, 8, 8);
  final num = s ~/ 2;
  for (var iy = 0; iy < num; iy++) {
    for (var ix = 0; ix < num; ix++) {
      final c00 = coeffs[pY + iy][pX + ix];
      final c01 = coeffs[pY + iy][pX + ix + num];
      final c10 = coeffs[pY + iy + num][pX + ix];
      final c11 = coeffs[pY + iy + num][pX + ix + num];
      result[psY + iy * 2][psX + ix * 2] = c00 + c01 + c10 + c11;
      result[psY + iy * 2][psX + ix * 2 + 1] = c00 + c01 - c10 - c11;
      result[psY + iy * 2 + 1][psX + ix * 2] = c00 - c01 + c10 - c11;
      result[psY + iy * 2 + 1][psX + ix * 2 + 1] = c00 - c01 - c10 + c11;
    }
  }
}

/// Accumulates previous-pass coefficients, bakes dequantized coefficients,
/// and inverse-transforms every varblock of this group into the frame's
/// float channel rows.
void invertVarDCTGroup(
    HfCoefficients hf,
    HfCoefficients? prev,
    List<Float32List> fb0,
    List<Float32List> fb1,
    List<Float32List> fb2,
    List<Float32List> s0,
    List<Float32List> s1,
    List<Float32List> s2,
    List<Float32List> s3,
    List<Float32List> s4,
    List<Float32x4List>? fbV0,
    List<Float32x4List>? fbV1,
    List<Float32x4List>? fbV2) {
  final frame = hf.frame;
  final header = frame.header;
  final meta = hf.lfg.hfMetadata!;

  if (prev != null) {
    for (var i = 0; i < hf.blockIncluded.length; i++) {
      if (!hf.blockIncluded[i]) continue;
      final posY = meta.blockY[i];
      final posX = meta.blockX[i];
      final tt = meta.dctSelectAt(posY, posX)!;
      final groupY = posY - hf.groupPosY;
      final groupX = posX - hf.groupPosX;
      for (var c = 0; c < 3; c++) {
        final sGroupY = groupY >> header.jpegUpsamplingY[c];
        final sGroupX = groupX >> header.jpegUpsamplingX[c];
        if (sGroupY << header.jpegUpsamplingY[c] != groupY ||
            sGroupX << header.jpegUpsamplingX[c] != groupX) {
          continue;
        }
        final pixelY = sGroupY << 3;
        final pixelX = sGroupX << 3;
        final qc = hf.quantizedCoeffs[c];
        final pqc = prev.quantizedCoeffs[c];
        final qw = hf.coeffWidth[c];
        for (var iy = 0; iy < tt.pixelHeight; iy++) {
          final base = (pixelY + iy) * qw + pixelX;
          for (var ix = 0; ix < tt.pixelWidth; ix++) {
            qc[base + ix] += pqc[base + ix];
          }
        }
      }
    }
  }

  hf.bakeDequantizedCoeffs();
  final groupLoc = frame.getGroupLocation(hf.groupID);
  final groupLocY = groupLoc.y << 8;
  final groupLocX = groupLoc.x << 8;

  for (var i = 0; i < hf.blockIncluded.length; i++) {
    if (!hf.blockIncluded[i]) continue;
    final posY = meta.blockY[i];
    final posX = meta.blockX[i];
    final tt = meta.dctSelectAt(posY, posX)!;
    final groupY = posY - hf.groupPosY;
    final groupX = posX - hf.groupPosX;
    for (var c = 0; c < 3; c++) {
      final sGroupY = groupY >> header.jpegUpsamplingY[c];
      final sGroupX = groupX >> header.jpegUpsamplingX[c];
      if (sGroupY << header.jpegUpsamplingY[c] != groupY ||
          sGroupX << header.jpegUpsamplingX[c] != groupX) {
        continue;
      }
      final ppgY = sGroupY << 3;
      final ppgX = sGroupX << 3;
      final ppfY = ppgY + (groupLocY >> header.jpegUpsamplingY[c]);
      final ppfX = ppgX + (groupLocX >> header.jpegUpsamplingX[c]);
      final cc = hf.dequantHFCoeffAt(c);
      final fb = c == 0 ? fb0 : (c == 1 ? fb1 : fb2);
      switch (tt.transformMethod) {
        case TransformMethod.dct:
          if (tt.pixelHeight == 8 &&
              tt.pixelWidth == 8 &&
              fbV0 != null &&
              hf.simdViews) {
            inverseDCT8x8Simd(
                hf.dequantHFCoeffVAt(c),
                c == 0 ? fbV0 : (c == 1 ? fbV1! : fbV2!),
                ppgY,
                ppgX >> 2,
                ppfY,
                ppfX >> 2);
          } else {
            inverseDCT2D(cc, fb, ppgY, ppgX, ppfY, ppfX, tt.pixelHeight,
                tt.pixelWidth, s0, s1, false);
          }
        case TransformMethod.dct8x4:
          final coeff0 = cc[ppgY][ppgX];
          final coeff1 = cc[ppgY + 1][ppgX];
          final lfs = [coeff0 + coeff1, coeff0 - coeff1];
          for (var x = 0; x < 2; x++) {
            s0[0][0] = lfs[x];
            for (var iy = 0; iy < 4; iy++) {
              for (var ix = iy == 0 ? 1 : 0; ix < 8; ix++) {
                s0[iy][ix] = cc[ppgY + x + iy * 2][ppgX + ix];
              }
            }
            inverseDCT2D(
                s0, fb, 0, 0, ppfY, ppfX + (x << 2), 4, 8, s1, s2, true);
          }
        case TransformMethod.dct4x8:
          final coeff0 = cc[ppgY][ppgX];
          final coeff1 = cc[ppgY + 1][ppgX];
          final lfs = [coeff0 + coeff1, coeff0 - coeff1];
          for (var y = 0; y < 2; y++) {
            s0[0][0] = lfs[y];
            for (var iy = 0; iy < 4; iy++) {
              for (var ix = iy == 0 ? 1 : 0; ix < 8; ix++) {
                s0[iy][ix] = cc[ppgY + y + iy * 2][ppgX + ix];
              }
            }
            inverseDCT2D(
                s0, fb, 0, 0, ppfY + (y << 2), ppfX, 4, 8, s1, s2, false);
          }
        case TransformMethod.afv:
          _invertAFV(cc, fb, tt, ppgY, ppgX, ppfY, ppfX, s0, s1, s2, s3);
        case TransformMethod.dct2:
          _auxDCT2(cc, s0, ppgY, ppgX, 0, 0, 2);
          _auxDCT2(s0, s1, 0, 0, 0, 0, 4);
          _auxDCT2(s1, fb, 0, 0, ppfY, ppfX, 8);
        case TransformMethod.hornuss:
          _auxDCT2(cc, s1, ppgY, ppgX, 0, 0, 2);
          for (var y = 0; y < 2; y++) {
            for (var x = 0; x < 2; x++) {
              final blockLF = s1[y][x];
              var residual = 0.0;
              for (var iy = 0; iy < 4; iy++) {
                for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
                  residual += cc[ppgY + y + iy * 2][ppgX + x + ix * 2];
                }
              }
              s0[4 * y + 1][4 * x + 1] = blockLF - residual * 0.0625;
              for (var iy = 0; iy < 4; iy++) {
                for (var ix = 0; ix < 4; ix++) {
                  if (ix == 1 && iy == 1) continue;
                  s0[y * 4 + iy][x * 4 + ix] = cc[ppgY + y + iy * 2]
                          [ppgX + x + ix * 2] +
                      s0[4 * y + 1][4 * x + 1];
                }
              }
              s0[4 * y][4 * x] =
                  cc[ppgY + y + 2][ppgX + x + 2] + s0[4 * y + 1][4 * x + 1];
            }
          }
          _layBlock(s0, fb, 0, 0, ppfY, ppfX, tt.pixelHeight, tt.pixelWidth);
        case TransformMethod.dct4:
          _auxDCT2(cc, s4, ppgY, ppgX, 0, 0, 2);
          for (var y = 0; y < 2; y++) {
            for (var x = 0; x < 2; x++) {
              s0[0][0] = s4[y][x];
              for (var iy = 0; iy < 4; iy++) {
                for (var ix = iy == 0 ? 1 : 0; ix < 4; ix++) {
                  s0[iy][ix] = cc[ppgY + y + iy * 2][ppgX + x + ix * 2];
                }
              }
              inverseDCT2D(s0, s1, 0, 0, 0, 0, 4, 4, s2, s3, true);
              for (var iy = 0; iy < 4; iy++) {
                for (var ix = 0; ix < 4; ix++) {
                  fb[ppfY + 4 * y + iy][ppfX + 4 * x + ix] = s1[iy][ix];
                }
              }
            }
          }
        default:
          throw UnsupportedError('transform not implemented: $tt');
      }
    }
  }
}
