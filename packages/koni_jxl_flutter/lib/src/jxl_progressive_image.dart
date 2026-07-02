import 'dart:ui' as ui_image;

import 'package:flutter/widgets.dart';

import 'jxl_codec.dart';

/// Displays a JPEG XL image from a byte stream, showing the 1:8 DC
/// preview while the rest of the data arrives (VarDCT images), then
/// swapping in the final image.
///
/// ```dart
/// JxlProgressiveImage(
///   response.stream,             // e.g. an http byte stream
///   fit: BoxFit.contain,
/// )
/// ```
class JxlProgressiveImage extends StatefulWidget {
  const JxlProgressiveImage(this.byteStream,
      {super.key,
      this.fit = BoxFit.contain,
      this.filterQuality = FilterQuality.low,
      this.placeholder});

  /// Single-subscription stream of file bytes, in order.
  final Stream<List<int>> byteStream;
  final BoxFit fit;

  /// Sampling quality; [FilterQuality.low] gives the classic smooth blur
  /// for the upscaled preview.
  final FilterQuality filterQuality;

  /// Shown until the first (preview or final) image is available.
  final Widget? placeholder;

  @override
  State<JxlProgressiveImage> createState() => _JxlProgressiveImageState();
}

class _JxlProgressiveImageState extends State<JxlProgressiveImage> {
  ui_image.Image? _current;
  Object? _error;

  @override
  void initState() {
    super.initState();
    decodeJxlProgressive(widget.byteStream).listen((image) {
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _current?.dispose();
        _current = image;
      });
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  void dispose() {
    _current?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ErrorWidget(_error!);
    }
    final image = _current;
    if (image == null) {
      return widget.placeholder ?? const SizedBox.expand();
    }
    return FittedBox(
      fit: widget.fit,
      child: SizedBox(
        // Previews are 1:8; lay out at intended display size so the
        // preview-to-final swap does not change geometry.
        width: image.width.toDouble(),
        height: image.height.toDouble(),
        child: RawImage(
          image: image,
          fit: BoxFit.fill,
          filterQuality: widget.filterQuality,
        ),
      ),
    );
  }
}
