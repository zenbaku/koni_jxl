import 'dart:math' as math;
import 'dart:typed_data';

import '../../color/color_encoding.dart';
import '../../color/opsin_inverse.dart';
import '../../color/transfer_function.dart';

double _cbrt(double v) =>
    v < 0 ? -math.pow(-v, 1 / 3).toDouble() : math.pow(v, 1 / 3).toDouble();

List<double> _invert3x3(List<double> m) {
  final a = m[0], b = m[1], c = m[2];
  final d = m[3], e = m[4], f = m[5];
  final g = m[6], h = m[7], i = m[8];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  final invDet = 1.0 / det;
  return [
    (e * i - f * h) * invDet, (c * h - b * i) * invDet,
    (b * f - c * e) * invDet, //
    (f * g - d * i) * invDet, (a * i - c * g) * invDet,
    (c * d - a * f) * invDet, //
    (d * h - e * g) * invDet, (b * g - a * h) * invDet,
    (a * e - b * d) * invDet, //
  ];
}

/// Forward XYB transform: the exact inverse of
/// [OpsinInverseMatrix.invertXyb] with the default matrix/bias and
/// `intensityTarget == 255` (`itScale == 1`), which is what an encoder that
/// writes `default_matrix = true` (the only mode this encoder supports)
/// always gets on decode.
final class XybForward {
  XybForward() : _inv = _invert3x3(_matrix.matrix);

  static const _matrix = OpsinInverseMatrix();
  final List<double> _inv;

  /// Converts linear-light RGB rows (the same domain
  /// [OpsinInverseMatrix.invertXyb] produces, roughly `[0, 1]` for SDR) in
  /// place into XYB rows.
  void forward(List<Float32List> rRows, List<Float32List> gRows,
      List<Float32List> bRows) {
    final ob0 = _matrix.opsinBias[0];
    final ob1 = _matrix.opsinBias[1];
    final ob2 = _matrix.opsinBias[2];
    final cob0 = _cbrt(ob0);
    final cob1 = _cbrt(ob1);
    final cob2 = _cbrt(ob2);
    final inv = _inv;
    for (var y = 0; y < rRows.length; y++) {
      final rRow = rRows[y];
      final gRow = gRows[y];
      final bRow = bRows[y];
      for (var x = 0; x < rRow.length; x++) {
        final r = rRow[x], g = gRow[x], bl = bRow[x];
        final mixL = inv[0] * r + inv[1] * g + inv[2] * bl;
        final mixM = inv[3] * r + inv[4] * g + inv[5] * bl;
        final mixS = inv[6] * r + inv[7] * g + inv[8] * bl;
        final gammaL = _cbrt(mixL - ob0);
        final gammaM = _cbrt(mixM - ob1);
        final gammaS = _cbrt(mixS - ob2);
        rRow[x] = 0.5 * (gammaL - gammaM + cob0 - cob1); // X
        gRow[x] = 0.5 * (gammaL + gammaM + cob0 + cob1); // Y
        bRow[x] = gammaS + cob2; // B
      }
    }
  }

  /// Converts 8-bit sRGB samples (0..255) in place into linear-light values
  /// suitable for [forward], via the sRGB EOTF.
  static void srgbToLinear(List<Float32List> rows) {
    final tf = TransferFunction.forTransfer(ColorFlags.tfSrgb);
    for (final row in rows) {
      for (var x = 0; x < row.length; x++) {
        row[x] = tf.toLinear(row[x] / 255.0);
      }
    }
  }
}
