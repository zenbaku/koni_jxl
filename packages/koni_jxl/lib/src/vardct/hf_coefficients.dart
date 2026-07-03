import 'dart:math' as math;
import 'dart:typed_data';

import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../frame/frame.dart';
import '../frame/lf_group.dart';
import '../io/bit_reader.dart';
import '../util/image_buffer.dart';
import '../util/math_helper.dart';
import 'dct.dart';
import 'hf_block_context.dart';

const _coeffFreqCtx = <int>[
  // Index 0 is unused.
  -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, //
  15, 15, 16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, //
  23, 23, 23, 23, 24, 24, 24, 24, 25, 25, 25, 25, 26, 26, 26, 26, //
  27, 27, 27, 27, 28, 28, 28, 28, 29, 29, 29, 29, 30, 30, 30, 30,
];

const _coeffNumNonzeroCtx = <int>[
  // Index 0 is unused.
  -1, 0, 31, 62, 62, 93, 93, 93, 93, 123, 123, 123, 123, 152, 152, //
  152, 152, 152, 152, 152, 152, 180, 180, 180, 180, 180, 180, 180, //
  180, 180, 180, 180, 180, 206, 206, 206, 206, 206, 206, 206, 206, //
  206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, 206, //
  206, 206, 206, 206, 206, 206, 206, 206, 206, 206,
];

