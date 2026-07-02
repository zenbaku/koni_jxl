import '../io/bit_reader.dart';

/// The `AnimationHeader` bundle. Parsed for bitstream correctness; animated
/// frames themselves are not decoded in v1.
final class AnimationHeader {
  factory AnimationHeader.read(BitReader reader) {
    final tpsNumerator = reader.readU32(100, 0, 1000, 0, 1, 10, 1, 30);
    final tpsDenominator = reader.readU32(1, 0, 1001, 0, 1, 8, 1, 10);
    final numLoops = reader.readU32(0, 0, 0, 3, 0, 16, 0, 32);
    final haveTimecodes = reader.readBool();
    return AnimationHeader._(
        tpsNumerator, tpsDenominator, numLoops, haveTimecodes);
  }

  const AnimationHeader._(this.tpsNumerator, this.tpsDenominator, this.numLoops,
      this.haveTimecodes);

  final int tpsNumerator;
  final int tpsDenominator;
  final int numLoops;
  final bool haveTimecodes;
}
