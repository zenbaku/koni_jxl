# Changelog

## 0.1.2

### Decoding

- Fixed 7 Java-int-truncation overflow bugs in modular (lossless)
  prediction and entropy reconstruction: the weighted predictor's `eSum`
  masking (the original crash) and its subpred/n3 truncation, the simple
  predictor's averaging/gradient cases, MA-tree property computation
  (including cross-channel gradient), the core per-pixel decode loop, and
  hybrid-uint reconstruction's final mask. Found while auditing
  float-sample support (packed values approach the full ±2^31 range,
  unlike ordinary 8/16-bit samples) and verified against jxlatte/libjxl
  source; includes a genuine bug inherited from jxlatte, where the
  hybrid-integer extra-bit count now correctly wraps via `n &= 31`
  (matching libjxl) instead of rejecting anything over 32.
- Fixed 32-bit bitwise-op truncation on the `dart2js` web target.
  `dart2js` compiles `int` to a JS double and coerces every bitwise
  operator through JS's `ToInt32`/`ToUint32`, silently corrupting the bit
  reader, the weighted predictor (decode and encode), VLC/hybrid-integer
  sentinels, and `XorShiro`'s 64-bit noise constants whenever a value or
  shift amount left 32-bit range — latent on `dart2wasm` (real 64-bit
  ints, this project's actual web target), live on `dart2js`. Found with
  a new differential oracle comparing native vs. `dart2js` output on the
  corpus.
- 18-24% faster real-manga decode (~0.3s → ~0.25s): skip redundant
  integer divisions in the AC coefficient context computation for the
  (common, for JPEG-transcoded manga content) single-block case, and
  replace six full-block-list scans with a precomputed per-LF-group
  index. Lossless decode is also 2-4% faster generally from a matching
  fix to `MaTree.compactify()`.

### Encoding

- **Fixed 16x16 transform-size selection, now on by default.** Replaced
  the old pre-quantization coefficient-magnitude proxy — which
  over-selected 16x16 on manga content (+20% screentone, +31% line art)
  — with a real bootstrap-frozen bit-rate estimate plus a whole-image
  real-assembly safety net, so enabling this can never produce a larger
  file than leaving it off. `VardctL0Config.enableVariableTransforms` now
  defaults to **true**: 4-27% smaller with better RMSE on photographic
  content across `distance` 0.5-8.0, never worse on screentone/line-art;
  narrows the gap to `cjxl -e1` from 1.52x-2.79x to 1.18x-1.82x on the
  benchmark corpus. A further cascade refinement (candidate scoring now
  uses a live, incrementally-updated neighbor-prediction grid instead of
  a frozen bootstrap snapshot) shrinks output up to a further ~4% on
  multi-level transform-size configurations.
- **All 27 VarDCT transform types now exist and are `djxl`-verified
  correct** (up from 8x8/16x16 only): every remaining square size (32x32
  through 256x256, `maxTransformSize`), all 12 rectangular types
  (`enableRectangularTransforms`), and all 9 bespoke types — DCT4x4,
  DCT2x2, Hornuss, DCT4x8/DCT8x4, AFV0-3 (`enableBespokeTransforms`).
  This completes the full-format-coverage goal tracked since 0.1.1's L3
  milestone. A real-manga ROI evaluation across 144 encodes of real
  chapter pages found real but small wins (best combination: -0.86% at
  6.1x baseline encode time) — every one of these knobs stays **off by
  default**; existence and default-on-ness remain separate questions.
  See `ROADMAP.md`/`doc/spec_notes.md` for the full numbers.

## 0.1.1

### API

- **`looksLikeJxl(bytes)`** — cheap signature sniff (bare `FF 0A`
  codestream or the ISOBMFF container box) for routing bytes of mixed
  image formats to the right decoder, e.g. inside a custom Flutter
  `ImageProvider`. Never throws.

### Encoding

- **Lossy (VarDCT) — L0 milestone.** `JxlEncoder.encodeLossy` produces a
  real VarDCT stream: 8x8-DCT-only, uniform quantization mirroring the
  decoder's own dequantization formulas, chroma-from-luma pre-subtraction,
  filters off, single group (width/height multiples of 8, up to 256x256).
  This is a correctness-first milestone (see ROADMAP.md) — quality and
  compactness come with later phases.
- **Lossy (VarDCT) — L1 milestone.** `encodeLossy` gained a `distance:`
  parameter, the real HF coefficient context model (in place of L0's
  single shared histogram — meaningfully smaller files on busier images),
  and multi-group support (up to 2048x2048, still a single LF group; see
  ROADMAP.md for the multi-LfGroup gap).
- **Lossy (VarDCT) — L2 milestone.** Adaptive per-block quantization
  (~65-70% RMSE reduction on smooth/gradient content, where fixed
  quantization causes visible banding), a custom per-frequency quant
  weight table that removes `distance`'s previous quality floor (now
  monotonic down to `distance = 0.05` in testing, vs. plateauing around
  0.5-0.8 before), and a global (whole-image) chroma-from-luma fit. See
  ROADMAP.md for the remaining per-region CfL upgrade.
