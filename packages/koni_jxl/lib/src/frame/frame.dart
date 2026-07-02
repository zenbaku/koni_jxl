import '../exceptions.dart';
import '../header/image_header.dart';
import '../io/bit_reader.dart';
import '../modular/ma_tree.dart';
import '../modular/modular_channel.dart';
import '../modular/modular_stream.dart';
import '../util/image_buffer.dart';
import '../util/math_helper.dart';
import 'frame_flags.dart';
import 'frame_header.dart';
import 'lf_global.dart';
import 'passes_info.dart';
import 'toc.dart';

/// Per-pass modular metadata: which not-yet-decoded global channels this
/// pass carries (VarDCT HFPass data lands with M5).
final class Pass {
  Pass(Frame frame, int passIndex, int prevMinShift)
      : maxShift = passIndex > 0 ? prevMinShift : 3 {
    final PassesInfo passes = frame.header.passes;
    var n = -1;
    for (var i = 0; i < passes.lastPass.length; i++) {
      if (passes.lastPass[i] == passIndex) {
        n = i;
        break;
      }
    }
    minShift = n >= 0 ? ceilLog1p(passes.downSample[n] - 1) : maxShift;
    final stream = frame.lfGlobal.globalModular;
    replacedChannels =
        List<ModularChannel?>.filled(stream.encodedChannelCount, null);
    for (var i = 0; i < replacedChannels.length; i++) {
      final chan = stream.getChannel(i);
      if (!chan.decoded) {
        final m = chan.vshift < chan.hshift ? chan.vshift : chan.hshift;
        if (minShift <= m && m < maxShift) {
          replacedChannels[i] = ModularChannel.copy(chan);
        }
      }
    }
  }

  final int maxShift;
  late final int minShift;
  late final List<ModularChannel?> replacedChannels;
}

/// One frame of the codestream: header, TOC, and the decode orchestration
/// across LF groups, passes and pass groups (modular path; VarDCT is M5).
final class Frame {
  Frame(this.globalReader, this.globalMetadata);

  final BitReader globalReader;
  final ImageHeader globalMetadata;

  late FrameHeader header;
  late Toc toc;
  late LfGlobal lfGlobal;
  MaTree? globalTree;

  /// Frame bounds (mutable copies; upsampling adjusts them later).
  int boundsX0 = 0, boundsY0 = 0, boundsWidth = 0, boundsHeight = 0;

  int numGroups = 0, numLfGroups = 0;
  int groupRowStride = 0, lfGroupRowStride = 0;

  /// Per-channel frame output, sized to the padded frame size.
  late List<ImageBuffer> buffer;

  List<ModularStream?> _lfGroupStreams = [];

  FrameHeader readFrameHeader() {
    globalReader.zeroPadToByte();
    header = FrameHeader.read(globalReader, globalMetadata);
    boundsX0 = header.x0;
    boundsY0 = header.y0;
    boundsWidth = header.width;
    boundsHeight = header.height;
    groupRowStride = ceilDiv(boundsWidth, header.groupDim);
    lfGroupRowStride = ceilDiv(boundsWidth, header.groupDim << 3);
    numGroups = groupRowStride * ceilDiv(boundsHeight, header.groupDim);
    numLfGroups =
        lfGroupRowStride * ceilDiv(boundsHeight, header.groupDim << 3);
    return header;
  }

  void readToc() {
    final int tocEntries;
    if (numGroups == 1 && header.passes.numPasses == 1) {
      tocEntries = 1;
    } else {
      // lfGlobal + one per LF group + hfGlobal + one per pass per group.
      tocEntries = 1 + numLfGroups + 1 + numGroups * header.passes.numPasses;
    }
    toc = Toc.read(globalReader, tocEntries);
  }

  /// Number of color channels in the frame representation (not the output).
  int get colorChannelCount =>
      globalMetadata.xybEncoded || header.encoding == FrameFlags.vardct
          ? 3
          : globalMetadata.colorChannelCount;

