import 'dart:typed_data';

import 'color/transfer_function.dart';
import 'exceptions.dart';
import 'frame/frame.dart';
import 'frame/frame_flags.dart';
import 'header/image_header.dart';
import 'icc/icc_codec.dart';
import 'io/bit_reader.dart';
import 'io/container.dart';
import 'jxl_image.dart';
import 'render/blend.dart';
import 'render/transpose.dart';
import 'util/image_buffer.dart';

/// Decodes JPEG XL images to raw pixels.
///
/// Currently supported: still images with modular (lossless) encoding,
/// including patches, reference frames and blending. Unsupported features
/// throw [JxlUnsupportedException] naming the feature.
final class JxlDecoder {
  /// Decodes [bytes] (bare codestream or ISOBMFF container).
  ///
  /// For animated inputs, decodes and returns the first visible frame.
  static JxlImage decode(Uint8List bytes) => _DecoderState()._decode(bytes);
}

final class _DecoderState {
  late ImageHeader imageHeader;
  final List<List<ImageBuffer?>?> _reference =
      List<List<ImageBuffer?>?>.filled(4, null);
  List<ImageBuffer?>? _canvas;

  JxlImage _decode(Uint8List bytes) {
    final demuxed = demuxContainer(bytes);
    final reader = BitReader(demuxed.codestream);
    imageHeader = ImageHeader.read(reader, level: demuxed.level);

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

    while (true) {
      final frame = Frame(reader, imageHeader);
      final header = frame.readFrameHeader();
      frame.readToc();

      if (header.lfLevel > 0 || header.flags & FrameFlags.useLfFrame != 0) {
        throw JxlUnsupportedException('lf-frames');
      }
      frame.decodeFrame();

      final save = (header.saveAsReference != 0 || header.duration == 0) &&
          !header.isLast &&
          header.type != FrameFlags.lfFrame;
      if (save && header.saveBeforeCT) {
        _reference[header.saveAsReference] = [
          for (final b in frame.buffer) ImageBuffer.copy(b),
        ];
      }
      _computePatches(frame);
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

      if (header.isLast || header.duration != 0) break;
    }

    final canvas = _canvas;
    if (canvas == null || canvas[0] == null) {
      throw const JxlInvalidBitstreamException('no visible frame decoded');
    }
    // XYB frames come out of the color transform in linear RGB; convert to
    // the image's tagged transfer function (what djxl outputs).
    if (imageHeader.xybEncoded) {
      final tf = TransferFunction.forTransfer(imageHeader.colorEncoding.tf);
      for (var c = 0; c < imageHeader.colorChannelCount && c < 3; c++) {
        final buf = canvas[c]!.floatBuffer;
        for (var i = 0; i < buf.length; i++) {
          buf[i] = tf.fromLinear(buf[i]);
        }
      }
    }
    final oriented = [
      for (final plane in canvas)
        transposeBuffer(plane!, imageHeader.orientation),
    ];
    return JxlImage.internal(imageHeader, oriented, iccProfile);
  }

  /// Applies the XYB inverse (into linear RGB with the image's primaries)
  /// in place on the frame's color channels.
  void _performColorTransforms(Frame frame) {
    if (!imageHeader.xybEncoded) return;
    final bundle = imageHeader.colorEncoding;
    final matrix =
        imageHeader.opsinInverseMatrix.getMatrix(bundle.prim, bundle.white);
    final rows = [
      for (var c = 0; c < 3; c++) frame.buffer[c].floatRows(),
    ];
    matrix.invertXyb(rows, imageHeader.toneMapping.intensityTarget);
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
    for (var c = 0; c < canvas.length; c++) {
      final info =
          c >= colors ? header.ecBlendingInfo[c - colors] : header.blendingInfo;
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
}
