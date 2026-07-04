import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:koni_jxl/koni_jxl.dart';

/// A decode failure that occurred in a background isolate. The original
/// [JxlException] subtype can't cross the isolate boundary as-is (it's a
/// sealed hierarchy reconstructed only through its concrete subtypes), so
/// only the message survives.
final class JxlPageDecodeException implements Exception {
  const JxlPageDecodeException(this.message);

  final String message;

  @override
  String toString() => 'JxlPageDecodeException: $message';
}

final class _CancelledException implements Exception {
  const _CancelledException();
}

sealed class _CacheEntry {}

final class _Pending extends _CacheEntry {
  _Pending(this.completer) {
    // A page can be evicted/cancelled before anyone ever calls imageFor
    // on it (prefetched but never displayed): completer.completeError
    // would then complete a future with zero listeners, which Dart
    // reports as an unhandled async error. This safety listener doesn't
    // stop imageFor's own await from seeing the same error - Futures
    // broadcast to every listener independently - it just marks the
    // error as observed so an unlistened cancellation doesn't crash.
    completer.future.ignore();
  }

  final Completer<ui.Image> completer;
  Isolate? isolate;
  ReceivePort? resultPort;
  ReceivePort? exitPort;
}

final class _Ready extends _CacheEntry {
  _Ready(this.image);

  final ui.Image image;
}

/// Runs on a freshly spawned isolate: decodes [bytes] and sends the result
/// back (as a tagged record, not a thrown exception - see
/// [JxlPageDecodeException]) before terminating via [Isolate.exit], which
/// sends the final message and dies atomically.
void _decodeEntryPoint((SendPort, Uint8List) args) {
  final (port, bytes) = args;
  try {
    final image = JxlDecoder.decode(bytes);
    Isolate.exit(port, ('ok', image.toRgba8(), image.width, image.height));
  } catch (e) {
    Isolate.exit(port, ('error', e.toString()));
  }
}

