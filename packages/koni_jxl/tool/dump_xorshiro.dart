import 'dart:io';
import 'dart:typed_data';

import 'package:koni_jxl/src/render/noise.dart';

/// Dumps XorShiro output for a spread of 64-bit seeds (zero, small,
/// high-bit-set, carry-boundary, arbitrary) to a text file — used to
/// differentially verify the rewritten (hi, lo)-pair implementation
/// produces byte-identical output to the original Int64List-backed one
/// (see noise.dart's 64-bit-safe rewrite). Each original 64-bit seed is
/// split into (hi, lo) exactly as `_add64`'s 0x9e3779b97f4a7c15 constant is:
/// hi = seed's top 32 bits (as unsigned), lo = seed's bottom 32 bits.
void main(List<String> args) {
  final seeds = <(int, int)>[
    (0, 0),
    (1, 0),
    (0, 1),
    (-1, -1), // all bits set: 0xFFFFFFFFFFFFFFFF as a signed 64-bit int
    (0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF),
    (0x100000000, 0x100000000), // exactly at the 32-bit carry boundary
    (0xFFFFFFFF, 0xFFFFFFFF), // low 32 bits all set, high 32 bits zero
    (12345, 67890),
    (0x123456789ABCDEF0, 0x0FEDCBA987654321),
    (42, 42),
  ];
  final out = StringBuffer();
  for (final (s0, s1) in seeds) {
    final s0Hi = (s0 >>> 32) & 0xFFFFFFFF;
    final s0Lo = s0 & 0xFFFFFFFF;
    final s1Hi = (s1 >>> 32) & 0xFFFFFFFF;
    final s1Lo = s1 & 0xFFFFFFFF;
    final rng = XorShiro(s0Hi, s0Lo, s1Hi, s1Lo);
    final bits = Uint32List(64);
    rng.fill(bits);
    out.writeln('$s0,$s1: ${bits.join(",")}');
  }
  File(args[0]).writeAsStringSync(out.toString());
  print('wrote ${args[0]}');
}
