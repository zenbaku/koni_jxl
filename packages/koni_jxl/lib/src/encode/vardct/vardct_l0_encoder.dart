import 'dart:math' as math;
import 'dart:typed_data';

import '../../entropy/hybrid_uint.dart';
import '../../frame/frame_flags.dart';
import '../../io/bit_writer.dart';
import '../../util/math_helper.dart';
import '../../vardct/dct.dart';
import '../../vardct/hf_block_context.dart';
import '../../vardct/hf_coefficients.dart' show HfCoefficients;
import '../../vardct/hf_global.dart' show defaultDctParams, getDCTQuantWeights;
import '../../vardct/hf_pass.dart' show getNaturalOrder;
import '../../vardct/transform_type.dart' show TransformMode, TransformType;
import '../context_tree.dart';
import '../entropy_writer.dart';
import '../headers.dart';
import '../wp_predictor.dart';
import 'xyb_forward.dart';

/// Lossy (VarDCT) encoder (doc/lossy_encoder_plan.md's L0/L1/L2/L3): 8x8
/// DCT (plus optional adaptive 16x16 selection), real HF coefficient
/// context model, multi-group, adaptive per-block quantization, a custom
/// per-frequency quant weight table and optional filters; still
/// single-LfGroup (see ROADMAP.md for what's left).
///
/// The overall quantization step is `scaleFactor[c] / rawWeight[c][y][x]`
/// for AC and `lfDequantDefault[c] / (globalScale * quantLF)` for DC; both
/// mirror the decoder's dequantization formulas exactly (see
/// `vardct/hf_coefficients.dart` and `vardct/lf_coefficients.dart`).
/// [globalScale] and [quantLF] jointly set the DC step size; [acScale] and
/// [quantLF] set the AC/DC step size respectively — smaller [quantLF] or
/// larger [acScale] mean finer (more precise) quantized integers and thus
/// higher quality / larger files.
class VardctL0Config {
  const VardctL0Config({
    this.globalScale = 65536,
    this.quantLF = 16,
    this.xqmScale = 3,
    this.bqmScale = 2,
    this.acScale = 1.0,
    this.enableFilters = false,
    this.enableVariableTransforms = false,
    this.enableRdHfMult = false,
    this.rdHfMultLambdaOverride,
  });

  /// Derives quantization knobs from a cjxl-like `distance` (butteraugli
  /// distance is what libjxl's own distance parameter targets; this is a
  /// simple monotonic proxy, not a reproduction of libjxl's internal
  /// distance-to-quantizer formula, since there is no decoder-side
  /// computation to mirror here — this is pure encoder policy). `1.0` is
  /// this encoder's baseline; larger values quantize more coarsely
  /// (smaller files, lower quality), smaller values quantize more finely.
  /// AC fineness comes from [acScale] (a custom per-frequency quant weight
  /// table — see `_writeHfGlobalAndPass`), not from [globalScale] (left at
  /// its baseline): `globalScale`'s bitstream field alone can only push AC
  /// quality ~11% finer than baseline before hitting its ceiling, which
  /// used to put a quality floor around `distance` ~0.5-0.8.
  factory VardctL0Config.fromDistance(double distance) {
    if (distance <= 0) {
      throw ArgumentError.value(distance, 'distance', 'must be positive');
    }
    // Both are dequantization *divisors* (dequant = stored / (something *
    // distance-derived-value)), so a smaller distance (finer/higher
    // quality) needs LARGER values of both, not smaller — inverting this
    // direction (an earlier version of this formula did, for quantLF)
    // silently makes "higher quality" requests coarser instead.
    final quantLF = (16 / distance).round().clamp(1, 65536);
    return VardctL0Config(quantLF: quantLF, acScale: 1.0 / distance);
  }

  final int globalScale;
  final int quantLF;
  final int xqmScale;
  final int bqmScale;

  /// Multiplies the default DCT quant weight tables (written as custom
  /// `quant_all_default = false` tables rather than relying on
  /// [globalScale], which has limited fine-quantization headroom). `1.0`
  /// reproduces the library default tables exactly.
  final double acScale;

  /// Whether to enable Gaborish deringing and edge-preserving filtering
  /// (the format's own defaults: `gab = true`, 2 EPF iterations). Defaults
  /// to **off**: measured to help smooth/photographic content (a few
  /// percent RMSE reduction) but to catastrophically hurt manga's two
  /// dominant content types — screentone patterns and high-contrast line
  /// art both got ~13x *worse* RMSE in testing, since these filters are
  /// smoothing filters that blur exactly the sharp edges and regular
  /// high-frequency detail those content types are made of. See
  /// doc/spec_notes.md before flipping this on for a non-manga use case.
  final bool enableFilters;

  /// Whether to adaptively choose between 8x8 and 16x16 DCT per 16x16
  /// pixel region (a rough bit-cost proxy decides). Defaults to **off**:
  /// the proxy is a crude per-coefficient magnitude/count estimate, not
  /// the real context-adaptive entropy cost, and it mispredicts badly on
  /// regular high-frequency content — it picked 16x16 100% of the time on
  /// a screentone test pattern, yet the real (entropy-coded, djxl-
  /// verified) output was both larger *and* worse RMSE than plain 8x8
  /// there (+20% size) and on line art (+31% size). It's a small, genuine
  /// win on smooth photographic content (~4% smaller at matched quality
  /// in testing). See doc/spec_notes.md before flipping this on for a
  /// non-manga use case.
  final bool enableVariableTransforms;

  /// Whether to replace the default 3-bucket adaptive-quantization
  /// heuristic (`hfMult` chosen from a threshold on relative AC energy)
  /// with a real per-block rate-distortion search over the same
  /// candidate multipliers ({1, 2, 4}). Defaults to **off** — see
  /// `_chooseHfMultRd`'s doc comment and doc/spec_notes.md for the
  /// calibration status and measured numbers before enabling.
  final bool enableRdHfMult;

  /// Overrides the rate/distortion trade-off constant `_kRdLambda` used
  /// by [enableRdHfMult] (a runtime knob rather than a recompile, purely
  /// so `tool/calibrate_rd_lambda.dart` can sweep it in one process).
  /// Null (the default) uses the shipped, calibrated constant.
  final double? rdHfMultLambdaOverride;
}

int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

const _hfConfig = HybridIntegerConfig(4, 1, 0);

/// Channel processing/bitstream order used throughout VarDCT: Y, X, B
/// (semantic indices 1, 0, 2 — see `frame/frame.dart`'s `cMap`).
const _channelOrder = [1, 0, 2];

final _tt8 = TransformType.byType(0); // DCT 8x8: orderID 0, parameterIndex 0
final _tt16 = TransformType.byType(4); // DCT 16x16: orderID 2, parameterIndex 4

/// LF groups are 256x256 blocks (2048x2048 pixels) — `frame.dart`'s
/// `header.lfGroupDim` (`groupDim << 3`, `groupDim` hardcoded to 256 for
/// VarDCT).
const _lfGroupBlockDim = 256;

/// `LfChannelCorrelation.colorFactor`: the resolution of the per-region HF
/// correlation delta (`xFromY`/`bFromY` in `_writeHfMetadata` — a stored
/// integer divided by this). 84 is the format's own default; shared here
/// so `_writeLfGlobal` (which writes it) and the per-region fit (which
/// must quantize deltas against the exact same value) can't drift apart.
const _colorFactor = 84;

