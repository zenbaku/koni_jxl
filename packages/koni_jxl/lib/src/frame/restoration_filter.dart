import 'dart:typed_data';

import '../header/extensions.dart';
import '../io/bit_reader.dart';
import 'frame_flags.dart';

/// Gaborish + edge-preserving-filter parameters from the frame header.
final class RestorationFilter {
  RestorationFilter.defaults() {
    _bakeSharpLut();
  }

  factory RestorationFilter.read(BitReader reader, int encoding) {
    final allDefault = reader.readBool();
    if (allDefault) return RestorationFilter.defaults();
    final rf = RestorationFilter._();
    rf.gab = reader.readBool();
    rf.customGab = rf.gab && reader.readBool();
    if (rf.customGab) {
      for (var i = 0; i < 3; i++) {
        rf.gab1Weights[i] = reader.readF16();
        rf.gab2Weights[i] = reader.readF16();
      }
    }
    rf.epfIterations = reader.readBits(2);
    rf.epfSharpCustom = rf.epfIterations > 0 &&
        encoding == FrameFlags.vardct &&
        reader.readBool();
    if (rf.epfSharpCustom) {
      for (var i = 0; i < 8; i++) {
        rf.epfSharpLut[i] = reader.readF16();
      }
    }
    rf.epfWeightCustom = rf.epfIterations > 0 && reader.readBool();
    if (rf.epfWeightCustom) {
      for (var i = 0; i < 3; i++) {
        rf.epfChannelScale[i] = reader.readF16();
      }
      reader.readBits(32);
    }
    rf.epfSigmaCustom = rf.epfIterations > 0 && reader.readBool();
    rf.epfQuantMul = rf.epfSigmaCustom && encoding == FrameFlags.vardct
        ? reader.readF16()
        : 0.46;
    rf.epfPass0SigmaScale = rf.epfSigmaCustom ? reader.readF16() : 0.9;
    rf.epfPass2SigmaScale = rf.epfSigmaCustom ? reader.readF16() : 6.5;
    rf.epfBorderSadMul = rf.epfSigmaCustom ? reader.readF16() : 2 / 3;
    rf.epfSigmaForModular =
        rf.epfIterations > 0 && encoding == FrameFlags.modular
            ? reader.readF16()
            : 1.0;
    rf.extensions = Extensions.read(reader);
    rf._bakeSharpLut();
    return rf;
  }

  RestorationFilter._();

  bool gab = true;
  bool customGab = false;
  final Float32List gab1Weights =
      Float32List.fromList(const [0.115169525, 0.115169525, 0.115169525]);
  final Float32List gab2Weights =
      Float32List.fromList(const [0.061248592, 0.061248592, 0.061248592]);
  int epfIterations = 2;
  bool epfSharpCustom = false;
  final Float32List epfSharpLut = Float32List.fromList(
      const [0, 1 / 7, 2 / 7, 3 / 7, 4 / 7, 5 / 7, 6 / 7, 1]);
  bool epfWeightCustom = false;
  final Float32List epfChannelScale =
      Float32List.fromList(const [40.0, 5.0, 3.5]);
  bool epfSigmaCustom = false;
  double epfQuantMul = 0.46;
  double epfPass0SigmaScale = 0.9;
  double epfPass2SigmaScale = 6.5;
  double epfBorderSadMul = 2 / 3;
  double epfSigmaForModular = 1.0;
  Extensions extensions = const Extensions();

  void _bakeSharpLut() {
    for (var i = 0; i < 8; i++) {
      epfSharpLut[i] *= epfQuantMul;
    }
  }
}
