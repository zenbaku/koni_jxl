import 'dart:typed_data';

/// LSB-first bit writer: the exact mirror of [BitReader].
final class BitWriter {
  final _bytes = BytesBuilder();
  int _cache = 0;
  int _cacheBits = 0;

  /// Bits written so far (including unflushed cache bits).
  int get bitsWritten => _bytes.length * 8 + _cacheBits;

  void writeBits(int value, int bits) {
    assert(bits >= 0 && bits <= 32);
    assert(value >= 0 && (bits >= 32 || value < (1 << bits)),
        'value $value does not fit in $bits bits');
    _cache |= value << _cacheBits;
    _cacheBits += bits;
    while (_cacheBits >= 8) {
      _bytes.addByte(_cache & 0xFF);
      _cache >>= 8;
      _cacheBits -= 8;
    }
  }

  void writeBool(bool value) => writeBits(value ? 1 : 0, 1);

  /// Writes [value] with the U32 distribution that encodes it in the
  /// fewest bits (mirror of `BitReader.readU32`).
  void writeU32(int value, int c0, int u0, int c1, int u1, int c2, int u2,
      int c3, int u3) {
    final constants = [c0, c1, c2, c3];
    final bits = [u0, u1, u2, u3];
    var best = -1;
    var bestCost = 1 << 30;
    for (var i = 0; i < 4; i++) {
      final lo = constants[i];
      final hi = lo + (bits[i] >= 32 ? 0xFFFFFFFF : (1 << bits[i]) - 1);
      if (value >= lo && value <= hi && 2 + bits[i] < bestCost) {
        best = i;
        bestCost = 2 + bits[i];
      }
    }
    if (best < 0) {
      throw ArgumentError('value $value not representable by this U32');
    }
    writeBits(best, 2);
    writeBits(value - constants[best], bits[best]);
  }

  /// Mirror of `BitReader.readU64`.
  void writeU64(int value) {
    if (value == 0) {
      writeBits(0, 2);
    } else if (value <= 16) {
      writeBits(1, 2);
      writeBits(value - 1, 4);
    } else if (value <= 272) {
      writeBits(2, 2);
      writeBits(value - 17, 8);
    } else {
      writeBits(3, 2);
      writeBits(value & 0xFFF, 12);
      var remaining = value >>> 12;
      var shift = 12;
      while (remaining != 0 && shift < 60) {
        writeBool(true);
        writeBits(remaining & 0xFF, 8);
        remaining >>>= 8;
        shift += 8;
      }
      if (remaining != 0) {
        // shift == 60: final 4-bit tail with no continuation bit.
        writeBool(true);
        writeBits(remaining & 0xF, 4);
      } else {
        writeBool(false);
      }
    }
  }

  /// Mirror of `BitReader.readEnum`.
  void writeEnum(int value) {
    assert(value >= 0 && value <= 63);
    writeU32(value, 0, 0, 1, 0, 2, 4, 18, 6);
  }

  /// Pads with zero bits to the next byte boundary.
  void zeroPadToByte() {
    if (_cacheBits > 0) writeBits(0, 8 - _cacheBits);
  }

  /// Appends whole bytes; the writer must be byte-aligned.
  void writeBytes(List<int> bytes) {
    assert(_cacheBits == 0, 'writeBytes requires byte alignment');
    _bytes.add(bytes);
  }

  Uint8List toBytes() {
    zeroPadToByte();
    return _bytes.toBytes();
  }
}
