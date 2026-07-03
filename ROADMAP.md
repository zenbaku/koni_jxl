# koni_jxl roadmap

Direction and deferred work. The decoder is feature-complete for the manga
use case and both packages are published at 0.1.0; the lossless encoder
beats `cjxl -e3` on real manga pages. This file tracks what's next.

Status legend: 🔲 not started · 🔨 in progress · ✅ done (kept here for
context until it ships in a release).

---

## Headline: lossy (VarDCT) encoding — "a true codec"

Today we decode lossy (VarDCT) and encode lossless (modular). Encoding
lossy makes koni_jxl a complete JPEG XL codec. This is a large project —
roughly the inverse of the entire lossy decode pipeline — so it's phased.
Every phase gates the same way the decoder does, but reversed: **our
encode → djxl decode → within an RMSE/max threshold of the source**, and
our own decoder must agree with djxl.

The decoder already gives us most of the hard reference material: the DCTs
(we invert them; the forward transforms share structure), the quant-weight
tables, XYB color, CfL math, coefficient orders, and the entropy encoder
from the lossless work. What the encoder adds is the *analysis* side —
choosing quantization, block sizes, and CfL — which is where perceptual
quality lives.

- ✅ **L0 — minimal valid stream.** `JxlEncoder.encodeLossy` (single-group,
  ≤256×256, width/height multiples of 8): RGB→XYB forward (exact inverse of
  `OpsinInverseMatrix.invertXyb`), forward 8×8 DCT via the existing
  `forwardDCT2D`, uniform quantization mirroring the decoder's DC
  (`scaledDequant`) and AC (`scaleFactor` × default DCT8x8 quant weights)
  formulas, chroma-from-luma pre-subtraction for B, filters off, natural
  coefficient order, HF coefficients entropy-coded with a single collapsed
  prefix-code cluster (correct but not yet using the real 495-context
  model). Gated against djxl end-to-end on the first real attempt; see
  `packages/koni_jxl/test/encode/vardct_l0_test.dart` and
  `packages/koni_jxl/test/encode/vardct_forward_test.dart`. Quality is
  intentionally crude (~28% of raw at defaults) — L1 is where it improves.
- ✅ **L1 — rate control + coefficient model.** `distance:` parameter on
  `JxlEncoder.encodeLossy` (encoder policy, not a decoder-mirrored
  formula — see `VardctL0Config.fromDistance`'s doc comment for its
  known floor around distance ~0.5-0.8, a consequence of `quant_all_default
  = true` capping how fine `globalScale` can go; genuine near-lossless
  needs custom per-frequency quant weights, deferred to L2). The real HF
  coefficient context model is now implemented (non-zero-count prediction,
  block context, per-position coefficient context — mirrors
  `hf_coefficients.dart` exactly), clustered into up to 256 histograms
  (a hard, empirically-discovered bitstream limit — see doc/spec_notes.md)
  with the smallest-actual-bytes choice made per image rather than a fixed
  budget. Multi-group support removed the 256x256 ceiling — up to
  2048x2048 (single LF group at the time; multi-LfGroup, removing that
  ceiling too, followed later — see below).
- ✅ **L2 — perceptual quantization.** Adaptive per-block quant multiplier
  from a Y AC-energy heuristic (smooth/low-energy blocks get boosted
  precision to avoid banding — measured ~65-70% RMSE reduction on smooth
  gradients; busy blocks stay at baseline, since masking hides
  quantization noise there). Custom per-frequency quant weight tables
  (`quant_all_default = false`, via a new `acScale` config knob) removed
  L1's ~0.5-0.8 `distance` floor entirely — RMSE is now monotonic all the
  way to `distance = 0.05` in testing. Chroma-from-luma is implemented as
  a **global** (whole-image, least-squares-optimal X-on-Y and B-on-Y
  slope) correlation rather than the spec's per-64x64-region granularity
  — a deliberate scope cut (see doc/spec_notes.md); still a real,
  measured win on non-gradient content. `BitWriter` gained `writeF16`
  (mirror of `BitReader.readF16`) to support both of the above.
- ✅ **Per-region chroma-from-luma.** Upgraded L2's global-only CfL to the
  spec's real per-64x64-region granularity (`xFromY`/`bFromY` in
  HfMetadata, a least-squares fit per region instead of always 0), layered
  on top of the still-global DC/LF correlation (which the format only
  ever applies as one frame-wide value — DC has no per-region field).
  Measured a real, on-by-default win: ~26% RMSE reduction at roughly the
  same file size on synthetic content with genuinely different color
  relationships in different regions (e.g. a reddish region next to a
  bluish one), vs. only ~1% size overhead on content with no real
  regional color variation to exploit. See doc/spec_notes.md.
