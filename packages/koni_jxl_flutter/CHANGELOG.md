# Changelog

## 0.1.0

First release. Flutter bindings for the pure-Dart `koni_jxl` codec.

- `JxlImageProvider` (`.asset` / `.file` / `.memory`) and
  `decodeJxlToUiImage` — decode `.jxl` in a background isolate,
  integrated with Flutter's image cache.
- `decodeJxlAnimation` and the `JxlAnimationView` widget — play animated
  JPEG XL with correct frame timing and loop count.
- `decodeJxlProgressive` and the `JxlProgressiveImage` widget — show a
  blurry 1:8 preview while bytes stream in, then the sharp final image.
- `encodeJxlFromRgba` / `encodeJxlFromUiImage` — lossless JPEG XL
  encoding in a background isolate.
