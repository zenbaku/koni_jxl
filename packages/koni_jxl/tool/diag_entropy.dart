import 'dart:io';

import 'package:koni_jxl/src/frame/frame.dart';
import 'package:koni_jxl/src/header/image_header.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/container.dart';

/// One-off diagnostic: confirms/refutes the "redundant full-nbBlocks scan per
/// pass-group" hypothesis and the "numBlocks==1 (8x8-only)" hypothesis for
/// real content, before optimizing hf_coefficients.dart's hot loop.
void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
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

  print('numLfGroups=${frame.numLfGroups} numGroups=${frame.numGroups} '
      'numPasses=${frame.passes.length}');

  for (var lfGroupID = 0; lfGroupID < frame.numLfGroups; lfGroupID++) {
    final lfg = frame.lfGroups[lfGroupID]!;
    final meta = lfg.hfMetadata!;
    print('lfGroup $lfGroupID: nbBlocks=${meta.nbBlocks}');
    var n1 = 0, total = 0;
    for (var i = 0; i < meta.nbBlocks; i++) {
      final tt = meta.dctSelectAt(meta.blockY[i], meta.blockX[i])!;
      total++;
      if (tt.dctSelectHeight * tt.dctSelectWidth == 1) n1++;
    }
    print('  numBlocks==1 (8x8-or-smaller): $n1/$total '
        '(${(100 * n1 / total).toStringAsFixed(1)}%)');
  }

  // How many groups share each LF group (redundant-scan multiplier).
  final groupsPerLfGroup = <int, int>{};
  for (var group = 0; group < frame.numGroups; group++) {
    final lfg = frame.getLFGroupForGroup(group);
    groupsPerLfGroup[lfg.lfGroupID] =
        (groupsPerLfGroup[lfg.lfGroupID] ?? 0) + 1;
  }
  print('pass-groups per LF group: $groupsPerLfGroup');
}
