import '../io/bit_reader.dart';

final class SqueezeParam {
  SqueezeParam.read(BitReader reader)
      : horizontal = reader.readBool(),
        inPlace = reader.readBool(),
        beginC = reader.readU32(0, 3, 8, 6, 72, 10, 1096, 13),
        numC = reader.readU32(1, 0, 2, 0, 3, 0, 4, 4);

  SqueezeParam(this.horizontal, this.inPlace, this.beginC, this.numC);

  final bool horizontal;
  final bool inPlace;
  final int beginC;
  final int numC;
}

/// One entry of a modular stream's transform chain.
final class TransformInfo {
  static const rct = 0;
  static const palette = 1;
  static const squeeze = 2;

  factory TransformInfo.read(BitReader reader) {
    final tr = reader.readBits(2);
    final beginC =
        tr != squeeze ? reader.readU32(0, 3, 8, 6, 72, 10, 1096, 13) : 0;
    final rctType = tr == rct ? reader.readU32(6, 0, 0, 2, 2, 4, 10, 6) : 0;
    var numC = 0, nbColors = 0, nbDeltas = 0, dPred = 0;
    if (tr == palette) {
      numC = reader.readU32(1, 0, 3, 0, 4, 0, 1, 13);
      nbColors = reader.readU32(0, 8, 256, 10, 1280, 12, 5376, 16);
      nbDeltas = reader.readU32(0, 0, 1, 8, 257, 10, 1281, 16);
      dPred = reader.readBits(4);
    }
    List<SqueezeParam>? sp;
    if (tr == squeeze) {
      final numSq = reader.readU32(0, 0, 1, 4, 9, 6, 41, 8);
      sp = List.generate(numSq, (_) => SqueezeParam.read(reader));
    }
    return TransformInfo._(
        tr, beginC, rctType, numC, nbColors, nbDeltas, dPred, sp);
  }

  TransformInfo._(this.tr, this.beginC, this.rctType, this.numC, this.nbColors,
      this.nbDeltas, this.dPred, this.sp);

  final int tr;
  final int beginC;
  final int rctType;
  final int numC;
  final int nbColors;
  final int nbDeltas;
  final int dPred;
  final List<SqueezeParam>? sp;
}
