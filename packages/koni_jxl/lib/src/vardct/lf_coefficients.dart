import 'dart:typed_data';

import '../exceptions.dart';
import '../frame/frame.dart';
import '../frame/frame_flags.dart';
import '../frame/frame_header.dart';
import '../frame/lf_group.dart';
import '../io/bit_reader.dart';
import '../modular/modular_channel.dart';
import '../modular/modular_stream.dart';
import '../util/image_buffer.dart';
import 'hf_block_context.dart';

/// Dequantized LF (DC) coefficients of one LF group, plus the per-block
/// LF context indices.
final class LfCoefficients {
  LfCoefficients(BitReader reader, LfGroup parent, Frame frame) {
    final header = frame.header;
    lfIndex = Int32List(parent.blockHeight * parent.blockWidth);
    final adaptiveSmoothing = header.flags &
            (FrameFlags.skipAdaptiveLfSmoothing | FrameFlags.useLfFrame) ==
        0;
    final subsampled = header.isSubsampled;
    if (adaptiveSmoothing && subsampled) {
      throw const JxlInvalidBitstreamException(
          'adaptive smoothing is incompatible with subsampling');
    }

    final info = List<ModularChannel?>.filled(3, null);
    var coeff = <List<Float32List>>[];
    for (var i = 0; i < 3; i++) {
      final sizeY = parent.blockHeight >> header.jpegUpsamplingY[i];
      final sizeX = parent.blockWidth >> header.jpegUpsamplingX[i];
      info[cMap[i]] = ModularChannel(
          sizeY, sizeX, header.jpegUpsamplingY[i], header.jpegUpsamplingX[i]);
      coeff.add(floatMatrix(sizeY, sizeX));
    }

    if (header.flags & FrameFlags.useLfFrame != 0) {
      // The dequantized LF is a direct copy of the LF frame's pixels at
      // this LF group's position; the LF context indices stay zero.
      final lfFrame = frame.lfFrame!;
      final pos = frame.getLFGroupLocation(parent.lfGroupID);
      final pY = pos.y << 8;
      final pX = pos.x << 8;
      for (var c = 0; c < 3; c++) {
        lfFrame[c].castToFloat(frame.globalMetadata.bitDepth.bitsPerSample);
        final b = lfFrame[c].floatRows;
        final co = coeff[c];
        for (var y = 0; y < co.length; y++) {
          co[y].setRange(0, co[y].length, b[pY + y], pX);
        }
      }
      dequantLFCoeff0 = List<Float32List>.of(coeff[0], growable: false);
      dequantLFCoeff1 = List<Float32List>.of(coeff[1], growable: false);
      dequantLFCoeff2 = List<Float32List>.of(coeff[2], growable: false);
      return;
    }

    final extraPrecision = reader.readBits(2);
    final lfQuantStream = ModularStream.read(reader, frame.modularContext,
        streamIndex: 1 + parent.lfGroupID,
        channelArray: info.cast<ModularChannel>());
    lfQuantStream.decodeChannels(reader);
    // lfQuant channels are in Y, X, B order.
    final lfQuant = [for (var i = 0; i < 3; i++) lfQuantStream.getChannel(i)];

    // JPEG reconstruction: capture the pre-dequant integer DC. JPEG component
    // `ch` is `lfQuant[ch]`; its block grid follows channel `cMap[ch]`'s
    // subsampling.
    final sink = frame.jpegSink;
    if (sink != null) {
      final lfLoc = frame.getLFGroupLocation(parent.lfGroupID);
      final lfBlkStride = header.lfGroupDim >> 3;
      for (var ch = 0; ch < 3; ch++) {
        final chan = lfQuant[ch];
        final offY =
            (lfLoc.y * lfBlkStride) >> header.jpegUpsamplingY[cMap[ch]];
        final offX =
            (lfLoc.x * lfBlkStride) >> header.jpegUpsamplingX[cMap[ch]];
        final buf = chan.buffer!;
        for (var y = 0; y < chan.height; y++) {
          final row = y * chan.width;
          for (var x = 0; x < chan.width; x++) {
            sink.setDc(ch, offY + y, offX + x, buf[row + x]);
          }
        }
      }
    }

    final scaledDequant = frame.lfGlobal.scaledDequant;
    for (var i = 0; i < 3; i++) {
      final c = cMap[i];
      final sd = scaledDequant[i] / (1 << extraPrecision);
      final chan = lfQuant[c];
      final q = chan.buffer!;
      for (var y = 0; y < chan.height; y++) {
        final dq = coeff[i][y];
        for (var x = 0; x < chan.width; x++) {
          dq[x] = q[y * chan.width + x] * sd;
        }
      }
    }

    // Chroma from luma.
    if (!subsampled) {
      final lfc = frame.lfGlobal.lfChanCorr;
      // SPEC: -128, not -127.
      final kX =
          lfc.baseCorrelationX + (lfc.xFactorLF - 128.0) / lfc.colorFactor;
      final kB =
          lfc.baseCorrelationB + (lfc.bFactorLF - 128.0) / lfc.colorFactor;
      final dqLFY = coeff[1];
      final dqLFX = coeff[0];
      final dqLFB = coeff[2];
      for (var y = 0; y < dqLFY.length; y++) {
        final yRow = dqLFY[y];
        final xRow = dqLFX[y];
        final bRow = dqLFB[y];
        for (var x = 0; x < yRow.length; x++) {
          xRow[x] += kX * yRow[x];
          bRow[x] += kB * yRow[x];
        }
      }
    }

    if (adaptiveSmoothing) {
      coeff = _adaptiveSmooth(coeff, scaledDequant);
    }
    dequantLFCoeff0 = List<Float32List>.of(coeff[0], growable: false);
    dequantLFCoeff1 = List<Float32List>.of(coeff[1], growable: false);
    dequantLFCoeff2 = List<Float32List>.of(coeff[2], growable: false);

    // Populate LF context indices.
    final hfctx = frame.lfGlobal.hfBlockCtx!;
    for (var y = 0; y < parent.blockHeight; y++) {
      for (var x = 0; x < parent.blockWidth; x++) {
        lfIndex[y * parent.blockWidth + x] =
            _getLFIndex(lfQuant, hfctx, header, y, x);
      }
    }
  }

