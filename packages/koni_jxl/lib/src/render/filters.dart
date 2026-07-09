import 'dart:math' as math;
import 'dart:typed_data';

import '../exceptions.dart';
import '../frame/frame.dart';
import '../frame/frame_flags.dart';
import '../frame/restoration_filter.dart';
import '../util/image_buffer.dart';
import '../util/math_helper.dart';

/// Gaborish: a 3x3 smoothing convolution applied to the color channels.
void performGabConvolution(Frame frame, int colors) {
  final rf = frame.header.restorationFilter;
  final normGabBase = Float32List(colors);
  final normGabAdj = Float32List(colors);
  final normGabDiag = Float32List(colors);
  for (var c = 0; c < colors; c++) {
    final gabW1 = rf.gab1Weights[c];
    final gabW2 = rf.gab2Weights[c];
    final mult = 1.0 / (1.0 + 4.0 * (gabW1 + gabW2));
    normGabBase[c] = mult;
    normGabAdj[c] = gabW1 * mult;
    normGabDiag[c] = gabW2 * mult;
  }
  for (var c = 0; c < colors; c++) {
    frame.buffer[c].castToFloat(frame.globalMetadata.bitDepth.bitsPerSample);
    final height = frame.buffer[c].height;
    final width = frame.buffer[c].width;
    final rows = frame.buffer[c].floatRows;
    final newBuffer = ImageBuffer.float32(height, width);
    final newRows = newBuffer.floatRows;
    final rowsV = rowVectorViews(rows);
    final newRowsV = rowVectorViews(newRows);
    final w4 = width >> 2;
    final useVec = w4 >= 3;
    final vBase = Float32x4.splat(normGabBase[c]);
    final vAdj = Float32x4.splat(normGabAdj[c]);
    final vDiag = Float32x4.splat(normGabDiag[c]);
    for (var y = 0; y < height; y++) {
      final north = y == 0 ? 0 : y - 1;
      final south = y + 1 == height ? height - 1 : y + 1;
      final buffR = rows[y];
      final buffN = rows[north];
      final buffS = rows[south];
      final out = newRows[y];
      if (useVec) {
        final vC = rowsV[y];
        final vN = rowsV[north];
        final vS = rowsV[south];
        final vOut = newRowsV[y];
        for (var j = 1; j < w4 - 1; j++) {
          final c0 = vC[j];
          final p0 = vC[j - 1];
          final n0 = vC[j + 1];
          final cN = vN[j];
          final pN = vN[j - 1];
          final nN = vN[j + 1];
          final cS = vS[j];
          final pS = vS[j - 1];
          final nS = vS[j + 1];
          final wC = c0.shuffle(Float32x4.xxyz).withX(p0.w);
          final eC = c0.shuffle(Float32x4.yzww).withW(n0.x);
          final wN = cN.shuffle(Float32x4.xxyz).withX(pN.w);
          final eN = cN.shuffle(Float32x4.yzww).withW(nN.x);
          final wS = cS.shuffle(Float32x4.xxyz).withX(pS.w);
          final eS = cS.shuffle(Float32x4.yzww).withW(nS.x);
          vOut[j] = vBase * c0 +
              vAdj * (wC + eC + cN + cS) +
              vDiag * (wN + eN + wS + eS);
        }
      }
      for (var x = 0; x < width; x++) {
        if (useVec && x == 4) x = (w4 - 1) << 2;
        final west = x == 0 ? 0 : x - 1;
        final east = x + 1 == width ? width - 1 : x + 1;
        final adj = buffR[west] + buffR[east] + buffN[x] + buffS[x];
        final diag = buffN[west] + buffN[east] + buffS[west] + buffS[east];
        out[x] = normGabBase[c] * buffR[x] +
            normGabAdj[c] * adj +
            normGabDiag[c] * diag;
      }
    }
    frame.buffer[c] = newBuffer;
  }
}

// (dy, dx) offsets, as parallel flat arrays (records are too slow in the
// per-pixel loops).
const _epfCrossDy = [0, -1, 1, 0, 0];
const _epfCrossDx = [0, 0, 0, -1, 1];

const _epfDoubleCrossDy = [0, -1, 1, 0, 0, 1, 1, -1, -1, -2, 2, 0, 0];
const _epfDoubleCrossDx = [0, 0, 0, -1, 1, -1, 1, 1, -1, 0, 0, 2, -2];

/// Edge-preserving filter: up to three weighted-average passes over the
/// color channels, guided by per-block sigma.
///
/// All three passes run Float32x4 SIMD kernels over the interior (four
/// pixels at a time) with the fully general mirroring path as the border
/// fallback: pass 0 (only when epfIterations == 3) is the 12-neighbor
/// double-cross (`_epfPass0GrayVec`/`_epfPass0ColorVec`), passes 1 and 2 the
/// 4-neighbor cross. Term ordering matches the general path exactly; the
/// SIMD interior accumulates in float32 lanes rather than the general path's
/// float64, a difference well within the lossy tolerance the EPF output is
/// gated at (conformance/corpus decode vs. djxl/ref.png), not bit-identical.
void performEdgePreservingFilter(Frame frame, int colors) {
  final rf = frame.header.restorationFilter;
  final stepMultiplier = 1.65 * 4 * (1 - math.sqrt(0.5));
  final padded = frame.paddedFrameSize;
  final blockHeight = (padded.height + 7) >> 3;
  final blockWidth = (padded.width + 7) >> 3;
  List<Float32List>? inverseSigma;
  var invModularSigma = 0.0;
  if (frame.header.encoding == FrameFlags.vardct) {
    inverseSigma = floatMatrix(blockHeight, blockWidth);
    final globalScale = 65536.0 / frame.lfGlobal.globalScale;
    for (var y = 0; y < blockHeight; y++) {
      final lfY = y >> 8;
      final bY = y - (lfY << 8);
      final lfR = lfY * frame.lfGroupRowStride;
      for (var x = 0; x < blockWidth; x++) {
        final lfX = x >> 8;
        final bX = x - (lfX << 8);
        final lfg = frame.lfGroups[lfR + lfX]!;
        final meta = lfg.hfMetadata!;
        final hf = meta.hfMultiplierAt(bY, bX);
        final sharpness = meta.sharpnessAt(bY, bX);
        if (sharpness < 0 || sharpness > 7) {
          throw const JxlInvalidBitstreamException('invalid EPF sharpness');
        }
        final sigma = globalScale * rf.epfSharpLut[sharpness] / hf;
        inverseSigma[y][x] = 1.0 / sigma;
      }
    }
  } else {
    invModularSigma = 1.0 / rf.epfSigmaForModular;
  }

  for (var c = 0; c < colors; c++) {
    frame.buffer[c].castToFloat(frame.globalMetadata.bitDepth.bitsPerSample);
  }
  final outputBuffer = [
    for (var c = 0; c < colors; c++)
      ImageBuffer.float32(padded.height, padded.width),
  ];

  for (var i = 0; i < 3; i++) {
    if (i == 0 && rf.epfIterations < 3) continue;
    if (i == 2 && rf.epfIterations < 2) break;
    final inputRows = [
      for (var c = 0; c < colors; c++) frame.buffer[c].floatRows,
    ];
    final outputRows = [
      for (var c = 0; c < colors; c++) outputBuffer[c].floatRows,
    ];
    final double sigmaScale;
    if (i == 0) {
      sigmaScale = stepMultiplier * rf.epfPass0SigmaScale;
    } else if (i == 2) {
      sigmaScale = stepMultiplier * rf.epfPass2SigmaScale;
    } else {
      sigmaScale = stepMultiplier;
    }
    if (i == 0 && colors == 1) {
      _epfPass0Gray(
          frame.buffer[0].floatRows,
          outputBuffer[0].floatRows,
          inputRows,
          outputRows,
          rf,
          inverseSigma,
          invModularSigma,
          sigmaScale,
          padded.height,
          padded.width);
    } else if (i == 0) {
      _epfPass0Color(
          frame.buffer[0].floatRows,
          frame.buffer[1].floatRows,
          frame.buffer[2].floatRows,
          outputBuffer[0].floatRows,
          outputBuffer[1].floatRows,
          outputBuffer[2].floatRows,
          inputRows,
          outputRows,
          colors,
          rf,
          inverseSigma,
          invModularSigma,
          sigmaScale,
          padded.height,
          padded.width);
    } else if (colors == 1) {
      _epfPassGray(
          frame.buffer[0].floatRows,
          outputBuffer[0].floatRows,
          inputRows,
          outputRows,
          rf,
          inverseSigma,
          invModularSigma,
          sigmaScale,
          i,
          padded.height,
          padded.width);
    } else {
      _epfPassColor(
          frame.buffer[0].floatRows,
          frame.buffer[1].floatRows,
          frame.buffer[2].floatRows,
          outputBuffer[0].floatRows,
          outputBuffer[1].floatRows,
          outputBuffer[2].floatRows,
          inputRows,
          outputRows,
          colors,
          rf,
          inverseSigma,
          invModularSigma,
          sigmaScale,
          i,
          padded.height,
          padded.width);
    }
    for (var c = 0; c < colors; c++) {
      final tmp = frame.buffer[c];
      frame.buffer[c] = outputBuffer[c];
      outputBuffer[c] = tmp;
    }
  }
}

/// One pixel via the fully general (mirroring) path.
void _epfPixelGeneral(
    List<List<Float32List>> inputRows,
    List<List<Float32List>> outputRows,
    int colors,
    Float32List channelScale,
    double borderSadMul,
    List<int> crossDy,
    List<int> crossDx,
    double sigmaScale,
    double s,
    int i,
    int y,
    int x,
    int height,
    int width,
    Float32List sumChannels) {
  var sumWeights = 0.0;
  sumChannels.fillRange(0, colors, 0);
  for (var k = 0; k < crossDy.length; k++) {
    final cy = crossDy[k];
    final cx = crossDx[k];
    final dist = i == 2
        ? _epfDistance2(
            inputRows, colors, channelScale, y, x, cy, cx, height, width)
        : _epfDistance1(
            inputRows, colors, channelScale, y, x, cy, cx, height, width);
    final weight = _epfWeight(borderSadMul, sigmaScale, dist, s, y, x);
    sumWeights += weight;
    final mY = mirrorCoordinate(y + cy, height);
    final mX = mirrorCoordinate(x + cx, width);
    for (var c = 0; c < colors; c++) {
      sumChannels[c] += inputRows[c][mY][mX] * weight;
    }
  }
  for (var c = 0; c < colors; c++) {
    outputRows[c][y][x] = sumChannels[c] / sumWeights;
  }
}

