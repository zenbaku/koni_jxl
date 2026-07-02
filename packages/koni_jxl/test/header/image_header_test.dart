import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

/// Conformance corpus checks run only when the (gitignored) corpus clone is
/// present; they are skipped in CI.
final conformanceDir = Directory('../../third_party/conformance/testcases');

Uint8List readCase(String name) =>
    File('${conformanceDir.path}/$name/input.jxl').readAsBytesSync();

void main() {
  final haveConformance = conformanceDir.existsSync();

  group('JxlInfo.parse on conformance files', () {
    test('grayscale: 200x200 8-bit gray with ICC', () {
      final info = JxlInfo.parse(readCase('grayscale'));
      expect(info.width, 200);
      expect(info.height, 200);
      expect(info.bitsPerSample, 8);
      expect(info.isGrayscale, isTrue);
      expect(info.hasAlpha, isFalse);
      expect(info.usesIccProfile, isTrue);
      expect(info.isXybEncoded, isTrue);
      expect(info.isAnimated, isFalse);
    });

    test('alpha_triangles: 1024x1024 9-bit RGB+alpha, non-XYB', () {
      final info = JxlInfo.parse(readCase('alpha_triangles'));
      expect(info.width, 1024);
      expect(info.height, 1024);
      expect(info.bitsPerSample, 9);
      expect(info.isGrayscale, isFalse);
      expect(info.hasAlpha, isTrue);
      expect(info.extraChannelCount, 1);
      expect(info.isXybEncoded, isFalse);
    });

    test('bench_oriented_brg: orientation 5 transposes output size', () {
      final info = JxlInfo.parse(readCase('bench_oriented_brg'));
      expect(info.orientation, 5);
      expect(info.encodedWidth, 500);
      expect(info.encodedHeight, 606);
      expect(info.width, 606);
      expect(info.height, 500);
    });

    test('animation_icos4d: reports animated', () {
      final info = JxlInfo.parse(readCase('animation_icos4d'));
      expect(info.isAnimated, isTrue);
      expect(info.width, 128);
    });

    test('lossless_pfm: float samples', () {
      final info = JxlInfo.parse(readCase('lossless_pfm'));
      expect(info.usesFloatSamples, isTrue);
      expect(info.bitsPerSample, 32);
      expect(info.exponentBits, 8);
    });

    test('every conformance file parses without error', () {
      final cases = conformanceDir
          .listSync()
          .whereType<Directory>()
          .where((d) => File('${d.path}/input.jxl').existsSync());
      var count = 0;
      for (final dir in cases) {
        final bytes = File('${dir.path}/input.jxl').readAsBytesSync();
        expect(() => JxlInfo.parse(bytes), returnsNormally, reason: dir.path);
        count++;
      }
      expect(count, greaterThanOrEqualTo(39));
    });
  }, skip: haveConformance ? null : 'conformance corpus not present');

  group('truncation', () {
    test('truncated header throws cleanly or parses consistently', () {
      if (!haveConformance) return;
      final bytes = readCase('grayscale');
      final full = JxlInfo.parse(bytes);
      // A short header can legitimately fit in a handful of bytes, so a
      // prefix parse may succeed — but then it must agree with the full
      // parse. Otherwise it must throw a JxlException (never hang/crash).
      for (var len = 0; len < 64; len++) {
        final prefix = Uint8List.sublistView(bytes, 0, len);
        try {
          final info = JxlInfo.parse(prefix);
          expect(info.width, full.width, reason: 'prefix length $len');
          expect(info.height, full.height, reason: 'prefix length $len');
          expect(info.bitsPerSample, full.bitsPerSample,
              reason: 'prefix length $len');
        } on JxlException {
          // expected for most prefix lengths
        }
      }
    });

    test('garbage input throws', () {
      expect(() => JxlInfo.parse(Uint8List.fromList(List.filled(100, 0xAB))),
          throwsA(isA<JxlException>()));
    });
  });
}
