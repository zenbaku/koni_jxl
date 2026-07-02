# Changelog

## 0.1.0-dev

- `decodeJxlAnimation` and the `JxlAnimationView` playback widget.
- `encodeJxlFromRgba` / `encodeJxlFromUiImage`: lossless JXL encoding in
  a background isolate.
- `decodeJxlProgressive` and the `JxlProgressiveImage` widget: blurry
  1:8 preview while bytes stream in, then the final image.
- Initial release: `JxlImageProvider` (asset/file/memory) and
  `decodeJxlToUiImage`, with decoding in a background isolate.
