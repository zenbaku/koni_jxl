# Changelog

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
  tree and per-image choice of LZ77 / ANS / palette / YCoCg RCT by exact
  coded-size estimation. Every output is verified bit-exact through this
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