- ✅ **Multi-LfGroup support.** Removed the 2048x2048 ceiling: images of
  any size now split into multiple LF groups (each up to 2048x2048
  pixels / 256x256 blocks), not just multiple 256x256 groups within one.
  A key simplification made this tractable: since blocks never straddle
  an LF group boundary (the same even-block-alignment argument used for
  group boundaries — see doc/spec_notes.md), and groups are already
  numbered independent of LF groups end-to-end, the *only* new work was
  splitting DC/HfMetadata into per-LF-group sections and restructuring
  the TOC; the AC entropy coding path needed zero changes.
- ✅ **L3 — transform selection + filters.** Two independent additions,
  both opt-in and **off by default** — both are real, djxl-verified,
  working capabilities that help smooth/photographic content but were
  measured to *regress* manga's dominant content types, so neither is a
  net win for this project's primary use case at its current tuning
  (see doc/spec_notes.md for the full numbers and the two config knobs,
  `VardctL0Config.enableFilters` / `enableVariableTransforms`):
  - **Filters** (Gaborish + 2 EPF iterations, the format's own defaults).
    Helps smooth/photo content a few percent; ~13x *worse* RMSE on
    screentone and line art (these are smoothing filters, and manga's
    dominant content is exactly the sharp edges/regular high-frequency
    detail they blur).
  - **Variable transform size** (adaptive per-16x16-region 8x8-vs-16x16
    DCT selection, with placement mirroring the decoder's greedy block
    layout, per-transform-type context/weight tables, and an exact
    algebraic inversion of the decoder's LLF-from-DC-plane
    reconstruction for 16x16 blocks). ~4% smaller at matched quality on
    smooth photographic content; up to ~31% *larger* on line art and
    screentone, because the selection heuristic (a cheap bit-cost proxy)
    doesn't capture the real context-adaptive entropy cost and
    over-selects 16x16 on regular high-frequency patterns. A
    higher-fidelity heuristic (or an actual-assembled-bytes comparison,
    per this project's established "measure, don't estimate" pattern —
    see `_chooseAcClustering`) could recover this as a real per-region
    win rather than an all-or-nothing global toggle; not attempted here.
  Full 27-transform-type support (this encoder only added 8x8/16x16) and
  a real rate-distortion search remain open if a non-manga use case ever
  needs them.
- ✅ **L4 — API + gates.** `JxlEncoder.encodeLossy(..., distance:)` (done
  since L1). Added: `encodeJxlLossyFromRgba`/`encodeJxlLossyFromUiImage`
  Flutter helpers (`koni_jxl_flutter`, alpha dropped — RGB-only, matching
  the core encoder); a real-corpus lossy round-trip gate
  (`test/encode/encoder_lossy_corpus_test.dart`, complementing the
  hand-written synthetic patterns in `vardct_l0_test.dart`); a
  `cjxl`-comparison benchmark (`tool/bench_lossy_vs_cjxl.dart`, matched
  distances, both decoded via `djxl` for size/RMSE/time). The benchmark's
  honest finding: koni_jxl is 1.5-5x larger than even `cjxl -e1` at the
  same `distance`, though often at comparable-or-better RMSE — expected,
  since this encoder has no rate-distortion search and only 2 of 27
  transform types, but now concretely measured rather than assumed.
  Also removed an incidental limitation found while building the
  Flutter helper: `encodeLossyVardctL0` now accepts *any* positive
  width/height (previously required multiples of 8), padding internally
  via edge replication and writing the true size to the header — real
  manga pages are very unlikely to be exactly block-aligned, so this was
  a real gap for a "Flutter helper" to paper over rather than fix.

Open question to settle before L0: target the **VarDCT** path (the real
lossy format, big but correct) vs a **lossy-modular** shortcut (quantize
then encode with the existing modular encoder — far less work, worse
quality, still "lossy"). Decided: **VarDCT** (a true codec). Detailed implementation plan in
[doc/lossy_encoder_plan.md](doc/lossy_encoder_plan.md).

L0 through L4 are done (see above), along with per-region chroma-from-luma
and multi-LF-group support — everything originally scoped in
doc/lossy_encoder_plan.md. What's left is real quality/compactness work
rather than missing capabilities — see `tool/bench_lossy_vs_cjxl.dart`'s
output for where the gap actually is.

- ✅ **Compression efficiency, round 1: DC gradient prediction.** Found by
  instrumenting the benchmark's output with a per-section byte breakdown:
  DC (LF) coefficients — encoded with *zero* spatial prediction since L0 —
  were over half this encoder's total output size on real photo content,
  more than the AC coefficients every prior phase had focused on tuning.
  Fixed by writing DC through the same clamped-gradient predictor
  (predictor 5) the lossless encoder already uses and gates bit-exact
  against djxl, instead of predictor 0 (no prediction). Cut DC size by
  49-75% and total file size by 25-27% on the two corpus test images,
  roughly halving the size gap vs `cjxl -e1` (2.17-4.88x → 1.59-2.79x and
  1.55-2.34x → 1.16-1.52x). See doc/spec_notes.md for the full numbers and
  the ranked list of what's likely next (a DC context tree, the
  self-correcting weighted predictor for DC, then AC-side rate-distortion
  search — the largest remaining lever and the most work).
