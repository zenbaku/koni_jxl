import 'dart:typed_data';

import 'color/icc_transform.dart';
import 'color/transfer_function.dart';
import 'exceptions.dart';
import 'frame/frame.dart';
import 'frame/frame_flags.dart';
import 'frame/frame_header.dart';
import 'frame/splines.dart';
import 'header/extra_channel.dart';
import 'header/image_header.dart';
import 'icc/icc_codec.dart';
import 'io/bit_reader.dart';
import 'io/container.dart';
import 'jpeg/jpeg_reconstruct.dart';
import 'jxl_image.dart';
import 'jxl_limits.dart';
import 'render/blend.dart';
import 'render/dc_image.dart';
import 'render/noise.dart';
import 'render/transpose.dart';
import 'render/upsample.dart';
import 'util/image_buffer.dart';
import 'util/math_helper.dart';
import 'util/resample.dart';

/// Decodes JPEG XL images to raw pixels.
///
/// Handles lossless (Modular) and lossy (VarDCT) still images, animation,
/// splines, patches, reference frames and blending. Features that are not
/// yet implemented throw [JxlUnsupportedException] with the feature name;
/// malformed input throws another [JxlException] subtype.
final class JxlDecoder {
  const JxlDecoder._();

  /// Decodes [bytes] (bare codestream or ISOBMFF container).
  ///
  /// For animated inputs, decodes and returns the first visible frame.
  ///
  /// [targetWidth]/[targetHeight] request a reduced-resolution result — the
  /// output never exceeds that box (fit-within, aspect-preserving, never
  /// upscaled — the same contract as `ui.ResizeImage`). For a single-frame
  /// lossy (VarDCT) image with no patches, splines, noise or format-level
  /// upsampling, and a target no larger than the format's built-in 1:8-scale
  /// DC image, this decodes *only* the DC data — every AC coefficient is
  /// skipped, which is the bulk of decode time and memory for an oversized
  /// image — and box-filters that down to the exact target. Every other case
  /// (animated, Modular/lossless, patches/splines/noise present, or a target
  /// finer than 1:8 scale) decodes the image fully and then downsamples the
  /// result: always correct, just without the CPU/memory saving.
  static JxlImage decode(
    Uint8List bytes, {
    int? targetWidth,
    int? targetHeight,
  }) {
    if (targetWidth != null || targetHeight != null) {
      final dcOnly = _tryDcOnlyDecode(bytes, targetWidth, targetHeight);
      if (dcOnly != null) return dcOnly;
    }
    final full = _DecoderState()._decode(bytes, allFrames: false).frames.first;
    return _downsampleIfNeeded(full, targetWidth, targetHeight);
  }

  /// Decodes all visible frames of [bytes].
  ///
  /// Still images produce a single frame with duration 0.
  static JxlAnimation decodeAnimation(Uint8List bytes) =>
      _DecoderState()._decode(bytes, allFrames: true);

  /// Reconstructs the original JPEG file from a JPEG-transcoded JXL, byte for
  /// byte, using its `jbrd` box. Returns null when [bytes] carry no JPEG
  /// reconstruction data (not a transcode). Throws [JxlUnsupportedException]
  /// for transcode variants not yet supported.
  static Uint8List? reconstructJpeg(Uint8List bytes) {
    final demuxed = demuxContainer(bytes);
    if (demuxed.jbrd == null) return null;
    final state = _DecoderState()..captureJpeg = true;
    state._decode(bytes, allFrames: false);
    final frame = state.capturedFrame;
    if (frame == null) return null;
    return buildJpegFromCapture(frame, demuxed.jbrd!);
  }

