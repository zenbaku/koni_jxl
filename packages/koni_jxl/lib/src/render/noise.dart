import 'dart:typed_data';

import '../frame/frame.dart';
import '../util/image_buffer.dart';
import '../util/math_helper.dart';

/// xorshift128+ with 8 lanes, matching the JXL noise RNG.
///
/// Every 64-bit lane is stored as an (hi, lo) pair of 32-bit-unsigned `int`s
/// rather than a single 64-bit value: dart2js's `int` cannot exactly
/// represent values, literals, or intermediate shift/multiply results above
/// 2^53, so a direct port (as this class used to be, backed by [Int64List])
/// fails to even compile for web ("integer literal ... can't be represented
/// exactly in JavaScript") and would be silently wrong at runtime even if it
/// did. Every operation below is deliberately mask-before-shift and
/// add-with-carry so no intermediate value ever exceeds 2^32, which keeps
/// every platform (VM, AOT, dart2js, dart2wasm) bit-identical.
final class XorShiro {
  XorShiro(int seed0Hi, int seed0Lo, int seed1Hi, int seed1Lo) {
    var (h, l) = _add64(seed0Hi, seed0Lo, 0x9e3779b9, 0x7f4a7c15);
    (h, l) = _splitMix64(h, l);
    _state0Hi[0] = h;
    _state0Lo[0] = l;
    (h, l) = _add64(seed1Hi, seed1Lo, 0x9e3779b9, 0x7f4a7c15);
    (h, l) = _splitMix64(h, l);
    _state1Hi[0] = h;
    _state1Lo[0] = l;
    for (var i = 1; i < 8; i++) {
      (h, l) = _splitMix64(_state0Hi[i - 1], _state0Lo[i - 1]);
      _state0Hi[i] = h;
      _state0Lo[i] = l;
      (h, l) = _splitMix64(_state1Hi[i - 1], _state1Lo[i - 1]);
      _state1Hi[i] = h;
      _state1Lo[i] = l;
    }
  }

  static final BigInt _mask64 = (BigInt.one << 64) - BigInt.one;
  static final BigInt _mul1 = BigInt.parse('bf58476d1ce4e5b9', radix: 16);
  static final BigInt _mul2 = BigInt.parse('94d049bb133111eb', radix: 16);

  /// The seeding-only mixing step: only ~16 calls per [XorShiro] (one per
  /// image group), so exactness via [BigInt] costs nothing that matters,
  /// and removes the error-prone part (a full 64x64 multiply) from the
  /// hand-rolled 32-bit-limb surface entirely.
  static (int, int) _splitMix64(int hi, int lo) {
    var z = (BigInt.from(hi) << 32) | BigInt.from(lo);
    z = ((z ^ (z >> 30)) * _mul1) & _mask64;
    z = ((z ^ (z >> 27)) * _mul2) & _mask64;
    z ^= z >> 31;
    return ((z >> 32).toInt(), (z & BigInt.from(0xFFFFFFFF)).toInt());
  }

  /// 64-bit add mod 2^64 on (hi, lo) uint32 pairs.
  static (int, int) _add64(int aHi, int aLo, int bHi, int bLo) {
    final loSum = aLo + bLo;
    return ((aHi + bHi + (loSum >> 32)) & 0xFFFFFFFF, loSum & 0xFFFFFFFF);
  }

  final Uint32List _state0Hi = Uint32List(8);
  final Uint32List _state0Lo = Uint32List(8);
  final Uint32List _state1Hi = Uint32List(8);
  final Uint32List _state1Lo = Uint32List(8);
  final Uint32List _batch = Uint32List(16);
  int _batchPos = 16;

  void fill(Uint32List bits) {
    for (var i = 0; i < bits.length; i++) {
      if (_batchPos >= 16) _fillBatch();
      bits[i] = _batch[_batchPos++];
    }
  }

  void _fillBatch() {
    for (var i = 0; i < 8; i++) {
      final aHi = _state1Hi[i];
      final aLo = _state1Lo[i];
      final bHi = _state0Hi[i];
      final bLo = _state0Lo[i];
      // c = a + b (64-bit, mod 2^64).
      final cLoSum = aLo + bLo;
      final cLo = cLoSum & 0xFFFFFFFF;
      final cHi = (aHi + bHi + (cLoSum >> 32)) & 0xFFFFFFFF;
      _state0Hi[i] = aHi;
      _state0Lo[i] = aLo;
      // b ^= b << 23 (64-bit shift). Every intermediate below is masked
      // BEFORE shifting (not after) so it never exceeds 2^32 - shifting
      // first and masking after would transiently need up to 2^55, which
      // dart2js's double-backed `int` can't represent exactly.
      final nbHi = bHi ^ (((bHi & 0x1FF) << 23) | (bLo >>> 9));
      final nbLo = bLo ^ ((bLo & 0x1FF) << 23);
      // state1 = b ^ a ^ (b >>> 18) ^ (a >>> 5), same 64-bit-shift rule.
      _state1Hi[i] = nbHi ^ aHi ^ (nbHi >>> 18) ^ (aHi >>> 5);
      _state1Lo[i] = nbLo ^
          aLo ^
          (((nbHi & 0x3FFFF) << 14) | (nbLo >>> 18)) ^
          (((aHi & 0x1F) << 27) | (aLo >>> 5));
      _batch[2 * i] = cLo;
      _batch[2 * i + 1] = cHi;
    }
    _batchPos = 0;
  }
}

