# Changelog

## 0.1.2

- **`JxlPagePrefetcher`** — decodes upcoming pages of a sequential reader
  (manga chapters, documents, etc.) on background isolates ahead of when
  they're displayed. `setCurrentIndex` keeps a
  `[index - behindCount, index + aheadCount]` window decoded or decoding,
  cancelling in-flight decodes and evicting cached results outside the
  window as the reader navigates; `imageFor` returns the decoded image
  whether or not it was prefetched. `.fromBytesList` / `.fromFiles` /
  `.fromAssets` constructors. Cancellation interrupts an in-flight decode
  within 1-2ms. Falls back to on-demand decode on the web, which has no
  isolates.
- Picked up `koni_jxl` 0.1.2's decoder correctness fixes and ~18-24%
  faster real-manga decode (see that package's changelog).

## 0.1.1

- **`decodeJxlToUiCodec`** — decode to a `ui.Codec`, the shape custom
  `ImageProvider`s feed to `MultiFrameImageStreamCompleter`. Stills yield
  a single-frame codec; animated files carry their frame durations and
  loop count. Handles the engine's raw-descriptor lifetime rules
  internally (frames are extracted before the backing buffers are
  released, then handed out as clones).
- **`jxlAwareDecode(bytes, decode)`** — the drop-in seam for apps whose
  providers render mixed formats from one byte source: sniffs JPEG XL by
  content (`looksLikeJxl`, re-exported from `koni_jxl` 0.1.1) and decodes
  it here; anything else goes to the engine callback unchanged.
- `JxlImageProvider` now uses `decodeJxlToUiCodec`, so animated JPEG XL
  plays through plain `Image` widgets with correct timing and loop count
  (it previously showed only the first frame).
- The whole `koni_jxl` API is re-exported, so one dependency suffices.
- Fixed web builds: every decode/encode helper used `Isolate.run`, which
  throws `UnsupportedError` under dart2js/dart2wasm, so the package did
  not actually work on the web. All heavy work now goes through Flutter's
  `compute` — still a background isolate (with transferred, not copied,
  result buffers) on native platforms, a plain call on the web, where the
  decode runs on the UI thread.

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
