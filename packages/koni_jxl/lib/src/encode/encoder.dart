import 'dart:math' as math;
import 'dart:typed_data';

import '../entropy/hybrid_uint.dart';
import '../io/bit_writer.dart';
import '../jxl_image.dart';
import '../util/math_helper.dart';
import 'context_tree.dart';
import 'entropy_writer.dart';
import 'headers.dart';
import 'vardct/vardct_l0_encoder.dart';
import 'wp_predictor.dart';

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

  /// Lossily (VarDCT) encodes an interleaved 8-bit RGB image
  /// (doc/lossy_encoder_plan.md's L0-L3 plus per-region chroma-from-luma:
  /// real HF coefficient context model, multi-group, multi-LF-group,
  /// adaptive quantization; filters and variable transform size are
  /// opt-in via [config], off by default). [width] and [height] must be
  /// multiples of 8. [distance] is a cjxl-like quality knob (larger =
  /// smaller/lower quality); pass [config] instead for direct control
  /// over the quantizer knobs.
  static Uint8List encodeLossy(
    Uint8List rgbPixels, {
    required int width,
    required int height,
    double distance = 1.0,
    VardctL0Config? config,
  }) =>
      encodeLossyVardctL0(rgbPixels,
          width: width,
          height: height,
          config: config ?? VardctL0Config.fromDistance(distance));
}

/// The default hybrid-uint tokenization config, also used to train the
/// context tree (the tree's split ranking is insensitive to which candidate
/// config below is ultimately chosen — verified: fixing tree training here
/// while sweeping the entropy config gives byte-identical output).
const _config = HybridIntegerConfig(4, 1, 0);

/// Candidate hybrid-uint configs tried per image at the entropy-coding stage;
/// the smallest actual output wins (like the predictor / entropy-mode choice).
/// The config only changes how residuals at/above the split point (2^4 packed,
/// i.e. |residual| >= 8) are tokenized — it's a no-op for small-residual
/// content, so trying `(4, 2, 0)` is free there and a real win where it
/// helps (screentone/manga -2% to -4%, some gradients/photos a fraction of a
/// percent; `(4, 1, 0)` still wins on smooth-photo and palette content, hence
/// keeping both and choosing per image). Both are decoder-legal and the
/// chosen config is serialized into each entropy stream's header.
const _hybridConfigs = [
  HybridIntegerConfig(4, 1, 0),
  HybridIntegerConfig(4, 2, 0),
];

int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

