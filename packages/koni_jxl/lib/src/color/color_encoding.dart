import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';

/// Color-related enum constants from the JPEG XL spec. Kept as plain ints
/// (mirroring jxlatte's ColorFlags) so bitstream values map directly.
abstract final class ColorFlags {
  static const priSrgb = 1;
  static const priCustom = 2;
  static const priBt2100 = 9;
  static const priP3 = 11;

  static const wpD50 = -1;
  static const wpD65 = 1;
  static const wpCustom = 2;
  static const wpE = 10;
  static const wpDci = 11;

  static const ceRgb = 0;
  static const ceGray = 1;
  static const ceXyb = 2;
  static const ceUnknown = 3;

  static const riPerceptual = 0;
  static const riRelative = 1;
  static const riSaturation = 2;
  static const riAbsolute = 3;

  static const tfBt709 = 1 + (1 << 24);
  static const tfUnknown = 2 + (1 << 24);
  static const tfLinear = 8 + (1 << 24);
  static const tfSrgb = 13 + (1 << 24);
  static const tfPq = 16 + (1 << 24);
  static const tfDci = 17 + (1 << 24);
  static const tfHlg = 18 + (1 << 24);

  static bool validatePrimaries(int primaries) =>
      primaries == priSrgb ||
      primaries == priCustom ||
      primaries == priBt2100 ||
      primaries == priP3;

  static bool validateWhitePoint(int whitePoint) =>
      whitePoint == wpD65 ||
      whitePoint == wpCustom ||
      whitePoint == wpE ||
      whitePoint == wpDci;

  static bool validateColorEncoding(int colorEncoding) =>
      colorEncoding >= 0 && colorEncoding <= 3;

  static bool validateRenderingIntent(int renderingIntent) =>
      renderingIntent >= 0 && renderingIntent <= 3;

  static bool validateTransfer(int transfer) {
    if (transfer < 0) return false;
    if (transfer <= 10000000) return true;
    if (transfer < 1 << 24) return false;
    return transfer == tfBt709 ||
        transfer == tfUnknown ||
        transfer == tfLinear ||
        transfer == tfSrgb ||
        transfer == tfPq ||
        transfer == tfDci ||
        transfer == tfHlg;
  }

  static String primariesToString(int primaries) => switch (primaries) {
        priSrgb => 'sRGB / BT.709',
        priBt2100 => 'BT Rec.2100 / BT Rec.2020',
        priP3 => 'P3',
        _ => 'Unknown',
      };

  static String whitePointToString(int whitePoint) => switch (whitePoint) {
        wpD65 => 'D65',
        wpE => 'Standard Illuminant E',
        wpDci => 'DCI',
        wpD50 => 'D50',
        _ => 'Unknown',
      };

  static String transferToString(int transfer) {
    if (transfer < 1 << 24) return 'Gamma ${transfer * 1e-7}';
    return switch (transfer) {
      tfBt709 => 'BT.709',
      tfLinear => 'Linear',
      tfSrgb => 'sRGB',
      tfPq => 'PQ',
      tfDci => 'DCI',
      tfHlg => 'HLG',
      _ => 'Unknown',
    };
  }

  static CieXy? getWhitePoint(int whitePoint) => switch (whitePoint) {
        wpD65 => const CieXy(0.3127, 0.3290),
        wpE => const CieXy(1 / 3, 1 / 3),
        wpDci => const CieXy(0.314, 0.351),
        wpD50 => const CieXy(0.34567, 0.34567),
        _ => null,
      };

  static CiePrimaries? getPrimaries(int primaries) => switch (primaries) {
        priSrgb => const CiePrimaries(CieXy(0.639998686, 0.330010138),
            CieXy(0.300003784, 0.600003357), CieXy(0.150002046, 0.059997204)),
        priBt2100 => const CiePrimaries(
            CieXy(0.708, 0.292), CieXy(0.170, 0.797), CieXy(0.131, 0.046)),
        priP3 => const CiePrimaries(
            CieXy(0.680, 0.320), CieXy(0.265, 0.690), CieXy(0.150, 0.060)),
        _ => null,
      };
}

/// A CIE xy chromaticity coordinate.
final class CieXy {
  const CieXy(this.x, this.y);

  factory CieXy.readCustom(BitReader reader) {
    final ux = reader.readU32(0, 19, 524288, 19, 1048576, 20, 2097152, 21);
    final uy = reader.readU32(0, 19, 524288, 19, 1048576, 20, 2097152, 21);
    return CieXy(unpackSigned(ux) * 1e-6, unpackSigned(uy) * 1e-6);
  }

  final double x;
  final double y;

  bool matches(CieXy other) => (x - other.x).abs() + (y - other.y).abs() < 1e-4;

  @override
  String toString() => 'CieXy($x, $y)';
}

/// Red/green/blue CIE xy primaries.
final class CiePrimaries {
  const CiePrimaries(this.red, this.green, this.blue);

  final CieXy red;
  final CieXy green;
  final CieXy blue;

  bool matches(CiePrimaries other) =>
      red.matches(other.red) &&
      green.matches(other.green) &&
      blue.matches(other.blue);
}

