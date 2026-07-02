import 'dart:typed_data';

import '../exceptions.dart';
import '../io/bit_reader.dart';

/// The `Extensions` bundle: 64 optional payloads gated by a bitmask key.
/// Payload contents are opaque; they are read and retained but not
/// interpreted.
final class Extensions {
  const Extensions()
      : extensionsKey = 0,
        _payloads = const [];

  factory Extensions.read(BitReader reader) {
    final extensionsKey = reader.readU64();
    final lengths = List<int>.filled(64, -1);
    for (var i = 0; i < 64; i++) {
      if ((1 << i) & extensionsKey != 0) {
        final length = reader.readU64();
        if (length < 0 || length > 0x7FFFFFFF) {
          throw const JxlInvalidBitstreamException(
              'extension payload too large');
        }
        lengths[i] = length;
      }
    }
    final payloads = List<Uint8List?>.filled(64, null);
    for (var i = 0; i < 64; i++) {
      final length = lengths[i];
      if (length >= 0) {
        final buf = Uint8List(length);
        for (var j = 0; j < length; j++) {
          buf[j] = reader.readBits(8);
        }
        payloads[i] = buf;
      }
    }
    return Extensions._(extensionsKey, payloads);
  }

  const Extensions._(this.extensionsKey, this._payloads);

  final int extensionsKey;
  final List<Uint8List?> _payloads;

  Uint8List? operator [](int extId) =>
      extId < _payloads.length ? _payloads[extId] : null;
}