/// Encodes an interleaved 8-bit RGB image as a VarDCT (lossy) JPEG XL
/// stream. [width]/[height] may be any positive size — VarDCT always
/// operates on an 8-pixel-block-aligned canvas internally, so a size
/// that isn't already a multiple of 8 is padded up to the next multiple
/// by replicating the last row/column of pixels (avoiding a sharp,
/// bit-costly edge at the padding boundary); the true (unpadded)
/// [width]/[height] is what's written to the image header and what
/// decoders report/crop to, matching how real-world JPEG XL files
/// (almost never exactly block-aligned) already work. Multiple 256x256
/// groups and multiple 2048x2048 LF groups are both supported for
/// arbitrarily large images.
Uint8List encodeLossyVardctL0(
  Uint8List rgbPixels, {
  required int width,
  required int height,
  VardctL0Config config = const VardctL0Config(),
}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('empty image');
  }
  if (rgbPixels.length != width * height * 3) {
    throw ArgumentError('expected ${width * height * 3} bytes of RGB');
  }
  final paddedWidth = (width + 7) & ~7;
  final paddedHeight = (height + 7) & ~7;

  // 1. Deinterleave, linearize (sRGB EOTF) and transform to XYB in place,
  // onto the padded canvas (edge-replicated beyond the true width/height).
  final planes = [
    for (var c = 0; c < 3; c++)
      List.generate(paddedHeight, (_) => Float32List(paddedWidth)),
  ];
  for (var y = 0; y < paddedHeight; y++) {
    final srcY = y < height ? y : height - 1;
    final rRow = planes[0][y], gRow = planes[1][y], bRow = planes[2][y];
    for (var x = 0; x < paddedWidth; x++) {
      final srcX = x < width ? x : width - 1;
      final o = (srcY * width + srcX) * 3;
      rRow[x] = rgbPixels[o].toDouble();
      gRow[x] = rgbPixels[o + 1].toDouble();
      bRow[x] = rgbPixels[o + 2].toDouble();
    }
  }
  for (final plane in planes) {
    XybForward.srgbToLinear(plane);
  }
  XybForward().forward(planes[0], planes[1], planes[2]);

  final bh = paddedHeight ~/ 8;
  final bw = paddedWidth ~/ 8;

  // 2. Quantization tables (mirroring the decoder's default DCT weights and
  // scale factors exactly; see doc/lossy_encoder_plan.md). Scaling only the
  // first (lowest-frequency) band by acScale scales the entire interpolated
  // weight table by the same factor (see doc/spec_notes.md), giving a
  // fineness knob with no ceiling — unlike globalScale, whose bitstream
  // field caps how much finer than baseline it can reach.
  List<List<double>> customParams(TransformType tt) => [
        for (var c = 0; c < 3; c++)
          [
            defaultDctParams[tt.parameterIndex].dctParam![c][0] *
                config.acScale,
            ...defaultDctParams[tt.parameterIndex].dctParam![c].skip(1),
          ],
      ];
  final customDctParams8 = customParams(_tt8);
  final customDctParams16 = customParams(_tt16);
  final rawWeight8 = [
    for (var c = 0; c < 3; c++) getDCTQuantWeights(8, 8, customDctParams8[c]),
  ];
  final rawWeight16 = [
    for (var c = 0; c < 3; c++)
      getDCTQuantWeights(16, 16, customDctParams16[c]),
  ];
  final globalScaleF = 65536.0 / config.globalScale;
  final scaleFactor = [
    globalScaleF * math.pow(0.8, config.xqmScale - 2.0),
    globalScaleF,
    globalScaleF * math.pow(0.8, config.bqmScale - 2.0),
  ];
  const lfDequantDefault = [1 / 4096.0, 1 / 512.0, 1 / 256.0];
  final sd = [
    for (var c = 0; c < 3; c++)
      (1 << 16) * lfDequantDefault[c] / (config.globalScale * config.quantLF),
  ];

  // 3. Chroma-from-luma: a global (whole-image) least-squares X-on-Y/B-on-Y
  // fit (used for baseCorrelationX/B and always for DC/LLF), plus a
  // per-64x64-region fit layered on top for true AC coefficients (see
  // _ChromaFromLumaFit's doc comment for why DC can't use the per-region
  // value) — replacing the format's neutral defaults (kX = 0, kB = 1.0).
  final scratch8a = List.generate(8, (_) => Float32List(8));
  final scratch8b = List.generate(8, (_) => Float32List(8));
  final scratch16a = List.generate(16, (_) => Float32List(16));
  final scratch16b = List.generate(16, (_) => Float32List(16));
  final cfl = _chromaFromLumaFit(planes, bh, bw, scratch8a, scratch8b);
  // Reference AC step at the first (lowest-frequency, most perceptually
  // important) Y position: the scale against which "how smooth is this
  // block" is judged, so heuristics adapt with `distance` instead of using
  // an absolute threshold tuned for one quantization strength.
  final refStep = scaleFactor[1] / rawWeight8[1][0][1];

  // 4. Decide the block layout: adaptively 8x8 or 16x16 per aligned 16x16
  // pixel region (a rough bit-cost proxy, `_should16x16`), in the exact
  // raster-scan-with-skip order `HfMetadata`'s decoder-side `_placeBlock`
  // reconstructs from a flat block list — placement order IS the wire
  // format here, not just a convenience.
  final placedBlocks = <_PlacedBlock>[];
  if (config.enableVariableTransforms) {
    final covered = List<bool>.filled(bh * bw, false);
    for (var by = 0; by < bh; by++) {
      for (var bx = 0; bx < bw; bx++) {
        if (covered[by * bw + bx]) continue;
        final canPair = by.isEven &&
            bx.isEven &&
            by + 1 < bh &&
            bx + 1 < bw &&
            !covered[(by + 1) * bw + bx] &&
            !covered[by * bw + bx + 1] &&
            !covered[(by + 1) * bw + bx + 1];
        if (canPair &&
            _should16x16(planes[1], by, bx, refStep, scratch8a, scratch8b,
                scratch16a, scratch16b)) {
          covered[(by + 1) * bw + bx] = true;
          covered[by * bw + bx + 1] = true;
          covered[(by + 1) * bw + bx + 1] = true;
          placedBlocks.add(_PlacedBlock(by, bx, _tt16));
        } else {
          placedBlocks.add(_PlacedBlock(by, bx, _tt8));
        }
      }
    }
  } else {
    for (var by = 0; by < bh; by++) {
      for (var bx = 0; bx < bw; bx++) {
        placedBlocks.add(_PlacedBlock(by, bx, _tt8));
      }
    }
  }

  // 4.5. Context/grouping setup: hoisted ahead of quantization since it
  // only depends on which transform types are placed and where — not on
  // any block's chosen hfMult — and the RD-hfMult search (step 5.5) needs
  // it for its bootstrap pass before step 6's real one.
  final hfctx = HfBlockContext.defaults();
  final ctxByType = {
    for (final tt in [_tt8, _tt16]) tt.type: _TransformCtx(tt, hfctx),
  };
  // ceilDiv(trueSize, 256) == ceilDiv(paddedSize, 256) always (padding adds
  // at most 7 pixels, far short of a 256 boundary, and true/padded sizes
  // coincide exactly whenever trueSize is already a multiple of 256 since
  // 256 is itself a multiple of 8) — using the padded size here is just
  // the more directly available one (matches bw/bh already in scope).
  final groupsX = ceilDiv(paddedWidth, 256);
  final groupsY = ceilDiv(paddedHeight, 256);
  final numGroups = groupsX * groupsY;
  final blocksByGroup = List<List<_PlacedBlock>>.generate(numGroups, (_) => []);
  for (final block in placedBlocks) {
    final g = (block.by ~/ 32) * groupsX + (block.bx ~/ 32);
    blocksByGroup[g].add(block);
  }

  // 5. Per-block forward DCT, chroma-from-luma pre-subtraction, adaptive
  // quantization multiplier and quantization. dcInt is semantic-indexed
  // (0=X, 1=Y, 2=B), always at native 8x8-block granularity (DC/LF is
  // always coded per 8x8 cell regardless of the HF transform covering it —
  // see _PlacedBlock's doc comment on the LLF relationship for 16x16).
  final dcInt = [for (var c = 0; c < 3; c++) Int32List(bh * bw)];
  for (final block in placedBlocks) {
    block.computeAndQuantize(
        planes,
        cfl,
        refStep,
        sd,
        block.tt == _tt16 ? rawWeight16 : rawWeight8,
        scaleFactor,
        dcInt,
        bw,
        scratch8a,
        scratch8b,
        scratch16a,
        scratch16b);
  }

  // 5.5. Optional: replace the L2 heuristic's per-block hfMult choice
  // (just committed above) with a real rate-distortion search — see
  // _chooseHfMultRd's doc comment. Off by default pending calibration
  // (doc/spec_notes.md).
  if (config.enableRdHfMult) {
    _chooseHfMultRd(
        placedBlocks,
        planes,
        cfl,
        refStep,
        sd,
        rawWeight8,
        rawWeight16,
        scaleFactor,
        dcInt,
        bw,
        scratch8a,
        scratch8b,
        scratch16a,
        scratch16b,
        hfctx,
        ctxByType,
        groupsX,
        groupsY,
        blocksByGroup,
        config.rdHfMultLambdaOverride);
  }

  // 6. AC coefficient tokens, one group at a time (each group is its own
  // 256x256-pixel / 32x32-block tile with an independent non-zero
  // prediction grid, mirroring a fresh HfCoefficients per (pass, group)).
  // Blocks never straddle a group boundary: groups are 32-block-aligned
  // (even) and 16x16 blocks only start at globally-even coordinates with a
  // 2x2 footprint, so a block's origin alone determines its group.
  final groupTokens = <_GroupTokens>[
    for (var gy = 0; gy < groupsY; gy++)
      for (var gx = 0; gx < groupsX; gx++)
        _computeGroupTokens(gy * 32, gx * 32, blocksByGroup[gy * groupsX + gx],
            hfctx, ctxByType),
  ];
  final clustering = _chooseAcClustering(groupTokens);

  // 6b. Partition into LF groups (each up to 2048x2048 pixels / 256x256
  // blocks — `_lfGroupBlockDim`), matching `frame.dart`'s
  // lfGroupRowStride/numLfGroups exactly. Blocks never straddle an LF
  // group boundary either (256 blocks is even; same argument as the group
  // boundary above), so filtering the *global* placedBlocks list down to
  // one LF group's blocks — in the same relative order — reproduces
  // exactly the raster-scan-with-skip order that LF group's own
  // independent placement decoding expects; no separate per-LF-group
  // placement pass is needed.
  final lfGroupsX = ceilDiv(bw, _lfGroupBlockDim);
  final lfGroupsY = ceilDiv(bh, _lfGroupBlockDim);
  final numLfGroups = lfGroupsX * lfGroupsY;
  final lfGroupOriginBy = List<int>.filled(numLfGroups, 0);
  final lfGroupOriginBx = List<int>.filled(numLfGroups, 0);
  final lfGroupBh = List<int>.filled(numLfGroups, 0);
  final lfGroupBw = List<int>.filled(numLfGroups, 0);
  for (var id = 0; id < numLfGroups; id++) {
    final row = id ~/ lfGroupsX, col = id % lfGroupsX;
    final originBy = row * _lfGroupBlockDim;
    final originBx = col * _lfGroupBlockDim;
    lfGroupOriginBy[id] = originBy;
    lfGroupOriginBx[id] = originBx;
    lfGroupBh[id] = math.min(_lfGroupBlockDim, bh - originBy);
    lfGroupBw[id] = math.min(_lfGroupBlockDim, bw - originBx);
  }
  final blocksByLfGroup =
      List<List<_PlacedBlock>>.generate(numLfGroups, (_) => []);
  for (final block in placedBlocks) {
    final id = (block.by ~/ _lfGroupBlockDim) * lfGroupsX +
        (block.bx ~/ _lfGroupBlockDim);
    blocksByLfGroup[id].add(block);
  }

  // 7. Assemble the bitstream: image header, VarDCT frame header, then
  // either the single concatenated section body (numGroups == 1 and
  // numLfGroups == 1 forces tocEntryCount == 1 — no byte alignment
  // between LfGlobal / LfGroup / HfGlobal+HfPass / PassGroup; see
  // doc/lossy_encoder_plan.md's TOC single-section note) or, otherwise,
  // one independently byte-aligned section per (LfGlobal, each LF
  // group's LfCoefficients+HfMetadata, HfGlobal+HfPass, and each group's
  // PassGroup) — matching `frame.dart`'s exact TOC section ordering:
  // LfGlobal, one section per LF group, HfGlobal+passes, then one
  // PassGroup section per group.
  final usesCustomWeights = config.acScale != 1.0;
  final customParamsByIndex = usesCustomWeights
      ? {
          _tt8.parameterIndex: customDctParams8,
          _tt16.parameterIndex: customDctParams16
        }
      : null;

  final out = BitWriter();
  writeImageHeader(
      out,
      JxlEncodeSetup(
          width: width,
          height: height,
          bitsPerSample: 8,
          grayscale: false,
          hasAlpha: false),
      xybEncoded: true);
  _writeVardctFrameHeader(out, config);

  if (numGroups == 1 && numLfGroups == 1) {
    final body = BitWriter();
    _writeLfGlobal(body, config, cfl.kXGlobal, cfl.kBGlobal);
    _writeLfCoefficients(body, dcInt[0], dcInt[1], dcInt[2], bw);
    _writeHfMetadata(body, bh, bw, placedBlocks, 0, 0, cfl);
    _writeHfGlobalAndPass(body, numGroups, customParamsByIndex);
    clustering.codes.writeHeader(body, clusterMap: clustering.clusterMap);
    _writeAcGroupPayload(body, clustering.codes,
        clustering.mappedClustersPerGroup[0], groupTokens[0].values);
    final bodyBytes = body.toBytes();
    writeToc(out, [bodyBytes.length]);
    out.writeBytes(bodyBytes);
  } else {
    final lfGlobalW = BitWriter();
    _writeLfGlobal(lfGlobalW, config, cfl.kXGlobal, cfl.kBGlobal);

    final lfGroupSections = <Uint8List>[
      for (var id = 0; id < numLfGroups; id++)
        _assembleLfGroupSection(
            dcInt,
            bw,
            lfGroupOriginBy[id],
            lfGroupOriginBx[id],
            lfGroupBh[id],
            lfGroupBw[id],
            blocksByLfGroup[id],
            cfl),
    ];

    final hfGlobalW = BitWriter();
    _writeHfGlobalAndPass(hfGlobalW, numGroups, customParamsByIndex);
    clustering.codes.writeHeader(hfGlobalW, clusterMap: clustering.clusterMap);

    final passGroupSections = [
      for (var g = 0; g < numGroups; g++)
        _assembleGroupSection(clustering.codes,
            clustering.mappedClustersPerGroup[g], groupTokens[g].values),
    ];
    final sections = <Uint8List>[
      lfGlobalW.toBytes(),
      ...lfGroupSections,
      hfGlobalW.toBytes(),
      ...passGroupSections,
    ];
    if (const bool.fromEnvironment('jxl.encdebug')) {
      final lfGroupBytes = lfGroupSections.fold(0, (a, s) => a + s.length);
      final acBytes = passGroupSections.fold(0, (a, s) => a + s.length);
      // ignore: avoid_print
      print('vardct sections: lfGlobal=${lfGlobalW.toBytes().length} '
          'lfGroups(dc+meta)=$lfGroupBytes hfGlobal=${hfGlobalW.toBytes().length} '
          'ac=$acBytes total=${sections.fold(0, (a, s) => a + s.length)}');
    }
    writeToc(out, [for (final s in sections) s.length]);
    for (final s in sections) {
      out.writeBytes(s);
    }
  }
  return out.toBytes();
}