- ✅ **Compression efficiency, round 2: weighted predictor for DC.**
  `_writeLfCoefficients` now tries predictor 6 (self-correcting weighted,
  reusing `encode/wp_predictor.dart`'s already decoder-verified,
  lossless-encoder-shared `wpTileResiduals`) alongside predictor 5
  (clamped gradient) and keeps whichever assembles smaller real bytes —
  the same "try both, keep smaller" pattern the lossless encoder already
  uses. Content-dependent, no-downside win: ~5% smaller on real photo
  content where WP wins (`color_cover`: 1.59x → 1.51x vs `cjxl -e1`),
  byte-identical where gradient already wins (`palette16`, no regression).
  A DC context tree and AC-side rate-distortion search remain the larger
  levers — see doc/spec_notes.md.

---

## Lossless encoder refinements

Smaller levers on top of the current learned-tree + WP + ANS/LZ77 encoder.

- 🔲 **Predictor-selection heuristic.** The encoder runs both predictor
  pipelines (gradient and weighted) fully and keeps the smaller — ~2×
  encode time. Compare the two learned trees' training entropy first and
  run only the winner's full pipeline (Pass B + assembly). Roughly halves
  encode time for a sub-percent size risk.
- 🔲 **Larger hybrid split exponent for WP.** WP residuals have larger
  magnitudes, so the fixed `HybridIntegerConfig(4,1,0)` spends many extra
  bits. A larger split (fewer extra bits, bigger token alphabet) likely
  helps WP-chosen images; measure and pick per image.
- 🔲 **Delta palette.** The decoder supports delta-palette entries; the
  encoder only emits plain palettes. Would help near-flat color art.
- 🔲 **Per-leaf predictor selection.** The learned tree currently uses one
  predictor for all leaves. Letting each leaf pick gradient vs WP (vs
  others) is closer to what cjxl does and stacks with property 15.
- 🔲 **Better LZ77 matcher.** The current greedy hash-chain is basic;
  lazy matching / longer chains would help the (rare) repetitive cases
  where LZ77 already wins.

---

## Decoder gaps (documented, throw `JxlUnsupportedException`)

None block the manga use case; listed for completeness.

- 🔲 **ICC-driven output transform.** XYB/enum-transfer output is done;
  files whose color is described only by an embedded ICC profile are
  decoded as sRGB. A full ICC transform would fix the one documented
  `progressive` conformance tone-curve deviation.
- 🔲 **Spot-color rendering.** Spot-color extra channels.
- 🔲 **JPEG bitstream reconstruction.** Reconstruct the original JPEG from
  a JPEG-transcoded `.jxl` (needs the jbrd box + JPEG serialization).
- 🔲 **Float (HDR) sample formats.** 16/32-bit float output samples.

---

## Performance & infrastructure

- 🔲 **EPF pass-0 SIMD.** The `epfIterations == 3` path (rare) is scalar;
  an 11 MP triple-pass progressive photo takes ~6.5 s. Vectorize it.
- 🔲 **Isolate parallelism.** Evaluated and deferred (shared-nothing →
  re-parse or bulk copies; poor ROI at current single-thread speeds).
  Revisit if very large images or batch decoding become a use case.
- 🔲 **Downscaled decode.** A `decodeScaled(1/2, 1/4)` API (cheaper than
  decode-then-resize) for library grid/thumbnail views.
