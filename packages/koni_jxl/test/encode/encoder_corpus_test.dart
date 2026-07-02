import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// Encoder gate over real corpus content: every 8-bit golden (the original
/// pixels of the lossless corpus) must re-encode and round-trip bit-exact
/// through our decoder and djxl.
final goldenDir = Directory('../../third_party/corpus/golden');

final _haveDjxl = (() {
  try {
    return Process.runSync('djxl', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
})();

void main() {
  final haveCorpus = goldenDir.existsSync();
  if (!haveCorpus) {
    test('corpus not generated', () {},
        skip: 'run tool/gen_corpus.py to enable the encoder corpus gate');
    return;
  }
  final goldens = goldenDir
      .listSync()
      .whereType<File>()
      .where((f) =>
          (f.path.endsWith('.pgm') || f.path.endsWith('.ppm')) &&
          f.path.contains('_d0_') &&
          f.path.contains('_e7'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final golden in goldens) {
    final stem = golden.uri.pathSegments.last;
    test('re-encode $stem', () {
      final ref = PnmImage.parse(golden.readAsBytesSync());
      if (ref.maxValue != 255) return; // 16-bit sources: not yet supported
      final gray = ref.channels == 1;
      final n = ref.channels;
      final pixels = Uint8List(ref.width * ref.height * n);
      for (var c = 0; c < n; c++) {
        final plane = ref.intPlanes![c];
        for (var i = 0; i < plane.length; i++) {
          pixels[i * n + c] = plane[i];
        }
      }
      final encoded = JxlEncoder.encodeLossless(pixels,
          width: ref.width, height: ref.height, grayscale: gray);

      final image = JxlDecoder.decode(encoded);
      for (var c = 0; c < n; c++) {
        expect(channelAsInts(image.channels[c], 255), ref.intPlanes![c],
            reason: 'our decoder, channel $c');
      }

      if (_haveDjxl) {
        final dir = Directory.systemTemp.createTempSync('koni_enc');
        try {
          final jxlPath = '${dir.path}/t.jxl';
          final outPath = '${dir.path}/t.${gray ? 'pgm' : 'ppm'}';
          File(jxlPath).writeAsBytesSync(encoded);
          final r =
              Process.runSync('djxl', [jxlPath, outPath, '--num_threads', '1']);
          expect(r.exitCode, 0, reason: 'djxl: ${r.stderr}');
          final theirs = PnmImage.parse(File(outPath).readAsBytesSync());
          for (var c = 0; c < n; c++) {
            expect(theirs.intPlanes![c], ref.intPlanes![c],
                reason: 'djxl, channel $c');
          }
        } finally {
          dir.deleteSync(recursive: true);
        }
      }
    });
  }
}
