import 'dart:convert';

import '../header/extensions.dart';
import '../header/image_header.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';
import 'blending_info.dart';
import 'frame_flags.dart';
import 'passes_info.dart';
import 'restoration_filter.dart';

/// The frame header bundle, including the resolved frame bounds.
final class FrameHeader {
  factory FrameHeader.read(BitReader reader, ImageHeader parent) {
    final h = FrameHeader._();
    final allDefault = reader.readBool();
    h.type = allDefault ? FrameFlags.regularFrame : reader.readBits(2);
    h.encoding = allDefault ? FrameFlags.vardct : reader.readBits(1);
    h.flags = allDefault ? 0 : reader.readU64();
    h.doYCbCr = !allDefault && !parent.xybEncoded && reader.readBool();
    if (h.doYCbCr && h.flags & FrameFlags.useLfFrame == 0) {
      for (var i = 0; i < 3; i++) {
        final mode = reader.readBits(2);
        switch (mode) {
          case 1:
            h.jpegUpsamplingY[i] = 1;
            h.jpegUpsamplingX[i] = 1;
          case 2:
            h.jpegUpsamplingY[i] = 0;
            h.jpegUpsamplingX[i] = 1;
          case 3:
            h.jpegUpsamplingY[i] = 1;
            h.jpegUpsamplingX[i] = 0;
        }
      }
    }
    h.ecUpsampling = List<int>.filled(parent.extraChannels.length, 1);
    if (!allDefault && h.flags & FrameFlags.useLfFrame == 0) {
      h.upsampling = 1 << reader.readBits(2);
      for (var i = 0; i < h.ecUpsampling.length; i++) {
        h.ecUpsampling[i] = 1 << reader.readBits(2);
      }
    } else {
      h.upsampling = 1;
    }
    h.groupSizeShift =
        h.encoding == FrameFlags.modular ? reader.readBits(2) : 1;
    h.groupDim = 128 << h.groupSizeShift;
    h.lfGroupDim = h.groupDim << 3;
    h.logGroupDim = ceilLog2(h.groupDim);
    h.logLfGroupDim = ceilLog2(h.lfGroupDim);
    if (parent.xybEncoded && h.encoding == FrameFlags.vardct) {
      h.xqmScale = allDefault ? 3 : reader.readBits(3);
      h.bqmScale = allDefault ? 2 : reader.readBits(3);
    } else {
      h.xqmScale = 2;
      h.bqmScale = 2;
    }
    h.passes = !allDefault && h.type != FrameFlags.referenceOnly
        ? PassesInfo.read(reader)
        : PassesInfo.defaults();
    h.lfLevel = h.type == FrameFlags.lfFrame ? 1 + reader.readBits(2) : 0;
    h.haveCrop =
        !allDefault && h.type != FrameFlags.lfFrame && reader.readBool();
    final imageWidth = parent.size.width;
    final imageHeight = parent.size.height;
    if (h.haveCrop && h.type != FrameFlags.referenceOnly) {
      final x0 = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      final y0 = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      h.x0 = unpackSigned(x0);
      h.y0 = unpackSigned(y0);
    }
    if (h.haveCrop) {
      h.width = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
      h.height = reader.readU32(0, 8, 256, 11, 2304, 14, 18688, 30);
    } else {
      h.width = imageWidth;
      h.height = imageHeight;
    }
    final normalFrame = !allDefault &&
        (h.type == FrameFlags.regularFrame ||
            h.type == FrameFlags.skipProgressive);
    // Computed before the upsampling/lfLevel divisions, intentionally.
    final fullFrame = h.y0 <= 0 &&
        h.x0 <= 0 &&
        h.height + h.y0 >= imageHeight &&
        h.width + h.x0 >= imageWidth;
    h.fullFrame = fullFrame;
    h.height = ceilDiv(h.height, h.upsampling);
    h.width = ceilDiv(h.width, h.upsampling);
    h.height = ceilDiv(h.height, 1 << (3 * h.lfLevel));
    h.width = ceilDiv(h.width, 1 << (3 * h.lfLevel));
    h.ecBlendingInfo = List<BlendingInfo>.filled(
        parent.extraChannels.length, const BlendingInfo.defaults());
    if (normalFrame) {
      h.blendingInfo = BlendingInfo.read(reader,
          extra: h.ecBlendingInfo.isNotEmpty, fullFrame: fullFrame);
      for (var i = 0; i < h.ecBlendingInfo.length; i++) {
        h.ecBlendingInfo[i] =
            BlendingInfo.read(reader, extra: true, fullFrame: fullFrame);
      }
    } else {
      h.blendingInfo = const BlendingInfo.defaults();
    }
    final animated = parent.animation != null;
    h.duration =
        normalFrame && animated ? reader.readU32(0, 0, 1, 0, 0, 8, 0, 32) : 0;
    h.timecode = normalFrame && animated && parent.animation!.haveTimecodes
        ? reader.readBits(32)
        : 0;
    h.isLast =
        normalFrame ? reader.readBool() : h.type == FrameFlags.regularFrame;
    h.saveAsReference = !allDefault && h.type != FrameFlags.lfFrame && !h.isLast
        ? reader.readBits(2)
        : 0;
    h.saveBeforeCT = !allDefault &&
        (h.type == FrameFlags.referenceOnly ||
            fullFrame &&
                (h.type == FrameFlags.regularFrame ||
                    h.type == FrameFlags.skipProgressive) &&
                (h.duration == 0 || h.saveAsReference != 0) &&
                !h.isLast &&
                h.blendingInfo.mode == FrameFlags.blendReplace) &&
        reader.readBool();
    if (allDefault) {
      h.name = '';
    } else {
      final nameLen = reader.readU32(0, 0, 0, 4, 16, 5, 48, 10);
      final buffer = List<int>.generate(nameLen, (_) => reader.readBits(8));
      h.name = utf8.decode(buffer, allowMalformed: true);
    }
    h.restorationFilter = allDefault
        ? RestorationFilter.defaults()
        : RestorationFilter.read(reader, h.encoding);
    h.extensions = allDefault ? const Extensions() : Extensions.read(reader);
    var maxJPY = 0;
    var maxJPX = 0;
    for (var i = 0; i < 3; i++) {
      if (h.jpegUpsamplingY[i] > maxJPY) maxJPY = h.jpegUpsamplingY[i];
      if (h.jpegUpsamplingX[i] > maxJPX) maxJPX = h.jpegUpsamplingX[i];
    }
    h.isSubsampled = maxJPX > 0 || maxJPY > 0;
    h.height = ceilDiv(h.height, 1 << maxJPY) << maxJPY;
    h.width = ceilDiv(h.width, 1 << maxJPX) << maxJPX;
    for (var i = 0; i < 3; i++) {
      h.jpegUpsamplingY[i] = maxJPY - h.jpegUpsamplingY[i];
      h.jpegUpsamplingX[i] = maxJPX - h.jpegUpsamplingX[i];
    }
    return h;
  }

