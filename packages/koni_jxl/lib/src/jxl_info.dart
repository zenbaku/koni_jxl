import 'dart:typed_data';

import 'color/color_encoding.dart';
import 'header/extra_channel.dart';
import 'header/image_header.dart';
import 'io/bit_reader.dart';
import 'io/container.dart';

/// Header-level information about a JPEG XL image, parsed without decoding
/// any pixels. Cheap: reads only the first few hundred bytes.
final class JxlInfo {
  /// Parses the image header from [bytes] (bare codestream or container).
  ///
  /// Throws a [JxlException] subtype on malformed input.
  factory JxlInfo.parse(Uint8List bytes) {
    final demuxed = demuxContainer(bytes);
    final reader = BitReader(demuxed.codestream);
    final header = ImageHeader.read(reader, level: demuxed.level);
    return JxlInfo._(header, demuxed.isContainer);
  }

  JxlInfo._(this._header, this.isContainer);

  /// Internal: wraps an already-parsed header (streaming decoder).
  JxlInfo.internal(this._header, this.isContainer);

  final ImageHeader _header;

  /// Whether the file used the ISOBMFF container format.
  final bool isContainer;

  /// Output width after orientation (the size callers should allocate).
  int get width => _header.orientedSize.width;

  /// Output height after orientation.
  int get height => _header.orientedSize.height;

  /// Width as stored in the codestream, before orientation is applied.
  int get encodedWidth => _header.size.width;

  /// Height as stored in the codestream, before orientation is applied.
  int get encodedHeight => _header.size.height;

  int get bitsPerSample => _header.bitDepth.bitsPerSample;
  bool get usesFloatSamples => _header.bitDepth.usesFloatSamples;
  int get exponentBits => _header.bitDepth.expBits;

  /// EXIF-style orientation (1–8) already applied to [width]/[height].
  int get orientation => _header.orientation;

  bool get isGrayscale => _header.isGrayscale;
  bool get hasAlpha => _header.hasAlpha;

  bool get alphaPremultiplied =>
      _header.alphaIndices.isNotEmpty &&
      _header.extraChannels[_header.alphaIndices.first].alphaAssociated;

  int get extraChannelCount => _header.extraChannels.length;
  bool get isAnimated => _header.isAnimated;

  /// Whether the color channels are XYB-encoded (true implies lossy).
  bool get isXybEncoded => _header.xybEncoded;

  bool get usesIccProfile => _header.colorEncoding.useIccProfile;

  /// Conformance level (5 or 10).
  int get level => _header.level;

  double get intensityTarget => _header.toneMapping.intensityTarget;

  /// Human-readable color encoding summary.
  String get colorDescription {
    final ce = _header.colorEncoding;
    if (ce.useIccProfile) return 'ICC profile';
    final space = switch (ce.colorEncoding) {
      ColorFlags.ceGray => 'Grayscale',
      ColorFlags.ceRgb => 'RGB',
      ColorFlags.ceXyb => 'XYB',
      _ => 'Unknown',
    };
    return '$space, ${ColorFlags.whitePointToString(ce.whitePoint)}, '
        '${ColorFlags.primariesToString(ce.primaries)} primaries, '
        '${ColorFlags.transferToString(ce.tf)} transfer';
  }

  /// Names/types of extra channels, e.g. `['Alpha']`.
  List<String> get extraChannelDescriptions => [
        for (final ec in _header.extraChannels)
          ec.name.isNotEmpty
              ? '${ExtraChannelType.toDisplayString(ec.type)} (${ec.name})'
              : ExtraChannelType.toDisplayString(ec.type),
      ];

  /// The parsed header, for internal decoder use.
  ImageHeader get header => _header;

  @override
  String toString() => 'JxlInfo(${width}x$height, $bitsPerSample-bit, '
      '${isGrayscale ? 'grayscale' : 'RGB'}'
      '${hasAlpha ? '+alpha' : ''}'
      '${isAnimated ? ', animated' : ''})';
}
