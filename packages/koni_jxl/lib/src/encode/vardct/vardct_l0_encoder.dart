import 'dart:math' as math;
import 'dart:typed_data';

import '../../entropy/hybrid_uint.dart';
import '../../frame/frame_flags.dart';
import '../../io/bit_writer.dart';
import '../../util/math_helper.dart';
import '../../vardct/afv_basis.dart' show afvBasis;
import '../../vardct/dct.dart';
import '../../vardct/hf_block_context.dart';
import '../../vardct/hf_coefficients.dart' show HfCoefficients;
import '../../vardct/hf_global.dart'
    show
        DctParams,
        defaultDctParams,
        getAFVQuantWeights,
        getDCTQuantWeights,
        getDct2x2QuantWeights,
        getDct4x4QuantWeights,
        getDct4x8QuantWeights,
        getHornussQuantWeights;
import '../../vardct/hf_pass.dart' show getNaturalOrder;
import '../../vardct/transform_type.dart'
    show TransformMethod, TransformMode, TransformType;
import '../context_tree.dart';
import '../entropy_writer.dart';
import '../headers.dart';
import '../wp_predictor.dart';
import 'xyb_forward.dart';

/// Lossy (VarDCT) encoder (doc/lossy_encoder_plan.md's L0/L1/L2/L3): 8x8
/// DCT (plus adaptive 16x16 selection, on by default — see
/// `VardctL0Config.enableVariableTransforms`), real HF coefficient context
/// model, multi-group, multi-LF-group, adaptive per-block quantization, a
/// custom per-frequency quant weight table and optional filters (see
/// ROADMAP.md for what's left).
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
    this.enableVariableTransforms = true,
    this.transformRdLambdaOverride,
    this.maxTransformSize = 16,
    this.transformRdLambdaOverrideBeyond16,
    this.enableRectangularTransforms = false,
    this.enableBespokeTransforms = false,
    this.enableRdHfMult = false,
    this.rdHfMultLambdaOverride,
    this.perceptualMask = false,
    this.maskParamsOverride,
    this.enableRdoq = true,
    this.rdoqLambdaOverride,
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
  /// pixel region. Defaults to **on**: the per-region decision
  /// (`_decideTransformLayout`) is a real, bootstrap-frozen bit-rate
  /// estimate — quantize the whole image as all-8x8 first, build a real AC
  /// entropy-code-length table from that, then compare each region's
  /// actual `distortion + lambda * rate` cost against a freshly quantized
  /// 16x16 candidate's — replacing an earlier version that used a crude
  /// pre-quantization coefficient-magnitude proxy with no visibility into
  /// the real context-adaptive entropy cost (measured to over-select
  /// 16x16 on regular high-frequency content: +20% size on screentone,
  /// +31% on line art, despite picking 16x16 there 50-100% of the time).
  /// On top of that per-region estimate, `encodeLossyVardctL0` also
  /// assembles a real, fully-encoded body for *both* the all-8x8 layout
  /// and the decided mixed layout and keeps whichever is genuinely
  /// smaller — the same real-assembly safety net RDOQ already uses, one
  /// level up — so enabling this can never produce a larger file than
  /// leaving it off, only the same size (the estimate found no
  /// improvement) or smaller. See `_decideTransformLayout`'s doc comment
  /// for the full method and doc/spec_notes.md for the calibration and
  /// measured numbers behind the current default.
  final bool enableVariableTransforms;

  /// Overrides the rate/distortion trade-off constant `_kTransformRdLambda`
  /// used by [enableVariableTransforms]'s layout decision (a runtime knob
  /// rather than a recompile, purely so
  /// `tool/calibrate_transform_lambda.dart` can sweep it in one process).
  /// Null (the default) uses the shipped, calibrated constant.
  final double? transformRdLambdaOverride;

  /// How far [enableVariableTransforms]'s layout decision may cascade
  /// beyond its always-on 8x8-vs-16x16 first level: one of 16 (default —
  /// stop there), 32, 64, 128, or 256. Each step up adds one more
  /// structurally identical merge level in `_decideTransformLayout` — for
  /// every aligned region of four already-decided candidates at the
  /// current size, compare their real summed `distortion + lambda * rate`
  /// cost against a freshly quantized candidate of the next size up, using
  /// the same frozen bootstrap code-length table every level shares — plus
  /// its own real-assembly comparison against the immediately-prior
  /// level's actual body (not just against `enableVariableTransforms:
  /// false`), which is what makes raising this provably never-worse
  /// regardless of how many levels are enabled (see
  /// `_decideTransformLayout`'s doc comment for why a weaker "not worse
  /// than the original baseline" guarantee isn't sufficient once more than
  /// one extra level exists).
  ///
  /// **Existence vs. default are separate questions here.** `maxTransformSize:
  /// 32` (DCT 32x32, Tranche A's first extra size) is implemented,
  /// correct, and real-assembly-verified never-worse — but real
  /// `manga_samples/` chapter pages showed only a -0.0% to -0.6% win for
  /// the *same* ~40% encode-time cost that looked like -7.6% to -16.7% on
  /// synthetic patterns and the corpus' `gray_screentone` golden (a
  /// content-density mismatch, not a bug — see doc/spec_notes.md for the
  /// full numbers). That's why the default stays 16, not because sizes
  /// beyond 16 don't work. Full 27-transform-type support is tracked as a
  /// completeness goal independent of manga ROI (see ROADMAP.md, dated
  /// 2026-07-05) — raise this deliberately for content that genuinely has
  /// large flat regions, or to exercise/benchmark the larger sizes; don't
  /// expect it to help typical manga pages.
  final int maxTransformSize;

  /// Overrides the shared rate/distortion trade-off constant
  /// (`_kTransformRdLambdaBeyond16`) used by every cascade level beyond the
  /// first (16→32, 32→64, 64→128, 128→256) — a runtime knob rather than a
  /// recompile, purely so a calibration tool can sweep it in one process.
  /// Null (the default) uses the shipped constant, which calibration found
  /// no benefit to varying by level (see doc/spec_notes.md). Has no effect
  /// below `maxTransformSize: 32`.
  final double? transformRdLambdaOverrideBeyond16;

  /// Whether to also try DCT 16x8 / DCT 8x16 (Tranche B's first pair —
  /// the first *rectangular* transform types this encoder emits) at the
  /// bootstrap-leaf level, before the 8x8-vs-16x16 decision. Orthogonal to
  /// [maxTransformSize]: that knob is a square-tier size scale, this is a
  /// separate shape axis, so `maxTransformSize: 16` (the default) doesn't
  /// implicitly mean "no rectangular" and vice versa — conflating them
  /// would make the int knob ambiguous for existing callers. Defaults to
  /// **off** for the same reason [maxTransformSize] stays at 16:
  /// existence is a completeness goal (ROADMAP.md, 2026-07-05), the
  /// default is a separate, real-content-ROI question evaluated (and
  /// found real-but-small at real encode-time cost) in round 17, see
  /// doc/spec_notes.md.
  ///
  /// The 16x8/8x16 half-strip pair (Tranche B's first pair) is decided
  /// jointly with the whole-16x16 merge and the stay-split option — a
  /// true per-region argmin (`_decideTransformLayout`'s `decideLevel1`),
  /// not the pairwise greedy chain an earlier version of this comment
  /// described. `_tt8x32`/`_tt32x8` (the only 4:1-line case in the
  /// format, no matching square tier to pair against) still go through
  /// the older sequential `tryMergeLevel` chain, run after Level 1 —
  /// existence-vs-default is unaffected, but their own never-worse
  /// guarantee is still only "vs. whatever Level 0/1 left behind," not a
  /// joint choice with the levels below `maxTransformSize` 32.
  final bool enableRectangularTransforms;

  /// Whether to also try Tranche C's "bespoke" transform types (types with
  /// no shared plain-DCT machinery — all 9 are now implemented: DCT4x4,
  /// Hornuss, DCT2x2, DCT4x8, DCT8x4, and AFV0-3, completing Tranche C) at
  /// the leaf 8x8 footprint, as alternative encodings of the *same*
  /// footprint plain DCT8x8 already occupies — not a merge into a larger
  /// footprint like every Tranche A/B type. Decided via a true per-cell
  /// N-way argmin (`_decideTransformLayout`'s `decideLevel0`): every
  /// candidate at a cell is scored against the same snapshot of its
  /// west/north neighbors' state, and the true minimum is committed —
  /// not the sequential chain of pairwise `tryMergeLevel` swaps an
  /// earlier version of this comment described, where each type's own
  /// whole-image pass only ever compared against whatever the *previous*
  /// type's pass had already committed nearby (a real ordering artifact:
  /// the same type at the same cell could score differently purely
  /// because of list order — confirmed as the mechanism behind a real
  /// per-page regression measured in round 17, see doc/spec_notes.md's
  /// round 17/18 entries).
  ///
  /// **Both `decideLevel0`'s own result and the subsequent
  /// `decideLevel1`'s own result are exposed as separate real-assembled
  /// candidates** (`_decideTransformLayout`'s `candidates` list) whenever
  /// each differs from what came before — not just the final layout.
  /// This isn't redundant bookkeeping: a per-region *estimate* choosing
  /// to merge into 16x16 over staying split doesn't guarantee the real
  /// assembled bytes agree (the same "estimates can't resolve near-ties,
  /// verify by real assembly" gap this project has hit before, e.g.
  /// round 7's 32x32 case) — round 18's own testing hit a concrete
  /// instance of exactly this: content where every cell's true argmin was
  /// a bespoke type, but Level 1's *estimate* preferred merging into
  /// 16x16 anyway, which assembled to real *more* bytes than staying
  /// split (211B vs. 167B). Without Level 0's own result as its own
  /// candidate, that better layout would never have been tried for real
  /// at all.
  ///
  /// **This does not eliminate the separate, still-present caveat
  /// [enableRectangularTransforms]'s own doc comment describes** (a leaf
  /// choice changing what the region-level merge decision's *estimate*
  /// sees, via the live prediction grid's west/north dependency on
  /// already-decided neighbors) — round 17 measured that caveat's real
  /// magnitude for bespoke specifically (up to +4-5% worse on one real
  /// page, comparing this flag alone against it off — both runs otherwise
  /// identical, `enableVariableTransforms: true` in both). That's a
  /// property of comparing two *independent* encodes whose leaf layout
  /// differs from the start, not the within-one-encode estimate-vs-real
  /// gap the two paragraphs above describe and fix — round 18's rewrite
  /// removes the sequential-order artifact and adds Level 0's own
  /// candidate, but hasn't yet been re-measured against round 17's
  /// specific real-page case (see ROADMAP.md/doc/spec_notes.md for
  /// whichever round did that check last).
  ///
  /// Defaults to **off** for the same reason [enableRectangularTransforms]
  /// does: existence is a completeness goal (ROADMAP.md), the default is
  /// a separate, real-content-ROI question evaluated in round 17
  /// (doc/spec_notes.md).
  final bool enableBespokeTransforms;

  /// Whether to replace the default 3-bucket adaptive-quantization
  /// heuristic (`hfMult` chosen from a threshold on relative AC energy)
  /// with a real per-block rate-distortion search over the same
  /// candidate multipliers ({1, 2, 4}). Defaults to **off** — a
  /// multi-distance sweep (`tool/calibrate_rd_lambda.dart`) isolated from
  /// [enableVariableTransforms] found the previously-known-safe,
  /// `distance=1.0`-only `kLambda` degrades into a real regression as
  /// distance grows (e.g. gradient RMSE 48-60% over the heuristic by
  /// `distance>=4.0`) — this search's `refStep^2` lambda scaling has the
  /// same class of distance-dependent issue RDOQ's old formula had.
  /// Unlike RDOQ's fix, though, switching to `acScale^2` only mitigates
  /// the high-distance blowup (verified: near-zero regression at
  /// `distance>=4.0` at an equivalent `kLambda`) without resolving the
  /// underlying `distance<=2.0` photo-vs-banding trade-off — so this
  /// isn't shippable yet either way. See `_chooseHfMultRd`'s doc comment
  /// and doc/spec_notes.md for the full calibration status before
  /// enabling or attempting a scaling fix.
  final bool enableRdHfMult;

  /// Overrides the rate/distortion trade-off constant `_kRdLambda` used
  /// by [enableRdHfMult] (a runtime knob rather than a recompile, purely
  /// so `tool/calibrate_rd_lambda.dart` can sweep it in one process).
  /// Null (the default) uses the shipped, calibrated constant.
  final double? rdHfMultLambdaOverride;

  /// Whether the [enableRdHfMult] search weights each block's distortion by
  /// a perceptual **masking** factor before the `distortion + lambda * rate`
  /// trade (see `_maskWeight`). Only meaningful when [enableRdHfMult] is also
  /// on. Defaults to **off**.
  ///
  /// This is the banding-aware distortion term round 3 identified as the
  /// missing piece (see `_chooseHfMultRd`'s doc comment and
  /// doc/spec_notes.md): plain weighted-squared-error, at a lambda that wins
  /// on photo content, strips the L2 heuristic's smooth-block precision
  /// boosts because it can't see that banding is far more objectionable than
  /// its raw MSE contribution. The masking weight amplifies the distortion of
  /// smooth/low-AC-energy blocks (restoring banding protection) and reverts
  /// to plain weighted-MSE (weight ~1) in busy blocks where masking genuinely
  /// hides quantization noise — a continuous generalization of the L2
  /// 3-bucket relative-AC-energy heuristic, driven by an RD search rather
  /// than fixed thresholds.
  final bool perceptualMask;

  /// Overrides the perceptual masking curve's `(hi, knee, gamma)` constants
  /// (`_kMaskHi`/`_kMaskKnee`/`_kMaskGamma`) used by [perceptualMask] — a
  /// runtime knob for `tool/calibrate_perceptual_mask.dart` to sweep the
  /// curve shape in one process, not a recompile. Null (the default) uses the
  /// shipped constants.
  final ({double hi, double knee, double gamma})? maskParamsOverride;

  /// Whether to run a rate-distortion coefficient-dropping pass ("RDOQ")
  /// over each block's already-committed AC coefficients (from the L2
  /// heuristic and, if [enableRdHfMult] is also on, its RD hfMult
  /// choice): walks each block-channel's scan-order coefficients
  /// backward from the true last-nonzero position, proposing to zero any
  /// coefficient whose removal reduces `distortion + lambda * rate`, then
  /// only committing the proposal if a real re-encode confirms it
  /// actually shrinks that block-channel (see `_chooseAcRdoq`'s and
  /// `_rdoqBlockChannel`'s doc comments for why the real-assembly check
  /// is load-bearing, not just a sanity check). Independent of
  /// [enableRdHfMult] — meaningful (and runs) whichever hfMult source is
  /// active; when both are enabled, RDOQ always runs after hfMult is
  /// finalized.
  ///
  /// Defaults to **on**, after a two-step calibration story worth
  /// knowing before touching [rdoqLambdaOverride] (full detail in
  /// doc/spec_notes.md): a first calibration at `distance = 1.0` only
  /// found a constant that looked perfect there but roughly *doubled*
  /// RMSE at `distance = 8.0` (`lambda`'s old `refStep^2` scaling grew in
  /// the opposite direction from how RDOQ's own distortion metric scales
  /// with the dequant weight table — see `_kRdoqLambda`'s doc comment for
  /// the exact mechanism). Fixed by rederiving the scaling (`lambda ∝
  /// acScale^2`, not `refStep^2`) and recalibrating `_kRdoqLambda` via a
  /// **multi-distance** sweep (0.5-8.0). The shipped constant is
  /// verified safe (no regression beyond a small, bounded RMSE cost) at
  /// every distance tested — a real win on photo and real screentone
  /// content concentrated at low-to-mid distance, shrinking to a
  /// negligible-but-never-regressing effect at high distance, where
  /// quantization alone already zeros out most marginal AC content
  /// before RDOQ gets a chance to.
  final bool enableRdoq;

  /// Overrides the RDOQ rate/distortion trade-off constant `_kRdoqLambda`
  /// (mirrors [rdHfMultLambdaOverride] — a runtime knob for
  /// `tool/calibrate_rdoq_lambda.dart`, not a recompile). Null uses the
  /// shipped constant.
  final double? rdoqLambdaOverride;
}

int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

const _hfConfig = HybridIntegerConfig(4, 1, 0);

/// Channel processing/bitstream order used throughout VarDCT: Y, X, B
/// (semantic indices 1, 0, 2 — see `frame/frame.dart`'s `cMap`).
const _channelOrder = [1, 0, 2];

final _tt8 = TransformType.byType(0); // DCT 8x8: orderID 0, parameterIndex 0
final _tt16 = TransformType.byType(4); // DCT 16x16: orderID 2, parameterIndex 4
final _tt32 = TransformType.byType(5); // DCT 32x32: orderID 3, parameterIndex 5
final _tt64 =
    TransformType.byType(18); // DCT 64x64: orderID 7, parameterIndex 11
final _tt128 =
    TransformType.byType(21); // DCT 128x128: orderID 9, parameterIndex 13
final _tt256 =
    TransformType.byType(24); // DCT 256x256: orderID 11, parameterIndex 15
final _tt16x8 =
    TransformType.byType(6); // DCT 16x8: orderID 4, parameterIndex 6, flip
final _tt8x16 =
    TransformType.byType(7); // DCT 8x16: orderID 4, parameterIndex 6, no flip
final _tt32x8 =
    TransformType.byType(8); // DCT 32x8: orderID 5, parameterIndex 7, flip
final _tt8x32 =
    TransformType.byType(9); // DCT 8x32: orderID 5, parameterIndex 7, no flip
final _tt32x16 =
    TransformType.byType(10); // DCT 32x16: orderID 6, parameterIndex 8, flip
final _tt16x32 =
    TransformType.byType(11); // DCT 16x32: orderID 6, parameterIndex 8, no flip
final _tt64x32 =
    TransformType.byType(19); // DCT 64x32: orderID 8, parameterIndex 12, flip
final _tt32x64 = TransformType.byType(
    20); // DCT 32x64: orderID 8, parameterIndex 12, no flip
final _tt128x64 =
    TransformType.byType(22); // DCT 128x64: orderID 10, parameterIndex 14, flip
final _tt64x128 = TransformType.byType(
    23); // DCT 64x128: orderID 10, parameterIndex 14, no flip