const _laplacian = [
  [0.16, 0.16, 0.16, 0.16, 0.16],
  [0.16, 0.16, 0.16, 0.16, 0.16],
  [0.16, 0.16, -3.84, 0.16, 0.16],
  [0.16, 0.16, 0.16, 0.16, 0.16],
  [0.16, 0.16, 0.16, 0.16, 0.16],
];

/// Generates the per-group noise field (uniform [1,2) floats convolved with
/// a Laplacian kernel). Must run after upsampling, before synthesis.
///
/// [seed0Hi]/[seed0Lo] are the high/low 32 bits of the frame-wide 64-bit
/// seed (kept as a pair rather than one packed 64-bit int for the same
/// web-safety reason as [XorShiro]).
List<List<Float32List>>? initializeNoise(
    Frame frame, int seed0Hi, int seed0Lo) {
  if (frame.lfGlobal.noiseParameters == null) return null;
  final colors = frame.colorChannelCount;
  final height = frame.boundsHeight;
  final width = frame.boundsWidth;
  final localNoise = [
    for (var c = 0; c < colors; c++) floatMatrix(height, width),
  ];
  final bitsView = Uint32List(16);
  final floatView = Float32List.view(bitsView.buffer);
  for (var group = 0; group < frame.numGroups; group++) {
    final loc = frame.getGroupLocation(group);
    final y0 = loc.y << frame.header.logGroupDim;
    final x0 = loc.x << frame.header.logGroupDim;
    final ySize = frame.header.groupDim < height - y0
        ? frame.header.groupDim
        : height - y0;
    final xSize =
        frame.header.groupDim < width - x0 ? frame.header.groupDim : width - x0;
    final rng = XorShiro(seed0Hi, seed0Lo, x0 & 0xFFFFFFFF, y0 & 0xFFFFFFFF);
    for (var c = 0; c < colors; c++) {
      for (var y = 0; y < ySize; y++) {
        for (var x = 0; x < xSize; x += 16) {
          rng.fill(bitsView);
          for (var i = 0; i < 16 && x + i < xSize; i++) {
            bitsView[i] = (bitsView[i] >> 9) | 0x3f800000;
            localNoise[c][y0 + y][x0 + x + i] = floatView[i];
          }
        }
      }
    }
  }
  final noiseBuffer = [
    for (var c = 0; c < colors; c++) floatMatrix(height, width),
  ];
  for (var c = 0; c < colors; c++) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var total = 0.0;
        for (var iy = 0; iy < 5; iy++) {
          final cy = mirrorCoordinate(y + iy - 2, height);
          for (var ix = 0; ix < 5; ix++) {
            final cx = mirrorCoordinate(x + ix - 2, width);
            total += localNoise[c][cy][cx] * _laplacian[iy][ix];
          }
        }
        noiseBuffer[c][y][x] = total;
      }
    }
  }
  return noiseBuffer;
}

/// Adds synthesized noise to the (XYB-space) color channels.
void synthesizeNoise(Frame frame, List<List<Float32List>>? noiseBuffer) {
  final lut = frame.lfGlobal.noiseParameters;
  if (lut == null || noiseBuffer == null) return;
  final buffers = [
    for (var c = 0; c < 3; c++) frame.buffer[c].floatRows,
  ];
  final lfc = frame.lfGlobal.lfChanCorr;
  for (var y = 0; y < frame.boundsHeight; y++) {
    for (var x = 0; x < frame.boundsWidth; x++) {
      var inScaledR = buffers[1][y][x] + buffers[0][y][x];
      inScaledR = inScaledR < 0 ? 0 : 3 * inScaledR;
      var inScaledG = buffers[1][y][x] - buffers[0][y][x];
      inScaledG = inScaledG < 0 ? 0 : 3 * inScaledG;
      int intInR;
      double fracInR;
      if (inScaledR >= 7.0) {
        intInR = 6;
        fracInR = 1.0;
      } else {
        intInR = inScaledR.truncate();
        fracInR = inScaledR - intInR;
      }
      int intInG;
      double fracInG;
      if (inScaledG >= 7.0) {
        intInG = 6;
        fracInG = 1.0;
      } else {
        intInG = inScaledG.truncate();
        fracInG = inScaledG - intInG;
      }
      var sr = (lut[intInR + 1] - lut[intInR]) * fracInR + lut[intInR];
      var sg = (lut[intInG + 1] - lut[intInG]) * fracInG + lut[intInG];
      sr = sr < 0
          ? 0
          : sr > 1
              ? 1
              : sr;
      sg = sg < 0
          ? 0
          : sg > 1
              ? 1
              : sg;
      final nr = sr *
          (0.00171875 * noiseBuffer[0][y][x] +
              0.21828125 * noiseBuffer[2][y][x]);
      final ng = sg *
          (0.00171875 * noiseBuffer[1][y][x] +
              0.21828125 * noiseBuffer[2][y][x]);
      final nrg = nr + ng;
      buffers[1][y][x] += nrg;
      buffers[0][y][x] += lfc.baseCorrelationX * nrg + nr - ng;
      buffers[2][y][x] += lfc.baseCorrelationB * nrg;
    }
  }
}