/// One LF group's section: its own slice of the DC/LF plane (extracted
/// from the whole-image [dcInt], row-major within this LF group's own
/// [lfGroupBh] x [lfGroupBw] extent) plus HfMetadata for its own blocks
/// ([blocksInLfGroup], already in this LF group's local raster-scan-with-
/// skip order — see the comment where `blocksByLfGroup` is built).
Uint8List _assembleLfGroupSection(
    List<Int32List> dcInt,
    int bwFull,
    int originBy,
    int originBx,
    int lfGroupBh,
    int lfGroupBw,
    List<_PlacedBlock> blocksInLfGroup,
    _ChromaFromLumaFit cfl) {
  Int32List extractLocal(Int32List global) {
    final out = Int32List(lfGroupBh * lfGroupBw);
    for (var ly = 0; ly < lfGroupBh; ly++) {
      final srcRow = (originBy + ly) * bwFull + originBx;
      out.setRange(ly * lfGroupBw, ly * lfGroupBw + lfGroupBw, global, srcRow);
    }
    return out;
  }

  final w = BitWriter();
  _writeLfCoefficients(w, extractLocal(dcInt[0]), extractLocal(dcInt[1]),
      extractLocal(dcInt[2]), lfGroupBw);
  final dcBits = w.bitsWritten;
  _writeHfMetadata(
      w, lfGroupBh, lfGroupBw, blocksInLfGroup, originBy, originBx, cfl);
  if (const bool.fromEnvironment('jxl.encdebug')) {
    // ignore: avoid_print
    print(
        '  lfGroup: dc=${dcBits ~/ 8}B meta=${(w.bitsWritten - dcBits) ~/ 8}B');
  }
  return w.toBytes();
}

/// Rough bit-cost proxy (count of above-threshold coefficients, log-weighted
/// by magnitude) comparing one 16x16 DCT against four independent 8x8 DCTs
/// over the same 16x16 pixel region, on the Y channel only (the dominant
/// perceptual signal). Measured to favor 16x16 on every content type tried
/// (smooth gradients, screentone, line art, noise) in ad hoc testing before
/// this was wired in — see doc/spec_notes.md.
bool _should16x16(
    List<Float32List> yPlane,
    int by,
    int bx,
    double refStep,
    List<Float32List> scratch8a,
    List<Float32List> scratch8b,
    List<Float32List> scratch16a,
    List<Float32List> scratch16b) {
  final c8 = List.generate(8, (_) => Float32List(8));
  var cost8 = 0.0;
  for (final oy in [by * 8, by * 8 + 8]) {
    for (final ox in [bx * 8, bx * 8 + 8]) {
      forwardDCT2D(yPlane, c8, oy, ox, 0, 0, 8, 8, scratch8a, scratch8b);
      cost8 += _bitProxy(c8, 8, 8, 1, refStep);
    }
  }
  final c16 = List.generate(16, (_) => Float32List(16));
  forwardDCT2D(
      yPlane, c16, by * 8, bx * 8, 0, 0, 16, 16, scratch16a, scratch16b);
  final cost16 = _bitProxy(c16, 16, 16, 4, refStep);
  return cost16 < cost8;
}

double _bitProxy(
    List<Float32List> coeffs, int h, int w, int numLlf, double thresh) {
  var cost = 0.0;
  var llfSeen = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (y < 2 && x < 2 && llfSeen < numLlf) {
        llfSeen++;
        continue; // LLF/DC positions are quantized separately.
      }
      final v = coeffs[y][x].abs();
      if (v > thresh) cost += 1 + math.log(v / thresh) / math.ln2;
    }
  }
  return cost;
}

/// One placed HF block: either an 8x8 or 16x16 DCT at block-grid origin
/// ([by], [bx]) (8x8-cell units). The DC/LF (coarse) plane is always at
/// native 8x8-cell granularity regardless of [tt] — a 16x16 block's four
/// underlying DC values combine via a forward 2x2 DCT on the *decode* side
/// (`hf_coefficients.dart`'s `_finalizeLLF`) to produce its top-left 2x2
/// "LLF" coefficient corner (scaled by `tt.llfScale`), so this encoder must
/// invert that relationship: compute the true 16x16 DCT's own LLF corner,
/// divide out `llfScale`, then apply the algebraic inverse of the forward
/// 2x2 DCT (a self-inverse Hadamard-like transform up to the same 1/4
/// scaling either direction cancels) to recover the four DC-plane values
/// that will reconstruct it. For an 8x8 block this degenerates to the
/// trivial 1x1 case (`llfScale[0] == 1.0`, no inversion needed).
class _PlacedBlock {
  _PlacedBlock(this.by, this.bx, this.tt);

  final int by, bx;
  final TransformType tt;
  int hfMult = 1;

  /// Per semantic channel (X, Y, B): flat, row-major
  /// (`tt.pixelHeight` x `tt.pixelWidth`) quantized AC coefficients. The
  /// LLF corner (`tt.dctSelectHeight` x `tt.dctSelectWidth` positions) is
  /// unused here — those come from the DC plane on decode. Set only by
  /// [commit] (never re-set directly), so a block can be re-quantized
  /// with several candidate multipliers (see `_chooseHfMultRd`) before
  /// committing to one without violating single-assignment expectations.
  List<Int32List> acInt = const [];

  /// Forward DCT + chroma-from-luma pre-subtraction for this block: the
  /// shared first step of both [computeAndQuantize] (the default path)
  /// and the RD-hfMult search (`_chooseHfMultRd`, which needs to try
  /// several quantization candidates against the *same* coefficients).
  List<List<Float32List>> computeCoeffBuf(
      List<List<Float32List>> planes,
      _ChromaFromLumaFit cfl,
      List<Float32List> scratch8a,
      List<Float32List> scratch8b,
      List<Float32List> scratch16a,
      List<Float32List> scratch16b) {
    final n = tt.pixelHeight; // == pixelWidth for both 8x8 and 16x16
    final coeffBuf = [
      for (var c = 0; c < 3; c++) List.generate(n, (_) => Float32List(n))
    ];
    final scratchA = n == 8 ? scratch8a : scratch16a;
    final scratchB = n == 8 ? scratch8b : scratch16b;
    for (var c = 0; c < 3; c++) {
      forwardDCT2D(planes[c], coeffBuf[c], by * 8, bx * 8, 0, 0, n, n, scratchA,
          scratchB);
    }

    final llfH = tt.dctSelectHeight, llfW = tt.dctSelectWidth;

    // Chroma-from-luma: the decoder always adds kX/kB times the Y
    // coefficient into X/B, so that must be pre-subtracted here. The LLF
    // corner uses the *global* slope (DC/LF never varies per region — see
    // _ChromaFromLumaFit's doc comment); true AC positions use this
    // block's own 64x64-pixel region slope.
    final regionIdx = cfl.regionIndexOf(by, bx);
    final kXAc = cfl.kXRegion[regionIdx], kBAc = cfl.kBRegion[regionIdx];
    for (var y = 0; y < n; y++) {
      final isLlfRow = y < llfH;
      for (var x = 0; x < n; x++) {
        final yv = coeffBuf[1][y][x];
        final isLlf = isLlfRow && x < llfW;
        final kX = isLlf ? cfl.kXGlobal : kXAc;
        final kB = isLlf ? cfl.kBGlobal : kBAc;
        coeffBuf[0][y][x] -= kX * yv;
        coeffBuf[2][y][x] -= kB * yv;
      }
    }
    return coeffBuf;
  }

