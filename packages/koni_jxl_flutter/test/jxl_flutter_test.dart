import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koni_jxl_flutter/koni_jxl_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sample = File('test/assets/screentone_256_d0_e5.jxl');
  final alphaSample = File('test/assets/alpha_page_d0_e3.jxl');
  final lossySample = File('test/assets/color_cover_d1.0_e3.jxl');
  final unsupportedSample = File('test/assets/float_samples.jxl');

  group('decodeJxlToUiImage', () {
    test('decodes a lossless grayscale page', () async {
      final image = await decodeJxlToUiImage(sample.readAsBytesSync());
      expect(image.width, 256);
      expect(image.height, 256);
      image.dispose();
    });

    test('decodes an image with alpha', () async {
      final image = await decodeJxlToUiImage(alphaSample.readAsBytesSync());
      expect(image.width, 512);
      expect(image.height, 768);
      image.dispose();
    });

    test('decodes a lossy (VarDCT) image', () async {
      final image = await decodeJxlToUiImage(lossySample.readAsBytesSync());
      expect(image.width, 1024);
      expect(image.height, 1536);
      image.dispose();
    });

    test('propagates JxlUnsupportedException for unsupported features',
        () async {
      await expectLater(
        decodeJxlToUiImage(unsupportedSample.readAsBytesSync()),
        throwsA(isA<JxlUnsupportedException>()
            .having((e) => e.feature, 'feature', 'float-samples')),
      );
    });
  });

  group('decodeJxlAnimation', () {
    test('decodes all frames of an animated file', () async {
      final anim = await decodeJxlAnimation(
          File('test/assets/anim_d0.jxl').readAsBytesSync());
      expect(anim.frames.length, 4);
      expect(anim.isAnimated, isTrue);
      expect(anim.numLoops, 0);
      expect(anim.frameDurations.first, const Duration(milliseconds: 100));
      expect(anim.frames.first.width, 64);
      expect(anim.frames.first.height, 48);
      anim.dispose();
    });

    test('still image yields a single frame', () async {
      final anim = await decodeJxlAnimation(sample.readAsBytesSync());
      expect(anim.frames.length, 1);
      expect(anim.isAnimated, isFalse);
      anim.dispose();
    });
  });

  group('decodeJxlProgressive', () {
    Stream<List<int>> chunked(Uint8List bytes, int size) async* {
      for (var off = 0; off < bytes.length; off += size) {
        yield bytes.sublist(
            off, off + size > bytes.length ? bytes.length : off + size);
      }
    }

    test('VarDCT stream emits preview then final', () async {
      final bytes = lossySample.readAsBytesSync();
      final images = await decodeJxlProgressive(chunked(bytes, 1024)).toList();
      expect(images.length, 2);
      expect(images[0].width, (images[1].width + 7) ~/ 8);
      expect(images[0].height, (images[1].height + 7) ~/ 8);
      expect(images[1].width, 1024);
      expect(images[1].height, 1536);
      for (final i in images) {
        i.dispose();
      }
    });

    test('lossless stream emits only the final image', () async {
      final bytes = sample.readAsBytesSync();
      final images = await decodeJxlProgressive(chunked(bytes, 997)).toList();
      expect(images.length, 1);
      expect(images.single.width, 256);
      images.single.dispose();
    });

    test('truncated stream reports an error', () async {
      final bytes = lossySample.readAsBytesSync();
      await expectLater(
        decodeJxlProgressive(chunked(bytes.sublist(0, bytes.length ~/ 2), 1024))
            .toList(),
        throwsStateError,
      );
    });
  });

  group('encodeJxlFromRgba', () {
    test('round-trips through the decoder', () async {
      const w = 40, h = 30;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < rgba.length; i++) {
        rgba[i] = (i * 7) & 255;
      }
      final encoded = await encodeJxlFromRgba(rgba, width: w, height: h);
      final image = JxlDecoder.decode(encoded);
      expect(image.width, w);
      expect(image.height, h);
      expect(image.toRgba8(), rgba);
    });
  });

  group('JxlImageProvider', () {
    test('memory provider resolves an ImageInfo with correct size', () async {
      final provider = JxlImageProvider.memory(sample.readAsBytesSync());
      final completer = Completer<ImageInfo>();
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) => completer.complete(info),
        onError: (error, stack) => completer.completeError(error, stack),
      );
      stream.addListener(listener);
      final info = await completer.future;
      expect(info.image.width, 256);
      expect(info.image.height, 256);
      stream.removeListener(listener);
      info.dispose();
    });

    test('file provider resolves', () async {
      final provider = JxlImageProvider.file(alphaSample);
      final completer = Completer<ImageInfo>();
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) => completer.complete(info),
        onError: (error, stack) => completer.completeError(error, stack),
      );
      stream.addListener(listener);
      final info = await completer.future;
      expect(info.image.width, 512);
      stream.removeListener(listener);
      info.dispose();
    });

    test('reports decode errors through the image stream', () async {
      final provider =
          JxlImageProvider.memory(unsupportedSample.readAsBytesSync());
      final completer = Completer<Object>();
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) => completer.completeError(StateError('unexpected success')),
        onError: (error, stack) => completer.complete(error),
      );
      stream.addListener(listener);
      final error = await completer.future;
      expect(error, isA<JxlUnsupportedException>());
      stream.removeListener(listener);
    });

    test('equality keys the image cache correctly', () {
      final bytes = sample.readAsBytesSync();
      expect(JxlImageProvider.memory(bytes), JxlImageProvider.memory(bytes));
      expect(JxlImageProvider.asset('a.jxl'), JxlImageProvider.asset('a.jxl'));
      expect(JxlImageProvider.asset('a.jxl'),
          isNot(JxlImageProvider.asset('b.jxl')));
    });
  });
}
