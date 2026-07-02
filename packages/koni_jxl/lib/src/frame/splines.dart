import 'dart:math' as math;

import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';
import 'frame.dart';

/// The LfGlobal splines bundle (control points and 32-coefficient DCTs for
/// the X/Y/B intensities and sigma along each spline).
final class SplinesBundle {
  SplinesBundle.read(BitReader reader) {
    final stream = EntropyStream.read(reader, 6);
    numSplines = 1 + stream.readSymbol(reader, 2);
    splineY = List.filled(numSplines, 0);
    splineX = List.filled(numSplines, 0);
    for (var i = 0; i < numSplines; i++) {
      var x = stream.readSymbol(reader, 1);
      var y = stream.readSymbol(reader, 1);
      if (i != 0) {
        x = unpackSigned(x) + splineX[i - 1];
        y = unpackSigned(y) + splineY[i - 1];
      }
      splineX[i] = x;
      splineY[i] = y;
    }
    quantAdjust = unpackSigned(stream.readSymbol(reader, 0));
    controlPointsY = List.generate(numSplines, (_) => <int>[]);
    controlPointsX = List.generate(numSplines, (_) => <int>[]);
    coeffX = List.generate(numSplines, (_) => List.filled(32, 0));
    coeffY = List.generate(numSplines, (_) => List.filled(32, 0));
    coeffB = List.generate(numSplines, (_) => List.filled(32, 0));
    coeffSigma = List.generate(numSplines, (_) => List.filled(32, 0));
    for (var i = 0; i < numSplines; i++) {
      final count = 1 + stream.readSymbol(reader, 3);
      controlPointsY[i].add(splineY[i]);
      controlPointsX[i].add(splineX[i]);
      final deltaY = List.filled(count - 1, 0);
      final deltaX = List.filled(count - 1, 0);
      for (var j = 0; j < count - 1; j++) {
        deltaX[j] = unpackSigned(stream.readSymbol(reader, 4));
        deltaY[j] = unpackSigned(stream.readSymbol(reader, 4));
      }
      var cY = splineY[i];
      var cX = splineX[i];
      var dY = 0;
      var dX = 0;
      for (var j = 1; j < count; j++) {
        dY += deltaY[j - 1];
        dX += deltaX[j - 1];
        cY += dY;
        cX += dX;
        controlPointsY[i].add(cY);
        controlPointsX[i].add(cX);
      }
      for (var j = 0; j < 32; j++) {
        coeffX[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        coeffY[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        coeffB[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
      for (var j = 0; j < 32; j++) {
        coeffSigma[i][j] = unpackSigned(stream.readSymbol(reader, 5));
      }
    }
    if (!stream.validateFinalState()) {
      throw const JxlInvalidBitstreamException(
          'illegal final ANS state in splines');
    }
  }

  late final int numSplines;
  late final int quantAdjust;
  late final List<int> splineY;
  late final List<int> splineX;
  late final List<List<int>> controlPointsY;
  late final List<List<int>> controlPointsX;
  late final List<List<int>> coeffX;
  late final List<List<int>> coeffY;
  late final List<List<int>> coeffB;
  late final List<List<int>> coeffSigma;
}

const _sqrtH = 0.7071067811865476; // sqrt(0.5)
const _sqrtF = 0.3535533905932738; // sqrt(0.125)

double _fourierICT(List<double> coeffs, double t) {
  var total = _sqrtH * coeffs[0];
  for (var i = 1; i < 32; i++) {
    total += coeffs[i] * math.cos(i * (math.pi / 32) * (t + 0.5));
  }
  return total;
}

/// Draws all splines of the frame onto its (float, pre-color-transform)
/// color channels.
///
/// Deviates from jxlatte, which renders every spline with spline 0's
/// coefficients (its Spline constructor never stores the spline index);
/// here each spline uses its own coefficients, matching djxl.
void renderSplines(Frame frame) {
  final bundle = frame.lfGlobal.splines;
  if (bundle == null) return;
  if (frame.colorChannelCount < 3) {
    throw const JxlInvalidBitstreamException(
        'splines require 3 color channels');
  }
  for (var s = 0; s < bundle.numSplines; s++) {
    _renderSpline(frame, bundle, s);
  }
}

void _renderSpline(Frame frame, SplinesBundle bundle, int splineID) {
  // Coefficients, with quant adjustment and LF chroma correlation baked in.
  final lfc = frame.lfGlobal.lfChanCorr;
  final quantAdjust = bundle.quantAdjust / 8.0;
  final invQa =
      quantAdjust >= 0 ? 1.0 / (1.0 + quantAdjust) : 1.0 - quantAdjust;
  final yAdjust = 0.106066017 * invQa;
  final xAdjust = 0.005939697 * invQa;
  final bAdjust = 0.098994949 * invQa;
  final sigmaAdjust = 0.47135738 * invQa;
  final coeffX = List<double>.filled(32, 0);
  final coeffY = List<double>.filled(32, 0);
  final coeffB = List<double>.filled(32, 0);
  final coeffSigma = List<double>.filled(32, 0);
  for (var i = 0; i < 32; i++) {
    coeffY[i] = bundle.coeffY[splineID][i] * yAdjust;
    coeffX[i] =
        bundle.coeffX[splineID][i] * xAdjust + lfc.baseCorrelationX * coeffY[i];
    coeffB[i] =
        bundle.coeffB[splineID][i] * bAdjust + lfc.baseCorrelationB * coeffY[i];
    coeffSigma[i] = bundle.coeffSigma[splineID][i] * sigmaAdjust;
  }

  // Centripetal Catmull-Rom upsampling of the control points (16 segments
  // per span).
  final cpY = bundle.controlPointsY[splineID];
  final cpX = bundle.controlPointsX[splineID];
  final n = cpY.length;
  List<double> upY;
  List<double> upX;
  if (n == 1) {
    upY = [cpY[0].toDouble()];
    upX = [cpX[0].toDouble()];
  } else {
    final extY = [
      2.0 * cpY[0] - cpY[1],
      ...cpY.map((v) => v.toDouble()),
      2.0 * cpY[n - 1] - cpY[n - 2]
    ];
    final extX = [
      2.0 * cpX[0] - cpX[1],
      ...cpX.map((v) => v.toDouble()),
      2.0 * cpX[n - 1] - cpX[n - 2]
    ];
    upY = List.filled(16 * (extY.length - 3) + 1, 0);
    upX = List.filled(upY.length, 0);
    final t = List<double>.filled(4, 0);
    final dY = List<double>.filled(3, 0);
    final dX = List<double>.filled(3, 0);
    final aY = List<double>.filled(3, 0);
    final aX = List<double>.filled(3, 0);
    final bY = List<double>.filled(2, 0);
    final bX = List<double>.filled(2, 0);
    for (var i = 0; i < extY.length - 3; i++) {
      upY[i << 4] = extY[i + 1];
      upX[i << 4] = extX[i + 1];
      t[0] = 0;
      for (var k = 0; k < 3; k++) {
        dY[k] = extY[i + k + 1] - extY[i + k];
        dX[k] = extX[i + k + 1] - extX[i + k];
        t[k + 1] =
            t[k] + math.pow(dY[k] * dY[k] + dX[k] * dX[k], 0.25).toDouble();
      }
      for (var step = 1; step < 16; step++) {
        final knot = t[1] + 0.0625 * step * (t[2] - t[1]);
        for (var k = 0; k < 3; k++) {
          final f = (knot - t[k]) / (t[k + 1] - t[k]);
          aY[k] = dY[k] * f + extY[i + k];
          aX[k] = dX[k] * f + extX[i + k];
        }
        for (var k = 0; k < 2; k++) {
          final f = (knot - t[k]) / (t[k + 2] - t[k]);
          bY[k] = (aY[k + 1] - aY[k]) * f + aY[k];
          bX[k] = (aX[k + 1] - aX[k]) * f + aX[k];
        }
        final f = (knot - t[1]) / (t[2] - t[1]);
        upY[i * 16 + step] = (bY[1] - bY[0]) * f + bY[0];
        upX[i * 16 + step] = (bX[1] - bX[0]) * f + bX[0];
      }
    }
    upY[upY.length - 1] = cpY[n - 1].toDouble();
    upX[upX.length - 1] = cpX[n - 1].toDouble();
  }

  // Resample to equal arc-length samples.
  const renderDistance = 1.0;
  final arcY = <double>[];
  final arcX = <double>[];
  final arcLen = <double>[];
  var currentY = upY[0];
  var currentX = upX[0];
  var nextID = 0;
  arcY.add(currentY);
  arcX.add(currentX);
  arcLen.add(renderDistance);
  while (nextID < upY.length) {
    var prevY = currentY;
    var prevX = currentX;
    var fromPrevious = 0.0;
    while (true) {
      if (nextID >= upY.length) {
        arcY.add(prevY);
        arcX.add(prevX);
        arcLen.add(fromPrevious);
        break;
      }
      final nY = upY[nextID];
      final nX = upX[nextID];
      final dY = nY - prevY;
      final dX = nX - prevX;
      final toNext = math.sqrt(dY * dY + dX * dX);
      if (fromPrevious + toNext >= renderDistance) {
        final f = (renderDistance - fromPrevious) / toNext;
        currentY = dY * f + prevY;
        currentX = dX * f + prevX;
        arcY.add(currentY);
        arcX.add(currentX);
        arcLen.add(renderDistance);
        break;
      }
      fromPrevious += toNext;
      prevY = nY;
      prevX = nX;
      nextID++;
    }
  }

  final totalArc = (arcY.length - 2.0) * renderDistance + arcLen.last;
  if (totalArc <= 0) return;

  final width = frame.boundsWidth;
  final height = frame.boundsHeight;
  final bits = frame.globalMetadata.bitDepth.bitsPerSample;
  for (var c = 0; c < 3; c++) {
    frame.buffer[c].castToFloat(bits);
  }
  final rows = [for (var c = 0; c < 3; c++) frame.buffer[c].floatRows];
  final values = List<double>.filled(3, 0);
  for (var i = 0; i < arcY.length; i++) {
    final progress = math.min(1.0, i * renderDistance / totalArc);
    final t = 31.0 * progress;
    values[0] = _fourierICT(coeffX, t) * arcLen[i];
    values[1] = _fourierICT(coeffY, t) * arcLen[i];
    values[2] = _fourierICT(coeffB, t) * arcLen[i];
    final sigma = _fourierICT(coeffSigma, t);
    final inverseSigma = 1.0 / sigma;
    final maxColor =
        [0.01, values[0], values[1], values[2]].reduce((a, b) => a > b ? a : b);
    final maxDist =
        math.sqrt(-2.0 * sigma * sigma * (math.log(0.1) * 3.0 - maxColor));
    final xBegin = math.max(0, (arcX[i] - maxDist).round());
    final xEnd = math.min(width - 1, (arcX[i] + maxDist).round());
    final yBegin = math.max(0, (arcY[i] - maxDist).round());
    final yEnd = math.min(height - 1, (arcY[i] + maxDist).round());
    for (var c = 0; c < 3; c++) {
      final fb = rows[c];
      for (var y = yBegin; y <= yEnd; y++) {
        final fby = fb[y];
        final dY = y - arcY[i];
        for (var x = xBegin; x <= xEnd; x++) {
          final dX = x - arcX[i];
          final distance = math.sqrt(dY * dY + dX * dX);
          var factor = erf((0.5 * distance + _sqrtF) * inverseSigma);
          factor -= erf((0.5 * distance - _sqrtF) * inverseSigma);
          fby[x] += 0.25 * values[c] * sigma * factor * factor;
        }
      }
    }
  }
}