  /// Quantizes an already-computed [coeffBuf] with a specific candidate
  /// [mult], *without* committing anything (no mutation of this block or
  /// any output array) — used by the RD-hfMult search to score several
  /// candidates before picking one (see [commit]). Also returns the
  /// weighted-squared-error distortion this candidate would introduce
  /// (see `_chooseHfMultRd`'s doc comment for why weighted, not plain,
  /// MSE), computed in the same loop as quantization to avoid a second
  /// pass over the coefficients.
  ({List<double> dc, List<Int32List> ac, double distortion}) quantizeCandidate(
      List<List<Float32List>> coeffBuf,
      int mult,
      List<double> sd,
      List<List<Float32List>> rawWeight,
      List<double> scaleFactor) {
    final n = tt.pixelHeight;
    final llfH = tt.dctSelectHeight, llfW = tt.dctSelectWidth;
    final numBlocks = llfH * llfW;

    // DC/LLF: invert the decoder's forward-DCT-of-DC-values relationship
    // (trivial identity when numBlocks == 1). Unaffected by `mult` — DC
    // uses its own dedicated scale (`sd`), never `hfMult`.
    final List<double> dc;
    if (numBlocks == 1) {
      dc = [for (var c = 0; c < 3; c++) coeffBuf[c][0][0] / sd[c]];
    } else {
      // numBlocks == 4 (16x16): coeffBuf[c][0][0..1] and [1][0..1] are the
      // true LLF corner (row-major); llfScale is also row-major. Flat
      // layout: index c * 4 + {0: top-left, 1: top-right, 2: bottom-left,
      // 3: bottom-right} of the 2x2 DC-plane patch, matching [commit].
      dc = List<double>.filled(12, 0);
      for (var c = 0; c < 3; c++) {
        final pre00 = coeffBuf[c][0][0] / tt.llfScale[0];
        final pre01 = coeffBuf[c][0][1] / tt.llfScale[1];
        final pre10 = coeffBuf[c][1][0] / tt.llfScale[2];
        final pre11 = coeffBuf[c][1][1] / tt.llfScale[3];
        dc[c * 4] = (pre00 + pre01 + pre10 + pre11) / sd[c];
        dc[c * 4 + 1] = (pre00 - pre01 + pre10 - pre11) / sd[c];
        dc[c * 4 + 2] = (pre00 + pre01 - pre10 - pre11) / sd[c];
        dc[c * 4 + 3] = (pre00 - pre01 - pre10 + pre11) / sd[c];
      }
    }

    final ac = [for (var c = 0; c < 3; c++) Int32List(n * n)];
    var distortion = 0.0;
    for (var c = 0; c < 3; c++) {
      final acc = ac[c];
      final rw = rawWeight[c];
      final sfc = scaleFactor[c] / mult;
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          if (y < llfH && x < llfW) continue;
          final w = rw[y][x];
          final step = sfc / w;
          final trueVal = coeffBuf[c][y][x];
          final qval = (trueVal / step).round();
          acc[y * n + x] = qval;
          final err = trueVal - qval * step;
          distortion += (w * err) * (w * err);
        }
      }
    }
    return (dc: dc, ac: ac, distortion: distortion);
  }

  /// Commits a [quantizeCandidate] result as this block's real,
  /// bitstream-bound quantization: writes DC into [dcInt] and sets
  /// [hfMult]/[acInt].
  void commit(
      ({List<double> dc, List<Int32List> ac, double distortion}) candidate,
      int mult,
      List<Int32List> dcInt,
      int bw) {
    hfMult = mult;
    acInt = candidate.ac;
    final numBlocks = tt.dctSelectHeight * tt.dctSelectWidth;
    if (numBlocks == 1) {
      for (var c = 0; c < 3; c++) {
        dcInt[c][by * bw + bx] = candidate.dc[c].round();
      }
    } else {
      for (var c = 0; c < 3; c++) {
        dcInt[c][by * bw + bx] = candidate.dc[c * 4].round();
        dcInt[c][by * bw + bx + 1] = candidate.dc[c * 4 + 1].round();
        dcInt[c][(by + 1) * bw + bx] = candidate.dc[c * 4 + 2].round();
        dcInt[c][(by + 1) * bw + bx + 1] = candidate.dc[c * 4 + 3].round();
      }
    }
  }

  /// Default (non-RD-search) path: compute coefficients, choose `hfMult`
  /// via the L2 adaptive-energy heuristic (smooth/low-energy blocks get a
  /// boost — hfMultiplier can only refine *finer* than the baseline, dequant
  /// being inversely proportional to it, see doc/spec_notes.md), quantize,
  /// commit.
  void computeAndQuantize(
      List<List<Float32List>> planes,
      _ChromaFromLumaFit cfl,
      double refStep,
      List<double> sd,
      List<List<Float32List>> rawWeight,
      List<double> scaleFactor,
      List<Int32List> dcInt,
      int bw,
      List<Float32List> scratch8a,
      List<Float32List> scratch8b,
      List<Float32List> scratch16a,
      List<Float32List> scratch16b) {
    final coeffBuf = computeCoeffBuf(
        planes, cfl, scratch8a, scratch8b, scratch16a, scratch16b);
    final n = tt.pixelHeight;
    final llfH = tt.dctSelectHeight, llfW = tt.dctSelectWidth;

    var acEnergy = 0.0;
    final y1 = coeffBuf[1];
    for (var y = 0; y < n; y++) {
      final row = y1[y];
      for (var x = 0; x < n; x++) {
        if (y < llfH && x < llfW) continue;
        acEnergy += row[x] * row[x];
      }
    }
    final relEnergy = math.sqrt(acEnergy) / refStep;
    final mult = relEnergy < 1.0
        ? 4
        : relEnergy < 4.0
            ? 2
            : 1;

    final candidate =
        quantizeCandidate(coeffBuf, mult, sd, rawWeight, scaleFactor);
    commit(candidate, mult, dcInt, bw);
  }
}

/// Per-transform-type context/order data, shared by every block of that
/// type (`blockCtx` only depends on channel/orderID/hfMult/lfIndex, and the
/// default HfBlockContext's empty qfThresholds make the hfMult argument a
/// no-op regardless of the real per-block adaptive multiplier).
class _TransformCtx {
  _TransformCtx(this.tt, HfBlockContext hfctx)
      : blockCtx = [
          for (var c = 0; c < 3; c++)
            HfCoefficients.getBlockContext(hfctx, c, tt.orderID, 1, 0),
        ],
        order = getNaturalOrder(tt.orderID) {
    histCtx = [for (final b in blockCtx) 458 * b + 37 * hfctx.numClusters];
  }

  final TransformType tt;
  final List<int> blockCtx;
  late final List<int> histCtx;
  final Int32List order;
  int get numBlocks => tt.dctSelectHeight * tt.dctSelectWidth;
  int get orderSize => tt.pixelHeight * tt.pixelWidth;
}

Uint8List _assembleGroupSection(
    EntropyCodes codes, List<int> mappedClusters, List<int> values) {
  final w = BitWriter();
  _writeAcGroupPayload(w, codes, mappedClusters, values);
  return w.toBytes();
}

void _writeVardctFrameHeader(BitWriter w, VardctL0Config config) {
  w.writeBool(false); // all_default
  w.writeBits(FrameFlags.regularFrame, 2); // type
  w.writeBits(FrameFlags.vardct, 1); // encoding
  // skipAdaptiveLfSmoothing: the encoder already chose the DC values it
  // wants decoded; the decoder's 5-tap LF smoothing filter would otherwise
  // perturb them by an amount independent of (and often larger than) the
  // quantization step, putting a content-dependent floor under the
  // achievable RMSE regardless of how finely AC/DC are quantized.
  w.writeU64(FrameFlags.skipAdaptiveLfSmoothing); // flags
  // do_YCbCr: not present (parent.xybEncoded == true).
  w.writeBits(0, 2); // upsampling = 1x
  // ec_upsampling: none (0 extra channels).
  // group_size_shift: not present for VarDCT (decoder hardcodes 1).
  w.writeBits(config.xqmScale, 3);
  w.writeBits(config.bqmScale, 3);
  w.writeU32(1, 1, 0, 2, 0, 3, 0, 4, 3); // passes.num_passes = 1
  // lf_level: not present (type != lfFrame).
  w.writeBool(false); // have_crop
  w.writeU32(0, 0, 0, 1, 0, 2, 0, 3, 2); // blending_info.mode = replace
  // duration/timecode: not present (not animated).
  w.writeBool(true); // is_last
  // save_as_reference / save_before_ct: not present (isLast == true).
  w.writeU32(0, 0, 0, 0, 4, 16, 5, 48, 10); // name_length = 0
  // RestorationFilter: explicit (the frame header's own all_default is
  // already false for other reasons, so this can't use its shortcut
  // either way). When enabled, every sub-field still takes its own
  // library default (customGab/epfSharpCustom/epfWeightCustom/
  // epfSigmaCustom all false) — only gab and epfIterations flip on.
  w.writeBool(false); // restoration_filter.all_default
  w.writeBool(config.enableFilters); // gab
  if (config.enableFilters) {
    w.writeBool(false); // customGab -> default gab1/gab2 weights
    w.writeBits(2, 2); // epf_iterations = 2 (library default)
    w.writeBool(false); // epfSharpCustom -> default sharpLut
    w.writeBool(false); // epfWeightCustom -> default channel scale
    w.writeBool(false); // epfSigmaCustom -> default sigma scales
  } else {
    w.writeBits(0, 2); // epf_iterations = 0
  }
  w.writeU64(0); // restoration_filter extensions
  w.writeU64(0); // frame extensions
}

