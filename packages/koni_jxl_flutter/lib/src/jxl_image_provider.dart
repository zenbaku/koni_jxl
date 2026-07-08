import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'jxl_codec.dart';

/// An [ImageProvider] that decodes JPEG XL images with the pure-Dart
/// koni_jxl decoder.
///
/// ```dart
/// Image(image: JxlImageProvider.asset('assets/page.jxl'))
/// Image(image: JxlImageProvider.file(File('/path/page.jxl')))
/// Image(image: JxlImageProvider.memory(jxlBytes))
/// ```
///
/// Decoding runs in a background isolate; results participate in Flutter's
/// [ImageCache] like any other provider. Animated JPEG XL plays with its
/// frame timing and loop count, exactly like an engine-decoded GIF/APNG
/// (via [decodeJxlToUiCodec]).
///
/// [cacheWidth]/[cacheHeight] request a reduced-resolution decode for
/// thumbnail/grid views: the decode never exceeds that box (fit-within,
/// aspect-preserving, never upscaled), and for eligible images skips the bulk
/// of decode work rather than decoding fully and shrinking — see
/// `JxlDecoder.decode`. Pass them here instead of wrapping in `ResizeImage`,
/// which has no effect on JXL bytes (they never reach the engine's decode
/// callback). They participate in the provider's identity, so the same file at
/// two target sizes caches as two distinct entries.
class JxlImageProvider extends ImageProvider<JxlImageProvider> {
  /// Decodes .jxl bytes already in memory.
  JxlImageProvider.memory(Uint8List bytes,
      {this.scale = 1.0, this.cacheWidth, this.cacheHeight})
      : _load = (() => SynchronousFuture(bytes)),
        _identity = bytes {
    _assertCacheDims();
  }

  /// Decodes a .jxl file from disk.
  JxlImageProvider.file(File file,
      {this.scale = 1.0, this.cacheWidth, this.cacheHeight})
      : _load = file.readAsBytes,
        _identity = file.path {
    _assertCacheDims();
  }

  /// Decodes a .jxl asset from the given [bundle] (or the root bundle).
  JxlImageProvider.asset(String assetName,
      {AssetBundle? bundle,
      this.scale = 1.0,
      this.cacheWidth,
      this.cacheHeight})
      : _load = (() async {
          final data = await (bundle ?? rootBundle).load(assetName);
          return data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes);
        }),
        _identity = assetName {
    _assertCacheDims();
  }

  final double scale;

  /// Cap the decoded width; see the class doc. Null means native width.
  final int? cacheWidth;

  /// Cap the decoded height; see the class doc. Null means native height.
  final int? cacheHeight;

  final Future<Uint8List> Function() _load;
  final Object _identity;

  void _assertCacheDims() {
    assert(cacheWidth == null || cacheWidth! > 0,
        'cacheWidth must be positive when set');
    assert(cacheHeight == null || cacheHeight! > 0,
        'cacheHeight must be positive when set');
  }

  @override
  Future<JxlImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<JxlImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
      JxlImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load().then((bytes) => decodeJxlToUiCodec(bytes,
          cacheWidth: cacheWidth, cacheHeight: cacheHeight)),
      scale: scale,
      debugLabel: toString(),
      informationCollector: () => [
        DiagnosticsProperty<JxlImageProvider>('Image provider', this),
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JxlImageProvider &&
      other._identity == _identity &&
      other.scale == scale &&
      other.cacheWidth == cacheWidth &&
      other.cacheHeight == cacheHeight;

  @override
  int get hashCode => Object.hash(_identity, scale, cacheWidth, cacheHeight);

  @override
  String toString() =>
      'JxlImageProvider(${_identity is String ? _identity : 'memory'}, '
      'scale: $scale, cacheWidth: $cacheWidth, cacheHeight: $cacheHeight)';
}
