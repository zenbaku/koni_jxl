import 'dart:typed_data';

import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';

/// Decodes JPEG XL's entropy-coded ICC representation.
///
/// Two stages, matching the spec: [readEncodedStream] reads the
/// entropy-coded bytes that follow the image header, and [decompress]
/// expands them (varint header, tag-list reconstruction, prediction
/// commands) into a real ICC profile.
abstract final class IccCodec {
  /// Context model over the previous two bytes (spec ICC context function).
  static int _iccContext(Uint8List buffer, int index) {
    if (index <= 128) return 0;
    final b1 = buffer[index - 1];
    final b2 = buffer[index - 2];
    int p1, p2;
    if (b1 >= 0x61 && b1 <= 0x7A || b1 >= 0x41 && b1 <= 0x5A) {
      p1 = 0;
    } else if (b1 >= 0x30 && b1 <= 0x39 || b1 == 0x2E || b1 == 0x2C) {
      p1 = 1;
    } else if (b1 <= 1) {
      p1 = 2 + b1;
    } else if (b1 > 1 && b1 < 16) {
      p1 = 4;
    } else if (b1 > 240 && b1 < 255) {
      p1 = 5;
    } else if (b1 == 255) {
      p1 = 6;
    } else {
      p1 = 7;
    }
    if (b2 >= 0x61 && b2 <= 0x7A || b2 >= 0x41 && b2 <= 0x5A) {
      p2 = 0;
    } else if (b2 >= 0x30 && b2 <= 0x39 || b2 == 0x2E || b2 == 0x2C) {
      p2 = 1;
    } else if (b2 < 16) {
      p2 = 2;
    } else if (b2 > 240) {
      p2 = 3;
    } else {
      p2 = 4;
    }
    return 1 + p1 + 8 * p2;
  }

  /// Reads the entropy-coded ICC payload ([encodedSize] bytes) that directly
  /// follows the image header in the codestream.
  static Uint8List readEncodedStream(BitReader reader, int encodedSize) {
    final stream = EntropyStream.read(reader, 41);
    final encoded = Uint8List(encodedSize);
    for (var i = 0; i < encodedSize; i++) {
      encoded[i] = stream.readSymbol(reader, _iccContext(encoded, i));
    }
    if (!stream.validateFinalState()) {
      throw const JxlInvalidBitstreamException('ICC stream final state');
    }
    return encoded;
  }

  static const _mntrRgb = 'mntrRGB XYZ ';
  static const _acsp = 'acsp';
  static const _iccTags = [
    'cprt', 'wtpt', 'bkpt', 'rXYZ', 'gXYZ', 'bXYZ', //
    'kXYZ', 'rTRC', 'gTRC', 'bTRC', 'kTRC', 'chad', //
    'desc', 'chrm', 'dmnd', 'dmdd', 'lumi',
  ];
  static const _sized20Tags = {
    'rXYZ',
    'gXYZ',
    'bXYZ',
    'kXYZ',
    'wtpt',
    'bkpt',
    'lumi',
  };

  static int _prediction(Uint8List buffer, int outputSize, int i) {
    if (i <= 3) return outputSize >> (8 * (3 - i)) & 0xFF;
    if (i == 8) return 4;
    if (i >= 12 && i <= 23) return _mntrRgb.codeUnitAt(i - 12);
    if (i >= 36 && i <= 39) return _acsp.codeUnitAt(i - 36);
    if (buffer[40] == 0x41 /* A */) {
      if (i == 41 || i == 42) return 0x50; // P
      if (i == 43) return 0x4C; // L
    } else if (buffer[40] == 0x4D /* M */) {
      if (i == 41) return 0x53; // S
      if (i == 42) return 0x46; // F
      if (i == 43) return 0x54; // T
    } else if (buffer[40] == 0x53 /* S */) {
      if (buffer[41] == 0x47 /* G */) {
        if (i == 42) return 0x49; // I
        if (i == 43) return 32;
      } else if (buffer[41] == 0x55 /* U */) {
        if (i == 42) return 0x4E; // N
        if (i == 43) return 0x57; // W
      }
    }
    if (i == 70) return 246;
    if (i == 71) return 214;
    if (i == 73) return 1;
    if (i == 78) return 211;
    if (i == 79) return 45;
    if (i >= 80 && i < 84) return buffer[i - 76];
    return 0;
  }

  static Uint8List _shuffle(Uint8List buffer, int width) {
    final height = ceilDiv(buffer.length, width);
    final result = Uint8List(buffer.length);
    for (var i = 0; i < buffer.length; i++) {
      result[(i % height) * width + i ~/ height] = buffer[i];
    }
    return result;
  }