/// [kX]/[kB] are this image's globally-optimal chroma-from-luma
/// coefficients (see `_chromaFromLumaFit`), written as a custom (not
/// default) LfChannelCorrelation with `xFactorLF`/`bFactorLF` left at
/// their neutral defaults so `baseCorrelationX`/`baseCorrelationB` (the
/// only F16 fields) equal [kX]/[kB] exactly at the DC
/// (`lf_coefficients.dart`) stage — DC/LF never varies per region (see
/// `_ChromaFromLumaFit`'s doc comment) — and serve as the *base* that HF's
/// per-64x64-region delta (`xFromY`/`bFromY`, written in
/// `_writeHfMetadata`) is layered on top of.
void _writeLfGlobal(BitWriter w, VardctL0Config config, double kX, double kB) {
  w.writeBool(true); // LfChannelDequantization.all_default
  w.writeU32(config.globalScale, 1, 11, 2049, 11, 4097, 12, 8193, 16);
  w.writeU32(config.quantLF, 16, 0, 1, 5, 1, 8, 1, 16);
  w.writeBool(true); // HfBlockContext default
  w.writeBool(false); // LfChannelCorrelation.all_default
  w.writeU32(_colorFactor, 84, 0, 256, 0, 2, 8, 258, 16);
  w.writeF16(kX); // baseCorrelationX
  w.writeF16(kB); // baseCorrelationB
  w.writeBits(128, 8); // xFactorLF = 128 (neutral: (128-128)/colorFactor == 0)
  w.writeBits(128, 8); // bFactorLF = 128 (neutral)
  w.writeBool(false); // hasGlobalTree
  // Global modular stream: 0 extra channels -> 0 bits (ModularStream.read
  // short-circuits when channelCount == 0).
}

/// Result of [_chromaFromLumaFit]: a global (whole-image) fit, used for
/// `baseCorrelationX`/`baseCorrelationB` and always for DC/LLF (the
/// decoder's `xFactorLF` stays a single per-frame value — see
/// `_writeLfGlobal`'s doc comment), plus a per-region fit for every
/// `corrH x corrW` 64x64-pixel region, used for true AC coefficients only
/// (see `_ChromaFromLumaFit`'s doc comment on why DC never sees the
/// per-region value).
class _ChromaFromLumaFit {
  _ChromaFromLumaFit(
      this.kXGlobal, this.kBGlobal, this.kXRegion, this.kBRegion, this.corrW);
  final double kXGlobal;
  final double kBGlobal;
  final Float64List kXRegion;
  final Float64List kBRegion;
  final int corrW;

  int regionIndexOf(int by, int bx) => (by >> 3) * corrW + (bx >> 3);
}

/// Finds the least-squares-optimal linear chroma-from-luma slopes (X on Y,
/// B on Y) both globally (whole image) and per 64x64-pixel (8x8-block)
/// region, over every native 8x8 block's raw (pre-correlation) AC DCT
/// coefficients (DC excluded — see doc/spec_notes.md's note on why DC
/// pollutes an AC-relevant fit) — one forward-DCT pass serves both, since
/// the per-region sums are simply a finer-grained partition of the same
/// terms the global sums accumulate.
///
/// The decoder only ever varies chroma-from-luma per-region at the HF (AC)
/// stage (`hf_coefficients.dart`'s `_chromaFromLuma`, driven by
/// `HfMetadata`'s `xFromY`/`bFromY`); DC/LF always uses the single global
/// `baseCorrelationX`/`baseCorrelationB` (`lf_coefficients.dart`), and
/// critically `_chromaFromLuma` runs *before* `_finalizeLLF` in the
/// decoder, at which point a block's LLF/DC positions are still zero — so
/// the per-region correction is a no-op there and gets overwritten by the
/// DC-derived LLF value immediately after. This encoder's own 16x16 LLF
/// inversion (`_PlacedBlock.computeAndQuantize`) must therefore keep using
/// the *global* slope for the LLF corner even though true AC coefficients
/// in the same block use the region's slope. Regions with too little AC
/// energy to fit reliably fall back to the global slope (a zero
/// `xFromY`/`bFromY` delta).
_ChromaFromLumaFit _chromaFromLumaFit(List<List<Float32List>> planes, int bh,
    int bw, List<Float32List> scratch0, List<Float32List> scratch1) {
  final corrH = (bh + 7) ~/ 8;
  final corrW = (bw + 7) ~/ 8;
  var sumYXGlobal = 0.0, sumYBGlobal = 0.0, sumYYGlobal = 0.0;
  final sumYXRegion = Float64List(corrH * corrW);
  final sumYBRegion = Float64List(corrH * corrW);
  final sumYYRegion = Float64List(corrH * corrW);
  final coeff = [
    for (var c = 0; c < 3; c++) List.generate(8, (_) => Float32List(8))
  ];
  for (var by = 0; by < bh; by++) {
    final regionRow = by >> 3;
    for (var bx = 0; bx < bw; bx++) {
      final regionIdx = regionRow * corrW + (bx >> 3);
      for (var c = 0; c < 3; c++) {
        forwardDCT2D(planes[c], coeff[c], by * 8, bx * 8, 0, 0, 8, 8, scratch0,
            scratch1);
      }
      for (var y = 0; y < 8; y++) {
        final xRow = coeff[0][y], yRow = coeff[1][y], bRow = coeff[2][y];
        for (var x = 0; x < 8; x++) {
          if (y == 0 && x == 0) continue; // DC has its own dedicated scale
          final yv = yRow[x];
          final yx = yv * xRow[x], yb = yv * bRow[x], yy = yv * yv;
          sumYXGlobal += yx;
          sumYBGlobal += yb;
          sumYYGlobal += yy;
          sumYXRegion[regionIdx] += yx;
          sumYBRegion[regionIdx] += yb;
          sumYYRegion[regionIdx] += yy;
        }
      }
    }
  }
  // Flat image: fall back to the format's own neutral defaults.
  final (kXGlobal, kBGlobal) = sumYYGlobal < 1e-12
      ? (0.0, 1.0)
      : (sumYXGlobal / sumYYGlobal, sumYBGlobal / sumYYGlobal);
  final kXRegion = Float64List(corrH * corrW);
  final kBRegion = Float64List(corrH * corrW);
  for (var i = 0; i < corrH * corrW; i++) {
    // A region with little AC energy has too few (or too small) samples to
    // fit a reliable slope; falling back to the global value costs nothing
    // (a zero xFromY/bFromY delta) and avoids fitting noise.
    if (sumYYRegion[i] < 1e-6) {
      kXRegion[i] = kXGlobal;
      kBRegion[i] = kBGlobal;
    } else {
      kXRegion[i] = sumYXRegion[i] / sumYYRegion[i];
      kBRegion[i] = sumYBRegion[i] / sumYYRegion[i];
    }
  }
  return _ChromaFromLumaFit(kXGlobal, kBGlobal, kXRegion, kBRegion, corrW);
}

/// Writes a modular sub-stream using [predictor] (default 0 == Zero, so
/// `prediction == 0` always and every decoded pixel equals exactly
/// `unpackSigned(symbol)`; see `_gradientResiduals` for the non-zero-
/// predictor case). Offset 0, multiplier 1 always: the decoder reconstructs
/// `trueValue = unpackSigned(symbol) + prediction(...)`
/// (`modular/modular_channel.dart`'s decode loop), so [channelsInOrder]
/// must already be in that residual domain for [predictor] != 0.
///
/// With [tree] null, uses a single-leaf MA tree (one shared histogram for
/// the whole stream) — the original L0/L1/L2 behavior. With [tree] given
/// (a real learned context tree, [tree.contexts] leaves), serializes it via
/// [serializeContextTree] and routes each channel's values to the
/// per-pixel context in the matching entry of [contexts] (same shape as
/// [channelsInOrder]) — the same `EntropyWriter`/cluster-map machinery the
/// lossless encoder's learned tree already uses (identity cluster map, the
/// complex nested-stream form kicking in automatically above 8 contexts).
void _writeModularStream(BitWriter w, List<List<int>> channelsInOrder,
    {int predictor = 0, ContextTree? tree, List<List<int>>? contexts}) {
  w.writeBool(false); // use_global_tree
  w.writeBool(true); // wp_params default
  w.writeU32(0, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 0
  if (tree != null) {
    serializeContextTree(w, tree, predictor);
  } else {
    final treeTokens = EntropyWriter(6);
    treeTokens.write(1, 0); // property + 1 == 0 -> leaf
    treeTokens.write(2, predictor);
    treeTokens.write(3, 0); // offset = packSigned(0) = 0
    treeTokens.write(4, 0); // mulLog = 0
    treeTokens.write(5, 0); // mulBits = 0 -> multiplier = 1
    treeTokens.finalize(w);
  }
  final residuals = EntropyWriter(tree?.contexts ?? 1);
  for (var c = 0; c < channelsInOrder.length; c++) {
    final channel = channelsInOrder[c];
    final channelContexts = contexts?[c];
    for (var i = 0; i < channel.length; i++) {
      residuals.write(channelContexts?[i] ?? 0, _packSigned(channel[i]));
    }
  }
  residuals.finalize(w);
}

/// Computes predictor-5 (clamped gradient: `clamp(w + n - nw, min(w, n),
/// max(w, n))`, with the same edge-of-image fallbacks as
/// `modular_channel.dart`'s `prediction(y, x, 5)`) residuals for a flat,
/// row-major `width`-wide grid — the *exact* mirror of that decode-side
/// formula (verified directly against `_west`/`_north`/`_northWest`'s edge
/// cases; also the same formula `encoder.dart`'s lossless `_tileResiduals`
/// already uses and gates bit-exact against djxl). DC (LF) values are
/// highly spatially correlated between neighboring blocks — real image
/// content rarely jumps in average brightness/color block to block — so
/// this alone removes most of the redundancy the previous predictor-0
/// (no prediction at all) left on the table; see doc/spec_notes.md for
/// the measured effect (DC was over half of total file size on
/// photographic content before this).
List<int> _gradientResiduals(Int32List values, int width) {
  final height = values.length ~/ width;
  final residuals = List<int>.filled(values.length, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = y * width + x;
      final w = x > 0
          ? values[o - 1]
          : y > 0
              ? values[o - width]
              : 0;
      final n = y > 0 ? values[o - width] : w;
      final nw = x > 0 && y > 0 ? values[o - width - 1] : w;
      final grad = w + n - nw;
      final lo = w < n ? w : n;
      final hi = w > n ? w : n;
      final pred = grad < lo
          ? lo
          : grad > hi
              ? hi
              : grad;
      residuals[o] = values[o] - pred;
    }
  }
  return residuals;
}

