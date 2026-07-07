import 'dart:typed_data';

import '../color/transfer_function.dart';
import '../exceptions.dart';
import '../frame/frame.dart';
import '../header/image_header.dart';
import '../jxl_image.dart';
import '../util/image_buffer.dart';
import '../util/math_helper.dart';
import 'transpose.dart';

/// Assembles a VarDCT frame's decoded DC ("LF") coefficients — from
/// [Frame.decodeLfOnly] — into a [JxlImage] at the format's fixed 1:8 scale.
///
/// Shared by [JxlStreamingDecoder]'s progressive preview ([isPreview] true,
/// the default) and [JxlDecoder.decode]'s reduced-resolution fast path
/// ([isPreview] false — the result is the caller's actual requested output,
/// not a placeholder to be replaced later).
JxlImage buildDcImage(
  Frame frame,
  ImageHeader header,
  Uint8List? iccProfile, {
  bool isPreview = true,
}) {
  final padded = frame.paddedFrameSize;
  final lfHeight = padded.height >> 3;
  final lfWidth = padded.width >> 3;

  // Assemble the per-LF-group dequantized DC into full planes (at each
  // channel's subsampled resolution), then bring chroma up to luma
  // resolution by duplication.
  final planes = <List<Float32List>>[];
  for (var c = 0; c < 3; c++) {
    final sy = frame.header.jpegUpsamplingY[c];
    final sx = frame.header.jpegUpsamplingX[c];
    final rows = floatMatrix(lfHeight >> sy, lfWidth >> sx);
    for (var g = 0; g < frame.numLfGroups; g++) {
      final lfg = frame.lfGroups[g];
      if (lfg == null || lfg.lfCoeff == null) {
        throw const JxlInvalidBitstreamException(
            'incomplete DC sections for preview');
      }
      final src = lfg.lfCoeff!.dequantLFCoeffAt(c);
      final pos = frame.getLFGroupLocation(g);
      final oy = (pos.y << 8) >> sy;
      final ox = (pos.x << 8) >> sx;
      for (var y = 0; y < src.length; y++) {
        rows[oy + y].setRange(ox, ox + src[y].length, src[y]);
      }
    }
    if (sy != 0 || sx != 0) {
      final full = floatMatrix(lfHeight, lfWidth);
      for (var y = 0; y < lfHeight; y++) {
        final srcRow = rows[y >> sy];
        final dst = full[y];
        for (var x = 0; x < lfWidth; x++) {
          dst[x] = srcRow[x >> sx];
        }
      }
      planes.add(full);
    } else {
      planes.add(rows);
    }
  }

  return buildDcImageFromRows(
    planes,
    lfHeight,
    lfWidth,
    frame.header.doYCbCr,
    header,
    iccProfile,
    isPreview: isPreview,
  );
}

/// As [buildDcImage], but from already-decoded float rows — the progressive
/// level-1 LF-frame case, where the DC data comes from a separate frame
/// rather than this frame's own LF groups.
JxlImage buildDcImageFromRows(
  List<List<Float32List>> planes,
  int lfHeight,
  int lfWidth,
  bool doYCbCr,
  ImageHeader header,
  Uint8List? iccProfile, {
  bool isPreview = true,
}) {
  if (header.xybEncoded) {
    final bundle = header.colorEncoding;
    final matrix =
        header.opsinInverseMatrix.getMatrix(bundle.prim, bundle.white);
    matrix.invertXyb(
        planes[0], planes[1], planes[2], header.toneMapping.intensityTarget);
  } else if (doYCbCr) {
    for (var y = 0; y < lfHeight; y++) {
      final cbRow = planes[0][y];
      final yRow = planes[1][y];
      final crRow = planes[2][y];
      for (var x = 0; x < lfWidth; x++) {
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
  if (header.xybEncoded) {
    final tf = TransferFunction.forTransfer(header.colorEncoding.tf);
    for (var c = 0; c < 3; c++) {
      for (final row in planes[c]) {
        for (var i = 0; i < row.length; i++) {
          row[i] = tf.fromLinear(row[i]);
        }
      }
    }
  }

  // Crop to the visible 1:8 size and copy into ImageBuffers.
  final visHeight = ceilDiv(header.size.height, 8);
  final visWidth = ceilDiv(header.size.width, 8);
  ImageBuffer cropped(List<Float32List> rows) {
    final buf = ImageBuffer.float32(visHeight, visWidth);
    final out = buf.floatRows;
    for (var y = 0; y < visHeight; y++) {
      out[y].setRange(0, visWidth, rows[y]);
    }
    return buf;
  }

  final colors = header.colorChannelCount;
  final channels = <ImageBuffer>[
    if (colors == 1)
      cropped(planes[1])
    else ...[
      cropped(planes[0]),
      cropped(planes[1]),
      cropped(planes[2]),
    ],
  ];
  for (var i = 0; i < header.extraChannels.length; i++) {
    final opaque = ImageBuffer.float32(visHeight, visWidth);
    for (final row in opaque.floatRows) {
      row.fillRange(0, visWidth, 1.0);
    }
    channels.add(opaque);
  }

  final oriented = [
    for (final plane in channels) transposeBuffer(plane, header.orientation),
  ];
  return isPreview
      ? JxlImage.preview(
          header, oriented, iccProfile, oriented[0].width, oriented[0].height)
      : JxlImage.scaled(
          header, oriented, iccProfile, oriented[0].width, oriented[0].height);
}
