# koni_jxl_flutter

Display and encode JPEG XL (`.jxl`) images in Flutter with a **pure Dart**
codec — no native libraries, no FFI, no platform channels. Works on
Android, iOS, macOS, Windows and Linux out of the box (and on the web,
with reduced lossy-decode speed).

```dart
import 'package:koni_jxl_flutter/koni_jxl_flutter.dart';

// Like any other ImageProvider:
Image(image: JxlImageProvider.asset('assets/page.jxl'))
Image(image: JxlImageProvider.file(File('/comics/page-042.jxl')))
Image(image: JxlImageProvider.memory(jxlBytes))

// Or decode to a ui.Image directly:
final ui.Image image = await decodeJxlToUiImage(bytes);
```

Decoding runs through Flutter's `compute` — a background isolate on
native platforms, so the UI thread never blocks; on the web, which has
no isolates, the decode runs on the UI thread. Decoded images
participate in Flutter's `ImageCache` normally.

## What's included

- **`JxlImageProvider`** (`.asset` / `.file` / `.memory`) and
  `decodeJxlToUiImage` — decode an image; animated files play through
  plain `Image` widgets with correct timing and loop count.
- **`jxlAwareDecode` and `decodeJxlToUiCodec`** — for apps with custom
  `ImageProvider`s over mixed formats (readers, caches, archives): sniff
  JPEG XL by content and decode it to a `ui.Codec` for the standard
  `MultiFrameImageStreamCompleter` machinery, handing everything else to
  the engine callback unchanged:

  ```dart
  Future<ui.Codec> _loadCodec(ImageDecoderCallback decode) async {
    final bytes = await _readBytes();
    return jxlAwareDecode(bytes, decode);
  }
  ```
- **`JxlAnimationView`** and `decodeJxlAnimation` — play animated JPEG XL
  with correct per-frame timing and loop count.
- **`JxlProgressiveImage`** and `decodeJxlProgressive` — show a blurry
  1:8 preview while bytes stream in (e.g. from the network), then swap in
  the sharp final image.
- **`encodeJxlFromRgba` / `encodeJxlFromUiImage`** — lossless JPEG XL
  encoding in a background isolate.
- **`encodeJxlLossyFromRgba` / `encodeJxlLossyFromUiImage`** — lossy
  (VarDCT) encoding in a background isolate (RGB-only; alpha is dropped).
- **`JxlPagePrefetcher`** — decodes upcoming pages of a sequential reader
  (manga chapters, documents) on background isolates ahead of display,
  keeping a window of pages decoded around the current one and
  cancelling/evicting as the reader navigates:

  ```dart
  final prefetcher = JxlPagePrefetcher.fromFiles(pageFiles);
  prefetcher.setCurrentIndex(currentPage);
  final ui.Image page = await prefetcher.imageFor(currentPage);
  ```

Full lossless (bit-exact) and lossy (VarDCT) decoding, animation,
splines and streaming come from the underlying
[`koni_jxl`](https://pub.dev/packages/koni_jxl) package, which also has
the details on lossy encoding's current trade-offs (correct and
djxl-verified, but not yet compression-competitive with cjxl).
Unsupported files throw `JxlUnsupportedException` with a stable feature
id, so you can fall back to another pipeline per file.

See the `example/` app for a small gallery.

## License

MIT — see `LICENSE` and `NOTICE`.
