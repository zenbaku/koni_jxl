import 'package:koni_jxl/src/util/image_buffer.dart';
import 'package:koni_jxl/src/vardct/dct.dart';

void main() {
  final src = floatMatrix(256, 256);
  final dest = floatMatrix(256, 256);
  final s0 = floatMatrix(256, 256);
  final s1 = floatMatrix(256, 256);
  for (var y = 0; y < 256; y++) {
    for (var x = 0; x < 256; x++) {
      src[y][x] = ((x * 31 + y * 17) & 255) / 255.0;
    }
  }
  for (var rep = 0; rep < 2; rep++) {
    for (final n in [8, 16, 32, 64, 128, 256]) {
      final iters = (1 << 24) ~/ (n * n);
      final sw = Stopwatch()..start();
      for (var i = 0; i < iters; i++) {
        inverseDCT2D(src, dest, 0, 0, 0, 0, n, n, s0, s1, false);
      }
      final us = sw.elapsedMicroseconds / iters;
      final nsPx = (us / (n * n) * 1000).toStringAsFixed(1);
      print('n=$n: ${us.toStringAsFixed(1)} us/block ($nsPx ns/px)');
    }
  }
}
