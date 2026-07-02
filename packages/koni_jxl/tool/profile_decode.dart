import 'dart:io';

import 'package:koni_jxl/src/frame/frame.dart';
import 'package:koni_jxl/src/header/image_header.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/container.dart';
import 'package:koni_jxl/src/render/filters.dart';

/// Rough phase timing for a single-frame decode.
void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final demuxed = demuxContainer(bytes);
  final reader = BitReader(demuxed.codestream);
  final imageHeader = ImageHeader.read(reader, level: demuxed.level);
  final frame = Frame(reader, imageHeader);
  frame.readFrameHeader();
  frame.readToc();

  // Temporarily disable filters to time the core decode.
  final rf = frame.header.restorationFilter;
  final gab = rf.gab;
  final epf = rf.epfIterations;
  rf.gab = false;
  rf.epfIterations = 0;
  final sw = Stopwatch()..start();
  frame.decodeFrame();
  print('core decode (no filters): ${sw.elapsedMilliseconds} ms');

  final colors = frame.colorChannelCount;
  if (gab) {
    sw
      ..reset()
      ..start();
    performGabConvolution(frame, colors);
    print('gaborish: ${sw.elapsedMilliseconds} ms');
  }
  if (epf > 0) {
    rf.epfIterations = epf;
    sw
      ..reset()
      ..start();
    performEdgePreservingFilter(frame, colors);
    print('epf ($epf iterations): ${sw.elapsedMilliseconds} ms');
  }
}
