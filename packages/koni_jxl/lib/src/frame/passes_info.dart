import '../exceptions.dart';
import '../io/bit_reader.dart';

/// The `Passes` bundle from the frame header.
final class PassesInfo {
  PassesInfo.defaults()
      : numPasses = 1,
        numDS = 0,
        shift = const [0],
        downSample = const [1],
        lastPass = const [0];

  factory PassesInfo.read(BitReader reader) {
    final numPasses = reader.readU32(1, 0, 2, 0, 3, 0, 4, 3);
    final numDS = numPasses != 1 ? reader.readU32(0, 0, 1, 0, 2, 0, 3, 1) : 0;
    if (numDS >= numPasses) {
      throw const JxlInvalidBitstreamException('num_ds < num_passes violated');
    }
    final shift = List<int>.filled(numPasses, 0);
    for (var i = 0; i < numPasses - 1; i++) {
      shift[i] = reader.readBits(2);
    }
    final downSample = List<int>.filled(numDS + 1, 1);
    for (var i = 0; i < numDS; i++) {
      downSample[i] = 1 << reader.readBits(2);
    }
    final lastPass = List<int>.filled(numDS + 1, numPasses - 1);
    for (var i = 0; i < numDS; i++) {
      lastPass[i] = reader.readU32(0, 0, 1, 0, 2, 0, 0, 3);
    }
    return PassesInfo._(numPasses, numDS, shift, downSample, lastPass);
  }

  PassesInfo._(
      this.numPasses, this.numDS, this.shift, this.downSample, this.lastPass);

  final int numPasses;
  final int numDS;
  final List<int> shift;
  final List<int> downSample;
  final List<int> lastPass;
}
