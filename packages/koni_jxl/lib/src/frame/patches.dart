import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';
import 'blending_info.dart';

/// One patch: a rectangle of a reference frame blended at one or more
/// positions in the current frame.
final class Patch {
  static Patch read(EntropyStream stream, BitReader reader,
      int extraChannelCount, int alphaChannelCount) {
    final ref = stream.readSymbol(reader, 1);
    final x = stream.readSymbol(reader, 3);
    final y = stream.readSymbol(reader, 3);
    final width = 1 + stream.readSymbol(reader, 2);
    final height = 1 + stream.readSymbol(reader, 2);
    final count = 1 + stream.readSymbol(reader, 7);
    if (count <= 0) {
      throw const JxlInvalidBitstreamException('bad patch count');
    }
    final positionsX = List<int>.filled(count, 0);
    final positionsY = List<int>.filled(count, 0);
    final blendingInfos = <List<BlendingInfo>>[];
    for (var j = 0; j < count; j++) {
      if (j == 0) {
        positionsX[j] = stream.readSymbol(reader, 4);
        positionsY[j] = stream.readSymbol(reader, 4);
      } else {
        positionsX[j] =
            unpackSigned(stream.readSymbol(reader, 6)) + positionsX[j - 1];
        positionsY[j] =
            unpackSigned(stream.readSymbol(reader, 6)) + positionsY[j - 1];
      }
      final infos = <BlendingInfo>[];
      for (var k = 0; k < extraChannelCount + 1; k++) {
        final mode = stream.readSymbol(reader, 5);
        var alpha = 0;
        var clamp = false;
        if (mode >= 8) {
          throw const JxlInvalidBitstreamException(
              'illegal blending mode in patch');
        }
        if (mode > 3 && alphaChannelCount > 1) {
          alpha = stream.readSymbol(reader, 8);
          if (alpha >= extraChannelCount) {
            throw const JxlInvalidBitstreamException(
                'patch alpha out of bounds');
          }
        }
        if (mode > 2) {
          clamp = stream.readSymbol(reader, 9) != 0;
        }
        infos.add(BlendingInfo.raw(mode, alpha, clamp, 0));
      }
      blendingInfos.add(infos);
    }
    return Patch._(
        ref, x, y, width, height, positionsX, positionsY, blendingInfos);
  }

  Patch._(this.ref, this.x, this.y, this.width, this.height, this.positionsX,
      this.positionsY, this.blendingInfos);

  final int ref;

  /// Source rectangle within the reference frame.
  final int x, y, width, height;

  /// Target positions in the current frame.
  final List<int> positionsX;
  final List<int> positionsY;

  /// Per-position, per-(color-group + extra channel) blending modes. Note
  /// these use the *patch* mode numbering (0=none, 1=replace, 2=add, 3=mul,
  /// 4=blend above, 5=blend below, 6=muladd above, 7=muladd below).
  final List<List<BlendingInfo>> blendingInfos;
}
