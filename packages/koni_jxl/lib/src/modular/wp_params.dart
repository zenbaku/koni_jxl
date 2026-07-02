import '../io/bit_reader.dart';

/// Self-correcting (weighted) predictor parameters, from the modular stream
/// header.
final class WpParams {
  factory WpParams.read(BitReader reader) {
    if (reader.readBool()) {
      return const WpParams._(16, 10, 7, 7, 7, 0, 0, [13, 12, 12, 12]);
    }
    final param1 = reader.readBits(5);
    final param2 = reader.readBits(5);
    final param3a = reader.readBits(5);
    final param3b = reader.readBits(5);
    final param3c = reader.readBits(5);
    final param3d = reader.readBits(5);
    final param3e = reader.readBits(5);
    final weight = List<int>.generate(4, (_) => reader.readBits(4));
    return WpParams._(
        param1, param2, param3a, param3b, param3c, param3d, param3e, weight);
  }

  const WpParams._(this.param1, this.param2, this.param3a, this.param3b,
      this.param3c, this.param3d, this.param3e, this.weight);

  final int param1;
  final int param2;
  final int param3a, param3b, param3c, param3d, param3e;
  final List<int> weight;
}
