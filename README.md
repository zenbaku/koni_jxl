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

// Progressive display straight from a network byte stream:
JxlProgressiveImage(httpResponse.stream)
```

## Quick start (pure Dart)

```dart
import 'package:koni_jxl/koni_jxl.dart';

final info = JxlInfo.parse(bytes);          // header only, cheap
final image = JxlDecoder.decode(bytes);     // full decode (first frame)
final rgba = image.toRgba8();               // interleaved RGBA bytes

final anim = JxlDecoder.decodeAnimation(bytes);   // all frames
final delay = anim.frameDuration(0);              // per-frame Duration

final session = JxlStreamingDecoder();            // progressive display
session.addBytes(chunk);                          // as bytes arrive...
if (session.state == JxlStreamState.dcReady) {
  final blurry = session.decodePreview();         // 1:8 DC preview
}
```

## Status

**Feature-complete for its target use case** (manga/comic readers and
general image display). All planned milestones (M0–M7) are done:
container/headers, the full entropy stack, lossless modular, lossy
VarDCT, restoration filters, animation, splines, and a Float32x4 SIMD
performance pass.

Correctness is verified **bit-exact against libjxl's `djxl`** on a large
generated corpus and the official conformance test suite (~210 automated
tests), and validated on real-world commercially-distributed CBZ chapters
containing JPEG-transcoded JXL pages: **34/34 pages match djxl within a
max pixel difference of 1/255**.

Supported today:

- ✅ Modular (lossless) still images — the format used by `cjxl -d 0`
  (PNG→JXL conversions, manga/comic archives, screenshots, line art) —
  **bit-exact vs libjxl**
- ✅ VarDCT (lossy) still images — all 27 transform types, adaptive
  quantization, chroma-from-luma, XYB color, Gaborish + edge-preserving
  filters (within ~1 RMSE of libjxl; see `doc/spec_notes.md`)
- ✅ Upsampling (2x/4x/8x), noise synthesis, YCbCr + chroma subsampling
- ✅ Grayscale, RGB, palette (incl. delta palette), alpha, 8/16-bit
- ✅ All modular predictors incl. the self-correcting weighted predictor
- ✅ RCT, palette, and squeeze (responsive) transforms
- ✅ Patches, reference frames, all blend modes
- ✅ ISOBMFF container and bare codestreams; EXIF orientation
- ✅ Embedded ICC profiles (decoded and exposed)
- ✅ Animation: all frames with durations and loop count
  (`JxlDecoder.decodeAnimation`, `JxlAnimationView` widget) — the
  newtons_cradle conformance animation is bit-exact on all 36 frames
- ✅ Splines (both spline conformance cases within 1/255 of djxl)
- ✅ Progressive DC (LF frames), multi-pass AC — files from
  `cjxl --progressive_dc` decode within lossy tolerance of djxl
- ✅ Streaming decode: `JxlStreamingDecoder` turns partial bytes into a
  1:8 preview (blurry-then-sharp progressive display);
  `JxlProgressiveImage` renders an http byte stream directly

Not yet (decoding throws `JxlUnsupportedException` with the feature name):

- ⏳ Spot-color rendering, extra-channel blend modes
- ⏳ JPEG bitstream reconstruction
- ⏳ Float (HDR) sample formats; ICC-driven output color transforms

Performance (Apple Silicon, AOT, single-threaded): a 1536×2200 lossless
manga page decodes in ~60 ms (effort 1 encodes) to ~400 ms (effort 7–9).
Lossy (VarDCT) pages decode in ~0.3 s (JPEG-transcoded manga chapters) to
~0.5 s (worst-case dense screentone at effort 7), using Float32x4 SIMD
throughout the float pipeline: fused 8×8 inverse DCT, batched-vector
large DCTs, dequantization, XYB inverse, gaborish and EPF filters.
Flutter Web (dart2js) emulates SIMD and decodes lossy images noticeably
slower.

## Encoding (new)

`JxlEncoder` provides pure-Dart **lossless encoding** (modular, prefix
codes, fixed gradient-context tree, YCoCg RCT for color):

```dart
final jxl = JxlEncoder.encodeLossless(rgbaBytes,
    width: w, height: h, hasAlpha: true);
final again = JxlEncoder.encodeImage(decodedImage);  // JXL -> JXL transcode
```

Every encoded file is gated bit-exact through **both** this package's
decoder and djxl. The encoder picks per image between LZ77, palette
(≤256 colors) and YCoCg RCT by exact coded-size estimates. Sizes vs
`cjxl -e1` on the benchmark set: real manga page 93%, color cover 78%,
16-color art 112%, synthetic screentone **7%** (LZ77 dominates there).
~0.3–1 s/page single-threaded. 8/16-bit gray/RGB with optional alpha;
lossy encoding is not implemented (use cjxl for that).

Flutter: `encodeJxlFromRgba` / `encodeJxlFromUiImage` run the encoder in
a background isolate.

## Development

```bash
dart pub get
cd packages/koni_jxl && dart test           # unit + gate tests
cd packages/koni_jxl_flutter && flutter test
python3 tool/gen_corpus.py                  # regenerate test corpus (needs cjxl/djxl)
python3 tool/check_jxl_info.py              # header gate vs jxlinfo
```

Differential gates (bit-exact lossless compares, lossy RMSE thresholds)
run automatically when `cjxl`/`djxl` and the generated corpus are
present, and skip cleanly otherwise. `doc/spec_notes.md` documents every
known deviation from libjxl and from the jxlatte reference (including
two jxlatte bugs this decoder fixes). See `CLAUDE.md` for the full
development playbook.

The decoder is ported from [jxlatte](https://github.com/Traneptora/jxlatte)
(MIT) and cross-checked against
[jxl-oxide](https://github.com/tirr-c/jxl-oxide) and ISO/IEC 18181. See
`NOTICE`.

## License

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
