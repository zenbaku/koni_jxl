# Changelog

## Unreleased

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
