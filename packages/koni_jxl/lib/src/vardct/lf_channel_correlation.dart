import '../io/bit_reader.dart';

/// Chroma-from-luma correlation parameters.
final class LfChannelCorrelation {
  const LfChannelCorrelation()
      : colorFactor = 84,
        baseCorrelationX = 0.0,
        baseCorrelationB = 1.0,
        xFactorLF = 128,
        bFactorLF = 128;

  factory LfChannelCorrelation.read(BitReader reader) {
    if (reader.readBool()) return const LfChannelCorrelation();
    final colorFactor = reader.readU32(84, 0, 256, 0, 2, 8, 258, 16);
    final baseCorrelationX = reader.readF16();
    final baseCorrelationB = reader.readF16();
    final xFactorLF = reader.readBits(8);
    final bFactorLF = reader.readBits(8);
    return LfChannelCorrelation._(
        colorFactor, baseCorrelationX, baseCorrelationB, xFactorLF, bFactorLF);
  }

  const LfChannelCorrelation._(this.colorFactor, this.baseCorrelationX,
      this.baseCorrelationB, this.xFactorLF, this.bFactorLF);

  final int colorFactor;
  final double baseCorrelationX;
  final double baseCorrelationB;
  final int xFactorLF;
  final int bFactorLF;
}
