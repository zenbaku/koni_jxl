import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:koni_jxl/koni_jxl.dart';

/// Empirical web-decode oracle: decodes each given .jxl file and prints an
/// MD5 of the resulting RGBA pixels plus width/height, so the SAME script
/// compiled for native (`dart run`) and for web (`dart compile js` + node,
/// fed base64-embedded bytes) can be diffed line-for-line. Catches any
/// dart2js numeric-precision divergence (large shifts, values beyond 2^53)
/// that a plain "does it throw" check would miss.
void main(List<String> args) {
  for (final path in args) {
    final bytes = File(path).readAsBytesSync();
    final image = JxlDecoder.decode(bytes);
    final rgba = image.toRgba8();
    final digest = md5.convert(rgba);
    print('$path: ${image.width}x${image.height} md5=$digest');
  }
}
