# koni_jxl_flutter

Display JPEG XL (`.jxl`) images in Flutter with a **pure Dart** decoder —
no native libraries, no FFI, no platform channels. Works on Android, iOS,
macOS, Windows and Linux out of the box.

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

Currently decodes modular (lossless) `.jxl` — the format produced by
`cjxl -d 0` and most PNG→JXL conversions (manga/comic archives, line art,
screenshots). Lossy (VarDCT) support is in progress; unsupported files
throw `JxlUnsupportedException` with a stable feature id so you can fall
back to another pipeline per-file.

See the `example/` app for a small gallery.
