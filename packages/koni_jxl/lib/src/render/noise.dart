import 'dart:typed_data';

import '../frame/frame.dart';
import '../util/image_buffer.dart';
import '../util/math_helper.dart';

/// xorshift128+ with 8 lanes, matching the JXL noise RNG.
final class XorShiro {
  XorShiro(int seed0, int seed1) {
    _state0[0] = _splitMix64(seed0 + 0x9e3779b97f4a7c15);
    _state1[0] = _splitMix64(seed1 + 0x9e3779b97f4a7c15);
    for (var i = 1; i < 8; i++) {
      _state0[i] = _splitMix64(_state0[i - 1]);
      _state1[i] = _splitMix64(_state1[i - 1]);
    }
  }

  static int _splitMix64(int z) {
    z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >>> 27)) * 0x94d049bb133111eb;
    return z ^ (z >>> 31);
  }

  final Int64List _state0 = Int64List(8);
  final Int64List _state1 = Int64List(8);
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
      final a = _state1[i];
      var b = _state0[i];
      final c = a + b;
      _state0[i] = a;
      b ^= b << 23;
      _state1[i] = b ^ a ^ (b >>> 18) ^ (a >>> 5);
      _batch[2 * i] = c & 0xFFFFFFFF;
      _batch[2 * i + 1] = c >>> 32;
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
List<List<Float32List>>? initializeNoise(Frame frame, int seed0) {
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
    final seed1 = ((x0 & 0xFFFFFFFF) << 32) | (y0 & 0xFFFFFFFF);
    final ySize = frame.header.groupDim < height - y0
        ? frame.header.groupDim
        : height - y0;
    final xSize =
        frame.header.groupDim < width - x0 ? frame.header.groupDim : width - x0;
    final rng = XorShiro(seed0, seed1);
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