  FrameHeader._();

  int type = FrameFlags.regularFrame;
  int encoding = FrameFlags.vardct;
  int flags = 0;
  bool doYCbCr = false;
  final List<int> jpegUpsamplingY = [0, 0, 0];
  final List<int> jpegUpsamplingX = [0, 0, 0];
  int upsampling = 1;
  List<int> ecUpsampling = const [];
  int groupSizeShift = 1;
  int groupDim = 256;
  int lfGroupDim = 2048;
  int logGroupDim = 8;
  int logLfGroupDim = 11;
  int xqmScale = 2;
  int bqmScale = 2;
  PassesInfo passes = PassesInfo.defaults();
  int lfLevel = 0;
  bool haveCrop = false;

  /// Frame bounds: origin can be negative; width/height are the decoded
  /// frame size (after the upsampling/lfLevel adjustments).
  int x0 = 0;
  int y0 = 0;
  int width = 0;
  int height = 0;
  bool fullFrame = true;

  BlendingInfo blendingInfo = const BlendingInfo.defaults();
  List<BlendingInfo> ecBlendingInfo = const [];
  int duration = 0;
  int timecode = 0;
  bool isLast = true;
  int saveAsReference = 0;
  bool saveBeforeCT = false;
  String name = '';
  RestorationFilter restorationFilter = RestorationFilter.defaults();
  Extensions extensions = const Extensions();
  bool isSubsampled = false;
}