/// Pass A over a tile: appends packed-signed residuals (clamped-gradient, or
/// the weighted predictor when [useWp]) to [valuesOut], and for every
/// [stride]-th pixel records its property vector and hybrid token for
/// context-tree training.
void _tileResiduals(
    Int32List plane,
    int imageWidth,
    int ox,
    int oy,
    int tw,
    int th,
    List<int> valuesOut,
    List<int>? maxErrOut,
    List<int> trainProps,
    List<int> trainTokens,
    int stride,
    List<int> strideState,
    bool useWp,
    List<int> properties) {
  final tile = Int32List(tw * th);
  for (var y = 0; y < th; y++) {
    tile.setRange(y * tw, y * tw + tw, plane, (oy + y) * imageWidth + ox);
  }
  Int32List? wpRes;
  Int32List? wpErr;
  if (useWp) {
    wpRes = Int32List(tw * th);
    wpErr = Int32List(tw * th);
    wpTileResiduals(tile, tw, th, wpRes, wpErr);
  }
  final props = Int32List(properties.length);
  var counter = strideState[0];
  for (var y = 0; y < th; y++) {
    for (var x = 0; x < tw; x++) {
      final o = y * tw + x;
      final int value;
      if (useWp) {
        value = _packSigned(wpRes![o]);
        maxErrOut!.add(wpErr![o]);
      } else {
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
        value = _packSigned(tile[o] - pred);
      }
      valuesOut.add(value);
      if (counter == 0) {
        computeProps(tile, tw, th, y, x, properties, wpErr?[o] ?? 0, props);
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

/// Pass B over a tile: assigns each pixel a context by walking [tree]. The
/// per-pixel max-error (property 15) is read from [maxErrIn] (filled by Pass
/// A in the same order) so the weighted predictor isn't recomputed.
void _tileContexts(Int32List plane, int imageWidth, int ox, int oy, int tw,
    int th, ContextTree tree, List<int> contextsOut, List<int>? maxErrIn) {
  final tile = Int32List(tw * th);
  for (var y = 0; y < th; y++) {
    tile.setRange(y * tw, y * tw + tw, plane, (oy + y) * imageWidth + ox);
  }
  final props = Int32List(tree.properties.length);
  for (var y = 0; y < th; y++) {
    for (var x = 0; x < tw; x++) {
      final me = maxErrIn != null ? maxErrIn[contextsOut.length] : 0;
      computeProps(tile, tw, th, y, x, tree.properties, me, props);
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

/// Minimum relative gap in learned-tree training entropy for one predictor to
/// be declared the clear winner (so the loser's Pass B + entropy coding +
/// assembly is skipped). 2% is comfortably above the strided training set's
/// own sampling noise (~0.2% for the ~300k-sample cap), so a gap this large
/// reflects a real difference, not noise; smaller gaps fall through to the
/// "finish both, keep smaller" path. Empirically, every corpus/photographic
/// image with a gap ≥ this picked the same predictor its full-pipeline byte
/// count did.
const _kPredictorMargin = 1.02;

/// Everything Pass A + tree learning produces for one predictor, kept around so
/// the two predictors' trees can be compared cheaply (via
/// [ContextTree.trainingBits]) before the expensive Pass B + entropy coding,
/// and so the loser's per-pixel residuals stay available for per-leaf predictor
/// selection (the winning tree's leaves may switch to the loser's predictor).
typedef _Prep = ({
  int predictor,
  List<int> properties,
  ContextTree tree,
  List<List<int>> groupValues,
  List<List<int>>? groupMaxErr,
  List<int> metaValues,
  List<int>? metaMaxErr,
});

/// Pass B output for one prep: the per-region leaf contexts (reused to build
/// the mixed value stream) plus the same contexts already grouped into
/// entropy-coding sections.
typedef _PassB = ({
  List<int> metaContexts,
  List<List<int>> groupContexts,
  List<List<int>> sectionContexts,
});

double _histEntropy(Int32List hist, int off, int width, int total) {
  if (total == 0) return 0;
  var bits = 0.0;
  final lt = total.toDouble();
  for (var t = 0; t < width; t++) {
    final c = hist[off + t];
    if (c > 0) bits += c * (math.log(lt / c) * 1.4426950408889634);
  }
  return bits;
}

/// Chooses, per tree leaf, whether to keep [primaryPredictor]'s residuals or
/// switch to [altPredictor]'s — whichever tokenises that leaf's own pixels to
/// fewer bits (zeroth-order token entropy over the leaf's histogram, plus the
/// hybrid-uint extra bits, mirroring [ContextTree.trainingBits]). This only
/// constructs a candidate; the caller assembles both the mixed and the
/// single-predictor streams and keeps the smaller actual bytes, so a per-leaf
/// misprediction never regresses size. [primaryValues]/[altValues] are the two
/// predictors' packed-signed residuals, aligned index-for-index with the
/// contexts (same Pass A iteration order).
List<int> _selectLeafPredictors(
  int numContexts,
  int primaryPredictor,
  int altPredictor,
  List<int> metaContexts,
  List<List<int>> groupContexts,
  List<int> primaryMeta,
  List<List<int>> primaryGroups,
  List<int> altMeta,
  List<List<int>> altGroups,
) {
  var maxTok = 0;
  void scan(int v) {
    final t = tokenizeHybrid(_config, v).$1;
    if (t > maxTok) maxTok = t;
  }

  for (var i = 0; i < primaryMeta.length; i++) {
    scan(primaryMeta[i]);
    scan(altMeta[i]);
  }
  for (var g = 0; g < primaryGroups.length; g++) {
    final pg = primaryGroups[g];
    final ag = altGroups[g];
    for (var i = 0; i < pg.length; i++) {
      scan(pg[i]);
      scan(ag[i]);
    }
  }

  final w = maxTok + 1;
  final pHist = Int32List(numContexts * w);
  final aHist = Int32List(numContexts * w);
  final pExtra = Float64List(numContexts);
  final aExtra = Float64List(numContexts);
  final counts = Int32List(numContexts);

  void acc(int c, int pv, int av) {
    final (pt, pn, _) = tokenizeHybrid(_config, pv);
    final (at, an, _) = tokenizeHybrid(_config, av);
    pHist[c * w + pt]++;
    aHist[c * w + at]++;
    pExtra[c] += pn;
    aExtra[c] += an;
    counts[c]++;
  }

  for (var i = 0; i < metaContexts.length; i++) {
    acc(metaContexts[i], primaryMeta[i], altMeta[i]);
  }
  for (var g = 0; g < groupContexts.length; g++) {
    final gc = groupContexts[g];
    final pg = primaryGroups[g];
    final ag = altGroups[g];
    for (var i = 0; i < gc.length; i++) {
      acc(gc[i], pg[i], ag[i]);
    }
  }

  final leafPred = List<int>.filled(numContexts, primaryPredictor);
  for (var c = 0; c < numContexts; c++) {
    final total = counts[c];
    if (total == 0) continue;
    final pBits = _histEntropy(pHist, c * w, w, total) + pExtra[c];
    final aBits = _histEntropy(aHist, c * w, w, total) + aExtra[c];
    // Strict improvement only, so a numerical tie keeps the primary predictor
    // (and thus stays byte-identical to the single-predictor baseline).
    if (aBits < pBits) leafPred[c] = altPredictor;
  }
  return leafPred;
}

/// Builds the per-pixel residual stream for a per-leaf predictor assignment:
/// each pixel emits [primary]'s residual when its leaf kept [primaryPredictor],
/// else [alt]'s. All three lists are aligned index-for-index.
List<int> _mixValues(List<int> contexts, List<int> primary, List<int> alt,
    List<int> leafPred, int primaryPredictor) {
  final out = List<int>.filled(contexts.length, 0);
  for (var i = 0; i < contexts.length; i++) {
    out[i] = leafPred[contexts[i]] == primaryPredictor ? primary[i] : alt[i];
  }
  return out;
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

  // The palette meta channel (its colors) is predictor-independent.
  final totalPixels = width * height * planes.length;
  final stride = totalPixels > 300000 ? totalPixels ~/ 300000 : 1;
  Int32List? pal;
  if (palette != null) {
    final n = palette.length;
    pal = Int32List(3 * n);
    for (var i = 0; i < n; i++) {
      pal[i] = palette[i] >>> 40;
      pal[n + i] = (palette[i] >>> 20) & 0xFFFFF;
      pal[2 * n + i] = palette[i] & 0xFFFFF;
    }
  }

  // Builds the smallest codestream for one predictor (5 = clamped gradient,
  // 6 = self-correcting weighted). WP wins on photographic/tonal content,
  // gradient on line art; the encoder tries both and keeps the smaller.
  // Pass A + tree learning for one predictor (5 = clamped gradient, 6 =
  // self-correcting weighted). Split out from the rest so the two predictors'
  // learned trees can be compared (via [ContextTree.trainingBits]) before the
  // expensive Pass B + entropy-coding + assembly runs — see the decision
  // below `prep`/`finish`.
  _Prep prep(bool useWp) {
    final predictor = useWp ? 6 : 5;
    final properties = useWp ? wpProperties : gradProperties;
    final strideState = [0];
    final trainProps = <int>[];
    final trainTokens = <int>[];

    // Pass A: residuals per group (and the palette meta channel) plus a
    // strided training set for the context tree. For WP, the max-error
    // (property 15) is captured here so Pass B needn't recompute it.
    final metaValues = <int>[];
    final metaMaxErr = useWp ? <int>[] : null;
    if (pal != null) {
      _tileResiduals(
          pal,
          palette!.length,
          0,
          0,
          palette.length,
          3,
          metaValues,
          metaMaxErr,
          trainProps,
          trainTokens,
          stride,
          strideState,
          useWp,
          properties);
    }
    final groupValues = List<List<int>>.generate(numGroups, (_) => []);
    final groupMaxErr =
        useWp ? List<List<int>>.generate(numGroups, (_) => []) : null;
    for (var g = 0; g < numGroups; g++) {
      final ox = (g % groupsX) * groupDim;
      final oy = (g ~/ groupsX) * groupDim;
      final tw = (width - ox).clamp(0, groupDim);
      final th = (height - oy).clamp(0, groupDim);
      for (final plane in planes) {
        _tileResiduals(
            plane,
            width,
            ox,
            oy,
            tw,
            th,
            groupValues[g],
            groupMaxErr?[g],
            trainProps,
            trainTokens,
            stride,
            strideState,
            useWp,
            properties);
      }
    }

    final tree = learnContextTree(Int32List.fromList(trainProps),
        Int32List.fromList(trainTokens), properties);
    return (
      predictor: predictor,
      properties: properties,
      tree: tree,
      groupValues: groupValues,
      groupMaxErr: groupMaxErr,
      metaValues: metaValues,
      metaMaxErr: metaMaxErr,
    );
  }

  // Sections: the LfGlobal section carries the meta channel (and, for small
  // images, all pixel channels); otherwise one section per group. LZ77 windows
  // are per section. Contexts and values share this layout.
  List<List<int>> mkSections(List<int> meta, List<List<int>> groups) => [
        [
          ...meta,
          if (globalChannels)
            for (var g = 0; g < numGroups; g++) ...groups[g],
        ],
        if (!globalChannels)
          for (var g = 0; g < numGroups; g++) groups[g],
      ];

  // Pass B: assign every pixel a context by walking the learned tree. Contexts
  // are predictor-independent (they depend only on the tree and each pixel's
  // causal neighbourhood), so they are computed once per prep and reused for
  // both the single-predictor baseline and the per-leaf-mixed value stream.
  _PassB passB(_Prep p) {
    final tree = p.tree;
    final metaContexts = <int>[];
    if (pal != null) {
      _tileContexts(pal, palette!.length, 0, 0, palette.length, 3, tree,
          metaContexts, p.metaMaxErr);
    }
    final groupContexts = List<List<int>>.generate(numGroups, (_) => []);
    for (var g = 0; g < numGroups; g++) {
      final ox = (g % groupsX) * groupDim;
      final oy = (g ~/ groupsX) * groupDim;
      final tw = (width - ox).clamp(0, groupDim);
      final th = (height - oy).clamp(0, groupDim);
      for (final plane in planes) {
        _tileContexts(plane, width, ox, oy, tw, th, tree, groupContexts[g],
            p.groupMaxErr?[g]);
      }
    }
    return (
      metaContexts: metaContexts,
      groupContexts: groupContexts,
      sectionContexts: mkSections(metaContexts, groupContexts),
    );
  }

  // Entropy-codes and assembles the smallest real codestream for one
  // context/value partition and (optional) per-leaf predictor assignment,
  // serializing [tree] with [predictor] (or [leafPredictors] if given).
  // Returns the bytes, a mode label, and the winning entropy mode selector
  // (config index, LZ77, ANS). With [only] set, it skips the candidate search
  // and assembles exactly that one mode — used to code the mixed stream in the
  // baseline's already-chosen mode (the flips only nudge a few residuals, so
  // re-searching every {config}x{plain,LZ77}x{prefix,ANS} candidate would
  // roughly double assembly time for no measured size gain).
  (Uint8List, String, int, bool, bool) assembleStream(
    ContextTree tree,
    int predictor,
    List<List<int>> sectionContexts,
    List<List<int>> sectionValues,
    List<int>? leafPredictors, {
    (int, bool, bool)? only,
  }) {
    final numContexts = tree.contexts;
    // LZ77 (an expensive hash-chain pass) is only computed when a candidate
    // actually needs it — skipped entirely for a plain-mode `only` assembly.
    late final sectionOps = [
      for (var s = 0; s < sectionValues.length; s++)
        lz77Compress(sectionContexts[s], sectionValues[s]),
    ];

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
      serializeContextTree(lfGlobal, tree, predictor, leafPredictors);
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

    String modeStr(HybridIntegerConfig cfg, bool lz, bool ans) =>
        '${lz ? "lz" : "plain"}+${ans ? "ans" : "prefix"}'
        '/h${cfg.splitExponent}${cfg.msbInToken}${cfg.lsbInToken}';

    List<int> flatContexts() {
      final all = <int>[];
      for (final s in sectionContexts) {
        all.addAll(s);
      }
      return all;
    }

    List<int> flatValues() {
      final all = <int>[];
      for (final s in sectionValues) {
        all.addAll(s);
      }
      return all;
    }

    if (only != null) {
      final (cfgI, lz, ans) = only;
      final cfg = _hybridConfigs[cfgI];
      final codes = lz
          ? EntropyCodes.buildLz77(numContexts, sectionOps, cfg)
          : EntropyCodes.build(numContexts, flatContexts(), flatValues(), cfg);
      return (assemble(codes, ans, lz), modeStr(cfg, lz, ans), cfgI, lz, ans);
    }

    final allContexts = flatContexts();
    final allValues = flatValues();
    // For each candidate hybrid-uint config, build the {plain, LZ77} x
    // {prefix, ANS} entropy codes and their size estimates. ANS spends
    // fractional bits (no 1-bit-per-symbol floor); LZ77 copies repeated runs;
    // the config governs how at/above-split residuals tokenize.
    final candidates = <(EntropyCodes, bool, bool, int, double)>[];
    for (var ci = 0; ci < _hybridConfigs.length; ci++) {
      final cfg = _hybridConfigs[ci];
      final lzCodes = EntropyCodes.buildLz77(numContexts, sectionOps, cfg);
      final plainCodes =
          EntropyCodes.build(numContexts, allContexts, allValues, cfg);
      candidates
          .add((plainCodes, false, false, ci, plainCodes.estimatedBits()));
      candidates.add((lzCodes, false, true, ci, lzCodes.estimatedBits()));
      if (plainCodes.ansViable) {
        candidates
            .add((plainCodes, true, false, ci, plainCodes.ansEstimatedBits()));
      }
      if (lzCodes.ansViable) {
        candidates.add((lzCodes, true, true, ci, lzCodes.ansEstimatedBits()));
      }
    }
    final best = candidates.map((c) => c.$5).reduce((a, b) => a < b ? a : b);

    // Candidates within 3% of the best estimate get assembled for real; the
    // smallest actual output wins. This captures near-tie wins (e.g. unified
    // ANS+LZ77 beating LZ77 by a fraction of a percent) that estimates miss.
    final threshold = best * 1.03;
    Uint8List? bestBytes;
    var bestMode = '';
    var bestCfg = 0, bestLz = false, bestAns = false;
    for (final (codes, ans, lz, ci, est) in candidates) {
      if (est > threshold) continue;
      final bytes = assemble(codes, ans, lz);
      if (bestBytes == null || bytes.length < bestBytes.length) {
        bestBytes = bytes;
        bestMode = modeStr(codes.config, lz, ans);
        bestCfg = ci;
        bestLz = lz;
        bestAns = ans;
      }
    }
    if (bestBytes == null) {
      final (codes, ans, lz, ci, _) = candidates.first;
      bestBytes = assemble(codes, ans, lz);
      bestMode = modeStr(codes.config, lz, ans);
      bestCfg = ci;
      bestLz = lz;
      bestAns = ans;
    }
    return (bestBytes, bestMode, bestCfg, bestLz, bestAns);
  }

  // Single-predictor baseline for one prep; also returns its winning entropy
  // mode so per-leaf refinement can re-use it.
  (Uint8List, String, (int, bool, bool)) baselineOf(
      _Prep p, List<List<int>> sectionContexts) {
    final (bytes, mode, cfg, lz, ans) = assembleStream(p.tree, p.predictor,
        sectionContexts, mkSections(p.metaValues, p.groupValues), null);
    return (bytes, '${p.predictor == 6 ? "wp" : "grad"}/$mode', (cfg, lz, ans));
  }

  // Per-leaf predictor selection: refine the chosen tree by letting each leaf
  // switch to the alternate [alt]'s predictor wherever that codes its pixels
  // smaller (the residuals for both predictors were computed in Pass A and are
  // aligned index-for-index). The decoder reads a predictor per leaf and keeps
  // WP state live for every pixel whenever any leaf is WP, so a gradient leaf
  // beside a WP leaf reconstructs bit-exactly. Returns the smaller of the
  // single-predictor baseline and the per-leaf-mixed stream (strictly
  // never-worse).
  (Uint8List, String) refineOf(_Prep p, _Prep alt, _PassB ctx,
      Uint8List baseBytes, String baseLabel, (int, bool, bool) baseSel) {
    final leafPred = _selectLeafPredictors(
        p.tree.contexts,
        p.predictor,
        alt.predictor,
        ctx.metaContexts,
        ctx.groupContexts,
        p.metaValues,
        p.groupValues,
        alt.metaValues,
        alt.groupValues);
    var flips = 0;
    for (final lp in leafPred) {
      if (lp != p.predictor) flips++;
    }
    // No leaf switched -> the mixed stream is byte-identical to the baseline.
    if (flips == 0) return (baseBytes, baseLabel);

    final mixedMeta = _mixValues(
        ctx.metaContexts, p.metaValues, alt.metaValues, leafPred, p.predictor);
    final mixedGroups = [
      for (var g = 0; g < numGroups; g++)
        _mixValues(ctx.groupContexts[g], p.groupValues[g], alt.groupValues[g],
            leafPred, p.predictor),
    ];
    final (mixBytes, mixMode, _, _, _) = assembleStream(p.tree, p.predictor,
        ctx.sectionContexts, mkSections(mixedMeta, mixedGroups), leafPred,
        only: baseSel);
    if (mixBytes.length < baseBytes.length) {
      final wpLeaves = leafPred.where((x) => x == 6).length;
      return (
        mixBytes,
        'leaf(g${leafPred.length - wpLeaves}/w$wpLeaves)/$mixMode'
      );
    }
    return (baseBytes, baseLabel);
  }

  // Predictor selection. Both predictors' Pass A + tree learning always run
  // (learnTree is the single most expensive phase, and its output — the
  // learned tree's training entropy — is the cheapest reliable signal of
  // which predictor will compress better; a pre-tree residual-entropy proxy
  // was measured to mispredict badly, e.g. picking WP where gradient wins by
  // 11%). When one tree's training entropy is clearly lower, only that
  // predictor's Pass B + entropy coding + assembly runs; near-ties
  // (`_kPredictorMargin`) assemble both baselines and keep the smaller. On top
  // of the chosen predictor, per-leaf selection refines that one tree, letting
  // individual leaves switch to the other predictor where it codes their pixels
  // smaller.
  final gradPrep = prep(false);
  final wpPrep = prep(true);
  final gBits = gradPrep.tree.trainingBits;
  final wBits = wpPrep.tree.trainingBits;

  final Uint8List chosen;
  final String debug;
  if (gBits * _kPredictorMargin < wBits || wBits * _kPredictorMargin < gBits) {
    final useWp = wBits < gBits;
    final win = useWp ? wpPrep : gradPrep;
    final lose = useWp ? gradPrep : wpPrep;
    final ctx = passB(win);
    final (bb, bl, sel) = baselineOf(win, ctx.sectionContexts);
    final (bytes, mode) = refineOf(win, lose, ctx, bb, bl, sel);
    chosen = bytes;
    debug = 'chose=$mode (skip loser tree; trainBits '
        'g=${gBits.round()} w=${wBits.round()})';
  } else {
    // Near-tie: per-leaf-refine BOTH trees and keep the smaller. The raw
    // single-predictor baselines don't reliably predict which tree refines
    // smaller (a tree whose raw baseline loses can win after per-leaf mixing —
    // e.g. a manga page where raw WP beats raw gradient but the refined
    // gradient tree beats the refined WP tree), and each refinement's mixed
    // stream is assembled in just its baseline's winning mode, so refining both
    // is cheap.
    final gctx = passB(gradPrep);
    final (gbb, gbl, gsel) = baselineOf(gradPrep, gctx.sectionContexts);
    final (gradBytes, gradMode) =
        refineOf(gradPrep, wpPrep, gctx, gbb, gbl, gsel);
    final wctx = passB(wpPrep);
    final (wbb, wbl, wsel) = baselineOf(wpPrep, wctx.sectionContexts);
    final (wpBytes, wpMode) = refineOf(wpPrep, gradPrep, wctx, wbb, wbl, wsel);
    final wpWins = wpBytes.length < gradBytes.length;
    chosen = wpWins ? wpBytes : gradBytes;
    debug = 'chose=${wpWins ? wpMode : gradMode} (near-tie, refined both; '
        'grad=${gradBytes.length} wp=${wpBytes.length})';
  }
  if (const bool.fromEnvironment('jxl.encdebug')) {
    // ignore: avoid_print
    print('palette=${palette?.length} rct=$useRct $debug');
  }
  return chosen;
}
