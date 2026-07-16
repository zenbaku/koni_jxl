@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:koni_jxl/src/header/image_header.dart';
import 'package:koni_jxl/src/icc/icc_codec.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/container.dart';
import 'package:test/test.dart';

/// M1 gate: for every conformance file whose codestream embeds an ICC
/// profile, our decoded profile must be byte-identical (sha256) to the
/// `original.icc` recorded in the conformance test.json.
final conformanceDir = Directory('../../third_party/conformance/testcases');

void main() {
  final haveConformance = conformanceDir.existsSync();

  group('ICC decode vs conformance sha256', () {
    if (!haveConformance) return;
    var tested = 0;
    for (final dir in conformanceDir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path))) {
      final inputFile = File('${dir.path}/input.jxl');
      final testJson = File('${dir.path}/test.json');
      if (!inputFile.existsSync() || !testJson.existsSync()) continue;

      final config =
          jsonDecode(testJson.readAsStringSync()) as Map<String, dynamic>;
      final sums = config['sha256sums'] as Map<String, dynamic>?;
      final expected = sums?['original.icc'] as String?;
      if (expected == null) continue;

      test(dir.path.split('/').last, () {
        final demuxed = demuxContainer(inputFile.readAsBytesSync());
        final reader = BitReader(demuxed.codestream);
        final header = ImageHeader.read(reader, level: demuxed.level);
        if (header.iccEncodedSize == null) {
          // No embedded ICC in the codestream; original.icc refers to the
          // serialized enum color encoding instead. Out of scope here.
          return;
        }
        final encoded =
            IccCodec.readEncodedStream(reader, header.iccEncodedSize!);
        reader.zeroPadToByte();
        final icc = IccCodec.decompress(encoded);
        expect(sha256.convert(icc).toString(), expected,
            reason: '${dir.path} ICC mismatch (${icc.length} bytes)');
        tested++;
      });
    }
    tearDownAll(() {
      // At least the known-ICC cases must actually have been exercised.
      expect(tested, greaterThanOrEqualTo(2),
          reason: 'expected to verify ICC bytes on at least 2 files');
    });
  }, skip: haveConformance ? null : 'conformance corpus not present');
}
