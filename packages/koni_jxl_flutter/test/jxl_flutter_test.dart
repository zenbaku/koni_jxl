import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koni_jxl_flutter/koni_jxl_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sample = File('test/assets/screentone_256_d0_e5.jxl');
  final alphaSample = File('test/assets/alpha_page_d0_e3.jxl');
  final lossySample = File('test/assets/color_cover_d1.0_e3.jxl');

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

    test('propagates JxlUnsupportedException for VarDCT input', () async {
      await expectLater(
        decodeJxlToUiImage(lossySample.readAsBytesSync()),
        throwsA(isA<JxlUnsupportedException>()
            .having((e) => e.feature, 'feature', 'vardct')),
      );
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
      final provider = JxlImageProvider.memory(lossySample.readAsBytesSync());
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