/// Pass 0 (epfIterations == 3): the 12-cross double-cross pass with fully
/// unrolled interior kernels (direct row locals passed from a call site
/// with statically known concrete lists; nested-container access in or
/// feeding the pixel loop is a 10x+ AOT penalty) and the general
/// mirroring path for the 3-pixel border.
void _epfPass0Gray(
    List<Float32List> input,
    List<Float32List> output,
    List<List<Float32List>> inputRows,
    List<List<Float32List>> outputRows,
    RestorationFilter rf,
    List<Float32List>? inverseSigma,
    double invModularSigma,
    double sigmaScale,
    int height,
    int width) {
  final scaleSum =
      rf.epfChannelScale[0] + rf.epfChannelScale[1] + rf.epfChannelScale[2];
  final borderSadMul = rf.epfBorderSadMul;
  final sumChannels = Float32List(1);
  final xEnd = width - 3 < 3 ? 3 : width - 3;
  final inV = rowVectorViews(input);
  final outV = rowVectorViews(output);
  final vScaleSum = Float32x4.splat(scaleSum);
  final vOne = Float32x4.splat(1.0);
  final vZero = Float32x4.zero();
  final patLo = Float32x4(borderSadMul, 1, 1, 1);
  final patHi = Float32x4(1, 1, 1, borderSadMul);
  final patAll = Float32x4.splat(borderSadMul);
  // Pass 0 reaches +/-3 pixels horizontally (the double-cross's +/-2 neighbor
  // taps each read a +/-1 cross), so leave a wider unvectorized margin than
  // the +/-2 passes; still within +/-1 vector (3 < 4), so only prev/next
  // vectors are needed.
  final vecEnd = width >= 28 ? (width - 16) & ~7 : 8;
  final hasVec = vecEnd > 8;
  Float32List? constSigmaRow;
  if (inverseSigma == null) {
    constSigmaRow = Float32List((width + 7) >> 3);
    constSigmaRow.fillRange(0, constSigmaRow.length, invModularSigma);
  }
  for (var y = 0; y < height; y++) {
    final sigmaRow =
        inverseSigma != null ? inverseSigma[y >> 3] : constSigmaRow!;
    if (y < 3 || y + 3 >= height) {
      for (var x = 0; x < width; x++) {
        final s = sigmaRow[x >> 3];
        if (s.isNaN || s > 1 / 0.3) {
          output[y][x] = input[y][x];
          continue;
        }
        _epfPixelGeneral(
            inputRows,
            outputRows,
            1,
            rf.epfChannelScale,
            borderSadMul,
            _epfDoubleCrossDy,
            _epfDoubleCrossDx,
            sigmaScale,
            s,
            0,
            y,
            x,
            height,
            width,
            sumChannels);
      }
      continue;
    }
    final rM3 = input[y - 3];
    final rM2 = input[y - 2];
    final rM1 = input[y - 1];
    final r0 = input[y + 0];
    final rP1 = input[y + 1];
    final rP2 = input[y + 2];
    final rP3 = input[y + 3];
    final out = output[y];
    final modY = y & 7;
    final borderY = modY == 0 || modY == 7;
    if (hasVec) {
      _epfPass0GrayVec(
          inV[y - 3],
          inV[y - 2],
          inV[y - 1],
          inV[y],
          inV[y + 1],
          inV[y + 2],
          inV[y + 3],
          outV[y],
          sigmaRow,
          sigmaScale,
          borderY,
          vScaleSum,
          vOne,
          vZero,
          patLo,
          patHi,
          patAll,
          vecEnd);
    }
    for (var x = 0; x < width; x++) {
      if (hasVec && x == 8) x = vecEnd;
      final s = sigmaRow[x >> 3];
      if (s.isNaN || s > 1 / 0.3) {
        out[x] = r0[x];
        continue;
      }
      if (x < 3 || x >= xEnd) {
        _epfPixelGeneral(
            inputRows,
            outputRows,
            1,
            rf.epfChannelScale,
            borderSadMul,
            _epfDoubleCrossDy,
            _epfDoubleCrossDx,
            sigmaScale,
            s,
            0,
            y,
            x,
            height,
            width,
            sumChannels);
        continue;
      }
      final modX = x & 7;
      final mul = borderY || modX == 0 || modX == 7
          ? sigmaScale * s * borderSadMul
          : sigmaScale * s;
      var sumW = 0.0;
      var sum = 0.0;
      var w = 1 -
          ((r0[x] - r0[x]).abs() +
                  (rM1[x] - rM1[x]).abs() +
                  (rP1[x] - rP1[x]).abs() +
                  (r0[x - 1] - r0[x - 1]).abs() +
                  (r0[x + 1] - r0[x + 1]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += r0[x] * w;
      w = 1 -
          ((r0[x] - rM1[x]).abs() +
                  (rM1[x] - rM2[x]).abs() +
                  (rP1[x] - r0[x]).abs() +
                  (r0[x - 1] - rM1[x - 1]).abs() +
                  (r0[x + 1] - rM1[x + 1]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += rM1[x] * w;
      w = 1 -
          ((r0[x] - rP1[x]).abs() +
                  (rM1[x] - r0[x]).abs() +
                  (rP1[x] - rP2[x]).abs() +
                  (r0[x - 1] - rP1[x - 1]).abs() +
                  (r0[x + 1] - rP1[x + 1]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += rP1[x] * w;
      w = 1 -
          ((r0[x] - r0[x - 1]).abs() +
                  (rM1[x] - rM1[x - 1]).abs() +
                  (rP1[x] - rP1[x - 1]).abs() +
                  (r0[x - 1] - r0[x - 2]).abs() +
                  (r0[x + 1] - r0[x]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += r0[x - 1] * w;
      w = 1 -
          ((r0[x] - r0[x + 1]).abs() +
                  (rM1[x] - rM1[x + 1]).abs() +
                  (rP1[x] - rP1[x + 1]).abs() +
                  (r0[x - 1] - r0[x]).abs() +
                  (r0[x + 1] - r0[x + 2]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += r0[x + 1] * w;
      w = 1 -
          ((r0[x] - rP1[x - 1]).abs() +
                  (rM1[x] - r0[x - 1]).abs() +
                  (rP1[x] - rP2[x - 1]).abs() +
                  (r0[x - 1] - rP1[x - 2]).abs() +
                  (r0[x + 1] - rP1[x]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += rP1[x - 1] * w;
      w = 1 -
          ((r0[x] - rP1[x + 1]).abs() +
                  (rM1[x] - r0[x + 1]).abs() +
                  (rP1[x] - rP2[x + 1]).abs() +
                  (r0[x - 1] - rP1[x]).abs() +
                  (r0[x + 1] - rP1[x + 2]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += rP1[x + 1] * w;
      w = 1 -
          ((r0[x] - rM1[x + 1]).abs() +
                  (rM1[x] - rM2[x + 1]).abs() +
                  (rP1[x] - r0[x + 1]).abs() +
                  (r0[x - 1] - rM1[x]).abs() +
                  (r0[x + 1] - rM1[x + 2]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += rM1[x + 1] * w;
      w = 1 -
          ((r0[x] - rM1[x - 1]).abs() +
                  (rM1[x] - rM2[x - 1]).abs() +
                  (rP1[x] - r0[x - 1]).abs() +
                  (r0[x - 1] - rM1[x - 2]).abs() +
                  (r0[x + 1] - rM1[x]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += rM1[x - 1] * w;
      w = 1 -
          ((r0[x] - rM2[x]).abs() +
                  (rM1[x] - rM3[x]).abs() +
                  (rP1[x] - rM1[x]).abs() +
                  (r0[x - 1] - rM2[x - 1]).abs() +
                  (r0[x + 1] - rM2[x + 1]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += rM2[x] * w;
      w = 1 -
          ((r0[x] - rP2[x]).abs() +
                  (rM1[x] - rP1[x]).abs() +
                  (rP1[x] - rP3[x]).abs() +
                  (r0[x - 1] - rP2[x - 1]).abs() +
                  (r0[x + 1] - rP2[x + 1]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += rP2[x] * w;
      w = 1 -
          ((r0[x] - r0[x + 2]).abs() +
                  (rM1[x] - rM1[x + 2]).abs() +
                  (rP1[x] - rP1[x + 2]).abs() +
                  (r0[x - 1] - r0[x + 1]).abs() +
                  (r0[x + 1] - r0[x + 3]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += r0[x + 2] * w;
      w = 1 -
          ((r0[x] - r0[x - 2]).abs() +
                  (rM1[x] - rM1[x - 2]).abs() +
                  (rP1[x] - rP1[x - 2]).abs() +
                  (r0[x - 1] - r0[x - 3]).abs() +
                  (r0[x + 1] - r0[x - 1]).abs()) *
              scaleSum *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sum += r0[x - 2] * w;
      out[x] = sum / sumW;
    }
  }
}

/// SIMD interior kernel for pass 0 (gray): the 12-neighbor double-cross with
/// a 5-tap distance per neighbor, four pixels at a time. Row vectors are
/// passed as concrete `Float32x4List` params (per the CLAUDE.md perf rule —
/// deriving them from a nested container inside the loop is a 10x+ penalty).
/// The 12 neighbor taps and their term ordering mirror `_epfPass0Gray`'s
/// scalar body exactly; only the accumulation type differs (float32 lanes
/// vs. the scalar's float64), a difference already established as within the
/// lossy tolerance by the pass 1/2 SIMD kernels. Reaches +/-3 pixels
/// horizontally (the EE/WW taps' own cross), so it builds shift-by-3 vectors
/// (`aW3`/`aE3`) the +/-2 passes never needed.
void _epfPass0GrayVec(
    Float32x4List vM3,
    Float32x4List vM2,
    Float32x4List vM1,
    Float32x4List v0,
    Float32x4List vP1,
    Float32x4List vP2,
    Float32x4List vP3,
    Float32x4List vOut,
    Float32List sigmaRow,
    double sigmaScale,
    bool borderY,
    Float32x4 vScaleSum,
    Float32x4 vOne,
    Float32x4 vZero,
    Float32x4 patLo,
    Float32x4 patHi,
    Float32x4 patAll,
    int vecEnd) {
  for (var gx = 8; gx < vecEnd; gx += 8) {
    final s = sigmaRow[gx >> 3];
    final vi = gx >> 2;
    if (s.isNaN || s > 1 / 0.3) {
      vOut[vi] = v0[vi];
      vOut[vi + 1] = v0[vi + 1];
      continue;
    }
    final base = sigmaScale * s;
    for (var h = 0; h < 2; h++) {
      final j = vi + h;
      final mul = borderY
          ? patAll.scale(base)
          : (h == 0 ? patLo.scale(base) : patHi.scale(base));
      final c0 = v0[j];
      final p0 = v0[j - 1];
      final n0 = v0[j + 1];
      final cM1 = vM1[j];
      final pM1 = vM1[j - 1];
      final nM1 = vM1[j + 1];
      final cP1 = vP1[j];
      final pP1 = vP1[j - 1];
      final nP1 = vP1[j + 1];
      final cM2 = vM2[j];
      final pM2 = vM2[j - 1];
      final nM2 = vM2[j + 1];
      final cP2 = vP2[j];
      final pP2 = vP2[j - 1];
      final nP2 = vP2[j + 1];
      final gC = vM3[j];
      final hC = vP3[j];
      // Row y (r0): shifts -3..+3.
      final a = c0;
      final aW = c0.shuffle(Float32x4.xxyz).withX(p0.w);
      final aE = c0.shuffle(Float32x4.yzww).withW(n0.x);
      final aW2 = p0.shuffleMix(c0, Float32x4.zwxy);
      final aE2 = c0.shuffleMix(n0, Float32x4.zwxy);
      final aW3 = p0.shuffle(Float32x4.yzww).withW(c0.x);
      final aE3 = n0.shuffle(Float32x4.xxyz).withX(c0.w);
      // Row y-1 (rM1): shifts -2..+2.
      final bC = cM1;
      final bW = cM1.shuffle(Float32x4.xxyz).withX(pM1.w);
      final bE = cM1.shuffle(Float32x4.yzww).withW(nM1.x);
      final bW2 = pM1.shuffleMix(cM1, Float32x4.zwxy);
      final bE2 = cM1.shuffleMix(nM1, Float32x4.zwxy);
      // Row y+1 (rP1): shifts -2..+2.
      final dC = cP1;
      final dW = cP1.shuffle(Float32x4.xxyz).withX(pP1.w);
      final dE = cP1.shuffle(Float32x4.yzww).withW(nP1.x);
      final dW2 = pP1.shuffleMix(cP1, Float32x4.zwxy);
      final dE2 = cP1.shuffleMix(nP1, Float32x4.zwxy);
      // Row y-2 (rM2): shifts -1..+1.
      final eC = cM2;
      final eW = cM2.shuffle(Float32x4.xxyz).withX(pM2.w);
      final eE = cM2.shuffle(Float32x4.yzww).withW(nM2.x);
      // Row y+2 (rP2): shifts -1..+1.
      final fC = cP2;
      final fW = cP2.shuffle(Float32x4.xxyz).withX(pP2.w);
      final fE = cP2.shuffle(Float32x4.yzww).withW(nP2.x);

      var sumW = vOne;
      var sum = a;
      // N (dy=-1, dx=0)
      var dist = ((a - bC).abs() +
              (bC - eC).abs() +
              (dC - a).abs() +
              (aW - bW).abs() +
              (aE - bE).abs()) *
          vScaleSum;
      var w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += bC * w;
      // S (dy=1, dx=0)
      dist = ((a - dC).abs() +
              (bC - a).abs() +
              (dC - fC).abs() +
              (aW - dW).abs() +
              (aE - dE).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += dC * w;
      // W (dy=0, dx=-1)
      dist = ((a - aW).abs() +
              (bC - bW).abs() +
              (dC - dW).abs() +
              (aW - aW2).abs() +
              (aE - a).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += aW * w;
      // E (dy=0, dx=1)
      dist = ((a - aE).abs() +
              (bC - bE).abs() +
              (dC - dE).abs() +
              (aW - a).abs() +
              (aE - aE2).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += aE * w;
      // SW (dy=1, dx=-1)
      dist = ((a - dW).abs() +
              (bC - aW).abs() +
              (dC - fW).abs() +
              (aW - dW2).abs() +
              (aE - dC).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += dW * w;
      // SE (dy=1, dx=1)
      dist = ((a - dE).abs() +
              (bC - aE).abs() +
              (dC - fE).abs() +
              (aW - dC).abs() +
              (aE - dE2).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += dE * w;
      // NE (dy=-1, dx=1)
      dist = ((a - bE).abs() +
              (bC - eE).abs() +
              (dC - aE).abs() +
              (aW - bC).abs() +
              (aE - bE2).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += bE * w;
      // NW (dy=-1, dx=-1)
      dist = ((a - bW).abs() +
              (bC - eW).abs() +
              (dC - aW).abs() +
              (aW - bW2).abs() +
              (aE - bC).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += bW * w;
      // NN (dy=-2, dx=0)
      dist = ((a - eC).abs() +
              (bC - gC).abs() +
              (dC - bC).abs() +
              (aW - eW).abs() +
              (aE - eE).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += eC * w;
      // SS (dy=2, dx=0)
      dist = ((a - fC).abs() +
              (bC - dC).abs() +
              (dC - hC).abs() +
              (aW - fW).abs() +
              (aE - fE).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += fC * w;
      // EE (dy=0, dx=2)
      dist = ((a - aE2).abs() +
              (bC - bE2).abs() +
              (dC - dE2).abs() +
              (aW - aE).abs() +
              (aE - aE3).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += aE2 * w;
      // WW (dy=0, dx=-2)
      dist = ((a - aW2).abs() +
              (bC - bW2).abs() +
              (dC - dW2).abs() +
              (aW - aW3).abs() +
              (aE - aW).abs()) *
          vScaleSum;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sum += aW2 * w;
      vOut[j] = sum / sumW;
    }
  }
}

void _epfPass0Color(
    List<Float32List> in0,
    List<Float32List> in1,
    List<Float32List> in2,
    List<Float32List> out0,
    List<Float32List> out1,
    List<Float32List> out2,
    List<List<Float32List>> inputRows,
    List<List<Float32List>> outputRows,
    int colors,
    RestorationFilter rf,
    List<Float32List>? inverseSigma,
    double invModularSigma,
    double sigmaScale,
    int height,
    int width) {
  final cs0 = rf.epfChannelScale[0];
  final cs1 = rf.epfChannelScale[1];
  final cs2 = rf.epfChannelScale[2];
  final borderSadMul = rf.epfBorderSadMul;
  final sumChannels = Float32List(colors);
  final xEnd = width - 3 < 3 ? 3 : width - 3;
  final inV0 = rowVectorViews(in0);
  final inV1 = rowVectorViews(in1);
  final inV2 = rowVectorViews(in2);
  final outV0 = rowVectorViews(out0);
  final outV1 = rowVectorViews(out1);
  final outV2 = rowVectorViews(out2);
  final vs0 = Float32x4.splat(cs0);
  final vs1 = Float32x4.splat(cs1);
  final vs2 = Float32x4.splat(cs2);
  final vOne = Float32x4.splat(1.0);
  final vZero = Float32x4.zero();
  final patLo = Float32x4(borderSadMul, 1, 1, 1);
  final patHi = Float32x4(1, 1, 1, borderSadMul);
  final patAll = Float32x4.splat(borderSadMul);
  final vecEnd = width >= 28 ? (width - 16) & ~7 : 8;
  final hasVec = vecEnd > 8;
  Float32List? constSigmaRow;
  if (inverseSigma == null) {
    constSigmaRow = Float32List((width + 7) >> 3);
    constSigmaRow.fillRange(0, constSigmaRow.length, invModularSigma);
  }
  for (var y = 0; y < height; y++) {
    final sigmaRow =
        inverseSigma != null ? inverseSigma[y >> 3] : constSigmaRow!;
    if (y < 3 || y + 3 >= height) {
      for (var x = 0; x < width; x++) {
        final s = sigmaRow[x >> 3];
        if (s.isNaN || s > 1 / 0.3) {
          for (var c = 0; c < colors; c++) {
            outputRows[c][y][x] = inputRows[c][y][x];
          }
          continue;
        }
        _epfPixelGeneral(
            inputRows,
            outputRows,
            colors,
            rf.epfChannelScale,
            borderSadMul,
            _epfDoubleCrossDy,
            _epfDoubleCrossDx,
            sigmaScale,
            s,
            0,
            y,
            x,
            height,
            width,
            sumChannels);
      }
      continue;
    }
    final aM3 = in0[y - 3];
    final aM2 = in0[y - 2];
    final aM1 = in0[y - 1];
    final a0 = in0[y + 0];
    final aP1 = in0[y + 1];
    final aP2 = in0[y + 2];
    final aP3 = in0[y + 3];
    final bM3 = in1[y - 3];
    final bM2 = in1[y - 2];
    final bM1 = in1[y - 1];
    final b0 = in1[y + 0];
    final bP1 = in1[y + 1];
    final bP2 = in1[y + 2];
    final bP3 = in1[y + 3];
    final qM3 = in2[y - 3];
    final qM2 = in2[y - 2];
    final qM1 = in2[y - 1];
    final q0 = in2[y + 0];
    final qP1 = in2[y + 1];
    final qP2 = in2[y + 2];
    final qP3 = in2[y + 3];
    final oa = out0[y];
    final ob = out1[y];
    final oc = out2[y];
    final modY = y & 7;
    final borderY = modY == 0 || modY == 7;
    if (hasVec) {
      _epfPass0ColorVec(
          inV0[y - 3],
          inV0[y - 2],
          inV0[y - 1],
          inV0[y],
          inV0[y + 1],
          inV0[y + 2],
          inV0[y + 3], //
          inV1[y - 3],
          inV1[y - 2],
          inV1[y - 1],
          inV1[y],
          inV1[y + 1],
          inV1[y + 2],
          inV1[y + 3], //
          inV2[y - 3],
          inV2[y - 2],
          inV2[y - 1],
          inV2[y],
          inV2[y + 1],
          inV2[y + 2],
          inV2[y + 3], //
          outV0[y],
          outV1[y],
          outV2[y],
          sigmaRow,
          sigmaScale,
          borderY,
          vs0,
          vs1,
          vs2,
          vOne,
          vZero,
          patLo,
          patHi,
          patAll,
          vecEnd);
    }
    for (var x = 0; x < width; x++) {
      if (hasVec && x == 8) x = vecEnd;
      final s = sigmaRow[x >> 3];
      if (s.isNaN || s > 1 / 0.3) {
        oa[x] = a0[x];
        ob[x] = b0[x];
        oc[x] = q0[x];
        continue;
      }
      if (x < 3 || x >= xEnd) {
        _epfPixelGeneral(
            inputRows,
            outputRows,
            colors,
            rf.epfChannelScale,
            borderSadMul,
            _epfDoubleCrossDy,
            _epfDoubleCrossDx,
            sigmaScale,
            s,
            0,
            y,
            x,
            height,
            width,
            sumChannels);
        continue;
      }
      final modX = x & 7;
      final mul = borderY || modX == 0 || modX == 7
          ? sigmaScale * s * borderSadMul
          : sigmaScale * s;
      var sumW = 0.0;
      var sumA = 0.0;
      var sumB = 0.0;
      var sumQ = 0.0;
      var w = 1 -
          (((a0[x] - a0[x]).abs() +
                          (aM1[x] - aM1[x]).abs() +
                          (aP1[x] - aP1[x]).abs() +
                          (a0[x - 1] - a0[x - 1]).abs() +
                          (a0[x + 1] - a0[x + 1]).abs()) *
                      cs0 +
                  ((b0[x] - b0[x]).abs() +
                          (bM1[x] - bM1[x]).abs() +
                          (bP1[x] - bP1[x]).abs() +
                          (b0[x - 1] - b0[x - 1]).abs() +
                          (b0[x + 1] - b0[x + 1]).abs()) *
                      cs1 +
                  ((q0[x] - q0[x]).abs() +
                          (qM1[x] - qM1[x]).abs() +
                          (qP1[x] - qP1[x]).abs() +
                          (q0[x - 1] - q0[x - 1]).abs() +
                          (q0[x + 1] - q0[x + 1]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += a0[x] * w;
      sumB += b0[x] * w;
      sumQ += q0[x] * w;
      w = 1 -
          (((a0[x] - aM1[x]).abs() +
                          (aM1[x] - aM2[x]).abs() +
                          (aP1[x] - a0[x]).abs() +
                          (a0[x - 1] - aM1[x - 1]).abs() +
                          (a0[x + 1] - aM1[x + 1]).abs()) *
                      cs0 +
                  ((b0[x] - bM1[x]).abs() +
                          (bM1[x] - bM2[x]).abs() +
                          (bP1[x] - b0[x]).abs() +
                          (b0[x - 1] - bM1[x - 1]).abs() +
                          (b0[x + 1] - bM1[x + 1]).abs()) *
                      cs1 +
                  ((q0[x] - qM1[x]).abs() +
                          (qM1[x] - qM2[x]).abs() +
                          (qP1[x] - q0[x]).abs() +
                          (q0[x - 1] - qM1[x - 1]).abs() +
                          (q0[x + 1] - qM1[x + 1]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += aM1[x] * w;
      sumB += bM1[x] * w;
      sumQ += qM1[x] * w;
      w = 1 -
          (((a0[x] - aP1[x]).abs() +
                          (aM1[x] - a0[x]).abs() +
                          (aP1[x] - aP2[x]).abs() +
                          (a0[x - 1] - aP1[x - 1]).abs() +
                          (a0[x + 1] - aP1[x + 1]).abs()) *
                      cs0 +
                  ((b0[x] - bP1[x]).abs() +
                          (bM1[x] - b0[x]).abs() +
                          (bP1[x] - bP2[x]).abs() +
                          (b0[x - 1] - bP1[x - 1]).abs() +
                          (b0[x + 1] - bP1[x + 1]).abs()) *
                      cs1 +
                  ((q0[x] - qP1[x]).abs() +
                          (qM1[x] - q0[x]).abs() +
                          (qP1[x] - qP2[x]).abs() +
                          (q0[x - 1] - qP1[x - 1]).abs() +
                          (q0[x + 1] - qP1[x + 1]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += aP1[x] * w;
      sumB += bP1[x] * w;
      sumQ += qP1[x] * w;
      w = 1 -
          (((a0[x] - a0[x - 1]).abs() +
                          (aM1[x] - aM1[x - 1]).abs() +
                          (aP1[x] - aP1[x - 1]).abs() +
                          (a0[x - 1] - a0[x - 2]).abs() +
                          (a0[x + 1] - a0[x]).abs()) *
                      cs0 +
                  ((b0[x] - b0[x - 1]).abs() +
                          (bM1[x] - bM1[x - 1]).abs() +
                          (bP1[x] - bP1[x - 1]).abs() +
                          (b0[x - 1] - b0[x - 2]).abs() +
                          (b0[x + 1] - b0[x]).abs()) *
                      cs1 +
                  ((q0[x] - q0[x - 1]).abs() +
                          (qM1[x] - qM1[x - 1]).abs() +
                          (qP1[x] - qP1[x - 1]).abs() +
                          (q0[x - 1] - q0[x - 2]).abs() +
                          (q0[x + 1] - q0[x]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += a0[x - 1] * w;
      sumB += b0[x - 1] * w;
      sumQ += q0[x - 1] * w;
      w = 1 -
          (((a0[x] - a0[x + 1]).abs() +
                          (aM1[x] - aM1[x + 1]).abs() +
                          (aP1[x] - aP1[x + 1]).abs() +
                          (a0[x - 1] - a0[x]).abs() +
                          (a0[x + 1] - a0[x + 2]).abs()) *
                      cs0 +
                  ((b0[x] - b0[x + 1]).abs() +
                          (bM1[x] - bM1[x + 1]).abs() +
                          (bP1[x] - bP1[x + 1]).abs() +
                          (b0[x - 1] - b0[x]).abs() +
                          (b0[x + 1] - b0[x + 2]).abs()) *
                      cs1 +
                  ((q0[x] - q0[x + 1]).abs() +
                          (qM1[x] - qM1[x + 1]).abs() +
                          (qP1[x] - qP1[x + 1]).abs() +
                          (q0[x - 1] - q0[x]).abs() +
                          (q0[x + 1] - q0[x + 2]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += a0[x + 1] * w;
      sumB += b0[x + 1] * w;
      sumQ += q0[x + 1] * w;
      w = 1 -
          (((a0[x] - aP1[x - 1]).abs() +
                          (aM1[x] - a0[x - 1]).abs() +
                          (aP1[x] - aP2[x - 1]).abs() +
                          (a0[x - 1] - aP1[x - 2]).abs() +
                          (a0[x + 1] - aP1[x]).abs()) *
                      cs0 +
                  ((b0[x] - bP1[x - 1]).abs() +
                          (bM1[x] - b0[x - 1]).abs() +
                          (bP1[x] - bP2[x - 1]).abs() +
                          (b0[x - 1] - bP1[x - 2]).abs() +
                          (b0[x + 1] - bP1[x]).abs()) *
                      cs1 +
                  ((q0[x] - qP1[x - 1]).abs() +
                          (qM1[x] - q0[x - 1]).abs() +
                          (qP1[x] - qP2[x - 1]).abs() +
                          (q0[x - 1] - qP1[x - 2]).abs() +
                          (q0[x + 1] - qP1[x]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += aP1[x - 1] * w;
      sumB += bP1[x - 1] * w;
      sumQ += qP1[x - 1] * w;
      w = 1 -
          (((a0[x] - aP1[x + 1]).abs() +
                          (aM1[x] - a0[x + 1]).abs() +
                          (aP1[x] - aP2[x + 1]).abs() +
                          (a0[x - 1] - aP1[x]).abs() +
                          (a0[x + 1] - aP1[x + 2]).abs()) *
                      cs0 +
                  ((b0[x] - bP1[x + 1]).abs() +
                          (bM1[x] - b0[x + 1]).abs() +
                          (bP1[x] - bP2[x + 1]).abs() +
                          (b0[x - 1] - bP1[x]).abs() +
                          (b0[x + 1] - bP1[x + 2]).abs()) *
                      cs1 +
                  ((q0[x] - qP1[x + 1]).abs() +
                          (qM1[x] - q0[x + 1]).abs() +
                          (qP1[x] - qP2[x + 1]).abs() +
                          (q0[x - 1] - qP1[x]).abs() +
                          (q0[x + 1] - qP1[x + 2]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += aP1[x + 1] * w;
      sumB += bP1[x + 1] * w;
      sumQ += qP1[x + 1] * w;
      w = 1 -
          (((a0[x] - aM1[x + 1]).abs() +
                          (aM1[x] - aM2[x + 1]).abs() +
                          (aP1[x] - a0[x + 1]).abs() +
                          (a0[x - 1] - aM1[x]).abs() +
                          (a0[x + 1] - aM1[x + 2]).abs()) *
                      cs0 +
                  ((b0[x] - bM1[x + 1]).abs() +
                          (bM1[x] - bM2[x + 1]).abs() +
                          (bP1[x] - b0[x + 1]).abs() +
                          (b0[x - 1] - bM1[x]).abs() +
                          (b0[x + 1] - bM1[x + 2]).abs()) *
                      cs1 +
                  ((q0[x] - qM1[x + 1]).abs() +
                          (qM1[x] - qM2[x + 1]).abs() +
                          (qP1[x] - q0[x + 1]).abs() +
                          (q0[x - 1] - qM1[x]).abs() +
                          (q0[x + 1] - qM1[x + 2]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += aM1[x + 1] * w;
      sumB += bM1[x + 1] * w;
      sumQ += qM1[x + 1] * w;
      w = 1 -
          (((a0[x] - aM1[x - 1]).abs() +
                          (aM1[x] - aM2[x - 1]).abs() +
                          (aP1[x] - a0[x - 1]).abs() +
                          (a0[x - 1] - aM1[x - 2]).abs() +
                          (a0[x + 1] - aM1[x]).abs()) *
                      cs0 +
                  ((b0[x] - bM1[x - 1]).abs() +
                          (bM1[x] - bM2[x - 1]).abs() +
                          (bP1[x] - b0[x - 1]).abs() +
                          (b0[x - 1] - bM1[x - 2]).abs() +
                          (b0[x + 1] - bM1[x]).abs()) *
                      cs1 +
                  ((q0[x] - qM1[x - 1]).abs() +
                          (qM1[x] - qM2[x - 1]).abs() +
                          (qP1[x] - q0[x - 1]).abs() +
                          (q0[x - 1] - qM1[x - 2]).abs() +
                          (q0[x + 1] - qM1[x]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += aM1[x - 1] * w;
      sumB += bM1[x - 1] * w;
      sumQ += qM1[x - 1] * w;
      w = 1 -
          (((a0[x] - aM2[x]).abs() +
                          (aM1[x] - aM3[x]).abs() +
                          (aP1[x] - aM1[x]).abs() +
                          (a0[x - 1] - aM2[x - 1]).abs() +
                          (a0[x + 1] - aM2[x + 1]).abs()) *
                      cs0 +
                  ((b0[x] - bM2[x]).abs() +
                          (bM1[x] - bM3[x]).abs() +
                          (bP1[x] - bM1[x]).abs() +
                          (b0[x - 1] - bM2[x - 1]).abs() +
                          (b0[x + 1] - bM2[x + 1]).abs()) *
                      cs1 +
                  ((q0[x] - qM2[x]).abs() +
                          (qM1[x] - qM3[x]).abs() +
                          (qP1[x] - qM1[x]).abs() +
                          (q0[x - 1] - qM2[x - 1]).abs() +
                          (q0[x + 1] - qM2[x + 1]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += aM2[x] * w;
      sumB += bM2[x] * w;
      sumQ += qM2[x] * w;
      w = 1 -
          (((a0[x] - aP2[x]).abs() +
                          (aM1[x] - aP1[x]).abs() +
                          (aP1[x] - aP3[x]).abs() +
                          (a0[x - 1] - aP2[x - 1]).abs() +
                          (a0[x + 1] - aP2[x + 1]).abs()) *
                      cs0 +
                  ((b0[x] - bP2[x]).abs() +
                          (bM1[x] - bP1[x]).abs() +
                          (bP1[x] - bP3[x]).abs() +
                          (b0[x - 1] - bP2[x - 1]).abs() +
                          (b0[x + 1] - bP2[x + 1]).abs()) *
                      cs1 +
                  ((q0[x] - qP2[x]).abs() +
                          (qM1[x] - qP1[x]).abs() +
                          (qP1[x] - qP3[x]).abs() +
                          (q0[x - 1] - qP2[x - 1]).abs() +
                          (q0[x + 1] - qP2[x + 1]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += aP2[x] * w;
      sumB += bP2[x] * w;
      sumQ += qP2[x] * w;
      w = 1 -
          (((a0[x] - a0[x + 2]).abs() +
                          (aM1[x] - aM1[x + 2]).abs() +
                          (aP1[x] - aP1[x + 2]).abs() +
                          (a0[x - 1] - a0[x + 1]).abs() +
                          (a0[x + 1] - a0[x + 3]).abs()) *
                      cs0 +
                  ((b0[x] - b0[x + 2]).abs() +
                          (bM1[x] - bM1[x + 2]).abs() +
                          (bP1[x] - bP1[x + 2]).abs() +
                          (b0[x - 1] - b0[x + 1]).abs() +
                          (b0[x + 1] - b0[x + 3]).abs()) *
                      cs1 +
                  ((q0[x] - q0[x + 2]).abs() +
                          (qM1[x] - qM1[x + 2]).abs() +
                          (qP1[x] - qP1[x + 2]).abs() +
                          (q0[x - 1] - q0[x + 1]).abs() +
                          (q0[x + 1] - q0[x + 3]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += a0[x + 2] * w;
      sumB += b0[x + 2] * w;
      sumQ += q0[x + 2] * w;
      w = 1 -
          (((a0[x] - a0[x - 2]).abs() +
                          (aM1[x] - aM1[x - 2]).abs() +
                          (aP1[x] - aP1[x - 2]).abs() +
                          (a0[x - 1] - a0[x - 3]).abs() +
                          (a0[x + 1] - a0[x - 1]).abs()) *
                      cs0 +
                  ((b0[x] - b0[x - 2]).abs() +
                          (bM1[x] - bM1[x - 2]).abs() +
                          (bP1[x] - bP1[x - 2]).abs() +
                          (b0[x - 1] - b0[x - 3]).abs() +
                          (b0[x + 1] - b0[x - 1]).abs()) *
                      cs1 +
                  ((q0[x] - q0[x - 2]).abs() +
                          (qM1[x] - qM1[x - 2]).abs() +
                          (qP1[x] - qP1[x - 2]).abs() +
                          (q0[x - 1] - q0[x - 3]).abs() +
                          (q0[x + 1] - q0[x - 1]).abs()) *
                      cs2) *
              mul;
      if (w < 0) w = 0;
      sumW += w;
      sumA += a0[x - 2] * w;
      sumB += b0[x - 2] * w;
      sumQ += q0[x - 2] * w;
      oa[x] = sumA / sumW;
      ob[x] = sumB / sumW;
      oc[x] = sumQ / sumW;
    }
  }
}

/// SIMD interior kernel for pass 0 (3-channel color): the 12-neighbor
/// double-cross, four pixels at a time, per-neighbor distance summed across
/// all three channels (`cs0/cs1/cs2`). Mirrors `_epfPass0Color`'s scalar
/// term ordering exactly; float32 lane accumulation vs. the scalar's float64
/// (within the lossy tolerance, as the pass 1/2 SIMD kernels established).
/// Row vectors are concrete `Float32x4List` params (CLAUDE.md perf rule).
void _epfPass0ColorVec(
    Float32x4List aM3,
    Float32x4List aM2,
    Float32x4List aM1,
    Float32x4List aC,
    Float32x4List aP1,
    Float32x4List aP2,
    Float32x4List aP3, //
    Float32x4List bM3,
    Float32x4List bM2,
    Float32x4List bM1,
    Float32x4List bC,
    Float32x4List bP1,
    Float32x4List bP2,
    Float32x4List bP3, //
    Float32x4List qM3,
    Float32x4List qM2,
    Float32x4List qM1,
    Float32x4List qC,
    Float32x4List qP1,
    Float32x4List qP2,
    Float32x4List qP3, //
    Float32x4List oA,
    Float32x4List oB,
    Float32x4List oQ,
    Float32List sigmaRow,
    double sigmaScale,
    bool borderY,
    Float32x4 vs0,
    Float32x4 vs1,
    Float32x4 vs2,
    Float32x4 vOne,
    Float32x4 vZero,
    Float32x4 patLo,
    Float32x4 patHi,
    Float32x4 patAll,
    int vecEnd) {
  for (var gx = 8; gx < vecEnd; gx += 8) {
    final s = sigmaRow[gx >> 3];
    final vi = gx >> 2;
    if (s.isNaN || s > 1 / 0.3) {
      oA[vi] = aC[vi];
      oA[vi + 1] = aC[vi + 1];
      oB[vi] = bC[vi];
      oB[vi + 1] = bC[vi + 1];
      oQ[vi] = qC[vi];
      oQ[vi + 1] = qC[vi + 1];
      continue;
    }
    final base = sigmaScale * s;
    for (var h = 0; h < 2; h++) {
      final j = vi + h;
      final mul = borderY
          ? patAll.scale(base)
          : (h == 0 ? patLo.scale(base) : patHi.scale(base));
      // --- channel a shifts ---
      final a0 = aC[j], a0p = aC[j - 1], a0n = aC[j + 1];
      final a1 = aM1[j], a1p = aM1[j - 1], a1n = aM1[j + 1];
      final ad1 = aP1[j], ad1p = aP1[j - 1], ad1n = aP1[j + 1];
      final a2 = aM2[j], a2p = aM2[j - 1], a2n = aM2[j + 1];
      final ad2 = aP2[j], ad2p = aP2[j - 1], ad2n = aP2[j + 1];
      final a3 = aM3[j], ad3 = aP3[j];
      final aw = a0.shuffle(Float32x4.xxyz).withX(a0p.w);
      final ae = a0.shuffle(Float32x4.yzww).withW(a0n.x);
      final aw2 = a0p.shuffleMix(a0, Float32x4.zwxy);
      final ae2 = a0.shuffleMix(a0n, Float32x4.zwxy);
      final aw3 = a0p.shuffle(Float32x4.yzww).withW(a0.x);
      final ae3 = a0n.shuffle(Float32x4.xxyz).withX(a0.w);
      final a1w = a1.shuffle(Float32x4.xxyz).withX(a1p.w);
      final a1e = a1.shuffle(Float32x4.yzww).withW(a1n.x);
      final a1w2 = a1p.shuffleMix(a1, Float32x4.zwxy);
      final a1e2 = a1.shuffleMix(a1n, Float32x4.zwxy);
      final ad1w = ad1.shuffle(Float32x4.xxyz).withX(ad1p.w);
      final ad1e = ad1.shuffle(Float32x4.yzww).withW(ad1n.x);
      final ad1w2 = ad1p.shuffleMix(ad1, Float32x4.zwxy);
      final ad1e2 = ad1.shuffleMix(ad1n, Float32x4.zwxy);
      final a2w = a2.shuffle(Float32x4.xxyz).withX(a2p.w);
      final a2e = a2.shuffle(Float32x4.yzww).withW(a2n.x);
      final ad2w = ad2.shuffle(Float32x4.xxyz).withX(ad2p.w);
      final ad2e = ad2.shuffle(Float32x4.yzww).withW(ad2n.x);
      // --- channel b shifts ---
      final b0 = bC[j], b0p = bC[j - 1], b0n = bC[j + 1];
      final b1 = bM1[j], b1p = bM1[j - 1], b1n = bM1[j + 1];
      final bd1 = bP1[j], bd1p = bP1[j - 1], bd1n = bP1[j + 1];
      final b2 = bM2[j], b2p = bM2[j - 1], b2n = bM2[j + 1];
      final bd2 = bP2[j], bd2p = bP2[j - 1], bd2n = bP2[j + 1];
      final b3 = bM3[j], bd3 = bP3[j];
      final bw = b0.shuffle(Float32x4.xxyz).withX(b0p.w);
      final be = b0.shuffle(Float32x4.yzww).withW(b0n.x);
      final bw2 = b0p.shuffleMix(b0, Float32x4.zwxy);
      final be2 = b0.shuffleMix(b0n, Float32x4.zwxy);
      final bw3 = b0p.shuffle(Float32x4.yzww).withW(b0.x);
      final be3 = b0n.shuffle(Float32x4.xxyz).withX(b0.w);
      final b1w = b1.shuffle(Float32x4.xxyz).withX(b1p.w);
      final b1e = b1.shuffle(Float32x4.yzww).withW(b1n.x);
      final b1w2 = b1p.shuffleMix(b1, Float32x4.zwxy);
      final b1e2 = b1.shuffleMix(b1n, Float32x4.zwxy);
      final bd1w = bd1.shuffle(Float32x4.xxyz).withX(bd1p.w);
      final bd1e = bd1.shuffle(Float32x4.yzww).withW(bd1n.x);
      final bd1w2 = bd1p.shuffleMix(bd1, Float32x4.zwxy);
      final bd1e2 = bd1.shuffleMix(bd1n, Float32x4.zwxy);
      final b2w = b2.shuffle(Float32x4.xxyz).withX(b2p.w);
      final b2e = b2.shuffle(Float32x4.yzww).withW(b2n.x);
      final bd2w = bd2.shuffle(Float32x4.xxyz).withX(bd2p.w);
      final bd2e = bd2.shuffle(Float32x4.yzww).withW(bd2n.x);
      // --- channel q shifts ---
      final q0 = qC[j], q0p = qC[j - 1], q0n = qC[j + 1];
      final q1 = qM1[j], q1p = qM1[j - 1], q1n = qM1[j + 1];
      final qd1 = qP1[j], qd1p = qP1[j - 1], qd1n = qP1[j + 1];
      final q2 = qM2[j], q2p = qM2[j - 1], q2n = qM2[j + 1];
      final qd2 = qP2[j], qd2p = qP2[j - 1], qd2n = qP2[j + 1];
      final q3 = qM3[j], qd3 = qP3[j];
      final qw = q0.shuffle(Float32x4.xxyz).withX(q0p.w);
      final qe = q0.shuffle(Float32x4.yzww).withW(q0n.x);
      final qw2 = q0p.shuffleMix(q0, Float32x4.zwxy);
      final qe2 = q0.shuffleMix(q0n, Float32x4.zwxy);
      final qw3 = q0p.shuffle(Float32x4.yzww).withW(q0.x);
      final qe3 = q0n.shuffle(Float32x4.xxyz).withX(q0.w);
      final q1w = q1.shuffle(Float32x4.xxyz).withX(q1p.w);
      final q1e = q1.shuffle(Float32x4.yzww).withW(q1n.x);
      final q1w2 = q1p.shuffleMix(q1, Float32x4.zwxy);
      final q1e2 = q1.shuffleMix(q1n, Float32x4.zwxy);
      final qd1w = qd1.shuffle(Float32x4.xxyz).withX(qd1p.w);
      final qd1e = qd1.shuffle(Float32x4.yzww).withW(qd1n.x);
      final qd1w2 = qd1p.shuffleMix(qd1, Float32x4.zwxy);
      final qd1e2 = qd1.shuffleMix(qd1n, Float32x4.zwxy);
      final q2w = q2.shuffle(Float32x4.xxyz).withX(q2p.w);
      final q2e = q2.shuffle(Float32x4.yzww).withW(q2n.x);
      final qd2w = qd2.shuffle(Float32x4.xxyz).withX(qd2p.w);
      final qd2e = qd2.shuffle(Float32x4.yzww).withW(qd2n.x);

      var sumW = vOne;
      var sumA = a0;
      var sumB = b0;
      var sumQ = q0;
      // N (dy=-1, dx=0)
      var dist = ((a0 - a1).abs() +
                  (a1 - a2).abs() +
                  (ad1 - a0).abs() +
                  (aw - a1w).abs() +
                  (ae - a1e).abs()) *
              vs0 +
          ((b0 - b1).abs() +
                  (b1 - b2).abs() +
                  (bd1 - b0).abs() +
                  (bw - b1w).abs() +
                  (be - b1e).abs()) *
              vs1 +
          ((q0 - q1).abs() +
                  (q1 - q2).abs() +
                  (qd1 - q0).abs() +
                  (qw - q1w).abs() +
                  (qe - q1e).abs()) *
              vs2;
      var w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += a1 * w;
      sumB += b1 * w;
      sumQ += q1 * w;
      // S (dy=1, dx=0)
      dist = ((a0 - ad1).abs() +
                  (a1 - a0).abs() +
                  (ad1 - ad2).abs() +
                  (aw - ad1w).abs() +
                  (ae - ad1e).abs()) *
              vs0 +
          ((b0 - bd1).abs() +
                  (b1 - b0).abs() +
                  (bd1 - bd2).abs() +
                  (bw - bd1w).abs() +
                  (be - bd1e).abs()) *
              vs1 +
          ((q0 - qd1).abs() +
                  (q1 - q0).abs() +
                  (qd1 - qd2).abs() +
                  (qw - qd1w).abs() +
                  (qe - qd1e).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += ad1 * w;
      sumB += bd1 * w;
      sumQ += qd1 * w;
      // W (dy=0, dx=-1)
      dist = ((a0 - aw).abs() +
                  (a1 - a1w).abs() +
                  (ad1 - ad1w).abs() +
                  (aw - aw2).abs() +
                  (ae - a0).abs()) *
              vs0 +
          ((b0 - bw).abs() +
                  (b1 - b1w).abs() +
                  (bd1 - bd1w).abs() +
                  (bw - bw2).abs() +
                  (be - b0).abs()) *
              vs1 +
          ((q0 - qw).abs() +
                  (q1 - q1w).abs() +
                  (qd1 - qd1w).abs() +
                  (qw - qw2).abs() +
                  (qe - q0).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += aw * w;
      sumB += bw * w;
      sumQ += qw * w;
      // E (dy=0, dx=1)
      dist = ((a0 - ae).abs() +
                  (a1 - a1e).abs() +
                  (ad1 - ad1e).abs() +
                  (aw - a0).abs() +
                  (ae - ae2).abs()) *
              vs0 +
          ((b0 - be).abs() +
                  (b1 - b1e).abs() +
                  (bd1 - bd1e).abs() +
                  (bw - b0).abs() +
                  (be - be2).abs()) *
              vs1 +
          ((q0 - qe).abs() +
                  (q1 - q1e).abs() +
                  (qd1 - qd1e).abs() +
                  (qw - q0).abs() +
                  (qe - qe2).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += ae * w;
      sumB += be * w;
      sumQ += qe * w;
      // SW (dy=1, dx=-1)
      dist = ((a0 - ad1w).abs() +
                  (a1 - aw).abs() +
                  (ad1 - ad2w).abs() +
                  (aw - ad1w2).abs() +
                  (ae - ad1).abs()) *
              vs0 +
          ((b0 - bd1w).abs() +
                  (b1 - bw).abs() +
                  (bd1 - bd2w).abs() +
                  (bw - bd1w2).abs() +
                  (be - bd1).abs()) *
              vs1 +
          ((q0 - qd1w).abs() +
                  (q1 - qw).abs() +
                  (qd1 - qd2w).abs() +
                  (qw - qd1w2).abs() +
                  (qe - qd1).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += ad1w * w;
      sumB += bd1w * w;
      sumQ += qd1w * w;
      // SE (dy=1, dx=1)
      dist = ((a0 - ad1e).abs() +
                  (a1 - ae).abs() +
                  (ad1 - ad2e).abs() +
                  (aw - ad1).abs() +
                  (ae - ad1e2).abs()) *
              vs0 +
          ((b0 - bd1e).abs() +
                  (b1 - be).abs() +
                  (bd1 - bd2e).abs() +
                  (bw - bd1).abs() +
                  (be - bd1e2).abs()) *
              vs1 +
          ((q0 - qd1e).abs() +
                  (q1 - qe).abs() +
                  (qd1 - qd2e).abs() +
                  (qw - qd1).abs() +
                  (qe - qd1e2).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += ad1e * w;
      sumB += bd1e * w;
      sumQ += qd1e * w;
      // NE (dy=-1, dx=1)
      dist = ((a0 - a1e).abs() +
                  (a1 - a2e).abs() +
                  (ad1 - ae).abs() +
                  (aw - a1).abs() +
                  (ae - a1e2).abs()) *
              vs0 +
          ((b0 - b1e).abs() +
                  (b1 - b2e).abs() +
                  (bd1 - be).abs() +
                  (bw - b1).abs() +
                  (be - b1e2).abs()) *
              vs1 +
          ((q0 - q1e).abs() +
                  (q1 - q2e).abs() +
                  (qd1 - qe).abs() +
                  (qw - q1).abs() +
                  (qe - q1e2).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += a1e * w;
      sumB += b1e * w;
      sumQ += q1e * w;
      // NW (dy=-1, dx=-1)
      dist = ((a0 - a1w).abs() +
                  (a1 - a2w).abs() +
                  (ad1 - aw).abs() +
                  (aw - a1w2).abs() +
                  (ae - a1).abs()) *
              vs0 +
          ((b0 - b1w).abs() +
                  (b1 - b2w).abs() +
                  (bd1 - bw).abs() +
                  (bw - b1w2).abs() +
                  (be - b1).abs()) *
              vs1 +
          ((q0 - q1w).abs() +
                  (q1 - q2w).abs() +
                  (qd1 - qw).abs() +
                  (qw - q1w2).abs() +
                  (qe - q1).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += a1w * w;
      sumB += b1w * w;
      sumQ += q1w * w;
      // NN (dy=-2, dx=0)
      dist = ((a0 - a2).abs() +
                  (a1 - a3).abs() +
                  (ad1 - a1).abs() +
                  (aw - a2w).abs() +
                  (ae - a2e).abs()) *
              vs0 +
          ((b0 - b2).abs() +
                  (b1 - b3).abs() +
                  (bd1 - b1).abs() +
                  (bw - b2w).abs() +
                  (be - b2e).abs()) *
              vs1 +
          ((q0 - q2).abs() +
                  (q1 - q3).abs() +
                  (qd1 - q1).abs() +
                  (qw - q2w).abs() +
                  (qe - q2e).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += a2 * w;
      sumB += b2 * w;
      sumQ += q2 * w;
      // SS (dy=2, dx=0)
      dist = ((a0 - ad2).abs() +
                  (a1 - ad1).abs() +
                  (ad1 - ad3).abs() +
                  (aw - ad2w).abs() +
                  (ae - ad2e).abs()) *
              vs0 +
          ((b0 - bd2).abs() +
                  (b1 - bd1).abs() +
                  (bd1 - bd3).abs() +
                  (bw - bd2w).abs() +
                  (be - bd2e).abs()) *
              vs1 +
          ((q0 - qd2).abs() +
                  (q1 - qd1).abs() +
                  (qd1 - qd3).abs() +
                  (qw - qd2w).abs() +
                  (qe - qd2e).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += ad2 * w;
      sumB += bd2 * w;
      sumQ += qd2 * w;
      // EE (dy=0, dx=2)
      dist = ((a0 - ae2).abs() +
                  (a1 - a1e2).abs() +
                  (ad1 - ad1e2).abs() +
                  (aw - ae).abs() +
                  (ae - ae3).abs()) *
              vs0 +
          ((b0 - be2).abs() +
                  (b1 - b1e2).abs() +
                  (bd1 - bd1e2).abs() +
                  (bw - be).abs() +
                  (be - be3).abs()) *
              vs1 +
          ((q0 - qe2).abs() +
                  (q1 - q1e2).abs() +
                  (qd1 - qd1e2).abs() +
                  (qw - qe).abs() +
                  (qe - qe3).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += ae2 * w;
      sumB += be2 * w;
      sumQ += qe2 * w;
      // WW (dy=0, dx=-2)
      dist = ((a0 - aw2).abs() +
                  (a1 - a1w2).abs() +
                  (ad1 - ad1w2).abs() +
                  (aw - aw3).abs() +
                  (ae - aw).abs()) *
              vs0 +
          ((b0 - bw2).abs() +
                  (b1 - b1w2).abs() +
                  (bd1 - bd1w2).abs() +
                  (bw - bw3).abs() +
                  (be - bw).abs()) *
              vs1 +
          ((q0 - qw2).abs() +
                  (q1 - q1w2).abs() +
                  (qd1 - qd1w2).abs() +
                  (qw - qw3).abs() +
                  (qe - qw).abs()) *
              vs2;
      w = (vOne - dist * mul).max(vZero);
      sumW += w;
      sumA += aw2 * w;
      sumB += bw2 * w;
      sumQ += qw2 * w;
      oA[j] = sumA / sumW;
      oB[j] = sumB / sumW;
      oQ[j] = sumQ / sumW;
    }
  }
}

void _epfPassGray(
    List<Float32List> input,
    List<Float32List> output,
    List<List<Float32List>> inputRows,
    List<List<Float32List>> outputRows,
    RestorationFilter rf,
    List<Float32List>? inverseSigma,
    double invModularSigma,
    double sigmaScale,
    int i,
    int height,
    int width) {
  final scaleSum =
      rf.epfChannelScale[0] + rf.epfChannelScale[1] + rf.epfChannelScale[2];
  final borderSadMul = rf.epfBorderSadMul;
  final sumChannels = Float32List(1);
  final pass2 = i == 2;
  final inV = rowVectorViews(input);
  final outV = rowVectorViews(output);
  final vScaleSum = Float32x4.splat(scaleSum);
  final vOne = Float32x4.splat(1.0);
  final vZero = Float32x4.zero();
  final patLo = Float32x4(borderSadMul, 1, 1, 1);
  final patHi = Float32x4(1, 1, 1, borderSadMul);
  final patAll = Float32x4.splat(borderSadMul);
  final vecEnd = width >= 24 ? (width - 12) & ~7 : 8;
  final hasVec = vecEnd > 8;
  // A constant sigma row keeps the hot loop free of null checks for the
  // modular case.
  Float32List? constSigmaRow;
  if (inverseSigma == null) {
    constSigmaRow = Float32List((width + 7) >> 3);
    constSigmaRow.fillRange(0, constSigmaRow.length, invModularSigma);
  }
  final xEnd = width - 2 < 2 ? 2 : width - 2;
  for (var y = 0; y < height; y++) {
    final sigmaRow =
        inverseSigma != null ? inverseSigma[y >> 3] : constSigmaRow!;
    if (y < 2 || y + 2 >= height) {
      for (var x = 0; x < width; x++) {
        final s = sigmaRow[x >> 3];
        if (s.isNaN || s > 1 / 0.3) {
          output[y][x] = input[y][x];
          continue;
        }
        _epfPixelGeneral(
            inputRows,
            outputRows,
            1,
            rf.epfChannelScale,
            borderSadMul,
            _epfCrossDy,
            _epfCrossDx,
            sigmaScale,
            s,
            i,
            y,
            x,
            height,
            width,
            sumChannels);
      }
      continue;
    }
    // Border columns via the general path, outside the hot loop.
    for (var x = 0; x < width; x++) {
      if (x == 2 && width > 4) x = width - 2;
      final s = sigmaRow[x >> 3];
      if (s.isNaN || s > 1 / 0.3) {
        output[y][x] = input[y][x];
        continue;
      }
      _epfPixelGeneral(
          inputRows,
          outputRows,
          1,
          rf.epfChannelScale,
          borderSadMul,
          _epfCrossDy,
          _epfCrossDx,
          sigmaScale,
          s,
          i,
          y,
          x,
          height,
          width,
          sumChannels);
    }
    if (width <= 4) continue;
    final rM2 = input[y - 2];
    final rM1 = input[y - 1];
    final r0 = input[y];
    final rP1 = input[y + 1];
    final rP2 = input[y + 2];
    final out = output[y];
    final modY = y & 7;
    final borderY = modY == 0 || modY == 7;
    if (hasVec) {
      final vM1 = inV[y - 1];
      final v0 = inV[y];
      final vP1 = inV[y + 1];
      final vOut = outV[y];
      if (pass2) {
        for (var gx = 8; gx < vecEnd; gx += 8) {
          final s = sigmaRow[gx >> 3];
          final vi = gx >> 2;
          if (s.isNaN || s > 1 / 0.3) {
            vOut[vi] = v0[vi];
            vOut[vi + 1] = v0[vi + 1];
            continue;
          }
          final base = sigmaScale * s;
          for (var h = 0; h < 2; h++) {
            final j = vi + h;
            final mul = borderY
                ? patAll.scale(base)
                : (h == 0 ? patLo.scale(base) : patHi.scale(base));
            final c0 = v0[j];
            final p0 = v0[j - 1];
            final n0 = v0[j + 1];
            final cN = vM1[j];
            final cS = vP1[j];
            final w0 = c0.shuffle(Float32x4.xxyz).withX(p0.w);
            final e0 = c0.shuffle(Float32x4.yzww).withW(n0.x);
            var sumW = vOne;
            var sum = c0;
            var w = (vOne - (c0 - cN).abs() * vScaleSum * mul).max(vZero);
            sumW += w;
            sum += cN * w;
            w = (vOne - (c0 - cS).abs() * vScaleSum * mul).max(vZero);
            sumW += w;
            sum += cS * w;
            w = (vOne - (c0 - w0).abs() * vScaleSum * mul).max(vZero);
            sumW += w;
            sum += w0 * w;
            w = (vOne - (c0 - e0).abs() * vScaleSum * mul).max(vZero);
            sumW += w;
            sum += e0 * w;
            vOut[j] = sum / sumW;
          }
        }
      } else {
        final vM2 = inV[y - 2];
        final vP2 = inV[y + 2];
        for (var gx = 8; gx < vecEnd; gx += 8) {
          final s = sigmaRow[gx >> 3];
          final vi = gx >> 2;
          if (s.isNaN || s > 1 / 0.3) {
            vOut[vi] = v0[vi];
            vOut[vi + 1] = v0[vi + 1];
            continue;
          }
          final base = sigmaScale * s;
          for (var h = 0; h < 2; h++) {
            final j = vi + h;
            final mul = borderY
                ? patAll.scale(base)
                : (h == 0 ? patLo.scale(base) : patHi.scale(base));
            final c0 = v0[j];
            final p0 = v0[j - 1];
            final n0 = v0[j + 1];
            final cN = vM1[j];
            final pN = vM1[j - 1];
            final nN = vM1[j + 1];
            final cS = vP1[j];
            final pS = vP1[j - 1];
            final nS = vP1[j + 1];
            final cN2 = vM2[j];
            final cS2 = vP2[j];
            final w0 = c0.shuffle(Float32x4.xxyz).withX(p0.w);
            final e0 = c0.shuffle(Float32x4.yzww).withW(n0.x);
            final wN = cN.shuffle(Float32x4.xxyz).withX(pN.w);
            final eN = cN.shuffle(Float32x4.yzww).withW(nN.x);
            final wS = cS.shuffle(Float32x4.xxyz).withX(pS.w);
            final eS = cS.shuffle(Float32x4.yzww).withW(nS.x);
            final w20 = p0.shuffleMix(c0, Float32x4.zwxy);
            final e20 = c0.shuffleMix(n0, Float32x4.zwxy);
            final distN = ((c0 - cN).abs() +
                    (cN - cN2).abs() +
                    (cS - c0).abs() +
                    (w0 - wN).abs() +
                    (e0 - eN).abs()) *
                vScaleSum;
            final distS = ((c0 - cS).abs() +
                    (cN - c0).abs() +
                    (cS - cS2).abs() +
                    (w0 - wS).abs() +
                    (e0 - eS).abs()) *
                vScaleSum;
            final distW = ((c0 - w0).abs() +
                    (cN - wN).abs() +
                    (cS - wS).abs() +
                    (w0 - w20).abs() +
                    (e0 - c0).abs()) *
                vScaleSum;
            final distE = ((c0 - e0).abs() +
                    (cN - eN).abs() +
                    (cS - eS).abs() +
                    (w0 - c0).abs() +
                    (e0 - e20).abs()) *
                vScaleSum;
            var sumW = vOne;
            var sum = c0;
            var w = (vOne - distN * mul).max(vZero);
            sumW += w;
            sum += cN * w;
            w = (vOne - distS * mul).max(vZero);
            sumW += w;
            sum += cS * w;
            w = (vOne - distW * mul).max(vZero);
            sumW += w;
            sum += w0 * w;
            w = (vOne - distE * mul).max(vZero);
            sumW += w;
            sum += e0 * w;
            vOut[j] = sum / sumW;
          }
        }
      }
    }
    if (pass2) {
      for (var x = 2; x < xEnd; x++) {
        if (hasVec && x == 8) x = vecEnd;
        final s = sigmaRow[x >> 3];
        if (s.isNaN || s > 1 / 0.3) {
          out[x] = r0[x];
          continue;
        }
        final modX = x & 7;
        final mul = borderY || modX == 0 || modX == 7
            ? sigmaScale * s * borderSadMul
            : sigmaScale * s;
        final c0 = r0[x];
        final cN = rM1[x];
        final cS = rP1[x];
        final cW = r0[x - 1];
        final cE = r0[x + 1];
        var sumWeights = 1.0;
        var sum = c0;
        var w = 1 - (c0 - cN).abs() * scaleSum * mul;
        if (w > 0) {
          sumWeights += w;
          sum += cN * w;
        }
        w = 1 - (c0 - cS).abs() * scaleSum * mul;
        if (w > 0) {
          sumWeights += w;
          sum += cS * w;
        }
        w = 1 - (c0 - cW).abs() * scaleSum * mul;
        if (w > 0) {
          sumWeights += w;
          sum += cW * w;
        }
        w = 1 - (c0 - cE).abs() * scaleSum * mul;
        if (w > 0) {
          sumWeights += w;
          sum += cE * w;
        }
        out[x] = sum / sumWeights;
      }
      continue;
    }
    for (var x = 2; x < xEnd; x++) {
      if (hasVec && x == 8) x = vecEnd;
      final s = sigmaRow[x >> 3];
      if (s.isNaN || s > 1 / 0.3) {
        out[x] = r0[x];
        continue;
      }
      final modX = x & 7;
      final mul = borderY || modX == 0 || modX == 7
          ? sigmaScale * s * borderSadMul
          : sigmaScale * s;
      final c0 = r0[x];
      final cN = rM1[x];
      final cS = rP1[x];
      final cW = r0[x - 1];
      final cE = r0[x + 1];
      var sumWeights = 1.0; // center cross has distance 0 -> weight 1
      var sum = c0;
      var dist = ((c0 - cN).abs() +
              (cN - rM2[x]).abs() +
              (cS - c0).abs() +
              (cW - rM1[x - 1]).abs() +
              (cE - rM1[x + 1]).abs()) *
          scaleSum;
      var w = 1 - dist * mul;
      if (w > 0) {
        sumWeights += w;
        sum += cN * w;
      }
      dist = ((c0 - cS).abs() +
              (cN - c0).abs() +
              (cS - rP2[x]).abs() +
              (cW - rP1[x - 1]).abs() +
              (cE - rP1[x + 1]).abs()) *
          scaleSum;
      w = 1 - dist * mul;
      if (w > 0) {
        sumWeights += w;
        sum += cS * w;
      }
      dist = ((c0 - cW).abs() +
              (cN - rM1[x - 1]).abs() +
              (cS - rP1[x - 1]).abs() +
              (cW - r0[x - 2]).abs() +
              (cE - c0).abs()) *
          scaleSum;
      w = 1 - dist * mul;
      if (w > 0) {
        sumWeights += w;
        sum += cW * w;
      }
      dist = ((c0 - cE).abs() +
              (cN - rM1[x + 1]).abs() +
              (cS - rP1[x + 1]).abs() +
              (cW - c0).abs() +
              (cE - r0[x + 2]).abs()) *
          scaleSum;
      w = 1 - dist * mul;
      if (w > 0) {
        sumWeights += w;
        sum += cE * w;
      }
      out[x] = sum / sumWeights;
    }
  }
}

void _epfPassColor(
    List<Float32List> in0,
    List<Float32List> in1,
    List<Float32List> in2,
    List<Float32List> out0,
    List<Float32List> out1,
    List<Float32List> out2,
    List<List<Float32List>> inputRows,
    List<List<Float32List>> outputRows,
    int colors,
    RestorationFilter rf,
    List<Float32List>? inverseSigma,
    double invModularSigma,
    double sigmaScale,
    int i,
    int height,
    int width) {
  final s0 = rf.epfChannelScale[0];
  final s1 = rf.epfChannelScale[1];
  final s2 = rf.epfChannelScale[2];
  final borderSadMul = rf.epfBorderSadMul;
  final sumChannels = Float32List(colors);
  final pass2 = i == 2;
  final inV0 = rowVectorViews(in0);
  final inV1 = rowVectorViews(in1);
  final inV2 = rowVectorViews(in2);
  final outV0 = rowVectorViews(out0);
  final outV1 = rowVectorViews(out1);
  final outV2 = rowVectorViews(out2);
  final vs0 = Float32x4.splat(s0);
  final vs1 = Float32x4.splat(s1);
  final vs2 = Float32x4.splat(s2);
  final vOne = Float32x4.splat(1.0);
  final vZero = Float32x4.zero();
  final patLo = Float32x4(borderSadMul, 1, 1, 1);
  final patHi = Float32x4(1, 1, 1, borderSadMul);
  final patAll = Float32x4.splat(borderSadMul);
  final vecEnd = width >= 24 ? (width - 12) & ~7 : 8;
  final hasVec = vecEnd > 8;
  for (var y = 0; y < height; y++) {
    if (y < 2 || y + 2 >= height) {
      for (var x = 0; x < width; x++) {
        final s = inverseSigma != null
            ? inverseSigma[y >> 3][x >> 3]
            : invModularSigma;
        if (s.isNaN || s > 1 / 0.3) {
          for (var c = 0; c < colors; c++) {
            outputRows[c][y][x] = inputRows[c][y][x];
          }
          continue;
        }
        _epfPixelGeneral(
            inputRows,
            outputRows,
            colors,
            rf.epfChannelScale,
            borderSadMul,
            _epfCrossDy,
            _epfCrossDx,
            sigmaScale,
            s,
            i,
            y,
            x,
            height,
            width,
            sumChannels);
      }
      continue;
    }
    final aM2 = in0[y - 2];
    final aM1 = in0[y - 1];
    final a0 = in0[y];
    final aP1 = in0[y + 1];
    final aP2 = in0[y + 2];
    final bM2 = in1[y - 2];
    final bM1 = in1[y - 1];
    final b0 = in1[y];
    final bP1 = in1[y + 1];
    final bP2 = in1[y + 2];
    final cM2 = in2[y - 2];
    final cM1 = in2[y - 1];
    final c0r = in2[y];
    final cP1 = in2[y + 1];
    final cP2 = in2[y + 2];
    final oa = out0[y];
    final ob = out1[y];
    final oc = out2[y];
    final modY = y & 7;
    final borderY = modY == 0 || modY == 7;
    final sigmaRow = inverseSigma?[y >> 3];
    if (hasVec) {
      final vAM1 = inV0[y - 1];
      final vA0 = inV0[y];
      final vAP1 = inV0[y + 1];
      final vBM1 = inV1[y - 1];
      final vB0 = inV1[y];
      final vBP1 = inV1[y + 1];
      final vQM1 = inV2[y - 1];
      final vQ0 = inV2[y];
      final vQP1 = inV2[y + 1];
      final vOutA = outV0[y];
      final vOutB = outV1[y];
      final vOutQ = outV2[y];
      if (pass2) {
        for (var gx = 8; gx < vecEnd; gx += 8) {
          final s = sigmaRow != null ? sigmaRow[gx >> 3] : invModularSigma;
          final vi = gx >> 2;
          if (s.isNaN || s > 1 / 0.3) {
            vOutA[vi] = vA0[vi];
            vOutA[vi + 1] = vA0[vi + 1];
            vOutB[vi] = vB0[vi];
            vOutB[vi + 1] = vB0[vi + 1];
            vOutQ[vi] = vQ0[vi];
            vOutQ[vi + 1] = vQ0[vi + 1];
            continue;
          }
          final base = sigmaScale * s;
          for (var h = 0; h < 2; h++) {
            final j = vi + h;
            final mul = borderY
                ? patAll.scale(base)
                : (h == 0 ? patLo.scale(base) : patHi.scale(base));
            final cA = vA0[j];
            final pA = vA0[j - 1];
            final nA = vA0[j + 1];
            final cAN = vAM1[j];
            final cAS = vAP1[j];
            final wA = cA.shuffle(Float32x4.xxyz).withX(pA.w);
            final eA = cA.shuffle(Float32x4.yzww).withW(nA.x);
            final cB = vB0[j];
            final pB = vB0[j - 1];
            final nB = vB0[j + 1];
            final cBN = vBM1[j];
            final cBS = vBP1[j];
            final wB = cB.shuffle(Float32x4.xxyz).withX(pB.w);
            final eB = cB.shuffle(Float32x4.yzww).withW(nB.x);
            final cQ = vQ0[j];
            final pQ = vQ0[j - 1];
            final nQ = vQ0[j + 1];
            final cQN = vQM1[j];
            final cQS = vQP1[j];
            final wQ = cQ.shuffle(Float32x4.xxyz).withX(pQ.w);
            final eQ = cQ.shuffle(Float32x4.yzww).withW(nQ.x);
            var sumW = vOne;
            var sumA = cA;
            var sumB = cB;
            var sumQ = cQ;
            final distN = (cA - cAN).abs() * vs0 +
                (cB - cBN).abs() * vs1 +
                (cQ - cQN).abs() * vs2;
            var w = (vOne - distN * mul).max(vZero);
            sumW += w;
            sumA += cAN * w;
            sumB += cBN * w;
            sumQ += cQN * w;
            final distS = (cA - cAS).abs() * vs0 +
                (cB - cBS).abs() * vs1 +
                (cQ - cQS).abs() * vs2;
            w = (vOne - distS * mul).max(vZero);
            sumW += w;
            sumA += cAS * w;
            sumB += cBS * w;
            sumQ += cQS * w;
            final distW = (cA - wA).abs() * vs0 +
                (cB - wB).abs() * vs1 +
                (cQ - wQ).abs() * vs2;
            w = (vOne - distW * mul).max(vZero);
            sumW += w;
            sumA += wA * w;
            sumB += wB * w;
            sumQ += wQ * w;
            final distE = (cA - eA).abs() * vs0 +
                (cB - eB).abs() * vs1 +
                (cQ - eQ).abs() * vs2;
            w = (vOne - distE * mul).max(vZero);
            sumW += w;
            sumA += eA * w;
            sumB += eB * w;
            sumQ += eQ * w;
            vOutA[j] = sumA / sumW;
            vOutB[j] = sumB / sumW;
            vOutQ[j] = sumQ / sumW;
          }
        }
      } else {
        final vAM2 = inV0[y - 2];
        final vAP2 = inV0[y + 2];
        final vBM2 = inV1[y - 2];
        final vBP2 = inV1[y + 2];
        final vQM2 = inV2[y - 2];
        final vQP2 = inV2[y + 2];
        for (var gx = 8; gx < vecEnd; gx += 8) {
          final s = sigmaRow != null ? sigmaRow[gx >> 3] : invModularSigma;
          final vi = gx >> 2;
          if (s.isNaN || s > 1 / 0.3) {
            vOutA[vi] = vA0[vi];
            vOutA[vi + 1] = vA0[vi + 1];
            vOutB[vi] = vB0[vi];
            vOutB[vi + 1] = vB0[vi + 1];
            vOutQ[vi] = vQ0[vi];
            vOutQ[vi + 1] = vQ0[vi + 1];
            continue;
          }
          final base = sigmaScale * s;
          for (var h = 0; h < 2; h++) {
            final j = vi + h;
            final mul = borderY
                ? patAll.scale(base)
                : (h == 0 ? patLo.scale(base) : patHi.scale(base));
            final cA = vA0[j];
            final pA = vA0[j - 1];
            final nA = vA0[j + 1];
            final cAN = vAM1[j];
            final cAS = vAP1[j];
            final pAN = vAM1[j - 1];
            final nAN = vAM1[j + 1];
            final pAS = vAP1[j - 1];
            final nAS = vAP1[j + 1];
            final cAM2 = vAM2[j];
            final cAP2 = vAP2[j];
            final wA = cA.shuffle(Float32x4.xxyz).withX(pA.w);
            final eA = cA.shuffle(Float32x4.yzww).withW(nA.x);
            final wAN = cAN.shuffle(Float32x4.xxyz).withX(pAN.w);
            final eAN = cAN.shuffle(Float32x4.yzww).withW(nAN.x);
            final wAS = cAS.shuffle(Float32x4.xxyz).withX(pAS.w);
            final eAS = cAS.shuffle(Float32x4.yzww).withW(nAS.x);
            final w2A = pA.shuffleMix(cA, Float32x4.zwxy);
            final e2A = cA.shuffleMix(nA, Float32x4.zwxy);
            final cB = vB0[j];
            final pB = vB0[j - 1];
            final nB = vB0[j + 1];
            final cBN = vBM1[j];
            final cBS = vBP1[j];
            final pBN = vBM1[j - 1];
            final nBN = vBM1[j + 1];
            final pBS = vBP1[j - 1];
            final nBS = vBP1[j + 1];
            final cBM2 = vBM2[j];
            final cBP2 = vBP2[j];
            final wB = cB.shuffle(Float32x4.xxyz).withX(pB.w);
            final eB = cB.shuffle(Float32x4.yzww).withW(nB.x);
            final wBN = cBN.shuffle(Float32x4.xxyz).withX(pBN.w);
            final eBN = cBN.shuffle(Float32x4.yzww).withW(nBN.x);
            final wBS = cBS.shuffle(Float32x4.xxyz).withX(pBS.w);
            final eBS = cBS.shuffle(Float32x4.yzww).withW(nBS.x);
            final w2B = pB.shuffleMix(cB, Float32x4.zwxy);
            final e2B = cB.shuffleMix(nB, Float32x4.zwxy);
            final cQ = vQ0[j];
            final pQ = vQ0[j - 1];
            final nQ = vQ0[j + 1];
            final cQN = vQM1[j];
            final cQS = vQP1[j];
            final pQN = vQM1[j - 1];
            final nQN = vQM1[j + 1];
            final pQS = vQP1[j - 1];
            final nQS = vQP1[j + 1];
            final cQM2 = vQM2[j];
            final cQP2 = vQP2[j];
            final wQ = cQ.shuffle(Float32x4.xxyz).withX(pQ.w);
            final eQ = cQ.shuffle(Float32x4.yzww).withW(nQ.x);
            final wQN = cQN.shuffle(Float32x4.xxyz).withX(pQN.w);
            final eQN = cQN.shuffle(Float32x4.yzww).withW(nQN.x);
            final wQS = cQS.shuffle(Float32x4.xxyz).withX(pQS.w);
            final eQS = cQS.shuffle(Float32x4.yzww).withW(nQS.x);
            final w2Q = pQ.shuffleMix(cQ, Float32x4.zwxy);
            final e2Q = cQ.shuffleMix(nQ, Float32x4.zwxy);
            var sumW = vOne;
            var sumA = cA;
            var sumB = cB;
            var sumQ = cQ;
            final distN = ((cA - cAN).abs() +
                        (cAN - cAM2).abs() +
                        (cAS - cA).abs() +
                        (wA - wAN).abs() +
                        (eA - eAN).abs()) *
                    vs0 +
                ((cB - cBN).abs() +
                        (cBN - cBM2).abs() +
                        (cBS - cB).abs() +
                        (wB - wBN).abs() +
                        (eB - eBN).abs()) *
                    vs1 +
                ((cQ - cQN).abs() +
                        (cQN - cQM2).abs() +
                        (cQS - cQ).abs() +
                        (wQ - wQN).abs() +
                        (eQ - eQN).abs()) *
                    vs2;
            var w = (vOne - distN * mul).max(vZero);
            sumW += w;
            sumA += cAN * w;
            sumB += cBN * w;
            sumQ += cQN * w;
            final distS = ((cA - cAS).abs() +
                        (cAN - cA).abs() +
                        (cAS - cAP2).abs() +
                        (wA - wAS).abs() +
                        (eA - eAS).abs()) *
                    vs0 +
                ((cB - cBS).abs() +
                        (cBN - cB).abs() +
                        (cBS - cBP2).abs() +
                        (wB - wBS).abs() +
                        (eB - eBS).abs()) *
                    vs1 +
                ((cQ - cQS).abs() +
                        (cQN - cQ).abs() +
                        (cQS - cQP2).abs() +
                        (wQ - wQS).abs() +
                        (eQ - eQS).abs()) *
                    vs2;
            w = (vOne - distS * mul).max(vZero);
            sumW += w;
            sumA += cAS * w;
            sumB += cBS * w;
            sumQ += cQS * w;
            final distW = ((cA - wA).abs() +
                        (cAN - wAN).abs() +
                        (cAS - wAS).abs() +
                        (wA - w2A).abs() +
                        (eA - cA).abs()) *
                    vs0 +
                ((cB - wB).abs() +
                        (cBN - wBN).abs() +
                        (cBS - wBS).abs() +
                        (wB - w2B).abs() +
                        (eB - cB).abs()) *
                    vs1 +
                ((cQ - wQ).abs() +
                        (cQN - wQN).abs() +
                        (cQS - wQS).abs() +
                        (wQ - w2Q).abs() +
                        (eQ - cQ).abs()) *
                    vs2;
            w = (vOne - distW * mul).max(vZero);
            sumW += w;
            sumA += wA * w;
            sumB += wB * w;
            sumQ += wQ * w;
            final distE = ((cA - eA).abs() +
                        (cAN - eAN).abs() +
                        (cAS - eAS).abs() +
                        (wA - cA).abs() +
                        (eA - e2A).abs()) *
                    vs0 +
                ((cB - eB).abs() +
                        (cBN - eBN).abs() +
                        (cBS - eBS).abs() +
                        (wB - cB).abs() +
                        (eB - e2B).abs()) *
                    vs1 +
                ((cQ - eQ).abs() +
                        (cQN - eQN).abs() +
                        (cQS - eQS).abs() +
                        (wQ - cQ).abs() +
                        (eQ - e2Q).abs()) *
                    vs2;
            w = (vOne - distE * mul).max(vZero);
            sumW += w;
            sumA += eA * w;
            sumB += eB * w;
            sumQ += eQ * w;
            vOutA[j] = sumA / sumW;
            vOutB[j] = sumB / sumW;
            vOutQ[j] = sumQ / sumW;
          }
        }
      }
    }
    for (var x = 0; x < width; x++) {
      if (hasVec && x == 8) x = vecEnd;
      final s = sigmaRow != null ? sigmaRow[x >> 3] : invModularSigma;
      if (s.isNaN || s > 1 / 0.3) {
        oa[x] = a0[x];
        ob[x] = b0[x];
        oc[x] = c0r[x];
        continue;
      }
      if (x < 2 || x + 2 >= width) {
        _epfPixelGeneral(
            inputRows,
            outputRows,
            colors,
            rf.epfChannelScale,
            borderSadMul,
            _epfCrossDy,
            _epfCrossDx,
            sigmaScale,
            s,
            i,
            y,
            x,
            height,
            width,
            sumChannels);
        continue;
      }
      final modX = x & 7;
      final mul = borderY || modX == 0 || modX == 7
          ? sigmaScale * s * borderSadMul
          : sigmaScale * s;
      final a = a0[x];
      final aN = aM1[x];
      final aS = aP1[x];
      final aW = a0[x - 1];
      final aE = a0[x + 1];
      final b = b0[x];
      final bN = bM1[x];
      final bS = bP1[x];
      final bW = b0[x - 1];
      final bE = b0[x + 1];
      final cc = c0r[x];
      final ccN = cM1[x];
      final ccS = cP1[x];
      final ccW = c0r[x - 1];
      final ccE = c0r[x + 1];
      var sumWeights = 1.0;
      var sumA = a;
      var sumB = b;
      var sumC = cc;
      double dist;
      double w;
      // North.
      if (pass2) {
        dist =
            (a - aN).abs() * s0 + (b - bN).abs() * s1 + (cc - ccN).abs() * s2;
      } else {
        dist = ((a - aN).abs() +
                    (aN - aM2[x]).abs() +
                    (aS - a).abs() +
                    (aW - aM1[x - 1]).abs() +
                    (aE - aM1[x + 1]).abs()) *
                s0 +
            ((b - bN).abs() +
                    (bN - bM2[x]).abs() +
                    (bS - b).abs() +
                    (bW - bM1[x - 1]).abs() +
                    (bE - bM1[x + 1]).abs()) *
                s1 +
            ((cc - ccN).abs() +
                    (ccN - cM2[x]).abs() +
                    (ccS - cc).abs() +
                    (ccW - cM1[x - 1]).abs() +
                    (ccE - cM1[x + 1]).abs()) *
                s2;
      }
      w = 1 - dist * mul;
      if (w > 0) {
        sumWeights += w;
        sumA += aN * w;
        sumB += bN * w;
        sumC += ccN * w;
      }
      // South.
      if (pass2) {
        dist =
            (a - aS).abs() * s0 + (b - bS).abs() * s1 + (cc - ccS).abs() * s2;
      } else {
        dist = ((a - aS).abs() +
                    (aN - a).abs() +
                    (aS - aP2[x]).abs() +
                    (aW - aP1[x - 1]).abs() +
                    (aE - aP1[x + 1]).abs()) *
                s0 +
            ((b - bS).abs() +
                    (bN - b).abs() +
                    (bS - bP2[x]).abs() +
                    (bW - bP1[x - 1]).abs() +
                    (bE - bP1[x + 1]).abs()) *
                s1 +
            ((cc - ccS).abs() +
                    (ccN - cc).abs() +
                    (ccS - cP2[x]).abs() +
                    (ccW - cP1[x - 1]).abs() +
                    (ccE - cP1[x + 1]).abs()) *
                s2;
      }
      w = 1 - dist * mul;
      if (w > 0) {
        sumWeights += w;
        sumA += aS * w;
        sumB += bS * w;
        sumC += ccS * w;
      }
      // West.
      if (pass2) {
        dist =
            (a - aW).abs() * s0 + (b - bW).abs() * s1 + (cc - ccW).abs() * s2;
      } else {
        dist = ((a - aW).abs() +
                    (aN - aM1[x - 1]).abs() +
                    (aS - aP1[x - 1]).abs() +
                    (aW - a0[x - 2]).abs() +
                    (aE - a).abs()) *
                s0 +
            ((b - bW).abs() +
                    (bN - bM1[x - 1]).abs() +
                    (bS - bP1[x - 1]).abs() +
                    (bW - b0[x - 2]).abs() +
                    (bE - b).abs()) *
                s1 +
            ((cc - ccW).abs() +
                    (ccN - cM1[x - 1]).abs() +
                    (ccS - cP1[x - 1]).abs() +
                    (ccW - c0r[x - 2]).abs() +
                    (ccE - cc).abs()) *
                s2;
      }
      w = 1 - dist * mul;
      if (w > 0) {
        sumWeights += w;
        sumA += aW * w;
        sumB += bW * w;
        sumC += ccW * w;
      }
      // East.
      if (pass2) {
        dist =
            (a - aE).abs() * s0 + (b - bE).abs() * s1 + (cc - ccE).abs() * s2;
      } else {
        dist = ((a - aE).abs() +
                    (aN - aM1[x + 1]).abs() +
                    (aS - aP1[x + 1]).abs() +
                    (aW - a).abs() +
                    (aE - a0[x + 2]).abs()) *
                s0 +
            ((b - bE).abs() +
                    (bN - bM1[x + 1]).abs() +
                    (bS - bP1[x + 1]).abs() +
                    (bW - b).abs() +
                    (bE - b0[x + 2]).abs()) *
                s1 +
            ((cc - ccE).abs() +
                    (ccN - cM1[x + 1]).abs() +
                    (ccS - cP1[x + 1]).abs() +
                    (ccW - cc).abs() +
                    (ccE - c0r[x + 2]).abs()) *
                s2;
      }
      w = 1 - dist * mul;
      if (w > 0) {
        sumWeights += w;
        sumA += aE * w;
        sumB += bE * w;
        sumC += ccE * w;
      }
      oa[x] = sumA / sumWeights;
      ob[x] = sumB / sumWeights;
      oc[x] = sumC / sumWeights;
    }
  }
}

double _epfDistance1(
    List<List<Float32List>> buffer,
    int colors,
    Float32List channelScale,
    int basePosY,
    int basePosX,
    int dCrossY,
    int dCrossX,
    int height,
    int width) {
  var dist = 0.0;
  for (var c = 0; c < 3; c++) {
    final i = colors == 1 ? 0 : c;
    final buffC = buffer[i];
    final scale = channelScale[c];
    for (var e = 0; e < 5; e++) {
      final cy = _epfCrossDy[e];
      final cx = _epfCrossDx[e];
      final pY = mirrorCoordinate(basePosY + cy, height);
      final pX = mirrorCoordinate(basePosX + cx, width);
      final dY = mirrorCoordinate(basePosY + dCrossY + cy, height);
      final dX = mirrorCoordinate(basePosX + dCrossX + cx, width);
      dist += (buffC[pY][pX] - buffC[dY][dX]).abs() * scale;
    }
  }
  return dist;
}

double _epfDistance2(
    List<List<Float32List>> buffer,
    int colors,
    Float32List channelScale,
    int basePosY,
    int basePosX,
    int crossY,
    int crossX,
    int height,
    int width) {
  var dist = 0.0;
  for (var c = 0; c < 3; c++) {
    final i = colors == 1 ? 0 : c;
    final buffC = buffer[i];
    final dY = mirrorCoordinate(basePosY + crossY, height);
    final dX = mirrorCoordinate(basePosX + crossX, width);
    dist += (buffC[basePosY][basePosX] - buffC[dY][dX]).abs() * channelScale[c];
  }
  return dist;
}

double _epfWeight(double borderSadMul, double sigmaScale, double distance,
    double inverseSigma, int refY, int refX) {
  final modY = refY & 7;
  final modX = refX & 7;
  if (modY == 0 || modY == 7 || modX == 0 || modX == 7) {
    distance *= borderSadMul;
  }
  final v = 1 - distance * sigmaScale * inverseSigma;
  return v < 0 ? 0 : v;
}