final class ToneMapping {
  const ToneMapping()
      : intensityTarget = 255,
        minNits = 0,
        relativeToMaxDisplay = false,
        linearBelow = 0;

  factory ToneMapping.read(BitReader reader) {
    if (reader.readBool()) return const ToneMapping();
    final intensityTarget = reader.readF16();
    if (intensityTarget <= 0) {
      throw const JxlInvalidBitstreamException(
          'intensity target must be positive');
    }
    final minNits = reader.readF16();
    if (minNits < 0 || minNits > intensityTarget) {
      throw const JxlInvalidBitstreamException(
          'min nits must be in [0, intensityTarget]');
    }
    final relativeToMaxDisplay = reader.readBool();
    final linearBelow = reader.readF16();
    if (relativeToMaxDisplay && (linearBelow < 0 || linearBelow > 1)) {
      throw const JxlInvalidBitstreamException(
          'linear below out of relative range');
    }
    if (!relativeToMaxDisplay && linearBelow < 0) {
      throw const JxlInvalidBitstreamException(
          'linear below must be nonnegative');
    }
    return ToneMapping._(
        intensityTarget, minNits, relativeToMaxDisplay, linearBelow);
  }

  const ToneMapping._(this.intensityTarget, this.minNits,
      this.relativeToMaxDisplay, this.linearBelow);

  final double intensityTarget;
  final double minNits;
  final bool relativeToMaxDisplay;
  final double linearBelow;
}

/// The `ColourEncoding` header bundle.
final class ColorEncodingBundle {
  const ColorEncodingBundle()
      : useIccProfile = false,
        colorEncoding = ColorFlags.ceRgb,
        whitePoint = ColorFlags.wpD65,
        white = const CieXy(0.3127, 0.3290),
        primaries = ColorFlags.priSrgb,
        prim = const CiePrimaries(CieXy(0.639998686, 0.330010138),
            CieXy(0.300003784, 0.600003357), CieXy(0.150002046, 0.059997204)),
        tf = ColorFlags.tfSrgb,
        renderingIntent = ColorFlags.riRelative;

  factory ColorEncodingBundle.read(BitReader reader) {
    final allDefault = reader.readBool();
    final useIccProfile = !allDefault && reader.readBool();
    final colorEncoding = allDefault ? ColorFlags.ceRgb : reader.readEnum();
    if (!ColorFlags.validateColorEncoding(colorEncoding)) {
      throw const JxlInvalidBitstreamException('invalid ColorSpace enum');
    }
    final int whitePoint;
    if (!allDefault && !useIccProfile && colorEncoding != ColorFlags.ceXyb) {
      whitePoint = reader.readEnum();
    } else {
      whitePoint = ColorFlags.wpD65;
    }
    if (!ColorFlags.validateWhitePoint(whitePoint)) {
      throw const JxlInvalidBitstreamException('invalid WhitePoint enum');
    }
    final white = whitePoint == ColorFlags.wpCustom
        ? CieXy.readCustom(reader)
        : ColorFlags.getWhitePoint(whitePoint)!;
    final int primaries;
    if (!allDefault &&
        !useIccProfile &&
        colorEncoding != ColorFlags.ceXyb &&
        colorEncoding != ColorFlags.ceGray) {
      primaries = reader.readEnum();
    } else {
      primaries = ColorFlags.priSrgb;
    }
    if (!ColorFlags.validatePrimaries(primaries)) {
      throw const JxlInvalidBitstreamException('invalid Primaries enum');
    }
    final CiePrimaries prim;
    if (primaries == ColorFlags.priCustom) {
      final red = CieXy.readCustom(reader);
      final green = CieXy.readCustom(reader);
      final blue = CieXy.readCustom(reader);
      prim = CiePrimaries(red, green, blue);
    } else {
      prim = ColorFlags.getPrimaries(primaries)!;
    }
    var tf = ColorFlags.tfSrgb;
    var renderingIntent = ColorFlags.riRelative;
    if (!allDefault && !useIccProfile) {
      final useGamma = reader.readBool();
      tf = useGamma ? reader.readBits(24) : (1 << 24) + reader.readEnum();
      if (!ColorFlags.validateTransfer(tf)) {
        throw const JxlInvalidBitstreamException('illegal transfer function');
      }
      renderingIntent = reader.readEnum();
      if (!ColorFlags.validateRenderingIntent(renderingIntent)) {
        throw const JxlInvalidBitstreamException(
            'invalid RenderingIntent enum');
      }
    }
    return ColorEncodingBundle._(useIccProfile, colorEncoding, whitePoint,
        white, primaries, prim, tf, renderingIntent);
  }

  const ColorEncodingBundle._(
      this.useIccProfile,
      this.colorEncoding,
      this.whitePoint,
      this.white,
      this.primaries,
      this.prim,
      this.tf,
      this.renderingIntent);

  final bool useIccProfile;
  final int colorEncoding;
  final int whitePoint;
  final CieXy white;
  final int primaries;
  final CiePrimaries prim;
  final int tf;
  final int renderingIntent;
}
