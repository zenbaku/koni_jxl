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
import '../../vardct/transform_type.dart' show TransformMode;
import '../entropy_writer.dart';
import '../headers.dart';
import 'xyb_forward.dart';

/// Lossy (VarDCT) encoder (doc/lossy_encoder_plan.md's L0/L1/L2): 8x8-DCT
/// only, real HF coefficient context model, multi-group, adaptive
/// per-block quantization and a custom per-frequency quant weight table;
/// still filters-off and single-LfGroup (see ROADMAP.md for what's left).
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

  /// Multiplies the default DCT8x8 quant weight table (written as a custom
  /// `quant_all_default = false` table rather than relying on
  /// [globalScale], which has limited fine-quantization headroom). `1.0`
  /// reproduces the library default table exactly.
  final double acScale;
}

int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

const _hfConfig = HybridIntegerConfig(4, 1, 0);

/// Channel processing/bitstream order used throughout VarDCT: Y, X, B
/// (semantic indices 1, 0, 2 — see `frame/frame.dart`'s `cMap`).
const _channelOrder = [1, 0, 2];

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

  // 2. Quantization tables (mirroring the decoder's default DCT8x8 weights
  // and scale factors exactly; see doc/lossy_encoder_plan.md). Scaling
  // only the first (lowest-frequency) band by acScale scales the entire
  // interpolated weight table by the same factor (see
  // doc/spec_notes.md), giving a fineness knob with no ceiling — unlike
  // globalScale, whose bitstream field caps how much finer than baseline
  // it can reach.
  final customDctParams = [
    for (var c = 0; c < 3; c++)
      [
        defaultDctParams[0].dctParam![c][0] * config.acScale,
        ...defaultDctParams[0].dctParam![c].skip(1),
      ],
  ];
  final rawWeight = [
    for (var c = 0; c < 3; c++) getDCTQuantWeights(8, 8, customDctParams[c]),
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

  // 3. Per-block forward DCT, chroma-from-luma pre-subtraction, adaptive
  // quantization multiplier and quantization. dcInt/acInt are
  // semantic-indexed (0=X, 1=Y, 2=B); acInt blocks are flat 64-entry
  // (row-major y*8+x) grids, DC slot unused. hfMult is per-block, shared
  // across channels (mirrors HfMetadata's one multiplier per block).
  final dcInt = [for (var c = 0; c < 3; c++) Int32List(bh * bw)];
  final acInt = [
    for (var c = 0; c < 3; c++)
      List<Int32List>.generate(bh * bw, (_) => Int32List(64)),
  ];
  final hfMult = Int32List(bh * bw);
  final coeffBuf = [
    for (var c = 0; c < 3; c++) List.generate(8, (_) => Float32List(8))
  ];
  final scratch0 = List.generate(8, (_) => Float32List(8));
  final scratch1 = List.generate(8, (_) => Float32List(8));
  // Global chroma-from-luma: the least-squares-optimal X-on-Y and B-on-Y
  // slopes, applied uniformly (not yet per 64x64 region — see
  // _writeLfGlobal's doc comment) in place of the format's defaults
  // (kX = 0, kB = 1.0).
  final (kX, kB) = _globalChromaFromLuma(planes, bh, bw, scratch0, scratch1);
  // Reference AC step at the first (lowest-frequency, most perceptually
  // important) Y position: the scale against which "how smooth is this
  // block" is judged, so the heuristic adapts with `distance` instead of
  // using an absolute threshold tuned for one quantization strength.
  final refStep = scaleFactor[1] / rawWeight[1][0][1];
  for (var by = 0; by < bh; by++) {
    for (var bx = 0; bx < bw; bx++) {
      final blockIdx = by * bw + bx;
      for (var c = 0; c < 3; c++) {
        forwardDCT2D(planes[c], coeffBuf[c], by * 8, bx * 8, 0, 0, 8, 8,
            scratch0, scratch1);
      }
      // Chroma-from-luma: the decoder always adds kX/kB times the Y
      // coefficient into X/B, so that must be pre-subtracted here, at
      // every position including DC.
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final yv = coeffBuf[1][y][x];
          coeffBuf[0][y][x] -= kX * yv;
          coeffBuf[2][y][x] -= kB * yv;
        }
      }

      // Adaptive quantization: hfMultiplier can only refine *finer* than
      // the baseline (dequant is inversely proportional to it — see
      // doc/spec_notes.md), so smooth/low-energy blocks (where rounding
      // AC to zero causes visible banding) get a boost; busy blocks stay
      // at the baseline multiplier, since masking hides quantization
      // noise there and they already spend plenty of bits.
      var acEnergy = 0.0;
      final y1 = coeffBuf[1];
      for (var y = 0; y < 8; y++) {
        final row = y1[y];
        for (var x = 0; x < 8; x++) {
          if (y == 0 && x == 0) continue;
          acEnergy += row[x] * row[x];
        }
      }
      final relEnergy = math.sqrt(acEnergy) / refStep;
      final mult = relEnergy < 1.0
          ? 4
          : relEnergy < 4.0
              ? 2
              : 1;
      hfMult[blockIdx] = mult;

      for (var c = 0; c < 3; c++) {
        dcInt[c][blockIdx] = (coeffBuf[c][0][0] / sd[c]).round();
        final ac = acInt[c][blockIdx];
        final rw = rawWeight[c];
        final sfc = scaleFactor[c] / mult;
        for (var y = 0; y < 8; y++) {
          for (var x = 0; x < 8; x++) {
            if (y == 0 && x == 0) continue;
            final step = sfc / rw[y][x];
            ac[y * 8 + x] = (coeffBuf[c][y][x] / step).round();
          }
        }
      }
    }
  }

  // 4. AC coefficient tokens, one group at a time (each group is its own
  // 256x256-pixel / 32x32-block tile with an independent non-zero
  // prediction grid, mirroring a fresh HfCoefficients per (pass, group)).
  final order = getNaturalOrder(0); // DCT 8x8 has orderID 0.
  final hfctx = HfBlockContext.defaults();
  // blockCtx depends on (channel, orderID, hfMult, lfIndex), but the
  // default HfBlockContext has empty qfThresholds, so the hfMult argument
  // is a no-op (getBlockContext's threshold loop never runs) regardless of
  // the real per-block adaptive multiplier — it's constant per channel.
  final blockCtx = [
    for (var c = 0; c < 3; c++)
      HfCoefficients.getBlockContext(hfctx, c, 0, 1, 0),
  ];
  final histCtx = [for (final b in blockCtx) 458 * b + 37 * hfctx.numClusters];
  final groupsX = ceilDiv(width, 256);
  final groupsY = ceilDiv(height, 256);
  final numGroups = groupsX * groupsY;
  final groupTokens = <_GroupTokens>[
    for (var gy = 0; gy < groupsY; gy++)
      for (var gx = 0; gx < groupsX; gx++)
        _computeGroupTokens(
            gy * 32,
            gx * 32,
            math.min(32, bh - gy * 32),
            math.min(32, bw - gx * 32),
            bw,
            acInt,
            hfctx,
            blockCtx,
            histCtx,
            order),
  ];
  final clustering = _chooseAcClustering(groupTokens);

  // 5. Assemble the bitstream: image header, VarDCT frame header, then
  // either the single concatenated section body (numGroups == 1 forces
  // tocEntryCount == 1 — no byte alignment between LfGlobal / LfGroup /
  // HfGlobal+HfPass / PassGroup; see doc/lossy_encoder_plan.md's TOC
  // single-section note) or, for numGroups > 1, one independently
  // byte-aligned section per (LfGlobal, the single LfGroup, HfGlobal+
  // HfPass, and each group's PassGroup).
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
    _writeLfGlobal(body, config, kX, kB);
    _writeLfCoefficients(body, dcInt[0], dcInt[1], dcInt[2]);
    _writeHfMetadata(body, bh, bw, hfMult);
    _writeHfGlobalAndPass(
        body, numGroups, config.acScale == 1.0 ? null : customDctParams);
    clustering.codes.writeHeader(body, clusterMap: clustering.clusterMap);
    _writeAcGroupPayload(body, clustering.codes,
        clustering.mappedClustersPerGroup[0], groupTokens[0].values);
    final bodyBytes = body.toBytes();
    writeToc(out, [bodyBytes.length]);
    out.writeBytes(bodyBytes);
  } else {
    final lfGlobalW = BitWriter();
    _writeLfGlobal(lfGlobalW, config, kX, kB);

    final lfGroupW = BitWriter();
    _writeLfCoefficients(lfGroupW, dcInt[0], dcInt[1], dcInt[2]);
    _writeHfMetadata(lfGroupW, bh, bw, hfMult);

    final hfGlobalW = BitWriter();
    _writeHfGlobalAndPass(
        hfGlobalW, numGroups, config.acScale == 1.0 ? null : customDctParams);
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
  // RestorationFilter: explicit, everything off (defaults() has Gaborish
  // and 2 EPF iterations on, so the top-level all_default shortcut can't
  // be used).
  w.writeBool(false); // restoration_filter.all_default
  w.writeBool(false); // gab
  w.writeBits(0, 2); // epf_iterations
  w.writeU64(0); // restoration_filter extensions
  w.writeU64(0); // frame extensions
}

