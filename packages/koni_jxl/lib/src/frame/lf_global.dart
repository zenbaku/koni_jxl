import '../color/color_encoding.dart';
import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../modular/ma_tree.dart';
import '../modular/modular_stream.dart';
import '../vardct/hf_block_context.dart';
import '../vardct/lf_channel_correlation.dart';
import 'frame.dart';
import 'frame_flags.dart';
import 'patches.dart';

/// The LfGlobal frame section: frame-wide features and the global modular
/// stream. (VarDCT-specific parts land with M5.)
final class LfGlobal {
  factory LfGlobal.read(BitReader reader, Frame frame) {
    final lf = LfGlobal._();
    final header = frame.header;
    final metadata = frame.globalMetadata;
    if (header.flags & FrameFlags.patches != 0) {
      final stream = EntropyStream.read(reader, 10);
      final numPatches = stream.readSymbol(reader, 0);
      for (var i = 0; i < numPatches; i++) {
        lf.patches.add(Patch.read(stream, reader, metadata.extraChannels.length,
            metadata.alphaIndices.length));
      }
      if (!stream.validateFinalState()) {
        throw const JxlInvalidBitstreamException('illegal patch entropy state');
      }
    }
    if (header.flags & FrameFlags.splines != 0) {
      throw JxlUnsupportedException('splines');
    }
    if (header.flags & FrameFlags.noise != 0) {
      throw JxlUnsupportedException('noise');
    }
    if (!reader.readBool()) {
      for (var i = 0; i < 3; i++) {
        lf.lfDequant[i] = reader.readF16() * (1 / 128);
      }
    }
    if (header.encoding == FrameFlags.vardct) {
      lf.globalScale = reader.readU32(1, 11, 2049, 11, 4097, 12, 8193, 16);
      lf.quantLF = reader.readU32(16, 0, 1, 5, 1, 8, 1, 16);
      for (var i = 0; i < 3; i++) {
        lf.scaledDequant[i] =
            (1 << 16) * lf.lfDequant[i] / (lf.globalScale * lf.quantLF);
      }
      lf.hfBlockCtx = HfBlockContext.read(reader);
      lf.lfChanCorr = LfChannelCorrelation.read(reader);
    }

    final hasGlobalTree = reader.readBool();
    frame.globalTree = hasGlobalTree ? MaTree.read(reader) : null;

    var ecStart = 0;
    if (header.encoding == FrameFlags.modular) {
      if (!header.doYCbCr &&
          !metadata.xybEncoded &&
          metadata.colorEncoding.colorEncoding == ColorFlags.ceGray) {
        ecStart = 1;
      } else {
        ecStart = 3;
      }
    }
    final subModularChannelCount = metadata.extraChannels.length + ecStart;
    lf.globalModular = ModularStream.read(reader, frame.modularContext,
        streamIndex: 0, channelCount: subModularChannelCount, ecStart: ecStart);
    lf.globalModular.decodeChannels(reader, partial: true);
    return lf;
  }

  LfGlobal._();

  final List<Patch> patches = [];
  final List<double> lfDequant = [1 / 4096, 1 / 512, 1 / 256];
  int globalScale = 0;
  int quantLF = 0;
  final List<double> scaledDequant = [0, 0, 0];
  HfBlockContext? hfBlockCtx;
  LfChannelCorrelation lfChanCorr = const LfChannelCorrelation();
  late ModularStream globalModular;
}
