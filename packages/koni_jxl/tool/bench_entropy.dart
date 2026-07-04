import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/src/frame/frame.dart';
import 'package:koni_jxl/src/header/image_header.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/container.dart';
import 'package:koni_jxl/src/vardct/hf_coefficients.dart';

/// Isolated A/B benchmark for the AC entropy-decode phase (the `passGroups`
/// hot loop identified by `profile_decode.dart`'s phase timings). Fully
/// decodes a real file once (filters off) to populate the frame's HfGlobal/
/// HfPass/LfGroup state, then replays a single pass-group's HfCoefficients
/// decode from pristine section bytes [reps] times so Stopwatch overhead is
/// amortized across many repeated, bit-identical decodes.
void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final reps = args.length > 1 ? int.parse(args[1]) : 200;

  final demuxed = demuxContainer(bytes);
  final reader = BitReader(demuxed.codestream);
  final imageHeader = ImageHeader.read(reader, level: demuxed.level);
  final frame = Frame(reader, imageHeader);
  frame.readFrameHeader();
  frame.readToc();
  final rf = frame.header.restorationFilter;
  rf.gab = false;
  rf.epfIterations = 0;
  frame.decodeFrame();

  final numPasses = frame.passes.length;
  final numGroups = frame.numGroups;
  print('numPasses=$numPasses numGroups=$numGroups reps=$reps');

  var totalUs = 0;
  var totalGroups = 0;
  for (var pass = 0; pass < numPasses; pass++) {
    for (var group = 0; group < numGroups; group++) {
      final sectionIndex = 2 + frame.numLfGroups + pass * numGroups + group;
      final Uint8List section;
      try {
        section = frame.toc.sectionBytes(sectionIndex);
      } catch (_) {
        continue;
      }
      // Warm up (JIT/branch predictors) before timing.
      HfCoefficients(BitReader(section), frame, pass, group);

      final sw = Stopwatch()..start();
      for (var i = 0; i < reps; i++) {
        HfCoefficients(BitReader(section), frame, pass, group);
      }
      sw.stop();
      final us = sw.elapsedMicroseconds ~/ reps;
      totalUs += us;
      totalGroups++;
      print('  pass=$pass group=$group: ${us}us/decode '
          '(${section.length} bytes)');
    }
  }
  print('TOTAL: ${totalUs}us/decode-of-all-groups '
      '(avg over $totalGroups groups x $reps reps)');
}
