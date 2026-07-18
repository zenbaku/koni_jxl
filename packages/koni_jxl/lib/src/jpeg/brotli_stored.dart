import 'dart:typed_data';

import '../exceptions.dart';
import '../io/bit_reader.dart';

/// Decodes a Brotli stream (RFC 7932) that uses only *stored* (uncompressed)
/// and empty meta-blocks — the form libjxl emits for small `jbrd`-tail blobs
/// such as a JFIF APP0 marker. Reads from [br] (LSB-first, the same bit order
/// as the JXL codestream), which must be positioned at the stream start on a
/// byte boundary, and returns the full decompressed output.
///
/// Throws [JxlUnsupportedException] (`'brotli-compressed'`) on the first
/// genuinely compressed meta-block; a full RFC 7932 decoder is a later phase.
Uint8List decodeBrotliStored(BitReader br) {
  // Stream header: WBITS. The value only bounds back-reference distances,
  // which stored blocks never use, so we just consume the right number of
  // bits (1 for WBITS==16, else a 4- or 7-bit variable-length code).
  if (br.readBits(1) == 1) {
    if (br.readBits(3) == 0) {
      br.readBits(3); // 7-bit codes (WBITS 10..17); 4-bit codes stop here.
    }
  }

  final out = BytesBuilder(copy: false);
  while (true) {
    final isLast = br.readBits(1) == 1;
    if (isLast && br.readBits(1) == 1) break; // ISLASTEMPTY -> stream ends.

    final mnibCode = br.readBits(2);
    if (mnibCode == 3) {
      // Metadata meta-block: no uncompressed output; skip its bytes.
      br.readBits(1); // reserved (must be 0)
      final mskipBytes = br.readBits(2);
      final mskipLen = mskipBytes > 0 ? br.readBits(mskipBytes * 8) + 1 : 0;
      _alignToByte(br);
      br.skipBits(mskipLen * 8);
      if (isLast) break;
      continue;
    }

    final numNibbles = mnibCode == 0 ? 4 : (mnibCode == 1 ? 5 : 6);
    final mlen = br.readBits(numNibbles * 4) + 1;

    // ISUNCOMPRESSED only exists when !ISLAST. An ISLAST non-empty block with
    // MNIBBLES>0 is therefore always compressed, as is any block whose
    // ISUNCOMPRESSED bit is 0.
    if (isLast || br.readBits(1) != 1) {
      throw JxlUnsupportedException('brotli-compressed');
    }

    _alignToByte(br);
    final chunk = br.remainingBytes();
    if (chunk.length < mlen) {
      throw const JxlTruncatedException('truncated brotli stored block');
    }
    out.add(Uint8List.sublistView(chunk, 0, mlen));
    br.skipBits(mlen * 8);
  }
  return out.toBytes();
}

/// Advances [br] to the next byte boundary, discarding the intervening bits.
void _alignToByte(BitReader br) {
  final rem = (8 - (br.bitsRead & 7)) & 7;
  if (rem != 0) br.skipBits(rem);
}
