import 'dart:typed_data';

import 'package:koni_jxl/src/exceptions.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:test/test.dart';

import '../util/bit_writer.dart';

BitReader readerOf(List<int> bytes) => BitReader(Uint8List.fromList(bytes));

void main() {
  group('readBits', () {
    test('reads LSB-first within a byte', () {
      final r = readerOf([0xB2]); // 1011_0010
      expect(r.readBits(3), 2); // low bits 010
      expect(r.readBits(5), 22); // remaining 10110
      expect(r.atEnd, isTrue);
    });

    test('crosses byte boundaries', () {
      final r = readerOf([0xFF, 0x00, 0xA5]);
      expect(r.readBits(4), 0xF);
      expect(r.readBits(8), 0x0F); // high nibble of 0xFF + low nibble of 0x00
      expect(r.readBits(12), 0xA50);
      expect(r.atEnd, isTrue);
    });

    test('reads 32 bits at once', () {
      final r = readerOf([0x78, 0x56, 0x34, 0x12]);
      expect(r.readBits(32), 0x12345678);
    });

    test('reads 0 bits', () {
      final r = readerOf([]);
      expect(r.readBits(0), 0);
      expect(r.bitsRead, 0);
    });

    test('throws JxlTruncatedException past the end', () {
      final r = readerOf([0xFF]);
      expect(r.readBits(8), 0xFF);
      expect(() => r.readBits(1), throwsA(isA<JxlTruncatedException>()));
    });

    test('throws when not enough bits remain mid-byte', () {
      final r = readerOf([0xFF]);
      r.readBits(5);
      expect(() => r.readBits(4), throwsA(isA<JxlTruncatedException>()));
    });

    test('tracks bitsRead', () {
      final r = readerOf([0xFF, 0xFF, 0xFF]);
      r.readBits(3);
      expect(r.bitsRead, 3);
      r.readBits(13);
      expect(r.bitsRead, 16);
    });

    test('round-trips values written by BitWriter', () {
      final w = BitWriter();
      final values = <(int, int)>[
        (0, 1),
        (1, 1),
        (5, 3),
        (0xFFFF, 16),
        (0, 7),
        (123456789, 27),
        (0xFFFFFFFF, 32),
        (1, 2),
      ];
      for (final (v, n) in values) {
        w.writeBits(v, n);
      }
      final r = BitReader(w.toBytes());
      for (final (v, n) in values) {
        expect(r.readBits(n), v, reason: 'value $v of width $n');
      }
    });
  });

  group('peekBits', () {
    test('does not consume', () {
      final r = readerOf([0xB2]);
      expect(r.peekBits(3), 2);
      expect(r.bitsRead, 0);
      expect(r.readBits(3), 2);
    });

    test('zero-pads past the end of input', () {
      final r = readerOf([0x01]);
      expect(r.peekBits(16), 0x0001);
      expect(r.readBits(8), 1);
      expect(r.peekBits(8), 0);
      expect(r.atEnd, isTrue);
    });
  });

  group('readU32', () {
    // U32(Val(0), Bits(4), BitsOffset(8, 16), BitsOffset(12, 1)) style fields.
    test('selects each of the four distributions', () {
      final w = BitWriter();
      w.writeBits(0, 2); // selector 0 -> c0, no bits
      w.writeBits(1, 2); // selector 1
      w.writeBits(9, 4); // u1 = 4 bits
      w.writeBits(2, 2); // selector 2
      w.writeBits(200, 8); // u2 = 8 bits
      w.writeBits(3, 2); // selector 3
      w.writeBits(3000, 12); // u3 = 12 bits
      final r = BitReader(w.toBytes());
      expect(r.readU32(0, 0, 1, 4, 16, 8, 1, 12), 0);
      expect(r.readU32(0, 0, 1, 4, 16, 8, 1, 12), 1 + 9);
      expect(r.readU32(0, 0, 1, 4, 16, 8, 1, 12), 16 + 200);
      expect(r.readU32(0, 0, 1, 4, 16, 8, 1, 12), 1 + 3000);
    });
  });

  group('readU64', () {
    test('selector 0 is zero', () {
      final w = BitWriter()..writeBits(0, 2);
      expect(BitReader(w.toBytes()).readU64(), 0);
    });

    test('selector 1 is 1 + 4 bits', () {
      final w = BitWriter()
        ..writeBits(1, 2)
        ..writeBits(15, 4);
      expect(BitReader(w.toBytes()).readU64(), 16);
    });

    test('selector 2 is 17 + 8 bits', () {
      final w = BitWriter()
        ..writeBits(2, 2)
        ..writeBits(255, 8);
      expect(BitReader(w.toBytes()).readU64(), 272);
    });

    test('selector 3 without continuation', () {
      final w = BitWriter()
        ..writeBits(3, 2)
        ..writeBits(0xABC, 12)
        ..writeBool(false);
      expect(BitReader(w.toBytes()).readU64(), 0xABC);
    });

    test('selector 3 with one continuation byte', () {
      final w = BitWriter()
        ..writeBits(3, 2)
        ..writeBits(0xABC, 12)
        ..writeBool(true)
        ..writeBits(0xDE, 8)
        ..writeBool(false);
      expect(BitReader(w.toBytes()).readU64(), 0xABC | (0xDE << 12));
    });

    test('selector 3 continued to the 60-bit tail', () {
      final w = BitWriter()
        ..writeBits(3, 2)
        ..writeBits(1, 12);
      for (var i = 0; i < 6; i++) {
        w
          ..writeBool(true)
          ..writeBits(0, 8);
      }
      w
        ..writeBool(true)
        ..writeBits(0x7, 4); // shift == 60: 4 bits, no trailing bool
      expect(BitReader(w.toBytes()).readU64(), 1 | (0x7 << 60));
    });
  });

  group('readF16', () {
    double f16(int bits) {
      final w = BitWriter()..writeBits(bits, 16);
      return BitReader(w.toBytes()).readF16();
    }

    test('decodes common values', () {
      expect(f16(0x3C00), 1.0);
      expect(f16(0xBC00), -1.0);
      expect(f16(0x4000), 2.0);
      expect(f16(0x3800), 0.5);
      expect(f16(0x0000), 0.0);
      expect(f16(0x7BFF), 65504.0); // f16 max
      expect(f16(0x3555), closeTo(0.333251953125, 1e-12));
    });

    test('decodes subnormals', () {
      expect(f16(0x0001), 5.9604644775390625e-8); // 2^-24
      expect(f16(0x03FF), 1023 * 5.9604644775390625e-8);
    });

    test('rejects infinity and NaN', () {
      expect(() => f16(0x7C00), throwsA(isA<JxlInvalidBitstreamException>()));
      expect(() => f16(0xFC00), throwsA(isA<JxlInvalidBitstreamException>()));
      expect(() => f16(0x7E00), throwsA(isA<JxlInvalidBitstreamException>()));
    });
  });

  group('readEnum', () {
    test('decodes each range', () {
      final w = BitWriter();
      w.writeBits(0, 2); // -> 0
      w.writeBits(1, 2); // -> 1
      w.writeBits(2, 2);
      w.writeBits(5, 4); // -> 2 + 5 = 7
      w.writeBits(3, 2);
      w.writeBits(10, 6); // -> 18 + 10 = 28
      final r = BitReader(w.toBytes());
      expect(r.readEnum(), 0);
      expect(r.readEnum(), 1);
      expect(r.readEnum(), 7);
      expect(r.readEnum(), 28);
    });

    test('rejects values above 63', () {
      final w = BitWriter()
        ..writeBits(3, 2)
        ..writeBits(46, 6); // 18 + 46 = 64
      expect(() => BitReader(w.toBytes()).readEnum(),
          throwsA(isA<JxlInvalidBitstreamException>()));
    });
  });

  group('readU8', () {
    test('decodes the ANS var-u8 encoding', () {
      final w = BitWriter();
      w.writeBool(false); // -> 0
      w.writeBool(true);
      w.writeBits(0, 3); // -> 1
      w.writeBool(true);
      w.writeBits(3, 3);
      w.writeBits(5, 3); // -> 5 + 8 = 13
      w.writeBool(true);
      w.writeBits(7, 3);
      w.writeBits(127, 7); // -> 127 + 128 = 255
      final r = BitReader(w.toBytes());
      expect(r.readU8(), 0);
      expect(r.readU8(), 1);
      expect(r.readU8(), 13);
      expect(r.readU8(), 255);
    });
  });

  group('readIccVarint', () {
    test('decodes single and multi-byte varints', () {
      final w = BitWriter();
      w.writeBits(0x7F, 8); // 127
      w.writeBits(0x80, 8);
      w.writeBits(0x01, 8); // 128
      w.writeBits(0xFF, 8);
      w.writeBits(0xFF, 8);
      w.writeBits(0x03, 8); // 65535
      final r = BitReader(w.toBytes());
      expect(r.readIccVarint(), 127);
      expect(r.readIccVarint(), 128);
      expect(r.readIccVarint(), 65535);
    });
  });

  group('zeroPadToByte', () {
    test('accepts zero padding and aligns', () {
      final r = readerOf([0x05, 0xFF]); // 0000_0101
      r.readBits(3);
      r.zeroPadToByte();
      expect(r.bitsRead, 8);
      expect(r.readBits(8), 0xFF);
    });

    test('is a no-op when aligned', () {
      final r = readerOf([0xFF]);
      r.zeroPadToByte();
      expect(r.bitsRead, 0);
    });

    test('rejects nonzero padding', () {
      final r = readerOf([0x09]); // 0000_1001: bit 3 set
      r.readBits(3);
      expect(r.zeroPadToByte, throwsA(isA<JxlInvalidBitstreamException>()));
    });
  });

  group('skipBits', () {
    test('skips within the cache', () {
      final r = readerOf([0xB2, 0xFF]);
      r.peekBits(16); // fill cache
      r.skipBits(3);
      expect(r.bitsRead, 3);
      expect(r.readBits(5), 22);
    });

    test('skips across many bytes', () {
      final bytes = List<int>.filled(100, 0)..[98] = 0x40;
      final r = readerOf(bytes);
      r.readBits(5);
      r.skipBits(98 * 8 + 1 - 5);
      expect(r.readBits(6), 0x20); // 0x40 >> 1
    });

    test('throws when skipping past the end', () {
      final r = readerOf([0x00]);
      expect(() => r.skipBits(9), throwsA(isA<JxlTruncatedException>()));
    });
  });

  group('alignment and views', () {
    test('bytePosition reflects consumed bytes', () {
      final r = readerOf([1, 2, 3, 4]);
      r.readBits(16);
      expect(r.isAligned, isTrue);
      expect(r.bytePosition, 2);
      expect(r.remainingBytes(), [3, 4]);
    });

    test('view constructor reads a slice', () {
      final data = Uint8List.fromList([9, 9, 0xAB, 0xCD, 9]);
      final r = BitReader.view(data, 2, 4);
      expect(r.readBits(16), 0xCDAB);
      expect(r.atEnd, isTrue);
    });
  });
}