/// AC coefficients of one (pass, group): entropy decode, dequantization,
/// chroma-from-luma and LLF insertion.
final class HfCoefficients {
  HfCoefficients(BitReader reader, this.frame, int pass, this.groupID)
      : lfg = frame.getLFGroupForGroup(groupID) {
    final hfGlobal = frame.hfGlobal!;
    final bits = ceilLog1p(hfGlobal.numHfPresets - 1);
    hfPreset = reader.readBits(bits);
    final hfctx = frame.lfGlobal.hfBlockCtx!;
    final offset = 495 * hfctx.numClusters * hfPreset;
    final header = frame.header;
    final shift = header.passes.shift[pass];
    final hfPass = frame.passes[pass].hfPass!;
    final size = frame.groupSize(groupID);
    final nonZeroes = Int32List(3 * 32 * 32);
    stream = EntropyStream.clone(hfPass.contextStream);
    quantizedCoeffs = [];
    coeffHeight = List.filled(3, 0);
    coeffWidth = List.filled(3, 0);
    for (var c = 0; c < 3; c++) {
      final sY = size.height >> header.jpegUpsamplingY[c];
      final sX = size.width >> header.jpegUpsamplingX[c];
      coeffHeight[c] = sY;
      coeffWidth[c] = sX;
      quantizedCoeffs.add(Float32List(sY * sX));
    }
    dequantHFCoeff0 = floatMatrix(coeffHeight[0], coeffWidth[0]);
    dequantHFCoeff1 = floatMatrix(coeffHeight[1], coeffWidth[1]);
    dequantHFCoeff2 = floatMatrix(coeffHeight[2], coeffWidth[2]);
    simdViews = coeffWidth[0] & 3 == 0 &&
        coeffWidth[1] & 3 == 0 &&
        coeffWidth[2] & 3 == 0;
    if (simdViews) {
      dequantHFCoeffV0 = rowVectorViews(dequantHFCoeff0);
      dequantHFCoeffV1 = rowVectorViews(dequantHFCoeff1);
      dequantHFCoeffV2 = rowVectorViews(dequantHFCoeff2);
      quantizedCoeffsV = [
        for (final qc in quantizedCoeffs)
          Float32x4List.view(qc.buffer, 0, qc.length >> 2),
      ];
    }
    final pos = frame.groupPosInLFGroup(lfg.lfGroupID, groupID);
    groupPosY = pos.y << 5;
    groupPosX = pos.x << 5;

    final meta = lfg.hfMetadata!;
    blockIncluded = List<bool>.filled(meta.nbBlocks, false);
    for (var i = 0; i < meta.nbBlocks; i++) {
      final posY = meta.blockY[i];
      final posX = meta.blockX[i];
      final groupY = posY - groupPosY;
      final groupX = posX - groupPosX;
      if (groupY < 0 || groupX < 0 || groupY >= 32 || groupX >= 32) {
        continue; // not in this group
      }
      blockIncluded[i] = true;
      final tt = meta.dctSelectAt(posY, posX)!;
      final flip = tt.flip;
      final hfMult = meta.hfMultiplierAt(posY, posX);
      final lfIndex = lfg.lfCoeff!.lfIndex[posY * meta.blockWidth + posX];
      final numBlocks = tt.dctSelectHeight * tt.dctSelectWidth;
      for (final c in cMap) {
        final sGroupY = groupY >> header.jpegUpsamplingY[c];
        final sGroupX = groupX >> header.jpegUpsamplingX[c];
        if (groupY != sGroupY << header.jpegUpsamplingY[c] ||
            groupX != sGroupX << header.jpegUpsamplingX[c]) {
          continue; // subsampled block
        }
        final pixelGroupY = sGroupY << 3;
        final pixelGroupX = sGroupX << 3;
        // A block must fit within its 32x32 group grid; a corrupt oversized
        // transform near the edge would otherwise index past nonZeroes.
        if (sGroupY + tt.dctSelectHeight > 32 ||
            sGroupX + tt.dctSelectWidth > 32) {
          throw const JxlInvalidBitstreamException(
              'transform block extends past its group');
        }
        final predicted = getPredictedNonZeroes(nonZeroes, c, sGroupY, sGroupX);
        final blockCtx = getBlockContext(hfctx, c, tt.orderID, hfMult, lfIndex);
        final nonZeroCtx =
            offset + getNonZeroContext(hfctx, predicted, blockCtx);
        var nonZero = stream.readSymbol(reader, nonZeroCtx);
        if (nonZero > tt.pixelHeight * tt.pixelWidth - numBlocks) {
          throw const JxlInvalidBitstreamException(
              'nonzero coefficient count out of range');
        }
        final base = c * 1024;
        final fill = (nonZero + numBlocks - 1) ~/ numBlocks;
        for (var iy = 0; iy < tt.dctSelectHeight; iy++) {
          for (var ix = 0; ix < tt.dctSelectWidth; ix++) {
            nonZeroes[base + (sGroupY + iy) * 32 + sGroupX + ix] = fill;
          }
        }
        // SPEC: the spec doesn't say to abort here if nonZero == 0.
        if (nonZero <= 0) continue;
        final orderSize = hfPass.orderFor(tt.orderID)[c].length;
        final ucoeffLen = orderSize - numBlocks;
        final histCtx = offset + 458 * blockCtx + 37 * hfctx.numClusters;
        var prevCoeff = 0;
        final orderList = hfPass.orderFor(tt.orderID)[c];
        final qc = quantizedCoeffs[c];
        final qw = coeffWidth[c];
        for (var k = 0; k < ucoeffLen; k++) {
          // SPEC: the spec has this condition flipped.
          final prev = k == 0
              ? (nonZero > orderSize ~/ 16 ? 0 : 1)
              : (prevCoeff != 0 ? 1 : 0);
          final ctx = histCtx +
              getCoefficientContext(k + numBlocks, nonZero, numBlocks, prev);
          final u = stream.readSymbol(reader, ctx);
          prevCoeff = u;
          final order = orderList[k + numBlocks];
          final oy = order >> 16;
          final ox = order & 0xFFFF;
          final posY2 = (flip ? ox : oy) + pixelGroupY;
          final posX2 = (flip ? oy : ox) + pixelGroupX;
          qc[posY2 * qw + posX2] = (unpackSigned(u) << shift).toDouble();
          if (u != 0) {
            if (--nonZero == 0) break;
          }
        }
        // SPEC: the spec doesn't mention that nonZero > 0 is illegal.
        if (nonZero != 0) {
          throw JxlInvalidBitstreamException(
              'illegal final nonzero count in group $groupID');
        }
      }
    }
    if (!stream.validateFinalState()) {
      throw JxlInvalidBitstreamException(
          'illegal final ANS state in pass group: $pass, $groupID');
    }
  }

  final Frame frame;
  final int groupID;
  final LfGroup lfg;
  late final int hfPreset;
  late final EntropyStream stream;