/// Mirrors `jxl_codec.dart`'s private `_rgbaToUiImage` (not reused directly:
/// the barrel file exports that file wholesale, so un-privating it would
/// leak new public API from an already-published package).
Future<ui.Image> _rgbaToUiImage(Uint8List pixels, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

/// Decodes upcoming pages of a sequential JPEG XL reader (manga chapter,
/// document, etc.) on background isolates ahead of when they're displayed.
///
/// [setCurrentIndex] should be called whenever the reader navigates; it
/// keeps a `[index - behindCount, index + aheadCount]` window of pages
/// decoded (or decoding), cancelling in-flight decodes and evicting cached
/// results for pages that fall outside the window. [imageFor] returns the
/// decoded image for a page, whether or not it was prefetched.
///
/// Only pays off on native platforms: `dart2js`/`dart2wasm` have no
/// isolates ([Isolate.spawn] throws `UnsupportedError` there), so on the
/// web this degrades to decoding the current page on demand, with no real
/// background work and no cancellation (nothing is ever truly in flight).
class JxlPagePrefetcher {
  JxlPagePrefetcher(
    List<Future<Uint8List> Function()> pageLoaders, {
    this.aheadCount = 2,
    this.behindCount = 1,
    @visibleForTesting bool? debugUseIsolates,
  })  : assert(aheadCount >= 0),
        assert(behindCount >= 0),
        _loaders = pageLoaders,
        _useIsolates = debugUseIsolates ?? !kIsWeb;

  /// Decodes pages already in memory.
  factory JxlPagePrefetcher.fromBytesList(
    List<Uint8List> pages, {
    int aheadCount = 2,
    int behindCount = 1,
    @visibleForTesting bool? debugUseIsolates,
  }) =>
      JxlPagePrefetcher(
        [for (final bytes in pages) () => SynchronousFuture(bytes)],
        aheadCount: aheadCount,
        behindCount: behindCount,
        debugUseIsolates: debugUseIsolates,
      );

  /// Decodes pages from files on disk.
  factory JxlPagePrefetcher.fromFiles(
    List<File> files, {
    int aheadCount = 2,
    int behindCount = 1,
    @visibleForTesting bool? debugUseIsolates,
  }) =>
      JxlPagePrefetcher(
        [for (final file in files) file.readAsBytes],
        aheadCount: aheadCount,
        behindCount: behindCount,
        debugUseIsolates: debugUseIsolates,
      );

  /// Decodes pages from assets in [bundle] (or the root bundle).
  factory JxlPagePrefetcher.fromAssets(
    List<String> assetNames, {
    AssetBundle? bundle,
    int aheadCount = 2,
    int behindCount = 1,
    @visibleForTesting bool? debugUseIsolates,
  }) =>
      JxlPagePrefetcher(
        [
          for (final name in assetNames)
            () async {
              final data = await (bundle ?? rootBundle).load(name);
              return data.buffer
                  .asUint8List(data.offsetInBytes, data.lengthInBytes);
            },
        ],
        aheadCount: aheadCount,
        behindCount: behindCount,
        debugUseIsolates: debugUseIsolates,
      );

  /// How many pages ahead of the current one to keep decoded.
  final int aheadCount;

  /// How many pages behind the current one to keep decoded.
  final int behindCount;

  /// Whether to use background isolates (native) or decode inline on
  /// demand (web, or forced off for testing that fallback path on the
  /// VM — `flutter test` always runs native, so `kIsWeb` alone can never
  /// exercise it).
  final bool _useIsolates;

  final List<Future<Uint8List> Function()> _loaders;
  final Map<int, _CacheEntry> _cache = {};
  int _currentIndex = 0;

  int get pageCount => _loaders.length;
  int get currentIndex => _currentIndex;

  /// Call whenever the reader navigates to [index]. Synchronous and
  /// fire-and-forget: it only ever diffs against already-settled cache
  /// state, so rapid repeated calls can't double-spawn or leave stale
  /// reconciliation state behind.
  void setCurrentIndex(int index) {
    _currentIndex = index.clamp(0, pageCount - 1);
    final lo = (_currentIndex - behindCount).clamp(0, pageCount - 1);
    final hi = (_currentIndex + aheadCount).clamp(0, pageCount - 1);
    final window = {for (var i = lo; i <= hi; i++) i};

    for (final i in _cache.keys.toList()) {
      if (!window.contains(i)) _evict(i);
    }

    if (!_useIsolates) {
      // No isolates on the web: eagerly decoding the whole window would
      // just multiply main-thread jank by aheadCount + behindCount, with
      // none of the background-decode benefit. Only ensure the page
      // actually being shown is decoded (or decoding).
      if (!_cache.containsKey(_currentIndex)) _startDecode(_currentIndex);
      return;
    }
    for (final i in window) {
      if (!_cache.containsKey(i)) _startDecode(i);
    }
  }

  /// The decoded image for page [index] - a clone the caller owns and must
  /// dispose. Returns the cached result if ready, awaits an in-flight
  /// decode if one is running, or starts one on demand if [index] isn't
  /// cached at all (e.g. a direct jump ahead of [setCurrentIndex]'s
  /// window).
  Future<ui.Image> imageFor(int index) async {
    RangeError.checkValidIndex(index, _loaders, 'index', pageCount);
    while (true) {
      final entry = _cache[index];
      if (entry is _Ready) return entry.image.clone();
      if (entry is _Pending) {
        try {
          return (await entry.completer.future).clone();
        } on _CancelledException {
          continue;
        }
      }
      _startDecode(index);
    }
  }

  /// Cancels all in-flight decodes and disposes all cached images.
  void dispose() {
    for (final i in _cache.keys.toList()) {
      _evict(i);
    }
  }

  void _startDecode(int index) {
    final pending = _Pending(Completer<ui.Image>());
    _cache[index] = pending;
    if (_useIsolates) {
      unawaited(_spawnDecode(index, pending));
    } else {
      unawaited(_decodeInline(index, pending));
    }
  }

  Future<void> _decodeInline(int index, _Pending pending) async {
    try {
      final bytes = await _loaders[index]();
      final image = JxlDecoder.decode(bytes);
      final uiImage =
          await _rgbaToUiImage(image.toRgba8(), image.width, image.height);
      if (identical(_cache[index], pending)) {
        _cache[index] = _Ready(uiImage);
        pending.completer.complete(uiImage);
      } else {
        uiImage.dispose();
      }
    } catch (e) {
      if (identical(_cache[index], pending)) _cache.remove(index);
      if (!pending.completer.isCompleted) pending.completer.completeError(e);
    }
  }

  Future<void> _spawnDecode(int index, _Pending pending) async {
    final Uint8List bytes;
    try {
      bytes = await _loaders[index]();
    } catch (e) {
      if (identical(_cache[index], pending)) _cache.remove(index);
      if (!pending.completer.isCompleted) pending.completer.completeError(e);
      return;
    }
    if (!identical(_cache[index], pending)) return; // evicted while loading

    final resultPort = ReceivePort();
    final exitPort = ReceivePort();

    // Isolate.exit sends its final message and then triggers onExit as
    // part of the same shutdown, so a legitimate ('ok', ...)/('error', ...)
    // message and the onExit port's (unavoidably raceable) notification can
    // both be in flight together. resultReceived is set synchronously, on
    // the first message resultPort delivers, before any await - so even
    // though the 'ok' branch below finishes settling asynchronously (it
    // awaits _rgbaToUiImage), a same-turn onExit notification still sees
    // it and no-ops instead of overwriting a real result with a spurious
    // "exited unexpectedly" error.
    var resultReceived = false;

    void settle(Object? message) {
      if (!identical(_cache[index], pending) || pending.completer.isCompleted) {
        resultPort.close();
        exitPort.close();
        return;
      }
      resultPort.close();
      exitPort.close();
      switch (message) {
        case ('ok', final Uint8List rgba, final int width, final int height):
          _rgbaToUiImage(rgba, width, height).then((uiImage) {
            if (identical(_cache[index], pending)) {
              _cache[index] = _Ready(uiImage);
              pending.completer.complete(uiImage);
            } else {
              uiImage.dispose();
            }
          });
        case ('error', final String msg):
          _cache.remove(index);
          pending.completer.completeError(JxlPageDecodeException(msg));
        default:
          _cache.remove(index);
          pending.completer.completeError(const JxlPageDecodeException(
              'decode isolate exited unexpectedly'));
      }
    }

    resultPort.listen((message) {
      resultReceived = true;
      settle(message);
    });
    exitPort.listen((_) {
      if (!resultReceived && !pending.completer.isCompleted) settle(null);
    });

    final isolate = await Isolate.spawn(
      _decodeEntryPoint,
      (resultPort.sendPort, bytes),
      onExit: exitPort.sendPort,
      errorsAreFatal: true,
    );
    pending.isolate = isolate;
    pending.resultPort = resultPort;
    pending.exitPort = exitPort;
    if (!identical(_cache[index], pending)) {
      // Evicted while spawning: nothing subscribed to the result yet, so
      // just tear the isolate down directly.
      isolate.kill(priority: Isolate.immediate);
      resultPort.close();
      exitPort.close();
    }
  }

  void _evict(int index) {
    final entry = _cache.remove(index);
    switch (entry) {
      case final _Pending p:
        p.isolate?.kill(priority: Isolate.immediate);
        p.resultPort?.close();
        p.exitPort?.close();
        if (!p.completer.isCompleted) {
          p.completer.completeError(const _CancelledException());
        }
      case final _Ready r:
        r.image.dispose();
      case null:
        break;
    }
  }
}
