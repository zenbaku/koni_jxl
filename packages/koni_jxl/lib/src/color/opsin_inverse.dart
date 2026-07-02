import 'dart:math' as math;
import 'dart:typed_data';

import '../io/bit_reader.dart';
import 'color_encoding.dart';
import 'color_management.dart';

/// The XYB → linear RGB opsin inverse matrix bundle.
final class OpsinInverseMatrix {
  static const _defaultMatrix = [
    11.031566901960783, -9.866943921568629, -0.16462299647058826, //
    -3.254147380392157, 4.418770392156863, -0.16462299647058826, //
    -3.6588512862745097, 2.7129230470588235, 1.9459282392156863,
  ];

  static const _defaultOpsinBias = [
    -0.0037930732552754493,
    -0.0037930732552754493,
    -0.0037930732552754493,
  ];

  static const _defaultQuantBias = [
    0.945349926692846,
    0.9299455010825141,
    0.9500648966626564,
  ];

  static const _defaultQuantBiasNumerator = 0.145;

  const OpsinInverseMatrix()
      : matrix = _defaultMatrix,
        opsinBias = _defaultOpsinBias,
        quantBias = _defaultQuantBias,
        quantBiasNumerator = _defaultQuantBiasNumerator;

  factory OpsinInverseMatrix.read(BitReader reader) {
    if (reader.readBool()) return const OpsinInverseMatrix();
    final matrix = List<double>.generate(9, (_) => reader.readF16());
    final opsinBias = List<double>.generate(3, (_) => reader.readF16());
    final quantBias = List<double>.generate(3, (_) => reader.readF16());
    final quantBiasNumerator = reader.readF16();
    return OpsinInverseMatrix._(
        matrix, opsinBias, quantBias, quantBiasNumerator);
  }

  const OpsinInverseMatrix._(
      this.matrix, this.opsinBias, this.quantBias, this.quantBiasNumerator);

  /// Row-major 3x3 matrix.
  final List<double> matrix;
  final List<double> opsinBias;
  final List<double> quantBias;
  final double quantBiasNumerator;

  /// Primaries/white point this matrix targets before any conversion.
  CiePrimaries get primaries => ColorFlags.getPrimaries(ColorFlags.priSrgb)!;
  CieXy get whitePoint => ColorFlags.getWhitePoint(ColorFlags.wpD65)!;

  /// Returns this matrix adapted to produce linear RGB with the given
  /// primaries and white point (instead of sRGB/D65).
  OpsinInverseMatrix getMatrix(CiePrimaries targetPrim, CieXy targetWP) {
    final conversion =
        getConversionMatrix(targetPrim, targetWP, primaries, whitePoint);
    final m = [
      [matrix[0], matrix[1], matrix[2]],
      [matrix[3], matrix[4], matrix[5]],
      [matrix[6], matrix[7], matrix[8]],
    ];
    final adapted = matrixMultiply3(conversion, m);
    return OpsinInverseMatrix._([
      for (var y = 0; y < 3; y++) ...adapted[y],
    ], opsinBias, quantBias, quantBiasNumerator);
  }

  /// Inverts XYB to linear RGB in place over the given channel rows
  /// (X, Y, B order in; R, G, B out).
  void invertXyb(List<List<Float32List>> buffer, double intensityTarget) {
    final itScale = 255.0 / intensityTarget;
    final scaledMatrix = Float32List(9);
    for (var i = 0; i < 9; i++) {
      scaledMatrix[i] = matrix[i] * itScale;
    }
    final ob0 = opsinBias[0];
    final ob1 = opsinBias[1];
    final ob2 = opsinBias[2];
    final cob0 = -_cbrt(opsinBias[0]);
    final cob1 = -_cbrt(opsinBias[1]);
    final cob2 = -_cbrt(opsinBias[2]);
    final xRows = buffer[0];
    final yRows = buffer[1];
    final bRows = buffer[2];
    for (var y = 0; y < xRows.length; y++) {
      final xRow = xRows[y];
      final yRow = yRows[y];
      final bRow = bRows[y];
      for (var x = 0; x < xRow.length; x++) {
        final xybX = xRow[x];
        final xybY = yRow[x];
        final xybB = bRow[x];
        final gammaL = xybY + xybX + cob0;
        final gammaM = xybY - xybX + cob1;
        final gammaS = xybB + cob2;
        final mixL = gammaL * gammaL * gammaL + ob0;
        final mixM = gammaM * gammaM * gammaM + ob1;
        final mixS = gammaS * gammaS * gammaS + ob2;
        xRow[x] = scaledMatrix[0] * mixL +
            scaledMatrix[1] * mixM +
            scaledMatrix[2] * mixS;
        yRow[x] = scaledMatrix[3] * mixL +
            scaledMatrix[4] * mixM +
            scaledMatrix[5] * mixS;
        bRow[x] = scaledMatrix[6] * mixL +
            scaledMatrix[7] * mixM +
            scaledMatrix[8] * mixS;
      }
    }
  }

  static double _cbrt(double v) =>
      v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();
}
