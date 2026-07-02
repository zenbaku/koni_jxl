import 'dart:typed_data';

import '../entropy/hybrid_uint.dart';
import '../io/bit_writer.dart';
import '../jxl_image.dart';
import '../util/math_helper.dart';
import 'entropy_writer.dart';
import 'headers.dart';

/// Pure-Dart JPEG XL encoder (lossless modular).
///
/// The output decodes bit-exact with any conforming decoder; every file is
/// gated in tests against both this package's decoder and libjxl's djxl.
final class JxlEncoder {
  /// Losslessly encodes interleaved 8-bit pixels.
  ///
  /// [pixels] layout is `width * height * channelCount` bytes where the
  /// channel count is 1 (gray), 2 (gray+alpha), 3 (RGB) or 4 (RGBA)
  /// according to [grayscale] and [hasAlpha].
  static Uint8List encodeLossless(
    Uint8List pixels, {
    required int width,
    required int height,
    bool grayscale = false,
    bool hasAlpha = false,
  }) {
    final setup = JxlEncodeSetup(
        width: width,
        height: height,
        bitsPerSample: 8,
        grayscale: grayscale,
        hasAlpha: hasAlpha);
    final n = setup.channelCount;
    if (pixels.length != width * height * n) {
      throw ArgumentError('expected ${width * height * n} bytes, '
          'got ${pixels.length}');
    }
    final planes = [
      for (var c = 0; c < n; c++) Int32List(width * height),
    ];
    for (var c = 0; c < n; c++) {
      final plane = planes[c];
      for (var i = 0; i < width * height; i++) {
        plane[i] = pixels[i * n + c];
      }
    }
    return _encodeModular(setup, planes);
  }

  /// Losslessly re-encodes a decoded [JxlImage] (integer samples only).
  static Uint8List encodeImage(JxlImage image) {
    final header = image.header;
    if (header.bitDepth.usesFloatSamples || image.channels[0].isFloat) {
      throw ArgumentError('only integer images can be re-encoded losslessly');
    }
    final setup = JxlEncodeSetup(
        width: image.width,
        height: image.height,
        bitsPerSample: header.bitDepth.bitsPerSample,
        grayscale: header.isGrayscale,
        hasAlpha: image.hasAlpha);
    final channels = setup.channelCount;
    final planes = <Int32List>[];
    final maxValue = header.bitDepth.maxValue;
    for (var c = 0; c < channels; c++) {
      final rows = image.channels[c].intRows;
      final plane = Int32List(setup.width * setup.height);
      for (var y = 0; y < setup.height; y++) {
        final row = rows[y];
        for (var x = 0; x < setup.width; x++) {
          final v = row[x];
          plane[y * setup.width + x] = v < 0
              ? 0
              : v > maxValue
                  ? maxValue
                  : v;
        }
      }
      planes.add(plane);
    }
    return _encodeModular(setup, planes);
  }
}

const _config = HybridIntegerConfig(4, 1, 0);

/// The fixed MA tree: 7 gradient-activity contexts, all leaves using the
/// clamped-gradient predictor. Written in the reader's BFS node order.
///
/// Walk (property > value ? left : right), properties: 11 = NW - N,
/// 10 = W - NW:
///   d = NW - N:  d > 16 -> ctx big+; 2 < d <= 16 -> mid+;
///   -2 <= d <= 2 -> split on e = W - NW into {e > 2, -2 <= e <= 2, e < -2};
///   -16 <= d < -2 -> mid-; d < -16 -> big-.
const _numContexts = 7;

void _writeFixedTree(BitWriter w) {
  final tokens = EntropyWriter(6);
  void inner(int property, int value) {
    tokens.write(1, property + 1);
    tokens.write(0, _packSigned(value));
  }

  void leaf() {
    tokens.write(1, 0);
    tokens.write(2, 5); // predictor: clamped gradient
    tokens.write(3, 0); // offset
    tokens.write(4, 0); // mul_log
    tokens.write(5, 0); // mul_bits
  }

  // BFS order (matches MaTree.read's node layout).
  inner(11, 16); //          root: d > 16 ?
  leaf(); //                 ctx 0: big+
  inner(11, 2); //           d > 2 ?
  leaf(); //                 ctx 1: mid+
  inner(11, -3); //          d >= -2 ?
  inner(10, 2); //             e > 2 ?
  inner(11, -17); //         d >= -16 ?
  leaf(); //                 ctx 2: e > 2
  inner(10, -3); //            e >= -2 ?
  leaf(); //                 ctx 3: mid-
  leaf(); //                 ctx 4: big-
  leaf(); //                 ctx 5: flat
  leaf(); //                 ctx 6: e < -2
  tokens.finalize(w);
}

@pragma('vm:prefer-inline')
int _context(int d, int e) {
  if (d > 16) return 0;
  if (d > 2) return 1;
  if (d >= -2) {
    if (e > 2) return 2;
    if (e >= -2) return 5;
    return 6;
  }
  if (d >= -16) return 3;
  return 4;
}

int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

