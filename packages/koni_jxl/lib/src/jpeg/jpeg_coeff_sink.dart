import 'dart:typed_data';

/// Collects the quantized DCT coefficients of a JPEG-transcoded VarDCT frame,
/// per JPEG component, in block-raster / within-block-raster layout — the form
/// [writeJpeg] consumes. Populated during decode via a gated hook (near-zero
/// cost when not reconstructing) from `LfCoefficients` (DC) and
/// `HfCoefficients` (AC).
///
/// Channel↔component mapping (measured against djxl on grayscale and YCbCr
/// 4:4:4 transcodes): DC in `lfQuant[j]` is JPEG component `j`; AC in
/// `quantizedCoeffs[c]` is JPEG component `cMap[c]`. The caller applies that
/// mapping, so this sink is keyed directly by JPEG component index.
final class JpegCoeffSink {
  JpegCoeffSink(this.widthInBlocks, this.heightInBlocks)
      : coeffs = [
          for (var i = 0; i < widthInBlocks.length; i++)
            Int32List(widthInBlocks[i] * heightInBlocks[i] * 64),
        ];

  /// Per JPEG component, block dimensions and the flat coefficient store
  /// (`coeffs[c][(by * wib + bx) * 64 + naturalPos]`).
  final List<int> widthInBlocks;
  final List<int> heightInBlocks;
  final List<Int32List> coeffs;

  /// Records the quantized DC integer for one block (natural position 0).
  void setDc(int component, int blockY, int blockX, int value) {
    if (component >= coeffs.length) return;
    final wib = widthInBlocks[component];
    if (blockX >= wib || blockY >= heightInBlocks[component]) return;
    coeffs[component][(blockY * wib + blockX) * 64] = value;
  }

  /// Copies the 63 AC coefficients of one block from a group's raster-frequency
  /// `quantizedCoeffs` plane. The DC slot (0,0) is left for [setDc].
  void setAcBlock(int component, int blockY, int blockX, Float32List qc,
      int pixelY, int pixelX, int qw) {
    if (component >= coeffs.length) return;
    final wib = widthInBlocks[component];
    if (blockX >= wib || blockY >= heightInBlocks[component]) return;
    final dst = (blockY * wib + blockX) * 64;
    final out = coeffs[component];
    for (var r = 0; r < 8; r++) {
      final srcRow = (pixelY + r) * qw + pixelX;
      final dstRow = dst + r * 8;
      for (var col = 0; col < 8; col++) {
        if (r == 0 && col == 0) continue; // DC comes from setDc.
        out[dstRow + col] = qc[srcRow + col].toInt();
      }
    }
  }
}
