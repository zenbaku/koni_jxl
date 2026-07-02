import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import 'delta_palette.dart';
import 'ma_tree.dart';
import 'modular_channel.dart';
import 'transform_info.dart';
import 'wp_params.dart';

const _permutationLut = [
  [0, 1, 2], [1, 2, 0], [2, 0, 1], //
  [0, 2, 1], [1, 0, 2], [2, 1, 0],
];

/// What a modular (sub-)stream needs to know about its enclosing frame.
final class ModularFrameContext {
  const ModularFrameContext({
    required this.frameWidth,
    required this.frameHeight,
    required this.groupDim,
    required this.globalTree,
    required this.ecDimShifts,
    required this.bitDepth,
  });

  /// The modular frame size (frame bounds).
  final int frameWidth;
  final int frameHeight;
  final int groupDim;
  final MaTree? globalTree;

  /// dimShift per extra channel.
  final List<int> ecDimShifts;

  /// Image bits per sample (used by the palette transform).
  final int bitDepth;
}

/// A modular bitstream section: channel list, transform chain, MA tree and
/// entropy stream, with forward parsing and inverse transform application.
final class ModularStream {
  /// Reads the stream header. If [channelArray] is given, those channels are
  /// used directly (group streams); otherwise [channelCount] full-frame
  /// channels are created, of which the last `channelCount - ecStart` are
  /// extra channels.
  ModularStream.read(
    BitReader reader,
    this.ctx, {
    required this.streamIndex,
    List<ModularChannel>? channelArray,
    int channelCount = 0,
    int ecStart = 0,
  }) {
    channelCount = channelArray?.length ?? channelCount;
    if (channelCount == 0) {
      distMultiplier = 1;
      return;
    }
    final useGlobalTree = reader.readBool();
    wpParams = WpParams.read(reader);
    final nbTransforms = reader.readU32(0, 0, 1, 0, 2, 4, 18, 8);
    transforms = List.generate(nbTransforms, (_) => TransformInfo.read(reader));

    if (channelArray == null) {
      for (var i = 0; i < channelCount; i++) {
        final dimShift = i < ecStart ? 0 : ctx.ecDimShifts[i - ecStart];
        channels.add(ModularChannel(
            ctx.frameHeight, ctx.frameWidth, dimShift, dimShift));
      }
    } else {
      channels.addAll(channelArray);
    }

    for (var i = 0; i < nbTransforms; i++) {
      final t = transforms[i];
      if (t.tr == TransformInfo.palette || t.tr == TransformInfo.rct) {
        final needed = t.tr == TransformInfo.rct ? 3 : t.numC;
        if (t.beginC < 0 || needed < 1 || t.beginC + needed > channels.length) {
          throw const JxlInvalidBitstreamException(
              'transform channel range out of bounds');
        }
      }
      if (t.tr == TransformInfo.palette) {
        if (t.beginC < nbMetaChannels) {
          nbMetaChannels += 2 - t.numC;
        } else {
          nbMetaChannels++;
        }
        final start = t.beginC + 1;
        for (var j = start; j < t.beginC + t.numC; j++) {
          channels.removeAt(start);
        }
        if (t.nbDeltas > 0 && t.dPred == 6) {
          channels[t.beginC].forceWp = true;
        }
        channels.insert(0, ModularChannel(t.numC, t.nbColors, -1, -1));
      } else if (t.tr == TransformInfo.squeeze) {
        final squeezeList = <SqueezeParam>[];
        if (t.sp!.isEmpty) {
          final first = nbMetaChannels;
          final count = channels.length - first;
          // Default squeeze parameters operate on the first non-meta
          // channel's size (libjxl uses channel[nb_meta_channels]).
          var w = channels[first].width;
          var h = channels[first].height;
          if (count > 2 && channels[first + 1].sizeEquals(channels[first])) {
            squeezeList.add(SqueezeParam(true, false, first + 1, 2));
            squeezeList.add(SqueezeParam(false, false, first + 1, 2));
          }
          if (h >= w && h > 8) {
            squeezeList.add(SqueezeParam(false, true, first, count));
            h = (h + 1) ~/ 2;
          }
          while (w > 8 || h > 8) {
            if (w > 8) {
              squeezeList.add(SqueezeParam(true, true, first, count));
              w = (w + 1) ~/ 2;
            }
            if (h > 8) {
              squeezeList.add(SqueezeParam(false, true, first, count));
              h = (h + 1) ~/ 2;
            }
          }
        } else {
          squeezeList.addAll(t.sp!);
        }
        _squeezeMap[i] = squeezeList;
        for (final sp in squeezeList) {
          final begin = sp.beginC;
          final end = begin + sp.numC - 1;
          if (begin < 0 || sp.numC < 1 || end >= channels.length) {
            throw const JxlInvalidBitstreamException(
                'squeeze channel range out of bounds');
          }
          final offset = sp.inPlace ? end + 1 : channels.length;
          if (begin < nbMetaChannels) {
            if (!sp.inPlace) {
              throw const JxlInvalidBitstreamException(
                  'squeeze meta must be in place');
            }
            if (end >= nbMetaChannels) {
              throw const JxlInvalidBitstreamException(
                  'squeeze meta must end in meta');
            }
            nbMetaChannels += sp.numC;
          }
          for (var k = begin; k <= end; k++) {
            final chan = channels[k];
            final r = offset + k - begin;
            final ModularChannel residu;
            if (sp.horizontal) {
              final w = chan.width;
              chan.width = (w + 1) ~/ 2;
              chan.hshift++;
              residu = ModularChannel.copy(chan);
              residu.width = w ~/ 2;
            } else {
              final h = chan.height;
              chan.height = (h + 1) ~/ 2;
              chan.vshift++;
              residu = ModularChannel.copy(chan);
              residu.height = h ~/ 2;
            }
            channels.insert(r, residu);
          }
        }
      } else if (t.tr == TransformInfo.rct) {
        // RCT doesn't modify the channel list.
        continue;
      } else {
        throw JxlInvalidBitstreamException('illegal transform ${t.tr}');
      }
    }

    if (!useGlobalTree) {
      tree = MaTree.read(reader);
    } else {
      tree = ctx.globalTree;
      if (tree == null) {
        throw const JxlInvalidBitstreamException(
            'stream uses global tree but no global tree exists');
      }
    }
    stream = EntropyStream.clone(tree!.stream!);

    distMultiplier = 0;
    for (final c in channels) {
      if (c.width > distMultiplier) distMultiplier = c.width;
    }
  }

