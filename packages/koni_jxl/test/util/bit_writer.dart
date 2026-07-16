import 'dart:typed_data';

import 'package:koni_jxl/src/util/math_helper.dart';

/// Test-only LSB-first bit writer: the mirror of BitReader, for authoring
/// bitstream vectors in tests.
final class BitWriter {
  final _bytes = BytesBuilder();
  int _cache = 0;
  int _cacheBits = 0;

  void writeBits(int value, int bits) {
    assert(bits >= 0 && bits <= 32);
    assert(value >= 0 && (bits == 32 || value < (1 << bits)));
    // += / wideShl (not |= / <<): see the production BitWriter for why a
    // plain << silently truncates on dart2js once value and _cacheBits
    // together need more than 32 bits.
    _cache += wideShl(value, _cacheBits);
    _cacheBits += bits;
    while (_cacheBits >= 8) {
      _bytes.addByte(_cache & 0xFF);
      _cache = wideShr(_cache, 8);
      _cacheBits -= 8;
    }
  }

  void writeBool(bool value) => writeBits(value ? 1 : 0, 1);

  /// Pads with zero bits to the next byte boundary.
  void zeroPadToByte() {
    if (_cacheBits > 0) writeBits(0, 8 - _cacheBits);
  }

  Uint8List toBytes() {
    zeroPadToByte();
    return _bytes.toBytes();
  }
}
