import 'dart:typed_data';

import '../exceptions.dart';
import '../util/math_helper.dart';

const _llfScaleTable = <double>[
  1.0000000000000000000, 1.0003954307206444720, 1.0015830492063566798, //
  1.0035668445359847378, 1.0063534990068075448, 1.0099524393750471170, //
  1.0143759095929498827, 1.0196390660646908181, 1.0257600967811994622, //
  1.0327603660498609462, 1.0406645869479269795, 1.0495010240726261235, //
  1.0593017296818027804, 1.0701028169146909598, 1.0819447744633102634, //
  1.0948728278735071820, 1.1089373535928257701, 1.1241943530045446156, //
  1.1407059950032801390, 1.1585412372562662921, 1.1777765381971696030, //
  1.1984966740821024139, 1.2207956782314713353, 1.2447779229495839992, //
  1.2705593687655135089, 1.2982690107340108228, 1.3280505578212198723, //
  1.3600643892400108061, 1.3944898413648201160, 1.4315278911623840964, //
  1.4714043176060183528, 1.5143734423313919909,
];

double _scaleF(int x, int xll) => _llfScaleTable[x << (5 - xll)];

/// Transform (encoding) methods.
abstract final class TransformMethod {
  static const dct = 0;
  static const dct2 = 1;
  static const dct4 = 2;
  static const hornuss = 3;
  static const dct8x4 = 4;
  static const dct4x8 = 5;
  static const afv = 6;
}

/// Quant-table encoding modes.
abstract final class TransformMode {
  static const library = 0;
  static const hornuss = 1;
  static const dct2 = 2;
  static const dct4 = 3;
  static const dct4x8 = 4;
  static const afv = 5;
  static const dct = 6;
  static const raw = 7;
}

/// One of the 27 VarDCT transform types.
final class TransformType {
  TransformType._(this.name, this.type, this.parameterIndex, this.orderID,
      this.transformMethod, this.pixelHeight, this.pixelWidth)
      : dctSelectHeight = pixelHeight >> 3,
        dctSelectWidth = pixelWidth >> 3,
        matrixHeight = pixelHeight < pixelWidth ? pixelHeight : pixelWidth,
        matrixWidth = pixelHeight > pixelWidth ? pixelHeight : pixelWidth {
    llfScale = Float32List(dctSelectHeight * dctSelectWidth);
    final yll = ceilLog2(dctSelectHeight);
    final xll = ceilLog2(dctSelectWidth);
    for (var y = 0; y < dctSelectHeight; y++) {
      for (var x = 0; x < dctSelectWidth; x++) {
        llfScale[y * dctSelectWidth + x] = _scaleF(y, yll) * _scaleF(x, xll);
      }
    }
  }

  final String name;
  final int type;
  final int parameterIndex;
  final int orderID;
  final int transformMethod;
  final int pixelHeight;
  final int pixelWidth;
  final int dctSelectHeight;
  final int dctSelectWidth;
  final int matrixHeight;
  final int matrixWidth;

  /// [dctSelectHeight] x [dctSelectWidth] LLF scale factors, flattened.
  late final Float32List llfScale;

  bool get isVertical => pixelHeight > pixelWidth;

  bool get flip =>
      pixelHeight > pixelWidth ||
      transformMethod == TransformMethod.dct && pixelHeight == pixelWidth;

  @override
  String toString() => name;

  static final List<TransformType> values = _buildValues();

  static List<TransformType> _buildValues() => [
        TransformType._('DCT 8x8', 0, 0, 0, TransformMethod.dct, 8, 8),
        TransformType._('Hornuss', 1, 1, 1, TransformMethod.hornuss, 8, 8),
        TransformType._('DCT 2x2', 2, 2, 1, TransformMethod.dct2, 8, 8),
        TransformType._('DCT 4x4', 3, 3, 1, TransformMethod.dct4, 8, 8),
        TransformType._('DCT 16x16', 4, 4, 2, TransformMethod.dct, 16, 16),
        TransformType._('DCT 32x32', 5, 5, 3, TransformMethod.dct, 32, 32),
        TransformType._('DCT 16x8', 6, 6, 4, TransformMethod.dct, 16, 8),
        TransformType._('DCT 8x16', 7, 6, 4, TransformMethod.dct, 8, 16),
        TransformType._('DCT 32x8', 8, 7, 5, TransformMethod.dct, 32, 8),
        TransformType._('DCT 8x32', 9, 7, 5, TransformMethod.dct, 8, 32),
        TransformType._('DCT 32x16', 10, 8, 6, TransformMethod.dct, 32, 16),
        TransformType._('DCT 16x32', 11, 8, 6, TransformMethod.dct, 16, 32),
        TransformType._('DCT 4x8', 12, 9, 1, TransformMethod.dct4x8, 8, 8),
        TransformType._('DCT 8x4', 13, 9, 1, TransformMethod.dct8x4, 8, 8),
        TransformType._('AFV0', 14, 10, 1, TransformMethod.afv, 8, 8),
        TransformType._('AFV1', 15, 10, 1, TransformMethod.afv, 8, 8),
        TransformType._('AFV2', 16, 10, 1, TransformMethod.afv, 8, 8),
        TransformType._('AFV3', 17, 10, 1, TransformMethod.afv, 8, 8),
        TransformType._('DCT 64x64', 18, 11, 7, TransformMethod.dct, 64, 64),
        TransformType._('DCT 64x32', 19, 12, 8, TransformMethod.dct, 64, 32),
        TransformType._('DCT 32x64', 20, 12, 8, TransformMethod.dct, 32, 64),
        TransformType._(
            'DCT 128x128', 21, 13, 9, TransformMethod.dct, 128, 128),
        TransformType._('DCT 128x64', 22, 14, 10, TransformMethod.dct, 128, 64),
        TransformType._('DCT 64x128', 23, 14, 10, TransformMethod.dct, 64, 128),
        TransformType._(
            'DCT 256x256', 24, 15, 11, TransformMethod.dct, 256, 256),
        TransformType._(
            'DCT 256x128', 25, 16, 12, TransformMethod.dct, 256, 128),
        TransformType._(
            'DCT 128x256', 26, 16, 12, TransformMethod.dct, 128, 256),
      ];

  static final List<TransformType> _byParameterIndex = () {
    final lookup = List<TransformType?>.filled(17, null);
    for (final t in values) {
      if (!t.isVertical) lookup[t.parameterIndex] ??= t;
    }
    return lookup.cast<TransformType>();
  }();

  static final List<TransformType> _byOrderID = () {
    final lookup = List<TransformType?>.filled(13, null);
    for (final t in values) {
      if (!t.isVertical) lookup[t.orderID] ??= t;
    }
    return lookup.cast<TransformType>();
  }();

  static TransformType byType(int typeIndex) => values[typeIndex];

  static TransformType byParameterIndex(int parameterIndex) =>
      _byParameterIndex[parameterIndex];

  static TransformType byOrderID(int orderID) => _byOrderID[orderID];

  static void validateIndex(int index, int mode) {
    if (mode == TransformMode.library ||
        mode == TransformMode.dct ||
        mode == TransformMode.raw) {
      return;
    }
    if (index >= 0 && index <= 3 || index == 9 || index == 10) return;
    throw JxlInvalidBitstreamException('invalid index for mode: $index, $mode');
  }
}
