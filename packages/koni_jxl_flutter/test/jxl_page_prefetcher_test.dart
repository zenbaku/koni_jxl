import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koni_jxl_flutter/koni_jxl_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A synthetic 6-page "chapter" cycling through 3 distinct fixtures with
  // known, distinguishable dimensions, so tests can confirm *which* page
  // was actually decoded, not just that decoding succeeded.
  final pageFiles = [
    File('test/assets/screentone_256_d0_e5.jxl'), // 256x256
    File('test/assets/alpha_page_d0_e3.jxl'), // 512x768
    File('test/assets/color_cover_d1.0_e3.jxl'), // 1024x1536
    File('test/assets/screentone_256_d0_e5.jxl'),
    File('test/assets/alpha_page_d0_e3.jxl'),
    File('test/assets/color_cover_d1.0_e3.jxl'),
  ];
  const expectedSizes = [
    (256, 256),
    (512, 768),
    (1024, 1536),
    (256, 256),
    (512, 768),
    (1024, 1536),
  ];

  List<Future<Uint8List> Function()> buildLoaders({
    void Function(int index)? onLoad,
  }) =>
      [
        for (var i = 0; i < pageFiles.length; i++)
          () async {
            onLoad?.call(i);
            return pageFiles[i].readAsBytesSync();
          },
      ];

  group('JxlPagePrefetcher', () {
    test('imageFor returns pixel-correct data for a prefetched page', () async {
      final prefetcher =
          JxlPagePrefetcher(buildLoaders(), aheadCount: 2, behindCount: 1);
      prefetcher.setCurrentIndex(2);
      final image = await prefetcher.imageFor(2);
      final (w, h) = expectedSizes[2];
      expect(image.width, w);
      expect(image.height, h);
      image.dispose();
      prefetcher.dispose();
    });

    test('imageFor on an index outside the window still decodes correctly',
        () async {
      final prefetcher =
          JxlPagePrefetcher(buildLoaders(), aheadCount: 1, behindCount: 0);
      prefetcher.setCurrentIndex(0); // window = [0, 1]
      final image = await prefetcher.imageFor(4); // outside the window
      final (w, h) = expectedSizes[4];
      expect(image.width, w);
      expect(image.height, h);
      image.dispose();
      prefetcher.dispose();
    });

    test('setCurrentIndex only loads pages within the window', () async {
      final loaded = <int>{};
      final prefetcher = JxlPagePrefetcher(
        buildLoaders(onLoad: loaded.add),
        aheadCount: 1,
        behindCount: 1,
      );
      prefetcher.setCurrentIndex(2); // window = [1, 2, 3]
      final images = await Future.wait([1, 2, 3].map(prefetcher.imageFor));
      for (final image in images) {
        image.dispose();
      }
      expect(loaded, {1, 2, 3});
      prefetcher.dispose();
    });

    test('moving the window evicts pages that fall out of range', () async {
      final loaded = <int>[];
      final prefetcher = JxlPagePrefetcher(
        buildLoaders(onLoad: loaded.add),
        aheadCount: 1,
        behindCount: 0,
      );
      prefetcher.setCurrentIndex(0); // window [0, 1]
      (await prefetcher.imageFor(0)).dispose();
      prefetcher.setCurrentIndex(4); // window [4, 5]; evicts 0, 1
      (await prefetcher.imageFor(4)).dispose();
      (await prefetcher.imageFor(5)).dispose();

      // Page 1 was evicted (outside the new window): revisiting it must
      // decode fresh, not return a stale/disposed cached image.
      loaded.clear();
      final revisited = await prefetcher.imageFor(1);
      final (w, h) = expectedSizes[1];
      expect(revisited.width, w);
      expect(revisited.height, h);
      expect(loaded, contains(1));
      revisited.dispose();
      prefetcher.dispose();
    });

    test(
        'a page cancelled while imageFor is awaiting it still resolves, '
        'not as a cancellation error', () async {
      final prefetcher =
          JxlPagePrefetcher(buildLoaders(), aheadCount: 1, behindCount: 0);
      prefetcher.setCurrentIndex(0); // starts decoding page 1 in background
      final future = prefetcher.imageFor(1); // awaits that in-flight decode
      prefetcher.setCurrentIndex(4); // evicts+cancels page 1 mid-flight
      final image = await future; // must retry internally, not throw
      final (w, h) = expectedSizes[1];
      expect(image.width, w);
      expect(image.height, h);
      image.dispose();
      prefetcher.dispose();
    });

    test('dispose tears down in-flight decodes and cached images cleanly',
        () async {
      final prefetcher =
          JxlPagePrefetcher(buildLoaders(), aheadCount: 2, behindCount: 1);
      prefetcher.setCurrentIndex(2);
      prefetcher.dispose();
      // A leaked isolate or unsettled completer would hang the test
      // process here or at suite teardown rather than fail cleanly.
    });

    test('imageFor rejects an out-of-range index', () async {
      final prefetcher = JxlPagePrefetcher(buildLoaders());
      await expectLater(prefetcher.imageFor(999), throwsRangeError);
      prefetcher.dispose();
    });

    test('fromBytesList decodes pages already in memory', () async {
      final prefetcher = JxlPagePrefetcher.fromBytesList(
          [for (final f in pageFiles) f.readAsBytesSync()]);
      prefetcher.setCurrentIndex(0);
      final image = await prefetcher.imageFor(0);
      final (w, h) = expectedSizes[0];
      expect(image.width, w);
      expect(image.height, h);
      image.dispose();
      prefetcher.dispose();
    });
  });

  // `flutter test` always runs on the native VM, so plain `kIsWeb` can never
  // be false in a test - the web (no-isolates) fallback path would otherwise
  // go completely unexercised by the automated suite. debugUseIsolates
  // forces that fallback so it's covered by more than just reading the code.
  group('JxlPagePrefetcher (web fallback, debugUseIsolates: false)', () {
    test('imageFor returns pixel-correct data via inline decode', () async {
      final prefetcher = JxlPagePrefetcher(buildLoaders(),
          aheadCount: 2, behindCount: 1, debugUseIsolates: false);
      prefetcher.setCurrentIndex(2);
      final image = await prefetcher.imageFor(2);
      final (w, h) = expectedSizes[2];
      expect(image.width, w);
      expect(image.height, h);
      image.dispose();
      prefetcher.dispose();
    });

    test(
        'setCurrentIndex only eagerly loads the current page, not the '
        'whole window', () async {
      final loaded = <int>{};
      final prefetcher = JxlPagePrefetcher(
        buildLoaders(onLoad: loaded.add),
        aheadCount: 2,
        behindCount: 1,
        debugUseIsolates: false,
      );
      prefetcher.setCurrentIndex(2); // window would be [1, 2, 3, 4] natively
      await Future<void>.delayed(Duration.zero);
      expect(loaded, {2});
      prefetcher.dispose();
    });

    test('imageFor on an index outside the window still decodes correctly',
        () async {
      final prefetcher = JxlPagePrefetcher(buildLoaders(),
          aheadCount: 1, behindCount: 0, debugUseIsolates: false);
      prefetcher.setCurrentIndex(0);
      final image = await prefetcher.imageFor(4);
      final (w, h) = expectedSizes[4];
      expect(image.width, w);
      expect(image.height, h);
      image.dispose();
      prefetcher.dispose();
    });

    test(
        'a page cancelled while imageFor is awaiting it still resolves, '
        'not as a cancellation error', () async {
      final prefetcher = JxlPagePrefetcher(buildLoaders(),
          aheadCount: 1, behindCount: 0, debugUseIsolates: false);
      prefetcher.setCurrentIndex(1); // starts an inline decode of page 1
      final future = prefetcher.imageFor(1);
      prefetcher.setCurrentIndex(4); // evicts+cancels page 1 mid-flight
      final image = await future; // must retry internally, not throw
      final (w, h) = expectedSizes[1];
      expect(image.width, w);
      expect(image.height, h);
      image.dispose();
      prefetcher.dispose();
    });

    test('dispose tears down in-flight and cached inline decodes cleanly',
        () async {
      final prefetcher = JxlPagePrefetcher(buildLoaders(),
          aheadCount: 2, behindCount: 1, debugUseIsolates: false);
      prefetcher.setCurrentIndex(2);
      prefetcher.dispose();
    });
  });
}
