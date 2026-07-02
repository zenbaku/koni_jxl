# koni_jxl

Pure Dart JPEG XL (`.jxl`) image decoder. Zero native dependencies, zero
runtime package dependencies — works on every Dart platform.

```dart
import 'package:koni_jxl/koni_jxl.dart';

// Header-only parse (cheap):
final info = JxlInfo.parse(bytes);
print('${info.width}x${info.height}, ${info.bitsPerSample}-bit');

// Full decode:
final image = JxlDecoder.decode(bytes);
final rgba = image.toRgba8(); // interleaved RGBA, sRGB, oriented

// Unsupported features throw JxlUnsupportedException with a stable
// feature id ('vardct', 'animation', ...) so you can fall back per-file.
```

Currently decodes modular (lossless) still images bit-exactly — see the
[repository README](https://github.com/zenbaku/koni_jxl) for the feature
matrix and roadmap (VarDCT/lossy support is in progress).

For Flutter, use
[`koni_jxl_flutter`](https://pub.dev/packages/koni_jxl_flutter) which adds
an `ImageProvider` with background-isolate decoding.

Includes two CLIs:

```bash
dart run koni_jxl:jxl_info image.jxl        # header info
dart run koni_jxl:jxl_dec image.jxl out.ppm # decode to PNM/PAM
```
