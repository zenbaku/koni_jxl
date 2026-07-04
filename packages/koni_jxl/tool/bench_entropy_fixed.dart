import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/src/frame/frame.dart';
import 'package:koni_jxl/src/header/image_header.dart';
import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/container.dart';
import 'package:koni_jxl/src/util/image_buffer.dart';

/// Decomposes the ~170us/group "fixed overhead" (measured via bench_entropy's
/// near-empty groups) into: (a) the full-nbBlocks scan-and-skip loop that
/// HfCoefficients' constructor runs once per pass-group, and (b) the
/// constructor's per-group allocations (blockIncluded/quantizedCoeffs/
/// dequantHFCoeff*/nonZeroes). Reproduces the exact arithmetic from
/// hf_coefficients.dart lines ~72-86 and ~44-71 without touching production
/// code, so this is read-only measurement.
void main(List<String> args) {
  final bytes = File(args[0]).readAsBytesSync();
  final groupID = args.length > 1 ? int.parse(args[1]) : 4;
  final reps = args.length > 2 ? int.parse(args[2]) : 2000;

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

  final lfg = frame.getLFGroupForGroup(groupID);
  final meta = lfg.hfMetadata!;
  final pos = frame.groupPosInLFGroup(lfg.lfGroupID, groupID);
  final groupPosY = pos.y << 5;
  final groupPosX = pos.x << 5;
  final size = frame.groupSize(groupID);

  print('group=$groupID nbBlocks=${meta.nbBlocks}');

  // (a) The scan-and-skip loop alone.
  {
    var included = 0;
    final sw = Stopwatch()..start();
    for (var r = 0; r < reps; r++) {
      included = 0;
      for (var i = 0; i < meta.nbBlocks; i++) {
        final posY = meta.blockY[i];
        final posX = meta.blockX[i];
        final groupY = posY - groupPosY;
        final groupX = posX - groupPosX;
        if (groupY < 0 || groupX < 0 || groupY >= 32 || groupX >= 32) {
          continue;
        }
        included++;
      }
    }
    sw.stop();
    print('  (a) scan-and-skip loop: '
        '${sw.elapsedMicroseconds ~/ reps}us/rep (included=$included)');
  }

  // (b) The per-group allocations alone.
  {
    final sw = Stopwatch()..start();
    for (var r = 0; r < reps; r++) {
      final nonZeroes = Int32List(3 * 32 * 32);
      final coeffHeight = List.filled(3, 0);
      final coeffWidth = List.filled(3, 0);
      final quantizedCoeffs = <Float32List>[];
      for (var c = 0; c < 3; c++) {
        final sY = size.height >> frame.header.jpegUpsamplingY[c];
        final sX = size.width >> frame.header.jpegUpsamplingX[c];
        coeffHeight[c] = sY;
        coeffWidth[c] = sX;
        quantizedCoeffs.add(Float32List(sY * sX));
      }
      floatMatrix(coeffHeight[0], coeffWidth[0]);
      floatMatrix(coeffHeight[1], coeffWidth[1]);
      floatMatrix(coeffHeight[2], coeffWidth[2]);
      List<bool>.filled(meta.nbBlocks, false);
      // Prevent the optimizer from proving these dead.
      if (identical(nonZeroes, quantizedCoeffs)) print('unreachable');
    }
    sw.stop();
    print('  (b) allocations: ${sw.elapsedMicroseconds ~/ reps}us/rep');
  }
}
