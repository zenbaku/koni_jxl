import 'dart:io';

import 'package:koni_jxl/koni_jxl.dart';

/// Prints header information for each given .jxl file, one line per field,
/// in a stable machine-parsable format (used by the jxlinfo comparison gate).
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: jxl_info <file.jxl> [more files...]');
    exit(2);
  }
  var failures = 0;
  for (final path in args) {
    try {
      final info = JxlInfo.parse(File(path).readAsBytesSync());
      stdout.writeln('$path:');
      stdout.writeln('  dimensions: ${info.width}x${info.height}');
      stdout.writeln(
          '  encoded_dimensions: ${info.encodedWidth}x${info.encodedHeight}');
      stdout.writeln('  bits_per_sample: ${info.bitsPerSample}'
          '${info.usesFloatSamples ? ' (float, exp ${info.exponentBits})' : ''}');
      stdout.writeln('  color_channels: ${info.isGrayscale ? 1 : 3}');
      stdout.writeln('  extra_channels: ${info.extraChannelCount}'
          '${info.extraChannelDescriptions.isEmpty ? '' : ' [${info.extraChannelDescriptions.join(', ')}]'}');
      stdout.writeln('  alpha: ${info.hasAlpha}');
      stdout.writeln('  animated: ${info.isAnimated}');
      stdout.writeln('  orientation: ${info.orientation}');
      stdout.writeln('  xyb_encoded: ${info.isXybEncoded}');
      stdout.writeln('  color: ${info.colorDescription}');
      stdout.writeln('  container: ${info.isContainer}');
      stdout.writeln('  intensity_target: ${info.intensityTarget}');
    } on JxlException catch (e) {
      stderr.writeln('$path: error: $e');
      failures++;
    } on FileSystemException catch (e) {
      stderr.writeln('$path: ${e.message}');
      failures++;
    }
  }
  if (failures > 0) exit(1);
}
