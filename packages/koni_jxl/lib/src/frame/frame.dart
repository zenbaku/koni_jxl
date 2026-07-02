import '../exceptions.dart';
import '../header/image_header.dart';
import '../io/bit_reader.dart';
import '../modular/ma_tree.dart';
import '../modular/modular_channel.dart';
import '../modular/modular_stream.dart';
import '../render/filters.dart';
import '../util/image_buffer.dart';
import '../util/math_helper.dart';
import '../vardct/hf_coefficients.dart';
import '../vardct/hf_global.dart';
import '../vardct/hf_pass.dart';
import '../vardct/vardct_inverter.dart';
import 'frame_flags.dart';
import 'frame_header.dart';
import 'lf_global.dart';
import 'lf_group.dart';
import 'passes_info.dart';
import 'toc.dart';

/// XYB channel remap: X, Y, B are stored as Y, X, (B - Y) in modular and
/// decode order Y, X, B in VarDCT.
const cMap = [1, 0, 2];

/// Per-pass metadata: which not-yet-decoded global modular channels this
/// pass carries, plus the VarDCT HFPass data.
final class Pass {
  Pass(BitReader reader, Frame frame, int passIndex, int prevMinShift)
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
    hfPass = frame.header.encoding == FrameFlags.vardct
        ? HfPass(reader, frame, passIndex)
        : null;
  }

  final int maxShift;
  late final int minShift;
  late final List<ModularChannel?> replacedChannels;
  HfPass? hfPass;
}

/// One frame of the codestream: header, TOC, and the decode orchestration
/// across LF groups, passes and pass groups (modular and VarDCT).
final class Frame {
  Frame(this.globalReader, this.globalMetadata);

  final BitReader globalReader;
  final ImageHeader globalMetadata;

  late FrameHeader header;
  late Toc toc;
  late LfGlobal lfGlobal;
  MaTree? globalTree;
  HfGlobal? hfGlobal;
  List<Pass> passes = [];
  List<LfGroup?> lfGroups = [];

  /// Frame bounds (mutable copies; upsampling adjusts them later).
  int boundsX0 = 0, boundsY0 = 0, boundsWidth = 0, boundsHeight = 0;

  int numGroups = 0, numLfGroups = 0;
  int groupRowStride = 0, lfGroupRowStride = 0;

  /// Per-channel frame output, sized to the padded frame size.
  late List<ImageBuffer> buffer;

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

  ({int y, int x}) getGroupLocation(int groupID) =>
      (y: groupID ~/ groupRowStride, x: groupID % groupRowStride);

  ({int y, int x}) getLFGroupLocation(int lfGroupID) =>
      (y: lfGroupID ~/ lfGroupRowStride, x: lfGroupID % lfGroupRowStride);

  /// Position of this group within its LF group, in group units.
  ({int y, int x}) groupPosInLFGroup(int lfGroupID, int groupID) {
    final gr = getGroupLocation(groupID);
    final lf = getLFGroupLocation(lfGroupID);
    return (y: gr.y - (lf.y << 3), x: gr.x - (lf.x << 3));
  }

  LfGroup getLFGroupForGroup(int groupID) {
    final pos = getGroupLocation(groupID);
    return lfGroups[(pos.y >> 3) * lfGroupRowStride + (pos.x >> 3)]!;
  }

  ({int height, int width}) groupSize(int groupID) {
    final pos = getGroupLocation(groupID);
    final padded = paddedFrameSize;
    final height = header.groupDim < padded.height - pos.y * header.groupDim
        ? header.groupDim
        : padded.height - pos.y * header.groupDim;
    final width = header.groupDim < padded.width - pos.x * header.groupDim
        ? header.groupDim
        : padded.width - pos.x * header.groupDim;
    return (height: height, width: width);
  }

  ({int height, int width}) lfGroupSize(int lfGroupID) {
    final pos = getLFGroupLocation(lfGroupID);
    final padded = paddedFrameSize;
    final height = header.lfGroupDim < padded.height - pos.y * header.lfGroupDim
        ? header.lfGroupDim
        : padded.height - pos.y * header.lfGroupDim;
    final width = header.lfGroupDim < padded.width - pos.x * header.lfGroupDim
        ? header.lfGroupDim
        : padded.width - pos.x * header.lfGroupDim;
    return (height: height, width: width);
  }

  /// The LF frame's channel buffers when this frame uses one
  /// (`FrameFlags.useLfFrame`).
  List<ImageBuffer>? lfFrame;

