import 'dart:io';
import 'dart:typed_data';

/// Minimal PNG reader for conformance references (`ref.png`): 8/16-bit,
/// colour types 0 (gray), 2 (RGB), 4 (gray+alpha), 6 (RGBA), no interlace.
/// Returns 8-bit samples (16-bit is high-byte-truncated — the references this
/// reads are 8-bit). Colour channels only are exposed; alpha is dropped.
final class PngImage {
  PngImage(this.width, this.height, this.colorChannels, this.planes);

  final int width;
  final int height;
  final int colorChannels; // 1 (gray) or 3 (RGB)
  final List<Uint8List> planes; // one per colour channel, row-major

  static PngImage parse(Uint8List d) {
    int be32(int o) =>
        (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];
    var i = 8; // skip signature
    final idat = <int>[];
    var w = 0, h = 0, bd = 8, ct = 0;
    while (i < d.length) {
      final len = be32(i);
      final type = String.fromCharCodes(d, i + 4, i + 8);
      if (type == 'IHDR') {
        w = be32(i + 8);
        h = be32(i + 12);
        bd = d[i + 16];
        ct = d[i + 17];
      } else if (type == 'IDAT') {
        idat.addAll(d.sublist(i + 8, i + 8 + len));
      } else if (type == 'IEND') {
        break;
      }
      i += 12 + len;
    }
    final raw = zlib.decode(idat);
    final ch = const {0: 1, 2: 3, 4: 2, 6: 4}[ct]!;
    final bpp = bd == 16 ? 2 : 1;
    final stride = w * ch * bpp;
    final bF = ch * bpp; // bytes per pixel, for filter left/up-left refs
    final samples = List.generate(ch, (_) => Uint8List(w * h));
    final prev = Uint8List(stride);
    var p = 0;
    for (var y = 0; y < h; y++) {
      final ft = raw[p++];
      final line = Uint8List.fromList(raw.sublist(p, p + stride));
      p += stride;
      for (var x = 0; x < stride; x++) {
        final a = x >= bF ? line[x - bF] : 0;
        final b = prev[x];
        final c = x >= bF ? prev[x - bF] : 0;
        var v = line[x];
        switch (ft) {
          case 1:
            v += a;
          case 2:
            v += b;
          case 3:
            v += (a + b) >> 1;
          case 4:
            final pp = a + b - c;
            final pa = (pp - a).abs(), pb = (pp - b).abs(), pc = (pp - c).abs();
            v += pa <= pb && pa <= pc ? a : (pb <= pc ? b : c);
        }
        line[x] = v & 0xff;
      }
      for (var x = 0; x < stride; x++) {
        prev[x] = line[x];
      }
      for (var x = 0; x < w * ch; x++) {
        samples[x % ch][y * w + x ~/ ch] = bd == 16 ? line[x * 2] : line[x];
      }
    }
    final colorCh = ch >= 3 ? 3 : 1;
    return PngImage(w, h, colorCh, samples.sublist(0, colorCh));
  }
}
