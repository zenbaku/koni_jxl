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
import '../entropy_writer.dart';
import '../headers.dart';
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
}

int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

const _hfConfig = HybridIntegerConfig(4, 1, 0);

/// Channel processing/bitstream order used throughout VarDCT: Y, X, B
/// (semantic indices 1, 0, 2 — see `frame/frame.dart`'s `cMap`).
const _channelOrder = [1, 0, 2];

final _tt8 = TransformType.byType(0); // DCT 8x8: orderID 0, parameterIndex 0
final _tt16 = TransformType.byType(4); // DCT 16x16: orderID 2, parameterIndex 4

/// `LfChannelCorrelation.colorFactor`: the resolution of the per-region HF
/// correlation delta (`xFromY`/`bFromY` in `_writeHfMetadata` — a stored
/// integer divided by this). 84 is the format's own default; shared here
/// so `_writeLfGlobal` (which writes it) and the per-region fit (which
/// must quantize deltas against the exact same value) can't drift apart.
const _colorFactor = 84;

/// Encodes an interleaved 8-bit RGB image as a VarDCT (lossy) JPEG XL
/// stream. Requires [width] and [height] to be multiples of 8 and at most
/// 2048 (single LF group; multi-LfGroup is not yet implemented — see
/// ROADMAP.md). Multiple 256x256 groups are supported.
Uint8List encodeLossyVardctL0(
  Uint8List rgbPixels, {
  required int width,
  required int height,
  VardctL0Config config = const VardctL0Config(),
}) {
  if (width % 8 != 0 || height % 8 != 0) {
    throw ArgumentError('requires width and height to be multiples of 8');
  }
  if (width > 2048 || height > 2048) {
    throw ArgumentError('supports at most 2048x2048 (single LF group)');
  }
  if (rgbPixels.length != width * height * 3) {
    throw ArgumentError('expected ${width * height * 3} bytes of RGB');
  }

  // 1. Deinterleave, linearize (sRGB EOTF) and transform to XYB in place.
  final planes = [
    for (var c = 0; c < 3; c++)
      List.generate(height, (_) => Float32List(width)),
  ];
  for (var y = 0; y < height; y++) {
    final rRow = planes[0][y], gRow = planes[1][y], bRow = planes[2][y];
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 3;
      rRow[x] = rgbPixels[o].toDouble();
      gRow[x] = rgbPixels[o + 1].toDouble();
      bRow[x] = rgbPixels[o + 2].toDouble();
    }
  }
  for (final plane in planes) {
    XybForward.srgbToLinear(plane);
  }
  XybForward().forward(planes[0], planes[1], planes[2]);

  final bh = height ~/ 8;
  final bw = width ~/ 8;

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

  // 6. AC coefficient tokens, one group at a time (each group is its own
  // 256x256-pixel / 32x32-block tile with an independent non-zero
  // prediction grid, mirroring a fresh HfCoefficients per (pass, group)).
  // Blocks never straddle a group boundary: groups are 32-block-aligned
  // (even) and 16x16 blocks only start at globally-even coordinates with a
  // 2x2 footprint, so a block's origin alone determines its group.
  final hfctx = HfBlockContext.defaults();
  final ctxByType = {
    for (final tt in [_tt8, _tt16]) tt.type: _TransformCtx(tt, hfctx),
  };
  final groupsX = ceilDiv(width, 256);
  final groupsY = ceilDiv(height, 256);
  final numGroups = groupsX * groupsY;
  final blocksByGroup = List<List<_PlacedBlock>>.generate(numGroups, (_) => []);
  for (final block in placedBlocks) {
    final g = (block.by ~/ 32) * groupsX + (block.bx ~/ 32);
    blocksByGroup[g].add(block);
  }
  final groupTokens = <_GroupTokens>[
    for (var gy = 0; gy < groupsY; gy++)
      for (var gx = 0; gx < groupsX; gx++)
        _computeGroupTokens(gy * 32, gx * 32, blocksByGroup[gy * groupsX + gx],
            hfctx, ctxByType),
  ];
  final clustering = _chooseAcClustering(groupTokens);

  // 7. Assemble the bitstream: image header, VarDCT frame header, then
  // either the single concatenated section body (numGroups == 1 forces
  // tocEntryCount == 1 — no byte alignment between LfGlobal / LfGroup /
  // HfGlobal+HfPass / PassGroup; see doc/lossy_encoder_plan.md's TOC
  // single-section note) or, for numGroups > 1, one independently
  // byte-aligned section per (LfGlobal, the single LfGroup, HfGlobal+
  // HfPass, and each group's PassGroup).
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

  if (numGroups == 1) {
    final body = BitWriter();
    _writeLfGlobal(body, config, cfl.kXGlobal, cfl.kBGlobal);
    _writeLfCoefficients(body, dcInt[0], dcInt[1], dcInt[2]);
    _writeHfMetadata(body, bh, bw, placedBlocks, cfl);
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

    final lfGroupW = BitWriter();
    _writeLfCoefficients(lfGroupW, dcInt[0], dcInt[1], dcInt[2]);
    _writeHfMetadata(lfGroupW, bh, bw, placedBlocks, cfl);

    final hfGlobalW = BitWriter();
    _writeHfGlobalAndPass(hfGlobalW, numGroups, customParamsByIndex);
    clustering.codes.writeHeader(hfGlobalW, clusterMap: clustering.clusterMap);

    final sections = <Uint8List>[
      lfGlobalW.toBytes(),
      lfGroupW.toBytes(), // numLfGroups == 1 (width/height <= 2048)
      hfGlobalW.toBytes(),
      for (var g = 0; g < numGroups; g++)
        _assembleGroupSection(clustering.codes,
            clustering.mappedClustersPerGroup[g], groupTokens[g].values),
    ];
    writeToc(out, [for (final s in sections) s.length]);
    for (final s in sections) {
      out.writeBytes(s);
    }
  }
  return out.toBytes();
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
  /// unused here — those come from the DC plane on decode.
  late final List<Int32List> acInt;

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
    final numBlocks = llfH * llfW;

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

    // Adaptive quantization: hfMultiplier can only refine *finer* than the
    // baseline (dequant is inversely proportional to it — see
    // doc/spec_notes.md), so smooth/low-energy blocks (where rounding AC to
    // zero causes visible banding) get a boost; busy blocks stay at the
    // baseline multiplier, since masking hides quantization noise there and
    // they already spend plenty of bits.
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
    hfMult = relEnergy < 1.0
        ? 4
        : relEnergy < 4.0
            ? 2
            : 1;

    // DC/LLF: invert the decoder's forward-DCT-of-DC-values relationship
    // (trivial identity when numBlocks == 1).
    if (numBlocks == 1) {
      for (var c = 0; c < 3; c++) {
        dcInt[c][by * bw + bx] = (coeffBuf[c][0][0] / sd[c]).round();
      }
    } else {
      // numBlocks == 4 (16x16): coeffBuf[c][0][0..1] and [1][0..1] are the
      // true LLF corner (row-major); llfScale is also row-major.
      for (var c = 0; c < 3; c++) {
        final pre00 = coeffBuf[c][0][0] / tt.llfScale[0];
        final pre01 = coeffBuf[c][0][1] / tt.llfScale[1];
        final pre10 = coeffBuf[c][1][0] / tt.llfScale[2];
        final pre11 = coeffBuf[c][1][1] / tt.llfScale[3];
        final p00 = pre00 + pre01 + pre10 + pre11;
        final p01 = pre00 - pre01 + pre10 - pre11;
        final p10 = pre00 + pre01 - pre10 - pre11;
        final p11 = pre00 - pre01 - pre10 + pre11;
        dcInt[c][by * bw + bx] = (p00 / sd[c]).round();
        dcInt[c][by * bw + bx + 1] = (p01 / sd[c]).round();
        dcInt[c][(by + 1) * bw + bx] = (p10 / sd[c]).round();
        dcInt[c][(by + 1) * bw + bx + 1] = (p11 / sd[c]).round();
      }
    }

    acInt = [for (var c = 0; c < 3; c++) Int32List(n * n)];
    for (var c = 0; c < 3; c++) {
      final ac = acInt[c];
      final rw = rawWeight[c];
      final sfc = scaleFactor[c] / hfMult;
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          if (y < llfH && x < llfW) continue;
          final step = sfc / rw[y][x];
          ac[y * n + x] = (coeffBuf[c][y][x] / step).round();
        }
      }
    }
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

