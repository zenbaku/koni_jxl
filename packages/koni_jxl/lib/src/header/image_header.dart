import 'dart:typed_data';

import '../color/color_encoding.dart';
import '../color/opsin_inverse.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import 'animation.dart';
import 'bit_depth.dart';
import 'extensions.dart';
import 'extra_channel.dart';
import 'upsampling_weights.dart';

/// An image size in pixels.
typedef SizeDim = ({int width, int height});

/// The JPEG XL image-level header: signature, SizeHeader, ImageMetadata and
/// the trailing default-transform data.
///
/// If [colorEncoding.useIccProfile] is set, the entropy-coded ICC payload
/// begins at the reader position right after [ImageHeader.read] returns
/// ([iccEncodedSize] bytes once decoded); the caller must consume it and then
/// call `zeroPadToByte`. Without an ICC profile the header is already
/// byte-aligned on return.
final class ImageHeader {
  static const codestreamHeader = 0x0AFF;

  static int _widthFromRatio(int ratio, int height) => switch (ratio) {
        1 => height,
        2 => height * 6 ~/ 5,
        3 => height * 4 ~/ 3,
        4 => height * 3 ~/ 2,
        5 => height * 16 ~/ 9,
        6 => height * 5 ~/ 4,
        7 => height * 2,
        _ => throw const JxlInvalidBitstreamException('invalid ratio'),
      };

  static SizeDim _readSizeHeader(BitReader reader, int level) {
    final div8 = reader.readBool();
    final height = div8
        ? (1 + reader.readBits(5)) << 3
        : reader.readU32(1, 9, 1, 13, 1, 18, 1, 30);
    final ratio = reader.readBits(3);
    final int width;
    if (ratio != 0) {
      width = _widthFromRatio(ratio, height);
    } else {
      width = div8
          ? (1 + reader.readBits(5)) << 3
          : reader.readU32(1, 9, 1, 13, 1, 18, 1, 30);
    }
    final maxDim = level <= 5 ? 1 << 18 : 1 << 28;
    final maxTimes = level <= 5 ? 1 << 30 : 1 << 40;
    if (width > maxDim || height > maxDim) {
      throw JxlInvalidBitstreamException(
          'width or height too large for level $level: ${width}x$height');
    }
    if (width * height > maxTimes) {
      throw JxlInvalidBitstreamException(
          'width times height too large for level $level: ${width}x$height');
    }
    return (width: width, height: height);
  }

  static SizeDim _readPreviewHeader(BitReader reader) {
    final div8 = reader.readBool();
    final height = div8
        ? reader.readU32(16, 0, 32, 0, 1, 5, 33, 9)
        : reader.readU32(1, 6, 65, 8, 321, 10, 1345, 12);
    final ratio = reader.readBits(3);
    final int width;
    if (ratio != 0) {
      width = _widthFromRatio(ratio, height);
    } else {
      width = div8
          ? reader.readU32(16, 0, 32, 0, 1, 5, 33, 9)
          : reader.readU32(1, 6, 65, 8, 321, 10, 1345, 12);
    }
    if (width > 4096 || height > 4096) {
      throw JxlInvalidBitstreamException('preview too large: ${width}x$height');
    }
    return (width: width, height: height);
  }

  factory ImageHeader.read(BitReader reader, {int level = 5}) {
    if (level != 5 && level != 10) {
      throw JxlInvalidBitstreamException('invalid level: $level');
    }
    if (reader.readBits(16) != codestreamHeader) {
      throw const JxlInvalidBitstreamException(
          'not a JXL codestream: 0xFF0A magic mismatch');
    }
    final size = _readSizeHeader(reader, level);

    final allDefault = reader.readBool();
    final extraFields = !allDefault && reader.readBool();

    var orientation = 1;
    SizeDim? intrinsicSize;
    SizeDim? previewSize;
    AnimationHeader? animation;
    if (extraFields) {
      orientation = 1 + reader.readBits(3);
      if (reader.readBool()) intrinsicSize = _readSizeHeader(reader, level);
      if (reader.readBool()) previewSize = _readPreviewHeader(reader);
      if (reader.readBool()) animation = AnimationHeader.read(reader);
    }

    final BitDepthHeader bitDepth;
    final bool modular16BitBuffers;
    final List<ExtraChannelInfo> extraChannels;
    final bool xybEncoded;
    final ColorEncodingBundle colorEncoding;
    if (allDefault) {
      bitDepth = const BitDepthHeader();
      modular16BitBuffers = true;
      extraChannels = const [];
      xybEncoded = true;
      colorEncoding = const ColorEncodingBundle();
    } else {
      bitDepth = BitDepthHeader.read(reader);
      modular16BitBuffers = reader.readBool();
      final extraChannelCount = reader.readU32(0, 0, 1, 0, 2, 4, 1, 12);
      extraChannels = List.generate(
          extraChannelCount, (_) => ExtraChannelInfo.read(reader));
      xybEncoded = reader.readBool();
      colorEncoding = ColorEncodingBundle.read(reader);
    }
    final alphaIndices = <int>[
      for (var i = 0; i < extraChannels.length; i++)
        if (extraChannels[i].type == ExtraChannelType.alpha) i,
    ];

    final toneMapping =
        extraFields ? ToneMapping.read(reader) : const ToneMapping();
    final extensions =
        allDefault ? const Extensions() : Extensions.read(reader);

    final defaultMatrix = reader.readBool();
    final opsinInverseMatrix = !defaultMatrix && xybEncoded
        ? OpsinInverseMatrix.read(reader)
        : const OpsinInverseMatrix();

    final cwMask = defaultMatrix ? 0 : reader.readBits(3);
    final up2Weights =
        cwMask & 1 != 0 ? _readWeights(reader, 15) : defaultUp2Weights;
    final up4Weights =
        cwMask & 2 != 0 ? _readWeights(reader, 55) : defaultUp4Weights;
    final up8Weights =
        cwMask & 4 != 0 ? _readWeights(reader, 210) : defaultUp8Weights;

    int? iccEncodedSize;
    if (colorEncoding.useIccProfile) {
      final encodedSize = reader.readU64();
      if (encodedSize < 0 || encodedSize > 0x7FFFFFFF) {
        throw const JxlInvalidBitstreamException('ICC size too large');
      }
      iccEncodedSize = encodedSize;
      // The entropy-coded ICC payload follows; the caller decodes it and
      // then re-aligns the reader.
    } else {
      reader.zeroPadToByte();
    }

    return ImageHeader._(
      level: level,
      size: size,
      orientation: orientation,
      intrinsicSize: intrinsicSize,
      previewSize: previewSize,
      animation: animation,
      bitDepth: bitDepth,
      modular16BitBuffers: modular16BitBuffers,
      extraChannels: extraChannels,
      alphaIndices: alphaIndices,
      xybEncoded: xybEncoded,
      colorEncoding: colorEncoding,
      toneMapping: toneMapping,
      extensions: extensions,
      opsinInverseMatrix: opsinInverseMatrix,
      up2Weights: up2Weights,
      up4Weights: up4Weights,
      up8Weights: up8Weights,
      iccEncodedSize: iccEncodedSize,
    );
  }

