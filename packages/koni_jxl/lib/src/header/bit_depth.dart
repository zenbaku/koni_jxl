import '../io/bit_reader.dart';

/// The `BitDepth` header bundle.
final class BitDepthHeader {
  const BitDepthHeader()
      : usesFloatSamples = false,
        bitsPerSample = 8,
        expBits = 0;

  factory BitDepthHeader.read(BitReader reader) {
    final usesFloatSamples = reader.readBool();
    if (usesFloatSamples) {
      final bits = reader.readU32(32, 0, 16, 0, 24, 0, 1, 6);
      final expBits = 1 + reader.readBits(4);
      return BitDepthHeader._(true, bits, expBits);
    }
    final bits = reader.readU32(8, 0, 10, 0, 12, 0, 1, 6);
    return BitDepthHeader._(false, bits, 0);
  }

  const BitDepthHeader._(
      this.usesFloatSamples, this.bitsPerSample, this.expBits);

  final bool usesFloatSamples;
  final int bitsPerSample;
  final int expBits;

  int get maxValue => (1 << bitsPerSample) - 1;

  @override
  String toString() => usesFloatSamples
      ? '$bitsPerSample-bit float (exp $expBits)'
      : '$bitsPerSample-bit';
}
