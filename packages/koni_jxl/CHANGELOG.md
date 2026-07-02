# Changelog

## 0.1.0-dev

- Initial release: pure Dart JPEG XL decoder.
- Modular (lossless) still images decode bit-exact vs libjxl: all
  predictors incl. weighted, RCT/palette/squeeze transforms, patches,
  reference frames, blending, alpha, 8/16-bit, EXIF orientation.
- Header-only `JxlInfo.parse`, embedded ICC profile decoding.
- `jxl_info` and `jxl_dec` CLIs.
- VarDCT (lossy), restoration filters, upsampling and animation are not
  yet supported and throw `JxlUnsupportedException`.
