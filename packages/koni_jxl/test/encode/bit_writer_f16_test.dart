import 'package:koni_jxl/src/io/bit_reader.dart';
import 'package:koni_jxl/src/io/bit_writer.dart';
import 'package:test/test.dart';

double _roundTrip(double v) {
  final w = BitWriter()..writeF16(v);
  final bytes = w.toBytes();
  return BitReader(bytes).readF16();
}

void main() {
  test('writeF16 round-trips representative quantizer parameter values', () {
    for (final v in [
      1.0,
      -1.0,
      0.0,
      3150.0,
      560.0,
      512.0,
      -0.4,
      -0.3,
      -2.0,
      49.21875, // 3150 / 64
      8.75, // 560 / 64
      8.0,
      65504.0, // largest finite half value
      100000.0, // overflow -> clamps to 65504
      0.001,
    ]) {
      final got = _roundTrip(v);
      if (v.abs() >= 100000.0) {
        expect(got, closeTo(65504.0, 1.0));
      } else if (v == 0.0) {
        expect(got, 0.0);
      } else {
        // Half precision has ~3 significant decimal digits.
        expect(got, closeTo(v, v.abs() * 0.01 + 1e-6));
      }
    }
  });
}
