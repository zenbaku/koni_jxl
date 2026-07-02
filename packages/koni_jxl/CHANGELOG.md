# Changelog

## 0.1.0-dev

- Initial release: pure Dart JPEG XL decoder.
- Modular (lossless) still images decode bit-exact vs libjxl: all
  predictors incl. weighted, RCT/palette/squeeze transforms, patches,
  reference frames, blending, alpha, 8/16-bit, EXIF orientation.
- Header-only `JxlInfo.parse`, embedded ICC profile decoding.
- `jxl_info` and `jxl_dec` CLIs.
- VarDCT (lossy) still images decode within ~1 RMSE of libjxl: all 27
  transform types, chroma-from-luma, XYB, Gaborish + EPF filters,
  upsampling, noise synthesis, YCbCr.
- Not yet supported (throws `JxlUnsupportedException`): splines,
  spot-color rendering, animation, progressive/LF frames, JPEG
  reconstruction, float (HDR) sample formats.