  static Float32List _readWeights(BitReader reader, int count) {
    final weights = Float32List(count);
    for (var i = 0; i < count; i++) {
      weights[i] = reader.readF16();
    }
    return weights;
  }

  ImageHeader._({
    required this.level,
    required this.size,
    required this.orientation,
    required this.intrinsicSize,
    required this.previewSize,
    required this.animation,
    required this.bitDepth,
    required this.modular16BitBuffers,
    required this.extraChannels,
    required this.alphaIndices,
    required this.xybEncoded,
    required this.colorEncoding,
    required this.toneMapping,
    required this.extensions,
    required this.opsinInverseMatrix,
    required this.up2Weights,
    required this.up4Weights,
    required this.up8Weights,
    required this.iccEncodedSize,
  });

  final int level;

  /// The stored (pre-orientation) size.
  final SizeDim size;

  /// EXIF-style orientation, 1–8. Values above 4 transpose the output.
  final int orientation;
  final SizeDim? intrinsicSize;
  final SizeDim? previewSize;
  final AnimationHeader? animation;
  final BitDepthHeader bitDepth;
  final bool modular16BitBuffers;
  final List<ExtraChannelInfo> extraChannels;
  final List<int> alphaIndices;
  final bool xybEncoded;
  final ColorEncodingBundle colorEncoding;
  final ToneMapping toneMapping;
  final Extensions extensions;
  final OpsinInverseMatrix opsinInverseMatrix;
  final Float32List up2Weights;
  final Float32List up4Weights;
  final Float32List up8Weights;

  /// Encoded byte length of the compressed ICC payload, or null if the color
  /// encoding does not use an ICC profile.
  final int? iccEncodedSize;

  /// The output size after applying [orientation].
  SizeDim get orientedSize =>
      orientation > 4 ? (width: size.height, height: size.width) : size;

  List<List<List<Float32List>>>? _upWeights;

  /// Upsampling weights: `upWeights[l][ky * k + kx]` is a 5x5 kernel,
  /// where k = 2 << l.
  List<List<List<Float32List>>> get upWeights {
    final cached = _upWeights;
    if (cached != null) return cached;
    final result = <List<List<Float32List>>>[];
    for (var l = 0; l < 3; l++) {
      final k = 1 << (l + 1);
      final upKWeights = switch (k) {
        2 => up2Weights,
        4 => up4Weights,
        _ => up8Weights,
      };
      final level = <List<Float32List>>[];
      for (var ky = 0; ky < k; ky++) {
        for (var kx = 0; kx < k; kx++) {
          final kernel = List.generate(5, (_) => Float32List(5));
          for (var iy = 0; iy < 5; iy++) {
            for (var ix = 0; ix < 5; ix++) {
              final j = ky < k ~/ 2 ? iy + 5 * ky : (4 - iy) + 5 * (k - 1 - ky);
              final i = kx < k ~/ 2 ? ix + 5 * kx : (4 - ix) + 5 * (k - 1 - kx);
              final x = i < j ? j : i;
              final y = x ^ j ^ i;
              final index = 5 * k * y ~/ 2 - y * (y - 1) ~/ 2 + x - y;
              kernel[iy][ix] = upKWeights[index];
            }
          }
          level.add(kernel);
        }
      }
      result.add(level);
    }
    return _upWeights = result;
  }

  bool get isGrayscale => colorEncoding.colorEncoding == ColorFlags.ceGray;

  int get colorChannelCount => isGrayscale ? 1 : 3;

  int get totalChannelCount => colorChannelCount + extraChannels.length;

  bool get hasAlpha => alphaIndices.isNotEmpty;

  bool get isAnimated => animation != null;
}
