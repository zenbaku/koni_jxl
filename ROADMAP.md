# koni_jxl roadmap

Direction and deferred work. The decoder is feature-complete for the manga
use case and both packages are published at 0.1.0; the lossless encoder
beats `cjxl -e3` on real manga pages. This file tracks what's next.

Status legend: 🔲 not started · 🔨 in progress · ✅ done (kept here for
context until it ships in a release).

**Full 27-transform-type support's success criterion (settled
2026-07-05, after round 7 shipped DCT 32x32 off-by-default and it wasn't
obvious from the outside whether that meant the initiative had stalled):
this is a completeness goal, not a manga-ROI-gated one.** A transform
type's *existence* — correctly implemented, djxl-verified, never-worse
via real-assembly safety net — is not gated on whether it measurably
helps `manga_samples/` content; keep building out Tranches A/B/C
regardless. A transform type's *default* (on vs. off) still is gated on
that, same discipline round 7 already established for 32x32 (correct and
shipped, but off because the real win there was -0.0% to -0.6%, not
worth its ~40% encode-time cost). Don't conflate the two again.

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
    over-selects 16x16 on regular high-frequency patterns.
    **Superseded — see "Compression efficiency, round 6" below**: a
    later session replaced the proxy with a real bootstrap-based
    estimate plus a whole-image real-assembly safety net, closing exactly
    this gap, and `enableVariableTransforms` now defaults to **on**.
  ✅ **Full 27-transform-type support is now COMPLETE** (this encoder only
  added 8x8/16x16 as of round 6; rounds 7/8 completed Tranche A — all
  square DCT sizes, 8x8 through 256x256, 6 of 27 types; rounds 9/10
  completed Tranche B — all 12 rectangular types, 18 of 27 total; round 11
  started Tranche C with DCT4x4, 19 of 27 total; round 12 added Hornuss and
  DCT2x2, 21 of 27 total; round 13 added DCT4x8 and DCT8x4, 23 of 27
  total; round 14 below added AFV0-3, 27 of 27 — Tranche C and the whole
  effort are done). A real rate-distortion search over transform size
  itself (rounds 6-14 choose between fixed candidates per region, not a
  search) remains open, as does a real-manga ROI evaluation for the full
  set (every non-default tranche/size still defaults off pending that —
  existence and default-on-ness were always separate questions) — see
  round 14's write-up for what's next now that completeness itself is
  done.
- ✅ **L4 — API + gates.** `JxlEncoder.encodeLossy(..., distance:)` (done
  since L1). Added: `encodeJxlLossyFromRgba`/`encodeJxlLossyFromUiImage`
  Flutter helpers (`koni_jxl_flutter`, alpha dropped — RGB-only, matching
  the core encoder); a real-corpus lossy round-trip gate
  (`test/encode/encoder_lossy_corpus_test.dart`, complementing the
  hand-written synthetic patterns in `vardct_l0_test.dart`); a
  `cjxl`-comparison benchmark (`tool/bench_lossy_vs_cjxl.dart`, matched
  distances, both decoded via `djxl` for size/RMSE/time). The benchmark's
  honest finding *at the time*: koni_jxl is 1.5-5x larger than even
  `cjxl -e1` at the same `distance`, though often at comparable-or-better
  RMSE — expected, since this encoder has no rate-distortion search and
  only 2 of 27 transform types, but now concretely measured rather than
  assumed. (Narrowed to 1.18x-1.82x on the same corpus image by
  "Compression efficiency, round 6" below — still worth re-running after
  any future transform-selection or RD-search work.)
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
- ✅ **Compression efficiency, round 3: a genuine RD search for hfMult
  (implemented; off by default — calibration found a real modeling
  limit, not a bug).** Scoped via two independent research agents before
  writing code (see doc/spec_notes.md for the full design and the
  grounding fact that made it tractable: `hfMult` can't change which
  entropy cluster a token routes to, only what value lands there, given
  this encoder's always-empty `HfBlockContext.qfThresholds`). Implemented
  a real per-block cost/benefit decision — weighted-squared-error
  distortion, a real Huffman-code-length-based rate estimate (`Entropy
  Codes.tokenBitLengths()`, new and unit-tested), a bootstrap-then-score
  architecture — behind `VardctL0Config.enableRdHfMult` (default
  `false`). Correctness is fully verified (djxl round-trips clean in
  every configuration tried). **Calibration (`tool/calibrate_rd_lambda.
  dart`) found no single trade-off constant beats the heuristic on real
  photo content while preserving its smooth-gradient banding protection**
  — the photo-favorable setting measurably removes most of the
  heuristic's banding protection (confirmed via the actual per-block
  multiplier histogram, not inferred), because plain weighted MSE can't
  see banding sensitivity the way a real perceptual metric would. This is
  a genuine modeling gap, not a constant to keep searching for — see
  doc/spec_notes.md before re-attempting without changing the distortion
  metric itself. The infrastructure (rate estimator, RD search, and
  calibration tool) ships anyway: it's correctness-verified and directly
  reusable for a future banding-aware distortion term or for the
  transform-size RD search still deferred from L3.
- ✅ **Compression efficiency, round 4: a learned context tree for DC.**
  `_writeLfCoefficients` now learns a real per-image context tree
  (`encode/context_tree.dart` — the same machinery the lossless encoder's
  biggest lever already uses, reused unmodified) instead of writing DC
  residuals through one shared single-leaf histogram. Verified legal by
  reading the decoder source first: DC decodes through the same generic
  modular-channel path lossless images use, and the property sets
  involved never cross a channel boundary, so one tree trained across all
  three DC channels together is exactly as sound as the lossless
  encoder's own multi-plane tree. Real, no-quality-cost win on photo
  content (`color_cover`: 6-9% smaller at *identical* RMSE across every
  distance) and a smaller real win on manga-typical screentone content
  (`gray_screentone`: 0.3-0.9% smaller, also at identical RMSE); a small
  synthetic pattern (`screentone_256`) came out byte-identical (the tree
  found no split worth its header cost and degenerated to the old
  single-leaf form exactly) and only `palette16` saw a tiny ~0.1-0.2%
  size increase. Costs ~20-60% more encode time (extra tree-learning and
  per-pixel context-assignment passes per predictor candidate per LF
  group) — still sub-second per LF group at every size tested. See
  doc/spec_notes.md for the full write-up, including a subtle bug caught
  before shipping (the original probe/commit shape copied a byte-aligned
  `toBytes()` for the winning candidate, which would have corrupted
  everything written after it in the same section once per-pixel
  contexts were involved).