  late final List<Float32List> dequantLFCoeff0;
  late final List<Float32List> dequantLFCoeff1;
  late final List<Float32List> dequantLFCoeff2;
  late final Int32List lfIndex;

  List<Float32List> dequantLFCoeffAt(int c) =>
      c == 0 ? dequantLFCoeff0 : (c == 1 ? dequantLFCoeff1 : dequantLFCoeff2);

  static List<List<Float32List>> _adaptiveSmooth(
      List<List<Float32List>> coeff, List<double> scaledDequant) {
    final weighted = List<List<Float32List?>>.generate(
        3, (i) => List<Float32List?>.filled(coeff[i].length, null));
    final gap = List<Float32List?>.filled(coeff[0].length, null);
    for (var i = 0; i < 3; i++) {
      final co = coeff[i];
      final sd = scaledDequant[i];
      for (var y = 1; y < co.length - 1; y++) {
        final coy = co[y];
        final coym = co[y - 1];
        final coyp = co[y + 1];
        final gy =
            gap[y] ??= Float32List(coy.length)..fillRange(0, coy.length, 0.5);
        final wy = weighted[i][y] = Float32List(coy.length);
        for (var x = 1; x < coy.length - 1; x++) {
          final sample = coy[x];
          final adjacent = coy[x - 1] + coy[x + 1] + coym[x] + coyp[x];
          final diag = coym[x - 1] + coym[x + 1] + coyp[x - 1] + coyp[x + 1];
          wy[x] = 0.05226273532324128 * sample +
              0.20345139757231578 * adjacent +
              0.0334829185968739 * diag;
          final g = (sample - wy[x]).abs() * sd;
          if (g > gy[x]) gy[x] = g;
        }
      }
    }
    for (var y = 0; y < gap.length; y++) {
      final gy = gap[y];
      if (gy == null) continue;
      for (var x = 0; x < gy.length; x++) {
        final v = 3.0 - 4.0 * gy[x];
        gy[x] = v < 0 ? 0 : v;
      }
    }
    final out = <List<Float32List>>[];
    for (var i = 0; i < 3; i++) {
      final co = coeff[i];
      final dqi = List<Float32List>.generate(
          co.length, (y) => Float32List(co[y].length),
          growable: false);
      for (var y = 0; y < co.length; y++) {
        final coy = co[y];
        final dqy = dqi[y];
        if (y == 0 || y + 1 == co.length) {
          dqy.setAll(0, coy);
          continue;
        }
        final gy = gap[y]!;
        final wiy = weighted[i][y]!;
        for (var x = 0; x < coy.length; x++) {
          if (x == 0 || x + 1 == coy.length) {
            dqy[x] = coy[x];
            continue;
          }
          dqy[x] = (coy[x] - wiy[x]) * gy[x] + wiy[x];
        }
      }
      out.add(dqi);
    }
    return out;
  }

  static int _getLFIndex(List<ModularChannel> lfQuant, HfBlockContext hfctx,
      FrameHeader header, int y, int x) {
    final index = List<int>.filled(3, 0);
    for (var i = 0; i < 3; i++) {
      final sy = y >> header.jpegUpsamplingY[i];
      final sx = x >> header.jpegUpsamplingX[i];
      final hft = hfctx.lfThresholds[i];
      final chan = lfQuant[cMap[i]];
      final v = chan.buffer![sy * chan.width + sx];
      for (var j = 0; j < hft.length; j++) {
        if (v > hft[j]) index[i]++;
      }
    }
    var lfIndex = index[0];
    lfIndex *= hfctx.lfThresholds[2].length + 1;
    lfIndex += index[2];
    lfIndex *= hfctx.lfThresholds[1].length + 1;
    lfIndex += index[1];
    return lfIndex;
  }
}
