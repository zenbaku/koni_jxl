import '../io/bit_reader.dart';
import '../modular/modular_channel.dart';
import '../modular/modular_stream.dart';
import '../vardct/hf_metadata.dart';
import '../vardct/lf_coefficients.dart';
import 'frame.dart';
import 'frame_flags.dart';

/// One LF group: LF (DC) coefficients and HF metadata for VarDCT frames,
/// plus the modular sub-stream carrying squeezed global channels.
final class LfGroup {
  LfGroup(BitReader reader, Frame frame, this.lfGroupID,
      List<ModularChannel> replaced) {
    final size = frame.lfGroupSize(lfGroupID);
    blockHeight = size.height >> 3;
    blockWidth = size.width >> 3;
    final isVarDCT = frame.header.encoding == FrameFlags.vardct;
    lfCoeff = isVarDCT ? LfCoefficients(reader, this, frame) : null;
    modularLfGroup = ModularStream.read(reader, frame.modularContext,
        streamIndex: 1 + frame.numLfGroups + lfGroupID, channelArray: replaced);
    modularLfGroup.decodeChannels(reader);
    hfMetadata = isVarDCT ? HfMetadata(reader, this, frame) : null;
  }

  final int lfGroupID;

  /// LF group size in 8x8 blocks.
  late final int blockHeight;
  late final int blockWidth;

  LfCoefficients? lfCoeff;
  late final ModularStream modularLfGroup;
  HfMetadata? hfMetadata;
}
