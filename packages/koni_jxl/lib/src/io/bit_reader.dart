import 'dart:typed_data';

import '../exceptions.dart';

/// Reads a JPEG XL codestream bit by bit.
///
/// JPEG XL bitstreams are read LSB-first within each byte: the first bit read
/// from a byte is its least significant bit, and the first bit read
/// contributes the least significant bit of the returned value.
///
/// The cache invariant keeps [_cache] strictly below 2^40 (at most 39 live
/// bits), so all arithmetic stays in non-negative Dart ints and never touches
/// the sign bit.
final class BitReader {
  BitReader(this._data);

  /// A reader over `data[start..end)` without copying.
  BitReader.view(Uint8List data, int start, [int? end])
      : this(Uint8List.sublistView(data, start, end));

  final Uint8List _data;
  int _pos = 0;
  int _cache = 0;
  int _cacheBits = 0;

  /// Total number of bits consumed so far.
  int get bitsRead => (_pos << 3) - _cacheBits;

  /// Whether every bit of the input has been consumed.
  bool get atEnd => _cacheBits == 0 && _pos >= _data.length;

  /// Whether the read position is on a byte boundary.
  bool get isAligned => _cacheBits & 7 == 0;

  /// Byte offset of the read position. Only valid when [isAligned].
  int get bytePosition {
    assert(isAligned);
    return _pos - (_cacheBits >> 3);
  }

  /// Bytes remaining from the current (aligned) position, as a no-copy view.
  Uint8List remainingBytes() {
    assert(isAligned);
    return Uint8List.sublistView(_data, bytePosition);
  }

  /// Reads `bits` bits (0–32) and returns them as an unsigned value.
  @pragma('vm:prefer-inline')
  int readBits(int bits) {
    assert(bits >= 0 && bits <= 32);
    if (bits == 0) return 0;
    while (_cacheBits < bits) {
      if (_pos >= _data.length) {
        throw JxlTruncatedException(
            'unable to read $bits bits at bit position $bitsRead');
      }
      _cache |= _data[_pos++] << _cacheBits;
      _cacheBits += 8;
    }
    final ret = _cache & ((1 << bits) - 1);
    _cache >>= bits;
    _cacheBits -= bits;
    return ret;
  }

  /// Returns the next `bits` bits without consuming them.
  ///
  /// Bits past the end of the input read as zero (required by prefix-code
  /// lookup near the end of a stream).
  @pragma('vm:prefer-inline')
  int peekBits(int bits) {
    assert(bits >= 0 && bits <= 32);
    while (_cacheBits < bits && _pos < _data.length) {
      _cache |= _data[_pos++] << _cacheBits;
      _cacheBits += 8;
    }
    return _cache & ((1 << bits) - 1);
  }

  bool readBool() => readBits(1) != 0;

  /// The spec's `U32(...)` field: a 2-bit selector choosing one of four
  /// (constant, extra-bits) alternatives; value = constant + extra bits.
  int readU32(int c0, int u0, int c1, int u1, int c2, int u2, int c3, int u3) {
    switch (readBits(2)) {
      case 0:
        return c0 + readBits(u0);
      case 1:
        return c1 + readBits(u1);
      case 2:
        return c2 + readBits(u2);
      default:
        return c3 + readBits(u3);
    }
  }

  /// The spec's variable-length `U64()` field.
  int readU64() {
    final index = readBits(2);
    if (index == 0) return 0;
    if (index == 1) return 1 + readBits(4);
    if (index == 2) return 17 + readBits(8);
    var value = readBits(12);
    var shift = 12;
    while (readBool()) {
      if (shift == 60) {
        value |= readBits(4) << shift;
        break;
      }
      value |= readBits(8) << shift;
      shift += 8;
    }
    return value;
  }

  /// A 16-bit IEEE half-precision float. Infinities and NaN are illegal in
  /// JPEG XL headers.
  double readF16() {
    final bits16 = readBits(16);
    final mantissa = bits16 & 0x3FF;
    final exp = (bits16 >> 10) & 0x1F;
    if (exp == 31) {
      throw const JxlInvalidBitstreamException('illegal infinite/NaN float16');
    }
    // Subnormal: m * 2^-24; normal: (m + 1024) * 2^(e - 25).
    final magnitude = exp == 0
        ? mantissa * 5.9604644775390625e-8
        : (mantissa + 1024) * _pow2(exp - 25);
    return bits16 & 0x8000 != 0 ? -magnitude : magnitude;
  }

  /// The spec's `Enum()` field; values above 63 are invalid.
  int readEnum() {
    final constant = readU32(0, 0, 1, 0, 2, 4, 18, 6);
    if (constant > 63) {
      throw const JxlInvalidBitstreamException('enum constant > 63');
    }
    return constant;
  }

  /// Variable-length U8 used by ANS distribution headers.
  int readU8() {
    if (!readBool()) return 0;
    final n = readBits(3);
    if (n == 0) return 1;
    return readBits(n) + (1 << n);
  }

  /// LEB128-style varint used by the compressed ICC stream.
  int readIccVarint() {
    var value = 0;
    for (var shift = 0; shift < 63; shift += 7) {
      final b = readBits(8);
      value |= (b & 127) << shift;
      if (b <= 127) break;
    }
    if (value > 0x7FFFFFFF) {
      throw const JxlInvalidBitstreamException('ICC varint overflow');
    }
    return value;
  }

  /// Consumes bits up to the next byte boundary, which must all be zero.
  ///
  /// Bits are only ever consumed from the cache, so `_cacheBits % 8` is
  /// always the exact distance to the next byte boundary.
  void zeroPadToByte() {
    final remaining = _cacheBits % 8;
    if (remaining > 0 && readBits(remaining) != 0) {
      throw const JxlInvalidBitstreamException('nonzero zero-padding-to-byte');
    }
  }

  /// Skips `bits` bits (any count ≥ 0).
  void skipBits(int bits) {
    assert(bits >= 0);
    if (bits <= _cacheBits) {
      _cache >>= bits;
      _cacheBits -= bits;
      return;
    }
    bits -= _cacheBits;
    _cache = 0;
    _cacheBits = 0;
    final bytes = bits >> 3;
    if (_pos + bytes > _data.length) {
      throw JxlTruncatedException('unable to skip $bits bits');
    }
    _pos += bytes;
    readBits(bits & 7);
  }
}

double _pow2(int e) {
  // e is in [-25, 6] for f16; direct ldexp.
  var v = 1.0;
  var n = e;
  while (n > 0) {
    v *= 2.0;
    n--;
  }
  while (n < 0) {
    v /= 2.0;
    n++;
  }
  return v;
}