final _tt256x128 = TransformType.byType(
    25); // DCT 256x128: orderID 12, parameterIndex 16, flip
final _tt128x256 = TransformType.byType(
    26); // DCT 128x256: orderID 12, parameterIndex 16, no flip
final _tt4x4 = TransformType.byType(
    3); // DCT4x4 (Tranche C, bespoke): orderID 1, parameterIndex 3, TransformMethod.dct4
final _ttHornuss = TransformType.byType(
    1); // Hornuss (Tranche C, bespoke): orderID 1, parameterIndex 1, TransformMethod.hornuss
final _ttDct2x2 = TransformType.byType(
    2); // DCT2x2 (Tranche C, bespoke): orderID 1, parameterIndex 2, TransformMethod.dct2
final _ttDct4x8 = TransformType.byType(
    12); // DCT4x8 (Tranche C, bespoke): orderID 1, parameterIndex 9, TransformMethod.dct4x8
final _ttDct8x4 = TransformType.byType(
    13); // DCT8x4 (Tranche C, bespoke): orderID 1, parameterIndex 9, TransformMethod.dct8x4
final _ttAfv0 = TransformType.byType(
    14); // AFV0 (Tranche C, bespoke): orderID 1, parameterIndex 10, TransformMethod.afv
final _ttAfv1 = TransformType.byType(
    15); // AFV1 (Tranche C, bespoke): orderID 1, parameterIndex 10, TransformMethod.afv
final _ttAfv2 = TransformType.byType(
    16); // AFV2 (Tranche C, bespoke): orderID 1, parameterIndex 10, TransformMethod.afv
final _ttAfv3 = TransformType.byType(
    17); // AFV3 (Tranche C, bespoke): orderID 1, parameterIndex 10, TransformMethod.afv

/// Transform types this encoder can currently emit, largest reused
/// mechanically wherever code is already N-way (context/rawWeight lookup,
/// quant-weight/order tables); genuinely new work (layout-decision merge
/// levels, flip/orientation handling) is called out separately in
/// ROADMAP.md as each size/tranche lands. All of Tranche A (square DCT
/// sizes) plus all of Tranche B (12 rectangular types) are listed here
/// regardless of [VardctL0Config.maxTransformSize]/[VardctL0Config.
/// enableRectangularTransforms] — preparing a type's context/quant-weight
/// tables is cheap and does not by itself make the layout decision ever
/// place it; that's gated purely by [_cascadeSizes]/[_cascadeRectPairs]/the
/// bootstrap-tier rectangular pre-pass in `_decideTransformLayout`.
/// `_finishEncode` restricts what actually gets *written* to HfGlobal's
/// custom-weight section down further still, to only the types each
/// specific assembled candidate's own placed blocks use (see its
/// `customParamsByType` parameter's doc comment) — precise per candidate,
/// not merely per-flag.
final _activeTransformTypes = [
  _tt8,
  _tt16,
  _tt32,
  _tt64,
  _tt128,
  _tt256,
  _tt16x8,
  _tt8x16,
  _tt32x8,
  _tt8x32,
  _tt32x16,
  _tt16x32,
  _tt64x32,
  _tt32x64,
  _tt128x64,
  _tt64x128,
  _tt256x128,
  _tt128x256,
  _tt4x4,
  _ttHornuss,
  _ttDct2x2,
  _ttDct4x8,
  _ttDct8x4,
  _ttAfv0,
  _ttAfv1,
  _ttAfv2,
  _ttAfv3,
];

/// The square sizes beyond the always-on 8x8/16x16 level, in ascending
/// order — `_decideTransformLayout`'s generic cascade stops at the first
/// entry wider than [VardctL0Config.maxTransformSize].
final _cascadeSizes = [_tt32, _tt64, _tt128, _tt256];

/// The "2:1 pair" rectangular type (wide, tall) formed by merging two
/// same-size square blocks from the cascade level *below* each entry in
/// [_cascadeSizes] (same index) — e.g. `_cascadeRectPairs[0]` (16x32,
/// 32x16) merges two 16x16-or-smaller blocks, one level below `_cascadeSizes
/// [0]` (32x32). Tried in `_decideTransformLayout` immediately before its
/// paired square merge, same "rectangular nests inside the square region,
/// so it must run first" argument the bootstrap-tier 16x8/8x16 pre-pass
/// already established — each pair's smaller dctSelect stride is exactly
/// half its paired square tier's, so alignment to the rectangular type's
/// own stride always keeps it within one square-tier-aligned region.
final _cascadeRectPairs = [
  (_tt16x32, _tt32x16),
  (_tt32x64, _tt64x32),
  (_tt64x128, _tt128x64),
  (_tt128x256, _tt256x128),
];

/// Scratch-buffer side length shared by every transform-pipeline call
/// (`computeCoeffBuf`, `_decideTransformLayout`, `_chooseHfMultRd`,
/// `_chooseAcRdoq`) — sized to the largest [_activeTransformTypes] member's
/// `pixelHeight`/`pixelWidth`. `forwardDCT2D`/`inverseDCT2D` only ever touch
/// the `[0, height) x [0, width)` sub-region a call passes explicitly, so
/// one shared, reused, max-sized pair works for every smaller size too —
/// bump this when a larger type is added, no other change needed here.
const _maxTransformPixelSize = 256;

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
  // Dispatches by each parameterIndex's real TransformMode (bitstream quant
  // weight encoding mode, not TransformType.transformMethod's pixel
  // reconstruction algorithm) rather than assuming every active type is
  // `TransformMode.dct`-shaped -- that assumption held for all 18 plain-DCT
  // types (Tranches A/B) but breaks the moment a bespoke type (Tranche C)
  // is active: `TransformMode.dct4`'s default params carry a *nested* 4x4
  // dctParam table plus 2 separate override values, a structurally
  // different shape `getDCTQuantWeights(pixelHeight, pixelWidth, ...)`
  // can't consume directly. `acScale`'s "scale band[0]" fineness-knob
  // mechanism still applies to the nested dctParam table unchanged (see
  // getDCTQuantWeights's own doc comment for why scaling only band[0]
  // scales the whole interpolated table uniformly); the 2 override values
  // are left at their unscaled defaults for now -- since both the weight
  // table built here and the params written to the bitstream derive from
  // this SAME DctParams, that's a rate-tuning choice, not a correctness
  // one (see getDct4x4QuantWeights's doc comment for the single-sourcing
  // this depends on).
  DctParams customParams(TransformType tt) {
    final base = defaultDctParams[tt.parameterIndex];
    switch (base.mode) {
      case TransformMode.dct:
        final scaledDctParam = [
          for (var c = 0; c < 3; c++)
            [
              base.dctParam![c][0] * config.acScale,
              ...base.dctParam![c].skip(1)
            ],
        ];
        return DctParams(scaledDctParam, null, TransformMode.dct);
      case TransformMode.dct4:
        final scaledDctParam = [
          for (var c = 0; c < 3; c++)
            [
              base.dctParam![c][0] * config.acScale,
              ...base.dctParam![c].skip(1)
            ],
        ];
        return DctParams(scaledDctParam, base.param, TransformMode.dct4);
      case TransformMode.hornuss:
        // Unlike a dct-shaped table, hornuss/dct2's `param` values are ALL
        // absolute weights used directly (not one band-interpolation seed
        // plus multiplicative ratios) -- see getHornussQuantWeights's doc
        // comment -- so acScale's "fineness knob" property (scale one
        // value, the whole table scales uniformly) requires scaling every
        // one of them, not just the first.
        return DctParams(
            null,
            [
              for (var c = 0; c < 3; c++)
                [for (final v in base.param![c]) v * config.acScale],
            ],
            TransformMode.hornuss);
      case TransformMode.dct2:
        return DctParams(
            null,
            [
              for (var c = 0; c < 3; c++)
                [for (final v in base.param![c]) v * config.acScale],
            ],
            TransformMode.dct2);
      case TransformMode.dct4x8:
        // Same shape as dct4 above: the 1 override value per channel is a
        // divisor on a separately-built base table (getDct4x8QuantWeights),
        // not an absolute weight -- left unscaled, same rate-tuning-not-
        // correctness reasoning as dct4's own overrides.
        final scaledDctParam = [
          for (var c = 0; c < 3; c++)
            [
              base.dctParam![c][0] * config.acScale,
              ...base.dctParam![c].skip(1)
            ],
        ];
        return DctParams(scaledDctParam, base.param, TransformMode.dct4x8);
      case TransformMode.afv:
        // dctParam (the 4x8-DCT region's base table) and params4x4 (the
        // transposed-4x4-DCT region's base table) each scale the same way
        // as any dct-shaped table (band[0] only -- see getDCTQuantWeights).
        // param's first 6 values (the 5 direct corner overrides plus
        // bands[0], the AFV-basis region's own band-interpolation seed)
        // are ALL absolute weights used directly -- like hornuss/dct2's
        // params, not dct4/dct4x8's divisor overrides -- so every one of
        // them scales for a uniform fineness knob; the last 3 (quantMult
        // ratios feeding the band chain) stay unscaled, matching a
        // dct-shaped table's own vals[1:].
        final scaledDctParam = [
          for (var c = 0; c < 3; c++)
            [
              base.dctParam![c][0] * config.acScale,
              ...base.dctParam![c].skip(1)
            ],
        ];
        final scaledParams4x4 = [
          for (var c = 0; c < 3; c++)
            [
              base.params4x4![c][0] * config.acScale,
              ...base.params4x4![c].skip(1)
            ],
        ];
        final scaledParam = [
          for (var c = 0; c < 3; c++)
            [
              for (var i = 0; i < base.param![c].length; i++)
                i < 6 ? base.param![c][i] * config.acScale : base.param![c][i],
            ],
        ];
        return DctParams(scaledDctParam, scaledParam, TransformMode.afv,
            params4x4: scaledParams4x4);
      default:
        throw UnsupportedError(
            'transform mode ${base.mode} not yet supported by the lossy encoder');
    }
  }

  List<List<Float32List>> rawWeightsFor(TransformType tt, DctParams p) {
    switch (p.mode) {
      case TransformMode.dct:
        return [
          for (var c = 0; c < 3; c++)
            getDCTQuantWeights(tt.pixelHeight, tt.pixelWidth, p.dctParam![c]),
        ];
      case TransformMode.dct4:
        return [
          for (var c = 0; c < 3; c++)
            getDct4x4QuantWeights(p.dctParam![c], p.param![c]),
        ];
      case TransformMode.dct4x8:
        return [
          for (var c = 0; c < 3; c++)
            getDct4x8QuantWeights(p.dctParam![c], p.param![c][0]),
        ];
      case TransformMode.afv:
        return [
          for (var c = 0; c < 3; c++)
            getAFVQuantWeights(p.dctParam![c], p.params4x4![c], p.param![c]),
        ];
      case TransformMode.hornuss:
        return [
          for (var c = 0; c < 3; c++) getHornussQuantWeights(p.param![c]),
        ];
      case TransformMode.dct2:
        return [
          for (var c = 0; c < 3; c++) getDct2x2QuantWeights(p.param![c]),
        ];
      default:
        throw UnsupportedError(
            'transform mode ${p.mode} not yet supported by the lossy encoder');
    }
  }

  // Keyed by tt.type, not parameterIndex: distinct transform types can
  // share a parameterIndex (e.g. DCT8x16/16x8), but each still needs its
  // own weight matrix at its own pixelHeight/pixelWidth.
  final customParamsByType = {
    for (final tt in _activeTransformTypes) tt.type: customParams(tt),
  };
  final rawWeightByType = {
    for (final tt in _activeTransformTypes)
      tt.type: rawWeightsFor(tt, customParamsByType[tt.type]!),
  };
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
  // Always native 8x8-granularity regardless of which HF transform types
  // are active, so this scratch pair is dedicated and unrelated to
  // _maxTransformPixelSize below.
  final cflScratchA = List.generate(8, (_) => Float32List(8));
  final cflScratchB = List.generate(8, (_) => Float32List(8));
  final cfl = _chromaFromLumaFit(planes, bh, bw, cflScratchA, cflScratchB);
  // Shared scratch for the transform pipeline proper (computeCoeffBuf,
  // _decideTransformLayout, _chooseHfMultRd, _chooseAcRdoq): one reused,
  // max-sized pair covers every active transform type (see
  // _maxTransformPixelSize's doc comment).
  final scratchA = List.generate(
      _maxTransformPixelSize, (_) => Float32List(_maxTransformPixelSize));
  final scratchB = List.generate(
      _maxTransformPixelSize, (_) => Float32List(_maxTransformPixelSize));
  // Reference AC step at the first (lowest-frequency, most perceptually
  // important) Y position: the scale against which "how smooth is this
  // block" is judged, so heuristics adapt with `distance` instead of using
  // an absolute threshold tuned for one quantization strength.
  final refStep = scaleFactor[1] / rawWeightByType[_tt8.type]![1][0][1];

  // 4.5. Context/grouping setup: hoisted ahead of layout/quantization since
  // it only depends on image size, not on which transform types end up
  // placed where — the layout decision itself (step 4, below) now needs
  // it too (a real bootstrap-frozen bit-rate estimate, not just the
  // RD-hfMult search in step 5.5).
  final hfctx = HfBlockContext.defaults();
  final ctxByType = {
    for (final tt in _activeTransformTypes)
      tt.type: _TransformCtx(tt, hfctx, rawWeightByType[tt.type]!),
  };
  // ceilDiv(trueSize, 256) == ceilDiv(paddedSize, 256) always (padding adds
  // at most 7 pixels, far short of a 256 boundary, and true/padded sizes
  // coincide exactly whenever trueSize is already a multiple of 256 since
  // 256 is itself a multiple of 8) — using the padded size here is just
  // the more directly available one (matches bw/bh already in scope).
  final groupsX = ceilDiv(paddedWidth, 256);
  final groupsY = ceilDiv(paddedHeight, 256);
  final numGroups = groupsX * groupsY;

  // Whether to write custom per-frequency quant weight tables at all
  // (only ever needed away from the library defaults). Which *types*
  // actually get a custom table written is decided per assembled
  // candidate, not here — see `_finishEncode`'s `customParamsByType`
  // parameter's doc comment for why per-candidate precision (not just
  // per-flag) is what actually eliminates the dead-bitstream-bytes cost.
  final usesCustomWeights = config.acScale != 1.0;

  // 4. Decide the block layout: adaptively 8x8 or 16x16 per aligned 16x16
  // pixel region, in the exact raster-scan-with-skip order `HfMetadata`'s
  // decoder-side `_placeBlock` reconstructs from a flat block list —
  // placement order IS the wire format here, not just a convenience. Also
  // performs this encoder's forward DCT + quantization (step 5, folded in
  // below) — dcInt is semantic-indexed (0=X, 1=Y, 2=B), always at native
  // 8x8-block granularity regardless of the HF transform covering it (see
  // _PlacedBlock's doc comment on the LLF relationship for 16x16).
  if (config.enableVariableTransforms) {
    // _decideTransformLayout returns a list of fully independent
    // candidates, bootstrap always first (its doc comment explains why) —
    // assemble a real body for each and keep whichever is genuinely
    // smaller, so this feature (and every cascade level
    // [VardctL0Config.maxTransformSize] enables beyond 16) can never
    // regress vs `enableVariableTransforms: false` alone, matching the
    // real-assembly safety net this file's other RD features already use.
    final dcIntBootstrap = [for (var c = 0; c < 3; c++) Int32List(bh * bw)];
    final candidates = _decideTransformLayout(
        planes,
        cfl,
        refStep,
        sd,
        scaleFactor,
        dcIntBootstrap,
        bh,
        bw,
        scratchA,
        scratchB,
        hfctx,
        ctxByType,
        groupsX,
        groupsY,
        config.transformRdLambdaOverride,
        config.maxTransformSize,
        config.transformRdLambdaOverrideBeyond16,
        config.enableRectangularTransforms,
        config.enableBespokeTransforms);

    Uint8List assemble(List<_PlacedBlock> blocks, List<Int32List> dcInt) =>
        _finishEncode(
            blocks,
            dcInt,
            bh,
            bw,
            groupsX,
            groupsY,
            numGroups,
            hfctx,
            ctxByType,
            planes,
            cfl,
            refStep,
            sd,
            scaleFactor,
            scratchA,
            scratchB,
            config,
            usesCustomWeights ? customParamsByType : null,
            width,
            height);

    // `candidates[0]` is always the plain bootstrap (identical to
    // `enableVariableTransforms: false`); every later entry already beat
    // its own immediately-prior candidate's *estimate*, but only a real
    // assembled-byte comparison against every candidate (not just
    // adjacent pairs) makes the whole cascade provably never-worse — the
    // exact gap a real end-to-end smoke test found during the 32x32 slice
    // (a level's estimate can regress vs. the immediately-prior level even
    // though it's still smaller than the original bootstrap).
    var chosen = assemble(candidates[0].$1, candidates[0].$2);
    final bodyOff = chosen;
    var chosenLevel = 0;
    for (var i = 1; i < candidates.length; i++) {
      final body = assemble(candidates[i].$1, candidates[i].$2);
      if (body.length < chosen.length) {
        chosen = body;
        chosenLevel = i;
      }
    }

    if (const bool.fromEnvironment('jxl.encdebug')) {
      final tally = <String, int>{};
      for (final block in candidates[chosenLevel].$1) {
        tally[block.tt.name] = (tally[block.tt.name] ?? 0) + 1;
      }
      // ignore: avoid_print
      print('vardct variable-transform candidates: off=${bodyOff.length}B '
          'chosen=level$chosenLevel (${chosen.length}B) of '
          '${candidates.length} candidates, tally=$tally');
    }
    return chosen;
  }

  final dcInt = [for (var c = 0; c < 3; c++) Int32List(bh * bw)];
  final placedBlocks = [
    for (var by = 0; by < bh; by++)
      for (var bx = 0; bx < bw; bx++) _PlacedBlock(by, bx, _tt8),
  ];
  for (final block in placedBlocks) {
    block.computeAndQuantize(
        planes,
        cfl,
        refStep,
        sd,
        ctxByType[_tt8.type]!.rawWeight,
        scaleFactor,
        dcInt,
        bw,
        scratchA,
        scratchB);
  }
  return _finishEncode(
      placedBlocks,
      dcInt,
      bh,
      bw,
      groupsX,
      groupsY,
      numGroups,
      hfctx,
      ctxByType,
      planes,
      cfl,
      refStep,
      sd,
      scaleFactor,
      scratchA,
      scratchB,
      config,
      usesCustomWeights ? customParamsByType : null,
      width,
      height);
}

