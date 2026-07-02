import 'dart:typed_data';

import 'package:koni_jxl/src/entropy/ans.dart';
import 'package:koni_jxl/src/entropy/hybrid_uint.dart';
import 'package:koni_jxl/src/entropy/prefix.dart';
import 'package:koni_jxl/src/entropy/symbol_distribution.dart';
import 'package:koni_jxl/src/entropy/vlc_table.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:test/test.dart';

import '../util/bit_writer.dart';

void main() {
  group('VlcTable.canonical', () {
    test('decodes a 3-symbol canonical code', () {
      // lengths {1, 2, 2}: canonical codes 0, 10, 11 (MSB-first),
      // read LSB-first from the stream.
      final table = VlcTable.canonical(2, const [1, 2, 2]);
      final w = BitWriter()
        ..writeBits(0, 1) // symbol 0
        ..writeBits(1, 1)
        ..writeBits(0, 1) // symbol 1: code 10 -> bits 1,0
        ..writeBits(1, 1)
        ..writeBits(1, 1); // symbol 2
      final r = BitReader(w.toBytes());
      expect(table.getVlc(r), 0);
      expect(table.getVlc(r), 1);
      expect(table.getVlc(r), 2);
    });

    test('applies the symbol mapping', () {
      final table = VlcTable.canonical(1, const [1, 1], const [42, 17]);
      final w = BitWriter()
        ..writeBits(0, 1)
        ..writeBits(1, 1);
      final r = BitReader(w.toBytes());
      expect(table.getVlc(r), 42);
      expect(table.getVlc(r), 17);
    });

    test('rejects over-subscribed code lengths', () {
      expect(() => VlcTable.canonical(2, const [1, 1, 1]), throwsA(anything));
    });
  });

  group('HybridIntegerConfig', () {
    // Independent implementation of the spec formula for cross-checking.
    int expand(HybridIntegerConfig c, int token, int extra, int extraBits) {
      final split = 1 << c.splitExponent;
      if (token < split) return token;
      final n = c.splitExponent -
          c.lsbInToken -
          c.msbInToken +
          ((token - split) >> (c.msbInToken + c.lsbInToken));
      expect(extraBits, n, reason: 'extra bit count for token $token');
      final low = token & ((1 << c.lsbInToken) - 1);
      var t = token >> c.lsbInToken;
      t &= (1 << c.msbInToken) - 1;
      t |= 1 << c.msbInToken;
      return (((t << n) | extra) << c.lsbInToken) | low;
    }

    test('config parses from bitstream', () {
      // logAlphabetSize 5 -> ceilLog1p(5) = 3 bits for splitExponent.
      final w = BitWriter()
        ..writeBits(4, 3) // splitExponent = 4
        ..writeBits(2, 3) // msbInToken = 2 (ceilLog1p(4) = 3 bits)
        ..writeBits(1, 2); // lsbInToken = 1 (ceilLog1p(2) = 2 bits)
      final c = HybridIntegerConfig.read(BitReader(w.toBytes()), 5);
      expect(c.splitExponent, 4);
      expect(c.msbInToken, 2);
      expect(c.lsbInToken, 1);
    });

    test('split == logAlphabetSize means no msb/lsb fields', () {
      final w = BitWriter()..writeBits(5, 3);
      final c = HybridIntegerConfig.read(BitReader(w.toBytes()), 5);
      expect(c.splitExponent, 5);
      expect(c.msbInToken, 0);
      expect(c.lsbInToken, 0);
    });

    test('expansion formula spot checks', () {
      const c = HybridIntegerConfig(4, 2, 1);
      // token < 16 is the value itself.
      expect(expand(c, 15, 0, 0), 15);
      // token 16: n = 4-1-2+0 = 1, msb bits 0b100 pattern.
      expect(expand(c, 16, 1, 1), 18);
      expect(expand(c, 16, 0, 1), 16);
      // token 23: (23-16)>>3 = 0, so n = 1 still.
      expect(expand(c, 23, 1, 1), 31);
      // token 24: (24-16)>>3 = 1 -> n = 2.
      expect(expand(c, 24, 3, 2), 38);
    });
  });

  group('PrefixSymbolDistribution simple form', () {
    test('single symbol consumes no bits per read', () {
      // alphabetSize 6 -> logAlphabetSize 3; hskip=1, nsym=1, symbol=5.
      final w = BitWriter()
        ..writeBits(1, 2) // hskip = 1: simple
        ..writeBits(0, 2) // nsym - 1 = 0
        ..writeBits(5, 3); // symbol
      final r = BitReader(w.toBytes());
      final dist = PrefixSymbolDistribution(r, 6);
      final state = AnsState();
      final before = r.bitsRead;
      expect(dist.readSymbol(r, state), 5);
      expect(dist.readSymbol(r, state), 5);
      expect(r.bitsRead, before);
    });

    test('two symbols: one bit each, sorted', () {
      final w = BitWriter()
        ..writeBits(1, 2) // simple
        ..writeBits(1, 2) // nsym = 2
        ..writeBits(7, 3) // symbol a
        ..writeBits(2, 3) // symbol b (will sort before 7)
        ..writeBits(0, 1) // -> 2
        ..writeBits(1, 1); // -> 7
      final r = BitReader(w.toBytes());
      final dist = PrefixSymbolDistribution(r, 8);
      final state = AnsState();
      expect(dist.readSymbol(r, state), 2);
      expect(dist.readSymbol(r, state), 7);
    });
  });

  group('AnsSymbolDistribution', () {
    test('single-peak distribution decodes and validates final state', () {
      final w = BitWriter()
        ..writeBool(true) // simple distribution
        ..writeBool(false) // single peak
        // readU8 of 7: bool(true), n=2, bits(2)=3 -> 3 + 4
        ..writeBool(true)
        ..writeBits(2, 3)
        ..writeBits(3, 2)
        // initial ANS state: the canonical final state
        ..writeBits(0x130000, 32);
      final r = BitReader(w.toBytes());
      final dist = AnsSymbolDistribution(r, 5);
      final state = AnsState();
      expect(dist.readSymbol(r, state), 7);
      expect(dist.readSymbol(r, state), 7);
      expect(dist.readSymbol(r, state), 7);
      expect(state.state, 0x130000);
    });

    test('flat distribution builds valid alias table', () {
      final w = BitWriter()
        ..writeBool(false)
        ..writeBool(true) // flat
        // readU8 of 4 (alphabet 5): bool(true), n=2, bits(2)=0 -> 0 + 4
        ..writeBool(true)
        ..writeBits(2, 3)
        ..writeBits(0, 2)
        ..writeBits(0x130000, 32);
      final r = BitReader(w.toBytes());
      final dist = AnsSymbolDistribution(r, 5);
      final state = AnsState();
      final symbol = dist.readSymbol(r, state);
      expect(symbol, inInclusiveRange(0, 4));
    });
  });

  group('Uint8List byte semantics', () {
    test('assignment truncates like a Java byte cast', () {
      final b = Uint8List(1);
      b[0] = 0x1FF;
      expect(b[0], 0xFF);
    });
  });
}
