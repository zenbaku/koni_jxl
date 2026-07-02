import 'dart:math' as math;
import 'dart:typed_data';

import '../exceptions.dart';
import '../frame/frame.dart';
import '../frame/frame_flags.dart';
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
    final rows = frame.buffer[c].floatRows();
    final newBuffer = ImageBuffer.float32(height, width);
    final newRows = newBuffer.floatRows();
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

// (dy, dx) offsets.
const _epfCross = [
  (0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), //
];

const _epfDoubleCross = [
  (0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), //
  (1, -1), (1, 1), (-1, 1), (-1, -1), //
  (-2, 0), (2, 0), (0, 2), (0, -2),
];

/// Edge-preserving filter: up to three weighted-average passes over the
/// color channels, guided by per-block sigma.
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
      for (var c = 0; c < colors; c++) frame.buffer[c].floatRows(),
    ];
    final outputRows = [
      for (var c = 0; c < colors; c++) outputBuffer[c].floatRows(),
    ];
    final double sigmaScale;
    if (i == 0) {
      sigmaScale = stepMultiplier * rf.epfPass0SigmaScale;
    } else if (i == 2) {
      sigmaScale = stepMultiplier * rf.epfPass2SigmaScale;
    } else {
      sigmaScale = stepMultiplier;
    }
    final crossList = i == 0 ? _epfDoubleCross : _epfCross;
    final sumChannels = Float32List(colors);
    for (var y = 0; y < padded.height; y++) {
      for (var x = 0; x < padded.width; x++) {
        final double s;
        if (inverseSigma != null) {
          s = inverseSigma[y >> 3][x >> 3];
        } else {
          s = invModularSigma;
        }
        if (s.isNaN || s > 1 / 0.3) {
          for (var c = 0; c < colors; c++) {
            outputRows[c][y][x] = inputRows[c][y][x];
          }
          continue;
        }
        var sumWeights = 0.0;
        sumChannels.fillRange(0, colors, 0);
        for (final (cy, cx) in crossList) {
          final dist = i == 2
              ? _epfDistance2(inputRows, colors, rf.epfChannelScale, y, x, cy,
                  cx, padded.height, padded.width)
              : _epfDistance1(inputRows, colors, rf.epfChannelScale, y, x, cy,
                  cx, padded.height, padded.width);
          final weight =
              _epfWeight(rf.epfBorderSadMul, sigmaScale, dist, s, y, x);
          sumWeights += weight;
          final mY = mirrorCoordinate(y + cy, padded.height);
          final mX = mirrorCoordinate(x + cx, padded.width);
          for (var c = 0; c < colors; c++) {
            sumChannels[c] += inputRows[c][mY][mX] * weight;
          }
        }
        for (var c = 0; c < colors; c++) {
          outputRows[c][y][x] = sumChannels[c] / sumWeights;
        }
      }
    }
    for (var c = 0; c < colors; c++) {
      final tmp = frame.buffer[c];
      frame.buffer[c] = outputBuffer[c];
      outputBuffer[c] = tmp;
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
    for (final (cy, cx) in _epfCross) {
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