  ({int width, int height}) get paddedFrameSize {
    var factorY = 0;
    var factorX = 0;
    for (var i = 0; i < 3; i++) {
      if (header.jpegUpsamplingY[i] > factorY) {
        factorY = header.jpegUpsamplingY[i];
      }
      if (header.jpegUpsamplingX[i] > factorX) {
        factorX = header.jpegUpsamplingX[i];
      }
    }
    var height = boundsHeight;
    var width = boundsWidth;
    if (header.encoding == FrameFlags.vardct) {
      height = (height + 7) >> 3;
      width = (width + 7) >> 3;
    }
    height = ceilDiv(height, 1 << factorY);
    width = ceilDiv(width, 1 << factorX);
    if (header.encoding == FrameFlags.vardct) {
      return (width: (width << factorX) << 3, height: (height << factorY) << 3);
    }
    return (width: width << factorX, height: height << factorY);
  }

  ModularFrameContext get modularContext => ModularFrameContext(
        frameWidth: boundsWidth,
        frameHeight: boundsHeight,
        groupDim: header.groupDim,
        globalTree: globalTree,
        ecDimShifts: [
          for (final ec in globalMetadata.extraChannels) ec.dimShift,
        ],
        bitDepth: globalMetadata.bitDepth.bitsPerSample,
      );

  bool get isVisible =>
      (header.type == FrameFlags.regularFrame ||
          header.type == FrameFlags.skipProgressive) &&
      (header.duration != 0 || header.isLast);

  void decodeFrame() {
    if (header.encoding == FrameFlags.vardct) {
      throw JxlUnsupportedException('vardct');
    }
    if (header.doYCbCr || header.isSubsampled) {
      throw JxlUnsupportedException('ycbcr');
    }
    if (globalMetadata.xybEncoded) {
      throw JxlUnsupportedException('modular-xyb');
    }
    if (globalMetadata.bitDepth.usesFloatSamples) {
      throw JxlUnsupportedException('float-samples');
    }
    for (final ec in globalMetadata.extraChannels) {
      if (ec.bitDepth.usesFloatSamples) {
        throw JxlUnsupportedException('float-samples');
      }
    }
    if (header.upsampling != 1 || header.ecUpsampling.any((u) => u != 1)) {
      throw JxlUnsupportedException('upsampling');
    }
    if (header.restorationFilter.gab) {
      throw JxlUnsupportedException('gaborish');
    }
    if (header.restorationFilter.epfIterations > 0) {
      throw JxlUnsupportedException('epf');
    }

    lfGlobal = LfGlobal.read(toc.sectionReader(0), this);
    final padded = paddedFrameSize;
    final colors = colorChannelCount;
    final channelCount = colors + globalMetadata.extraChannels.length;
    buffer = [
      for (var c = 0; c < channelCount; c++)
        ImageBuffer.int32(padded.height, padded.width),
    ];

    _decodeLfGroups();

    // The hfGlobal section (index 1 + numLfGroups) carries no bits for
    // modular frames; Pass metadata is derived without reading.
    final passes = <Pass>[];
    for (var i = 0; i < header.passes.numPasses; i++) {
      passes.add(Pass(this, i, i > 0 ? passes[i - 1].minShift : 0));
    }

    _decodePassGroups(passes);

    lfGlobal.globalModular.applyTransforms();
    _copyOutModular();
  }