/// LfGroup section, part 1: the DC/LF coefficient image. [dcX]/[dcY]/[dcB]
/// are semantic-channel-indexed, block-raster-order (by * bw + bx) integer
/// DC values, [width] wide; the modular sub-stream itself is written in
/// the decoder's Y, X, B channel order (`vardct/lf_coefficients.dart`'s
/// `cMap`). Tries predictor 5 (clamped gradient, `_gradientResiduals`)
/// and predictor 6 (self-correcting weighted, `wpTileResiduals` — the
/// exact same decoder-verified computation `encoder.dart`'s lossless
/// path already uses), each with its OWN learned context tree (property
/// splitting over all three channels together, exactly
/// `encoder.dart`'s `bestForPredictor`/learned-tree pattern for the
/// lossless path — same `context_tree.dart` machinery, same property
/// sets, legal here because the decoder's DC/LF stream is decoded via the
/// same generic modular-channel path as lossless, per-LF-group-local, and
/// none of `gradProperties`/`wpProperties` cross a channel boundary), and
/// keeps whichever assembles smaller real bytes. WP tends to win on
/// photographic/tonal content, gradient on flatter content, and DC planes
/// see both depending on image and channel (X/B are chroma-from-luma
/// residuals, often flatter than Y).
void _writeLfCoefficients(
    BitWriter w, Int32List dcX, Int32List dcY, Int32List dcB, int width) {
  w.writeBits(0, 2); // extraPrecision = 0
  final height = dcY.length ~/ width;
  final trueChannels = [dcY, dcX, dcB]; // decoder Y, X, B order

  // Builds one predictor's residuals/tree/contexts and a bits-only probe
  // (never actually appended anywhere — `_writeLfCoefficients` is not
  // byte-aligned within its section, so the real winner is re-emitted
  // directly into `w` from the same precomputed tree/contexts below rather
  // than copying a byte-aligned `probe.toBytes()`, which would corrupt
  // everything written after it).
  (BitWriter, List<Int32List>, ContextTree, List<List<int>>) buildCandidate(
      bool useWp) {
    final predictor = useWp ? 6 : 5;
    final properties = useWp ? wpProperties : gradProperties;
    final residuals = <Int32List>[];
    final maxErr = useWp ? <Int32List>[] : null;
    for (final ch in trueChannels) {
      if (useWp) {
        final res = Int32List(ch.length);
        final err = Int32List(ch.length);
        wpTileResiduals(ch, width, height, res, err);
        residuals.add(res);
        maxErr!.add(err);
      } else {
        residuals.add(Int32List.fromList(_gradientResiduals(ch, width)));
      }
    }

    // Learn a tree from every pixel of all three channels (small enough per
    // LF group — at most 256x256 DC values per channel — that no training
    // subsample is needed, unlike the lossless encoder's whole-image tree).
    final trainProps = <int>[];
    final trainTokens = <int>[];
    final props = Int32List(properties.length);
    for (var c = 0; c < 3; c++) {
      final ch = trueChannels[c];
      final err = maxErr?[c];
      final res = residuals[c];
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final o = y * width + x;
          computeProps(
              ch, width, height, y, x, properties, err?[o] ?? 0, props);
          trainProps.addAll(props);
          trainTokens.add(tokenizeHybrid(
                  const HybridIntegerConfig(4, 1, 0), _packSigned(res[o]))
              .$1);
        }
      }
    }
    final tree = learnContextTree(Int32List.fromList(trainProps),
        Int32List.fromList(trainTokens), properties);

    final contexts = <List<int>>[];
    for (var c = 0; c < 3; c++) {
      final ch = trueChannels[c];
      final err = maxErr?[c];
      final ctxList = List<int>.filled(ch.length, 0);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final o = y * width + x;
          computeProps(
              ch, width, height, y, x, tree.properties, err?[o] ?? 0, props);
          ctxList[o] = contextFor(tree, props);
        }
      }
      contexts.add(ctxList);
    }

    final probe = BitWriter();
    _writeModularStream(probe, residuals,
        predictor: predictor, tree: tree, contexts: contexts);
    return (probe, residuals, tree, contexts);
  }

  final (gradProbe, gradResiduals, gradTree, gradContexts) =
      buildCandidate(false);
  final (wpProbe, wpResiduals, wpTree, wpContexts) = buildCandidate(true);
  if (wpProbe.bitsWritten < gradProbe.bitsWritten) {
    _writeModularStream(w, wpResiduals,
        predictor: 6, tree: wpTree, contexts: wpContexts);
  } else {
    _writeModularStream(w, gradResiduals,
        predictor: 5, tree: gradTree, contexts: gradContexts);
  }
}

/// LfGroup section, part 2: HfMetadata — the placed block list (8x8 and/or
/// 16x16, in raster-scan-with-skip order) with each block's real (adaptive)
/// quant multiplier, and the per-64x64-region chroma-from-luma delta
/// (`xFromY`/`bFromY`, an integer offset from `baseCorrelationX`/`B` scaled
/// by `colorFactor` — see `_ChromaFromLumaFit`'s doc comment). [bh]/[bw]
/// are this *LF group's own* (possibly edge-clamped) block extent;
/// [originBy]/[originBx] are its block-grid origin in the whole image,
/// used to slice the matching sub-rectangle out of [cfl]'s whole-image
/// per-region fit (region boundaries always align with LF group
/// boundaries: both are multiples of 8 blocks).
void _writeHfMetadata(
    BitWriter w,
    int bh,
    int bw,
    List<_PlacedBlock> placedBlocks,
    int originBy,
    int originBx,
    _ChromaFromLumaFit cfl) {
  final nbBlocks = placedBlocks.length;
  // The decoder doesn't know nbBlocks until *after* this read, so it sizes
  // the field from the LfGroup's full block count (bh * bw) — an upper
  // bound it does know ahead of time (nbBlocks <= bh * bw always, since
  // larger transforms only reduce the block count) — not from nbBlocks
  // itself (see hf_metadata.dart's `ceilLog2(bh * bw)`).
  final n = ceilLog2(bh * bw);
  w.writeBits(nbBlocks - 1, n);
  final corrH = (bh + 7) ~/ 8;
  final corrW = (bw + 7) ~/ 8;
  final regionRowOffset = originBy >> 3;
  final regionColOffset = originBx >> 3;
  final xFromY = [
    for (var ry = 0; ry < corrH; ry++)
      for (var rx = 0; rx < corrW; rx++)
        ((cfl.kXRegion[(regionRowOffset + ry) * cfl.corrW +
                        (regionColOffset + rx)] -
                    cfl.kXGlobal) *
                _colorFactor)
            .round(),
  ];
  final bFromY = [
    for (var ry = 0; ry < corrH; ry++)
      for (var rx = 0; rx < corrW; rx++)
        ((cfl.kBRegion[(regionRowOffset + ry) * cfl.corrW +
                        (regionColOffset + rx)] -
                    cfl.kBGlobal) *
                _colorFactor)
            .round(),
  ];
  final blockInfo = List<int>.filled(2 * nbBlocks, 0);
  for (var i = 0; i < nbBlocks; i++) {
    blockInfo[i] = placedBlocks[i].tt.type; // row0: transform type id
    blockInfo[nbBlocks + i] = placedBlocks[i].hfMult - 1; // row1: mult - 1
  }
  final sharpness = List<int>.filled(bh * bw, 0);
  _writeModularStream(w, [xFromY, bFromY, blockInfo, sharpness]);
}

/// HfGlobal + the single HfPass: quant weight tables (the library default
/// for every one of the 17 parameter slots when [customParamsByIndex] is
/// null; otherwise a custom `TransformMode.dct` table for each entry in
/// [customParamsByIndex] — this encoder only ever emits transform types
/// 0 (DCT8x8, parameter slot 0) and 4 (DCT16x16, parameter slot 4) — with
/// the library default for the other 15/16 slots, which costs 0 further
/// bits each), a single HF preset shared by every group (cheapest choice;
/// costs 0 bits only when [numGroups] == 1), and natural (unpermuted)
/// coefficient order.
void _writeHfGlobalAndPass(BitWriter w, int numGroups,
    Map<int, List<List<double>>>? customParamsByIndex) {
  w.writeBool(customParamsByIndex == null); // quant_all_default
  if (customParamsByIndex != null) {
    for (var index = 0; index < 17; index++) {
      final params = customParamsByIndex[index];
      if (params == null) {
        w.writeBits(TransformMode.library, 3); // 0 further bits
        continue;
      }
      w.writeBits(TransformMode.dct, 3);
      w.writeBits(params[0].length - 1, 4); // num_params - 1
      for (final p in params) {
        // p[0] is divided by 64 on read (hf_global.dart's _readDCTParams).
        w.writeF16(p[0] / 64.0);
        for (final v in p.skip(1)) {
          w.writeF16(v);
        }
      }
    }
  }
  w.writeBits(0, ceilLog1p(numGroups - 1)); // num_hf_presets = 1
  w.writeU32(0, 0x5F, 0, 0x13, 0, 0, 0, 0, 13); // usedOrders = 0
}