  /// Per channel: flat (coeffHeight x coeffWidth) arrays.
  late final List<Float32List> quantizedCoeffs;
  late final List<Float32List> dequantHFCoeff0;
  late final List<Float32List> dequantHFCoeff1;
  late final List<Float32List> dequantHFCoeff2;
  late final List<int> coeffHeight;

  List<Float32List> dequantHFCoeffAt(int c) =>
      c == 0 ? dequantHFCoeff0 : (c == 1 ? dequantHFCoeff1 : dequantHFCoeff2);

  late final bool simdViews;
  late final List<Float32x4List> dequantHFCoeffV0;
  late final List<Float32x4List> dequantHFCoeffV1;
  late final List<Float32x4List> dequantHFCoeffV2;
  late final List<Float32x4List> quantizedCoeffsV;

  List<Float32x4List> dequantHFCoeffVAt(int c) => c == 0
      ? dequantHFCoeffV0
      : (c == 1 ? dequantHFCoeffV1 : dequantHFCoeffV2);
  late final List<int> coeffWidth;
  late final int groupPosY;
  late final int groupPosX;

  /// Whether lfg block i belongs to this group.
  late final List<bool> blockIncluded;

  void bakeDequantizedCoeffs() {
    _dequantizeHFCoefficients();
    _chromaFromLuma();
    _finalizeLLF();
  }

  /// Public so the lossy encoder can compute the exact same block-context
  /// cluster id the decoder does, without hand-duplicating the formula.
  static int getBlockContext(
      HfBlockContext hfctx, int c, int orderID, int hfMult, int lfIndex) {
    var idx = (c < 2 ? 1 - c : c) * 13 + orderID;
    idx *= hfctx.qfThresholds.length + 1;
    for (final t in hfctx.qfThresholds) {
      if (hfMult > t) idx++;
    }
    idx *= hfctx.numLFContexts;
    return hfctx.clusterMap[idx + lfIndex];
  }

  /// Public so the lossy encoder can compute the exact same non-zero-count
  /// context id the decoder does.
  static int getNonZeroContext(HfBlockContext hfctx, int predicted, int ctx) {
    if (predicted > 64) predicted = 64;
    if (predicted < 8) return ctx + hfctx.numClusters * predicted;
    return ctx + hfctx.numClusters * (4 + predicted ~/ 2);
  }

  /// Public so the lossy encoder can compute the exact same per-position
  /// coefficient context id the decoder does (mirrors `_coeffNumNonzeroCtx`
  /// / `_coeffFreqCtx` exactly, without hand-duplicating those tables).
  static int getCoefficientContext(
      int k, int nonZeroes, int numBlocks, int prev) {
    nonZeroes = (nonZeroes + numBlocks - 1) ~/ numBlocks;
    k ~/= numBlocks;
    return (_coeffNumNonzeroCtx[nonZeroes] + _coeffFreqCtx[k]) * 2 + prev;
  }

  /// Public so the lossy encoder can maintain the exact same
  /// predicted-non-zero-count grid the decoder does.
  static int getPredictedNonZeroes(Int32List nonZeroes, int c, int y, int x) {
    final base = c * 1024;
    if (x == 0 && y == 0) return 32;
    if (x == 0) return nonZeroes[base + (y - 1) * 32];
    if (y == 0) return nonZeroes[base + x - 1];
    return (nonZeroes[base + (y - 1) * 32 + x] +
            nonZeroes[base + y * 32 + x - 1] +
            1) >>
        1;
  }

