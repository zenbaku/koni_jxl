import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';
import 'symbol_distribution.dart';
import 'vlc_table.dart';

/// The fixed 4-bit level-0 table used to read code lengths of the level-1
/// code-length code (Brotli-style).
final _level0Table = VlcTable.fromEntries(4, const [
  0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5, //
], const [
  2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4, //
]);

const _codelenMap = [
  1,
  2,
  3,
  4,
  0,
  5,
  17,
  6,
  16,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
];

/// A Brotli-style prefix-code symbol distribution.
final class PrefixSymbolDistribution extends SymbolDistribution {
  PrefixSymbolDistribution(BitReader reader, int alphabetSize) {
    this.alphabetSize = alphabetSize;
    logAlphabetSize = ceilLog1p(alphabetSize - 1);

    if (alphabetSize == 1) {
      _table = null;
      _defaultSymbol = 0;
      return;
    }
    final hskip = reader.readBits(2);
    if (hskip == 1) {
      _populateSimple(reader);
    } else {
      _populateComplex(reader, hskip);
    }
  }

  VlcTable? _table;
  int _defaultSymbol = 0;

  void _populateSimple(BitReader reader) {
    final symbols = List<int>.filled(4, 0);
    final nsym = 1 + reader.readBits(2);
    for (var i = 0; i < nsym; i++) {
      symbols[i] = reader.readBits(logAlphabetSize);
    }
    final treeSelect = nsym == 4 && reader.readBool();
    List<int> lens;
    int bits;
    switch (nsym) {
      case 1:
        _table = null;
        _defaultSymbol = symbols[0];
        return;
      case 2:
        bits = 1;
        lens = const [1, 1, 0, 0];
        if (symbols[0] > symbols[1]) {
          final temp = symbols[1];
          symbols[1] = symbols[0];
          symbols[0] = temp;
        }
      case 3:
        bits = 2;
        lens = const [1, 2, 2, 0];
        if (symbols[1] > symbols[2]) {
          final temp = symbols[2];
          symbols[2] = symbols[1];
          symbols[1] = temp;
        }
      default:
        if (treeSelect) {
          bits = 3;
          lens = const [1, 2, 3, 3];
          if (symbols[2] > symbols[3]) {
            final temp = symbols[3];
            symbols[3] = symbols[2];
            symbols[2] = temp;
          }
        } else {
          bits = 2;
          lens = const [2, 2, 2, 2];
          symbols.sort();
        }
    }
    _table = VlcTable.canonical(bits, lens, symbols);
  }

  void _populateComplex(BitReader reader, int hskip) {
    final level1Lengths = List<int>.filled(18, 0);
    final level1Codecounts = List<int>.filled(19, 0);
    level1Codecounts[0] = hskip;

    var totalCode = 0;
    var numCodes = 0;
    for (var i = hskip; i < 18; i++) {
      final code = level1Lengths[_codelenMap[i]] = _level0Table.getVlc(reader);
      level1Codecounts[code]++;
      if (code != 0) {
        totalCode += 32 >> code;
        numCodes++;
      }
      if (totalCode >= 32) {
        level1Codecounts[0] += 17 - i;
        break;
      }
    }
    if (totalCode != 32 && numCodes >= 2 || numCodes < 1) {
      throw const JxlInvalidBitstreamException('invalid level 1 prefix codes');
    }
    for (var i = 1; i < 19; i++) {
      level1Codecounts[i] += level1Codecounts[i - 1];
    }
    final level1LengthsScrambled = List<int>.filled(18, 0);
    final level1Symbols = List<int>.filled(18, 0);
    for (var i = 17; i >= 0; i--) {
      final index = --level1Codecounts[level1Lengths[i]];
      if (index < 0 || index >= 18) {
        throw const JxlInvalidBitstreamException('invalid level 1 prefix code');
      }
      level1LengthsScrambled[index] = level1Lengths[i];
      level1Symbols[index] = i;
    }

    final VlcTable level1Table;
    if (numCodes == 1) {
      level1Table = VlcTable.fromEntries(0, [level1Symbols[17]], [0]);
    } else {
      level1Table =
          VlcTable.canonical(5, level1LengthsScrambled, level1Symbols);
    }

    totalCode = 0;
    var prevRepeatCount = 0;
    var prevZeroCount = 0;
    final level2Lengths = List<int>.filled(alphabetSize, 0);
    final level2Symbols = List<int>.filled(alphabetSize, 0);
    final level2Counts = List<int>.filled(alphabetSize + 1, 0);
    var prev = 8;
    for (var i = 0; i < alphabetSize; i++) {
      final code = level1Table.getVlc(reader);
      if (code == 16) {
        var extra = 3 + reader.readBits(2);
        if (prevRepeatCount > 0) {
          extra = 4 * (prevRepeatCount - 2) - prevRepeatCount + extra;
        }
        if (i + extra > alphabetSize) {
          throw const JxlInvalidBitstreamException(
              'level 2 repeat overflows alphabet');
        }
        if (prev > alphabetSize) {
          throw const JxlInvalidBitstreamException(
              'level 2 repeat length exceeds alphabet');
        }
        for (var j = 0; j < extra; j++) {
          level2Lengths[i + j] = prev;
        }
        totalCode += (32768 >> prev) * extra;
        i += extra - 1;
        prevRepeatCount += extra;
        prevZeroCount = 0;
        level2Counts[prev] += extra;
      } else if (code == 17) {
        var extra = 3 + reader.readBits(3);
        if (prevZeroCount > 0) {
          extra = 8 * (prevZeroCount - 2) - prevZeroCount + extra;
        }
        i += extra - 1;
        prevRepeatCount = 0;
        prevZeroCount += extra;
        level2Counts[0] += extra;
      } else {
        // A code length that cannot fit this alphabet is invalid (and would
        // index past level2Counts, which has alphabetSize + 1 buckets).
        if (code > alphabetSize) {
          throw const JxlInvalidBitstreamException(
              'prefix code length exceeds alphabet');
        }
        level2Lengths[i] = code;
        prevRepeatCount = 0;
        prevZeroCount = 0;
        if (code != 0) {
          totalCode += 32768 >> code;
          prev = code;
        }
        level2Counts[code]++;
      }
      if (totalCode >= 32768) {
        level2Counts[0] += alphabetSize - i - 1;
        break;
      }
    }
    if (totalCode != 32768 && level2Counts[0] < alphabetSize - 1) {
      throw const JxlInvalidBitstreamException('invalid level 2 prefix codes');
    }
    for (var i = 1; i <= alphabetSize; i++) {
      level2Counts[i] += level2Counts[i - 1];
    }
    final level2LengthsScrambled = List<int>.filled(alphabetSize, 0);
    for (var i = alphabetSize - 1; i >= 0; i--) {
      final index = --level2Counts[level2Lengths[i]];
      if (index < 0 || index >= alphabetSize) {
        throw const JxlInvalidBitstreamException('invalid level 2 prefix code');
      }
      level2LengthsScrambled[index] = level2Lengths[i];
      level2Symbols[index] = i;
    }
    _table = VlcTable.canonical(15, level2LengthsScrambled, level2Symbols);
  }

  @override
  int readSymbol(BitReader reader, AnsState state) {
    final table = _table;
    if (table == null) return _defaultSymbol;
    return table.getVlc(reader);
  }
}
