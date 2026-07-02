import 'package:koni_jxl/src/util/image_buffer.dart';
import 'package:koni_jxl/src/vardct/dct.dart';

void main() {
  final coeffs = floatMatrix(256, 256);
  final dest = floatMatrix(256, 256);
  final s0 = floatMatrix(256, 256);
  final s1 = floatMatrix(256, 256);
  for (var y = 0; y < 256; y++) {
    for (var x = 0; x < 256; x++) {
      coeffs[y][x] = (x * 31 + y * 17) % 255 / 255.0;
    }
  }
  const n = 120000;
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    inverseDCT2D(coeffs, dest, 0, 0, 0, 0, 8, 8, s0, s1, false);
  }
  print('8x8 inverseDCT2D x$n: ${sw.elapsedMilliseconds} ms '
      '(${sw.elapsedMicroseconds / n} us each)');

  sw
    ..reset()
    ..start();
  for (var i = 0; i < n; i++) {
    inverseDCTHorizontal(coeffs[0], dest[0], 0, 0, 3, 8);
  }
  print('idct row x$n: ${sw.elapsedMicroseconds / n} us each');
}
