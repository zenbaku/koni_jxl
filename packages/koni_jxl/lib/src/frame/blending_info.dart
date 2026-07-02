import '../io/bit_reader.dart';
import 'frame_flags.dart';

/// Per-channel blending parameters from the frame header.
final class BlendingInfo {
  const BlendingInfo.defaults()
      : mode = FrameFlags.blendReplace,
        alphaChannel = 0,
        clamp = false,
        source = 0;

  factory BlendingInfo.read(BitReader reader,
      {required bool extra, required bool fullFrame}) {
    final mode = reader.readU32(0, 0, 1, 0, 2, 0, 3, 2);
    final alphaChannel = extra &&
            (mode == FrameFlags.blendBlend || mode == FrameFlags.blendMulAdd)
        ? reader.readU32(0, 0, 1, 0, 2, 0, 3, 3)
        : 0;
    final clamp = extra &&
        (mode == FrameFlags.blendBlend ||
            mode == FrameFlags.blendMult ||
            mode == FrameFlags.blendMulAdd) &&
        reader.readBool();
    final source =
        mode != FrameFlags.blendReplace || !fullFrame ? reader.readBits(2) : 0;
    return BlendingInfo._(mode, alphaChannel, clamp, source);
  }

  const BlendingInfo._(this.mode, this.alphaChannel, this.clamp, this.source);

  /// Direct construction (used by patches).
  const BlendingInfo.raw(this.mode, this.alphaChannel, this.clamp, this.source);

  final int mode;
  final int alphaChannel;
  final bool clamp;
  final int source;
}
