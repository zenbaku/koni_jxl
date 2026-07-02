import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';

/// The (splitExponent, msbInToken, lsbInToken) configuration that expands an
/// entropy token into a full unsigned integer.
final class HybridIntegerConfig {
  const HybridIntegerConfig(
      this.splitExponent, this.msbInToken, this.lsbInToken);

  factory HybridIntegerConfig.read(BitReader reader, int logAlphabetSize) {
    final splitExponent = reader.readBits(ceilLog1p(logAlphabetSize));
    if (splitExponent == logAlphabetSize) {
      return HybridIntegerConfig(splitExponent, 0, 0);
    }
    final msbInToken = reader.readBits(ceilLog1p(splitExponent));
    if (msbInToken > splitExponent) {
      throw const JxlInvalidBitstreamException('msbInToken too large');
    }
    final lsbInToken = reader.readBits(ceilLog1p(splitExponent - msbInToken));
    if (msbInToken + lsbInToken > splitExponent) {
      throw const JxlInvalidBitstreamException(
          'msbInToken + lsbInToken too large');
    }
    return HybridIntegerConfig(splitExponent, msbInToken, lsbInToken);
  }

  final int splitExponent;
  final int msbInToken;
  final int lsbInToken;

  @override
  String toString() => '$splitExponent-$msbInToken-$lsbInToken';
}
