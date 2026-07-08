import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/src/color/icc_transform.dart';
import 'package:test/test.dart';

/// Builds a minimal matrix/TRC RGB ICC profile: `colorants` are the r/g/b
/// XYZ(D50) colorants as matrix columns; each channel gets a `curv` gamma TRC
/// (device^gamma = linear). Tags are packed tightly at explicit offsets (the
/// parser reads by offset, not alignment).
Uint8List _buildProfile(List<List<double>> colorants, double gamma) {
  final b = BytesBuilder();
  void be32(int v) =>
      b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
  // 128-byte header, RGB data space at bytes 16-19.
  final header = Uint8List(128);
  header.setAll(16, 'RGB '.codeUnits);
  b.add(header);
  const tags = ['rXYZ', 'gXYZ', 'bXYZ', 'rTRC', 'gTRC', 'bTRC'];
  const base = 128 + 4 + 6 * 12; // after header + tag table
  const xyzLen = 20, trcLen = 14;
  final offs = <int>[base, base + xyzLen, base + 2 * xyzLen];
  offs.add(base + 3 * xyzLen);
  offs.add(offs[3] + trcLen);
  offs.add(offs[3] + 2 * trcLen);
  be32(6);
  for (var i = 0; i < 6; i++) {
    b.add(tags[i].codeUnits);
    be32(offs[i]);
    be32(i < 3 ? xyzLen : trcLen);
  }
  int fix16(double v) => (v * 65536).round();
  for (var col = 0; col < 3; col++) {
    b.add('XYZ '.codeUnits);
    be32(0);
    for (var row = 0; row < 3; row++) {
      be32(fix16(colorants[row][col]));
    }
  }
  final g = (gamma * 256).round();
  for (var c = 0; c < 3; c++) {
    b.add('curv'.codeUnits);
    be32(0);
    be32(1); // count == 1 -> single gamma
    b.add([(g >> 8) & 0xff, g & 0xff]);
  }
  return b.toBytes();
}

void main() {
  // sRGB v4 D50-adapted colorants (must match icc_transform.dart's constant).
  const srgbD50 = [
    [0.436057, 0.385124, 0.143005],
    [0.222491, 0.716888, 0.060621],
    [0.013931, 0.097099, 0.713970],
  ];

  double gammaEncode(double lin, double g) => math.pow(lin, 1 / g).toDouble();

  test('identity primaries + gamma TRC: applies the inverse TRC', () {
    // colorants == sRGB_D50 -> M == identity, so output is just the gamma
    // encode of the linear input (verifies TRC inversion + the sRGB constant).
    final t = IccRgbOutputTransform.tryParse(_buildProfile(srgbD50, 2.2))!;
    final r = [
      Float32List.fromList([0.25, 0.5])
    ];
    final gp = [
      Float32List.fromList([0.25, 0.5])
    ];
    final bp = [
      Float32List.fromList([0.25, 0.5])
    ];
    t.apply(r, gp, bp);
    expect(r[0][0], closeTo(gammaEncode(0.25, 2.2), 2e-3));
    expect(r[0][1], closeTo(gammaEncode(0.5, 2.2), 2e-3));
    expect(bp[0][1], closeTo(gammaEncode(0.5, 2.2), 2e-3));
  });

  test('non-identity primaries: applies the colorant matrix then TRC', () {
    // colorants == 2 x sRGB_D50 -> profile RGB->XYZ is doubled, so
    // M = (2·sRGB)^-1 · sRGB = 0.5·I: a linear input is halved before the TRC.
    final scaled = [
      for (final row in srgbD50) [for (final v in row) v * 2],
    ];
    final t = IccRgbOutputTransform.tryParse(_buildProfile(scaled, 2.2))!;
    final r = [
      Float32List.fromList([0.4])
    ];
    final gp = [
      Float32List.fromList([0.4])
    ];
    final bp = [
      Float32List.fromList([0.4])
    ];
    t.apply(r, gp, bp);
    // 0.4 -> M(0.5·I) -> 0.2 -> gamma encode.
    expect(r[0][0], closeTo(gammaEncode(0.2, 2.2), 3e-3));
  });

  test('rejects non-RGB / LUT / incomplete profiles (falls back to sRGB)', () {
    // Too short.
    expect(IccRgbOutputTransform.tryParse(Uint8List(50)), isNull);
    // RGB header but no tags.
    final noTags = Uint8List(140);
    noTags.setAll(16, 'RGB '.codeUnits);
    expect(IccRgbOutputTransform.tryParse(noTags), isNull);
    // Grayscale data space is out of scope for this RGB transform.
    final gray = _buildProfile(srgbD50, 2.2);
    gray.setAll(16, 'GRAY'.codeUnits);
    expect(IccRgbOutputTransform.tryParse(gray), isNull);
  });
}
