import '../exceptions.dart';
import '../frame/blending_info.dart';
import '../frame/frame.dart';
import '../frame/frame_flags.dart';
import '../header/image_header.dart';
import '../util/image_buffer.dart';

/// Frame and patch blending onto a canvas (port of jxlatte's
/// JXLCodestreamDecoder blend machinery).
///
/// Throughout, "new" is the incoming frame content and "old" is the existing
/// reference content; parameter names follow jxlatte's (frame*/ref*) offsets.

double _clamp01(double v) => v < 0
    ? 0
    : v > 1
        ? 1
        : v;

void _copyToCanvas(ImageBuffer canvas, int patchY, int patchX, int frameY,
    int frameX, int height, int width, ImageBuffer frame) {
  if (canvas.isInt) {
    final c = canvas.intRows;
    final f = frame.intRows;
    for (var y = 0; y < height; y++) {
      c[y + patchY].setRange(patchX, patchX + width, f[y + frameY], frameX);
    }
  } else {
    final c = canvas.floatRows;
    final f = frame.floatRows;
    for (var y = 0; y < height; y++) {
      c[y + patchY].setRange(patchX, patchX + width, f[y + frameY], frameX);
    }
  }
}

void _blendAdd(
    ImageBuffer canvas,
    ImageBuffer frame,
    ImageBuffer ref,
    int patchY,
    int patchX,
    int frameY,
    int frameX,
    int refY,
    int refX,
    int height,
    int width) {
  if (frame.isInt) {
    final cb = canvas.intRows;
    final fb = frame.intRows;
    final rb = ref.intRows;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        cb[y + patchY][x + patchX] =
            rb[y + refY][x + refX] + fb[y + frameY][x + frameX];
      }
    }
  } else {
    final cb = canvas.floatRows;
    final fb = frame.floatRows;
    final rb = ref.floatRows;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        cb[y + patchY][x + patchX] =
            rb[y + refY][x + refX] + fb[y + frameY][x + frameX];
      }
    }
  }
}

void _blendMult(
    ImageBuffer canvas,
    ImageBuffer frame,
    ImageBuffer ref,
    int patchY,
    int patchX,
    int frameY,
    int frameX,
    int refY,
    int refX,
    int height,
    int width,
    bool clamp) {
  final cb = canvas.floatRows;
  final fb = frame.floatRows;
  final rb = ref.floatRows;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var newSample = fb[y + frameY][x + frameX];
      if (clamp) newSample = _clamp01(newSample);
      cb[y + patchY][x + patchX] = newSample * rb[y + refY][x + refX];
    }
  }
}

void _blendBlend(
    ImageBuffer canvas,
    ImageBuffer frame,
    ImageBuffer ref,
    ImageBuffer? frameAlpha,
    ImageBuffer? refAlpha,
    int patchY,
    int patchX,
    int frameY,
    int frameX,
    int refY,
    int refX,
    int height,
    int width,
    bool isAlpha,
    bool hasExtra,
    bool clamp,
    bool premult) {
  if (!hasExtra) {
    _blendAdd(canvas, frame, ref, patchY, patchX, frameY, frameX, refY, refX,
        height, width);
    return;
  }
  final oaf = isAlpha ? null : refAlpha!.floatRows;
  final naf = isAlpha ? null : frameAlpha!.floatRows;
  final rf = ref.floatRows;
  final ff = frame.floatRows;
  final cf = canvas.floatRows;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final fy2 = y + frameY;
      final fx2 = x + frameX;
      final ry2 = y + refY;
      final rx2 = x + refX;
      final oldSample = rf[ry2][rx2];
      final newSample = ff[fy2][fx2];
      final oldAlpha = isAlpha ? oldSample : oaf![ry2][rx2];
      var newAlpha = isAlpha ? newSample : naf![fy2][fx2];
      if (clamp) newAlpha = _clamp01(newAlpha);
      final double result;
      if (isAlpha) {
        result = oldAlpha + newAlpha * (1 - oldAlpha);
      } else if (premult) {
        result = newSample + oldSample * (1 - newAlpha);
      } else {
        result =
            (newSample * newAlpha + oldSample * oldAlpha * (1 - newAlpha)) /
                (oldAlpha + newAlpha * (1 - oldAlpha));
      }
      cf[y + patchY][x + patchX] = result;
    }
  }
}

