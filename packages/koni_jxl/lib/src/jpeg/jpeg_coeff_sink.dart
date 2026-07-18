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
        ],
        cflFactor = [
          for (var i = 0; i < widthInBlocks.length; i++)
            Int32List(widthInBlocks[i] * heightInBlocks[i]),
        ];

  /// Per JPEG component, block dimensions and the flat coefficient store
  /// (`coeffs[c][(by * wib + bx) * 64 + naturalPos]`).
  final List<int> widthInBlocks;
  final List<int> heightInBlocks;
  final List<Int32List> coeffs;

  /// Per JPEG component, the raw signed chroma-from-luma factor of each block's
  /// 64x64 color tile (X-from-Y for Cb, B-from-Y for Cr; 0 for luma). Used to
  /// invert CfL on 4:4:4 chroma AC during reconstruction.
  final List<Int32List> cflFactor;

  /// Set if any captured block uses a transform other than DCT 8x8. JPEG only
  /// has 8x8 blocks, so a transcode never does; a crafted `.jxl` might, and
  /// reconstruction rejects it rather than emitting wrong bytes.
  bool nonDct8 = false;

  /// Records the per-tile CfL factor for one block.
  void setFactor(int component, int blockY, int blockX, int value) {
    if (component >= coeffs.length) return;
    final wib = widthInBlocks[component];
    if (blockX >= wib || blockY >= heightInBlocks[component]) return;
    cflFactor[component][blockY * wib + blockX] = value;
  }

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
