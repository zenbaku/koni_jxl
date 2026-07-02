import '../io/bit_reader.dart';
import 'color_encoding.dart';

/// The XYB → linear RGB opsin inverse matrix bundle.
///
/// Only parsing and storage live here for now; the actual `invertXyb`
/// pixel transform lands with VarDCT support.
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
}