- ✅ **Compression efficiency, round 5: AC-side RDOQ.** Genuine
  per-AC-coefficient rate-distortion-optimized quantization ("RDOQ" —
  `_chooseAcRdoq`/`_rdoqBlockChannel`, behind `VardctL0Config.enableRdoq`,
  **on by default**): a greedy, single reverse-scan-order
  coefficient-dropping pass, chosen over a full per-block DP after a
  back-of-envelope perf estimate ruled the DP out (~60-500x more
  coefficient-decision ops for a 2048x2048 image). Two real bugs in the
  rate-accounting formulas were found and fixed via formal proof *before*
  any code was written (a frozen-table EOB-retreat pricing error; an
  unnecessarily-frozen `prev` bit at position 0); a *third*, larger gap
  was found only empirically, after both were fixed (dropping any
  coefficient shifts the real bit cost of every surviving lower position
  in the same block-channel) — fixed not by modeling the ripple but by
  turning the differential test into a real, always-on safety net: every
  proposed drop set is re-encoded for real before/after and only
  committed if bits genuinely decreased, making RDOQ provably
  never-worse-than-off on total bits regardless of estimation error
  elsewhere. First shipped off by default: a `distance=1.0`-only
  calibration found a constant that looked perfect there but, caught by
  re-running the standard benchmark across its *full* distance sweep,
  roughly doubled RMSE at `distance=8.0` — `lambda`'s `refStep²` scaling
  turned out to grow in the *opposite* direction from how RDOQ's own
  distortion metric scales with the dequant weight table. Fixed the very
  next session by rederiving the correct scaling (`lambda ∝ acScale²`,
  not `refStep²`) and recalibrating via a genuinely multi-distance sweep
  (0.5-8.0) — verified safe (no regression beyond a small, bounded RMSE
  cost) at every distance tested, with a real win concentrated at
  low-to-mid distance (`color_cover`: -8.8% at `distance=0.5`, -4.0% at
  `distance=1.0`) shrinking to a negligible-but-never-regressing effect
  at high distance, where plain rounding already zeros out most marginal
  AC content before RDOQ gets a chance to. See doc/spec_notes.md for the
  full derivation, the numbers, and an incidental unrelated finding
  (the gradient banding-protection test's own RDOQ-off baseline already
  exceeds its gate above `distance=4` — a pre-existing gap in that
  heuristic's own validation coverage, left for a future session).
- ✅ **Compression efficiency, round 6: variable-transform selection
  fixed, flipped on by default.** Replaced L3's `_should16x16` (a
  pre-quantization coefficient-magnitude proxy, measured to over-select
  16x16 on manga content: +20% screentone, +31% line art) with
  `_decideTransformLayout` — a real, bootstrap-frozen bit-rate estimate
  mirroring `_chooseHfMultRd`'s already-shipped pattern, generalized from
  "which `hfMult`" to "which transform type" — plus a whole-image
  real-assembly safety net (assemble a real body for both the all-8x8
  and decided-mixed layouts, keep whichever is genuinely smaller) added
  after an advisor review flagged that the per-region estimate alone
  couldn't promise RDOQ's never-worse guarantee, and two synthetic
  content patterns were thin ground to override manga's "off until
  proven" precedent on a project whose real fixtures can never be repo
  test cases. The safety net's marginal cost is small (~1.28x encode
  time, not 2x — the bootstrap's expensive DCT/quantization/clustering
  work is reused, only the final assembly runs twice) and it verified
  clean on a mixed-content case (half gradient, half screentone in one
  image) that no single-content-type test could have caught: byte-
  identical to `false` at most distances, a small real win at
  `distance=0.5`. Multi-distance calibration
  (`tool/calibrate_transform_lambda.dart`, same methodology as round 5's
  fix) found `_kTransformRdLambda = 3000.0` clears a stricter manga gate
  (within 2% of `false`) at every distance 0.5-8.0 while winning
  substantially elsewhere: `color_cover` -4.3% to -26.7% smaller with
  *better* RMSE throughout, screentone/line-art landing at 0% to -3.1%
  (real wins, not just flat). `VardctL0Config.enableVariableTransforms`
  now defaults to **true**; `tool/bench_lossy_vs_cjxl.dart`'s gap vs
  `cjxl -e1` narrowed from 1.52x-2.79x to 1.18x-1.82x on `color_cover` —
  the largest single improvement to that number yet, from fixing an
  existing transform type's selection rather than adding a new one. See
  doc/spec_notes.md for the full write-up.
- ✅ **Checked whether `_chooseHfMultRd`'s own lambda has the same
  distance-scaling bug RDOQ had — yes, partly, and `acScale^2` measurably
  helps (caught a self-inflicted confound along the way).**
  `tool/calibrate_rd_lambda.dart` now sweeps `distance` 0.5-8.0, isolated
  from `enableVariableTransforms` (a first, non-isolated pass produced a
  flat, kLambda-insensitive result that looked like saturation but was
  actually a degenerate near-zero-AC transform-layout choice at high
  distance — see doc/spec_notes.md for how that was caught). Isolated, at
  the shipped constant (`kLambda=3000`): gradient RMSE tracks the
  heuristic at `distance=1.0` (0.935 vs. 0.938) but becomes a real
  regression by `distance=2.0` (1.119 vs. heuristic 0.992) and
  `distance=8.0` (2.246 vs. 1.513) under the current `refStep^2` scaling —
  a genuine RDOQ-like distance-dependent issue. A one-off `acScale^2`
  patch (not shipped) at the equivalent `kLambda` (confirmed equivalent:
  identical 0.935 at `distance=1.0`) landed within noise of the heuristic
  at `distance>=4.0` instead of +48-60% over it — a real fix for the
  high-distance blowup, though it doesn't resolve the `distance<=2.0`
  photo-vs-banding trade-off, which is about the distortion metric, not
  lambda's scaling. `enableRdHfMult` stays off
  either way; **anyone revisiting this should start from `acScale^2`
  scaling, not `refStep^2`**. See doc/spec_notes.md's hfMult follow-up for
  the full numbers and the corrected conclusion (an earlier draft of this
  entry wrongly concluded no rescaling would help, before the isolated
  measurement was run).
