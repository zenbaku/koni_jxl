import 'dart:typed_data';

import '../exceptions.dart';
import '../frame/frame.dart';
import 'jbrd_decoder.dart';
import 'jpeg_writer.dart';

/// Assembles the exact original JPEG bytes from a decoded, coefficient-captured
/// [frame] and its `jbrd` box payload. The frame must have been decoded with
/// `captureJpeg` set so `frame.jpegSink` is populated.
///
/// Handles baseline grayscale and YCbCr transcodes (4:4:4 with integer-exact
/// chroma-from-luma inversion). Chroma subsampling, RGB (non-YCbCr) color,
/// and progressive scans throw [JxlUnsupportedException] pending later phases.
Uint8List buildJpegFromCapture(Frame frame, Uint8List jbrdBytes) {
  final jpg = decodeJbrd(jbrdBytes);
  final sink = frame.jpegSink;
  final hf = frame.hfGlobal;
  if (sink == null || hf == null) {
    throw JxlUnsupportedException('jpeg-reconstruction-non-vardct');
  }
  if (frame.passes.length != 1) {
    throw JxlUnsupportedException('jpeg-reconstruction-multipass');
  }
  if (sink.nonDct8) {
    // Only 8x8 DCT blocks map to JPEG; a crafted stream might use others.
    throw JxlUnsupportedException('jpeg-reconstruction-nondct8');
  }

  jpg.width = frame.globalMetadata.size.width;
  jpg.height = frame.globalMetadata.size.height;

  final header = frame.header;
  var maxUpX = 0, maxUpY = 0;
  for (var i = 0; i < 3; i++) {
    if (header.jpegUpsamplingX[i] > maxUpX) maxUpX = header.jpegUpsamplingX[i];
    if (header.jpegUpsamplingY[i] > maxUpY) maxUpY = header.jpegUpsamplingY[i];
  }
  final subsampled = maxUpX != 0 || maxUpY != 0;
  if (jpg.components.length > 1 && !header.doYCbCr) {
    // RGB (kNone) transcodes carry a DC level-shift (dcoff) not yet handled.
    throw JxlUnsupportedException('jpeg-reconstruction-rgb');
  }

  // Quant table values: the raw DCT8x8 quant matrices from the codestream,
  // in semantic (X, Y, B) channel order; JPEG component j uses channel cMap[j].
  final rawParams = hf.params[0].param;
  if (rawParams == null) {
    throw JxlUnsupportedException('jpeg-reconstruction-nonraw-quant');
  }
  for (var qi = 0; qi < jpg.quant.length; qi++) {
    // Find a component using quant-table array-slot qi, then pull its channel's
    // raw table.
    final compIdx = jpg.components.indexWhere((c) => c.quantIdx == qi);
    final j = compIdx < 0 ? 0 : compIdx;
    // The raw JXL quant matrix is stored transposed relative to JPEG's raster
    // (row-major) layout.
    final table = rawParams[cMap[j]];
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        jpg.quant[qi].values[row * 8 + col] = table[col * 8 + row].toInt();
      }
    }
  }

  for (var j = 0; j < jpg.components.length; j++) {
    final c = jpg.components[j];
    final channel = cMap[j];
    c.hSampFactor = (1 << maxUpX) >> header.jpegUpsamplingX[channel];
    c.vSampFactor = (1 << maxUpY) >> header.jpegUpsamplingY[channel];
    c.widthInBlocks = sink.widthInBlocks[j];
    c.heightInBlocks = sink.heightInBlocks[j];
    c.coeffs = sink.coeffs[j];
  }

  // Chroma-from-luma inversion. In 4:4:4 YCbCr, the stored chroma AC is a CfL
  // residual; add back the luma contribution exactly as libjxl's
  // reconstruction path does (fixed-point, kCFLFixedPointPrecision = 11,
  // color factor 84). Subsampled chroma carries no CfL, and luma never does.
  if (jpg.components.length == 3 && !subsampled) {
    final yQuant = jpg.quant[jpg.components[0].quantIdx].values;
    final yCoeffs = sink.coeffs[0];
    for (final j in const [1, 2]) {
      _invertCfl(sink.coeffs[j], yCoeffs, sink.cflFactor[j],
          jpg.quant[jpg.components[j].quantIdx].values, yQuant);
    }
  }

  // Robustness: JPEG coefficients must fit JPEG's range (DC clamped to
  // +/-2047, AC in +/-4095), matching libjxl's reconstruction guard. Valid
  // transcodes always satisfy this (so it is byte-exact-invariant); a crafted
  // `.jxl` with an out-of-range coefficient is rejected here instead of
  // overflowing the entropy writer's Huffman-symbol index.
  for (final comp in jpg.components) {
    final co = comp.coeffs;
    for (var b = 0; b < co.length; b += 64) {
      final dc = co[b];
      co[b] = dc < -2047 ? -2047 : (dc > 2047 ? 2047 : dc);
      for (var i = 1; i < 64; i++) {
        if (co[b + i] < -4095 || co[b + i] > 4095) {
          throw const JxlInvalidBitstreamException(
              'JPEG DCT coefficient out of range');
        }
      }
    }
  }

  return writeJpeg(jpg);
}

const int _cflPrecision = 11;
const int _cflRound = 1 << (_cflPrecision - 1);
const int _colorFactor = 84;

/// Adds the chroma-from-luma contribution back into [chroma]'s AC coefficients,
/// turning the stored residual into the original JPEG coefficient. Port of the
/// JPEG path in libjxl `dec_group.cc`: per block, per AC position i,
/// `chroma[i] += (y[i] * ((scaledQ[i] * ratio + r) >> 11) + r) >> 11`, where
/// `ratio = factor * 2^11 / 84` and `scaledQ[i] = 2^11 * qY[i] / qC[i]` (both
/// quant tables in JPEG raster order). DC (position 0) is untouched.
void _invertCfl(Int32List chroma, Int32List y, Int32List factors, Int32List qC,
    Int32List qY) {
  final scaledQ = Int32List(64);
  for (var i = 1; i < 64; i++) {
    scaledQ[i] = (qY[i] << _cflPrecision) ~/ qC[i];
  }
  final numBlocks = factors.length;
  for (var b = 0; b < numBlocks; b++) {
    final factor = factors[b];
    if (factor == 0) continue; // ratio 0 -> no contribution.
    final ratio = (factor << _cflPrecision) ~/ _colorFactor;
    final base = b * 64;
    for (var i = 1; i < 64; i++) {
      final coeffScale = (scaledQ[i] * ratio + _cflRound) >> _cflPrecision;
      chroma[base + i] +=
          (y[base + i] * coeffScale + _cflRound) >> _cflPrecision;
    }
  }
}
