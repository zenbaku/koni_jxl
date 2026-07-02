import 'dart:io';
import 'dart:math' as math;

import 'package:koni_jxl/koni_jxl.dart';

void main(List<String> args) {
  for (final path in args) {
    final bytes = File(path).readAsBytesSync();
    final dec = JxlStreamingDecoder();
    int? headerAt;
    int? dcAt;
    const chunk = 512;
    for (var off = 0; off < bytes.length; off += chunk) {
      dec.addBytes(bytes.sublist(off, math.min(off + chunk, bytes.length)));
      final s = dec.state;
      if (headerAt == null && s.index >= JxlStreamState.headersReady.index) {
        headerAt = dec.bytesReceived;
      }
      if (dcAt == null && s.index >= JxlStreamState.dcReady.index) {
        dcAt = dec.bytesReceived;
      }
    }
    final name = path.split('/').last;
    if (dec.state != JxlStreamState.complete) {
      print('$name: NOT COMPLETE (state=${dec.state}, p=${dec.progress})');
      continue;
    }
    final preview = dec.decodePreview();
    final full = dec.decodeFinal();
    var msg = '$name: hdr@$headerAt dc@$dcAt/${bytes.length} '
        '(${(100.0 * (dcAt ?? 0) / bytes.length).toStringAsFixed(1)}%)';
    if (preview != null) {
      // box-downscale full by 8 and compare
      final pw = preview.width;
      final ph = preview.height;
      final fullRgba = full.toRgba8();
      final prevRgba = preview.toRgba8();
      var sq = 0.0;
      var n = 0;
      for (var y = 0; y < ph; y++) {
        for (var x = 0; x < pw; x++) {
          for (var c = 0; c < 3; c++) {
            var sum = 0;
            var cnt = 0;
            for (var dy = 0; dy < 8; dy++) {
              for (var dx = 0; dx < 8; dx++) {
                final fy = y * 8 + dy;
                final fx = x * 8 + dx;
                if (fy < full.height && fx < full.width) {
                  sum += fullRgba[(fy * full.width + fx) * 4 + c];
                  cnt++;
                }
              }
            }
            final d = prevRgba[(y * pw + x) * 4 + c] - sum / cnt;
            sq += d * d;
            n++;
          }
        }
      }
      msg += ' preview ${pw}x$ph rmse=${math.sqrt(sq / n).toStringAsFixed(2)}';
    } else {
      msg += ' preview=null';
    }
    print(msg);
  }
}
