# Changelog

## 0.1.0-dev

- Initial release: pure Dart JPEG XL decoder.
- Modular (lossless) still images decode bit-exact vs libjxl: all
  predictors incl. weighted, RCT/palette/squeeze transforms, patches,
  reference frames, blending, alpha, 8/16-bit, EXIF orientation.
- Animation: `JxlDecoder.decodeAnimation` decodes all visible frames
  with durations, timecodes and loop count.
- Lossless encoding: `JxlEncoder.encodeLossless` / `encodeLossless16`
  (interleaved 8/16-bit gray/RGB with optional alpha) and
  `JxlEncoder.encodeImage` (JXL transcode). Modular with a fixed
  7-context gradient tree, per-image choice of LZ77 / palette / YCoCg
  RCT by exact coded-size estimation, prefix codes; output verified
  bit-exact through this decoder and djxl on every test.
- Robustness: all decode surfaces throw only `JxlException` on malformed
  input (fuzz-verified); `JxlLimits` caps header-driven allocations.
- Header-only `JxlInfo.parse`, embedded ICC profile decoding.
- `jxl_info` and `jxl_dec` CLIs.
- VarDCT (lossy) still images decode within ~1 RMSE of libjxl: all 27
  transform types, chroma-from-luma, XYB, Gaborish + EPF filters,
  upsampling, noise synthesis, YCbCr.
- Performance: row-based image planes, Lee-recursion DCT with fused
  unrolled 8x8 inverse kernel, specialized edge-preserving-filter loops,
  Float32x4 SIMD in the 8x8 IDCT / batched large-block IDCT /
  dequantization / XYB inverse / gaborish / edge-preserving filter
  (native on AOT targets; emulated on the web), allocation-free weighted
  predictor with an interior fast path, lazy quant-weight and
  coefficient-order setup.
- Splines (centripetal Catmull-Rom rendering with per-spline DCT32
  color/sigma profiles).
- Progressive files: LF frames (progressive DC) and multi-pass AC.
- Streaming: `JxlStreamingDecoder` decodes incrementally arriving bytes —
  header info, buffering progress, a 1:8 DC preview once the DC sections
  (or a progressive-DC LF frame) are available, and the final image.
- Not yet supported (throws `JxlUnsupportedException`): spot-color
  rendering, JPEG reconstruction, float (HDR) sample formats.