  final ModularFrameContext ctx;
  final int streamIndex;
  int nbMetaChannels = 0;
  int distMultiplier = 1;

  MaTree? tree;
  WpParams? wpParams;
  List<TransformInfo> transforms = const [];
  EntropyStream? stream;
  bool _transformed = false;

  final List<ModularChannel> channels = [];
  final Map<int, List<SqueezeParam>> _squeezeMap = {};

  int get encodedChannelCount => channels.length;

  ModularChannel getChannel(int index) => channels[index];

  void decodeChannels(BitReader reader, {bool partial = false}) {
    var channelIndex = 0;
    for (var i = 0; i < channels.length; i++) {
      final channel = channels[i];
      if (partial &&
          i >= nbMetaChannels &&
          (channel.height > ctx.groupDim || channel.width > ctx.groupDim)) {
        break;
      }
      if (channel.width == 0 || channel.height == 0) {
        channel.allocate();
      } else {
        channel.decode(reader, stream!, wpParams, tree!, channels, channelIndex,
            streamIndex, distMultiplier);
        channelIndex++;
      }
    }
    if (stream != null && !stream!.validateFinalState()) {
      throw const JxlInvalidBitstreamException('illegal final modular state');
    }
    if (!partial) applyTransforms();
  }

  void applyTransforms() {
    if (_transformed) return;
    _transformed = true;
    for (var i = transforms.length - 1; i >= 0; i--) {
      final t = transforms[i];
      if (t.tr == TransformInfo.squeeze) {
        final spa = _squeezeMap[i]!;
        for (var j = spa.length - 1; j >= 0; j--) {
          final sp = spa[j];
          final begin = sp.beginC;
          final end = begin + sp.numC - 1;
          final offset =
              sp.inPlace ? end + 1 : channels.length + begin - end - 1;
          for (var c = begin; c <= end; c++) {
            final r = offset + c - begin;
            final chan = channels[c];
            final residu = channels[r];
            final ModularChannel output;
            if (sp.horizontal) {
              output = ModularChannel.inverseHorizontalSqueeze(
                  ModularChannel(chan.height, chan.width + residu.width,
                      chan.vshift, chan.hshift - 1),
                  chan,
                  residu);
            } else {
              output = ModularChannel.inverseVerticalSqueeze(
                  ModularChannel(chan.height + residu.height, chan.width,
                      chan.vshift - 1, chan.hshift),
                  chan,
                  residu);
            }
            channels[c] = output;
          }
          for (var c = 0; c < end - begin + 1; c++) {
            channels.removeAt(offset);
          }
        }
      } else if (t.tr == TransformInfo.rct) {
        final permutation = t.rctType ~/ 7;
        final type = t.rctType % 7;
        if (permutation >= _permutationLut.length) {
          throw const JxlInvalidBitstreamException('invalid RCT permutation');
        }
        final start = t.beginC;
        final v = [channels[start], channels[start + 1], channels[start + 2]];
        if (!v[1].sizeEquals(v[0]) || !v[2].sizeEquals(v[1])) {
          throw const JxlInvalidBitstreamException(
              'RCT needs three equal-size channels');
        }
        final n = v[0].height * v[0].width;
        final b0 = v[0].buffer!;
        final b1 = v[1].buffer!;
        final b2 = v[2].buffer!;
        switch (type) {
          case 0:
            break;
          case 1:
            for (var p = 0; p < n; p++) {
              b2[p] += b0[p];
            }
          case 2:
            for (var p = 0; p < n; p++) {
              b1[p] += b0[p];
            }
          case 3:
            for (var p = 0; p < n; p++) {
              final a = b0[p];
              b2[p] += a;
              b1[p] += a;
            }
          case 4:
            for (var p = 0; p < n; p++) {
              b1[p] += (b0[p] + b2[p]) >> 1;
            }
          case 5:
            for (var p = 0; p < n; p++) {
              final a = b0[p];
              final ac = a + b2[p];
              b1[p] += (a + ac) >> 1;
              b2[p] = ac;
            }
          case 6:
            for (var p = 0; p < n; p++) {
              final b = b1[p];
              final c = b2[p];
              final tmp = b0[p] - (c >> 1);
              final f = tmp - (b >> 1);
              b0[p] = f + b;
              b1[p] = c + tmp;
              b2[p] = f;
            }
        }
        for (var j = 0; j < 3; j++) {
          channels[start + _permutationLut[permutation][j]] = v[j];
        }
      } else if (t.tr == TransformInfo.palette) {
        final first = t.beginC + 1;
        final endC = t.beginC + t.numC - 1;
        final last = endC + 1;
        final bitDepth = ctx.bitDepth;
        final firstChannel = channels[first];
        final c0 = channels[0];
        for (var j = first + 1; j <= last; j++) {
          channels.insert(j, ModularChannel.copy(firstChannel));
        }
        for (var c = 0; c < t.numC; c++) {
          final chan = channels[first + c];
          final cb = chan.buffer!;
          for (var y = 0; y < firstChannel.height; y++) {
            for (var x = 0; x < firstChannel.width; x++) {
              final o = y * firstChannel.width + x;
              var index = cb[o];
              final isDelta = index < t.nbDeltas;
              int value;
              if (index >= 0 && index < t.nbColors) {
                value = c0.get(c, index);
              } else if (index >= t.nbColors) {
                index -= t.nbColors;
                if (index < 64) {
                  value =
                      ((index >> (2 * c)) % 4) * ((1 << bitDepth) - 1) ~/ 4 +
                          (1 << (bitDepth - 3 > 0 ? bitDepth - 3 : 0));
                } else {
                  index -= 64;
                  for (var k = 0; k < c; k++) {
                    index ~/= 5;
                  }
                  value = (index % 5) * ((1 << bitDepth) - 1) ~/ 4;
                }
              } else if (c < 3) {
                index = (-index - 1) % 143;
                value = kDeltaPalette[((index + 1) >> 1) * 3 + c];
                if (index & 1 == 0) value = -value;
                if (bitDepth > 8) {
                  value <<= (bitDepth < 24 ? bitDepth : 24) - 8;
                }
              } else {
                value = 0;
              }
              cb[o] = value;
              if (isDelta) {
                cb[o] += chan.prediction(y, x, t.dPred);
              }
            }
          }
        }
        channels.removeAt(0);
        if (t.beginC < nbMetaChannels) {
          nbMetaChannels -= 2 - t.numC;
        } else {
          nbMetaChannels--;
        }
      }
    }
  }
}