  void _dequantizeHFCoefficients() {
    final matrix = frame.globalMetadata.opsinInverseMatrix;
    final header = frame.header;
    final globalScale = 65536.0 / frame.lfGlobal.globalScale;
    final scaleFactor = <double>[
      globalScale * math.pow(0.8, header.xqmScale - 2.0).toDouble(),
      globalScale,
      globalScale * math.pow(0.8, header.bqmScale - 2.0).toDouble(),
    ];
    final hfGlobal = frame.hfGlobal!;
    final weightsWidth = hfGlobal.weightsWidth;
    final vnum = Float32x4.splat(matrix.quantBiasNumerator);
    final vone = Float32x4.splat(1.0);
    final vzero = Float32x4.zero();
    final vbias = [
      Float32x4.splat(matrix.quantBias[0]),
      Float32x4.splat(matrix.quantBias[1]),
      Float32x4.splat(matrix.quantBias[2]),
    ];
    final qbclut = [
      [-matrix.quantBias[0], 0.0, matrix.quantBias[0]],
      [-matrix.quantBias[1], 0.0, matrix.quantBias[1]],
      [-matrix.quantBias[2], 0.0, matrix.quantBias[2]],
    ];
    final meta = lfg.hfMetadata!;
    for (var i = 0; i < blockIncluded.length; i++) {
      if (!blockIncluded[i]) continue;
      final posY = meta.blockY[i];
      final posX = meta.blockX[i];
      final tt = meta.dctSelectAt(posY, posX)!;
      final groupY = posY - groupPosY;
      final groupX = posX - groupPosX;
      final flip = tt.flip;
      final w2 = hfGlobal.flatWeightsFor(tt.parameterIndex);
      final w3w = weightsWidth[tt.parameterIndex];
      for (var c = 0; c < 3; c++) {
        final sGroupY = groupY >> header.jpegUpsamplingY[c];
        final sGroupX = groupX >> header.jpegUpsamplingX[c];
        if (groupY != sGroupY << header.jpegUpsamplingY[c] ||
            groupX != sGroupX << header.jpegUpsamplingX[c]) {
          continue; // subsampled block
        }
        final sfc = scaleFactor[c] / meta.hfMultiplierAt(posY, posX);
        final pixelGroupY = sGroupY << 3;
        final pixelGroupX = sGroupX << 3;
        final qw = coeffWidth[c];
        if (simdViews && tt.pixelWidth & 3 == 0) {
          // Vector path: LLF positions hold zero coefficients and produce
          // zero here (finalizeLLF overwrites them), so no skip test is
          // needed. quant for |coeff| < 2 is exactly bias * coeff, and
          // flipped transforms read the pre-transposed weights so the
          // access is always row-major with stride pixelWidth.
          final qcV = quantizedCoeffsV[c];
          final dqV = dequantHFCoeffVAt(c);
          final wV = flip
              ? hfGlobal.weightsFlatTV[tt.parameterIndex][c]!
              : hfGlobal.weightsFlatV[tt.parameterIndex][c]!;
          final vsfc = Float32x4.splat(sfc);
          final vbiasC = vbias[c];
          final qw4 = qw >> 2;
          final w3w4 = tt.pixelWidth >> 2;
          final gx4 = pixelGroupX >> 2;
          final vecs = tt.pixelWidth >> 2;
          for (var y = 0; y < tt.pixelHeight; y++) {
            final qRow = (pixelGroupY + y) * qw4 + gx4;
            final dRow = dqV[pixelGroupY + y];
            final wRow = y * w3w4;
            for (var i = 0; i < vecs; i++) {
              final coeff = qcV[qRow + i];
              // Coefficients are exact integers: m is 0 for |c| < 2 and
              // 1 otherwise, all in float math (Int32x4 masks box in AOT).
              final m = (coeff.abs() - vone).clamp(vzero, vone);
              final invM = vone - m;
              final big = coeff - vnum / (coeff * m + invM);
              final quant = vbiasC * coeff * invM + big * m;
              dRow[gx4 + i] = quant * vsfc * wV[wRow + i];
            }
          }
          continue;
        }
        final w3 = w2[c]!;
        final qbc = qbclut[c];
        final qc = quantizedCoeffs[c];
        final dq = dequantHFCoeffAt(c);
        for (var y = 0; y < tt.pixelHeight; y++) {
          for (var x = 0; x < tt.pixelWidth; x++) {
            if (y < tt.dctSelectHeight && x < tt.dctSelectWidth) continue;
            final pY = pixelGroupY + y;
            final pX = pixelGroupX + x;
            final coeff = qc[pY * qw + pX];
            final quant = coeff > -2 && coeff < 2
                ? qbc[coeff.toInt() + 1]
                : coeff - matrix.quantBiasNumerator / coeff;
            final wy = flip ? x : y;
            final wx = x ^ y ^ wy;
            dq[pY][pX] = quant * sfc * w3[wy * w3w + wx];
          }
        }
      }
    }
  }