/// [kX]/[kB] are this image's globally-optimal chroma-from-luma
/// coefficients (see `_globalChromaFromLuma`), written as a custom (not
/// default) LfChannelCorrelation with `colorFactor`/`xFactorLF`/
/// `bFactorLF` left at their neutral defaults so `baseCorrelationX`/
/// `baseCorrelationB` (the only F16 fields) equal [kX]/[kB] exactly at
/// both the DC (`lf_coefficients.dart`) and HF (`hf_coefficients.dart`)
/// stages — this encoder does not yet vary the correlation per 64x64
/// region (`xFromY`/`bFromY` stay 0 in `_writeHfMetadata`), only globally.
void _writeLfGlobal(BitWriter w, VardctL0Config config, double kX, double kB) {
  w.writeBool(true); // LfChannelDequantization.all_default
  w.writeU32(config.globalScale, 1, 11, 2049, 11, 4097, 12, 8193, 16);
  w.writeU32(config.quantLF, 16, 0, 1, 5, 1, 8, 1, 16);
  w.writeBool(true); // HfBlockContext default
  w.writeBool(false); // LfChannelCorrelation.all_default
  w.writeU32(84, 84, 0, 256, 0, 2, 8, 258, 16); // colorFactor = 84 (default)
  w.writeF16(kX); // baseCorrelationX
  w.writeF16(kB); // baseCorrelationB
  w.writeBits(128, 8); // xFactorLF = 128 (neutral: (128-128)/84 == 0)
  w.writeBits(128, 8); // bFactorLF = 128 (neutral)
  w.writeBool(false); // hasGlobalTree
  // Global modular stream: 0 extra channels -> 0 bits (ModularStream.read
  // short-circuits when channelCount == 0).
}