  void decodeFrame({List<ImageBuffer>? lfFrame}) {
    this.lfFrame = lfFrame;
    if (globalMetadata.bitDepth.usesFloatSamples) {
      throw JxlUnsupportedException('float-samples');
    }
    for (final ec in globalMetadata.extraChannels) {
      if (ec.bitDepth.usesFloatSamples) {
        throw JxlUnsupportedException('float-samples');
      }
    }

    const timings = bool.fromEnvironment('jxl.timings');
    final sw = timings ? (Stopwatch()..start()) : null;
    void mark(String label) {
      if (sw != null) {
        // ignore: avoid_print
        print('  $label: ${sw.elapsedMilliseconds} ms');
        sw.reset();
      }
    }

    final isVarDCT = header.encoding == FrameFlags.vardct;
    lfGlobal = LfGlobal.read(toc.sectionReader(0), this);
    mark('lfGlobal');
    final padded = paddedFrameSize;
    final colors = colorChannelCount;
    final channelCount = colors + globalMetadata.extraChannels.length;
    buffer = [
      for (var c = 0; c < channelCount; c++)
        c < colors && (globalMetadata.xybEncoded || isVarDCT)
            ? ImageBuffer.float32(
                c < 3
                    ? padded.height >> header.jpegUpsamplingY[c]
                    : padded.height,
                c < 3
                    ? padded.width >> header.jpegUpsamplingX[c]
                    : padded.width)
            : ImageBuffer.int32(padded.height, padded.width),
    ];

    _decodeLfGroups();
    mark('lfGroups');

    final hfGlobalReader = toc.sectionReader(1 + numLfGroups);
    if (isVarDCT) {
      hfGlobal = HfGlobal(hfGlobalReader, this);
    }
    passes = [];
    for (var i = 0; i < header.passes.numPasses; i++) {
      passes.add(
          Pass(hfGlobalReader, this, i, i > 0 ? passes[i - 1].minShift : 0));
    }

    mark('hfGlobal+passes');
    _decodePassGroups();
    mark('passGroups');

    lfGlobal.globalModular.applyTransforms();
    _copyOutModular();
    mark('transforms+copyOut');

    _invertSubsampling();
    if (header.restorationFilter.gab) {
      performGabConvolution(this, colors);
      mark('gaborish');
    }
    if (header.restorationFilter.epfIterations > 0) {
      performEdgePreservingFilter(this, colors);
      mark('epf');
    }
  }

  /// Inverts JPEG-style chroma subsampling by repeatedly doubling the
  /// subsampled color planes with a [0.25, 0.75] filter.
  ///
  /// Neighbor taps mirror at the *visible* subsampled extent, matching
  /// libjxl's render pipeline: the padded DCT rows/columns beyond
  /// ceil(visible / 2) are never read. (jxlatte reads the padded samples
  /// instead, which shifts the final visible row on 4:2:0 images whose
  /// height is not a block multiple.)
  void _invertSubsampling() {
    for (var c = 0; c < 3; c++) {
      var xShift = header.jpegUpsamplingX[c];
      while (xShift-- > 0) {
        final visIn = ceilDiv(boundsWidth, 1 << (xShift + 1));
        final old = buffer[c]
          ..castToFloat(globalMetadata.bitDepth.bitsPerSample);
        final oldRows = old.floatRows;
        final newBuffer = ImageBuffer.float32(old.height, old.width * 2);
        final newRows = newBuffer.floatRows;
        for (var y = 0; y < old.height; y++) {
          final oldRow = oldRows[y];
          final newRow = newRows[y];
          for (var x = 0; x < oldRow.length; x++) {
            final b75 = 0.75 * oldRow[x];
            newRow[2 * x] = b75 + 0.25 * oldRow[x == 0 ? 0 : x - 1];
            newRow[2 * x + 1] =
                b75 + 0.25 * oldRow[x + 1 >= visIn ? visIn - 1 : x + 1];
          }
        }
        buffer[c] = newBuffer;
      }
      var yShift = header.jpegUpsamplingY[c];
      while (yShift-- > 0) {
        final visIn = ceilDiv(boundsHeight, 1 << (yShift + 1));
        final old = buffer[c]
          ..castToFloat(globalMetadata.bitDepth.bitsPerSample);
        final oldRows = old.floatRows;
        final newBuffer = ImageBuffer.float32(old.height * 2, old.width);
        final newRows = newBuffer.floatRows;
        for (var y = 0; y < old.height; y++) {
          final oldRow = oldRows[y];
          final prevRow = oldRows[y == 0 ? 0 : y - 1];
          final nextRow = oldRows[y + 1 >= visIn ? visIn - 1 : y + 1];
          final first = newRows[2 * y];
          final second = newRows[2 * y + 1];
          for (var x = 0; x < oldRow.length; x++) {
            final b75 = 0.75 * oldRow[x];
            first[x] = b75 + 0.25 * prevRow[x];
            second[x] = b75 + 0.25 * nextRow[x];
          }
        }
        buffer[c] = newBuffer;
      }
    }
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

    lfGroups = List<LfGroup?>.filled(numLfGroups, null);
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
      lfGroups[lfGroupID] = LfGroup(reader, this, lfGroupID, replaced);
    }

