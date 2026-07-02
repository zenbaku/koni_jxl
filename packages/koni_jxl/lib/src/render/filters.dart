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
    for (var y = 0; y < height; y++) {
      final north = y == 0 ? 0 : y - 1;
      final south = y + 1 == height ? height - 1 : y + 1;
      final buffR = rows[y];
      final buffN = rows[north];
      final buffS = rows[south];
      final out = newRows[y];
      for (var x = 0; x < width; x++) {
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
/// Pass 0 (only when epfIterations == 3) uses the general path; passes 1
/// and 2 run specialized row kernels for the interior with a general
/// fallback at borders. Term ordering matches the general path exactly so
/// results are bit-identical.
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
    if (i == 0) {
      _epfPassGeneral(inputRows, outputRows, colors, rf, inverseSigma,
          invModularSigma, sigmaScale, i, padded.height, padded.width);
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

void _epfPassGeneral(
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
  final crossDy = i == 0 ? _epfDoubleCrossDy : _epfCrossDy;
  final crossDx = i == 0 ? _epfDoubleCrossDx : _epfCrossDx;
  final sumChannels = Float32List(colors);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final s =
          inverseSigma != null ? inverseSigma[y >> 3][x >> 3] : invModularSigma;
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
          rf.epfBorderSadMul,
          crossDy,
          crossDx,
          sigmaScale,
          s,
          i,
          y,
          x,
          height,
          width,
          sumChannels);
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
    if (pass2) {
      for (var x = 2; x < xEnd; x++) {
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
    for (var x = 0; x < width; x++) {
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
