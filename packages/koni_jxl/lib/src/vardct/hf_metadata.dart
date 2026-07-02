import 'dart:typed_data';

import '../exceptions.dart';
import '../frame/frame.dart';
import '../frame/lf_group.dart';
import '../io/bit_reader.dart';
import '../modular/modular_channel.dart';
import '../modular/modular_stream.dart';
import '../util/math_helper.dart';
import 'transform_type.dart';

/// Per-LF-group HF metadata: the varblock map (transform types + positions),
/// per-block quant multipliers, CfL factors and EPF sharpness.
final class HfMetadata {
  HfMetadata(BitReader reader, LfGroup parent, Frame frame) {
    final bh = parent.blockHeight;
    final bw = parent.blockWidth;
    final n = ceilLog2(bh * bw);
    nbBlocks = 1 + reader.readBits(n);
    final correlationHeight = (bh + 7) ~/ 8;
    final correlationWidth = (bw + 7) ~/ 8;
    final xFromY = ModularChannel(correlationHeight, correlationWidth, 0, 0);
    final bFromY = ModularChannel(correlationHeight, correlationWidth, 0, 0);
    final blockInfo = ModularChannel(2, nbBlocks, 0, 0);
    final sharpness = ModularChannel(bh, bw, 0, 0);
    final hfStream = ModularStream.read(reader, frame.modularContext,
        streamIndex: 1 + 2 * frame.numLfGroups + parent.lfGroupID,
        channelArray: [xFromY, bFromY, blockInfo, sharpness]);
    hfStream.decodeChannels(reader);
    hfStreamChannels = [for (var i = 0; i < 4; i++) hfStream.getChannel(i)];

    blockWidth = bw;
    _dctSelectIdx = Int32List(bh * bw)..fillRange(0, bh * bw, -1);
    hfMultiplier = Int32List(bh * bw);
    blockY = Int32List(nbBlocks);
    blockX = Int32List(nbBlocks);
    final blockInfoBuf = hfStreamChannels[2].buffer!;
    var lastY = 0;
    var lastX = 0;
    for (var i = 0; i < nbBlocks; i++) {
      final type = blockInfoBuf[i]; // row 0: type
      if (type > 26 || type < 0) {
        throw JxlInvalidBitstreamException('invalid transform type: $type');
      }
      final tt = TransformType.values[type];
      final mul = 1 + blockInfoBuf[nbBlocks + i]; // row 1: multiplier - 1
      final pos = _placeBlock(bh, bw, lastY, lastX, tt, mul);
      lastY = pos >> 20;
      lastX = pos & 0xFFFFF;
      blockY[i] = lastY;
      blockX[i] = lastX;
    }
  }

  late final int nbBlocks;
  late final int blockWidth;
  late final Int32List _dctSelectIdx;
  late final Int32List hfMultiplier;

  /// 4 channels: xFromY, bFromY, blockInfo (2 x nbBlocks), sharpness.
  late final List<ModularChannel> hfStreamChannels;
  late final Int32List blockY;
  late final Int32List blockX;

  TransformType? dctSelectAt(int y, int x) {
    final idx = _dctSelectIdx[y * blockWidth + x];
    return idx < 0 ? null : TransformType.values[idx];
  }

  int hfMultiplierAt(int y, int x) => hfMultiplier[y * blockWidth + x];

  int sharpnessAt(int y, int x) =>
      hfStreamChannels[3].buffer![y * blockWidth + x];

  /// Places [block] at the first free position at/after (lastY, lastX) in
  /// raster order; returns (y << 20) | x.
  int _placeBlock(
      int bh, int bw, int lastY, int lastX, TransformType block, int mul) {
    var x = lastX;
    for (var y = lastY; y < bh; y++, x = 0) {
      final rowBase = y * bw;
      outerX:
      for (; x < bw; x++) {
        if (block.dctSelectWidth + x > bw) break; // next row
        // Check the space is free.
        for (var ix = 0; ix < block.dctSelectWidth; ix++) {
          final idx = _dctSelectIdx[rowBase + x + ix];
          if (idx >= 0) {
            x += TransformType.values[idx].dctSelectWidth - 1;
            continue outerX;
          }
        }
        if (block.dctSelectHeight + y > bh) {
          throw const JxlInvalidBitstreamException(
              'block does not fit vertically');
        }
        for (var iy = 0; iy < block.dctSelectHeight; iy++) {
          final base = (y + iy) * bw + x;
          _dctSelectIdx.fillRange(
              base, base + block.dctSelectWidth, block.type);
          hfMultiplier.fillRange(base, base + block.dctSelectWidth, mul);
        }
        return (y << 20) | x;
      }
    }
    throw const JxlInvalidBitstreamException('could not place block');
  }
}