/// Finishes encoding one already-decided, already-quantized block layout
/// into a complete VarDCT bitstream: the optional RD-hfMult/RDOQ passes,
/// real AC clustering, LF-group partitioning, and section assembly (steps
/// 5.5-7 of `encodeLossyVardctL0`, factored out so
/// `enableVariableTransforms` can run this same pipeline independently on
/// two candidate layouts — see `_decideTransformLayout`'s doc comment —
/// and keep whichever assembles smaller).
///
/// [customParamsByType] (keyed by `TransformType.type`, or `null` if
/// `config.acScale == 1.0` and no custom table is ever needed) is the
/// *full* per-type table regardless of what this specific candidate
/// actually placed — deliberately not pre-filtered by the caller, so this
/// function can derive the minimal `customParamsByIndex` HfGlobal actually
/// needs from [placedBlocks] itself: only the parameterIndex slots this
/// candidate's own blocks use. This is more precise than filtering by
/// which *flags* could reach a type (an earlier version of this cleanup
/// did that, then found it made "does rectangular/bespoke genuinely win"
/// tests fragile — a flag-reachable-but-not-actually-placed type, e.g. one
/// of 4 rectangular bootstrap candidates when only 2 end up chosen, still
/// paid its custom-table cost under that scheme, and unevenly across the
/// two sides of a comparison). Per-candidate precision has no such
/// asymmetry: every candidate, in every config, pays for exactly the
/// custom tables its own placed blocks use and no more — restoring true
/// byte-optimality, not just distance-independent identity on the
/// (flag-only) default path. See doc/spec_notes.md.
Uint8List _finishEncode(
    List<_PlacedBlock> placedBlocks,
    List<Int32List> dcInt,
    int bh,
    int bw,
    int groupsX,
    int groupsY,
    int numGroups,
    HfBlockContext hfctx,
    Map<int, _TransformCtx> ctxByType,
    List<List<Float32List>> planes,
    _ChromaFromLumaFit cfl,
    double refStep,
    List<double> sd,
    List<double> scaleFactor,
    List<Float32List> scratchA,
    List<Float32List> scratchB,
    VardctL0Config config,
    Map<int, DctParams>? customParamsByType,
    int width,
    int height) {
  final usedTypeIndices = {for (final block in placedBlocks) block.tt.type};
  final customParamsByIndex = customParamsByType == null
      ? null
      : {
          for (final tt in _activeTransformTypes)
            if (usedTypeIndices.contains(tt.type))
              tt.parameterIndex: customParamsByType[tt.type]!,
        };

  final blocksByGroup = List<List<_PlacedBlock>>.generate(numGroups, (_) => []);
  for (final block in placedBlocks) {
    final g = (block.by ~/ 32) * groupsX + (block.bx ~/ 32);
    blocksByGroup[g].add(block);
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
        scaleFactor,
        dcInt,
        bw,
        scratchA,
        scratchB,
        hfctx,
        ctxByType,
        groupsX,
        groupsY,
        blocksByGroup,
        config.rdHfMultLambdaOverride,
        config.perceptualMask,
        config.maskParamsOverride,
        config.acScale);
  }

  // 5.8. Optional: a rate-distortion coefficient-dropping pass ("RDOQ")
  // over whatever hfMult/AC state is already committed (the L2 heuristic,
  // optionally refined by step 5.5) — see _chooseAcRdoq's doc comment.
  // Off by default pending calibration (doc/spec_notes.md).
  if (config.enableRdoq) {
    _chooseAcRdoq(
        placedBlocks,
        planes,
        cfl,
        config.acScale,
        scaleFactor,
        scratchA,
        scratchB,
        hfctx,
        ctxByType,
        groupsX,
        groupsY,
        blocksByGroup,
        config.rdoqLambdaOverride);
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

/// Rate/distortion trade-off constant for the 8x8-vs-16x16 layout decision
/// (`_decideTransformLayout`), scaled the same way as `_kRdLambda`
/// (`lambda = kLambda * refStep^2` — both trade off the *same* distortion
/// metric, `quantizeCandidate`'s weighted-squared-error, against a bit-rate
/// estimate, so the same scalar-quantizer-theory scaling law applies; see
/// `_kRdLambda`'s doc comment for the derivation). Calibrated independently
/// from `_kRdLambda` (via `tool/calibrate_transform_lambda.dart`, a
/// multi-distance sweep across photo/gradient/screentone/line-art content —
/// see doc/spec_notes.md for the calibration methodology this project
/// learned the hard way with RDOQ's lambda, and for the measured numbers
/// behind this specific value).
const _kTransformRdLambda = 3000.0;

/// Shared rate/distortion trade-off constant for every cascade level
/// beyond the first (16→32, 32→64, 64→128, 128→256 —
/// `VardctL0Config.maxTransformSize` above 16), same `lambda = kLambda *
/// refStep^2` scaling as `_kTransformRdLambda` (identical distortion
/// metric one level up: `quantizeCandidate`'s weighted-squared-error).
/// Calibrated for the 16-vs-32 level via
/// `tool/calibrate_transform32_lambda.dart`'s multi-distance sweep
/// (0.5-8.0): this value happens to coincide with `_kTransformRdLambda` —
/// both encode the same underlying trade-off, and the sweep found no
/// benefit to diverging from it — and a quick real-manga sanity check at
/// each further size (see doc/spec_notes.md) found no reason to sweep
/// separately per level either, so one shared constant covers all of
/// them. The two knobs (this and `_kTransformRdLambda`) remain
/// independently overridable and should be re-swept independently if
/// either distortion metric or scaling convention ever changes.
const _kTransformRdLambdaBeyond16 = 3000.0;

/// Decides the 8x8-vs-16x16 layout per 16x16-pixel region using a real,
/// bootstrap-frozen bit-rate estimate instead of the old pre-quantization
/// coefficient-magnitude proxy this replaced (`_should16x16`/`_bitProxy`,
/// removed) — that proxy was measured to over-select 16x16 on regular
/// high-frequency content (screentone, line art: real, djxl-verified output
/// was both larger *and* worse RMSE than plain 8x8 despite the proxy
/// favoring 16x16 there), because it had no visibility into the real
/// context-adaptive entropy cost (see doc/spec_notes.md's L3 write-up).
///
/// Returns a list of fully independent, already-quantized-and-committed
/// candidate layouts, always starting with the plain all-8x8 bootstrap and
/// growing by at most one entry per cascade level that actually changed
/// something — not just the single layout this decision favors: the
/// caller (`encodeLossyVardctL0`) assembles a real body for *every*
/// candidate and keeps whichever is actually smaller, the same
/// real-assembly safety net `_chooseAcClustering`/RDOQ already use
/// elsewhere in this file, applied one level up (per-image instead of
/// per-block-channel) — this decision's own cost estimate still uses a
/// bootstrap-frozen *code-length table* (re-deriving it live at every
/// level would mean re-running `_chooseAcClustering`'s own multi-
/// candidate real-assembly search that many more times, not a cheap
/// refresh — see point 3 below for the one piece that *is* kept live:
/// each block's predicted non-zero count), so unlike RDOQ it cannot
/// promise never-worse on its own; the outer safety net is what
/// makes the combination never-worse regardless of how many cascade
/// levels are enabled.
///
/// **Two independent layout paths feed the one candidate pool** (this is
/// what makes bespoke provably never-worse-than-baseline — see the "Method"
/// note below and doc/spec_notes.md's round 19 write-up):
/// - a **baseline path** (`runCascadeFrom(bootstrap)`), run unconditionally,
///   producing exactly the layouts the flags-off (`enableBespokeTransforms:
///   false`) config would — so the plain-8x8 + 16x16/rect/size layout is
///   *always* a pool member;
/// - a **bespoke path** (`decideLevel0` + `runCascadeFrom` on its result),
///   only when [VardctL0Config.enableBespokeTransforms], adding the
///   per-cell bespoke layouts.
/// Because the baseline path's candidates are always present and the caller
/// real-assembles every candidate, the chosen output is never larger than
/// the same config with bespoke off — the guarantee round 18 lost by
/// committing bespoke *before* the 16x16 decision (which let an over-selected
/// bespoke type crowd out beneficial 16x16 merges that then had no plain
/// candidate to fall back to). Within each path, the bootstrap is first and
/// every later candidate beat its own immediately-prior one to exist, so
/// `min(assemble(c).length) <= bootstrap` holds structurally too — closing
/// the separate gap a 32x32 smoke test found (a level whose per-region
/// estimate looks fine can still regress against the immediately-prior level,
/// not just the bootstrap). The candidates share no mutable `_PlacedBlock`
/// state (see [_PlacedBlock.copy]'s doc comment) — callers must not run
/// [_PlacedBlock.computeAndQuantize] on any returned block (all are
/// already committed).
///
/// **Method** (mirrors `_chooseHfMultRd`'s already-shipped
/// bootstrap-then-freeze pattern, generalized from "which hfMult" to
/// "which transform type"):
/// 1. Quantize the *whole* image as all-8x8 blocks first (the
///    "bootstrap"), committing into [dcIntBootstrap] and recording each
///    block's own distortion ([_PlacedBlock.distortion]). This bootstrap
///    layout, as-is, *is* the "off" candidate — identical to what
///    `enableVariableTransforms: false` alone would have produced.
/// 2. Build the bootstrap's own AC token/clustering pass
///    ([_computeGroupTokens]/[_chooseAcClustering]) to get a real, frozen
///    Huffman code-length table ([EntropyCodes.tokenBitLengths]) and
///    cluster map — the same bootstrap-then-freeze soundness argument
///    `_chooseHfMultRd`'s doc comment already establishes applies
///    unchanged here: `HfCoefficients.getBlockContext` only lets `hfMult`
///    (not transform type) shift which cluster a token routes to via
///    `HfBlockContext.qfThresholds`, which stays empty regardless of any
///    per-region transform-type decision, and each region's own `orderID`-
///    derived context ([_TransformCtx.blockCtx]) is a pure function of
///    *that* region's chosen type — so no candidate's context depends on
///    which candidate wins, only the values landing in it do.
/// 3. **Level 0** (`decideLevel0`): for every 8x8 cell, a true N-way argmin
///    among plain DCT8x8 and (when [VardctL0Config.enableBespokeTransforms])
///    all 9 bespoke alternative encodings of the same footprint — every
///    candidate at a cell is scored via `_blockRate(...)` against the
///    *same* snapshot of its live `predicted` non-zero-count value (see
///    `predictedForPosition`/`updateLiveGrid` below), and the true minimum
///    is committed immediately, in one single raster sweep. This replaced
///    an earlier design (round 17 and before) that tried each bespoke type
///    as its own separate whole-image `tryMergeLevel` pass, sequentially —
///    which only ever compared a type against whatever the *previous*
///    type's own pass had already committed nearby, a real ordering
///    artifact (the same type at the same cell could score differently
///    purely because of list order) confirmed as the mechanism behind a
///    real per-page regression (see doc/spec_notes.md's round 17/18
///    entries). Runs only in the bespoke path (see the two-path structure
///    above); the baseline path never invokes it, so a bespoke-off encode
///    pays nothing for a redundant re-quantization pass and stays
///    bit-identical to its prior behavior.
/// 4. **Level 1** (`decideLevel1`): for every 2x2-cell (16x16px) region, a
///    true argmin among *stay split* (Level 0's own 4 per-cell results,
///    summed the same `distortion + lambda * _blockRate(...)` way),
///    *whole* DCT16x16 (scored the same way step 3's bootstrap-vs-16x16
///    comparison used to be, before this was generalized), and (when
///    [VardctL0Config.enableRectangularTransforms]) the DCT16x8/DCT8x16
///    half-strip pairs. A pair candidate's second sub-block has a real
///    intra-region dependency on the first's own committed fill (its
///    west/north neighbor read lands inside the first sub-block's
///    footprint) — scored via a speculative "poke, score, restore" step
///    (`writeLiveGridCells`/`snapshotGridCells`/`restoreGridCells`) so
///    every candidate in a region is compared against the exact same
///    starting state, and only the true winner's effect on the live grid
///    is made permanent. Run once per path: on the plain bootstrap
///    (baseline path) and, when bespoke is on, again on `decideLevel0`'s
///    per-cell result (bespoke path). **Level 0's own result and Level 1's
///    own result are exposed as separate candidate entries whenever each
///    differs from what came before** — not folded into a single combined
///    candidate. This isn't redundant: a region's *estimate* preferring to
///    merge into 16x16 over staying split doesn't guarantee the real
///    assembled bytes agree (found concretely: content where every cell's
///    true argmin was a bespoke type, but Level 1's estimate preferred 16x16
///    anyway, which assembled to *more* real bytes than staying split — 211B
///    vs. 167B). Without Level 0's own result as its own candidate, that
///    better layout would never have been tried for real at all.
/// 5. For each size in [_cascadeSizes] up to [VardctL0Config.maxTransformSize]
///    (32, then 64, then 128, then 256), repeat steps 3/4 one level up:
///    merge the *previous* cascade level's layout (mixed 8x8/16x16/.../
///    previous-size blocks) into the next size wherever a freshly
///    quantized candidate of that size beats the real summed cost of the
///    smaller blocks it would replace, using the same frozen bootstrap
///    code-length table every level shares (transform-type choice never
///    shifts which cluster a token routes to, only what value lands
///    there, regardless of which two sizes are being compared) but the
///    same *live*, continuously-updated prediction grid every level
///    shares too (so a 32x32 decision, for instance, sees the *real* fill
///    pattern left behind by whichever 16x16/rectangular/bespoke merges
///    already happened at its own west/north neighbors, not the original
///    all-8x8 bootstrap's). A level that merges nothing is skipped (not
///    appended as a candidate) but the cascade still tries the *next*
///    size up on the unchanged layout — a size skipping over an
///    intermediate one is architecturally rare but not provably
///    impossible, and this project's own methodology is to verify by real
///    assembly rather than assume monotonicity. Unlike Levels 0/1, this
///    cascade is still the sequential pairwise-swap chain steps 3/4 used
///    to be (each `tryMergeLevel` call comparing only against whatever the
///    immediately-prior level committed) — not yet rebuilt as a joint
///    per-region argmin; see doc/spec_notes.md's round 18 write-up for the
///    scope decision to stop at Level 1 for now.
typedef _Scored = ({
  _PlacedBlock block,
  ({List<double> dc, List<Int32List> ac, double distortion}) quant,
  int mult,
  double rate,
  double cost
});

List<(List<_PlacedBlock>, List<Int32List>)> _decideTransformLayout(
    List<List<Float32List>> planes,
    _ChromaFromLumaFit cfl,
    double refStep,
    List<double> sd,
    List<double> scaleFactor,
    List<Int32List> dcIntBootstrap,
    int bh,
    int bw,
    List<Float32List> scratchA,
    List<Float32List> scratchB,
    HfBlockContext hfctx,
    Map<int, _TransformCtx> ctxByType,
    int groupsX,
    int groupsY,
    double? lambdaOverride,
    int maxTransformSize,
    double? lambdaOverrideBeyond16,
    bool enableRectangularTransforms,
    bool enableBespokeTransforms) {
  final ctx8 = ctxByType[_tt8.type]!;
  // 1. Bootstrap: quantize the whole image as all-8x8, committing into
  // dcIntBootstrap — this becomes (unmodified) the "off" candidate's DC
  // plane, so nothing below may overwrite it; every merge level gets its
  // own clone (`tryMergeLevel`'s `dcIntNext`) instead.
  final bootstrapBlocks = <_PlacedBlock>[
    for (var by = 0; by < bh; by++)
      for (var bx = 0; bx < bw; bx++) _PlacedBlock(by, bx, _tt8),
  ];
  for (final block in bootstrapBlocks) {
    block.computeAndQuantize(planes, cfl, refStep, sd, ctx8.rawWeight,
        scaleFactor, dcIntBootstrap, bw, scratchA, scratchB);
  }
  final bootstrapByGroup =
      List<List<_PlacedBlock>>.generate(groupsX * groupsY, (_) => []);
  for (final block in bootstrapBlocks) {
    final g = (block.by ~/ 32) * groupsX + (block.bx ~/ 32);
    bootstrapByGroup[g].add(block);
  }

  // 2. Bootstrap AC tokens/clustering -> frozen rate table (`clusterMap`/
  // `lengths`; see this function's own doc comment for why re-deriving
  // these fresh at every cascade level is neither necessary — the
  // context a token routes to never depends on which candidate wins,
  // only the value landing there does — nor cheap enough to be worth it
  // regardless: `_chooseAcClustering` real-assembles several candidate
  // cluster budgets against the *entire* image's tokens to pick the
  // smallest, so it is not a statistics pass, it is several real encode
  // passes). `liveGrid` (one non-zero-count grid per group, in the exact
  // layout `HfCoefficients.getPredictedNonZeroes` expects) is seeded here
  // too, via `_computeGroupTokens`'s `grid` parameter — unlike
  // `clusterMap`/`lengths`, this piece of the rate estimate genuinely
  // does go stale level over level (a block's predicted non-zero count
  // depends on its *immediate* west/north neighbors' real fill, which
  // changes the moment either neighbor is replaced by a differently-
  // shaped merge) and is cheap to keep live: `tryMergeLevel` below reads
  // and updates it incrementally, in the same raster-scan-with-skip
  // order placement already requires, at O(1) per lookup/update — no
  // re-running `_computeGroupTokens`/`_chooseAcClustering` needed.
  final liveGrid =
      List.generate(groupsX * groupsY, (_) => Int32List(3 * 32 * 32));
  final bootstrapTokens = <_GroupTokens>[
    for (var gy = 0; gy < groupsY; gy++)
      for (var gx = 0; gx < groupsX; gx++)
        _computeGroupTokens(gy * 32, gx * 32,
            bootstrapByGroup[gy * groupsX + gx], hfctx, ctxByType,
            grid: liveGrid[gy * groupsX + gx]),
  ];
  final bootstrap = _chooseAcClustering(bootstrapTokens);
  final lengths = bootstrap.codes.tokenBitLengths();
  final clusterMap = bootstrap.clusterMap;
  final lambda = (lambdaOverride ?? _kTransformRdLambda) * refStep * refStep;

  // Snapshot the freshly bootstrap-seeded live grid. The candidate-
  // generation block at the end of this function runs two independent
  // layout paths (the plain baseline cascade, then — when bespoke is on —
  // the bespoke Level-0 layout and its own cascade); each must be scored
  // from the same starting neighbor-prediction state, so `resetLiveGrid`
  // restores this snapshot between them (see that block's own comment).
  final liveGridInit = [for (final g in liveGrid) Int32List.fromList(g)];
  void resetLiveGrid() {
    for (var i = 0; i < liveGrid.length; i++) {
      liveGrid[i].setRange(0, liveGrid[i].length, liveGridInit[i]);
    }
  }

  // Per-channel predicted non-zero count for whatever block currently (as
  // of the most recent `updateLiveGrid` call touching its west/north
  // neighbors) occupies position (by, bx) — `HfCoefficients
  // .getPredictedNonZeroes` itself only ever looks at the single cell
  // immediately west and immediately north (see that function), so
  // `liveGrid` only needs to be current there, not globally recomputed.
  Int32List predictedForPosition(int by, int bx) {
    final groupX = bx ~/ 32, groupY = by ~/ 32;
    final grid = liveGrid[groupY * groupsX + groupX];
    final localY = by - groupY * 32, localX = bx - groupX * 32;
    return Int32List.fromList([
      for (var c = 0; c < 3; c++)
        HfCoefficients.getPredictedNonZeroes(grid, c, localY, localX),
    ]);
  }

  // Records a real fill (per-channel non-zero count, `dctSelectHeight x
  // dctSelectWidth`-block-averaged the same way `_computeGroupTokens`
  // does) into `liveGrid`, so any later position whose predicted count
  // reads this footprint as its west or north neighbor sees the real
  // value, not a stale bootstrap-derived one. Takes the placement/AC data
  // directly (not a `_PlacedBlock`) so [decideLevel1] can also use it to
  // *speculatively* preview an as-yet-uncommitted candidate's effect on a
  // same-region neighbor's rate estimate (paired with [snapshotGridCells]/
  // [restoreGridCells]), without needing a fully committed block to do so.
  void writeLiveGridCells(
      TransformType tt, int by, int bx, List<Int32List> ac) {
    final groupX = bx ~/ 32, groupY = by ~/ 32;
    final grid = liveGrid[groupY * groupsX + groupX];
    final localY = by - groupY * 32, localX = bx - groupX * 32;
    final ctx = ctxByType[tt.type]!;
    final numBlocks = ctx.numBlocks;
    for (var c = 0; c < 3; c++) {
      final (_, countNonZero, _) = _scanChannelValues(ctx, ac[c]);
      final fill = (countNonZero + numBlocks - 1) ~/ numBlocks;
      for (var iy = 0; iy < tt.dctSelectHeight; iy++) {
        for (var ix = 0; ix < tt.dctSelectWidth; ix++) {
          grid[c * 1024 + (localY + iy) * 32 + (localX + ix)] = fill;
        }
      }
    }
  }

  void updateLiveGrid(_PlacedBlock block) {
    writeLiveGridCells(block.tt, block.by, block.bx, block.acInt);
  }

  // Saves/restores exactly the cells [writeLiveGridCells] would touch for
  // a `(tt, by, bx)` footprint — used by [decideLevel1] to undo a
  // speculative poke once a pair candidate's second sub-block has been
  // scored against it, so a region's own candidates are always compared
  // against the same starting state regardless of scoring order, and only
  // the true winner's effect on the live grid is made permanent.
  List<int> snapshotGridCells(TransformType tt, int by, int bx) {
    final groupX = bx ~/ 32, groupY = by ~/ 32;
    final grid = liveGrid[groupY * groupsX + groupX];
    final localY = by - groupY * 32, localX = bx - groupX * 32;
    return [
      for (var c = 0; c < 3; c++)
        for (var iy = 0; iy < tt.dctSelectHeight; iy++)
          for (var ix = 0; ix < tt.dctSelectWidth; ix++)
            grid[c * 1024 + (localY + iy) * 32 + (localX + ix)],
    ];
  }

  void restoreGridCells(TransformType tt, int by, int bx, List<int> snapshot) {
    final groupX = bx ~/ 32, groupY = by ~/ 32;
    final grid = liveGrid[groupY * groupsX + groupX];
    final localY = by - groupY * 32, localX = bx - groupX * 32;
    var i = 0;
    for (var c = 0; c < 3; c++) {
      for (var iy = 0; iy < tt.dctSelectHeight; iy++) {
        for (var ix = 0; ix < tt.dctSelectWidth; ix++) {
          grid[c * 1024 + (localY + iy) * 32 + (localX + ix)] = snapshot[i++];
        }
      }
    }
  }

  // 3/4/5. Per-region decision, in the same raster-scan-with-skip order the
  // decoder's placement reconstructs from the flat block list. One shared
  // closure handles every level — the rectangular pre-pass (Tranche B),
  // level 1's 8x8-vs-16x16 decision, and every [_cascadeSizes] entry beyond
  // it: for every candidate region aligned to a target type's own
  // dctSelectHeight x dctSelectWidth footprint, compare the real summed
  // cost of whatever distinct blocks the *previous* layout already placed
  // there against a freshly quantized candidate of that type, keeping
  // whichever is smaller. `layoutBlockAt` is a one-cell-per-block lookup
  // into the *current* layout's mixed footprints, using each block's own
  // independent height/width (not assumed square, unlike the code this
  // replaced).
  //
  // The containment guard below is required once non-nesting shapes coexist
  // (DCT 16x8 and DCT 8x16 share no containment relationship — each spans
  // cells the other doesn't): without it, a region's `seen` set could
  // collect a block that only partially overlaps the candidate's footprint,
  // and committing over it would silently orphan whatever cells that block
  // also owned outside the region — a corrupt block list (some cells
  // covered by nothing), not just a suboptimal choice. For every *square*
  // level (level 1, and every [_cascadeSizes] entry — the only cases before
  // Tranche B) this is a structural no-op: each square size is a multiple
  // of the previous one and every region is square-aligned, so containment
  // always holds automatically — Tranche A behavior is provably unaffected.
  //
  // Every non-merged cell gets an independent `.copy()` (not the previous
  // layout's own instance) so candidates never alias the same mutable
  // `_PlacedBlock` — the caller runs RD-hfMult/RDOQ separately on each
  // candidate, and those passes mutate hfMult/acInt in place (see
  // `_PlacedBlock.copy`'s doc comment).
  // Quantizes a fresh candidate of `tt` at `(by,bx)` and scores it against
  // `predictedForPosition(by,bx)` — never mutates anything (the block
  // returned is uncommitted; the caller decides whether to `commit()` it).
  // Extracted from `tryMergeLevel`'s own inline body so `decideLevel0`/
  // `decideLevel1` below can score arbitrary candidates the same way,
  // without a merge decision's `costIn`/`layoutBlockAt` bookkeeping.
  _Scored scoreFreshCandidate(
      int by, int bx, TransformType tt, double lambdaForLevel) {
    final ctx = ctxByType[tt.type]!;
    final candidate = _PlacedBlock(by, bx, tt);
    final coeffBuf = candidate.computeCoeffBuf(planes, cfl, scratchA, scratchB);
    final (mult, quant) = candidate.chooseCandidate(
        coeffBuf, refStep, sd, ctx.rawWeight, scaleFactor);
    final rate = _blockRate(ctx, hfctx, quant.ac, predictedForPosition(by, bx),
        clusterMap, lengths);
    final cost = quant.distortion + lambdaForLevel * rate;
    return (block: candidate, quant: quant, mult: mult, rate: rate, cost: cost);
  }

  (List<_PlacedBlock>, List<Int32List>, bool) tryMergeLevel(
      List<_PlacedBlock> layoutIn,
      List<Int32List> dcIntIn,
      TransformType targetType,
      double lambdaForLevel) {
    final strideY = targetType.dctSelectHeight;
    final strideX = targetType.dctSelectWidth;
    final layoutBlockAt = List<_PlacedBlock?>.filled(bh * bw, null);
    for (final block in layoutIn) {
      final blockH = block.tt.dctSelectHeight, blockW = block.tt.dctSelectWidth;
      for (var dy = 0; dy < blockH; dy++) {
        for (var dx = 0; dx < blockW; dx++) {
          layoutBlockAt[(block.by + dy) * bw + (block.bx + dx)] = block;
        }
      }
    }
    // Every block's real rate computed on demand against its own current
    // (live-grid) `predicted` value — cheap (a handful of array reads plus
    // one already-quantized block's own token pass, not an image-wide
    // pass), and only once per distinct block thanks to `seen` below.
    double blockRateIn(_PlacedBlock block) {
      return _blockRate(ctxByType[block.tt.type]!, hfctx, block.acInt,
          predictedForPosition(block.by, block.bx), clusterMap, lengths);
    }

    final dcIntNext = [for (final ch in dcIntIn) Int32List.fromList(ch)];
    final next = <_PlacedBlock>[];
    final covered = List<bool>.filled(bh * bw, false);
    var anyMerge = false;
    for (var by = 0; by < bh; by++) {
      for (var bx = 0; bx < bw; bx++) {
        if (covered[by * bw + bx]) continue;
        final canPair = by % strideY == 0 &&
            bx % strideX == 0 &&
            by + strideY - 1 < bh &&
            bx + strideX - 1 < bw;
        _PlacedBlock? merged;
        if (canPair) {
          final seen = <_PlacedBlock>{};
          var costIn = 0.0;
          var mergeable = true;
          outer:
          for (var dy = 0; dy < strideY; dy++) {
            for (var dx = 0; dx < strideX; dx++) {
              final block = layoutBlockAt[(by + dy) * bw + (bx + dx)]!;
              if (block.by < by ||
                  block.bx < bx ||
                  block.by + block.tt.dctSelectHeight > by + strideY ||
                  block.bx + block.tt.dctSelectWidth > bx + strideX) {
                mergeable = false;
                break outer;
              }
              if (seen.add(block)) {
                costIn +=
                    block.distortion + lambdaForLevel * blockRateIn(block);
              }
            }
          }

          if (mergeable) {
            final scored =
                scoreFreshCandidate(by, bx, targetType, lambdaForLevel);
            if (scored.cost < costIn) {
              assert(
                  scored.block.by % targetType.dctSelectHeight == 0 &&
                      scored.block.bx % targetType.dctSelectWidth == 0,
                  'merge candidate not aligned to its own dctSelect '
                  'footprint');
              scored.block.commit(scored.quant, scored.mult, dcIntNext, bw);
              updateLiveGrid(scored.block);
              merged = scored.block;
            }
          }
        }
        if (merged != null) {
          anyMerge = true;
          for (var dy = 0; dy < strideY; dy++) {
            for (var dx = 0; dx < strideX; dx++) {
              covered[(by + dy) * bw + (bx + dx)] = true;
            }
          }
          next.add(merged);
        } else {
          final block = layoutBlockAt[by * bw + bx]!;
          covered[by * bw + bx] = true;
          // Only emit at the block's own origin — a multi-cell block is
          // visited (and skipped-as-covered) more than once by this
          // raster scan, but must land in `next` exactly once.
          if (block.by == by && block.bx == bx) {
            next.add(block.copy());
          }
        }
      }
    }
    return (next, dcIntNext, anyMerge);
  }

  // Level 0: a true N-way argmin per 8x8 cell among DCT8x8 and (when
  // enabled) all 9 bespoke alternative encodings of the same footprint —
  // replaces the old sequential bespoke pre-pass, which only ever
  // compared "this bespoke type" against whatever the *previous* bespoke
  // type's own whole-image pass had already committed nearby (an
  // ordering artifact: a cell's *rate* estimate depends on its west/north
  // neighbors' live-grid fill, which each separate pass mutates as it
  // goes — so the same type at the same cell could score differently
  // purely because of list order, not because of anything about the cell
  // itself; see doc/spec_notes.md's round 18 write-up, which traces this
  // to round 17's real per-page regression from `enableBespokeTransforms`
  // alone). One single raster sweep instead: every candidate at a cell is
  // scored against the exact same snapshot (whatever's already finalized
  // to its west/north), and the true minimum is committed once,
  // immediately updating the live grid before the next cell's turn — this
  // removes the ordering artifact by construction, not just reorganizes
  // it. When bespoke is off there is only one candidate everywhere
  // (DCT8x8), so this returns the bootstrap unchanged rather than paying
  // for a redundant re-quantization pass.
  (List<_PlacedBlock>, List<Int32List>) decideLevel0(
      bool enableBespokeTransforms) {
    if (!enableBespokeTransforms) {
      return (bootstrapBlocks, dcIntBootstrap);
    }
    final types = [
      _tt8,
      _ttHornuss,
      _ttDct2x2,
      _tt4x4,
      _ttDct4x8,
      _ttDct8x4,
      _ttAfv0,
      _ttAfv1,
      _ttAfv2,
      _ttAfv3,
    ];
    final dcIntNext = [for (final ch in dcIntBootstrap) Int32List.fromList(ch)];
    final result = <_PlacedBlock>[];
    for (var by = 0; by < bh; by++) {
      for (var bx = 0; bx < bw; bx++) {
        var best = scoreFreshCandidate(by, bx, types[0], lambda);
        for (var i = 1; i < types.length; i++) {
          final scored = scoreFreshCandidate(by, bx, types[i], lambda);
          if (scored.cost < best.cost) best = scored;
        }
        best.block.commit(best.quant, best.mult, dcIntNext, bw);
        updateLiveGrid(best.block);
        result.add(best.block);
      }
    }
    return (result, dcIntNext);
  }

  // Level 1: a true argmin per 2x2-cell (16x16px) region among "stay
  // split" (Level 0's own 4 per-cell decisions), the whole DCT16x16, and
  // (when enabled) the DCT16x8/DCT8x16 half-strip pairs — replaces the
  // old sequential rectangular pre-pass (which tried 16x8 then 8x16 as
  // two separate whole-image passes, each only comparing against
  // whatever the *other* orientation's pass had already committed) and
  // the old always-on 16x16 decision (a separate, later, single-candidate
  // comparison against whatever the rectangular pre-pass left behind).
  // Assumes its input is exactly one 1x1-footprint block per cell — true
  // of [decideLevel0]'s output, not true in general, so this simplified
  // direct-lookup form (no `layoutBlockAt`-style containment scanning)
  // must not be reused for a hypothetical Level 2+ built on Level 1's own
  // *mixed* output.
  //
  // A pair candidate's second sub-block has a real intra-region live-grid
  // dependency on the first sub-block's own fill (its west/north neighbor
  // read lands inside the first sub-block's footprint — e.g. the 16x8
  // pair's right block reads its west neighbor, which is the left
  // block's own origin cell). Scored via a speculative
  // "poke, score, restore" step (`writeLiveGridCells`/`snapshotGridCells`/
  // `restoreGridCells`) so every candidate in a region — split, whole, and
  // both pair orientations — is compared against the exact same starting
  // state, and only the true winner's effect on the live grid is made
  // permanent (a real `commit()`+`updateLiveGrid()`, reproducing the
  // scored state, not re-deriving it).
  // Note on list ordering (the decoder's raster-scan-with-skip placement,
  // `HfMetadata._placeBlock`, reconstructs every block's position purely
  // from flat-list order — there is no explicit coordinate in the
  // bitstream): a region's decision can place a block whose origin is in
  // the region's *second* row (stay-split's bottom two cells; the 8x16
  // pair's bottom half), which must not reach [result] until the sweep
  // has finished every region in the *first* row of this same row-pair —
  // otherwise a later region at, say, `(by, bx+2)` would have its own
  // first-row block appended after an earlier region's second-row block,
  // desyncing the decoder's placement. Handled by processing one row-pair
  // at a time, bucketing each decision's blocks into `topRow`/`bottomRow`
  // by which row their own origin falls in, and appending `topRow` then
  // `bottomRow` only once the whole row-pair is decided.
  (List<_PlacedBlock>, List<Int32List>, bool) decideLevel1(
      List<_PlacedBlock> layout0,
      List<Int32List> dcInt0,
      bool enableRectangularTransforms) {
    final dcIntNext = [for (final ch in dcInt0) Int32List.fromList(ch)];
    final result = <_PlacedBlock>[];
    var anyMerged = false;

    double splitBlockRate(_PlacedBlock b) => _blockRate(ctxByType[b.tt.type]!,
        hfctx, b.acInt, predictedForPosition(b.by, b.bx), clusterMap, lengths);

    for (var by = 0; by < bh; by += 2) {
      if (by + 1 >= bh) {
        // Stray final row (odd `bh`) — no 2x2 region possible here.
        for (var bx = 0; bx < bw; bx++) {
          result.add(layout0[by * bw + bx].copy());
        }
        continue;
      }
      final topRow = <_PlacedBlock>[];
      final bottomRow = <_PlacedBlock>[];
      var bx = 0;
      while (bx < bw) {
        if (bx + 1 >= bw) {
          // Stray final column (odd `bw`) — no 2x2 region possible here.
          topRow.add(layout0[by * bw + bx].copy());
          bottomRow.add(layout0[(by + 1) * bw + bx].copy());
          bx += 1;
          continue;
        }

        final c00 = layout0[by * bw + bx];
        final c01 = layout0[by * bw + bx + 1];
        final c10 = layout0[(by + 1) * bw + bx];
        final c11 = layout0[(by + 1) * bw + bx + 1];
        final splitCost = c00.distortion +
            lambda * splitBlockRate(c00) +
            c01.distortion +
            lambda * splitBlockRate(c01) +
            c10.distortion +
            lambda * splitBlockRate(c10) +
            c11.distortion +
            lambda * splitBlockRate(c11);

        final whole = scoreFreshCandidate(by, bx, _tt16, lambda);
        var bestCost = splitCost;
        // null = stay split. Otherwise the winning candidate's own
        // sub-blocks, each already tagged with which row bucket it
        // belongs to via its own `.by`.
        List<_Scored>? bestPair;
        if (whole.cost < bestCost) {
          bestCost = whole.cost;
          bestPair = [whole];
        }

        if (enableRectangularTransforms) {
          // 16x8 (tall) pair: left (by,bx), right (by,bx+1) — side by
          // side, each spanning both rows, both origins in the top row.
          final left = scoreFreshCandidate(by, bx, _tt16x8, lambda);
          final leftSnapshot = snapshotGridCells(_tt16x8, by, bx);
          writeLiveGridCells(_tt16x8, by, bx, left.quant.ac);
          final right = scoreFreshCandidate(by, bx + 1, _tt16x8, lambda);
          restoreGridCells(_tt16x8, by, bx, leftSnapshot);
          final pairCostV = left.cost + right.cost;
          if (pairCostV < bestCost) {
            bestCost = pairCostV;
            bestPair = [left, right];
          }

          // 8x16 (wide) pair: top (by,bx), bottom (by+1,bx) — stacked,
          // each spanning both columns; top's origin is the top row,
          // bottom's origin is the bottom row.
          final top = scoreFreshCandidate(by, bx, _tt8x16, lambda);
          final topSnapshot = snapshotGridCells(_tt8x16, by, bx);
          writeLiveGridCells(_tt8x16, by, bx, top.quant.ac);
          final bottom = scoreFreshCandidate(by + 1, bx, _tt8x16, lambda);
          restoreGridCells(_tt8x16, by, bx, topSnapshot);
          final pairCostH = top.cost + bottom.cost;
          if (pairCostH < bestCost) {
            bestCost = pairCostH;
            bestPair = [top, bottom];
          }
        }

        if (bestPair == null) {
          topRow
            ..add(c00.copy())
            ..add(c01.copy());
          bottomRow
            ..add(c10.copy())
            ..add(c11.copy());
        } else {
          anyMerged = true;
          for (final scored in bestPair) {
            scored.block.commit(scored.quant, scored.mult, dcIntNext, bw);
            updateLiveGrid(scored.block);
            (scored.block.by == by ? topRow : bottomRow).add(scored.block);
          }
        }
        bx += 2;
      }
      result.addAll(topRow);
      result.addAll(bottomRow);
    }
    return (result, dcIntNext, anyMerged);
  }

  final candidates = <(List<_PlacedBlock>, List<Int32List>)>[
    (bootstrapBlocks, dcIntBootstrap),
  ];
  final lambdaBeyond16 =
      (lambdaOverrideBeyond16 ?? _kTransformRdLambdaBeyond16) *
          refStep *
          refStep;

  // Runs the Level 1 (16x16) decision, the "4:1 line" rectangular pair, and
  // the [_cascadeSizes] cascade (32..256) starting from `startLayout` — which
  // must be exactly one 1x1-footprint block per cell (the plain bootstrap, or
  // [decideLevel0]'s per-cell result) — appending every level that changes
  // anything as its own candidate. The shared `liveGrid` must already reflect
  // `startLayout`'s own fills when this is called (true right after seeding
  // for the bootstrap, and right after [decideLevel0] commits for the bespoke
  // layout), since every level scores against it and evolves it in place.
  //
  // Level 1: a true argmin per 16x16 region among stay-split, whole 16x16,
  // and (when [enableRectangularTransforms]) the 16x8/8x16 half-strip pairs —
  // see [decideLevel1]'s own doc comment.
  //
  // The "4:1 line" pair (wide 8x32, tall 32x8 — the only 4:1 case in the
  // format) and the generic cascade run *after* Level 1, on its output, via
  // the sequential pairwise `tryMergeLevel` chain (not yet a joint per-region
  // argmin; see doc/spec_notes.md's round 18 scope note). A level that merges
  // nothing is skipped as a candidate but the cascade still tries the next
  // size up on the unchanged layout — see this function's doc comment for why
  // "no 32x32 merge" doesn't provably rule out a 64x64 merge helping.
  void runCascadeFrom(
      List<_PlacedBlock> startLayout, List<Int32List> startDcInt) {
    final (layout1, dcInt1, level1Merged) =
        decideLevel1(startLayout, startDcInt, enableRectangularTransforms);
    var layout = layout1;
    var dcInt = dcInt1;
    if (level1Merged) candidates.add((layout1, dcInt1));

    if (enableRectangularTransforms) {
      for (final tt in [_tt8x32, _tt32x8]) {
        final (next, dcNext, changed) =
            tryMergeLevel(layout, dcInt, tt, lambda);
        if (changed) {
          layout = next;
          dcInt = dcNext;
          candidates.add((layout, dcInt));
        }
      }
    }

    for (var idx = 0; idx < _cascadeSizes.length; idx++) {
      final tt = _cascadeSizes[idx];
      if (tt.pixelWidth > maxTransformSize) break;
      if (enableRectangularTransforms) {
        final (wide, tall) = _cascadeRectPairs[idx];
        for (final rtt in [wide, tall]) {
          final (next, dcNext, changed) =
              tryMergeLevel(layout, dcInt, rtt, lambdaBeyond16);
          if (changed) {
            layout = next;
            dcInt = dcNext;
            candidates.add((layout, dcInt));
          }
        }
      }
      final (next, dcNext, changed) =
          tryMergeLevel(layout, dcInt, tt, lambdaBeyond16);
      if (!changed) continue; // try the next size up on the unchanged layout
      layout = next;
      dcInt = dcNext;
      candidates.add((layout, dcInt));
    }
  }

  // Baseline path (always): run the 16x16/rect/size cascade on the plain
  // all-8x8 bootstrap. This makes the *exact* layout the flags-off
  // (`enableBespokeTransforms: false`) config would produce an unconditional
  // member of the candidate pool — so the caller's real-assembly safety net
  // can never choose a layout worse than baseline, even with bespoke on.
  //
  // Round 18 lost this guarantee by running the bespoke Level 0 pass *first*:
  // when a bespoke type over-selects (its rate estimate underestimating its
  // own real cost — e.g. Hornuss chosen for ~23k of ~24k cells on one real
  // page, assembling *larger* than plain 8x8), Level 1's beneficial 16x16
  // merges were then computed against that cheap-looking bespoke split and
  // lost, and the plain-8x8 + 16x16 layout flags-off would have found was
  // never a candidate at all — a real +4% regression vs. baseline on that
  // page. A per-region *estimate* argmin (unified or not) can't fix this: the
  // bespoke estimate is what's unreliable, so it keeps winning the estimate
  // while losing the real bytes. Only a real-assembled baseline candidate in
  // the pool does. See doc/spec_notes.md's round 19 write-up.
  //
  // When bespoke is off this is the only path and reproduces the prior
  // behavior exactly (bespoke-off output stays bit-identical).
  runCascadeFrom(bootstrapBlocks, dcIntBootstrap);

  // Bespoke path (only when enabled): additionally offer the per-cell bespoke
  // Level 0 layout (a true 10-way per-cell argmin — see [decideLevel0]) and
  // its own 16x16/rect/size cascade as candidates. These win only where
  // bespoke genuinely assembles smaller (measured on the color chapter:
  // ~-1.5% at distance 4); where it regresses, the baseline path's candidates
  // above already cover the pool. The live grid is reset to its bootstrap-
  // seeded snapshot first so [decideLevel0] scores from the same starting
  // state the baseline path did, not from the plain cascade's evolved fills.
  if (enableBespokeTransforms) {
    resetLiveGrid();
    final (layout0, dcInt0) = decideLevel0(true);
    // If no cell actually chose a bespoke type, layout0 is (semantically)
    // the plain bootstrap and its cascade would just duplicate the baseline
    // path already run above — skip it.
    if (layout0.any((b) => b.tt.type != _tt8.type)) {
      candidates.add((layout0, dcInt0));
      runCascadeFrom(layout0, dcInt0);
    }
  }

  return candidates;
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
/// The decoder's `_auxDCT2` (`vardct_inverter.dart`) single-stage (`s=2`,
/// `num=1`) 2x2 Hadamard-type butterfly, applied here to invert it: given
/// this isolated application's OWN output, applying the SAME formula again
/// recovers exactly 4x the original input at every position — verified by
/// hand three times and numerically (2000 random trials, max deviation
/// 1e-14). This is used by `TransformMethod.dct4`'s forward derivation
/// (`_PlacedBlock.computeCoeffBuf`) to combine the 4 quadrants' own DC terms
/// back into the coefficient grid's top-left 2x2 corner, mirroring
/// `_auxDCT2`'s role in the decoder's `TransformMethod.dct4` case exactly.
///
/// **Do NOT reuse this for DCT2x2's 3-stage cascade** (`_auxDCT2` called at
/// `s=2`, then `4`, then `8`, each stage's output feeding the next): that
/// composition was checked independently (a 64x64 basis-injection matrix,
/// see doc/spec_notes.md) and found NOT self-inverse this way — its Gram
/// matrix has a tiered 64/16/4 diagonal, not a uniform 4, because the
/// overlapping multi-stage structure doesn't preserve the single-stage
/// property. A hand-proof (or numeric check) of one isolated application
/// does not extend to a multi-stage cascade built from it — verify any
/// future reuse of this shape numerically against the real decoder logic
/// before trusting it, don't assume.
(double, double, double, double) _dct4QuadrantButterfly(
        double c00, double c01, double c10, double c11) =>
    (
      c00 + c01 + c10 + c11,
      c00 + c01 - c10 - c11,
      c00 - c01 + c10 - c11,
      c00 - c01 - c10 + c11,
    );

/// The transpose of the decoder's `_auxDCT2` (vardct_inverter.dart) at scale
/// [s], restricted to the top-left 8x8 (the only size `TransformMethod.dct2`
/// ever uses it at). Used by `TransformMethod.dct2`'s forward derivation to
/// invert its 3-stage cascade (`_auxDCT2` at s=2, then 4, then 8) via the
/// linear-algebra identity `inverse(A) = D^-1 . A^T`, which holds here
/// because the cascade's Gram matrix `A^T . A` is diagonal — see
/// [_dct2x2GramScale]'s doc comment for the tiered diagonal itself, and
/// doc/spec_notes.md for the basis-injection proof (both this transpose and
/// the full composition were checked against the real decoder logic to 0.0
/// deviation, not assumed from the algebra alone — a previous attempt to
/// reuse [_dct4QuadrantButterfly]'s single-stage self-inverse property
/// directly on this multi-stage cascade was checked the same way and found
/// wrong).
///
/// Each stage's own 4-value combination (H4, a symmetric Hadamard tensor
/// square) is applied identically in both directions; what differs is which
/// positions are read vs. written. The decoder's `_auxDCT2` reads the 4
/// "quadrant-decimated" positions `(iy,ix)`/`(iy,ix+num)`/`(iy+num,ix)`/
/// `(iy+num,ix+num)` and writes the 4 "interleaved" positions
/// `(2*iy,2*ix)`/`(2*iy,2*ix+1)`/`(2*iy+1,2*ix)`/`(2*iy+1,2*ix+1)`. Since H4
/// is symmetric, the transpose swaps those roles: read the interleaved
/// positions, write the quadrant-decimated ones, same H4 formula.
void _auxDCT2Transposed(
    List<Float32List> coeffs, List<Float32List> result, int s) {
  for (var y = 0; y < 8; y++) {
    result[y].setRange(0, 8, coeffs[y]);
  }
  final num = s ~/ 2;
  for (var iy = 0; iy < num; iy++) {
    for (var ix = 0; ix < num; ix++) {
      final dA = coeffs[iy * 2][ix * 2];
      final dB = coeffs[iy * 2][ix * 2 + 1];
      final dC = coeffs[iy * 2 + 1][ix * 2];
      final dD = coeffs[iy * 2 + 1][ix * 2 + 1];
      result[iy][ix] = dA + dB + dC + dD;
      result[iy][ix + num] = dA + dB - dC - dD;
      result[iy + num][ix] = dA - dB + dC - dD;
      result[iy + num][ix + num] = dA - dB - dC + dD;
    }
  }
}

/// The diagonal of `TransformMethod.dct2`'s 3-stage cascade's Gram matrix
/// (`A^T . A`, where `A` is the cascade as a 64x64 linear map): each of the 3
/// stages (`s=2`,`4`,`8`) multiplies the energy of every position within its
/// own `s x s` footprint by 4 (H4's row norm-squared), so a position gets one
/// factor of 4 for every stage whose footprint contains it — 3 factors (64)
/// for the top-left 2x2 (inside all 3 footprints), 2 factors (16) for the
/// rest of the top-left 4x4, 1 factor (4) for everywhere else. Confirmed by
/// basis injection against the real decoder logic (doc/spec_notes.md), not
/// derived from this argument alone.
double _dct2x2GramScale(int row, int col) {
  var scale = 4.0;
  if (row < 4 && col < 4) scale *= 4.0;
  if (row < 2 && col < 2) scale *= 4.0;
  return scale;
}

class _PlacedBlock {
  _PlacedBlock(this.by, this.bx, this.tt);

  final int by, bx;
  final TransformType tt;
  int hfMult = 1;

  /// Weighted-squared-error distortion of the committed candidate (see
  /// [quantizeCandidate]'s doc comment) — set by [commit], read back by
  /// [_decideTransformLayout]'s real-bit-cost region comparison, which
  /// needs each already-quantized bootstrap block's own distortion without
  /// recomputing it.
  double distortion = 0;

  /// Per semantic channel (X, Y, B): flat, row-major
  /// (`tt.pixelHeight` x `tt.pixelWidth`) quantized AC coefficients. The
  /// LLF corner (`tt.dctSelectHeight` x `tt.dctSelectWidth` positions) is
  /// unused here — those come from the DC plane on decode. Set only by
  /// [commit] (never re-set directly), so a block can be re-quantized
  /// with several candidate multipliers (see `_chooseHfMultRd`) before
  /// committing to one without violating single-assignment expectations.
  /// One narrow, documented exception: [applyRdoqDrops] (the RDOQ
  /// coefficient-dropping pass, `_rdoqBlockChannel`) zeroes individual
  /// already-committed entries in place — it only ever narrows what
  /// [commit] established (nonzero -> zero, never the reverse), so it
  /// doesn't disturb `commit`'s other invariants (hfMult, DC values).
  List<Int32List> acInt = const [];

  /// Forward DCT + chroma-from-luma pre-subtraction for this block: the
  /// shared first step of both [computeAndQuantize] (the default path)
  /// and the RD-hfMult search (`_chooseHfMultRd`, which needs to try
  /// several quantization candidates against the *same* coefficients).
  List<List<Float32List>> computeCoeffBuf(
      List<List<Float32List>> planes,
      _ChromaFromLumaFit cfl,
      List<Float32List> scratchA,
      List<Float32List> scratchB) {
    final ph = tt.pixelHeight, pw = tt.pixelWidth;
    final coeffBuf = [
      for (var c = 0; c < 3; c++) List.generate(ph, (_) => Float32List(pw))
    ];
    // scratchA/scratchB are shared, max-sized buffers (see
    // _maxTransformPixelSize's doc comment) — forwardDCT2D only ever
    // touches the [0, ph) x [0, pw) sub-region a call passes explicitly, so
    // one pair covers every active transform type without a size dispatch.
    if (tt.transformMethod == TransformMethod.dct4) {
      // Verified as the exact algebraic inverse of the decoder's
      // TransformMethod.dct4 case (vardct_inverter.dart) via a 64x64
      // basis-injection matrix check (M @ E == I to 4.4e-16) before being
      // trusted — see doc/spec_notes.md. Per quadrant: forwardDCT2D of the
      // TRANSPOSED quadrant recovers the coefficient grid that
      // inverseDCT2D(...,transposed=true) would reconstruct, since
      // transposed=true computes transpose(inverseDCT2D(...,false)) and
      // forwardDCT2D is already the proven exact inverse of
      // inverseDCT2D(...,false) (every Tranche A/B LLF-inversion test
      // depends on this). The 4 quadrants' own DC terms (position (0,0) of
      // each quadrant's forward DCT) are then combined via
      // _dct4QuadrantButterfly, mirroring the decoder's own _auxDCT2 call.
      final quadTransposed = List.generate(4, (_) => Float32List(4));
      final quadCoeffs = List.generate(4, (_) => Float32List(4));
      for (var c = 0; c < 3; c++) {
        final quadDC = List.generate(2, (_) => Float32List(2));
        for (var qy = 0; qy < 2; qy++) {
          for (var qx = 0; qx < 2; qx++) {
            for (var iy = 0; iy < 4; iy++) {
              final srcRow = planes[c][by * 8 + qy * 4 + iy];
              final srcBase = bx * 8 + qx * 4;
              for (var ix = 0; ix < 4; ix++) {
                quadTransposed[ix][iy] = srcRow[srcBase + ix];
              }
            }
            forwardDCT2D(quadTransposed, quadCoeffs, 0, 0, 0, 0, 4, 4, scratchA,
                scratchB);
            quadDC[qy][qx] = quadCoeffs[0][0];
            for (var iy = 0; iy < 4; iy++) {
              for (var ix = 0; ix < 4; ix++) {
                if (iy == 0 && ix == 0) continue;
                coeffBuf[c][qy + iy * 2][qx + ix * 2] = quadCoeffs[iy][ix];
              }
            }
          }
        }
        final (e00, e01, e10, e11) = _dct4QuadrantButterfly(
            quadDC[0][0], quadDC[0][1], quadDC[1][0], quadDC[1][1]);
        coeffBuf[c][0][0] = e00 / 4;
        coeffBuf[c][0][1] = e01 / 4;
        coeffBuf[c][1][0] = e10 / 4;
        coeffBuf[c][1][1] = e11 / 4;
      }
    } else if (tt.transformMethod == TransformMethod.hornuss) {
      // Verified as the exact algebraic inverse of the decoder's
      // TransformMethod.hornuss case (vardct_inverter.dart) via a 64x64
      // basis-injection matrix check (0.0 deviation) before being trusted —
      // see doc/spec_notes.md. The decoder sets each quadrant's local pixel
      // (1,1) to a "center" value and every other local pixel to a raw
      // coefficient plus that center, EXCEPT positions (0,0) and (1,1) swap
      // roles: pixel(0,0) uses the coefficient that "should" belong to
      // (1,1), and (1,1) itself carries no separate coefficient (it IS the
      // center). Forward: center = pixel(1,1) directly (a one-to-one
      // assignment, not solved for) — every other coefficient is then
      // `pixel - center`, and algebra shows the quadrant's blockLF (combined
      // across quadrants via the same single-stage butterfly TransformMethod
      // .dct4 uses) is exactly the quadrant's own pixel mean.
      for (var c = 0; c < 3; c++) {
        final blockLF = List.generate(2, (_) => Float32List(2));
        for (var qy = 0; qy < 2; qy++) {
          final baseY = by * 8 + qy * 4;
          for (var qx = 0; qx < 2; qx++) {
            final baseX = bx * 8 + qx * 4;
            var sum = 0.0;
            for (var iy = 0; iy < 4; iy++) {
              final row = planes[c][baseY + iy];
              for (var ix = 0; ix < 4; ix++) {
                sum += row[baseX + ix];
              }
            }
            blockLF[qy][qx] = sum * 0.0625;
            final center = planes[c][baseY + 1][baseX + 1];
            for (var iy = 0; iy < 4; iy++) {
              final row = planes[c][baseY + iy];
              for (var ix = 0; ix < 4; ix++) {
                if ((iy == 0 && ix == 0) || (iy == 1 && ix == 1)) continue;
                coeffBuf[c][qy + iy * 2][qx + ix * 2] =
                    row[baseX + ix] - center;
              }
            }
            coeffBuf[c][qy + 2][qx + 2] = planes[c][baseY][baseX] - center;
          }
        }
        final (e00, e01, e10, e11) = _dct4QuadrantButterfly(
            blockLF[0][0], blockLF[0][1], blockLF[1][0], blockLF[1][1]);
        coeffBuf[c][0][0] = e00 / 4;
        coeffBuf[c][0][1] = e01 / 4;
        coeffBuf[c][1][0] = e10 / 4;
        coeffBuf[c][1][1] = e11 / 4;
      }
    } else if (tt.transformMethod == TransformMethod.dct2) {
      // Verified as the exact algebraic inverse of the decoder's
      // TransformMethod.dct2 case (vardct_inverter.dart, 3 chained _auxDCT2
      // calls at s=2/4/8) via a 64x64 basis-injection matrix check (0.0
      // deviation) before being trusted — see doc/spec_notes.md. Unlike
      // dct4/hornuss's single-stage butterfly, this composition is NOT
      // self-inverse up to a uniform factor: its Gram matrix has a *tiered*
      // diagonal (64/16/4 depending on position), so inverting it is
      // `transpose(cascade) / tieredScale`, not `cascade / 4` again — see
      // _auxDCT2Transposed's doc comment for why the transpose has this
      // simple closed form.
      for (var c = 0; c < 3; c++) {
        for (var y = 0; y < 8; y++) {
          final row = planes[c][by * 8 + y];
          final base = bx * 8;
          final dst = coeffBuf[c][y];
          for (var x = 0; x < 8; x++) {
            dst[x] = row[base + x];
          }
        }
        _auxDCT2Transposed(coeffBuf[c], scratchA, 8);
        _auxDCT2Transposed(scratchA, scratchB, 4);
        _auxDCT2Transposed(scratchB, coeffBuf[c], 2);
        for (var y = 0; y < 8; y++) {
          final dst = coeffBuf[c][y];
          for (var x = 0; x < 8; x++) {
            dst[x] /= _dct2x2GramScale(y, x);
          }
        }
      }
    } else if (tt.transformMethod == TransformMethod.dct4x8) {
      // Verified as the exact algebraic inverse of the decoder's
      // TransformMethod.dct4x8 case (vardct_inverter.dart) via a 64x64
      // basis-injection matrix check (2.2e-15 deviation) before being
      // trusted — see doc/spec_notes.md. The block splits into a top and
      // bottom 4x8 pixel strip; each strip's own forwardDCT2D(height=4,
      // width=8) gives that strip's coefficients directly (no transpose
      // needed, since the decoder reconstructs each with
      // inverseDCT2D(...,transposed=false)). The 2 strips' own DC terms
      // combine via a plain 2-point Hadamard (sum/difference), the 1D
      // analog of _dct4QuadrantButterfly's 4-point version — self-inverse
      // up to /2, mirroring the decoder's `lfs = [c0+c1, c0-c1]`.
      final strip = List.generate(4, (_) => Float32List(8));
      final stripCoeffs = List.generate(4, (_) => Float32List(8));
      for (var c = 0; c < 3; c++) {
        final lf = Float32List(2);
        for (var y = 0; y < 2; y++) {
          for (var iy = 0; iy < 4; iy++) {
            final srcRow = planes[c][by * 8 + y * 4 + iy];
            final srcBase = bx * 8;
            for (var ix = 0; ix < 8; ix++) {
              strip[iy][ix] = srcRow[srcBase + ix];
            }
          }
          forwardDCT2D(
              strip, stripCoeffs, 0, 0, 0, 0, 4, 8, scratchA, scratchB);
          lf[y] = stripCoeffs[0][0];
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 8; ix++) {
              if (iy == 0 && ix == 0) continue;
              coeffBuf[c][y + iy * 2][ix] = stripCoeffs[iy][ix];
            }
          }
        }
        coeffBuf[c][0][0] = (lf[0] + lf[1]) / 2;
        coeffBuf[c][1][0] = (lf[0] - lf[1]) / 2;
      }
    } else if (tt.transformMethod == TransformMethod.dct8x4) {
      // Verified the same way as dct4x8 above (64x64 basis-injection
      // matrix, 2.2e-15 deviation). The block splits into a left and right
      // 8x4 pixel strip; the decoder reconstructs each via
      // inverseDCT2D(...,height=4,width=8,transposed=true), which computes
      // transpose(inverseDCT2D(...,false)) — so the forward here is
      // forwardDCT2D of the TRANSPOSED strip (8x4 pixels -> 4x8), the same
      // transposed=true handling already established and verified for
      // TransformMethod.dct4's per-quadrant case.
      final stripT = List.generate(4, (_) => Float32List(8));
      final stripCoeffs = List.generate(4, (_) => Float32List(8));
      for (var c = 0; c < 3; c++) {
        final lf = Float32List(2);
        for (var x = 0; x < 2; x++) {
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 8; ix++) {
              // Transposed: stripT[localCol][row] = pixel(row, x*4+localCol).
              stripT[iy][ix] = planes[c][by * 8 + ix][bx * 8 + x * 4 + iy];
            }
          }
          forwardDCT2D(
              stripT, stripCoeffs, 0, 0, 0, 0, 4, 8, scratchA, scratchB);
          lf[x] = stripCoeffs[0][0];
          for (var iy = 0; iy < 4; iy++) {
            for (var ix = 0; ix < 8; ix++) {
              if (iy == 0 && ix == 0) continue;
              coeffBuf[c][x + iy * 2][ix] = stripCoeffs[iy][ix];
            }
          }
        }
        coeffBuf[c][0][0] = (lf[0] + lf[1]) / 2;
        coeffBuf[c][1][0] = (lf[0] - lf[1]) / 2;
      }
    } else if (tt.transformMethod == TransformMethod.afv) {
      // Verified as the exact algebraic inverse of the decoder's
      // TransformMethod.afv case (vardct_inverter.dart's _invertAFV,
      // including the sign combination its own "SPEC: watch signs here"
      // comment flags) via a 64x64 basis-injection matrix check (2.2e-15
      // deviation) for all 4 flip variants (AFV0-3) before being trusted —
      // see doc/spec_notes.md. The 8x8 block splits into 3 disjoint
      // regions (matching getAFVQuantWeights' own partition): a 4x4
      // "AFV-basis" region (fixed custom basis, not a DCT), a 4x4
      // "transposed DCT" region, and a 4x8 "plain DCT" region — their own
      // local DC-like terms (d1, d2, d3) combine via a fixed 3x3 linear
      // system (not the 4-point/2-point butterflies elsewhere in this
      // tranche, since AFV's 3 regions read only 3 of the block's own
      // corner coefficients, never coeffs[1][1]) with a verified closed-
      // form inverse (c00 = d1/16+d2/4+d3/2, c10 = d1/16+d2/4-d3/2,
      // c01 = d1/8-d2/2).
      //
      // Region 1 reuses `afvBasis` directly rather than needing a new
      // generated inverse table: basis injection confirmed it's exactly
      // orthonormal (M @ M.T == M.T @ M == I), so the forward map is
      // `s0 = M @ s1` where the decoder's own map is `s1 = M.T @ s0` —
      // same loop shape as the decoder, just with the two 4x4-position
      // indices' roles swapped in the flat-array lookup (`afvBasis[k*16+j]`
      // instead of `afvBasis[j*16+k]`). Region 1's target pixels are first
      // mirrored (row-reversed if flipY, column-reversed if flipX) to
      // invert the decoder's own output mirroring — self-inverse since
      // reversal is an involution.
      final s1 = List.generate(4, (_) => Float32List(4));
      final region2 = List.generate(4, (_) => Float32List(4));
      final region2Coeffs = List.generate(4, (_) => Float32List(4));
      final region3 = List.generate(4, (_) => Float32List(8));
      final region3Coeffs = List.generate(4, (_) => Float32List(8));
      final flipY = tt.type == 16 || tt.type == 17 ? 1 : 0; // AFV2, AFV3
      final flipX = tt.type == 15 || tt.type == 17 ? 1 : 0; // AFV1, AFV3
      final colOff = flipX == 1 ? 0 : 4;
      final rowOff = flipY == 1 ? 0 : 4;
      for (var c = 0; c < 3; c++) {
        // Region 1: mirror the target 4x4 corner, then apply afvBasis with
        // swapped index roles.
        for (var iy = 0; iy < 4; iy++) {
          final srcY = flipY == 1 ? 3 - iy : iy;
          final row = planes[c][by * 8 + flipY * 4 + srcY];
          final base = bx * 8 + flipX * 4;
          for (var ix = 0; ix < 4; ix++) {
            final srcX = flipX == 1 ? 3 - ix : ix;
            s1[iy][ix] = row[base + srcX];
          }
        }
        final s1Flat = Float32List(16);
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = 0; ix < 4; ix++) {
            s1Flat[iy * 4 + ix] = s1[iy][ix];
          }
        }
        final quadDC = Float32List(3); // [d1, d2, d3]
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = 0; ix < 4; ix++) {
            final k = iy * 4 + ix;
            var sample = 0.0;
            for (var j = 0; j < 16; j++) {
              sample += s1Flat[j] * afvBasis[k * 16 + j];
            }
            if (k == 0) {
              quadDC[0] = sample;
            } else {
              coeffBuf[c][iy * 2][ix * 2] = sample;
            }
          }
        }

        // Region 2: transposed 4x4 DCT.
        for (var iy = 0; iy < 4; iy++) {
          final row = planes[c][by * 8 + flipY * 4 + iy];
          final base = bx * 8 + colOff;
          for (var ix = 0; ix < 4; ix++) {
            region2[ix][iy] = row[base + ix]; // transpose while reading
          }
        }
        forwardDCT2D(
            region2, region2Coeffs, 0, 0, 0, 0, 4, 4, scratchA, scratchB);
        quadDC[1] = region2Coeffs[0][0];
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = 0; ix < 4; ix++) {
            if (iy == 0 && ix == 0) continue;
            coeffBuf[c][iy * 2][ix * 2 + 1] = region2Coeffs[iy][ix];
          }
        }

        // Region 3: plain 4x8 DCT.
        for (var iy = 0; iy < 4; iy++) {
          final row = planes[c][by * 8 + rowOff + iy];
          final base = bx * 8;
          for (var ix = 0; ix < 8; ix++) {
            region3[iy][ix] = row[base + ix];
          }
        }
        forwardDCT2D(
            region3, region3Coeffs, 0, 0, 0, 0, 4, 8, scratchA, scratchB);
        quadDC[2] = region3Coeffs[0][0];
        for (var iy = 0; iy < 4; iy++) {
          for (var ix = 0; ix < 8; ix++) {
            if (iy == 0 && ix == 0) continue;
            coeffBuf[c][1 + iy * 2][ix] = region3Coeffs[iy][ix];
          }
        }

        final d1 = quadDC[0], d2 = quadDC[1], d3 = quadDC[2];
        coeffBuf[c][0][0] = d1 / 16 + d2 / 4 + d3 / 2;
        coeffBuf[c][1][0] = d1 / 16 + d2 / 4 - d3 / 2;
        coeffBuf[c][0][1] = d1 / 8 - d2 / 2;
      }
    } else {
      for (var c = 0; c < 3; c++) {
        forwardDCT2D(planes[c], coeffBuf[c], by * 8, bx * 8, 0, 0, ph, pw,
            scratchA, scratchB);
      }
    }

    final llfH = tt.dctSelectHeight, llfW = tt.dctSelectWidth;

    // Chroma-from-luma: the decoder always adds kX/kB times the Y
    // coefficient into X/B, so that must be pre-subtracted here. The LLF
    // corner uses the *global* slope (DC/LF never varies per region — see
    // _ChromaFromLumaFit's doc comment); true AC positions use this
    // block's own 64x64-pixel region slope.
    final regionIdx = cfl.regionIndexOf(by, bx);
    final kXAc = cfl.kXRegion[regionIdx], kBAc = cfl.kBRegion[regionIdx];
    for (var y = 0; y < ph; y++) {
      final isLlfRow = y < llfH;
      for (var x = 0; x < pw; x++) {
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
    final ph = tt.pixelHeight, pw = tt.pixelWidth;
    final llfH = tt.dctSelectHeight, llfW = tt.dctSelectWidth;
    final numBlocks = llfH * llfW;

    // DC/LLF: invert the decoder's forward-DCT-of-DC-values relationship
    // (trivial identity when numBlocks == 1). Unaffected by `mult` — DC
    // uses its own dedicated scale (`sd`), never `hfMult`. The decoder's
    // _finalizeLLF (hf_coefficients.dart) builds a block's LLF corner as
    // `forwardDCT2D(dcPlane, ..., llfH, llfW, ...)` then scales by
    // `tt.llfScale` elementwise — the exact algebraic inverse (divide by
    // llfScale, then inverseDCT2D over the same llfH x llfW grid) recovers
    // the DC-plane values that reconstruct it, for *any* grid size (a
    // generalization of the 16x16-only 2x2 Hadamard-like closed form this
    // replaced; verified directly against `_finalizeLLF`'s own construction
    // in test/encode/vardct_forward_test.dart). Flat layout:
    // `dc[c * numBlocks + y * llfW + x]`, matching [commit].
    final List<double> dc;
    if (numBlocks == 1) {
      dc = [for (var c = 0; c < 3; c++) coeffBuf[c][0][0] / sd[c]];
    } else {
      dc = List<double>.filled(3 * numBlocks, 0);
      final unscaled = List.generate(llfH, (_) => Float32List(llfW));
      final dcGrid = List.generate(llfH, (_) => Float32List(llfW));
      // Scratch must be sized to the larger dimension in both axes, not
      // (llfH, llfW) — dct.dart's transposeMatrixInto writes an
      // intermediate shaped (llfW, llfH) partway through, which overflows
      // an (llfH, llfW)-sized buffer whenever the grid is genuinely
      // rectangular (llfH != llfW, first possible for Tranche B's 16x8/
      // 8x16 — every square type has llfH == llfW, so this was latent
      // until now; found by a real end-to-end encode crashing, not by the
      // isolated identity test in vardct_forward_test.dart, which supplies
      // its own oversized scratch and never exercises this allocation).
      final llfScratchSize = llfH > llfW ? llfH : llfW;
      final llfScratchA =
          List.generate(llfScratchSize, (_) => Float32List(llfScratchSize));
      final llfScratchB =
          List.generate(llfScratchSize, (_) => Float32List(llfScratchSize));
      for (var c = 0; c < 3; c++) {
        for (var y = 0; y < llfH; y++) {
          final srcRow = coeffBuf[c][y];
          final dstRow = unscaled[y];
          for (var x = 0; x < llfW; x++) {
            dstRow[x] = srcRow[x] / tt.llfScale[y * llfW + x];
          }
        }
        inverseDCT2D(unscaled, dcGrid, 0, 0, 0, 0, llfH, llfW, llfScratchA,
            llfScratchB, false);
        for (var y = 0; y < llfH; y++) {
          final row = dcGrid[y];
          for (var x = 0; x < llfW; x++) {
            dc[c * numBlocks + y * llfW + x] = row[x] / sd[c];
          }
        }
      }
    }

    final ac = [for (var c = 0; c < 3; c++) Int32List(ph * pw)];
    var distortion = 0.0;
    for (var c = 0; c < 3; c++) {
      final acc = ac[c];
      final rw = rawWeight[c];
      final sfc = scaleFactor[c] / mult;
      for (var y = 0; y < ph; y++) {
        for (var x = 0; x < pw; x++) {
          if (y < llfH && x < llfW) continue;
          final w = rw[y][x];
          final step = sfc / w;
          final trueVal = coeffBuf[c][y][x];
          final qval = (trueVal / step).round();
          acc[y * pw + x] = qval;
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
    distortion = candidate.distortion;
    final llfH = tt.dctSelectHeight, llfW = tt.dctSelectWidth;
    final numBlocks = llfH * llfW;
    if (numBlocks == 1) {
      for (var c = 0; c < 3; c++) {
        dcInt[c][by * bw + bx] = candidate.dc[c].round();
      }
    } else {
      // Matches quantizeCandidate's flat layout:
      // dc[c * numBlocks + y * llfW + x].
      for (var c = 0; c < 3; c++) {
        final base = c * numBlocks;
        for (var y = 0; y < llfH; y++) {
          final row = (by + y) * bw + bx;
          final srcRow = base + y * llfW;
          for (var x = 0; x < llfW; x++) {
            dcInt[c][row + x] = candidate.dc[srcRow + x].round();
          }
        }
      }
    }
  }

  /// Zeros out already-committed AC coefficients at the given flat
  /// (row-major, `y * tt.pixelWidth + x`) indices for channel [c] — the
  /// sole mutation the RDOQ coefficient-dropping pass (`_rdoqBlockChannel`)
  /// performs on an already-[commit]-ted block. See [acInt]'s doc comment.
  void applyRdoqDrops(int c, List<int> flatIndices) {
    final data = acInt[c];
    for (final i in flatIndices) {
      data[i] = 0;
    }
  }

  /// An independent, already-[commit]-ted copy of this block (deep-copying
  /// [acInt], not just the reference) — used by [_decideTransformLayout]
  /// to hand the two candidate bodies (the bootstrap all-8x8 layout and
  /// the decided mixed layout) fully disjoint mutable objects for a
  /// region kept as 8x8 in both. Without this, `_finishEncode`'s RD-hfMult/
  /// RDOQ passes on one candidate would mutate the very `_PlacedBlock`
  /// object the other candidate also references for that same cell.
  _PlacedBlock copy() {
    final b = _PlacedBlock(by, bx, tt)
      ..hfMult = hfMult
      ..distortion = distortion
      ..acInt = [for (final ch in acInt) Int32List.fromList(ch)];
    return b;
  }

  /// The L2 adaptive-energy heuristic (smooth/low-energy blocks get a
  /// boost — hfMultiplier can only refine *finer* than the baseline, dequant
  /// being inversely proportional to it, see doc/spec_notes.md) plus the
  /// quantization it implies, *without* committing — used both by
  /// [computeAndQuantize] (the default path) and by
  /// [_decideTransformLayout] (which needs a 16x16 region's candidate cost
  /// before deciding whether to keep it, without disturbing [dcInt] for a
  /// region it might reject).
  (int, ({List<double> dc, List<Int32List> ac, double distortion}))
      chooseCandidate(
          List<List<Float32List>> coeffBuf,
          double refStep,
          List<double> sd,
          List<List<Float32List>> rawWeight,
          List<double> scaleFactor) {
    final ph = tt.pixelHeight, pw = tt.pixelWidth;
    final llfH = tt.dctSelectHeight, llfW = tt.dctSelectWidth;

    var acEnergy = 0.0;
    final y1 = coeffBuf[1];
    for (var y = 0; y < ph; y++) {
      final row = y1[y];
      for (var x = 0; x < pw; x++) {
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
    return (
      mult,
      quantizeCandidate(coeffBuf, mult, sd, rawWeight, scaleFactor)
    );
  }

  /// Default (non-RD-search) path: compute coefficients, choose `hfMult` via
  /// [chooseCandidate], quantize, commit.
  void computeAndQuantize(
      List<List<Float32List>> planes,
      _ChromaFromLumaFit cfl,
      double refStep,
      List<double> sd,
      List<List<Float32List>> rawWeight,
      List<double> scaleFactor,
      List<Int32List> dcInt,
      int bw,
      List<Float32List> scratchA,
      List<Float32List> scratchB) {
    final coeffBuf = computeCoeffBuf(planes, cfl, scratchA, scratchB);
    final (mult, candidate) =
        chooseCandidate(coeffBuf, refStep, sd, rawWeight, scaleFactor);
    commit(candidate, mult, dcInt, bw);
  }
}

/// Per-transform-type context/order data, shared by every block of that
/// type (`blockCtx` only depends on channel/orderID/hfMult/lfIndex, and the
/// default HfBlockContext's empty qfThresholds make the hfMult argument a
/// no-op regardless of the real per-block adaptive multiplier).
class _TransformCtx {
  _TransformCtx(this.tt, HfBlockContext hfctx, this.rawWeight)
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

  /// Per-channel (semantic index order: 0=X, 1=Y, 2=B) [tt.pixelHeight] x
  /// [tt.pixelWidth] quant weight matrix, mirroring the decoder's
  /// `getDCTQuantWeights` exactly. Keying this by transform type here (not
  /// threading `rawWeight8`/`rawWeight16`-style parameters everywhere) is
  /// what lets every caller look up the right table for a mixed-type block
  /// list via `ctxByType[block.tt.type]!.rawWeight` regardless of how many
  /// transform types are active.
  final List<List<Float32List>> rawWeight;
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

/// Writes a `_readDCTParams`-shaped table (`hf_global.dart`): a shared
/// nested encoding used both standalone (`TransformMode.dct`) and inside
/// `TransformMode.dct4`'s custom-param write.
void _writeDctParamTable(BitWriter w, List<List<double>> dctParam) {
  w.writeBits(dctParam[0].length - 1, 4); // num_params - 1
  for (final p in dctParam) {
    // p[0] is divided by 64 on read (hf_global.dart's _readDCTParams).
    w.writeF16(p[0] / 64.0);
    for (final v in p.skip(1)) {
      w.writeF16(v);
    }
  }
}

/// HfGlobal + the single HfPass: quant weight tables (the library default
/// for every one of the 17 parameter slots when [customParamsByIndex] is
/// null; otherwise a custom table for each entry in [customParamsByIndex],
/// encoded per that entry's own `DctParams.mode` — this encoder now emits
/// custom params for every mode Tranche A/B/C use: `TransformMode.dct`
/// (plain DCT types), `TransformMode.dct4` (DCT4x4),
/// `TransformMode.hornuss` (Hornuss), `TransformMode.dct2` (DCT2x2),
/// `TransformMode.dct4x8` (DCT4x8/DCT8x4, sharing one parameterIndex/mode),
/// and `TransformMode.afv` (AFV0-3, also sharing one parameterIndex/mode)
/// slots, with the library default for every other slot, which costs 0
/// further bits each), a single HF preset shared by every group (cheapest
/// choice; costs 0 bits only when [numGroups] == 1), and natural
/// (unpermuted) coefficient order.
void _writeHfGlobalAndPass(
    BitWriter w, int numGroups, Map<int, DctParams>? customParamsByIndex) {
  w.writeBool(customParamsByIndex == null); // quant_all_default
  if (customParamsByIndex != null) {
    for (var index = 0; index < 17; index++) {
      final p = customParamsByIndex[index];
      if (p == null) {
        w.writeBits(TransformMode.library, 3); // 0 further bits
        continue;
      }
      switch (p.mode) {
        case TransformMode.dct:
          w.writeBits(TransformMode.dct, 3);
          _writeDctParamTable(w, p.dctParam!);
        case TransformMode.dct4:
          // The 2 raw overrides per channel FIRST, then the nested
          // dct-shaped table (matches _setupDctParam's read order). The
          // overrides are written WITHOUT the *64 scaling _readDCTParams
          // applies to a table's own first value — writing/reading them
          // with *64 (matching hf_global.dart's _setupDctParam literally,
          // which does apply it) round-trips through OUR OWN decoder
          // perfectly but was found to disagree with djxl (confirmed via a
          // real round-trip test, not assumed): djxl reconstructs a block
          // averaging toward its overall DC, having lost almost all of the
          // per-quadrant detail these override positions carry (`target[1]
          // [0]`/`target[0][1]`/`target[1][1]` are exactly the coefficient
          // positions holding the quadrant-DC-redistribution terms) — a
          // genuine decoder bug, inherited (jxlatte has the identical *64),
          // never caught before since nothing ever exercised a *custom*
          // (non-default) DCT4x4 quant table until this encoder existed.
          // Fixed on both sides (see _setupDctParam's dct4 case) and
          // reverified against djxl. See doc/spec_notes.md — hornuss/dct2's
          // `_setupDctParam` cases have the SAME `64.0 *` pattern on their
          // own params but were confirmed CORRECT as-is once this encoder
          // could exercise them (see their own `case` branches below) —
          // the distinguishing factor is that dct4's 2 values are divisors
          // layered on a separate base table, while hornuss/dct2's ARE the
          // absolute weight-table values themselves (like a dct-shaped
          // table's own band[0], which legitimately gets *64 too). AFV's
          // `_setupDctParam` case has the same pattern on its own
          // override-shaped params and remains unverified (no encoder
          // exists yet to test it against djxl) — don't assume it's fine,
          // check when implementing that type.
          w.writeBits(TransformMode.dct4, 3);
          for (final ch in p.param!) {
            for (final v in ch) {
              w.writeF16(v);
            }
          }
          _writeDctParamTable(w, p.dctParam!);
        case TransformMode.hornuss:
        case TransformMode.dct2:
          // Unlike dct4's overrides, these params ARE the raw weight-table
          // values (see getHornussQuantWeights/getDct2x2QuantWeights) — the
          // same role a dct-shaped table's own band[0] plays, which
          // legitimately gets the *64 scaling on read (_readDCTParams), so
          // mirroring that convention here (rather than dct4's fix, which
          // removed it) is correct: confirmed via djxl round-trips at
          // non-default distances with content carrying real, nonzero
          // coefficients at every position these params govern (not just
          // flat/degenerate blocks, which would hide a *64 error the way
          // dct4's went undetected for so long) — see
          // vardct_l0_test.dart's "weight-table ... positions carry real
          // signal" tests and doc/spec_notes.md. Unlike dct4, this *64
          // convention was NOT a latent bug.
          w.writeBits(p.mode, 3);
          for (final ch in p.param!) {
            for (final v in ch) {
              w.writeF16(v / 64.0);
            }
          }
        case TransformMode.dct4x8:
          // Same wire shape as dct4 above (override(s) first, no *64, then
          // the nested dct-shaped table) — shared by both DCT4x8 and DCT8x4
          // (same parameterIndex, distinguished only by
          // vardct_inverter.dart's reconstruction switch). Confirmed via
          // djxl round-trips at non-default distances (0.5, 1.0) with
          // content carrying real, nonzero coefficients at the override
          // position for both types (vardct_l0_test.dart's "genuinely wins
          // on a step+gradient pattern" tests — the pure-sine content tried
          // first was found degenerate for this purpose, same trap
          // Hornuss's own test avoided) — not assumed correct just because
          // the read side already looked right. See doc/spec_notes.md.
          w.writeBits(TransformMode.dct4x8, 3);
          for (final ch in p.param!) {
            for (final v in ch) {
              w.writeF16(v);
            }
          }
          _writeDctParamTable(w, p.dctParam!);
        case TransformMode.afv:
          // Matches _setupDctParam's read order: the 9 raw values per
          // channel first (indices 0-5 divided by 64 before writing, since
          // they're read with *64 -- see _setupDctParam's afv case for why
          // that's correct here, unlike dct4's history), then the nested
          // dctParam table (the 4x8-DCT region), then params4x4 (the
          // transposed-4x4-DCT region). Confirmed via djxl round-trips at
          // non-default distances with content carrying real, nonzero
          // signal in all 3 regions across all 4 flip variants
          // (vardct_l0_test.dart) — not assumed correct just because the
          // read side already looked structurally right, especially given
          // this type's own decoder comment flagging a sign combination
          // to double-check. See doc/spec_notes.md.
          w.writeBits(TransformMode.afv, 3);
          for (final ch in p.param!) {
            for (var i = 0; i < ch.length; i++) {
              w.writeF16(i < 6 ? ch[i] / 64.0 : ch[i]);
            }
          }
          _writeDctParamTable(w, p.dctParam!);
          _writeDctParamTable(w, p.params4x4!);
        default:
          throw UnsupportedError(
              'custom weight write not implemented for mode ${p.mode}');
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
/// Reads a block-channel's already-quantized AC coefficients into scan
/// order, applying the same transposed index (`acData[ox * n + oy]`) the
/// decoder's `flip` convention requires for every square DCT this encoder
/// emits. Shared by [_blockChannelTokens] (token emission) and the RDOQ
/// coefficient-dropping pass (`_rdoqBlockChannel`, scoring only) — pure
/// extraction, no behavior change.
(List<int>, int, int) _scanChannelValues(_TransformCtx ctx, Int32List acData) {
  final numBlocks = ctx.numBlocks;
  final ucoeffLen = ctx.orderSize - numBlocks;
  final n = ctx.tt.pixelWidth;
  var countNonZero = 0;
  var lastNonZeroK = -1;
  final vals = List<int>.filled(ucoeffLen, 0);
  final flip = ctx.tt.flip;
  for (var k = 0; k < ucoeffLen; k++) {
    final o = ctx.order[k + numBlocks];
    final oy = o >> 16, ox = o & 0xFFFF;
    // flip == true (every square DCT, plus the "tall" member of every
    // rectangular pair) transposes the scan's (y, x) relative to the
    // coefficient grid; flip == false (the "wide" member) reads directly.
    // Mirrors the decoder's posY2/posX2 swap in hf_coefficients.dart.
    final v = flip ? acData[ox * n + oy] : acData[oy * n + ox];
    vals[k] = v;
    if (v != 0) {
      countNonZero++;
      lastNonZeroK = k;
    }
  }
  return (vals, countNonZero, lastNonZeroK);
}

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
  final (vals, countNonZero, lastNonZeroK) = _scanChannelValues(ctx, acData);

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
/// (pass, group) in the decoder — [grid], if given, is written into
/// directly instead of a fresh one being allocated, so a caller that needs
/// this group's *final* fill state afterward (`_decideTransformLayout`'s
/// live prediction grid, seeded from the bootstrap pass this same call
/// already computes) gets it with no separate pass. When [predictedOut]
/// is given, records each (block, channel)'s `predicted` value there —
/// used by the RD-hfMult search (`_chooseHfMultRd`) to freeze a bootstrap
/// pass's prediction context for scoring later candidates, without
/// re-deriving it live.
_GroupTokens _computeGroupTokens(
    int groupOriginY,
    int groupOriginX,
    List<_PlacedBlock> blocksInGroup,
    HfBlockContext hfctx,
    Map<int, _TransformCtx> ctxByType,
    {Map<_PlacedBlock, Int32List>? predictedOut,
    Int32List? grid}) {
  final nonZeroesGrid = grid ?? Int32List(3 * 32 * 32);
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
      rate += _tokenRate(clusterMap, lengths, contexts[j], values[j]);
    }
  }
  return rate;
}

/// Bit cost of one (context, value) token against a frozen bootstrap
/// code-length table — the single-token core of [_blockRate], extracted
/// so the RDOQ coefficient-dropping pass (`_rdoqBlockChannel`) can price
/// individual coefficients the same way without re-deriving a whole
/// block's token sequence per candidate. See [_blockRate]'s doc comment
/// for why a frozen table (not a live rebuild) is correct here, and why
/// an unseen-token fallback of 15 bits is a real bound, not arbitrary.
double _tokenRate(
    List<int> clusterMap, List<List<int>> lengths, int contextId, int value) {
  final cluster = clusterMap[contextId];
  final (token, extraBits, _) = tokenizeHybrid(_hfConfig, value);
  final lens = lengths[cluster];
  final codeLen = token < lens.length ? lens[token] : 15;
  return (codeLen + extraBits).toDouble();
}

/// Candidate multipliers tried by the RD search — the same set the
/// default heuristic chooses from (see `_PlacedBlock.computeAndQuantize`),
/// so this isolates "does real RD scoring beat the ad hoc threshold at
/// the same discrete choice" as the only new variable (a wider candidate
/// set is deferred — see doc/spec_notes.md).
const _rdHfMultCandidates = [1, 2, 4];

/// Perceptual masking curve constants (see [VardctL0Config.perceptualMask]
/// and [_maskWeight]). Placeholders pending calibration
/// (`tool/calibrate_perceptual_mask.dart`); overridable at runtime via
/// [VardctL0Config.maskParamsOverride].
///
/// - [_kMaskHi]: distortion amplification for a maximally-smooth block
///   (relEnergy -> 0). Must be large enough to make the RD search keep a
///   smooth block's precision boost that plain weighted-MSE (weight 1) threw
///   away — i.e. to overcome the rate cost round 3's photo-favorable lambda
///   couldn't justify on absolute-MSE grounds alone.
/// - [_kMaskKnee]: the relative-AC-energy value at which the weight is halfway
///   between [_kMaskHi] and 1. Sits near the L2 heuristic's own thresholds
///   (1.0 / 4.0) so the masking transition tracks where the heuristic already
///   switches buckets.
/// - [_kMaskGamma]: transition sharpness. Higher = a more step-like cutoff
///   between "protected as smooth" and "left to masking".
const _kMaskHi = 8.0;
const _kMaskKnee = 1.5;
const _kMaskGamma = 2.0;

/// Perceptual masking multiplier applied to a block's RD distortion, as a
/// continuous function of its relative AC energy (`relEnergy = sqrt(Y AC
/// energy) / refStep`, the exact signal the L2 3-bucket heuristic buckets on
/// — see `_PlacedBlock.chooseCandidate`).
///
/// Smooth/banding-prone blocks (low `relEnergy`) get their distortion
/// amplified toward [hi] so the `distortion + lambda * rate` trade favors
/// keeping their precision; busy blocks (high `relEnergy`) revert to plain
/// weighted-MSE (weight -> 1) since visual masking hides quantization noise
/// there. Monotonically decreasing in `relEnergy`; equals `1 + (hi-1)/2` at
/// `relEnergy == knee`.
double _maskWeight(double relEnergy, double hi, double knee, double gamma) =>
    1.0 + (hi - 1.0) / (1.0 + math.pow(relEnergy / knee, gamma).toDouble());

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
///
/// **This gap gets worse, not better, at higher `distance` — and it is
/// partly a `refStep^2`-vs-`acScale^2` scaling issue after all** (a later
/// multi-distance sweep, isolated from [VardctL0Config.enableVariableTransforms]
/// to remove a confound in an earlier attempt — see
/// `tool/calibrate_rd_lambda.dart`'s module doc for the full story and
/// exact numbers). At this constant's own value (`kLambda=3000`), gradient
/// RMSE tracks the heuristic closely at `distance=1.0` (0.935 vs. 0.938)
/// but degrades to a real regression by `distance>=2.0` (1.119 vs. 0.992)
/// under this file's `refStep^2` scaling. A one-off `acScale^2` patch at
/// the `distance=1.0`-equivalent `kLambda` (≈0.01, which gives the
/// identical 0.935 at `distance=1.0`) landed within noise of the
/// heuristic at `distance>=4.0` (1.045 vs. 1.043, and 1.513 vs. 1.513 —
/// vs. `refStep^2`'s +60% and +48% at those same distances) — genuinely
/// better, not a dead end like this comment previously (and wrongly)
/// concluded. It does not fix the `distance<=2.0` case, though:
/// that's the photo-vs-banding trade-off described above, which is about
/// the distortion metric itself, not lambda's units. Net: a future
/// attempt should start from `acScale^2` scaling, not `refStep^2`, but
/// still needs the banding-aware distortion term to actually ship.
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
    List<double> scaleFactor,
    List<Int32List> dcInt,
    int bw,
    List<Float32List> scratchA,
    List<Float32List> scratchB,
    HfBlockContext hfctx,
    Map<int, _TransformCtx> ctxByType,
    int groupsX,
    int groupsY,
    List<List<_PlacedBlock>> blocksByGroup,
    double? lambdaOverride,
    bool perceptualMask,
    ({double hi, double knee, double gamma})? maskOverride,
    double acScale) {
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
  // The masking path uses acScale^2 scaling (round 3's mandated fix: refStep^2
  // grows the rate/distortion trade in the *opposite* direction from how this
  // metric scales with the dequant table as distance rises, causing a
  // high-distance banding-protection collapse — see _kRdLambda's doc comment).
  // The plain (non-mask) path keeps refStep^2 so round 3's calibrated (if
  // unshipped) _kRdLambda is undisturbed.
  final maskParams = perceptualMask
      ? (maskOverride ?? (hi: _kMaskHi, knee: _kMaskKnee, gamma: _kMaskGamma))
      : null;
  final lambda = perceptualMask
      ? kLambda * acScale * acScale
      : kLambda * refStep * refStep;

  final chosenHistogram = const bool.fromEnvironment('jxl.encdebug')
      ? <int, int>{for (final m in _rdHfMultCandidates) m: 0}
      : null;
  for (final block in placedBlocks) {
    final coeffBuf = block.computeCoeffBuf(planes, cfl, scratchA, scratchB);
    final ctx = ctxByType[block.tt.type]!;
    final rawWeight = ctx.rawWeight;
    final predicted = predictedOut[block]!;

    // Per-block perceptual masking weight on distortion (constant across this
    // block's candidates). Uses the same relative-Y-AC-energy signal the L2
    // heuristic buckets on (`_PlacedBlock.chooseCandidate`). 1.0 when masking
    // is off, so this is a pure no-op vs. round 3's plain weighted-MSE search.
    var maskWeight = 1.0;
    if (maskParams != null) {
      final tt = block.tt;
      final ph = tt.pixelHeight, pw = tt.pixelWidth;
      final llfH = tt.dctSelectHeight, llfW = tt.dctSelectWidth;
      final y1 = coeffBuf[1];
      var acEnergy = 0.0;
      for (var y = 0; y < ph; y++) {
        final row = y1[y];
        for (var x = 0; x < pw; x++) {
          if (y < llfH && x < llfW) continue;
          acEnergy += row[x] * row[x];
        }
      }
      final relEnergy = math.sqrt(acEnergy) / refStep;
      maskWeight = _maskWeight(
          relEnergy, maskParams.hi, maskParams.knee, maskParams.gamma);
    }

    var bestCost = double.infinity;
    var bestMult = _rdHfMultCandidates[0];
    ({List<double> dc, List<Int32List> ac, double distortion})? bestCandidate;
    for (final mult in _rdHfMultCandidates) {
      final candidate =
          block.quantizeCandidate(coeffBuf, mult, sd, rawWeight, scaleFactor);
      final rate =
          _blockRate(ctx, hfctx, candidate.ac, predicted, clusterMap, lengths);
      final cost = maskWeight * candidate.distortion + lambda * rate;
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

/// Rate/distortion trade-off constant for RDOQ (`_chooseAcRdoq`/
/// `_rdoqBlockChannel`): `lambda = kLambda * acScale^2` — **not**
/// `refStep^2` like `_kRdLambda` (see its doc comment for why that
/// scaling is textbook-correct for a *rounding-error* distortion model).
/// The first version of this constant used `refStep^2` too, copied from
/// `_kRdLambda` without independently checking whether RDOQ's own
/// distortion metric has the same scaling behavior — it doesn't (see
/// below) — and shipped a severe, distance-dependent regression as a
/// result (roughly doubled RMSE at `distance=8.0`) before a broader
/// benchmark sweep caught it. Root cause: RDOQ's distortion, `(w*trueVal)
/// ^2 - (w*oldErr)^2`, is dominated for any non-marginal coefficient by
/// `(w*trueVal)^2` — a *removal* cost, not a rounding-noise term — and
/// `w` (the per-frequency `rawWeight` table) scales *proportionally*
/// with `acScale` (verified exactly, not approximately — see L2's
/// "scaling only the first band" finding in doc/spec_notes.md), so
/// `distortionDelta ∝ acScale^2`. `refStep ∝ 1/acScale`, so the old
/// `lambda ∝ refStep^2 ∝ 1/acScale^2` scaled in the *opposite* direction
/// from `distortionDelta` — their ratio grew as `acScale^-4`, a severe
/// compounding mismatch at coarse quantization (small `acScale`).
/// `lambda ∝ acScale^2` cancels the dominant `acScale`-dependence in
/// both terms, keeping the trade-off point governed mainly by coefficient
/// content and rate — not by `distance`. **Verified, not just derived**:
/// this direction change alone (with the *old* numeric constant) already
/// eliminated the catastrophic high-distance blowup in testing, though
/// the old magnitude was wildly wrong given the ~10^8 unit change between
/// `refStep^2` (~3e-6 at `distance=1`) and `acScale^2` (`=1` at
/// `distance=1`) — this value is freshly recalibrated for the new
/// formula via `tool/calibrate_rdoq_lambda.dart`'s **multi-distance**
/// sweep (0.5-8.0, not the single point that let the first regression
/// through undetected). See doc/spec_notes.md for the full sweep and
/// measured numbers: a real win concentrated at low-to-mid distance
/// (photo content notably smaller at bounded RMSE cost), shrinking to a
/// negligible-but-never-regressing effect at high distance.
const _kRdoqLambda = 0.03;

/// Blocks the L2 heuristic already flagged with its strongest banding
/// protection (`hfMult == 4`) are skipped by RDOQ entirely — see
/// `_chooseAcRdoq`'s doc comment for why.
const _rdoqExemptHfMult = 4;

/// Greedy, single reverse-scan-order ("coefficient dropping") RDOQ pass
/// for one block-channel's already-quantized AC coefficients
/// (`block.acInt[c]`): walks from the true last-nonzero scan position
/// backward toward position 0, zeroing any coefficient whose removal
/// reduces `distortion + lambda * rate`, against the frozen bootstrap
/// clustering/code-length table ([clusterMap]/[lengths]) and cross-block
/// [predicted] value — same bootstrap-then-freeze soundness argument
/// `_chooseHfMultRd` already establishes (coefficient values never change
/// which cluster a token routes to in this encoder's configuration).
///
/// **Live vs. frozen, and why** (verified by hand-trace and formal
/// induction before implementation — see doc/spec_notes.md for the full
/// derivation): within one block-channel's own scan, `remaining` (count
/// of not-yet-emitted nonzeros) is tracked *live* as the walk proceeds —
/// a drop at position k' only ever shifts `remaining`-context for
/// positions with LOWER index (not yet visited by this backward walk),
/// so it can be updated exactly. `prev` (whether the immediately
/// preceding position was nonzero) is the opposite: a drop at k' only
/// ever shifts `prev`-context at position k'+1 (HIGHER index, already
/// decided earlier in the walk) — causally unavailable to revise in a
/// single pass, so `prev` is frozen at its original, pre-RDOQ value
/// ([basePrev]) for every position except position 0, whose "prev" is
/// actually the block-global `remaining > orderSize/16` threshold, not a
/// sequential dependency — and being the LAST position visited (nothing
/// left below it), it's computed live too, from whatever `remaining`
/// each of position 0's own two hypotheses (kept/dropped) implies.
///
/// An end-of-block (EOB) retreat (dropping the *current* true
/// last-nonzero coefficient) doesn't just zero one token: every position
/// between the next surviving nonzero and the old EOB is removed from
/// the stream entirely (implicit, free zero — see the early-stop decode
/// loop in `hf_coefficients.dart`). That savings is priced *live*,
/// position by position over just the swept gap — never a table frozen
/// from the original (pre-RDOQ) scan, which would price a second-or-later
/// retreat in the same walk using stale `remaining` values (an earlier
/// design draft's bug, caught by proof before implementation). Since
/// each position is swept at most once across the whole walk, this stays
/// O(ucoeffLen) total per block-channel, not O(ucoeffLen) per retreat.
///
/// **Known estimation gap, and why the walk's proposed drops are only
/// ever committed after a real-assembly check** (found empirically
/// during implementation, documented in doc/spec_notes.md — a genuine
/// finding, not a hypothetical): dropping any coefficient — not just an
/// EOB retreat — shifts the `remaining` bucket (`_coeffNumNonzeroCtx`'s
/// coarse thresholds), hence the real bit cost, of *every surviving
/// lower position*, including ones whose own value never changes. This
/// walk only prices the position(s) directly flipped by each decision
/// (the swept gap for an EOB retreat, or the one token for an interior
/// drop) — it does not retroactively re-price already-encoded lower
/// positions each time an earlier (higher-k) drop shifts their bucket.
/// Exactly accounting for that ripple would mean repricing up to
/// O(ucoeffLen) positions per drop, reintroducing the O(ucoeffLen^2) cost
/// this greedy design was chosen over a full DP specifically to avoid
/// (see doc/spec_notes.md's cost comparison). This makes the per-decision
/// rate estimate an approximation that can go either way — measured
/// directly (not just theorized): a real test case had the walk propose
/// a single, individually-"beneficial-looking" drop that, once actually
/// re-encoded, made that block-channel's total bits *increase*. Given
/// that, the walk's proposed [toZero] set is never trusted blindly: the
/// function ends with one real-assembly comparison (before/after real
/// bit counts via the same [_blockChannelTokens] path the real bitstream
/// uses) and only commits via [_PlacedBlock.applyRdoqDrops] if the real
/// total actually decreased — the same "estimates can't resolve
/// near-ties, verify by real assembly, keep the better one" pattern
/// `_chooseAcClustering` and the lossless encoder's predictor choice
/// already use elsewhere in this codebase. This makes RDOQ provably
/// never-worse than not running it (per block-channel), at the cost of
/// occasionally discarding a drop set that was mostly, but not entirely,
/// beneficial, rather than trying to model the ripple.
void _rdoqBlockChannel(
    _TransformCtx ctx,
    HfBlockContext hfctx,
    int c,
    List<Float32List> coeffBufC,
    List<Float32List> rawWeightC,
    double sfc,
    int predicted,
    List<int> clusterMap,
    List<List<int>> lengths,
    double lambda,
    _PlacedBlock block) {
  final numBlocks = ctx.numBlocks;
  final orderSize = ctx.orderSize;
  final n = ctx.tt.pixelWidth;
  final flip = ctx.tt.flip;
  final acData = block.acInt[c];
  final (vals, countNonZero, lastNonZeroK) = _scanChannelValues(ctx, acData);
  if (countNonZero == 0) return;

  // Frozen prev for every position (position 0's frozen entry is never
  // read -- it's recomputed live in rateAt -- computing it here anyway
  // keeps this one forward pass uniform with _blockChannelTokens's).
  final basePrev = List<int>.filled(lastNonZeroK + 1, 0);
  {
    var remaining = countNonZero;
    var prevNonzero = false;
    for (var k = 0; k <= lastNonZeroK; k++) {
      basePrev[k] = k == 0
          ? (remaining > orderSize ~/ 16 ? 0 : 1)
          : (prevNonzero ? 1 : 0);
      prevNonzero = vals[k] != 0;
      if (prevNonzero) remaining--;
    }
  }

  final nonZeroCtxId =
      HfCoefficients.getNonZeroContext(hfctx, predicted, ctx.blockCtx[c]);
  final histCtx = ctx.histCtx[c];

  // Live cost of encoding position k under a specific (remaining, value)
  // hypothesis -- exactly what the decoder would charge, using frozen
  // basePrev except at k == 0 (see doc comment above).
  double rateAt(int k, int remainingForCtx, int packedValue) {
    final prev =
        k == 0 ? (remainingForCtx > orderSize ~/ 16 ? 0 : 1) : basePrev[k];
    final coefCtx = histCtx +
        HfCoefficients.getCoefficientContext(
            k + numBlocks, remainingForCtx, numBlocks, prev);
    return _tokenRate(clusterMap, lengths, coefCtx, packedValue);
  }

  final nonZeroPositions = <int>[
    for (var k = 0; k <= lastNonZeroK; k++)
      if (vals[k] != 0) k,
  ];

  var curLastK = lastNonZeroK;
  var curCountNonZero = countNonZero;
  var keptCountSoFar = 0; // count of higher-k positions visited and kept
  final toZero = <int>[];

  for (var idx = nonZeroPositions.length - 1; idx >= 0; idx--) {
    final k = nonZeroPositions[idx];
    final qval = vals[k];
    final o = ctx.order[k + numBlocks];
    final oy = o >> 16, ox = o & 0xFFFF;
    // Same flip mirror as _scanChannelValues.
    final posY = flip ? ox : oy, posX = flip ? oy : ox;
    final trueVal = coeffBufC[posY][posX];
    final w = rawWeightC[posY][posX];
    final step = sfc / w;
    final oldErr = trueVal - qval * step;
    final distortionDelta =
        (w * trueVal) * (w * trueVal) - (w * oldErr) * (w * oldErr);

    double rateDelta;
    if (k == curLastK) {
      final newCurLastK = idx > 0 ? nonZeroPositions[idx - 1] : -1;
      // Every position in (newCurLastK, curLastK] is currently paid for;
      // dropping curLastK removes all of them from the stream at once.
      // `remaining` is exactly keptCountSoFar+1 (==1, by construction:
      // nothing has been kept since the last retreat) throughout this
      // gap, since curLastK is its only nonzero.
      var savings = 0.0;
      var remaining = keptCountSoFar + 1;
      for (var p = newCurLastK + 1; p <= curLastK; p++) {
        final v = vals[p];
        savings += rateAt(p, remaining, v == 0 ? 0 : _packSigned(v));
        if (v != 0) remaining--;
      }
      rateDelta = -savings;
    } else {
      final ctxKept = rateAt(k, keptCountSoFar + 1, _packSigned(qval));
      final ctxDropped = rateAt(k, keptCountSoFar, 0);
      rateDelta = ctxDropped - ctxKept;
    }

    final nonZeroDelta =
        _tokenRate(clusterMap, lengths, nonZeroCtxId, curCountNonZero - 1) -
            _tokenRate(clusterMap, lengths, nonZeroCtxId, curCountNonZero);

    final totalCost = distortionDelta + lambda * (rateDelta + nonZeroDelta);
    if (totalCost < 0) {
      toZero.add(posY * n + posX);
      curCountNonZero--;
      if (k == curLastK) {
        curLastK = idx > 0 ? nonZeroPositions[idx - 1] : -1;
      }
    } else {
      keptCountSoFar++;
    }
  }
  if (toZero.isEmpty) return;

  // Real-assembly safety net (always on, not debug-only — this is a
  // functional guarantee, not a diagnostic): the walk's per-decision
  // rate estimate cannot be exact, because dropping any coefficient
  // shifts the `remaining` bucket (`_coeffNumNonzeroCtx`'s coarse
  // thresholds), hence the real bit cost, of every SURVIVING lower
  // position too — including positions whose own value never changes.
  // Pricing that ripple exactly would mean repricing up to O(ucoeffLen)
  // positions per drop, reintroducing the O(ucoeffLen^2) cost the
  // DP-vs-greedy tradeoff was chosen to avoid (see doc/spec_notes.md).
  // Discovered empirically during implementation: the ripple isn't
  // always negligible — a single isolated drop was measured to make one
  // real test block-channel's total bits *increase*, not decrease,
  // despite every individual decision looking beneficial under the
  // (ripple-blind) per-decision estimate. Rather than try to model the
  // ripple, this reuses the codebase's own established fallback pattern
  // (`_chooseAcClustering`, the lossless encoder's predictor choice,
  // etc.: "estimates can't resolve near-ties, verify by real assembly,
  // keep the smaller/better") — one extra pair of real re-scans per
  // block-channel with any proposed drops (still O(ucoeffLen) total, not
  // O(ucoeffLen) per decision), and only commits if the real total bits
  // actually decreased. This makes RDOQ provably never-worse than not
  // running it, at the cost of occasionally discarding a drop set that
  // was mostly, but not entirely, beneficial.
  double realBits(Int32List data) {
    final contexts = <int>[];
    final values = <int>[];
    _blockChannelTokens(ctx, hfctx, c, data, predicted, contexts, values);
    var bits = 0.0;
    for (var j = 0; j < contexts.length; j++) {
      bits += _tokenRate(clusterMap, lengths, contexts[j], values[j]);
    }
    return bits;
  }

  final before = realBits(acData);
  final afterData = Int32List.fromList(acData);
  for (final i in toZero) {
    afterData[i] = 0;
  }
  if (realBits(afterData) < before) {
    block.applyRdoqDrops(c, toZero);
  }
}

/// Bootstrap-then-freeze driver for the RDOQ coefficient-dropping pass:
/// builds a real `_AcClustering` from whatever hfMult/quantization state
/// is already committed (the L2 heuristic, optionally refined by
/// `_chooseHfMultRd` if `enableRdHfMult` is also on — RDOQ always runs
/// strictly after hfMult is finalized, since its own dequant step size
/// depends on it), freezes that clustering's code-length table and the
/// group's non-zero-count prediction grid (same frozen-bootstrap pattern
/// `_chooseHfMultRd` already uses, sound for the same reason — see its
/// doc comment), then runs [_rdoqBlockChannel] over every block-channel.
///
/// Blocks with `hfMult == _rdoqExemptHfMult` are skipped entirely: that
/// value is the L2 heuristic's own strongest banding-protection signal,
/// and RDOQ shares the same weighted-squared-error distortion metric
/// that, in `_chooseHfMultRd`'s own calibration, proved unable to
/// represent banding perceptual cost — an RD search using it is
/// structurally tempted to remove exactly that protection once its bit
/// cost is priced (see doc/spec_notes.md). Deferring to the heuristic's
/// own decision for these blocks is a mitigation only available *because*
/// RDOQ is additive (unlike hfMult's own RD search, which *was* the
/// protection decision and had no equivalent escape hatch).
void _chooseAcRdoq(
    List<_PlacedBlock> placedBlocks,
    List<List<Float32List>> planes,
    _ChromaFromLumaFit cfl,
    double acScale,
    List<double> scaleFactor,
    List<Float32List> scratchA,
    List<Float32List> scratchB,
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
  final lambda = (lambdaOverride ?? _kRdoqLambda) * acScale * acScale;

  for (final block in placedBlocks) {
    if (block.hfMult == _rdoqExemptHfMult) continue;
    final coeffBuf = block.computeCoeffBuf(planes, cfl, scratchA, scratchB);
    final ctx = ctxByType[block.tt.type]!;
    final rawWeight = ctx.rawWeight;
    final predicted = predictedOut[block]!;
    for (final c in _channelOrder) {
      _rdoqBlockChannel(
          ctx,
          hfctx,
          c,
          coeffBuf[c],
          rawWeight[c],
          scaleFactor[c] / block.hfMult,
          predicted[c],
          clusterMap,
          lengths,
          lambda,
          block);
    }
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