- ✅ **Fixed the gradient banding-protection test's own gate gap above
  `distance=4`.** Found as a side effect of round 5's fix, confirmed
  unrelated to RDOQ (byte-identical output regardless of `enableRdoq`):
  the `VardctL0Config.fromDistance`-driven L2 adaptive-quant heuristic's
  own RMSE, with every RD feature off, already exceeded the smooth-
  gradient regression test's 1.0 gate at `distance=4` (1.043) and
  `distance=8` (1.513) — that test had only ever run at the implicit
  default `distance=1.0`. `vardct_l0_test.dart`'s banding test now runs
  at 0.5/1.0/2.0/4.0/8.0 with per-distance thresholds (RMSE is *supposed*
  to grow with distance — a single flat bound was the wrong shape of
  gate), each with >=15% margin over the value measured with this
  encoder's actual shipped defaults (RDOQ + variable transforms on):
  0.5→0.6, 1.0→1.0, 2.0→1.0, 4.0→1.0, 8.0→1.6.
- ✅ **Compression efficiency, round 7 / full 27-transform-type support,
  Tranche A: DCT 32x32 shipped, off by default.** The start of "full
  27-transform-type support" (this section's long-standing open item),
  scoped via `EnterPlanMode` given the size: 18 of the 27 types share
  `TransformMethod.dct` (any size, decoder's `forwardDCT2D`/`inverseDCT2D`
  already fully generic) vs. 9 bespoke single-footprint types with no
  generic form at all vs. 6 "wide" rectangular types needing new
  flip/orientation handling the encoder doesn't have yet — three tranches
  (A: more square DCT sizes; B: rectangular pairs; C: bespoke types), only
  Tranche A's first size scoped for implementation now.
  Generalized the encoder's hardcoded-to-2 `rawWeight8`/`rawWeight16`
  dispatch to N-way by adding a `rawWeight` field to the already
  per-type-keyed `_TransformCtx` (byte-identical output verified before/
  after); generalized the 16x16-only hand-unrolled 2x2 DC/LLF-inversion
  formula to the real `inverseDCT2D`-based generic form (verified against
  the decoder's `_finalizeLLF` construction directly in
  `vardct_forward_test.dart` at 32x32's non-trivial 4x4 grid — a ~2-byte
  drift on existing 16x16 output from the different float-rounding path,
  fine since lossy correctness is RMSE-gated, not bit-exact); added a
  second, structurally identical bootstrap-frozen merge pass in
  `_decideTransformLayout` (16x16/8x8-mix → 32x32 per 32x32-pixel region).
  **Caught a real safety-net gap before shipping**: the new level's own
  per-region estimate picked a real, if modest, size *regression* vs. the
  level-1-only decision on some content (still smaller than plain 8x8, so
  the existing two-candidate safety net didn't catch it) — the same
  "estimates can't resolve near-ties, verify by real assembly" lesson
  RDOQ and round 6 both already learned, recurring one level deeper.
  Fixed by extending `_decideTransformLayout`'s return to a third,
  optional candidate and having `encodeLossyVardctL0` assemble a real
  body for level-1-only *and* level-1-plus-32x32, keeping whichever is
  genuinely smaller — `VardctL0Config.enableTransform32`'s own safety net,
  independent of `enableVariableTransforms`'s.
  **Calibration and synthetic/corpus benchmarking initially looked like a
  clear win** (`tool/calibrate_transform32_lambda.dart`,
  `_kTransformRdLambda32 = 3000.0`, real wins up to -9.8% on synthetic
  patterns, -1.6% to -9.7% on the corpus' `color_cover`, and -7.6% to
  -16.7% on `gray_screentone` at distance 0.5-4.0), enough to briefly ship
  it on by default. **That default was reverted after testing real
  `manga_samples/` chapter pages** (gitignored, copyrighted — a B&W
  screentone-heavy title and a flat-color "digital colored comics" title,
  6 pages total): the actual win there is -0.0% to -0.6%, an order of
  magnitude below every synthetic/corpus figure, for the same ~40%
  encode-time cost measured everywhere (a third `_finishEncode`
  real-assembly pass — unavoidable once 32x32 fires at all, which it does
  even on real pages, just barely). RMSE stayed flat; this is a value
  judgment, not a bug: `gray_screentone`'s flat-region density (a
  synthetic proxy with panels/speech-bubbles/a solid black polygon) turns
  out to overstate what real manga pages actually contain. Same
  "synthetic validation didn't survive contact with real content" pattern
  already hit for L3's variable-transforms, RDOQ's lambda scaling, and
  hfMult's banding blind spot. `VardctL0Config.enableTransform32` defaults
  to **false**; the feature remains correct, never-worse, and available as
  an opt-in for content that genuinely has large flat regions. See
  doc/spec_notes.md for the full write-up (both the synthetic numbers and
  the real-manga finding that reverted the default) and doc/BENCHMARKS.md
  for the updated numbers.