/// Finds the globally-optimal linear chroma-from-luma coefficients
/// (least-squares slope of X on Y, and B on Y) over every block's raw
/// (pre-correlation) DCT coefficients, DC included — the decoder applies
/// the same `baseCorrelationX`/`baseCorrelationB` uniformly to DC
/// (`lf_coefficients.dart`) and HF (`hf_coefficients.dart`) alike.
(double, double) _globalChromaFromLuma(List<List<Float32List>> planes, int bh,
    int bw, List<Float32List> scratch0, List<Float32List> scratch1) {
  var sumYX = 0.0, sumYB = 0.0, sumYY = 0.0;
  final coeff = [
    for (var c = 0; c < 3; c++) List.generate(8, (_) => Float32List(8))
  ];
  for (var by = 0; by < bh; by++) {
    for (var bx = 0; bx < bw; bx++) {
      for (var c = 0; c < 3; c++) {
        forwardDCT2D(planes[c], coeff[c], by * 8, bx * 8, 0, 0, 8, 8, scratch0,
            scratch1);
      }
      for (var y = 0; y < 8; y++) {
        final xRow = coeff[0][y], yRow = coeff[1][y], bRow = coeff[2][y];
        for (var x = 0; x < 8; x++) {
          if (y == 0 && x == 0) continue; // DC has its own dedicated scale
          final yv = yRow[x];
          sumYX += yv * xRow[x];
          sumYB += yv * bRow[x];
          sumYY += yv * yv;
        }
      }
    }
  }
  if (sumYY < 1e-12) return (0.0, 1.0); // flat image: fall back to defaults
  return (sumYX / sumYY, sumYB / sumYY);
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

/// LfGroup section, part 2: HfMetadata — every block is a plain 8x8 DCT
/// (transform type id 0) with a real (adaptive) quant multiplier and zero
/// chroma-from-luma.
void _writeHfMetadata(BitWriter w, int bh, int bw, Int32List hfMult) {
  final nbBlocks = bh * bw;
  final n = ceilLog2(nbBlocks);
  w.writeBits(nbBlocks - 1, n);
  final corrH = (bh + 7) ~/ 8;
  final corrW = (bw + 7) ~/ 8;
  final xFromY = List<int>.filled(corrH * corrW, 0);
  final bFromY = List<int>.filled(corrH * corrW, 0);
  final blockInfo = List<int>.filled(2 * nbBlocks, 0); // row0: type = 0
  for (var i = 0; i < nbBlocks; i++) {
    blockInfo[nbBlocks + i] = hfMult[i] - 1; // row1: multiplier - 1
  }
  final sharpness = List<int>.filled(bh * bw, 0);
  _writeTrivialModularStream(w, [xFromY, bFromY, blockInfo, sharpness]);
}

/// HfGlobal + the single HfPass: quant weight tables (the library default
/// for every one of the 17 parameter slots when [customDctParams] is
/// null, since this encoder only ever emits transform type 0 (DCT8x8);
/// otherwise a custom `TransformMode.dct` table for slot 0 — the only one
/// that matters — with the library default for the other 16, which costs
/// 0 further bits each), a single HF preset shared by every group
/// (cheapest choice; costs 0 bits only when [numGroups] == 1), and
/// natural (unpermuted) coefficient order.
void _writeHfGlobalAndPass(
    BitWriter w, int numGroups, List<List<double>>? customDctParams) {
  w.writeBool(customDctParams == null); // quant_all_default
  if (customDctParams != null) {
    w.writeBits(TransformMode.dct, 3); // encoding_mode for parameter slot 0
    w.writeBits(customDctParams[0].length - 1, 4); // num_params - 1 (= 5)
    for (final params in customDctParams) {
      // vals[0] is divided by 64 on read (hf_global.dart's _readDCTParams).
      w.writeF16(params[0] / 64.0);
      for (final p in params.skip(1)) {
        w.writeF16(p);
      }
    }
    for (var index = 1; index < 17; index++) {
      w.writeBits(TransformMode.library, 3); // 0 further bits
    }
  }
  w.writeBits(0, ceilLog1p(numGroups - 1)); // num_hf_presets = 1
  w.writeU32(0, 0x5F, 0, 0x13, 0, 0, 0, 0, 13); // usedOrders = 0
}

/// PassGroup: the AC (HF) coefficients for every block/channel, entropy
/// coded. [acInt] is semantic-channel-indexed; each block is a flat
/// 64-entry (row-major y*8+x) grid (position 0 unused).
///
/// The real HF context model (`vardct/hf_coefficients.dart`) spans 495
/// contexts per (HF preset, block-context cluster); L0 collapses that
/// entire space onto a single shared histogram (still bit-exact — see
/// `EntropyCodes.writeHeader`'s `clusterMapDomainSize`) since context
/// selection has no effect on which VALUES are legal to decode, only on
/// compression ratio.
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

/// Computes one group's AC coefficient tokens. [blockYStart]/[blockXStart]
/// are this group's origin in the whole image's block grid (row-major,
/// stride [bwFull]); [groupBh]/[groupBw] are this group's block extent
/// (up to 32x32, less at the image's right/bottom edge). The non-zero
/// prediction grid is local to the group, mirroring a fresh
/// `HfCoefficients` per (pass, group) in the decoder.
_GroupTokens _computeGroupTokens(
    int blockYStart,
    int blockXStart,
    int groupBh,
    int groupBw,
    int bwFull,
    List<List<Int32List>> acInt,
    HfBlockContext hfctx,
    List<int> blockCtx,
    List<int> histCtx,
    Int32List order) {
  final nonZeroesGrid = Int32List(3 * 32 * 32);
  final tokens = _GroupTokens();
  for (var y = 0; y < groupBh; y++) {
    for (var x = 0; x < groupBw; x++) {
      final blockIdx = (blockYStart + y) * bwFull + (blockXStart + x);
      for (final c in _channelOrder) {
        final block = acInt[c][blockIdx];
        var countNonZero = 0;
        var lastNonZeroK = -1;
        final vals = List<int>.filled(63, 0);
        for (var k = 0; k < 63; k++) {
          final o = order[k + 1];
          final oy = o >> 16, ox = o & 0xFFFF;
          // flip == true for plain 8x8 DCT (transform_type.dart): the
          // scan's (y, x) is transposed relative to the coefficient grid.
          final v = block[ox * 8 + oy];
          vals[k] = v;
          if (v != 0) {
            countNonZero++;
            lastNonZeroK = k;
          }
        }

        final predicted =
            HfCoefficients.getPredictedNonZeroes(nonZeroesGrid, c, y, x);
        final nonZeroCtx =
            HfCoefficients.getNonZeroContext(hfctx, predicted, blockCtx[c]);
        tokens.contexts.add(nonZeroCtx);
        tokens.values.add(countNonZero);
        nonZeroesGrid[c * 1024 + y * 32 + x] = countNonZero;

        var remaining = countNonZero;
        var prevNonzero = false;
        for (var k = 0; k <= lastNonZeroK; k++) {
          final prev = k == 0
              ? (remaining > 4 ? 0 : 1) // orderSize(64) ~/ 16 == 4
              : (prevNonzero ? 1 : 0);
          final coefCtx = histCtx[c] +
              HfCoefficients.getCoefficientContext(k + 1, remaining, 1, prev);
          final u = _packSigned(vals[k]);
          tokens.contexts.add(coefCtx);
          tokens.values.add(u);
          prevNonzero = u != 0;
          if (prevNonzero) remaining--;
        }
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
