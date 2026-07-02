# koni_jxl

A pure-Dart **JPEG XL (`.jxl`) codec** — decode and losslessly encode,
with **zero native dependencies** and zero runtime package dependencies.
Works on every platform Dart runs on: Android, iOS, macOS, Windows,
Linux, and (with reduced lossy speed) the web.

Correctness is verified **bit-exact against libjxl's `djxl`** on a
generated corpus, the official conformance suite, and real-world
JPEG-transcoded manga chapters.

```dart
import 'package:koni_jxl/koni_jxl.dart';

// Cheap header-only inspection (reads a few hundred bytes):
final info = JxlInfo.parse(bytes);
print('${info.width}x${info.height}, ${info.bitsPerSample}-bit');

// Full decode to interleaved RGBA (sRGB, EXIF-oriented):
final image = JxlDecoder.decode(bytes);
final rgba = image.toRgba8();

// All frames of an animation:
final anim = JxlDecoder.decodeAnimation(bytes);

// Lossless encode from raw RGBA:
final jxl = JxlEncoder.encodeLossless(rgba,
    width: image.width, height: image.height, hasAlpha: true);
```

For Flutter widgets (`JxlImageProvider`, animation and progressive
playback, background-isolate encode), use
[`koni_jxl_flutter`](https://pub.dev/packages/koni_jxl_flutter).

## Features

**Decoding**

- Modular (lossless) still images — **bit-exact vs libjxl**
- VarDCT (lossy) still images — within ~1 RMSE of libjxl
- Animation (all frames, durations, loop count)
- Splines, progressive DC (LF) frames, multi-pass AC
- Streaming decode with a 1:8 DC preview
  (`JxlStreamingDecoder`) for blurry-then-sharp display
- Grayscale/RGB, palette, alpha, 8/16-bit, EXIF orientation
- Embedded ICC profiles; header-only `JxlInfo.parse`

**Encoding** (lossless)

- `JxlEncoder.encodeLossless` / `encodeLossless16` from raw pixels
- `JxlEncoder.encodeImage` for JXL→JXL transcodes
- Per-image LZ77 / ANS / palette / YCoCg RCT selection; every output is
  verified bit-exact through this decoder **and** `djxl`

**Robustness** — all decode surfaces throw only `JxlException` on
malformed input (mutation-fuzz verified); `JxlLimits` caps
header-driven allocations.

Not yet supported (decoding throws `JxlUnsupportedException` with a
stable feature id): spot-color rendering, JPEG bitstream reconstruction,
and float (HDR) sample formats. Encoding is lossless-only.

## Performance

Apple Silicon, AOT, single-threaded: a 1536×2200 lossless page decodes
in ~60–410 ms; typical lossy pages in ~0.3–0.5 s, using Float32x4 SIMD
across the lossy pipeline (native on AOT targets; emulated on the web).

## Command-line tools

```bash
dart run koni_jxl:jxl_info image.jxl         # header info
dart run koni_jxl:jxl_dec  image.jxl out.ppm # decode to PNM/PAM
dart run koni_jxl:jxl_enc  in.ppm  out.jxl   # lossless encode
```

## License

MIT. Ported from [jxlatte](https://github.com/Traneptora/jxlatte) (MIT);
see `NOTICE` in the [repository](https://github.com/zenbaku/koni_jxl).
