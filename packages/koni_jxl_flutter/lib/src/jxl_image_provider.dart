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
class JxlImageProvider extends ImageProvider<JxlImageProvider> {
  /// Decodes .jxl bytes already in memory.
  JxlImageProvider.memory(Uint8List bytes, {this.scale = 1.0})
      : _load = (() => SynchronousFuture(bytes)),
        _identity = bytes;

  /// Decodes a .jxl file from disk.
  JxlImageProvider.file(File file, {this.scale = 1.0})
      : _load = file.readAsBytes,
        _identity = file.path;

  /// Decodes a .jxl asset from the given [bundle] (or the root bundle).
  JxlImageProvider.asset(String assetName,
      {AssetBundle? bundle, this.scale = 1.0})
      : _load = (() async {
          final data = await (bundle ?? rootBundle).load(assetName);
          return data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes);
        }),
        _identity = assetName;

  final double scale;
  final Future<Uint8List> Function() _load;
  final Object _identity;

  @override
  Future<JxlImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<JxlImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
      JxlImageProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load().then(decodeJxlToUiCodec),
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
      other.scale == scale;

  @override
  int get hashCode => Object.hash(_identity, scale);

  @override
  String toString() =>
      'JxlImageProvider(${_identity is String ? _identity : 'memory'}, '
      'scale: $scale)';
}