- ✅ **Round 8 / full 27-transform-type support, Tranche A completed:
  64x64/128x128/256x256.** After round 7, it wasn't clear from the outside
  whether "shipped off-by-default" meant this initiative had stalled —
  the user had been asking for it across sessions. Asked directly, the
  success criterion settled (see this file's top note, 2026-07-05):
  completeness, not manga-ROI-gated. On that basis, finished Tranche A:
  `VardctL0Config.enableTransform32` (bool) generalized to
  `maxTransformSize` (16/32/64/128/256), and the hardcoded second merge
  level generalized to a loop over `_cascadeSizes` up to that value —
  structurally never-worse (bootstrap is always a candidate, every later
  one beat its own immediately-prior candidate to exist), not per-level
  patched, closing round 7's safety-net-gap class of bug generically. All
  four sizes verified: forward/inverse identity + LLF-inversion tests at
  every size's `dctSelectHeight` grid, plus a dedicated correctness test
  for the edge case no smaller size reaches — a 256x256 candidate exactly
  fills one whole *group*, found to need a 256x256-canvas/distance=64
  gradient to make the *entire* cascade the real winner (not just an
  assembled-and-discarded candidate), via `jxl.encdebug` sweeping rather
  than guessing. Full suite green (313 tests). Also verified the
  *default* path (`maxTransformSize: 16`, unchanged from round 7) itself
  didn't regress despite `_activeTransformTypes` now always constructing
  64x64/128x128/256x256's quant-weight tables even when unused: a
  controlled `git stash` A/B (3 trials, same real manga page and corpus
  golden, before vs. after) found byte-identical output and no measurable
  timing difference — the one-time table cost is negligible against a
  multi-second encode. Per advice going in
  (bigger transforms had already helped less than 32x32, which was
  already negligible), skipped a full multi-distance recalibration in
  favor of reusing the shared lambda and running one real-manga sanity
  check first: same two `manga_samples/` chapters round 7 used, real win
  **-0.1% to -0.6%** (no better than 32x32 alone) for **~2x** encode time
  (four extra cascade levels tried per image instead of one). No
  surprise, so no deeper calibration was warranted.
  `VardctL0Config.maxTransformSize` stays at its default of **16**. This
  completes Tranche A (all square DCT sizes: 8x8 through 256x256, 6 of 27
  types now implemented). See doc/spec_notes.md for the full write-up.
  Tranches B (12 rectangular types, needs a flip/orientation layer
  `_scanChannelValues`/`quantizeCandidate` don't have yet) and C (9
  bespoke single-footprint types, needs from-scratch forward derivations,
  no shared machinery to lean on) remain fully unscoped — per the settled
  criterion, picking these up next should proceed on completeness
  grounds, not be blocked on predicting their manga ROI ahead of time.

- ✅ **Round 9 / Tranche B, first slice: DCT 16x8/8x16.** A research pass
  found most of the supporting machinery (`transform_type.dart`,
  `getDCTQuantWeights`, `getNaturalOrder`, `HfMetadata._placeBlock`,
  `dct.dart`'s forward/inverse DCT, the decoder's flip-aware
  `hf_coefficients.dart`) already fully generic — written that way from
  the start, since the decoder always had to handle every type
  uniformly. What was missing was entirely encoder-side: three functions
  (`computeCoeffBuf`, `quantizeCandidate`'s AC loop, `chooseCandidate`)
  collapsed independent height/width into a single `n`; two functions
  (`_scanChannelValues`, `_rdoqBlockChannel`) hardcoded the transposed
  (`flip=true`) coefficient access unconditionally — correct for every
  type shipped so far, wrong for the first `flip=false` block this
  encoder ever emits (DCT 8x16). All fixed. Per design review, scoped to
  just this one pair first (not all 12 rectangular types at once) — it
  exercises every genuinely new axis simultaneously (both flip
  polarities, a non-square `dctSelect` grid, rectangular placement) so
  proving it end to end localizes debugging before mechanically fanning
  out to the rest.
  The merge cascade itself needed real new logic, not just a parameter
  tweak: `_decideTransformLayout`'s square-only cascade (one `stride`
  value driving both axes) was generalized into a `tryMergeLevel`
  closure taking independent `strideY`/`strideX`, and — this is the part
  that would have shipped a real bug without the design review — a
  **containment guard** was added before any merge commits: DCT 16x8 and
  DCT 8x16 don't nest (each spans cells the other doesn't), so without
  checking that every block a region's cost-sum collects is *fully
  contained* in the candidate's own footprint, a committed 8x16 could be
  silently partially overwritten by a later 16x8 merge, orphaning cells
  — a corrupt block list, not just a suboptimal choice. The guard is a
  structural no-op for every existing square level (square sizes always
  nest cleanly), so Tranche A behavior is provably unaffected; confirmed
  by a `git stash` A/B (byte-identical output, comparable timing) same as
  round 8's.
  A **second real bug was caught mid-implementation, not by review**: the
  "already generic" DC/LLF-inversion code in `quantizeCandidate`
  allocated its `inverseDCT2D` scratch buffers sized exactly
  `(llfH, llfW)` — correct for every square type (where `llfH == llfW`
  always), but `dct.dart`'s `transposeMatrixInto` writes a `(llfW, llfH)`
  intermediate partway through, which overflows that buffer the moment a
  genuinely rectangular grid (16x8's is 2x1) is used. A real end-to-end
  encode crashed with a `RangeError` — the isolated forward/inverse
  identity test in `vardct_forward_test.dart` didn't catch it because
  that test supplies its own (correctly oversized) scratch and never
  exercises this specific internal allocation. Fixed by sizing scratch to
  `max(llfH, llfW)` in both axes, matching the convention this file's
  outer `scratchA`/`scratchB` and `test/vardct/dct_test.dart` already
  use. This is the concrete case for "prove end to end before trusting
  code that's merely *written* generically" — the LLF-inversion
  *formula* was already correct (verified in round 8's identity tests),
  but its *scratch allocation* was latently wrong the whole time,
  invisible until a real non-square grid actually ran through it.
  **A third gap was caught by advisor review, after implementation
  looked done**: every test so far compared our-decoder-vs-djxl, which
  cannot catch a semantic coefficient-scan error in the flip branch —
  both decoders read the same bitstream the same way, so a
  consistently-wrong scan leaves them agreeing with *each other* while
  both reconstruct garbage relative to the original pixels. Since DCT
  8x16 (`flip=false`) is the first non-transposed block this encoder has
  ever emitted, nothing exercised that branch's correctness at all before
  this was flagged. Added a decode-vs-*original* RMSE check (not
  decode-vs-djxl) to the mixed-shape test: measured rectangular-on RMSE
  (0.48) sits in the same ballpark as square-only (0.43) on the same
  content, not blown up by an order of magnitude the way a real flip bug
  would — this is now a permanent regression assertion, not just a
  one-off manual check.
  Verification, in order: forward/inverse identity + LLF-inversion tests
  for the pair (extending round 8's parameterized loop, exercising a
  genuinely non-square `dctSelect` grid for the first time); a
  mixed-shape integration test (4 quadrants, each engineered to favor a
  different shape — horizontal stripes/8x16, vertical stripes/16x8,
  gradient/16x16, noise/8x8 — found via `jxl.encdebug` tallies to
  genuinely beat the square-only cascade, not just the bootstrap, with
  the decode-vs-original check above and a tightened djxl RMSE gate
  (`<2.0`, this project's standard bar — 16x8/8x16 aren't in the
  documented "DCT 16x32 and larger" large-DCT deviation bucket, so they
  don't need the looser `<40` Tranche-A's biggest sizes use); and a
  multi-group test confirming rectangular blocks placed immediately
  adjacent to a 32-block group boundary round-trip correctly (not a
  straddle test — the alignment check already rules straddling out
  algebraically for every Tranche-B `dctSelect` dimension, all of which
  divide 32). Full suite green (319 tests).
  `VardctL0Config.enableRectangularTransforms` (new, orthogonal to
  `maxTransformSize`) defaults to **false** — existence is unconditional
  per the settled criterion, the default is a separate, not-yet-evaluated
  real-content-ROI question, same split every prior size used. Next:
  mechanically fan out the same `tryMergeLevel` machinery to the
  remaining four "2:1 pair" levels (32x16/16x32, 64x32/32x64,
  128x64/64x128, 256x128/128x256) and the one "4:1 line" case (32x8/8x32
  — merges four 8x8 blocks in a line, the only 4:1 case in the format).

- ✅ **Round 10 / Tranche B completed: the remaining 10 rectangular
  types.** The fan-out round 9 scoped for later — mechanical, since
  `tryMergeLevel` already generalizes over any `(strideY, strideX)`.
  Added all 10 remaining types (32x8/8x32, the format's only "4:1 line"
  case; 32x16/16x32, 64x32/32x64, 128x64/64x128, 256x128/128x256, four
  "2:1 pairs" one at each cascade tier). The bootstrap-tier pre-pass now
  tries 8x16, 16x8, 8x32, 32x8 in that order before the square 16x16
  decision (safe regardless of order — the containment guard already
  handles their non-nesting geometry); each `_cascadeSizes` tier's own
  "2:1 pair" (`_cascadeRectPairs`, new — a lookup table pairing each
  square tier with its wide/tall rectangular siblings) is tried
  immediately before that tier's square merge, gated by both
  `enableRectangularTransforms` and the tier itself being within
  `maxTransformSize`. Verified with the same "prove genuinely, don't
  assume" discipline: identity + LLF-inversion tests extended to all 10
  new types (confirmed correct at every new `dctSelectHeight`x
  `dctSelectWidth` grid, from 4x1 up to 32x16); a `jxl.encdebug`-driven
  hunt confirmed every one of the 12 rectangular types (not just the ones
  that happened to appear in a first sweep) gets chosen as a genuine
  winner somewhere across real content configs — including DCT 32x8, the
  one type a first broad sweep missed because *perfectly flat* content
  has zero AC-domain benefit to merging regardless of transform size
  (matching round 8's "flat content has no AC-overhead savings" finding);
  a cross-tier correctness test (a config with DCT 32x8 and DCT 16x16
  coexisting) catching the class of bug a single-tier test can't
  (tier-interaction desync); and a "genuinely wins" test at the opposite
  end of the size range from round 9's own (DCT 256x128, the largest
  pair). A gap caught by advisor review, not self-check: every gradient
  test above was vertical, so every winner proven was `flip=true`
  ("tall") — `flip=false` ("wide") types were left proven at only one
  size (8x16, round 9). Closed with a horizontal-gradient mirror of the
  256x128 test, finding DCT 128x256 (the largest `flip=false` type) as
  an outright winner — `flip=false` now proven at both size extremes,
  with the code's manifest size-independence covering the sizes between.
  **One real finding, documented rather than "fixed"**: the
  cross-tier config found (128x128 canvas, distance=16) has
  `enableRectangularTransforms: true` producing a slightly *larger* file
  than square-only at that specific point — expected per round 9's own
  documented caveat (the guarantee is "vs. plain 8x8," not "vs.
  square-only," once the rectangular pre-pass runs ahead of *every*
  square level, not just the 16x16 one) and not something worth
  "fixing." Full suite green (342 tests, up from 319). Default-path A/B
  (git stash, same real manga page) confirmed byte-identical output,
  comparable timing — `_activeTransformTypes` growing from 8 to 18
  entries doesn't regress the untouched default path, same finding round
  8/9 already established for smaller growth. `enableRectangularTransforms`
  stays off by default (no real-manga check run for the full set yet).
  This completes Tranche B (12 of 27 types now implemented, 9 to go —
  all in Tranche C). See doc/spec_notes.md for the full write-up.

- ✅ **Round 11 / Tranche C started: DCT4x4, the first "bespoke" transform
  type.** Unlike Tranche A/B (plain DCTs sharing one merge-cascade
  architecture), Tranche C's 9 types have no shared forward-transform
  machinery — the decoder reconstructs each via hand-derived formulas.
  Found most of the surrounding machinery (natural order, AC scatter,
  dequant loop, DC/LLF routing) is nonetheless already fully generic; only
  weight-table construction and pixel reconstruction are genuinely bespoke
  per type. A first derivation attempt (DCT2x2, hand-proved "self-inverse
  up to /4" for its 3-stage butterfly cascade) was caught WRONG by a
  design-review pass that built the real 64x64 linear map via basis
  injection — proof of one isolated stage doesn't extend to a multi-stage
  composition built from it. Switched to DCT4x4 (reuses the *verified*
  isolated single-stage case plus the already-generic `forwardDCT2D`),
  numerically confirmed end to end (a 64x64 basis-injection matrix,
  `M @ E == I` to 4.4e-16; 200 random-trial round-trips) before writing any
  production code, then re-derived as a permanent Dart identity test.
  Dropped an initially-planned new "bespoke vs. plain 8x8" chooser
  mechanism after design review found `tryMergeLevel` already degenerates
  to exactly that decision for a 1x1-footprint target type — zero new
  merge logic needed, just `_tt4x4` added to the existing bootstrap
  pre-pass list, gated by a new `enableBespokeTransforms` flag (off by
  default, mirrors `enableRectangularTransforms`'s precedent). Fixed two
  real plumbing gaps found by design review (weight-table construction and
  bitstream writing both assumed every type is `TransformMode.dct`-shaped,
  wrong for `TransformMode.dct4`) structurally, by extracting
  `getDct4x4QuantWeights` so both sides derive from the same function on
  the same params, rather than testing around the divergence.
  **Found and fixed a real, previously-undiscovered decoder bug** along
  the way: `_setupDctParam`'s `TransformMode.dct4` case read its 2 raw
  override values with an erroneous `*64` scaling (inherited — jxlatte has
  the identical mistake), silently corrupting exactly the coefficient
  positions carrying quadrant-DC-redistribution detail whenever a *custom*
  (non-default) DCT4x4 quant table was used — never caught before since no
  encoder had ever exercised that path. Found via the classic signature
  (our own decoder self-consistently correct, djxl very wrong), confirmed
  as a real bug (not "beyond jxlatte's capability") by running jxlatte on
  the same file and finding it agreed with our decoder, then root-caused
  and fixed on both the read and write sides, reverified against djxl.
  `hornuss`/`dct2`/`afv`'s own override reads have the identical `*64`
  pattern and are suspected to share this bug — flagged in code for
  whoever implements those types next, not fixed blind (unverifiable
  without an encoder to test them yet). An advisor review caught that
  every test so far forced a *uniform* tally, leaving DCT4x4's
  interleaving with plain DCT8x8/merged DCT16x16 in the same bitstream
  completely unexercised end-to-end (the same tier-interaction shape as
  Tranche B's flip=false gap) — added a mixed-layout config (checkerboard
  half + gradient half) that genuinely mixes all three transform types,
  round-tripped through djxl at 4 distances, passed first try. Full suite
  green (351 tests, up from 342). Default-path A/B (git stash, same real
  manga page) confirmed byte-identical output, comparable timing.
  `enableBespokeTransforms` stays off by default. This starts Tranche C
  (19 of 27 types now implemented, 8 to go). See doc/spec_notes.md for the
  full write-up.

- ✅ **Round 12 / Tranche C continued: Hornuss and DCT2x2.** Both forward
  derivations verified the same way as DCT4x4's — a Python basis-injection
  64x64 matrix built from the real decoder logic, checked to exact `0.0`
  deviation before writing any Dart, then re-verified as permanent Dart
  identity tests (passed first try, confirming the port too). Hornuss
  reuses DCT4x4's verified single-stage butterfly for cross-quadrant DC
  combination; DCT2x2 needed the corrected "tiered-scaling-plus-transpose"
  derivation flagged in round 11 (its 3-stage cascade's Gram matrix has a
  tiered 64/16/4 diagonal, not a uniform 4 — the true inverse is
  `transpose(cascade) / tieredScale`, confirmed by basis injection, not
  DCT4x4's debunked self-inverse shape). **Checked, not assumed, the
  suspected shared `*64` bug** round 11 explicitly left open
  ("hornuss/dct2/afv... unverifiable without an encoder... check when
  implementing those types"): two dedicated djxl round-trip tests using
  non-degenerate content (a smooth gradient for Hornuss, random noise for
  DCT2x2 — deliberately not flat/checkerboard content, which would make
  every governed coefficient exactly zero and hide a scaling error) both
  passed first try — the `*64` convention is correct as-is for these two
  modes, unlike dct4's genuine bug. `tryMergeLevel` now runs all three
  bespoke types (Hornuss, DCT2x2, DCT4x4) in sequence at the bootstrap
  tier, still under the single `enableBespokeTransforms` flag. **A more
  precise default-path A/B than prior rounds ran** (checked a non-default
  distance, not just 1.0) found that "byte-identical" only holds at
  distance=1.0: at distance=2.0, output already grew 36B after round 11
  (confirmed by rebuilding at the pre-round-11 commit) and grew another
  54B after this round, on a ~900KB file (~0.006% each time) — because
  `customParamsByIndex` writes a real but unused custom quant-weight table
  for every `_activeTransformTypes` entry whenever any non-default
  distance is used, regardless of that type's own enable flag. Pre-existing
  and cumulative (not new to this round), correctness-neutral (djxl
  decodes the extra tables fine, full suite green throughout), and
  negligible in size — doesn't block, but every prior round's
  "byte-identical" claim should be read as "at distance=1.0 specifically."
  Filed as a cleanup item below rather than fixed now (touches every
  tranche, not just this round's scope). Mixed-layout test now covers all
  5 active types at once (confirmed via encdebug tally:
  `{Hornuss: 39, DCT 8x8: 6, DCT 4x4: 1, DCT 2x2: 2, DCT 16x16: 4}` at
  distance=0.5). Full suite green (363 tests, up from 351).
  `enableBespokeTransforms` stays off by default (unchanged flag, now
  gating three types; same "never worse than plain 8x8/bootstrap" caveat
  `enableRectangularTransforms` already documents, not a stricter
  joint-optimum guarantee). This continues Tranche C (21 of 27 types now
  implemented, 6 to go: DCT4x8/DCT8x4 next — share DCT4x4's "butterfly +
  sub-block IDCT" shape almost exactly — then AFV last, most complex: a
  16x16 fixed basis matrix, a 3-region split, a decoder comment flagging a
  sign combination to double-check, and its own still-unverified `*64`
  suspicion). See doc/spec_notes.md for the full write-up.

- ✅ **Round 13 / Tranche C continued: DCT4x8 and DCT8x4.** Unlike
  Hornuss/DCT2x2 (no real DCT machinery), these share DCT4x4's "butterfly +
  sub-block IDCT" shape: a plain 2-point Hadamard (self-inverse up to /2,
  the 1D analog of DCT4x4's 4-point butterfly) combines the block's 2
  strips' own DC terms, each strip reconstructed via a genuine
  (height=4,width=8) forward/inverse DCT pair — DCT8x4's strips reuse the
  same `transposed=true` handling (dimension swap included) DCT4x4's own
  per-quadrant case already established. Both derivations verified by
  basis injection to ~2.2e-15 deviation before writing Dart, then
  re-derived as permanent Dart identity tests — which caught a real
  **test-only** bug immediately (a `RangeError` on first run): the DCT8x4
  identity test's first draft sized its intermediate decode buffer to
  (height=4,width=8) like DCT4x8's, but `transposed=true` at (4,8) writes
  an 8x4 *output* (the dimension swap), needing 8 rows not 4 — fixed by
  writing directly into the shared `fb` buffer, matching both the real
  decoder and DCT4x4's own test. DCT4x8/DCT8x4 share one parameterIndex
  and TransformMode (mirrors Tranche B's DCT16x8/DCT8x16 precedent).
  **The override read/write convention (`_setupDctParam`'s
  `TransformMode.dct4x8` case) was ALREADY `*64`-free**, matching dct4's
  fixed convention rather than hornuss/dct2's — verified anyway, not
  assumed: two djxl round-trip tests found the first content tried (a
  full-period sine) was **degenerate** for this purpose (sums to exactly
  zero per strip, making the override-affected coefficient trivially
  zero regardless of any bug — the same trap Hornuss's test avoided),
  switched to a "step+gradient" pattern (real DC difference between
  strips + a real per-strip gradient) that both wins outright (uniform
  `{DCT 4x8: 16}`/`{DCT 8x4: 16}` tallies at distances 0.5/1.0) and
  carries real override signal, confirming the convention correct.
  Mixed-layout test now covers ALL SEVEN active types at once (encdebug-
  confirmed: `{Hornuss: 38, DCT 8x8: 5, DCT 4x8: 17, DCT 4x4: 1, DCT 8x4:
  18, DCT 2x2: 1, DCT 16x16: 4}` at distance=0.5). Default-path A/B found
  another small, consistent increment (+31B at distance=2.0, unchanged at
  1.0) — same pre-existing `customParamsByIndex` cost flagged in round 12,
  not a new anomaly (cumulative drift from the pre-Tranche-C baseline: 36B
  + 54B + 31B = 121B at distance=2.0, still under 0.02% of file size).
  Full suite green (373 tests, up from 363); `flutter test` green on both
  packages. `enableBespokeTransforms` stays off by default (unchanged
  flag, now gating five types). This continues Tranche C (23 of 27 types
  now implemented, 4 to go — all AFV0-3: a 16x16 fixed basis matrix, a
  3-region split, a decoder comment flagging a sign combination to
  double-check, and its own still-unverified `*64` suspicion). See
  doc/spec_notes.md for the full write-up.

- ✅ **Round 14 / Tranche C final slice: AFV0-3 — Tranche C and full
  27-transform-type support are now COMPLETE.** The most complex bespoke
  type: unlike every prior one (a butterfly plus at most one DCT call),
  AFV splits the 8x8 block into 3 disjoint regions — a 4x4 region via a
  fixed custom 16x16 basis matrix (`afvBasis`, not a DCT), a 4x4 region
  via a transposed plain DCT, and a 4x8 region via a plain DCT — combined
  via a 3x3 (not 4-point/2-point) linear system, since AFV's regions only
  read 3 of the block's 4 corner coefficients. The decoder's own "SPEC:
  watch signs here" comment (flagging the region-2 DC combination
  `coeffs[0][0]+coeffs[1][0]-coeffs[0][1]`) made this the highest latent-
  bug risk in the tranche — verified with the full rigor that risk
  warranted: a Python basis-injection 64x64 matrix per flip variant
  (AFV0-3 independently, not assumed by symmetry), confirmed to 2.2e-15
  deviation, then 4 permanent Dart identity tests (all passed first try),
  then dedicated djxl round-trip tests per variant confirming the exact
  flagged sign combination was never a bug in this port. **A genuine
  simplification found, not assumed**: `afvBasis` turned out to be
  exactly orthonormal (confirmed by basis injection), so the forward
  transform reuses the same table with the two 4x4-position indices'
  roles swapped in the flat-array lookup — no new generated inverse table
  needed. Extracted `getAFVQuantWeights` (single-sourced, same precedent
  as every prior extraction). Checked, not assumed, the suspected shared
  `*64` bug flagged unverified since round 11: `_setupDctParam`'s afv case
  reads 6 of 9 param values with `*64` (matching hornuss/dct2's absolute-
  weight shape) — confirmed correct via djxl round-trips with
  non-degenerate "flat corner plus gradient" content (each AFV variant's
  own winning corner found empirically via `jxl.encdebug`, not assumed by
  flipY/flipX symmetry — AFV1/2/3's actual winning corner didn't match
  that naive guess). Mixed-layout test now covers every bespoke type
  except DCT4x4 in one bitstream at once at distance=0.5 (DCT4x4 covered
  at the other 3 distances instead, so all 9 types are exercised across
  the range). Default-path A/B found another consistent increment (+103B
  at distance=2.0, larger than prior ones since AFV's own param set is
  much bigger — 9 raw values plus 2 nested tables; unchanged at 1.0) —
  same pre-existing `customParamsByIndex` cost, cumulative 224B at
  distance=2.0 (still <0.025% of file size), not a new anomaly. Full
  suite green (385 tests, up from 373); `flutter test` green on both
  packages. `enableBespokeTransforms` stays off by default (unchanged
  flag, now gating all 9 Tranche C types). **All 27 of 27 VarDCT
  transform types now exist and are verified correct** — existence and
  default-on-ness remain separate: `enableRectangularTransforms`/
  `enableBespokeTransforms`/`maxTransformSize` beyond 16 all stay off/at-
  baseline pending a real-manga ROI evaluation across the full set, which
  hasn't been run yet — that, plus the rate-distortion search over
  transform size itself, are what's left once completeness is done. See
  doc/spec_notes.md for the full write-up.

- ✅ **Round 15: the `customParamsByIndex` cleanup — done more precisely
  than scoped.** The first attempt matched this entry's own original
  wording (filter by which types each config's *flags* make reachable,
  mirroring `_decideTransformLayout`'s gating in a parallel function) and
  broke 11 existing tests: "reachable given the flags" is coarser than
  "actually placed in this candidate" (a pre-pass tries several candidate
  types per cell and keeps one winner), and that gap fell unevenly across
  the two sides of every existing "does X genuinely win" test. The real
  fix: `_finishEncode` (already receiving each candidate's real
  `placedBlocks` list) now derives `customParamsByIndex` from which types
  are *actually placed* in that specific candidate — no parallel gating
  table needed (removed `_reachableTransformTypes` entirely, avoiding
  exactly the drift-from-two-copies risk this project avoids everywhere
  else). Every candidate, in every config, now pays for exactly the
  custom tables its own blocks use — genuinely byte-optimal, not just
  "no worse than flag-off." A pleasant surprise, verified via djxl not
  assumed: the default-path A/B now measures *smaller* than even the
  pre-Tranche-C baseline (912585B vs. 913107B at distance=2.0) — that
  baseline was itself never byte-optimal once Tranche A/B were both
  complete (18 active types), just not measured precisely enough to
  notice before this round. One existing test ("DCT 16x8/8x16 genuinely
  wins," a 32x32 canvas) needed re-tuning to 64x64 for a legitimate
  reason: byte-precise accounting exposed that its original margin was
  always paper-thin (a fixed one-time weight-table cost a tiny canvas
  couldn't amortize), re-swept via `jxl.encdebug` to a size where the
  real win (43-153B across the 4 standard distances) is unambiguous — the
  correct fix given the encoder's new accounting is more correct, not a
  loosened assertion. Full suite green (385 tests, count unchanged);
  `flutter test` green; a git-stash A/B timing comparison found no
  measurable performance difference. This closes the last item from the
  transform-type-completeness effort's own cleanup backlog. See
  doc/spec_notes.md for the full write-up.

- ✅ **Round 16: a live prediction grid sharpens the transform-size
  cascade — the "sharper cascade" scope of "a real rate-distortion search
  over transform size."** Scoped before implementing (see doc/
  spec_notes.md): a literal "refresh at every level" would mean re-
  running `_chooseAcClustering` 5+ more times per candidate, and that
  function is not a statistics pass — it real-assembles the entire
  image's tokens through several candidate cluster budgets just to
  measure the smallest, an expensive thing to multiply. The other frozen
  input, each block's "predicted non-zero count," is cheap to keep live
  instead (an O(1) west/north-neighbor dependency, not image-wide), so
  that's what got fixed: a live per-group prediction grid, seeded by
  `_computeGroupTokens` while it builds the bootstrap's own tokens (no
  duplicate pass) and updated incrementally by `tryMergeLevel` as each
  region's winner is decided, replacing the old scheme that always read a
  position's predicted value from the *original all-8x8 bootstrap* block
  there regardless of what any west/north neighbor had since become —
  even within one level's own raster scan, not just across levels.
  Verified via a git-worktree A/B at the pre-round commit: at a config
  that actually exercises multiple cascade levels (`maxTransformSize:
  256`, rectangular + bespoke both on), a real, sometimes substantial
  improvement (up to ~4%, -727B on a small corpus file) at 3 of 4 tested
  distances; smaller but still nonzero at the default (single-level)
  config. Confirmed correct via djxl (RMSE 0.41-0.47, well within gate).
  Full suite green (385 tests, unchanged — this changes which candidate a
  greedy decision favors, not the never-worse outer safety net);
  `flutter test` green; no measurable timing regression. See
  doc/spec_notes.md for the full write-up.

- 🔲 **Follow-up, found not fixed: elevated RMSE at one specific non-
  default config.** `screentone_256_d0_e7.pgm`, `maxTransformSize: 256`
  + `enableRectangularTransforms: true` + `enableBespokeTransforms: true`,
  distance=1.0, decodes through djxl with RMSE 3.24 — above this
  project's usual `< 2.0` gate. Confirmed (via a git-worktree check
  against the pre-round-16 commit) to be byte-for-byte pre-existing, not
  introduced by round 16 or the customParamsByIndex cleanup — a real
  latent gap in this specific combination of flags/content/distance, not
  currently caught by the standard test suite's own synthetic "genuinely
  wins" content. Worth root-causing (likely somewhere in the interaction
  between a large cascade and RDOQ/hfMult's own heuristics) before
  `enableRectangularTransforms`/`enableBespokeTransforms`/
  `maxTransformSize` beyond 16 are ever considered for default-on, but not
  blocking anything currently shipped (all default off).

- **Next phase, now that all 27 transform types exist: real-manga ROI
  evaluation, and (separately, lower priority) a genuine joint search
  over transform type/size.** Every tranche/size beyond the round-6
  baseline (8x8/16x16) still defaults off or at its round-6 baseline
  (`maxTransformSize: 16`, `enableRectangularTransforms: false`,
  `enableBespokeTransforms: false`) because each round deliberately
  scoped "does it exist and work" apart from "should it be on by default
  for manga" (see `maxTransformSize`'s own doc comment for the DCT32x32
  case study of why these are separate questions). With the full set now
  built and the existing cascade's own rate estimates sharpened (round
  16), the next phase is evaluating real `manga_samples/` pages across
  the whole space — which combinations of tranche/size actually help
  manga content, not just synthetic benchmarks — and only then
  reconsidering any defaults. Separately, the cascade is still a fixed
  bottom-up order (8x8 vs. 16x16 vs. rectangular vs. bespoke, then a
  square-size cascade beyond that), never a genuine joint search over the
  full 27-type space per region — a materially bigger change (real
  encode-time cost, not just an accuracy improvement) that's worth
  scoping only once the ROI question above narrows which types are
  actually worth searching over.

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