/// Writes a modular sub-stream whose bitstream contents are simply
/// `packSigned(value)` per pixel, in channel-then-raster order: a
/// single-leaf MA tree (predictor 0 == Zero, so `prediction == 0` always;
/// offset 0; multiplier 1) makes every decoded pixel equal exactly
/// `unpackSigned(symbol)` (`modular/modular_channel.dart`'s decode loop).
void _writeTrivialModularStream(BitWriter w, List<List<int>> channelsInOrder) {
  w.writeBool(false); // use_global_tree
  w.writeBool(true); // wp_params default
  w.writeU32(0, 0, 0, 1, 0, 2, 4, 18, 8); // nb_transforms = 0
  final treeTokens = EntropyWriter(6);
  treeTokens.write(1, 0); // property + 1 == 0 -> leaf
  treeTokens.write(2, 0); // predictor = 0 (Zero)
  treeTokens.write(3, 0); // offset = packSigned(0) = 0
  treeTokens.write(4, 0); // mulLog = 0
  treeTokens.write(5, 0); // mulBits = 0 -> multiplier = 1
  treeTokens.finalize(w);
  final residuals = EntropyWriter(1);
  for (final channel in channelsInOrder) {
    for (final v in channel) {
      residuals.write(0, _packSigned(v));
    }
  }
  residuals.finalize(w);
}

