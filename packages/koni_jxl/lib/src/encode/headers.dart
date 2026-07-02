import '../frame/frame_flags.dart';
import '../io/bit_writer.dart';

/// Static settings of an encode: dimensions and pixel format.
final class JxlEncodeSetup {
  JxlEncodeSetup({
    required this.width,
    required this.height,
    required this.bitsPerSample,
    required this.grayscale,
    required this.hasAlpha,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('empty image');
    }
    if (bitsPerSample != 8 && bitsPerSample != 16) {
      throw ArgumentError('bitsPerSample must be 8 or 16');
    }
    if (hasAlpha && bitsPerSample != 8) {
      throw ArgumentError('alpha is currently supported for 8-bit only');
    }
  }

  final int width;
  final int height;
  final int bitsPerSample;
  final bool grayscale;
  final bool hasAlpha;

  int get colorChannels => grayscale ? 1 : 3;
  int get channelCount => colorChannels + (hasAlpha ? 1 : 0);
}

void _writeSizeValue(BitWriter w, int value, bool div8) {
  if (div8) {
    w.writeBits((value >> 3) - 1, 5);
  } else {
    w.writeU32(value, 1, 9, 1, 13, 1, 18, 1, 30);
  }
}

/// Writes the 0xFF0A signature, SizeHeader and ImageMetadata for a
/// non-XYB (lossless modular) image, byte-aligned at return.
void writeImageHeader(BitWriter w, JxlEncodeSetup s) {
  w.writeBits(0xFF, 8);
  w.writeBits(0x0A, 8);
  // SizeHeader.
  final div8 = s.width % 8 == 0 &&
      s.height % 8 == 0 &&
      s.width <= 256 &&
      s.height <= 256;
  w.writeBool(div8);
  _writeSizeValue(w, s.height, div8);
  w.writeBits(0, 3); // no aspect-ratio shortcut
  _writeSizeValue(w, s.width, div8);

  // ImageMetadata: explicit (the all-default header implies XYB).
  w.writeBool(false); // all_default
  w.writeBool(false); // extra_fields (orientation 1, no animation)
  // BitDepth: integer samples.
  w.writeBool(false);
  w.writeU32(s.bitsPerSample, 8, 0, 10, 0, 12, 0, 1, 6);
  // modular_16bit_buffers: only guaranteed for 8-bit content.
  w.writeBool(s.bitsPerSample == 8);
  // Extra channels.
  w.writeU32(s.hasAlpha ? 1 : 0, 0, 0, 1, 0, 2, 4, 1, 12);
  if (s.hasAlpha) {
    w.writeBool(true); // d_alpha: default 8-bit unassociated alpha
  }
  w.writeBool(false); // xyb_encoded
  // ColorEncoding.
  if (s.grayscale) {
    w.writeBool(false); // all_default
    w.writeBool(false); // want_icc
    w.writeEnum(1); // colour_encoding: grayscale
    w.writeEnum(1); // white_point: D65
    // primaries: not present for grayscale
    w.writeBool(false); // have_gamma
    w.writeEnum(13); // transfer function: sRGB
    w.writeEnum(1); // rendering intent: relative
  } else {
    w.writeBool(true); // all_default: sRGB
  }
  // extensions
  w.writeU64(0);
  // default opsin inverse matrix + default upsampling weights
  w.writeBool(true);
  // no ICC payload follows (want_icc == false)
  w.zeroPadToByte();
}

/// Writes the frame header of the single modular lossless frame.
void writeFrameHeader(BitWriter w, JxlEncodeSetup s, {int groupSizeShift = 1}) {
  w.writeBool(false); // all_default
  w.writeBits(FrameFlags.regularFrame, 2);
  w.writeBits(FrameFlags.modular, 1);
  w.writeU64(0); // flags
  w.writeBool(false); // do_YCbCr
  w.writeBits(0, 2); // upsampling: 1x
  if (s.hasAlpha) {
    w.writeBits(0, 2); // ec_upsampling: 1x
  }
  w.writeBits(groupSizeShift, 2);
  // x/bqm scales: not present (not xyb+vardct)
  // PassesInfo: single pass
  w.writeU32(1, 1, 0, 2, 0, 3, 0, 4, 3);
  // lf_level: not present; have_crop:
  w.writeBool(false);
  // BlendingInfo (mode replace, full frame): color, then per EC.
  w.writeU32(0, 0, 0, 1, 0, 2, 0, 3, 2);
  if (s.hasAlpha) {
    w.writeU32(0, 0, 0, 1, 0, 2, 0, 3, 2);
  }
  // duration/timecode: not animated
  w.writeBool(true); // is_last
  // save_as_reference / save_before_ct: not present
  w.writeU32(0, 0, 0, 0, 4, 16, 5, 48, 10); // empty name
  // RestorationFilter: explicit, everything off (lossless).
  w.writeBool(false); // all_default
  w.writeBool(false); // gab
  w.writeBits(0, 2); // epf_iterations
  w.writeU64(0); // restoration extensions
  w.writeU64(0); // frame extensions
}

/// Writes the table of contents (no permutation) and byte-aligns.
void writeToc(BitWriter w, List<int> sectionLengths) {
  w.writeBool(false); // no permutation
  w.zeroPadToByte();
  for (final length in sectionLengths) {
    w.writeU32(length, 0, 10, 1024, 14, 17408, 22, 4211712, 30);
  }
  w.zeroPadToByte();
}
