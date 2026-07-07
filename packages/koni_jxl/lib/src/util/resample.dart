/// Downscale-decode support: resolving a caller's requested target size
/// against an image's native size, and box-filtering pixel planes down to
/// it. Shared by [JxlDecoder.decode]'s reduced-resolution fast path and its
/// full-decode-then-downsample fallback.
library;

import 'image_buffer.dart';

/// Resolves a "fit within this box, never upscale" target size, mirroring
/// `ui.ResizeImage`'s contract: at most one of [targetWidth]/[targetHeight]
/// may be null (fit the other dimension, preserving aspect ratio); when both
/// are given the image is scaled to fit inside that box; a box at least as
/// large as [nativeWidth]x[nativeHeight] resolves to the native size
/// unchanged (never upscaled).
({int width, int height}) resolveTargetSize(
  int nativeWidth,
  int nativeHeight, {
  int? targetWidth,
  int? targetHeight,
}) {
  if (targetWidth == null && targetHeight == null) {
    return (width: nativeWidth, height: nativeHeight);
  }
  var scale = 1.0;
  if (targetWidth != null) {
    final s = targetWidth / nativeWidth;
    if (s < scale) scale = s;
  }
  if (targetHeight != null) {
    final s = targetHeight / nativeHeight;
    if (s < scale) scale = s;
  }
  if (scale >= 1.0) return (width: nativeWidth, height: nativeHeight);
  final width = (nativeWidth * scale).round().clamp(1, nativeWidth);
  final height = (nativeHeight * scale).round().clamp(1, nativeHeight);
  return (width: width, height: height);
}

/// Box-downsamples [src] to exactly [dstWidth]x[dstHeight] (must be no
/// larger than [src] in either dimension — this never upscales). Every
/// source pixel is visited exactly once, in a single pass, regardless of the
/// output size. Preserves [src]'s int/float sample kind.
ImageBuffer boxDownsample(ImageBuffer src, int dstWidth, int dstHeight) {
  final srcWidth = src.width;
  final srcHeight = src.height;
  if (srcWidth == dstWidth && srcHeight == dstHeight) return src;
  assert(dstWidth <= srcWidth && dstHeight <= srcHeight);

  final colStart = List<int>.filled(dstWidth, 0);
  final colEnd = List<int>.filled(dstWidth, 0);
  for (var x = 0; x < dstWidth; x++) {
    final start = (x * srcWidth) ~/ dstWidth;
    var end = ((x + 1) * srcWidth + dstWidth - 1) ~/ dstWidth;
    if (end > srcWidth) end = srcWidth;
    if (end <= start) end = start + 1;
    colStart[x] = start;
    colEnd[x] = end;
  }

  final isInt = src.isInt;
  final dst = isInt
      ? ImageBuffer.int32(dstHeight, dstWidth)
      : ImageBuffer.float32(dstHeight, dstWidth);

  for (var y = 0; y < dstHeight; y++) {
    final rowStart = (y * srcHeight) ~/ dstHeight;
    var rowEnd = ((y + 1) * srcHeight + dstHeight - 1) ~/ dstHeight;
    if (rowEnd > srcHeight) rowEnd = srcHeight;
    if (rowEnd <= rowStart) rowEnd = rowStart + 1;

    if (isInt) {
      final dstRow = dst.intRows[y];
      for (var x = 0; x < dstWidth; x++) {
        var sum = 0;
        var count = 0;
        for (var sy = rowStart; sy < rowEnd; sy++) {
          final srcRow = src.intRows[sy];
          for (var sx = colStart[x]; sx < colEnd[x]; sx++) {
            sum += srcRow[sx];
            count++;
          }
        }
        dstRow[x] = count == 0 ? 0 : (sum / count).round();
      }
    } else {
      final dstRow = dst.floatRows[y];
      for (var x = 0; x < dstWidth; x++) {
        var sum = 0.0;
        var count = 0;
        for (var sy = rowStart; sy < rowEnd; sy++) {
          final srcRow = src.floatRows[sy];
          for (var sx = colStart[x]; sx < colEnd[x]; sx++) {
            sum += srcRow[sx];
            count++;
          }
        }
        dstRow[x] = count == 0 ? 0 : sum / count;
      }
    }
  }
  return dst;
}