/// numHfPresets(1) * default HfBlockContext.numClusters(15) * 495 contexts
/// per (preset, cluster) — the domain size the decoder's cluster map
/// expects for the shared HfPass.contextStream (`hf_pass.dart:80-83`).
const _contextDomainSize = 495 * 15;

/// The bitstream caps the number of histograms in one entropy code; verified
/// empirically against djxl (256 works, 257+ is rejected even though this
/// decoder's own `EntropyStream.readClusterMap` has no such check).
const _maxHfClusters = 256;

/// One group's (context, value) token stream, in decode order.
class _GroupTokens {
  final List<int> contexts = [];
  final List<int> values = [];
}

/// Computes one (block, channel)'s AC coefficient tokens (the non-zero-
/// count token, then per-position coefficient tokens up to the last
/// non-zero position), appending to [contextsOut]/[valuesOut]. [predicted]
/// (the non-zero-count context prediction from neighboring blocks) is
/// supplied by the caller rather than computed here: `_computeGroupTokens`
/// derives it live from a running per-group grid, while the RD-search
/// rate estimate (`_blockRate`) scores multiple quantization candidates
/// against a *frozen* snapshot of that grid (see `_chooseHfMultRd`'s doc
/// comment for why). Returns this channel's real non-zero count, which
/// the caller needs to update its own prediction grid/bookkeeping.
int _blockChannelTokens(
    _TransformCtx ctx,
    HfBlockContext hfctx,
    int c,
    Int32List acData,
    int predicted,
    List<int> contextsOut,
    List<int> valuesOut) {
  final numBlocks = ctx.numBlocks;
  final orderSize = ctx.orderSize;
  final ucoeffLen = orderSize - numBlocks;
  final n = ctx.tt.pixelWidth;
  var countNonZero = 0;
  var lastNonZeroK = -1;
  final vals = List<int>.filled(ucoeffLen, 0);
  for (var k = 0; k < ucoeffLen; k++) {
    final o = ctx.order[k + numBlocks];
    final oy = o >> 16, ox = o & 0xFFFF;
    // flip == true for every square DCT this encoder emits: the scan's
    // (y, x) is transposed relative to the coefficient grid.
    final v = acData[ox * n + oy];
    vals[k] = v;
    if (v != 0) {
      countNonZero++;
      lastNonZeroK = k;
    }
  }

  final nonZeroCtx =
      HfCoefficients.getNonZeroContext(hfctx, predicted, ctx.blockCtx[c]);
  contextsOut.add(nonZeroCtx);
  valuesOut.add(countNonZero);

  var remaining = countNonZero;
  var prevNonzero = false;
  for (var k = 0; k <= lastNonZeroK; k++) {
    final prev =
        k == 0 ? (remaining > orderSize ~/ 16 ? 0 : 1) : (prevNonzero ? 1 : 0);
    final coefCtx = ctx.histCtx[c] +
        HfCoefficients.getCoefficientContext(
            k + numBlocks, remaining, numBlocks, prev);
    final u = _packSigned(vals[k]);
    contextsOut.add(coefCtx);
    valuesOut.add(u);
    prevNonzero = u != 0;
    if (prevNonzero) remaining--;
  }
  return countNonZero;
}

/// Computes one group's AC coefficient tokens, iterating [blocksInGroup] in
/// their global raster-scan-with-skip (placement) order — the decoder's
/// `HfCoefficients` iterates every block in that same global order,
/// skipping ones outside its own group, so relative order within a group
/// is preserved by construction. The non-zero prediction grid is local to
/// the group (in 8x8-cell units relative to the group's own origin,
/// [groupOriginY]/[groupOriginX]), mirroring a fresh `HfCoefficients` per
/// (pass, group) in the decoder. When [predictedOut] is given, records
/// each (block, channel)'s `predicted` value there — used by the RD-hfMult
/// search (`_chooseHfMultRd`) to freeze a bootstrap pass's prediction
/// context for scoring later candidates, without re-deriving it live.
_GroupTokens _computeGroupTokens(
    int groupOriginY,
    int groupOriginX,
    List<_PlacedBlock> blocksInGroup,
    HfBlockContext hfctx,
    Map<int, _TransformCtx> ctxByType,
    {Map<_PlacedBlock, Int32List>? predictedOut}) {
  final nonZeroesGrid = Int32List(3 * 32 * 32);
  final tokens = _GroupTokens();
  for (final block in blocksInGroup) {
    final ctx = ctxByType[block.tt.type]!;
    final localY = block.by - groupOriginY;
    final localX = block.bx - groupOriginX;
    final numBlocks = ctx.numBlocks;
    final predictedForBlock = predictedOut == null ? null : Int32List(3);
    for (final c in _channelOrder) {
      final predicted = HfCoefficients.getPredictedNonZeroes(
          nonZeroesGrid, c, localY, localX);
      predictedForBlock?[c] = predicted;
      final countNonZero = _blockChannelTokens(ctx, hfctx, c, block.acInt[c],
          predicted, tokens.contexts, tokens.values);
      final fill = (countNonZero + numBlocks - 1) ~/ numBlocks;
      for (var iy = 0; iy < block.tt.dctSelectHeight; iy++) {
        for (var ix = 0; ix < block.tt.dctSelectWidth; ix++) {
          nonZeroesGrid[c * 1024 + (localY + iy) * 32 + (localX + ix)] = fill;
        }
      }
    }
    if (predictedForBlock != null) predictedOut![block] = predictedForBlock;
  }
  return tokens;
}

/// A clustering choice: the shared entropy codes, the cluster map to write
/// once in HfGlobal's contextStream, and each group's tokens remapped from
/// raw context id to cluster id (ready to write with [EntropyCodes.writeToken]).
class _AcClustering {
  _AcClustering(this.codes, this.clusterMap, this.mappedClustersPerGroup);
  final EntropyCodes codes;
  final List<int> clusterMap;
  final List<List<int>> mappedClustersPerGroup;
}

/// Chooses how to cluster the (up to `_contextDomainSize`) distinct HF
/// coefficient contexts actually reached across every group into at most
/// [_maxHfClusters] histograms — a hard bitstream limit found empirically
/// against djxl (this decoder's own `EntropyStream.readClusterMap` does
/// not enforce it). Splitting is not free: each cluster costs a fixed
/// header (config + alphabet size + a prefix code table) independent of
/// its sample count, so for small images fewer, shared clusters can beat
/// more numerous ones. Rather than guess a budget, this tries a few and
/// assembles the actual bytes for each — the same "estimates can't
/// resolve near-ties, verify by real assembly" rule the lossless encoder
/// follows (see doc/spec_notes.md) — and keeps the smallest real total.
_AcClustering _chooseAcClustering(List<_GroupTokens> groups) {
  final freq = <int, int>{};
  for (final g in groups) {
    for (final ctx in g.contexts) {
      freq[ctx] = (freq[ctx] ?? 0) + 1;
    }
  }
  final byFrequency = freq.keys.toList()..sort((a, b) => freq[b]! - freq[a]!);
  final candidateBudgets = <int>{
    1,
    for (final b in [16, 64, _maxHfClusters])
      if (b < byFrequency.length) b,
    byFrequency.length.clamp(1, _maxHfClusters),
  };

  int totalBytes = -1;
  _AcClustering? best;
  for (final budget in candidateBudgets) {
    final clusterOf = <int, int>{};
    if (byFrequency.length <= budget) {
      for (final id in byFrequency) {
        clusterOf[id] = clusterOf.length;
      }
    } else {
      final kept = budget - 1;
      for (var i = 0; i < kept; i++) {
        clusterOf[byFrequency[i]] = i;
      }
      for (var i = kept; i < byFrequency.length; i++) {
        clusterOf[byFrequency[i]] = kept; // shared overflow cluster
      }
    }
    final numClustersUsed =
        byFrequency.length <= budget ? byFrequency.length : budget;
    final mappedClustersPerGroup = [
      for (final g in groups) [for (final ctx in g.contexts) clusterOf[ctx]!],
    ];
    final allMapped = [for (final m in mappedClustersPerGroup) ...m];
    final allValues = [for (final g in groups) ...g.values];
    final fullClusterMap = List<int>.filled(_contextDomainSize, 0);
    clusterOf.forEach((context, cluster) => fullClusterMap[context] = cluster);
    final codes =
        EntropyCodes.build(numClustersUsed, allMapped, allValues, _hfConfig);
    // writeHeader must run once before any writeToken call: it populates
    // the per-cluster canonical codes writeToken reads (mirrors how the
    // lossless encoder's `assemble()` always calls writeHeader first).
    final headerProbe = BitWriter();
    codes.writeHeader(headerProbe, clusterMap: fullClusterMap);
    var bytes = headerProbe.toBytes().length;

    // Each group becomes its own byte-aligned section when numGroups > 1,
    // so measure per-group padded size; for a single group this is the
    // same total either way.
    var valueIndex = 0;
    for (final mapped in mappedClustersPerGroup) {
      final probe = BitWriter();
      for (final m in mapped) {
        codes.writeToken(probe, m, allValues[valueIndex++]);
      }
      bytes += probe.toBytes().length;
    }

    if (best == null || bytes < totalBytes) {
      totalBytes = bytes;
      best = _AcClustering(codes, fullClusterMap, mappedClustersPerGroup);
    }
  }
  if (const bool.fromEnvironment('jxl.encdebug')) {
    // ignore: avoid_print
    print('vardct: groups=${groups.length} distinctContexts='
        '${byFrequency.length} bestBytes=$totalBytes');
  }
  return best!;
}