- **Lossy (VarDCT) — L3 milestone.** Two opt-in additions, both **off by
  default**: Gaborish + edge-preserving filtering
  (`VardctL0Config.enableFilters`), and adaptive per-region 8x8/16x16
  transform size selection (`enableVariableTransforms`). Both are real,
  djxl-verified working capabilities that help smooth/photographic
  content but were measured to regress manga's dominant content types
  (screentone, line art) by a wide margin, so both default off — see
  doc/spec_notes.md for the full numbers.
- **Lossy (VarDCT) — per-region chroma-from-luma.** Upgraded L2's
  global-only chroma-from-luma fit to the spec's real per-64x64-region
  granularity (`HfMetadata`'s `xFromY`/`bFromY`), on by default: ~26%
  RMSE reduction at roughly the same file size on content with genuinely
  different color relationships across regions, vs. ~1% size overhead on
  content with no real regional color variation to exploit.
- **Lossy (VarDCT) — multi-LF-group support.** `encodeLossy` no longer
  caps at 2048x2048: images of any size now split into multiple LF
  groups as needed, matching the format's own structure. The AC entropy
  coding path required no changes — groups were already numbered
  independent of LF groups end-to-end — so this only needed splitting
  DC/HfMetadata into per-LF-group sections and restructuring the TOC.
- **Lossy (VarDCT) — L4 milestone.** `encodeLossy` now accepts *any*
  positive width/height, not just multiples of 8 (padded internally via
  edge replication, true size written to the header — see
  doc/spec_notes.md). New `encodeJxlLossyFromRgba`/
  `encodeJxlLossyFromUiImage` Flutter helpers (`koni_jxl_flutter`, alpha
  dropped). New real-corpus lossy round-trip gate
  (`test/encode/encoder_lossy_corpus_test.dart`) and a `cjxl`-comparison
  benchmark (`tool/bench_lossy_vs_cjxl.dart`) — this encoder currently
  produces files 1.5-5x larger than `cjxl -e1` at matched `distance`,
  expected given no rate-distortion search and only 2 of 27 transform
  types, now measured concretely rather than assumed. `VardctL0Config` is
  now exported from the public API.
- **Lossy (VarDCT) — DC gradient prediction.** DC (LF) coefficients were
  being encoded with zero spatial prediction — over half this encoder's
  total output size on real photo content, more than the AC coefficients.
  Now uses the same clamped-gradient predictor (predictor 5) the lossless
  encoder already uses, cutting DC size 49-75% and total file size 25-27%
  on the corpus's two RGB test images, roughly halving the size gap vs
  `cjxl -e1`.
- **Lossy (VarDCT) — weighted predictor for DC.** DC coefficients now
  also try the self-correcting weighted predictor (predictor 6) alongside
  the clamped-gradient predictor, keeping whichever compresses smaller —
  a further ~5% reduction on real photo content where WP wins, no change
  where gradient already wins.
- **Lossy (VarDCT) — RD-hfMult search (`VardctL0Config.enableRdHfMult`,
  off by default).** A genuine per-block rate-distortion search replacing
  the crude 3-bucket adaptive-quantization heuristic: real weighted-
  squared-error distortion, a real Huffman-code-length-based rate
  estimate (`EntropyCodes.tokenBitLengths()`, new), correctness-verified
  against djxl in every configuration tried. Calibration
  (`tool/calibrate_rd_lambda.dart`) found no single trade-off constant
  both beats the heuristic on real photo content and preserves its
  smooth-gradient banding protection — a genuine modeling limit (plain
  weighted MSE can't see banding sensitivity the way a real perceptual
  metric would), not a bug, documented in doc/spec_notes.md.
- **ANS (rANS)** is now a per-image lossless entropy candidate alongside
  prefix codes, and can carry LZ77 matches (`plain`/`LZ77` x
  `prefix`/`ANS`, smallest actual output wins).
- **Learned per-image context tree** replaces the fixed 7-context MA tree:
  a greedy entropy-minimizing split search over decoder properties, up to
  64 contexts.
- **Weighted predictor** is now a second per-image predictor candidate
  (alongside clamped gradient), with its own property set including the
  WP max-error signal.

## 0.1.0

First release. A pure-Dart JPEG XL codec with zero native dependencies,
verified against libjxl (`djxl`) and the official conformance suite.

### Decoding

- **Lossless (Modular)** still images decode **bit-exact vs libjxl**: all
  predictors including the self-correcting weighted predictor, RCT /
  palette (incl. delta palette) / squeeze transforms, patches, reference
  frames, all blend modes, alpha, 8/16-bit, EXIF orientation.
- **Lossy (VarDCT)** still images decode within ~1 RMSE of libjxl: all 27
  transform types, adaptive quantization, chroma-from-luma, XYB color,
  Gaborish and edge-preserving filters, upsampling, noise synthesis,
  YCbCr with chroma subsampling.
- **Animation** — `JxlDecoder.decodeAnimation` returns all visible frames
  with per-frame durations, timecodes and loop count.
- **Splines**, **progressive DC (LF) frames** and **multi-pass AC**.
- **Streaming** — `JxlStreamingDecoder` decodes incrementally arriving
  bytes: header info, buffering progress, a 1:8 DC preview once the DC
  sections (or a progressive-DC frame) are available, then the final
  image.
- Header-only `JxlInfo.parse` and embedded ICC profile decoding.

### Encoding

- **Lossless** — `JxlEncoder.encodeLossless` / `encodeLossless16`
  (interleaved 8/16-bit gray/RGB with optional alpha) and
  `encodeImage` (JXL→JXL transcode). Modular with a fixed gradient-context
  per-image learned context tree over either the clamped-gradient or
  self-correcting weighted predictor, palette / YCoCg RCT, and the
  smallest of four entropy modes ({plain, LZ77} x {prefix, ANS}) chosen
  by actual coded size. Every output is verified bit-exact through this
  decoder **and** `djxl` in tests.

### Robustness & performance

- All decode surfaces throw only `JxlException` on malformed input
  (mutation-fuzz verified); `JxlLimits` bounds header-driven allocations.
- Float32x4 SIMD across the lossy pipeline (fused 8×8 and batched
  large-block inverse DCT, dequantization, XYB inverse, Gaborish, EPF);
  native on AOT targets, emulated on the web. A 1536×2200 lossless page
  decodes in ~60–410 ms; typical lossy pages in ~0.3–0.5 s.

### Tools

- `jxl_info`, `jxl_dec` and `jxl_enc` command-line utilities.

### Not yet supported

Decoding throws `JxlUnsupportedException` (with the feature name) for
spot-color rendering, JPEG bitstream reconstruction, and float (HDR)
sample formats. Encoding is lossless-only.
