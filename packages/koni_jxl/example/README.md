# koni_jxl example

`main.dart` inspects a `.jxl` file's header, decodes it to
RGBA, and losslessly re-encodes those pixels back to JPEG XL:

```bash
dart run example/main.dart input.jxl
```

For Flutter widgets (`JxlImageProvider`, `JxlAnimationView`,
`JxlProgressiveImage`), see the `koni_jxl_flutter` package.