  /// Attempts the DC-only fast path; returns null (never throws) whenever it
  /// doesn't apply, so the caller falls back to a normal full decode — that
  /// full decode is the sole source of truth for real decode errors.
  static JxlImage? _tryDcOnlyDecode(
    Uint8List bytes,
    int? targetWidth,
    int? targetHeight,
  ) {
    try {
      final demuxed = demuxContainer(bytes);
      final reader = BitReader(demuxed.codestream);
      final header = ImageHeader.read(reader, level: demuxed.level);
      if (header.animation != null || header.extraChannels.isNotEmpty) {
        return null;
      }

      Uint8List? iccProfile;
      if (header.iccEncodedSize != null) {
        final encoded =
            IccCodec.readEncodedStream(reader, header.iccEncodedSize!);
        reader.zeroPadToByte();
        iccProfile = IccCodec.decompress(encoded);
      }
      if (header.previewSize != null) {
        final preview = Frame(reader, header);
        preview.readFrameHeader();
        preview.readToc();
      }

      final dcImage = _dcImageFor(reader, header, iccProfile);
      if (dcImage == null) return null;

      // Only usable when the caller's real target is no finer than the DC
      // image itself — otherwise this would silently under-deliver detail
      // that only a full AC decode can provide.
      final orientedSize = header.orientedSize;
      final resolved = resolveTargetSize(
        orientedSize.width,
        orientedSize.height,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      if (resolved.width == orientedSize.width &&
          resolved.height == orientedSize.height) {
        return null; // no downscale actually requested
      }
      if (resolved.width > dcImage.width || resolved.height > dcImage.height) {
        return null; // finer than 1:8 — needs real AC data
      }
      return _downsampleIfNeeded(dcImage, targetWidth, targetHeight);
    } on JxlException {
      return null;
    } on RangeError {
      return null;
    }
  }

  /// Builds the 1:8 DC image for the DC-only fast path, or null when this file
  /// isn't a shape the fast path handles (caller then falls back to a full
  /// decode). Two shapes are handled, both cheap because JXL keeps DC (LF) and
  /// AC (HF) in separate bitstream sections:
  ///
  /// - a **plain single VarDCT frame**: decode only its LfGlobal + LF groups
  ///   ([Frame.decodeLfOnly]) and assemble the DC ([buildDcImage]);
  /// - a **progressive-DC** file, whose DC lives in a separate level-1 LF frame
  ///   ahead of the main frame: decode that (small) LF frame and assemble its
  ///   rows ([buildDcImageFromRows]), skipping the main frame's AC entirely.
  ///   The main frame must itself be a plain full-canvas last VarDCT frame, so
  ///   its 1:8 DC represents the final image (the same discipline as the plain
  ///   case, just spread across two frames).
  static JxlImage? _dcImageFor(
    BitReader reader,
    ImageHeader header,
    Uint8List? iccProfile,
  ) {
    final first = Frame(reader, header);
    final firstFh = first.readFrameHeader();
    if (firstFh.type == FrameFlags.lfFrame) {
      if (firstFh.lfLevel != 1 ||
          firstFh.encoding != FrameFlags.vardct ||
          firstFh.upsampling != 1) {
        return null; // multi-level or non-VarDCT DC frame: not handled
      }
      first.readToc(); // Toc.read skips the reader past this frame's data
      final main = Frame(reader, header);
      final mainFh = main.readFrameHeader();
      if (mainFh.type != FrameFlags.regularFrame ||
          mainFh.flags & FrameFlags.useLfFrame == 0 ||
          !_plainVardctFrame(mainFh, allowLfFrame: true)) {
        return null;
      }
      // The LF frame kept its own section bytes at readToc, so it decodes
      // independent of where the reader now sits (past the main header).
      first.decodeFrame();
      return buildDcImageFromRows(
        [for (var c = 0; c < 3; c++) first.buffer[c].floatRows],
        first.paddedFrameSize.height,
        first.paddedFrameSize.width,
        first.header.doYCbCr,
        header,
        iccProfile,
        isPreview: false,
      );
    }
    if (firstFh.encoding == FrameFlags.modular) {
      return _modularLowResImageFor(first, firstFh, header, iccProfile);
    }
    if (!_dcOnlyEligible(firstFh)) return null;
    first.readToc();
    first.decodeLfOnly();
    return buildDcImage(first, header, iccProfile, isPreview: false);
  }

  /// Builds a ~1:8 image for a **Squeeze (responsive) lossless modular** frame
  /// without decoding its large full-resolution residual channels. Modular has
  /// no DC concept, but a responsive frame stores a hierarchical low-frequency
  /// pyramid (the `vshift/hshift >= 3` Squeeze channels) in the global +
  /// LF-group sections, with the high-frequency detail in the pass groups.
  /// Decoding with [Frame.modularLowRes] zero-fills those pass-group channels,
  /// so the inverse Squeeze upsamples the low-frequency pyramid alone — a 1:8-
  /// accurate image (measured RMSE ~0.6 vs. a true box-downsample) for a
  /// fraction of the cost (measured ~3.7x faster on a 1024x1536 responsive
  /// file). Returns null (caller falls back to a full decode) for anything not
  /// safely handled: a non-plain frame, a non-Squeeze modular stream (its
  /// pass-group channels are the image, not residuals — zero-filling them is
  /// garbage), or colour that isn't plain integer (XYB/float/YCbCr).
  static JxlImage? _modularLowResImageFor(
    Frame first,
    FrameHeader fh,
    ImageHeader header,
    Uint8List? iccProfile,
  ) {
    if (!_plainModularFrame(fh)) return null;
    if (header.xybEncoded || header.bitDepth.usesFloatSamples || fh.doYCbCr) {
      return null; // plain integer colour only; full decode handles the rest
    }
    first.readToc();
    first.decodeFrame(modularLowRes: true);
    if (!first.lfGlobal.globalModular.usesSqueeze) return null;

    final colors = header.colorChannelCount;
    final visH = first.boundsHeight;
    final visW = first.boundsWidth;
    final dstH = ceilDiv(visH, 8);
    final dstW = ceilDiv(visW, 8);
    final channels = <ImageBuffer>[
      for (var c = 0; c < colors; c++)
        boxDownsample(_cropVisible(first.buffer[c], visH, visW), dstW, dstH),
    ];
    final oriented = [
      for (final ch in channels) transposeBuffer(ch, header.orientation),
    ];
    return JxlImage.scaled(
        header, oriented, iccProfile, oriented[0].width, oriented[0].height);
  }

  /// Copies the visible top-left [visH]x[visW] region out of a (possibly
  /// group-padded) frame buffer, so the box-downsample below never averages in
  /// padding pixels. A no-op (returns [src]) when there's no padding.
  static ImageBuffer _cropVisible(ImageBuffer src, int visH, int visW) {
    if (src.height == visH && src.width == visW) return src;
    final dst = src.isFloat
        ? ImageBuffer.float32(visH, visW)
        : ImageBuffer.int32(visH, visW);
    if (src.isFloat) {
      for (var y = 0; y < visH; y++) {
        dst.floatRows[y].setRange(0, visW, src.floatRows[y]);
      }
    } else {
      for (var y = 0; y < visH; y++) {
        dst.intRows[y].setRange(0, visW, src.intRows[y]);
      }
    }
    return dst;
  }

  /// Whether [fh] is a plain, last, full-canvas modular frame with none of the
  /// features (patches/splines/noise/a separate LF frame/format-level
  /// upsampling) the low-res Squeeze path doesn't account for.
  static bool _plainModularFrame(FrameHeader fh) {
    const bad = FrameFlags.noise |
        FrameFlags.patches |
        FrameFlags.splines |
        FrameFlags.useLfFrame;
    return fh.encoding == FrameFlags.modular &&
        fh.type == FrameFlags.regularFrame &&
        fh.isLast &&
        fh.fullFrame &&
        fh.upsampling == 1 &&
        fh.ecUpsampling.every((u) => u == 1) &&
        fh.flags & bad == 0;
  }

  /// Whether [fh] is a plain single-frame VarDCT frame with none of the
  /// features (patches/splines/noise/a separate LF frame/format-level
  /// upsampling) that the DC-only path doesn't account for.
  static bool _dcOnlyEligible(FrameHeader fh) =>
      fh.type == FrameFlags.regularFrame &&
      _plainVardctFrame(fh, allowLfFrame: false);

  /// The shared "plain VarDCT frame" predicate: last, full-canvas, no
  /// format-level upsampling, and none of the patches/splines/noise features
  /// the DC path can't represent. [allowLfFrame] keeps a progressive-DC main
  /// frame's `useLfFrame` flag from disqualifying it (that flag is expected
  /// there); the plain single-frame path forbids it.
  static bool _plainVardctFrame(FrameHeader fh, {required bool allowLfFrame}) {
    const base = FrameFlags.noise | FrameFlags.patches | FrameFlags.splines;
    final bad = allowLfFrame ? base : base | FrameFlags.useLfFrame;
    return fh.encoding == FrameFlags.vardct &&
        fh.isLast &&
        fh.fullFrame &&
        fh.upsampling == 1 &&
        fh.ecUpsampling.every((u) => u == 1) &&
        fh.flags & bad == 0;
  }

  /// Downsamples [image] to fit [targetWidth]/[targetHeight] if it doesn't
  /// already (a no-op, returning [image] itself, when it's already within
  /// that box — this never upscales).
  static JxlImage _downsampleIfNeeded(
    JxlImage image,
    int? targetWidth,
    int? targetHeight,
  ) {
    final target = resolveTargetSize(
      image.width,
      image.height,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    if (target.width == image.width && target.height == image.height) {
      return image;
    }
    final resized = [
      for (final channel in image.channels)
        boxDownsample(channel, target.width, target.height),
    ];
    return JxlImage.scaled(
        image.header, resized, image.iccProfile, target.width, target.height);
  }
}

final class _DecoderState {
  late ImageHeader imageHeader;
  final List<List<ImageBuffer?>?> _reference =
      List<List<ImageBuffer?>?>.filled(4, null);
  final List<List<ImageBuffer>?> _lfBuffer = List.filled(5, null);
  List<ImageBuffer?>? _canvas;
  int _visibleFrames = 0;
  int _invisibleFrames = 0;

  /// JPEG reconstruction: when set, the first regular frame captures quantized
  /// coefficients and is retained in [capturedFrame].
  bool captureJpeg = false;
  Frame? capturedFrame;

  JxlAnimation _decode(Uint8List bytes, {required bool allFrames}) {
    final demuxed = demuxContainer(bytes);
    final reader = BitReader(demuxed.codestream);
    imageHeader = ImageHeader.read(reader, level: demuxed.level);
    _checkImageSize(imageHeader);

    Uint8List? iccProfile;
    if (imageHeader.iccEncodedSize != null) {
      final encoded =
          IccCodec.readEncodedStream(reader, imageHeader.iccEncodedSize!);
      reader.zeroPadToByte();
      iccProfile = IccCodec.decompress(encoded);
    }

    if (imageHeader.previewSize != null) {
      // Skip the preview frame entirely (readToc advances past the data).
      final preview = Frame(reader, imageHeader);
      preview.readFrameHeader();
      preview.readToc();
    }

    var frameCount = 0;
    while (true) {
      if (++frameCount > JxlLimits.maxFrames) {
        throw const JxlInvalidBitstreamException('too many frames');
      }
      final frame = Frame(reader, imageHeader);
      final header = frame.readFrameHeader();
      frame.readToc();

      if (header.flags & FrameFlags.useLfFrame != 0 &&
          _lfBuffer[header.lfLevel] == null) {
        throw const JxlInvalidBitstreamException('LF level too large');
      }
      if (const bool.fromEnvironment('jxl.framedebug')) {
        // ignore: avoid_print
        print('frame: type=${header.type} dur=${header.duration} '
            'x0=${header.x0} y0=${header.y0} ${header.width}x${header.height} '
            'saveRef=${header.saveAsReference} beforeCT=${header.saveBeforeCT} '
            'blend=(mode=${header.blendingInfo.mode} '
            'src=${header.blendingInfo.source} '
            'alpha=${header.blendingInfo.alphaChannel}) isLast=${header.isLast}');
      }
      if (captureJpeg && capturedFrame == null) frame.captureJpeg = true;
      frame.decodeFrame(lfFrame: _lfBuffer[header.lfLevel]);
      if (captureJpeg && capturedFrame == null && frame.captureJpeg) {
        capturedFrame = frame;
      }
      if (header.lfLevel > 0) {
        _lfBuffer[header.lfLevel - 1] = frame.buffer;
      }
      if (header.type == FrameFlags.lfFrame) continue;

      final save = (header.saveAsReference != 0 || header.duration == 0) &&
          !header.isLast &&
          header.type != FrameFlags.lfFrame;
      if (frame.isVisible) {
        _visibleFrames++;
        _invisibleFrames = 0;
      } else {
        _invisibleFrames++;
      }
      upsampleFrame(frame);
      final noiseBuffer =
          initializeNoise(frame, _visibleFrames, _invisibleFrames);
      if (save && header.saveBeforeCT) {
        _reference[header.saveAsReference] = [
          for (final b in frame.buffer) ImageBuffer.copy(b),
        ];
      }
      _computePatches(frame);
      renderSplines(frame);
      synthesizeNoise(frame, noiseBuffer);
      _performColorTransforms(frame);

      if (header.type == FrameFlags.regularFrame ||
          header.type == FrameFlags.skipProgressive) {
        _canvas ??= List<ImageBuffer?>.filled(
            imageHeader.colorChannelCount + imageHeader.extraChannels.length,
            null);
        final canvas = _canvas!;
        if (canvas[0] == null) {
          for (var c = 0; c < canvas.length; c++) {
            canvas[c] = frame.buffer[0].isInt
                ? ImageBuffer.int32(
                    imageHeader.size.height, imageHeader.size.width)
                : ImageBuffer.float32(
                    imageHeader.size.height, imageHeader.size.width);
          }
        }
        // If a reference aliases the canvas (and won't be overwritten),
        // detach before blending mutates it.
        var aliased = false;
        for (var i = 0; i < 4; i++) {
          if (identical(_reference[i], _canvas) &&
              i != header.saveAsReference) {
            aliased = true;
            break;
          }
        }
        if (aliased) {
          _canvas = [
            for (final b in _canvas!) ImageBuffer.copy(b!),
          ];
        }
        _blendFrame(_canvas!, frame);
      }
      if (save && !header.saveBeforeCT) {
        _reference[header.saveAsReference] = _canvas;
      }

      if (allFrames && frame.isVisible) {
        // Snapshot the canvas: later frames keep blending onto it, so
        // finalize a copy (except for the last frame).
        frames.add(_finalizeCanvas(iccProfile, copy: !header.isLast));
        durations.add(header.duration);
        timecodes.add(header.timecode);
      }
      if (allFrames ? header.isLast : header.isLast || header.duration != 0) {
        break;
      }
    }

    if (!allFrames) {
      frames.add(_finalizeCanvas(iccProfile, copy: false));
      durations.add(0);
      timecodes.add(0);
    }
    final animation = imageHeader.animation;
    return JxlAnimation.internal(
      frames: frames,
      durations: durations,
      timecodes: timecodes,
      tpsNumerator: animation?.tpsNumerator ?? 1,
      tpsDenominator: animation?.tpsDenominator ?? 1,
      numLoops: animation?.numLoops ?? 0,
    );
  }

  static void _checkImageSize(ImageHeader header) {
    final w = header.size.width;
    final h = header.size.height;
    if (w <= 0 || h <= 0 || h > JxlLimits.maxPlanePixels ~/ w) {
      throw const JxlInvalidBitstreamException(
          'image size exceeds JxlLimits.maxPlanePixels');
    }
  }

  final List<JxlImage> frames = [];
  final List<int> durations = [];
  final List<int> timecodes = [];

  JxlImage _finalizeCanvas(Uint8List? iccProfile, {required bool copy}) {
    final canvas = _canvas;
    if (canvas == null || canvas[0] == null) {
      throw const JxlInvalidBitstreamException('no visible frame decoded');
    }
    final planes =
        copy ? [for (final b in canvas) ImageBuffer.copy(b!)] : canvas;
    // Modular (non-XYB) float-sample channels are still holding their raw
    // decoded integers at this point — the packed sign/exponent/mantissa
    // bits, not a value to scale (see [ImageBuffer.reconstructFloatSamples]).
    // Float samples and XYB encoding are mutually exclusive in the format,
    // so this never touches a channel the transfer-function step below
    // also needs. Not verified against blending/patches/splines combined
    // with float samples — only the plain single-frame case.
    final colors = imageHeader.colorChannelCount;
    for (var c = 0; c < colors; c++) {
      final bd = imageHeader.bitDepth;
      if (bd.usesFloatSamples) {
        planes[c]!.reconstructFloatSamples(bd.bitsPerSample, bd.expBits);
      }
    }
    for (var i = 0; i < imageHeader.extraChannels.length; i++) {
      final bd = imageHeader.extraChannels[i].bitDepth;
      if (bd.usesFloatSamples) {
        planes[colors + i]!
            .reconstructFloatSamples(bd.bitsPerSample, bd.expBits);
      }
    }
    // XYB frames come out of the color transform in linear RGB. Convert to the
    // output encoding: for a file whose colour is described by a matrix/TRC RGB
    // ICC profile, apply that profile (linear -> profile device values, the
    // representation the conformance reference uses); otherwise apply the
    // image's tagged transfer function. See color/icc_transform.dart.
    if (imageHeader.xybEncoded) {
      final icc = imageHeader.colorEncoding.useIccProfile &&
              iccProfile != null &&
              imageHeader.colorChannelCount >= 3
          ? IccRgbOutputTransform.tryParse(iccProfile)
          : null;
      if (icc != null) {
        icc.apply(
            planes[0]!.floatRows, planes[1]!.floatRows, planes[2]!.floatRows);
      } else {
        final tf = TransferFunction.forTransfer(imageHeader.colorEncoding.tf);
        for (var c = 0; c < imageHeader.colorChannelCount && c < 3; c++) {
          for (final row in planes[c]!.floatRows) {
            for (var i = 0; i < row.length; i++) {
              row[i] = tf.fromLinear(row[i]);
            }
          }
        }
      }
    }
    _compositeSpotColors(planes);
    final oriented = [
      for (final plane in planes)
        transposeBuffer(plane!, imageHeader.orientation),
    ];
    return JxlImage.internal(imageHeader, oriented, iccProfile);
  }

  /// Composites spot-colour extra channels onto the colour channels:
  /// `out = mix * spotRGB + (1 - mix) * out`, `mix = spotValue * solidity`, in
  /// extra-channel order (each spot channel's own `red`/`green`/`blue`/
  /// `solidity` from the header). Runs on the final output-encoded values
  /// (device 0..1) — verified against the `spot` conformance case, which is
  /// Modular so this is the signal/device domain the spot colours are defined
  /// in. (For an XYB image this therefore blends in the output-encoded domain,
  /// not linear light; no conformance case exercises XYB + spot colour.)
  /// Channels stored subsampled (`dimShift > 0`) are skipped — none of the
  /// conformance spot channels use it, and blending a size-mismatched plane
  /// would be worse than leaving it un-applied.
  void _compositeSpotColors(List<ImageBuffer?> planes) {
    final colors = imageHeader.colorChannelCount;
    if (colors < 3) return; // spot colour is defined against RGB
    for (var i = 0; i < imageHeader.extraChannels.length; i++) {
      final ec = imageHeader.extraChannels[i];
      if (ec.type != ExtraChannelType.spotColor) continue;
      final spot = planes[colors + i];
      final r = planes[0]!, g = planes[1]!, b = planes[2]!;
      if (spot == null || spot.width != r.width || spot.height != r.height) {
        continue;
      }
      final srgb = [ec.red, ec.green, ec.blue];
      final solidity = ec.solidity;
      final spotMax = ec.bitDepth.maxValue.toDouble();
      final colorMax = imageHeader.bitDepth.maxValue;
      final colorMaxF = colorMax.toDouble();
      final cp = [r, g, b];
      for (var y = 0; y < r.height; y++) {
        for (var x = 0; x < r.width; x++) {
          final sv =
              spot.isInt ? spot.intRows[y][x] / spotMax : spot.floatRows[y][x];
          final mix = sv * solidity;
          if (mix == 0) continue;
          for (var c = 0; c < 3; c++) {
            final plane = cp[c];
            if (plane.isInt) {
              final base = plane.intRows[y][x] / colorMaxF;
              final v = mix * srgb[c] + (1 - mix) * base;
              plane.intRows[y][x] =
                  (v * colorMaxF + 0.5).floor().clamp(0, colorMax);
            } else {
              final base = plane.floatRows[y][x];
              plane.floatRows[y][x] = mix * srgb[c] + (1 - mix) * base;
            }
          }
        }
      }
    }
  }

  /// Applies the XYB inverse (into linear RGB with the image's primaries)
  /// and/or the YCbCr transform in place on the frame's color channels.
  void _performColorTransforms(Frame frame) {
    if (!imageHeader.xybEncoded && !frame.header.doYCbCr) return;
    for (var c = 0; c < 3; c++) {
      frame.buffer[c].castToFloat(imageHeader.bitDepth.bitsPerSample);
    }
    final rows = [
      for (var c = 0; c < 3; c++) frame.buffer[c].floatRows,
    ];
    if (imageHeader.xybEncoded) {
      final bundle = imageHeader.colorEncoding;
      final matrix =
          imageHeader.opsinInverseMatrix.getMatrix(bundle.prim, bundle.white);
      matrix.invertXyb(frame.buffer[0].floatRows, frame.buffer[1].floatRows,
          frame.buffer[2].floatRows, imageHeader.toneMapping.intensityTarget);
    }
    if (frame.header.doYCbCr) {
      final height = frame.buffer[0].height;
      final width = frame.buffer[0].width;
      for (var y = 0; y < height; y++) {
        final cbRow = rows[0][y];
        final yRow = rows[1][y];
        final crRow = rows[2][y];
        for (var x = 0; x < width; x++) {
          final cb = cbRow[x];
          final yh = yRow[x] + 0.50196078431372549019;
          final cr = crRow[x];
          cbRow[x] = yh + 1.402 * cr;
          yRow[x] =
              yh - 0.34413628620102214650 * cb - 0.71413628620102214650 * cr;
          crRow[x] = yh + 1.772 * cb;
        }
      }
    }
  }

  void _computePatches(Frame frame) {
    final header = frame.header;
    final colorChannels = imageHeader.colorChannelCount;
    final extraChannels = imageHeader.extraChannels.length;
    for (final patch in frame.lfGlobal.patches) {
      if (patch.ref > 3) {
        throw const JxlInvalidBitstreamException('patch ref out of range');
      }
      final refBuffers = _reference[patch.ref];
      // Referencing a nonexistent frame is legal; the patch is a no-op.
      if (refBuffers == null) continue;
      final refBuffer0 = refBuffers[0]!;
      if (patch.y + patch.height > refBuffer0.height ||
          patch.x + patch.width > refBuffer0.width) {
        throw const JxlInvalidBitstreamException('patch too large');
      }
      for (var j = 0; j < patch.positionsX.length; j++) {
        final y0 = patch.positionsY[j];
        final x0 = patch.positionsX[j];
        if (y0 < 0 || x0 < 0) {
          throw const JxlInvalidBitstreamException('patch out of bounds');
        }
        if (patch.height + y0 > frame.boundsHeight ||
            patch.width + x0 > frame.boundsWidth) {
          throw const JxlInvalidBitstreamException('patch out of bounds');
        }
        for (var d = 0; d < colorChannels + extraChannels; d++) {
          final c = d < colorChannels ? 0 : d - colorChannels + 1;
          final info = patch.blendingInfos[j][c];
          if (info.mode == 0) continue;
          if (info.mode > 3 &&
              header.upsampling > 1 &&
              c > 0 &&
              header.ecUpsampling[c - 1] <<
                      imageHeader.extraChannels[c - 1].dimShift !=
                  header.upsampling) {
            throw const JxlInvalidBitstreamException(
                'alpha upsampling mismatch in patch');
          }
          blendBuffers(
            imageHeader: imageHeader,
            canvas: frame.buffer[d],
            frameBuffers: frame.buffer,
            refBuffers: refBuffers,
            patchY: y0,
            patchX: x0,
            frameY: y0,
            frameX: x0,
            refY: patch.y,
            refX: patch.x,
            blendHeight: patch.height,
            blendWidth: patch.width,
            idx: d,
            srcFrame: frame,
            info: info,
            isPatch: true,
          );
        }
      }
    }
  }

  void _blendFrame(List<ImageBuffer?> canvas, Frame frame) {
    final width = imageHeader.size.width;
    final height = imageHeader.size.height;
    final header = frame.header;
    final patchStartY = header.y0.clamp(0, height);
    final patchStartX = header.x0.clamp(0, width);
    final frameOffsetY = patchStartY - header.y0;
    final frameOffsetX = patchStartX - header.x0;
    final lowerY = header.y0 + frame.boundsHeight;
    final lowerX = header.x0 + frame.boundsWidth;
    final blendHeight = (lowerY < height ? lowerY : height) - patchStartY;
    final blendWidth = (lowerX < width ? lowerX : width) - patchStartX;
    final colors = imageHeader.colorChannelCount;
    final fullCover = patchStartY == 0 &&
        patchStartX == 0 &&
        blendHeight == height &&
        blendWidth == width;
    for (var c = 0; c < canvas.length; c++) {
      final info =
          c >= colors ? header.ecBlendingInfo[c - colors] : header.blendingInfo;
      // The canvas outside the frame's crop is defined by the blending
      // source reference (zeros when that slot is empty), not by whatever
      // the canvas held before. When the reference aliases the canvas the
      // copy is a no-op.
      if (!fullCover && !identical(_reference[info.source], canvas)) {
        _fillFromReference(canvas[c]!, _reference[info.source]?[c]);
      }
      blendBuffers(
        imageHeader: imageHeader,
        canvas: canvas[c]!,
        frameBuffers: frame.buffer,
        refBuffers: _reference[info.source],
        patchY: patchStartY,
        patchX: patchStartX,
        frameY: frameOffsetY,
        frameX: frameOffsetX,
        refY: patchStartY,
        refX: patchStartX,
        blendHeight: blendHeight,
        blendWidth: blendWidth,
        idx: c,
        srcFrame: frame,
        info: info,
        isPatch: false,
      );
    }
  }

  void _fillFromReference(ImageBuffer dst, ImageBuffer? src) {
    if (src == null) {
      if (dst.isInt) {
        for (final row in dst.intRows) {
          row.fillRange(0, row.length, 0);
        }
      } else {
        for (final row in dst.floatRows) {
          row.fillRange(0, row.length, 0);
        }
      }
      return;
    }
    if (dst.isInt != src.isInt) {
      final bits = imageHeader.bitDepth.bitsPerSample;
      dst.castToFloat(bits);
      src.castToFloat(bits);
    }
    final h = dst.height < src.height ? dst.height : src.height;
    final w = dst.width < src.width ? dst.width : src.width;
    if (dst.isInt) {
      for (var y = 0; y < h; y++) {
        dst.intRows[y].setRange(0, w, src.intRows[y]);
      }
    } else {
      for (var y = 0; y < h; y++) {
        dst.floatRows[y].setRange(0, w, src.floatRows[y]);
      }
    }
  }
}
