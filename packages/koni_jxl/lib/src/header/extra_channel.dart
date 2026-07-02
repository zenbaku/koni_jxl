import 'dart:convert';

import '../exceptions.dart';
import '../io/bit_reader.dart';
import 'bit_depth.dart';

/// Extra channel type constants (spec values).
abstract final class ExtraChannelType {
  static const alpha = 0;
  static const depth = 1;
  static const spotColor = 2;
  static const selectionMask = 3;
  static const cmykBlack = 4;
  static const colorFilterArray = 5;
  static const thermal = 6;
  static const nonOptional = 15;
  static const optional = 16;

  static bool validate(int ec) => ec >= 0 && ec <= 6 || ec == 15 || ec == 16;

  static String toDisplayString(int ec) => switch (ec) {
        alpha => 'Alpha',
        depth => 'Depth',
        spotColor => 'Spot color',
        selectionMask => 'Selection mask',
        cmykBlack => 'CMYK black',
        colorFilterArray => 'CFA',
        thermal => 'Thermal',
        nonOptional => 'Non-optional',
        optional => 'Optional',
        _ => 'Unknown',
      };
}

/// The `ExtraChannelInfo` header bundle.
final class ExtraChannelInfo {
  factory ExtraChannelInfo.read(BitReader reader) {
    final dAlpha = reader.readBool();
    final int type;
    final BitDepthHeader bitDepth;
    final int dimShift;
    final String name;
    final bool alphaAssociated;
    if (!dAlpha) {
      type = reader.readEnum();
      if (!ExtraChannelType.validate(type)) {
        throw const JxlInvalidBitstreamException('illegal extra channel type');
      }
      bitDepth = BitDepthHeader.read(reader);
      dimShift = reader.readU32(0, 0, 3, 0, 4, 0, 1, 3);
      final nameLen = reader.readU32(0, 0, 0, 4, 16, 5, 48, 10);
      // No byte-alignment guarantee, so read the UTF-8 name bytewise.
      final nameBuffer = List<int>.generate(nameLen, (_) => reader.readBits(8));
      name = utf8.decode(nameBuffer, allowMalformed: true);
      alphaAssociated = type == ExtraChannelType.alpha && reader.readBool();
    } else {
      type = ExtraChannelType.alpha;
      bitDepth = const BitDepthHeader();
      dimShift = 0;
      name = '';
      alphaAssociated = false;
    }
    var red = 0.0, green = 0.0, blue = 0.0, solidity = 0.0;
    if (type == ExtraChannelType.spotColor) {
      red = reader.readF16();
      green = reader.readF16();
      blue = reader.readF16();
      solidity = reader.readF16();
    }
    final cfaIndex = type == ExtraChannelType.colorFilterArray
        ? reader.readU32(1, 0, 0, 2, 3, 4, 19, 8)
        : 1;
    return ExtraChannelInfo._(type, bitDepth, dimShift, name, alphaAssociated,
        red, green, blue, solidity, cfaIndex);
  }

  const ExtraChannelInfo._(
      this.type,
      this.bitDepth,
      this.dimShift,
      this.name,
      this.alphaAssociated,
      this.red,
      this.green,
      this.blue,
      this.solidity,
      this.cfaIndex);

  final int type;
  final BitDepthHeader bitDepth;
  final int dimShift;
  final String name;
  final bool alphaAssociated;
  final double red, green, blue, solidity;
  final int cfaIndex;
}