/// Rate estimate (bits) for a candidate quantization of one block: sums,
/// over both channels' token sequences, `codeLength + exactExtraBits` per
/// token. `codeLength` comes from [lengths] (a bootstrap pass's real,
/// already-built Huffman code lengths, indexed `[cluster][token]` — see
/// `_chooseHfMultRd`'s doc comment for why a frozen table, not a live
/// rebuild, is correct here) via [clusterMap] (dense, context -> cluster,
/// from that same bootstrap — `_chooseAcClustering`'s `fullClusterMap`,
/// which defaults unseen contexts to cluster 0; only an estimation-
/// accuracy question, not a correctness one, since the real bitstream is
/// built fresh afterward with the *final* chosen candidates' own real
/// clustering). `exactExtraBits` comes from `tokenizeHybrid` — a
/// closed-form, histogram-independent value, no table needed. A token
/// value larger than any seen in that cluster during the bootstrap (only
/// possible for a finer candidate than the bootstrap explored there)
/// falls back to 15 bits, the length-limited Huffman construction's own
/// cap (`huffmanLengths(hist, 15)`) — a real bound, not an arbitrary one.
double _blockRate(
    _TransformCtx ctx,
    HfBlockContext hfctx,
    List<Int32List> acIntCandidate,
    Int32List predictedPerChannel,
    List<int> clusterMap,
    List<List<int>> lengths) {
  var rate = 0.0;
  final contexts = <int>[];
  final values = <int>[];
  for (final c in _channelOrder) {
    contexts.clear();
    values.clear();
    _blockChannelTokens(ctx, hfctx, c, acIntCandidate[c],
        predictedPerChannel[c], contexts, values);
    for (var j = 0; j < contexts.length; j++) {
      final cluster = clusterMap[contexts[j]];
      final (token, extraBits, _) = tokenizeHybrid(_hfConfig, values[j]);
      final lens = lengths[cluster];
      final codeLen = token < lens.length ? lens[token] : 15;
      rate += codeLen + extraBits;
    }
  }
  return rate;
}

/// Candidate multipliers tried by the RD search — the same set the
/// default heuristic chooses from (see `_PlacedBlock.computeAndQuantize`),
/// so this isolates "does real RD scoring beat the ad hoc threshold at
/// the same discrete choice" as the only new variable (a wider candidate
/// set is deferred — see doc/spec_notes.md).
const _rdHfMultCandidates = [1, 2, 4];

/// Lagrange multiplier trading rate for distortion (`cost = distortion +
/// lambda * rate`), scaled by `refStep^2` (standard scalar-quantizer RD
/// theory: the rate/distortion trade-off's slope near a given step size
/// scales with step^2) so it stays consistent as `distance`/`acScale`
/// move the baseline step. The dimensionless constant has no formula to
/// mirror — pure encoder policy, calibrated empirically exactly like
/// `VardctL0Config.fromDistance` already is. `refStep` itself is tiny in
/// this encoder's units (~0.0018 at `distance = 1.0`, so `refStep^2` is
/// ~3e-6) while `distortion` (weighted-squared-error) and `rate` (bits)
/// are both O(1)-to-O(100) — so `kLambda` needs to be large (O(1e3)-
/// O(1e4)) to bring `lambda * rate` into the same range as `distortion`;
/// a naive small `kLambda` (e.g. this formula's superficial resemblance
/// to a [0.02, 5] range might suggest) has *zero* observable effect
/// since `lambda * rate` stays negligible regardless — confirmed by
/// direct measurement (sweeping `kLambda` from 0.02 to 10 produced
/// byte-identical output every time; sweeping 100 to 100000 produced the
/// expected monotonic size/RMSE trade-off).
///
/// **Calibration status: no value found clears both bars** (see
/// `tool/calibrate_rd_lambda.dart` and doc/spec_notes.md for the full
/// sweep and analysis) — this is why [VardctL0Config.enableRdHfMult]
/// stays off by default despite this machinery being implemented and
/// djxl-verified correct. Values around 10000-12000 genuinely beat the
/// L2 heuristic on real photo content (smaller *and* better RMSE), but
/// push the smooth-gradient banding-prevention test's RMSE to an
/// uncomfortable ~0.94-0.97 (a real regression from the heuristic's
/// comfortable margin there); values that keep gradient content safe
/// (~500) make photo content larger than the heuristic, not smaller.
/// Root cause (confirmed via `jxl.encdebug`'s hfMult histogram, not just
/// inferred): at the photo-favorable lambda, most gradient blocks shift
/// from the heuristic's aggressive `hfMult = 4` (which specifically
/// protects near-zero-AC-energy blocks from banding) down to `1`/`2` —
/// weighted-squared-error judges the *absolute* distortion saved by that
/// protection as not worth its bit cost, even though banding is far more
/// perceptually objectionable than its raw MSE contribution suggests.
/// This is a real modeling gap (a genuine perceptual/banding-aware term,
/// not just this constant, would be needed to close it), not a
/// calibration shortfall — see doc/spec_notes.md before spending more
/// time re-sweeping this constant.
const _kRdLambda = 3000.0;

/// Real per-block rate-distortion search replacing the crude 3-bucket
/// `hfMult` heuristic (`_PlacedBlock.computeAndQuantize`'s default path,
/// already run once by the time this is called — see step 5 of
/// `encodeLossyVardctL0`): scores every candidate in
/// [_rdHfMultCandidates] against a real distortion measure (weighted
/// squared error — `quantizeCandidate`'s `distortion`, weighted by the
/// same per-frequency `rawWeight` table quantization itself uses, since
/// that's exactly what the encoder already treats as perceptually
/// important) and a real rate estimate ([_blockRate]), picking the
/// minimizer of `distortion + lambda * rate`.
///
/// The rate estimate needs a real, already-built Huffman code-length
/// table, but that table depends on the very quantization decisions this
/// search is trying to make — resolved with a **bootstrap pass**: build a
/// real `_AcClustering` from the heuristic's own already-committed
/// choices, and *freeze* both its code-length table and its non-zero-
/// count prediction grid ([_computeGroupTokens]'s `predictedOut`) for
/// scoring every candidate. This is sound (not just convenient) because
/// `HfCoefficients.getBlockContext` only lets `hfMult` shift which
/// cluster a token routes to via `HfBlockContext.qfThresholds`, which
/// this encoder's always-used `HfBlockContext.defaults()` leaves empty —
/// so no candidate's *context* depends on which candidate wins, only the
/// *values* landing in that context do. The prediction grid is a real,
/// accepted approximation, though (a candidate other than the
/// heuristic's original choice could in principle shift a later block's
/// non-zero-count prediction) — see doc/spec_notes.md for the calibration
/// status and measured impact of that approximation.
void _chooseHfMultRd(
    List<_PlacedBlock> placedBlocks,
    List<List<Float32List>> planes,
    _ChromaFromLumaFit cfl,
    double refStep,
    List<double> sd,
    List<List<Float32List>> rawWeight8,
    List<List<Float32List>> rawWeight16,
    List<double> scaleFactor,
    List<Int32List> dcInt,
    int bw,
    List<Float32List> scratch8a,
    List<Float32List> scratch8b,
    List<Float32List> scratch16a,
    List<Float32List> scratch16b,
    HfBlockContext hfctx,
    Map<int, _TransformCtx> ctxByType,
    int groupsX,
    int groupsY,
    List<List<_PlacedBlock>> blocksByGroup,
    double? lambdaOverride) {
  final predictedOut = <_PlacedBlock, Int32List>{};
  final bootstrapTokens = <_GroupTokens>[
    for (var gy = 0; gy < groupsY; gy++)
      for (var gx = 0; gx < groupsX; gx++)
        _computeGroupTokens(gy * 32, gx * 32, blocksByGroup[gy * groupsX + gx],
            hfctx, ctxByType,
            predictedOut: predictedOut),
  ];
  final bootstrap = _chooseAcClustering(bootstrapTokens);
  final lengths = bootstrap.codes.tokenBitLengths();
  final clusterMap = bootstrap.clusterMap;
  final kLambda = lambdaOverride ?? _kRdLambda;
  final lambda = kLambda * refStep * refStep;

  final chosenHistogram = const bool.fromEnvironment('jxl.encdebug')
      ? <int, int>{for (final m in _rdHfMultCandidates) m: 0}
      : null;
  for (final block in placedBlocks) {
    final coeffBuf = block.computeCoeffBuf(
        planes, cfl, scratch8a, scratch8b, scratch16a, scratch16b);
    final rawWeight = block.tt == _tt16 ? rawWeight16 : rawWeight8;
    final ctx = ctxByType[block.tt.type]!;
    final predicted = predictedOut[block]!;

    var bestCost = double.infinity;
    var bestMult = _rdHfMultCandidates[0];
    ({List<double> dc, List<Int32List> ac, double distortion})? bestCandidate;
    for (final mult in _rdHfMultCandidates) {
      final candidate =
          block.quantizeCandidate(coeffBuf, mult, sd, rawWeight, scaleFactor);
      final rate =
          _blockRate(ctx, hfctx, candidate.ac, predicted, clusterMap, lengths);
      final cost = candidate.distortion + lambda * rate;
      if (cost < bestCost) {
        bestCost = cost;
        bestMult = mult;
        bestCandidate = candidate;
      }
    }
    block.commit(bestCandidate!, bestMult, dcInt, bw);
    if (chosenHistogram != null) {
      chosenHistogram[bestMult] = chosenHistogram[bestMult]! + 1;
    }
  }
  if (chosenHistogram != null) {
    // ignore: avoid_print
    print('vardct RD hfMult: lambda=$lambda chosen=$chosenHistogram');
  }
}

/// Writes the AC coefficient payload for one group using an already-built
/// clustering (its shared codes + this group's pre-mapped cluster ids).
void _writeAcGroupPayload(BitWriter w, EntropyCodes codes,
    List<int> mappedClusters, List<int> values) {
  for (var i = 0; i < values.length; i++) {
    codes.writeToken(w, mappedClusters[i], values[i]);
  }
}