  void _decodeLfGroups() {
    final globalModular = lfGlobal.globalModular;
    final replacementChannels = <ModularChannel>[];
    final replacementIndices = <int>[];
    for (var i = 0; i < globalModular.encodedChannelCount; i++) {
      final chan = globalModular.getChannel(i);
      if (!chan.decoded && chan.vshift >= 3 && chan.hshift >= 3) {
        replacementIndices.add(i);
        replacementChannels.add(ModularChannel.copy(chan));
      }
    }

    _lfGroupStreams = List<ModularStream?>.filled(numLfGroups, null);
    for (var lfGroupID = 0; lfGroupID < numLfGroups; lfGroupID++) {
      final reader = toc.sectionReader(1 + lfGroupID);
      final replaced = [
        for (final c in replacementChannels) ModularChannel.copy(c),
      ];
      for (final info in replaced) {
        final lfGroupHeight = header.lfGroupDim >> info.vshift;
        final lfGroupWidth = header.lfGroupDim >> info.hshift;
        final rowStride = ceilDiv(info.width, lfGroupWidth);
        info.originY = lfGroupID ~/ rowStride * lfGroupHeight;
        info.originX = lfGroupID % rowStride * lfGroupWidth;
        info.height = (info.height - info.originY).clamp(0, lfGroupHeight);
        info.width = (info.width - info.originX).clamp(0, lfGroupWidth);
      }
      final stream = ModularStream.read(reader, modularContext,
          streamIndex: 1 + numLfGroups + lfGroupID, channelArray: replaced);
      stream.decodeChannels(reader);
      _lfGroupStreams[lfGroupID] = stream;
    }

    for (var lfGroupID = 0; lfGroupID < numLfGroups; lfGroupID++) {
      for (var j = 0; j < replacementIndices.length; j++) {
        final channel = globalModular.getChannel(replacementIndices[j]);
        channel.allocate();
        final newChannel = _lfGroupStreams[lfGroupID]!.getChannel(j);
        _copyChannelRegion(newChannel, channel);
      }
    }
  }

  void _decodePassGroups(List<Pass> passes) {
    final numPasses = passes.length;
    final passGroups = List<List<ModularStream>>.generate(numPasses, (_) => []);

    for (var pass = 0; pass < numPasses; pass++) {
      for (var group = 0; group < numGroups; group++) {
        final reader =
            toc.sectionReader(2 + numLfGroups + pass * numGroups + group);
        final replaced = [
          for (final c in passes[pass].replacedChannels)
            if (c != null) ModularChannel.copy(c),
        ];
        for (final info in replaced) {
          final groupHeight = header.groupDim >> info.vshift;
          final groupWidth = header.groupDim >> info.hshift;
          final rowStride = ceilDiv(info.width, groupWidth);
          info.originY = group ~/ rowStride * groupHeight;
          info.originX = group % rowStride * groupWidth;
          info.height = (info.height - info.originY).clamp(0, groupHeight);
          info.width = (info.width - info.originX).clamp(0, groupWidth);
        }
        final stream = ModularStream.read(reader, modularContext,
            streamIndex: 18 + 3 * numLfGroups + numGroups * pass + group,
            channelArray: replaced);
        stream.decodeChannels(reader);
        passGroups[pass].add(stream);
      }
    }

    for (var pass = 0; pass < numPasses; pass++) {
      var j = 0;
      for (var i = 0; i < passes[pass].replacedChannels.length; i++) {
        if (passes[pass].replacedChannels[i] == null) continue;
        final channel = lfGlobal.globalModular.getChannel(i);
        channel.allocate();
        for (var group = 0; group < numGroups; group++) {
          final newChannel = passGroups[pass][group].getChannel(j);
          _copyChannelRegion(newChannel, channel);
        }
        j++;
      }
    }
  }

  static void _copyChannelRegion(ModularChannel src, ModularChannel dest) {
    final sb = src.buffer!;
    final db = dest.buffer!;
    for (var y = 0; y < src.height; y++) {
      final destStart = (y + src.originY) * dest.width + src.originX;
      db.setRange(destStart, destStart + src.width, sb, y * src.width);
    }
  }

  void _copyOutModular() {
    final channels = lfGlobal.globalModular.channels;
    for (var c = 0; c < channels.length; c++) {
      final cOut = c + buffer.length - channels.length;
      final out = buffer[cOut].intBuffer;
      final outWidth = buffer[cOut].width;
      final src = channels[c].buffer!;
      final srcWidth = channels[c].width;
      for (var y = 0; y < boundsHeight; y++) {
        out.setRange(
            y * outWidth, y * outWidth + boundsWidth, src, y * srcWidth);
      }
    }
  }
}