  void _chromaFromLuma() {
    if (frame.header.isSubsampled) return;
    final lfc = frame.lfGlobal.lfChanCorr;
    final meta = lfg.hfMetadata!;
    final xFromY = meta.hfStreamChannels[0];
    final bFromY = meta.hfStreamChannels[1];
    final corrW = xFromY.width;
    final xFactorHF = xFromY.buffer!;
    final bFactorHF = bFromY.buffer!;
    final xFactors = floatMatrix(xFromY.height, corrW);
    final bFactors = floatMatrix(bFromY.height, corrW);
    final d0 = dequantHFCoeff0;
    final d1 = dequantHFCoeff1;
    final d2 = dequantHFCoeff2;
    for (var i = 0; i < blockIncluded.length; i++) {
      if (!blockIncluded[i]) continue;
      final posY = meta.blockY[i];
      final posX = meta.blockX[i];
      final tt = meta.dctSelectAt(posY, posX)!;
      final pPosY = posY << 3;
      final pPosX = posX << 3;
      for (var iy = 0; iy < tt.pixelHeight; iy++) {
        final y = pPosY + iy;
        final fy = y >> 6;
        final by = fy << 6 == y;
        final xF = xFactors[fy];
        final bF = bFactors[fy];
        for (var ix = 0; ix < tt.pixelWidth; ix++) {
          final x = pPosX + ix;
          final fx = x >> 6;
          double kX;
          double kB;
          if (by && fx << 6 == x) {
            kX = lfc.baseCorrelationX +
                xFactorHF[fy * corrW + fx] / lfc.colorFactor;
            kB = lfc.baseCorrelationB +
                bFactorHF[fy * corrW + fx] / lfc.colorFactor;
            xF[fx] = kX;
            bF[fx] = kB;
          } else {
            kX = xF[fx];
            kB = bF[fx];
          }
          final dequantY = d1[y & 0xFF][x & 0xFF];
          d0[y & 0xFF][x & 0xFF] += kX * dequantY;
          d2[y & 0xFF][x & 0xFF] += kB * dequantY;
        }
      }
    }
  }

  void _finalizeLLF() {
    final scratch0 = floatMatrix(32, 32);
    final scratch1 = floatMatrix(32, 32);
    final header = frame.header;
    final meta = lfg.hfMetadata!;
    for (var i = 0; i < blockIncluded.length; i++) {
      if (!blockIncluded[i]) continue;
      final posY = meta.blockY[i];
      final posX = meta.blockX[i];
      final tt = meta.dctSelectAt(posY, posX)!;
      final groupY = posY - groupPosY;
      final groupX = posX - groupPosX;
      for (var c = 0; c < 3; c++) {
        final sGroupY = groupY >> header.jpegUpsamplingY[c];
        final sGroupX = groupX >> header.jpegUpsamplingX[c];
        if (groupY != sGroupY << header.jpegUpsamplingY[c] ||
            groupX != sGroupX << header.jpegUpsamplingX[c]) {
          continue; // subsampled block
        }
        final pixelGroupY = sGroupY << 3;
        final pixelGroupX = sGroupX << 3;
        final sLfgY = posY >> header.jpegUpsamplingY[c];
        final sLfgX = posX >> header.jpegUpsamplingX[c];
        final dqlf = lfg.lfCoeff!.dequantLFCoeffAt(c);
        final dq = dequantHFCoeffAt(c);
        forwardDCT2D(dqlf, dq, sLfgY, sLfgX, pixelGroupY, pixelGroupX,
            tt.dctSelectHeight, tt.dctSelectWidth, scratch0, scratch1);
        for (var y = 0; y < tt.dctSelectHeight; y++) {
          final dqy = dq[y + pixelGroupY];
          for (var x = 0; x < tt.dctSelectWidth; x++) {
            dqy[x + pixelGroupX] *= tt.llfScale[y * tt.dctSelectWidth + x];
          }
        }
      }
    }
  }
}
