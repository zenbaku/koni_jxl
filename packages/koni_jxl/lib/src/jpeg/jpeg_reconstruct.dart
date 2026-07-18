import 'dart:typed_data';

import '../exceptions.dart';
import '../frame/frame.dart';
import 'jbrd_decoder.dart';
import 'jpeg_writer.dart';

/// Assembles the exact original JPEG bytes from a decoded, coefficient-captured
/// [frame] and its `jbrd` box payload. The frame must have been decoded with
/// `captureJpeg` set so `frame.jpegSink` is populated.
///
/// Phase 1 handles baseline grayscale transcodes; color (chroma-from-luma) and
/// progressive scans throw [JxlUnsupportedException] pending later phases.
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
  if (jpg.components.length > 1) {
    // Chroma-from-luma inversion + subsampling are phase 2/3.
    throw JxlUnsupportedException('jpeg-reconstruction-color');
  }

  jpg.width = frame.globalMetadata.size.width;
  jpg.height = frame.globalMetadata.size.height;

  final header = frame.header;
  var maxUpX = 0, maxUpY = 0;
  for (var i = 0; i < 3; i++) {
    if (header.jpegUpsamplingX[i] > maxUpX) maxUpX = header.jpegUpsamplingX[i];
    if (header.jpegUpsamplingY[i] > maxUpY) maxUpY = header.jpegUpsamplingY[i];
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

  return writeJpeg(jpg);
}
