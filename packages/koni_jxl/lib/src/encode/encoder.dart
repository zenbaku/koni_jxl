import 'dart:typed_data';

import '../entropy/hybrid_uint.dart';
import '../io/bit_writer.dart';
import '../jxl_image.dart';
import '../util/math_helper.dart';
import 'context_tree.dart';
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

  /// Losslessly encodes interleaved 16-bit pixels (same layout as
  /// [encodeLossless]).
  static Uint8List encodeLossless16(
    Uint16List pixels, {
    required int width,
    required int height,
    bool grayscale = false,
    bool hasAlpha = false,
  }) {
    final setup = JxlEncodeSetup(
        width: width,
        height: height,
        bitsPerSample: 16,
        grayscale: grayscale,
        hasAlpha: hasAlpha);
    final n = setup.channelCount;
    if (pixels.length != width * height * n) {
      throw ArgumentError('expected ${width * height * n} samples, '
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

int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

/// Pass A over a tile: appends packed-signed clamped-gradient residuals to
/// [valuesOut], and for every [stride]-th pixel records its property vector
/// and hybrid token for context-tree training.
void _tileResiduals(
    Int32List plane,
    int imageWidth,
    int ox,
    int oy,
    int tw,
    int th,
    List<int> valuesOut,
    List<int> trainProps,
    List<int> trainTokens,
    int stride,
    List<int> strideState) {
  final tile = Int32List(tw * th);
  for (var y = 0; y < th; y++) {
    tile.setRange(y * tw, y * tw + tw, plane, (oy + y) * imageWidth + ox);
  }
  final props = Int32List(treeProperties.length);
  var counter = strideState[0];
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
      final value = _packSigned(tile[o] - pred);
      valuesOut.add(value);
      if (counter == 0) {
        computePropsAt(tile, tw, th, y, x, props);
        for (var pi = 0; pi < props.length; pi++) {
          trainProps.add(props[pi]);
        }
        trainTokens.add(tokenizeHybrid(_config, value).$1);
        counter = stride;
      }
      counter--;
    }
  }
  strideState[0] = counter;
}

/// Pass B over a tile: assigns each pixel a context by walking [tree].
void _tileContexts(Int32List plane, int imageWidth, int ox, int oy, int tw,
    int th, ContextTree tree, List<int> contextsOut) {
  final tile = Int32List(tw * th);
  for (var y = 0; y < th; y++) {
    tile.setRange(y * tw, y * tw + tw, plane, (oy + y) * imageWidth + ox);
  }
  final props = Int32List(treeProperties.length);
  for (var y = 0; y < th; y++) {
    for (var x = 0; x < tw; x++) {
      computePropsAt(tile, tw, th, y, x, props);
      contextsOut.add(contextFor(tree, props));
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

/// Collects the distinct colors of the first three [planes]; null when
/// more than [maxColors].
List<int>? _detectPalette(List<Int32List> planes, int maxColors) {
  final seen = <int>{};
  final p0 = planes[0];
  final p1 = planes[1];
  final p2 = planes[2];
  for (var i = 0; i < p0.length; i++) {
    seen.add((p0[i] << 40) | (p1[i] << 20) | p2[i]);
    if (seen.length > maxColors) return null;
  }
  final colors = seen.toList()
    ..sort((a, b) {
      int lum(int k) => (k >>> 40) + ((k >>> 20) & 0xFFFFF) + (k & 0xFFFFF);
      return lum(a) - lum(b);
    });
  return colors;
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

  // Transform choice: palette when the color count is small, RCT
  // otherwise (color images only).
  List<int>? palette;
  var useRct = false;
  if (!setup.grayscale) {
    palette = _detectPalette(planes, 256);
    if (palette != null) {
      final lookup = <int, int>{};
      for (var i = 0; i < palette.length; i++) {
        lookup[palette[i]] = i;
      }
      final p0 = planes[0];
      final p1 = planes[1];
      final p2 = planes[2];
      final index = Int32List(p0.length);
      for (var i = 0; i < p0.length; i++) {
        index[i] = lookup[(p0[i] << 40) | (p1[i] << 20) | p2[i]]!;
      }
      planes = [index, ...planes.sublist(3)];
    } else {
      useRct = true;
      _forwardRct(planes);
    }
  }

  // Pass A: residuals per group (and the palette meta channel), plus a
  // strided training set for the context tree. The meta channel (palette
  // colors) rides in the global stream and shares the same tree.
  final totalPixels = width * height * planes.length;
  final stride = totalPixels > 300000 ? totalPixels ~/ 300000 : 1;
  final strideState = [0];
  final trainProps = <int>[];
  final trainTokens = <int>[];

  final metaValues = <int>[];
  Int32List? pal;
  if (palette != null) {
    final n = palette.length;
    pal = Int32List(3 * n);
    for (var i = 0; i < n; i++) {
      pal[i] = palette[i] >>> 40;
      pal[n + i] = (palette[i] >>> 20) & 0xFFFFF;
      pal[2 * n + i] = palette[i] & 0xFFFFF;
    }
    _tileResiduals(pal, n, 0, 0, n, 3, metaValues, trainProps, trainTokens,
        stride, strideState);
  }

  final groupValues = List<List<int>>.generate(numGroups, (_) => []);
  for (var g = 0; g < numGroups; g++) {
    final ox = (g % groupsX) * groupDim;
    final oy = (g ~/ groupsX) * groupDim;
    final tw = (width - ox).clamp(0, groupDim);
    final th = (height - oy).clamp(0, groupDim);
    for (final plane in planes) {
      _tileResiduals(plane, width, ox, oy, tw, th, groupValues[g], trainProps,
          trainTokens, stride, strideState);
    }
  }

  // Learn the context tree, then Pass B: assign each pixel a context.
  final tree = learnContextTree(
      Int32List.fromList(trainProps), Int32List.fromList(trainTokens));
  final numContexts = tree.contexts;

  final metaContexts = <int>[];
  if (pal != null) {
    _tileContexts(
        pal, palette!.length, 0, 0, palette.length, 3, tree, metaContexts);
  }
  final groupContexts = List<List<int>>.generate(numGroups, (_) => []);
  for (var g = 0; g < numGroups; g++) {
    final ox = (g % groupsX) * groupDim;
    final oy = (g ~/ groupsX) * groupDim;
    final tw = (width - ox).clamp(0, groupDim);
    final th = (height - oy).clamp(0, groupDim);
    for (final plane in planes) {
      _tileContexts(plane, width, ox, oy, tw, th, tree, groupContexts[g]);
    }
  }

  // Section token sequences: the LfGlobal section carries the meta channel
  // (and, for small images, all pixel channels); otherwise one section per
  // group. LZ77 windows are per section.
  final sectionContexts = <List<int>>[
    [
      ...metaContexts,
      if (globalChannels)
        for (var g = 0; g < numGroups; g++) ...groupContexts[g],
    ],
    if (!globalChannels)
      for (var g = 0; g < numGroups; g++) groupContexts[g],
  ];
  final sectionValues = <List<int>>[
    [
      ...metaValues,
      if (globalChannels)
        for (var g = 0; g < numGroups; g++) ...groupValues[g],
    ],
    if (!globalChannels)
      for (var g = 0; g < numGroups; g++) groupValues[g],
  ];

  final sectionOps = [
    for (var s = 0; s < sectionValues.length; s++)
      lz77Compress(sectionContexts[s], sectionValues[s]),
  ];
  final lzCodes = EntropyCodes.buildLz77(numContexts, sectionOps, _config);
  final allContexts = <int>[];
  final allValues = <int>[];
  for (var s = 0; s < sectionValues.length; s++) {
    allContexts.addAll(sectionContexts[s]);
    allValues.addAll(sectionValues[s]);
  }
  final plainCodes =
      EntropyCodes.build(numContexts, allContexts, allValues, _config);
  // Four candidates: {plain, LZ77} x {prefix, ANS}. ANS spends fractional
  // bits (no 1-bit-per-symbol floor); LZ77 copies repeated runs. Unifying
  // them lets an image get both wins when the estimator says so.
  final plainEst = plainCodes.estimatedBits();
  final lzEst = lzCodes.estimatedBits();
  final plainAnsEst =
      plainCodes.ansViable ? plainCodes.ansEstimatedBits() : double.infinity;
  final lzAnsEst =
      lzCodes.ansViable ? lzCodes.ansEstimatedBits() : double.infinity;
  final best =
      [plainEst, lzEst, plainAnsEst, lzAnsEst].reduce((a, b) => a < b ? a : b);

  // Assembles the full codestream for one entropy mode. Cheap enough to run
  // for each close candidate and keep the smallest actual output — estimates
  // can't resolve sub-percent differences between near-tied modes.
  Uint8List assemble(EntropyCodes codes, bool ans, bool lz) {
    void writeSectionPayload(BitWriter w, int s) {
      if (ans && lz) {
        codes.encodeAnsLz77Section(w, sectionOps[s]);
      } else if (ans) {
        codes.encodeAnsSection(w, sectionContexts[s], sectionValues[s]);
      } else if (lz) {
        codes.writeOps(w, sectionOps[s]);
      } else {
        for (var i = 0; i < sectionValues[s].length; i++) {
          codes.writeToken(w, sectionContexts[s][i], sectionValues[s][i]);
        }
      }
    }

    final lfGlobal = BitWriter();
    lfGlobal.writeBool(true); // default lfDequant
    lfGlobal.writeBool(true); // has_global_tree
    serializeContextTree(lfGlobal, tree);
    if (ans) {
      codes.writeAnsHeader(lfGlobal);
    } else {
      codes.writeHeader(lfGlobal);
    }
    lfGlobal.writeBool(true); // use_global_tree
    lfGlobal.writeBool(true); // default wp_params
    if (palette != null) {
      lfGlobal.writeU32(1, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 1
      lfGlobal.writeBits(1, 2); // transform: palette
      lfGlobal.writeU32(0, 0, 3, 8, 6, 72, 10, 1096, 13); // begin_c = 0
      lfGlobal.writeU32(3, 1, 0, 3, 0, 4, 0, 1, 13); // num_c = 3
      lfGlobal.writeU32(
          palette.length, 0, 8, 256, 10, 1280, 12, 5376, 16); // nb_colors
      lfGlobal.writeU32(0, 0, 0, 1, 8, 257, 10, 1281, 16); // nb_deltas = 0
      lfGlobal.writeBits(0, 4); // d_pred
    } else if (useRct) {
      lfGlobal.writeU32(1, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 1
      lfGlobal.writeBits(0, 2); // transform: RCT
      lfGlobal.writeU32(0, 0, 3, 8, 6, 72, 10, 1096, 13); // begin_c = 0
      lfGlobal.writeU32(6, 6, 0, 0, 2, 2, 4, 10, 6); // rct_type = 6 (YCoCg)
    } else {
      lfGlobal.writeU32(0, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 0
    }
    writeSectionPayload(lfGlobal, 0);

    final out = BitWriter();
    writeImageHeader(out, setup);
    writeFrameHeader(out, setup);
    if (singleSection) {
      final body = lfGlobal.toBytes();
      writeToc(out, [body.length]);
      out.writeBytes(body);
    } else {
      Uint8List writeGroupSection(int s) {
        final w = BitWriter();
        w.writeBool(true); // use_global_tree
        w.writeBool(true); // default wp_params
        w.writeU32(0, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms
        writeSectionPayload(w, s);
        return w.toBytes();
      }

      final sections = <Uint8List>[
        lfGlobal.toBytes(),
        for (var i = 0; i < numLfGroups; i++) Uint8List(0),
        Uint8List(0),
        for (var g = 0; g < numGroups; g++) writeGroupSection(1 + g),
      ];
      writeToc(out, [for (final s in sections) s.length]);
      for (final s in sections) {
        out.writeBytes(s);
      }
    }
    return out.toBytes();
  }

  // Candidates within 3% of the best estimate get assembled for real; the
  // smallest actual output wins. This captures near-tie wins (e.g. unified
  // ANS+LZ77 beating LZ77 by a fraction of a percent) that estimates miss.
  final candidates = <(EntropyCodes, bool, bool, double)>[
    (plainCodes, false, false, plainEst),
    (lzCodes, false, true, lzEst),
    if (plainCodes.ansViable) (plainCodes, true, false, plainAnsEst),
    if (lzCodes.ansViable) (lzCodes, true, true, lzAnsEst),
  ];
  final threshold = best * 1.03;
  Uint8List? bestBytes;
  var bestMode = '';
  for (final (codes, ans, lz, est) in candidates) {
    if (est > threshold) continue;
    final bytes = assemble(codes, ans, lz);
    if (bestBytes == null || bytes.length < bestBytes.length) {
      bestBytes = bytes;
      bestMode = '${lz ? "lz" : "plain"}+${ans ? "ans" : "prefix"}';
    }
  }
  if (const bool.fromEnvironment('jxl.encdebug')) {
    String k(double v) => v.isFinite ? '${(v / 8192).round()}K' : '-';
    // ignore: avoid_print
    print('palette=${palette?.length} rct=$useRct chose=$bestMode '
        'plain=${k(plainEst)} lz=${k(lzEst)} '
        'plainAns=${k(plainAnsEst)} lzAns=${k(lzAnsEst)}');
  }
  return bestBytes ?? assemble(plainCodes, false, false);
}