  /// Expands the encoded ICC representation into the actual ICC profile.
  static Uint8List decompress(Uint8List encoded) {
    final commandReader = BitReader(encoded);
    final outputSize = commandReader.readIccVarint();
    final commandSize = commandReader.readIccVarint();
    final commandStart = commandReader.bitsRead >> 3;
    final dataStart = commandStart + commandSize;
    if (dataStart > encoded.length) {
      throw const JxlInvalidBitstreamException('ICC command size overflow');
    }
    final dataReader = BitReader.view(encoded, dataStart);
    final headerSize = outputSize < 128 ? outputSize : 128;
    final result = Uint8List(outputSize);
    var pos = 0;

    void put(int byte) {
      if (pos >= outputSize) {
        throw const JxlInvalidBitstreamException('ICC output overflow');
      }
      result[pos++] = byte & 0xFF;
    }

    // Header section: predicted bytes plus residuals.
    for (var i = 0; i < headerSize; i++) {
      final e = dataReader.readBits(8);
      final p = _prediction(result, outputSize, i);
      put(p + e);
    }
    if (pos == outputSize) return result;

    bool commandsRemain() =>
        !commandReader.atEnd && commandReader.bitsRead >> 3 < dataStart;

    // Tag list section.
    final tagCount = commandReader.readIccVarint() - 1;
    if (tagCount >= 0) {
      for (var i = 24; i >= 0; i -= 8) {
        put(tagCount >> i);
      }
      var prevTagStart = 128 + tagCount * 12;
      var prevTagSize = 0;
      while (commandsRemain()) {
        final command = commandReader.readBits(8);
        final tagCode = command & 0x3F;
        if (tagCode == 0) break;
        final String tag;
        if (tagCode == 1) {
          final tcr = List<int>.generate(4, (_) => dataReader.readBits(8));
          tag = String.fromCharCodes(tcr);
        } else if (tagCode == 2) {
          tag = 'rTRC';
        } else if (tagCode == 3) {
          tag = 'rXYZ';
        } else if (tagCode >= 4 && tagCode <= 21) {
          tag = _iccTags[tagCode - 4];
        } else {
          throw const JxlInvalidBitstreamException('illegal ICC tag code');
        }
        var tagStart = command & 0x40 != 0
            ? commandReader.readIccVarint()
            : prevTagStart + prevTagSize;
        final tagSize = command & 0x80 != 0
            ? commandReader.readIccVarint()
            : _sized20Tags.contains(tag)
                ? 20
                : prevTagSize;
        prevTagSize = tagSize;
        prevTagStart = tagStart;

        final tags = tagCode == 2
            ? const ['rTRC', 'gTRC', 'bTRC']
            : tagCode == 3
                ? const ['rXYZ', 'gXYZ', 'bXYZ']
                : [tag];
        for (final wTag in tags) {
          for (var i = 0; i < 4; i++) {
            put(wTag.codeUnitAt(i));
          }
          for (var i = 24; i >= 0; i -= 8) {
            put(tagStart >> i);
          }
          for (var i = 24; i >= 0; i -= 8) {
            put(tagSize >> i);
          }
          if (tagCode == 3) tagStart += tagSize;
        }
      }
    }

    // Data section.
    while (commandsRemain()) {
      final command = commandReader.readBits(8);
      if (command == 1) {
        final num = commandReader.readIccVarint();
        for (var i = 0; i < num; i++) {
          put(dataReader.readBits(8));
        }
      } else if (command == 2 || command == 3) {
        final num = commandReader.readIccVarint();
        var b = Uint8List(num);
        for (var p = 0; p < num; p++) {
          b[p] = dataReader.readBits(8);
        }
        b = _shuffle(b, command == 2 ? 2 : 4);
        for (var i = 0; i < b.length; i++) {
          put(b[i]);
        }
      } else if (command == 4) {
        final flags = commandReader.readBits(8);
        final width = (flags & 3) + 1;
        if (width == 3) {
          throw const JxlInvalidBitstreamException('illegal ICC width=3');
        }
        final order = (flags & 12) >> 2;
        if (order == 3) {
          throw const JxlInvalidBitstreamException('illegal ICC order=3');
        }
        final stride =
            flags & 0x10 != 0 ? commandReader.readIccVarint() : width;
        if (stride * 4 >= pos) {
          throw const JxlInvalidBitstreamException('ICC stride too large');
        }
        if (stride < width) {
          throw const JxlInvalidBitstreamException('ICC stride too small');
        }
        final num = commandReader.readIccVarint();
        var b = Uint8List(num);
        for (var p = 0; p < num; p++) {
          b[p] = dataReader.readBits(8);
        }
        if (width == 2 || width == 4) b = _shuffle(b, width);
        for (var i = 0; i < num; i += width) {
          final n = order + 1;
          final prev = List<int>.filled(n, 0);
          for (var j = 0; j < n; j++) {
            for (var k = 0; k < width; k++) {
              prev[j] <<= 8;
              prev[j] |= result[pos - stride * (j + 1) + k];
            }
          }
          final p = order == 0
              ? prev[0]
              : order == 1
                  ? 2 * prev[0] - prev[1]
                  : 3 * prev[0] - 3 * prev[1] + prev[2];
          for (var j = 0; j < width && i + j < num; j++) {
            put(b[i + j] + (p >> (8 * (width - 1 - j))));
          }
        }
      } else if (command == 10) {
        put(0x58); // X
        put(0x59); // Y
        put(0x5A); // Z
        put(0x20);
        pos += 4;
        for (var i = 0; i < 12; i++) {
          put(dataReader.readBits(8));
        }
      } else if (command >= 16 && command < 24) {
        const s = [
          'XYZ ',
          'desc',
          'text',
          'mluc',
          'para',
          'curv',
          'sf32',
          'gbd '
        ];
        final trc = s[command - 16];
        for (var i = 0; i < 4; i++) {
          put(trc.codeUnitAt(i));
        }
        pos += 4;
      } else {
        throw const JxlInvalidBitstreamException('illegal ICC data command');
      }
    }
    return result;
  }
}
