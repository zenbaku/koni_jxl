import 'dart:typed_data';

import 'package:koni_jxl/src/encode/encoder.dart';
import 'package:koni_jxl/src/exceptions.dart';
import 'package:koni_jxl/src/io/container.dart';
import 'package:test/test.dart';

Uint8List box(String tag, List<int> payload) {
  final b = BytesBuilder();
  final size = 8 + payload.length;
  b.add([size >> 24 & 0xFF, size >> 16 & 0xFF, size >> 8 & 0xFF, size & 0xFF]);
  b.add(tag.codeUnits);
  b.add(payload);
  return b.toBytes();
}

final signature = Uint8List.fromList(
    [0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]);

Uint8List concat(List<List<int>> parts) {
  final b = BytesBuilder();
  parts.forEach(b.add);
  return b.toBytes();
}

void main() {
  final codestream = [0xFF, 0x0A, 1, 2, 3, 4];

  test('bare codestream passes through untouched', () {
    final data = Uint8List.fromList(codestream);
    final demuxed = demuxContainer(data);
    expect(demuxed.codestream, same(data));
    expect(demuxed.isContainer, isFalse);
    expect(demuxed.level, 5);
  });

  test('rejects non-JXL data', () {
    expect(() => demuxContainer(Uint8List.fromList(List.filled(20, 0x42))),
        throwsA(isA<JxlInvalidBitstreamException>()));
  });

  test('rejects too-short input', () {
    expect(() => demuxContainer(Uint8List.fromList([0, 0, 0])),
        throwsA(isA<JxlTruncatedException>()));
  });

  test('extracts jxlc payload', () {
    final data = concat([
      signature,
      box('ftyp', 'jxl \x00\x00\x00\x00jxl '.codeUnits),
      box('jxlc', codestream)
    ]);
    final demuxed = demuxContainer(data);
    expect(demuxed.codestream, codestream);
    expect(demuxed.isContainer, isTrue);
  });

  test('concatenates jxlp partial codestreams in order', () {
    final data = concat([
      signature,
      box('jxlp', [0, 0, 0, 0, ...codestream.sublist(0, 3)]),
      box('jxlp', [0x80, 0, 0, 1, ...codestream.sublist(3)]),
    ]);
    expect(demuxContainer(data).codestream, codestream);
  });

  test('reads level from jxll box', () {
    final data = concat([
      signature,
      box('jxll', [10]),
      box('jxlc', codestream),
    ]);
    expect(demuxContainer(data).level, 10);
  });

  test('rejects invalid level', () {
    final data = concat([
      signature,
      box('jxll', [7]),
      box('jxlc', codestream)
    ]);
    expect(() => demuxContainer(data),
        throwsA(isA<JxlInvalidBitstreamException>()));
  });

  test('skips unknown boxes', () {
    final data = concat([
      signature,
      box('Exif', List.filled(30, 0xEE)),
      box('jxlc', codestream),
    ]);
    expect(demuxContainer(data).codestream, codestream);
  });

  test('handles size-zero box extending to EOF', () {
    final b = BytesBuilder();
    b.add(signature);
    b.add([0, 0, 0, 0]); // size 0: to EOF
    b.add('jxlc'.codeUnits);
    b.add(codestream);
    expect(demuxContainer(b.toBytes()).codestream, codestream);
  });

  test('handles extended (64-bit) box size', () {
    final b = BytesBuilder();
    b.add(signature);
    final size = 16 + codestream.length;
    b.add([0, 0, 0, 1]);
    b.add('jxlc'.codeUnits);
    b.add([0, 0, 0, 0, 0, 0, 0, size]);
    b.add(codestream);
    expect(demuxContainer(b.toBytes()).codestream, codestream);
  });

  test('throws on truncated box payload', () {
    final data = concat([
      signature,
      box('jxlc', codestream).sublist(0, 10),
    ]);
    expect(() => demuxContainer(Uint8List.fromList(data)),
        throwsA(isA<JxlTruncatedException>()));
  });

  test('throws when container has no codestream', () {
    final data = concat([
      signature,
      box('Exif', [1, 2, 3])
    ]);
    expect(() => demuxContainer(data),
        throwsA(isA<JxlInvalidBitstreamException>()));
  });

  group('looksLikeJxl', () {
    test('recognizes a bare codestream prefix', () {
      expect(looksLikeJxl(codestream), isTrue);
      expect(looksLikeJxl([0xFF, 0x0A]), isTrue);
    });

    test('recognizes the container signature', () {
      expect(looksLikeJxl(signature), isTrue);
      expect(
          looksLikeJxl(concat([signature, box('jxlc', codestream)])), isTrue);
    });

    test('recognizes real encoder output', () {
      final jxl = JxlEncoder.encodeLossless(
          Uint8List.fromList(List.filled(4 * 4 * 4, 128)),
          width: 4,
          height: 4,
          hasAlpha: true);
      expect(looksLikeJxl(jxl), isTrue);
    });

    test('rejects other formats, short input, and near-misses', () {
      expect(looksLikeJxl([0x89, 0x50, 0x4E, 0x47]), isFalse); // PNG
      expect(looksLikeJxl([0xFF, 0xD8, 0xFF, 0xE0]), isFalse); // JPEG
      expect(looksLikeJxl([]), isFalse);
      expect(looksLikeJxl([0xFF]), isFalse);
      expect(looksLikeJxl(signature.sublist(0, 11)), isFalse);
      final wrongTail = [...signature]..[11] = 0x0B;
      expect(looksLikeJxl(wrongTail), isFalse);
    });
  });
}
