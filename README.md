# koni_jxl

**Pure Dart JPEG XL (JXL) decoder** — render `.jxl` images in Dart and
Flutter with **zero native dependencies**. Works on every platform Dart
runs on: Android, iOS, macOS, Windows, Linux.

| Package | Description |
|---|---|
| [`packages/koni_jxl`](packages/koni_jxl) | The decoder: pure Dart, zero runtime dependencies |
| [`packages/koni_jxl_flutter`](packages/koni_jxl_flutter) | Flutter bindings: `JxlImageProvider`, isolate decoding |

## Quick start (Flutter)

```dart
import 'package:koni_jxl_flutter/koni_jxl_flutter.dart';

Image(image: JxlImageProvider.asset('assets/page.jxl'))
```

## Quick start (pure Dart)

```dart
import 'package:koni_jxl/koni_jxl.dart';

final info = JxlInfo.parse(bytes);          // header only, cheap
final image = JxlDecoder.decode(bytes);     // full decode
final rgba = image.toRgba8();               // interleaved RGBA bytes
```

## Status

Correctness is verified **bit-exact against libjxl's `djxl`** on a large
generated corpus and the official conformance test suite.

Supported today:

- ✅ Modular (lossless) still images — the format used by `cjxl -d 0`
  (PNG→JXL conversions, manga/comic archives, screenshots, line art)
- ✅ Grayscale, RGB, palette (incl. delta palette), alpha, 8/16-bit
- ✅ All modular predictors incl. the self-correcting weighted predictor
- ✅ RCT, palette, and squeeze (responsive) transforms
- ✅ Patches, reference frames, all blend modes
- ✅ ISOBMFF container and bare codestreams; EXIF orientation
- ✅ Embedded ICC profiles (decoded and exposed)
- ✅ First frame of animated files

Not yet (decoding throws `JxlUnsupportedException` with the feature name):

- ⏳ VarDCT (lossy) images — in progress (M5)
- ⏳ Gaborish/EPF restoration filters, upsampling, noise, splines (M6)
- ⏳ Animation (all frames), progressive decode, JPEG reconstruction

Performance (Apple Silicon, AOT, single-threaded): a 1536×2200 lossless
manga page decodes in ~60 ms (effort 1 encodes) to ~530 ms (effort 7–9),
roughly 3.5× single-threaded `djxl`.

## Development

```bash
dart pub get
cd packages/koni_jxl && dart test           # unit + gate tests
python3 tool/gen_corpus.py                  # regenerate test corpus (needs cjxl)
python3 tool/check_jxl_info.py              # header gate vs jxlinfo
```

The decoder is ported from [jxlatte](https://github.com/Traneptora/jxlatte)
(MIT) and cross-checked against
[jxl-oxide](https://github.com/tirr-c/jxl-oxide) and ISO/IEC 18181. See
`NOTICE`.

## License

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
