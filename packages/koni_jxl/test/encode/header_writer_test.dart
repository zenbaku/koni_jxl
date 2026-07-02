import 'package:koni_jxl/src/encode/headers.dart';
import 'package:koni_jxl/src/frame/frame.dart';
import 'package:koni_jxl/src/frame/frame_flags.dart';
import 'package:koni_jxl/src/header/image_header.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/bit_writer.dart';
import 'package:test/test.dart';

void main() {
  for (final (name, setup) in [
    (
      'rgb8',
      JxlEncodeSetup(
          width: 1531,
          height: 2207,
          bitsPerSample: 8,
          grayscale: false,
          hasAlpha: false)
    ),
    (
      'gray8',
      JxlEncodeSetup(
          width: 256,
          height: 64,
          bitsPerSample: 8,
          grayscale: true,
          hasAlpha: false)
    ),
    (
      'rgb16',
      JxlEncodeSetup(
          width: 33,
          height: 1,
          bitsPerSample: 16,
          grayscale: false,
          hasAlpha: false)
    ),
    (
      'rgba8',
      JxlEncodeSetup(
          width: 300,
          height: 200,
          bitsPerSample: 8,
          grayscale: false,
          hasAlpha: true)
    ),
  ]) {
    test('image + frame header round-trips ($name)', () {
      final w = BitWriter();
      writeImageHeader(w, setup);
      writeFrameHeader(w, setup);
      final reader = BitReader(w.toBytes());

      final header = ImageHeader.read(reader);
      expect(header.size.width, setup.width);
      expect(header.size.height, setup.height);
      expect(header.bitDepth.bitsPerSample, setup.bitsPerSample);
      expect(header.bitDepth.usesFloatSamples, isFalse);
      expect(header.isGrayscale, setup.grayscale);
      expect(header.hasAlpha, setup.hasAlpha);
      expect(header.xybEncoded, isFalse);
      expect(header.orientation, 1);
      expect(header.animation, isNull);
      expect(header.iccEncodedSize, isNull);

      final frame = Frame(reader, header);
      final fh = frame.readFrameHeader();
      expect(fh.type, FrameFlags.regularFrame);
      expect(fh.encoding, FrameFlags.modular);
      expect(fh.isLast, isTrue);
      expect(fh.width, setup.width);
      expect(fh.height, setup.height);
      expect(fh.groupDim, 256);
      expect(fh.passes.numPasses, 1);
      expect(fh.restorationFilter.gab, isFalse);
      expect(fh.restorationFilter.epfIterations, 0);
      expect(fh.doYCbCr, isFalse);
    });
  }
}
