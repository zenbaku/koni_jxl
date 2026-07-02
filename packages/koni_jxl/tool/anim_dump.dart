import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';

/// Decodes an animated JXL and writes each frame as `<out>_N.pam` (RGBA).
void main(List<String> args) {
  final anim = JxlDecoder.decodeAnimation(
      Uint8List.fromList(File(args[0]).readAsBytesSync()));
  stdout.writeln('frames: ${anim.frames.length} durations: ${anim.durations} '
      'tps: ${anim.tpsNumerator}/${anim.tpsDenominator} '
      'loops: ${anim.numLoops}');
  for (var i = 0; i < anim.frames.length; i++) {
    final f = anim.frames[i];
    final rgba = f.toRgba8();
    final header = 'P7\nWIDTH ${f.width}\nHEIGHT ${f.height}\nDEPTH 4\n'
        'MAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n';
    final out = BytesBuilder()
      ..add(header.codeUnits)
      ..add(rgba);
    File('${args[1]}_$i.pam').writeAsBytesSync(out.toBytes());
  }
}
