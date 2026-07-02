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

Decoding runs in a background isolate (`Isolate.run`) so the UI thread
never blocks; decoded images participate in Flutter's `ImageCache`
normally.

## What's included

- **`JxlImageProvider`** (`.asset` / `.file` / `.memory`) and
  `decodeJxlToUiImage` — decode a still image.
- **`JxlAnimationView`** and `decodeJxlAnimation` — play animated JPEG XL
  with correct per-frame timing and loop count.
- **`JxlProgressiveImage`** and `decodeJxlProgressive` — show a blurry
  1:8 preview while bytes stream in (e.g. from the network), then swap in
  the sharp final image.
- **`encodeJxlFromRgba` / `encodeJxlFromUiImage`** — lossless JPEG XL
  encoding in a background isolate.

Full lossless (bit-exact) and lossy (VarDCT) decoding, animation,
splines and streaming come from the underlying
[`koni_jxl`](https://pub.dev/packages/koni_jxl) package. Unsupported
files throw `JxlUnsupportedException` with a stable feature id, so you
can fall back to another pipeline per file.

See the `example/` app for a small gallery.

## License

MIT — see `LICENSE` and `NOTICE`.