    for (var lfGroupID = 0; lfGroupID < numLfGroups; lfGroupID++) {
      for (var j = 0; j < replacementIndices.length; j++) {
        final channel = globalModular.getChannel(replacementIndices[j]);
        channel.allocate();
        final newChannel = lfGroups[lfGroupID]!.modularLfGroup.getChannel(j);
        _copyChannelRegion(newChannel, channel);
      }
    }
  }

  void _decodePassGroups() {
    final numPasses = passes.length;
    final isVarDCT = header.encoding == FrameFlags.vardct;
    final passGroups = List<List<ModularStream>>.generate(numPasses, (_) => []);
    final hfGroups = List<List<HfCoefficients?>>.generate(
        numPasses, (_) => List<HfCoefficients?>.filled(numGroups, null));

    for (var pass = 0; pass < numPasses; pass++) {
      for (var group = 0; group < numGroups; group++) {
        final reader =
            toc.sectionReader(2 + numLfGroups + pass * numGroups + group);
        if (isVarDCT) {
          hfGroups[pass][group] = HfCoefficients(reader, this, pass, group);
        }
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

    const timings = bool.fromEnvironment('jxl.timings');
    final sw2 = timings ? (Stopwatch()..start()) : null;
    if (isVarDCT) {
      final fb0 = buffer[0].floatRows;
      final fb1 = buffer[1].floatRows;
      final fb2 = buffer[2].floatRows;
      final simdOk = fb0[0].length & 3 == 0 &&
          fb1[0].length & 3 == 0 &&
          fb2[0].length & 3 == 0;
      final fbV0 = simdOk ? rowVectorViews(fb0) : null;
      final fbV1 = simdOk ? rowVectorViews(fb1) : null;
      final fbV2 = simdOk ? rowVectorViews(fb2) : null;
      final s0 = floatMatrix(256, 256);
      final s1 = floatMatrix(256, 256);
      final s2 = floatMatrix(256, 256);
      final s3 = floatMatrix(256, 256);
      final s4 = floatMatrix(256, 256);
      for (var pass = 0; pass < numPasses; pass++) {
        for (var group = 0; group < numGroups; group++) {
          invertVarDCTGroup(
              hfGroups[pass][group]!,
              pass > 0 ? hfGroups[pass - 1][group] : null,
              fb0,
              fb1,
              fb2,
              s0,
              s1,
              s2,
              s3,
              s4,
              fbV0,
              fbV1,
              fbV2);
        }
      }
      if (sw2 != null) {
        // ignore: avoid_print
        print('  vardct inversion: ${sw2.elapsedMilliseconds} ms');
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
    final colors = colorChannelCount;
    for (var c = 0; c < channels.length; c++) {
      final isModularColor =
          header.encoding == FrameFlags.modular && c < colors;
      final isModularXYB = globalMetadata.xybEncoded && isModularColor;
      // X, Y, B is encoded as Y, X, (B - Y).
      final cOut =
          (isModularXYB ? cMap[c] : c) + buffer.length - channels.length;
      final src = channels[c].buffer!;
      final srcWidth = channels[c].width;
      if (isModularXYB && c == 2) {
        final out = buffer[cOut].floatRows;
        final scaleFactor = lfGlobal.lfDequant[cOut];
        final srcY = channels[0].buffer!;
        for (var y = 0; y < boundsHeight; y++) {
          final row = out[y];
          for (var x = 0; x < boundsWidth; x++) {
            row[x] =
                scaleFactor * (srcY[y * srcWidth + x] + src[y * srcWidth + x]);
          }
        }
      } else if (buffer[cOut].isFloat) {
        final out = buffer[cOut].floatRows;
        final scaleFactor = isModularXYB ? lfGlobal.lfDequant[cOut] : 1.0;
        for (var y = 0; y < boundsHeight; y++) {
          final row = out[y];
          for (var x = 0; x < boundsWidth; x++) {
            row[x] = scaleFactor * src[y * srcWidth + x];
          }
        }
      } else {
        final out = buffer[cOut].intRows;
        for (var y = 0; y < boundsHeight; y++) {
          out[y].setRange(0, boundsWidth, src, y * srcWidth);
        }
      }
    }
  }
}