/// Emits one tile's residual tokens (context from the fixed tree,
/// clamped-gradient prediction), matching the decoder's per-tile borders.
void _tokenizeTile(Int32List plane, int imageWidth, int ox, int oy, int tw,
    int th, List<int> contexts, List<int> values) {
  final tile = Int32List(tw * th);
  for (var y = 0; y < th; y++) {
    tile.setRange(y * tw, y * tw + tw, plane, (oy + y) * imageWidth + ox);
  }
  for (var y = 0; y < th; y++) {
    for (var x = 0; x < tw; x++) {
      final o = y * tw + x;
      final w = x > 0
          ? tile[o - 1]
          : y > 0
              ? tile[o - tw]
              : 0;
      final n = y > 0 ? tile[o - tw] : w;
      final nw = x > 0 && y > 0 ? tile[o - tw - 1] : w;
      final grad = w + n - nw;
      final lo = w < n ? w : n;
      final hi = w > n ? w : n;
      final pred = grad < lo
          ? lo
          : grad > hi
              ? hi
              : grad;
      contexts.add(_context(nw - n, w - nw));
      values.add(_packSigned(tile[o] - pred));
    }
  }
}

/// Forward YCoCg (RCT type 6): the exact integer mirror of the decoder's
/// inverse.
void _forwardRct(List<Int32List> planes) {
  final p0 = planes[0];
  final p1 = planes[1];
  final p2 = planes[2];
  for (var i = 0; i < p0.length; i++) {
    final o0 = p0[i];
    final o1 = p1[i];
    final o2 = p2[i];
    final s1 = o0 - o2;
    final tmp = o2 + (s1 >> 1);
    final s2 = o1 - tmp;
    p0[i] = tmp + (s2 >> 1);
    p1[i] = s1;
    p2[i] = s2;
  }
}

Uint8List _encodeModular(JxlEncodeSetup setup, List<Int32List> planes) {
  const groupDim = 256;
  final width = setup.width;
  final height = setup.height;
  final groupsX = ceilDiv(width, groupDim);
  final groupsY = ceilDiv(height, groupDim);
  final numGroups = groupsX * groupsY;
  final numLfGroups =
      ceilDiv(width, groupDim << 3) * ceilDiv(height, groupDim << 3);
  final singleSection = numGroups == 1;
  final globalChannels = width <= groupDim && height <= groupDim;
  final useRct = !setup.grayscale;
  if (useRct) _forwardRct(planes);

  // Tokenize every group tile (channel-major inside each group, matching
  // decodeChannels order).
  final groupContexts = List<List<int>>.generate(numGroups, (_) => []);
  final groupValues = List<List<int>>.generate(numGroups, (_) => []);
  for (var g = 0; g < numGroups; g++) {
    final ox = (g % groupsX) * groupDim;
    final oy = (g ~/ groupsX) * groupDim;
    final tw = (width - ox).clamp(0, groupDim);
    final th = (height - oy).clamp(0, groupDim);
    for (final plane in planes) {
      _tokenizeTile(
          plane, width, ox, oy, tw, th, groupContexts[g], groupValues[g]);
    }
  }
  final allContexts = <int>[];
  final allValues = <int>[];
  for (var g = 0; g < numGroups; g++) {
    allContexts.addAll(groupContexts[g]);
    allValues.addAll(groupValues[g]);
  }
  final residualCodes =
      EntropyCodes.build(_numContexts, allContexts, allValues, _config);

  // --- LfGlobal section ---
  final lfGlobal = BitWriter();
  lfGlobal.writeBool(true); // default lfDequant
  lfGlobal.writeBool(true); // has_global_tree
  _writeFixedTree(lfGlobal);
  // Residual distributions follow the tree (read inside MaTree.read).
  residualCodes.writeHeader(lfGlobal);
  // Global modular stream header.
  lfGlobal.writeBool(true); // use_global_tree
  lfGlobal.writeBool(true); // default wp_params
  if (useRct) {
    lfGlobal.writeU32(1, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 1
    lfGlobal.writeBits(0, 2); // transform: RCT
    lfGlobal.writeU32(0, 0, 3, 8, 6, 72, 10, 1096, 13); // begin_c = 0
    lfGlobal.writeU32(6, 6, 0, 0, 2, 2, 4, 10, 6); // rct_type = 6 (YCoCg)
  } else {
    lfGlobal.writeU32(0, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 0
  }
  if (globalChannels) {
    // Small image: the channels are encoded in the global stream itself.
    for (var g = 0; g < numGroups; g++) {
      for (var i = 0; i < groupValues[g].length; i++) {
        residualCodes.writeToken(
            lfGlobal, groupContexts[g][i], groupValues[g][i]);
      }
    }
  }

  // --- Group sections ---
  Uint8List writeGroupSection(int g) {
    final w = BitWriter();
    w.writeBool(true); // use_global_tree
    w.writeBool(true); // default wp_params
    w.writeU32(0, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms
    for (var i = 0; i < groupValues[g].length; i++) {
      residualCodes.writeToken(w, groupContexts[g][i], groupValues[g][i]);
    }
    return w.toBytes();
  }

  // --- Assemble the codestream ---
  final out = BitWriter();
  writeImageHeader(out, setup);
  writeFrameHeader(out, setup);
  if (singleSection) {
    // One section: LfGlobal, (empty) LF group, (empty) HfGlobal and the
    // pass group are read sequentially from the same bit stream. With the
    // channels in the global stream, nothing follows LfGlobal.
    final body = lfGlobal.toBytes();
    writeToc(out, [body.length]);
    out.writeBytes(body);
  } else {
    final sections = <Uint8List>[
      lfGlobal.toBytes(),
      for (var i = 0; i < numLfGroups; i++) Uint8List(0), // LF groups
      Uint8List(0), // HfGlobal + passes (nothing for modular)
      for (var g = 0; g < numGroups; g++) writeGroupSection(g),
    ];
    writeToc(out, [for (final s in sections) s.length]);
    for (final s in sections) {
      out.writeBytes(s);
    }
  }
  return out.toBytes();
}
