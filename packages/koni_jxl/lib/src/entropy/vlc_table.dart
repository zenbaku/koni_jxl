import 'dart:typed_data';

import '../exceptions.dart';
import '../io/bit_reader.dart';

int _reverse32(int v) {
  v = ((v >> 1) & 0x55555555) | ((v & 0x55555555) << 1);
  v = ((v >> 2) & 0x33333333) | ((v & 0x33333333) << 2);
  v = ((v >> 4) & 0x0F0F0F0F) | ((v & 0x0F0F0F0F) << 4);
  v = ((v >> 8) & 0x00FF00FF) | ((v & 0x00FF00FF) << 8);
  return ((v >> 16) & 0xFFFF) | ((v & 0xFFFF) << 16);
}

/// A lookup-table prefix (Huffman) decoder: peek [bits] bits, map directly to
/// (symbol, code length), consume the code length.
final class VlcTable {
  /// Builds from a pre-expanded table of (symbol, length) entries indexed by
  /// the peeked bits — used for the fixed spec tables.
  VlcTable.fromEntries(this.bits, List<int> symbols, List<int> lengths)
      : assert(symbols.length == 1 << bits && lengths.length == 1 << bits),
        _symbols = Int32List.fromList(symbols),
        _lengths = Int32List.fromList(lengths);

  /// Builds the canonical prefix table from per-symbol code [lengths].
  /// A length of 0 means the symbol is absent. [symbols] remaps indices
  /// (identity when null).
  factory VlcTable.canonical(int bits, List<int> lengths,
      [List<int>? symbols]) {
    final size = 1 << bits;
    final tableSymbols = Int32List(size)..fillRange(0, size, -1);
    final tableLengths = Int32List(size);
    final assigned = Uint8List(size);

    final codes = Int32List(lengths.length);
    final nLengths = Int32List(lengths.length);
    final nSymbols = Int32List(lengths.length);
    var count = 0;
    var code = 0;
    for (var i = 0; i < lengths.length; i++) {
      var len = lengths[i];
      if (len > 0) {
        nLengths[count] = len;
        nSymbols[count] = symbols != null ? symbols[i] : i;
        codes[count] = code;
        count++;
      } else if (len < 0) {
        len = -len;
      } else {
        continue;
      }
      code += 1 << (32 - len);
      // Written as the literal (not `1 << 32`): dart2js's `<<` returns 0
      // for any shift amount >= 32, so a *computed* `1 << 32` silently
      // gives 0 there, even though the value itself is exactly
      // representable as a double.
      if (code > 0x100000000) {
        throw const JxlInvalidBitstreamException('too many VLC codes');
      }
    }
    if (code != 0x100000000) {
      throw const JxlInvalidBitstreamException('not enough VLC codes');
    }
    for (var i = 0; i < count; i++) {
      final len = nLengths[i];
      if (len > bits) {
        throw const JxlInvalidBitstreamException('VLC table size too small');
      }
      var index = _reverse32(codes[i]);
      final number = 1 << (bits - len);
      final offset = 1 << len;
      for (var j = 0; j < number; j++) {
        if (assigned[index] != 0 &&
            (tableLengths[index] != len ||
                tableSymbols[index] != nSymbols[i])) {
          throw const JxlInvalidBitstreamException('illegal VLC codes');
        }
        tableSymbols[index] = nSymbols[i];
        tableLengths[index] = len;
        assigned[index] = 1;
        index += offset;
      }
    }
    return VlcTable._(bits, tableSymbols, tableLengths);
  }

  VlcTable._(this.bits, this._symbols, this._lengths);

  final int bits;
  final Int32List _symbols;
  final Int32List _lengths;

  @pragma('vm:prefer-inline')
  int getVlc(BitReader reader) {
    final index = reader.peekBits(bits);
    reader.skipBits(_lengths[index]);
    return _symbols[index];
  }
}