void _blendMulAdd(
    ImageBuffer canvas,
    ImageBuffer frame,
    ImageBuffer ref,
    ImageBuffer? frameAlpha,
    int patchY,
    int patchX,
    int frameY,
    int frameX,
    int refY,
    int refX,
    int height,
    int width,
    bool isAlpha,
    bool hasExtra,
    bool clamp) {
  if (!hasExtra) {
    _blendAdd(canvas, frame, ref, patchY, patchX, frameY, frameX, refY, refX,
        height, width);
    return;
  }
  if (isAlpha) {
    // The alpha channel itself keeps the old values.
    _copyToCanvas(canvas, patchY, patchX, frameY, frameX, height, width, ref);
    return;
  }
  final naf = frameAlpha!.floatRows;
  final rf = ref.floatRows;
  final ff = frame.floatRows;
  final cf = canvas.floatRows;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var newAlpha = naf[y + frameY][x + frameX];
      if (clamp) newAlpha = _clamp01(newAlpha);
      cf[y + patchY][x + patchX] =
          rf[y + refY][x + refX] + newAlpha * ff[y + frameY][x + frameX];
    }
  }
}

/// Blends channel [idx] of [srcFrame] onto [canvas]. For patches
/// ([isPatch]), [info.mode] uses the patch mode numbering.
void blendBuffers({
  required ImageHeader imageHeader,
  required ImageBuffer canvas,
  required List<ImageBuffer> frameBuffers,
  required List<ImageBuffer?>? refBuffers,
  required int patchY,
  required int patchX,
  required int frameY,
  required int frameX,
  required int refY,
  required int refX,
  required int blendHeight,
  required int blendWidth,
  required int idx,
  required Frame srcFrame,
  required BlendingInfo info,
  required bool isPatch,
}) {
  if (blendHeight <= 0 || blendWidth <= 0) return;
  final colors = imageHeader.colorChannelCount;
  final frameColors = srcFrame.colorChannelCount;
  // A grayscale canvas over a 3-channel (XYB) frame reads green (index 1).
  final frameBuffer =
      frameBuffers[colors != frameColors ? (idx == 0 ? 1 : idx + 2) : idx];
  final exIdx = idx - colors;
  final isExtra = exIdx >= 0;
  final hasExtra = imageHeader.extraChannels.isNotEmpty;
  final extraInfo = isExtra ? imageHeader.extraChannels[exIdx] : null;
  final isAlpha = isExtra && extraInfo!.type == 0;
  final alphaInfo =
      hasExtra ? imageHeader.extraChannels[info.alphaChannel] : null;
  final bitDepth = isExtra ? extraInfo!.bitDepth : imageHeader.bitDepth;
  final premult = hasExtra && alphaInfo!.alphaAssociated;

  if (canvas.isInt != frameBuffer.isInt) {
    frameBuffer.castToFloat(bitDepth.bitsPerSample);
    canvas.castToFloat(bitDepth.bitsPerSample);
  }

  var mode = info.mode;
  var below = false;
  if (isPatch) {
    // Patch modes: 0 none, 1 replace, 2 add, 3 mul, 4 blend above,
    // 5 blend below, 6 muladd above, 7 muladd below.
    switch (info.mode) {
      case 0:
        return;
      case 1:
        mode = FrameFlags.blendReplace;
      case 2:
        mode = FrameFlags.blendAdd;
      case 3:
        mode = FrameFlags.blendMult;
      case 4:
        mode = FrameFlags.blendBlend;
      case 5:
        mode = FrameFlags.blendBlend;
        below = true;
      case 6:
        mode = FrameFlags.blendMulAdd;
      case 7:
        mode = FrameFlags.blendMulAdd;
        below = true;
    }
  }

  if (mode == FrameFlags.blendReplace ||
      refBuffers == null && mode == FrameFlags.blendAdd) {
    _copyToCanvas(canvas, patchY, patchX, frameY, frameX, blendHeight,
        blendWidth, frameBuffer);
    return;
  }
  refBuffers![idx] ??= canvas.isInt
      ? ImageBuffer.int32(canvas.height, canvas.width)
      : ImageBuffer.float32(canvas.height, canvas.width);
  final refBuffer = refBuffers[idx]!;
  ImageBuffer? refAlpha =
      hasExtra ? refBuffers[colors + info.alphaChannel] : null;
  ImageBuffer? frameAlpha =
      hasExtra ? frameBuffers[frameColors + info.alphaChannel] : null;
  if (hasExtra &&
      (mode == FrameFlags.blendBlend || mode == FrameFlags.blendMulAdd)) {
    final alphaDepth = alphaInfo!.bitDepth.bitsPerSample;
    if (mode == FrameFlags.blendBlend) {
      if (refAlpha == null) {
        refAlpha = ImageBuffer.float32(canvas.height, canvas.width);
        refBuffers[colors + info.alphaChannel] = refAlpha;
      }
      refBuffers[colors + info.alphaChannel]!.castToFloat(alphaDepth);
      refAlpha = refBuffers[colors + info.alphaChannel];
    }
    frameBuffers[frameColors + info.alphaChannel].castToFloat(alphaDepth);
    frameAlpha = frameBuffers[frameColors + info.alphaChannel];
  }
  final shouldCast = mode == FrameFlags.blendMult ||
      mode == FrameFlags.blendBlend && hasExtra ||
      mode == FrameFlags.blendMulAdd && hasExtra && !isAlpha;
  if (shouldCast || refBuffer.isInt != frameBuffer.isInt) {
    frameBuffer.castToFloat(bitDepth.bitsPerSample);
    canvas.castToFloat(bitDepth.bitsPerSample);
    refBuffer.castToFloat(bitDepth.bitsPerSample);
  }

  // "below" swaps the roles of the incoming frame and the reference.
  var newBuffer = frameBuffer;
  var oldBuffer = refBuffer;
  if (below) {
    newBuffer = refBuffer;
    oldBuffer = frameBuffer;
  }
  // The _blend* helpers index their `frame` parameter (the new content)
  // with the frame offsets and `ref` (the old content) with ref offsets;
  // when swapped the offsets swap roles with them, matching jxlatte.
  switch (mode) {
    case FrameFlags.blendAdd:
      _blendAdd(canvas, newBuffer, oldBuffer, patchY, patchX, frameY, frameX,
          refY, refX, blendHeight, blendWidth);
    case FrameFlags.blendMult:
      _blendMult(canvas, newBuffer, oldBuffer, patchY, patchX, frameY, frameX,
          refY, refX, blendHeight, blendWidth, info.clamp);
    case FrameFlags.blendBlend:
      _blendBlend(
          canvas,
          newBuffer,
          oldBuffer,
          frameAlpha,
          refAlpha,
          patchY,
          patchX,
          frameY,
          frameX,
          refY,
          refX,
          blendHeight,
          blendWidth,
          isAlpha,
          hasExtra,
          info.clamp,
          premult);
    case FrameFlags.blendMulAdd:
      _blendMulAdd(
          canvas,
          newBuffer,
          oldBuffer,
          frameAlpha,
          patchY,
          patchX,
          frameY,
          frameX,
          refY,
          refX,
          blendHeight,
          blendWidth,
          isAlpha,
          hasExtra,
          info.clamp);
    default:
      throw const JxlInvalidBitstreamException('illegal blend mode');
  }
}