/// LfGroup section, part 1: the DC/LF coefficient image. [dcX]/[dcY]/[dcB]
/// are semantic-channel-indexed, block-raster-order (by * bw + bx) integer
/// DC values; the modular sub-stream itself is written in the decoder's Y,
/// X, B channel order (`vardct/lf_coefficients.dart`'s `cMap`).
void _writeLfCoefficients(
    BitWriter w, Int32List dcX, Int32List dcY, Int32List dcB) {
  w.writeBits(0, 2); // extraPrecision = 0
  _writeTrivialModularStream(w, [dcY, dcX, dcB]);
}

/// LfGroup section, part 2: HfMetadata — the placed block list (8x8 and/or
/// 16x16, in raster-scan-with-skip order) with each block's real (adaptive)
/// quant multiplier, and the per-64x64-region chroma-from-luma delta
/// (`xFromY`/`bFromY`, an integer offset from `baseCorrelationX`/`B` scaled
/// by `colorFactor` — see `_ChromaFromLumaFit`'s doc comment).
void _writeHfMetadata(BitWriter w, int bh, int bw,
    List<_PlacedBlock> placedBlocks, _ChromaFromLumaFit cfl) {
  final nbBlocks = placedBlocks.length;
  // The decoder doesn't know nbBlocks until *after* this read, so it sizes
  // the field from the LfGroup's full block count (bh * bw) — an upper
  // bound it does know ahead of time (nbBlocks <= bh * bw always, since
  // larger transforms only reduce the block count) — not from nbBlocks
  // itself (see hf_metadata.dart's `ceilLog2(bh * bw)`).
  final n = ceilLog2(bh * bw);
  w.writeBits(nbBlocks - 1, n);
  // cfl.kXRegion/kBRegion are already sized corrH * corrW (see
  // _chromaFromLumaFit) — the same (bh+7)~/8 x (bw+7)~/8 grid HfMetadata's
  // xFromY/bFromY channels use.
  final xFromY = [
    for (var i = 0; i < cfl.kXRegion.length; i++)
      ((cfl.kXRegion[i] - cfl.kXGlobal) * _colorFactor).round(),
  ];
  final bFromY = [
    for (var i = 0; i < cfl.kBRegion.length; i++)
      ((cfl.kBRegion[i] - cfl.kBGlobal) * _colorFactor).round(),
  ];
  final blockInfo = List<int>.filled(2 * nbBlocks, 0);
  for (var i = 0; i < nbBlocks; i++) {
    blockInfo[i] = placedBlocks[i].tt.type; // row0: transform type id
    blockInfo[nbBlocks + i] = placedBlocks[i].hfMult - 1; // row1: mult - 1
  }
  final sharpness = List<int>.filled(bh * bw, 0);
  _writeTrivialModularStream(w, [xFromY, bFromY, blockInfo, sharpness]);
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

/// Computes one group's AC coefficient tokens, iterating [blocksInGroup] in
/// their global raster-scan-with-skip (placement) order — the decoder's
/// `HfCoefficients` iterates every block in that same global order,
/// skipping ones outside its own group, so relative order within a group
/// is preserved by construction. The non-zero prediction grid is local to
/// the group (in 8x8-cell units relative to the group's own origin,
/// [groupOriginY]/[groupOriginX]), mirroring a fresh `HfCoefficients` per
/// (pass, group) in the decoder.
_GroupTokens _computeGroupTokens(
    int groupOriginY,
    int groupOriginX,
    List<_PlacedBlock> blocksInGroup,
    HfBlockContext hfctx,
    Map<int, _TransformCtx> ctxByType) {
  final nonZeroesGrid = Int32List(3 * 32 * 32);
  final tokens = _GroupTokens();
  for (final block in blocksInGroup) {
    final ctx = ctxByType[block.tt.type]!;
    final localY = block.by - groupOriginY;
    final localX = block.bx - groupOriginX;
    final numBlocks = ctx.numBlocks;
    final orderSize = ctx.orderSize;
    final ucoeffLen = orderSize - numBlocks;
    final n = block.tt.pixelWidth;
    for (final c in _channelOrder) {
      final acData = block.acInt[c];
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

      final predicted = HfCoefficients.getPredictedNonZeroes(
          nonZeroesGrid, c, localY, localX);
      final nonZeroCtx =
          HfCoefficients.getNonZeroContext(hfctx, predicted, ctx.blockCtx[c]);
      tokens.contexts.add(nonZeroCtx);
      tokens.values.add(countNonZero);
      final fill = (countNonZero + numBlocks - 1) ~/ numBlocks;
      for (var iy = 0; iy < block.tt.dctSelectHeight; iy++) {
        for (var ix = 0; ix < block.tt.dctSelectWidth; ix++) {
          nonZeroesGrid[c * 1024 + (localY + iy) * 32 + (localX + ix)] = fill;
        }
      }

      var remaining = countNonZero;
      var prevNonzero = false;
      for (var k = 0; k <= lastNonZeroK; k++) {
        final prev = k == 0
            ? (remaining > orderSize ~/ 16 ? 0 : 1)
            : (prevNonzero ? 1 : 0);
        final coefCtx = ctx.histCtx[c] +
            HfCoefficients.getCoefficientContext(
                k + numBlocks, remaining, numBlocks, prev);
        final u = _packSigned(vals[k]);
        tokens.contexts.add(coefCtx);
        tokens.values.add(u);
        prevNonzero = u != 0;
        if (prevNonzero) remaining--;
      }
    }
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

/// Writes the AC coefficient payload for one group using an already-built
/// clustering (its shared codes + this group's pre-mapped cluster ids).
void _writeAcGroupPayload(BitWriter w, EntropyCodes codes,
    List<int> mappedClusters, List<int> values) {
  for (var i = 0; i < values.length; i++) {
    codes.writeToken(w, mappedClusters[i], values[i]);
  }
}
