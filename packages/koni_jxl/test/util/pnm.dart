import 'dart:typed_data';

/// Minimal PNM/PAM/PFM reader for djxl golden outputs.
final class PnmImage {
  PnmImage(this.width, this.height, this.channels, this.maxValue,
      this.intPlanes, this.floatPlanes);

  final int width;
  final int height;
  final int channels;
  final int maxValue; // 0 for float images
  final List<Int32List>? intPlanes;
  final List<Float32List>? floatPlanes;

  static PnmImage parse(Uint8List data) {
    final magic = String.fromCharCodes(data, 0, 2);
    return switch (magic) {
      'P5' => _parseBinaryPnm(data, 1),
      'P6' => _parseBinaryPnm(data, 3),
      'P7' => _parsePam(data),
      'PF' => _parsePfm(data, 3),
      'Pf' => _parsePfm(data, 1),
      _ => throw FormatException('unsupported PNM magic: $magic'),
    };
  }

  // --- helpers ---

  static (List<int>, int) _headerTokens(Uint8List data, int count) {
    // Returns `count` whitespace-separated tokens after the magic, skipping
    // comments, and the offset of the byte after the single whitespace that
    // terminates the header.
    final tokens = <int>[];
    var i = 2;
    while (tokens.length < count) {
      while (i < data.length &&
          (data[i] == 0x20 ||
              data[i] == 0x0A ||
              data[i] == 0x0D ||
              data[i] == 0x09)) {
        i++;
      }
      if (data[i] == 0x23) {
        while (data[i] != 0x0A) {
          i++;
        }
        continue;
      }
      var value = 0;
      while (i < data.length && data[i] >= 0x30 && data[i] <= 0x39) {
        value = value * 10 + (data[i] - 0x30);
        i++;
      }
      tokens.add(value);
    }
    return (tokens, i + 1); // single whitespace after last token
  }

  static PnmImage _parseBinaryPnm(Uint8List data, int channels) {
    final (tokens, offset) = _headerTokens(data, 3);
    final [width, height, maxValue] = tokens;
    final wide = maxValue > 255;
    final planes = List.generate(channels, (_) => Int32List(width * height));
    var p = offset;
    for (var i = 0; i < width * height; i++) {
      for (var c = 0; c < channels; c++) {
        planes[c][i] = wide ? (data[p] << 8) | data[p + 1] : data[p];
        p += wide ? 2 : 1;
      }
    }
    return PnmImage(width, height, channels, maxValue, planes, null);
  }

  static PnmImage _parsePam(Uint8List data) {
    // Header is ASCII lines until ENDHDR.
    var i = 0;
    var width = 0, height = 0, depth = 0, maxValue = 0;
    while (true) {
      var end = i;
      while (data[end] != 0x0A) {
        end++;
      }
      final line = String.fromCharCodes(data, i, end).trim();
      i = end + 1;
      if (line == 'ENDHDR') break;
      final parts = line.split(RegExp(r'\s+'));
      switch (parts[0]) {
        case 'WIDTH':
          width = int.parse(parts[1]);
        case 'HEIGHT':
          height = int.parse(parts[1]);
        case 'DEPTH':
          depth = int.parse(parts[1]);
        case 'MAXVAL':
          maxValue = int.parse(parts[1]);
      }
    }
    final wide = maxValue > 255;
    final planes = List.generate(depth, (_) => Int32List(width * height));
    var p = i;
    for (var px = 0; px < width * height; px++) {
      for (var c = 0; c < depth; c++) {
        planes[c][px] = wide ? (data[p] << 8) | data[p + 1] : data[p];
        p += wide ? 2 : 1;
      }
    }
    return PnmImage(width, height, depth, maxValue, planes, null);
  }

  static PnmImage _parsePfm(Uint8List data, int channels) {
    // PF/Pf: "PF\n<w> <h>\n<scale>\n" then float32 samples, bottom-up rows.
    var i = 2;
    final tokens = <String>[];
    while (tokens.length < 3) {
      while (data[i] == 0x20 || data[i] == 0x0A || data[i] == 0x0D) {
        i++;
      }
      final start = i;
      while (data[i] != 0x20 && data[i] != 0x0A && data[i] != 0x0D) {
        i++;
      }
      tokens.add(String.fromCharCodes(data, start, i));
    }
    i++; // single whitespace after scale
    final width = int.parse(tokens[0]);
    final height = int.parse(tokens[1]);
    final scale = double.parse(tokens[2]);
    final littleEndian = scale < 0;
    final bd = ByteData.sublistView(data, i);
    final planes = List.generate(channels, (_) => Float32List(width * height));
    var p = 0;
    for (var row = 0; row < height; row++) {
      final y = height - 1 - row; // bottom-up
      for (var x = 0; x < width; x++) {
        for (var c = 0; c < channels; c++) {
          planes[c][y * width + x] =
              bd.getFloat32(p, littleEndian ? Endian.little : Endian.big);
          p += 4;
        }
      }
    }
    return PnmImage(width, height, channels, 0, null, planes);
  }
}
