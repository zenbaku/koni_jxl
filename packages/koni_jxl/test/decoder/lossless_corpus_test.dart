@TestOn('vm')
library;

import 'dart:io';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// M2/M3 gate: every lossless corpus file must decode bit-exact against its
/// djxl golden (PGM/PPM/PAM).
final corpusDir = Directory('../../third_party/corpus/jxl');
final goldenDir = Directory('../../third_party/corpus/golden');

void main() {
  final haveCorpus = corpusDir.existsSync() && goldenDir.existsSync();

  group('lossless corpus vs djxl goldens', () {
    if (!haveCorpus) return;
    final files = corpusDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jxl') && f.path.contains('_d0_'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final stem = file.uri.pathSegments.last.replaceAll('.jxl', '');
      final golden = ['pgm', 'ppm', 'pam']
          .map((ext) => File('${goldenDir.path}/$stem.$ext'))
          .where((f) => f.existsSync())
          .firstOrNull;
      test(stem, () {
        if (golden == null) fail('no golden found for $stem');
        final image = JxlDecoder.decode(file.readAsBytesSync());
        final ref = PnmImage.parse(golden.readAsBytesSync());
        expect(image.width, ref.width, reason: 'width');
        expect(image.height, ref.height, reason: 'height');
        expect(image.channels.length, greaterThanOrEqualTo(ref.channels),
            reason: 'channel count');
        for (var c = 0; c < ref.channels; c++) {
          final ours = channelAsInts(image.channels[c], ref.maxValue);
          final theirs = ref.intPlanes![c];
          expect(ours.length, theirs.length);
          for (var i = 0; i < ours.length; i++) {
            if (ours[i] != theirs[i]) {
              final y = i ~/ ref.width;
              final x = i % ref.width;
              fail('pixel mismatch in $stem channel $c at ($x, $y): '
                  'ours=${ours[i]} djxl=${theirs[i]}');
            }
          }
        }
      });
    }
  }, skip: haveCorpus ? null : 'local corpus not generated');
}
