import 'dart:math' as math;
import 'dart:typed_data';

import '../exceptions.dart';
import '../frame/frame.dart';
import '../io/bit_reader.dart';
import '../modular/modular_channel.dart';
import '../modular/modular_stream.dart';
import '../util/image_buffer.dart' show floatMatrix;
import '../util/math_helper.dart';
import 'transform_type.dart';

final class DctParams {
  const DctParams(this.dctParam, this.param, this.mode,
      {this.params4x4, this.denominator = 1});

  final List<List<double>>? dctParam;
  final List<List<double>>? param;
  final List<List<double>>? params4x4;
  final int mode;
  final double denominator;
}

const _afvFreqs = <double>[
  0, 0, 0.8517778890324296, 5.37778436506804, //
  0, 0, 4.734747904497923, 5.449245381693219, //
  1.6598270267479331, 4, 7.275749096817861, 10.423227632456525, //
  2.662932286148962, 7.630657783650829, 8.962388608184032, 12.97166202570235,
];

const _seqA = <double>[
  -1.025, -0.78, -0.65012, -0.19041574084286472, -0.20819395464, -0.421064,
  -0.32733845535848671, //
];
const _seqB = <double>[
  -0.3041958212306401, -0.3633036457487539, -0.35660379990111464,
  -0.3443074455424403, -0.33699592683512467, -0.30180866526242109,
  -0.27321683125358037, //
];
const _seqC = <double>[-1.2, -1.2, -0.8, -0.7, -0.7, -0.4, -0.5];

List<double> _prepend(double a, List<double> rest) => [a, ...rest];

const _dct4x4Params = <List<double>>[
  [2200, 0.0, 0.0, 0.0],
  [392, 0.0, 0.0, 0.0],
  [112, -0.25, -0.25, -0.5],
];

const _dct4x8Params = <List<double>>[
  [
    2198.050556016380522,
    -0.96269623020744692,
    -0.76194253026666783,
    -0.6551140670773547
  ], //
  [
    764.3655248643528689,
    -0.92630200888366945,
    -0.9675229603596517,
    -0.27845290869168118
  ], //
  [
    527.107573587542228,
    -1.4594385811273854,
    -1.450082094097871593,
    -1.5843722511996204
  ], //
];

final List<DctParams> defaultDctParams = [
  const DctParams([
    [3150.0, 0.0, -0.4, -0.4, -0.4, -2.0],
    [560.0, 0.0, -0.3, -0.3, -0.3, -0.3],
    [512.0, -2.0, -1.0, 0.0, -1.0, -2.0],
  ], null, TransformMode.dct),
  const DctParams(
      null,
      [
        [280.0, 3160.0, 3160.0],
        [60.0, 864.0, 864.0],
        [18.0, 200.0, 200.0],
      ],
      TransformMode.hornuss),
  const DctParams(
      null,
      [
        [3840.0, 2560.0, 1280.0, 640.0, 480.0, 300.0],
        [960.0, 640.0, 320.0, 180.0, 140.0, 120.0],
        [640.0, 320.0, 128.0, 64.0, 32.0, 16.0],
      ],
      TransformMode.dct2),
  const DctParams(
      _dct4x4Params,
      [
        [1.0, 1.0],
        [1.0, 1.0],
        [1.0, 1.0],
      ],
      TransformMode.dct4,
      params4x4: _dct4x4Params),
  const DctParams([
    [
      8996.8725711814115328,
      -1.3000777393353804,
      -0.49424529824571225,
      -0.439093774457103443,
      -0.6350101832695744,
      -0.90177264050827612,
      -1.6162099239887414
    ], //
    [
      3191.48366296844234752,
      -0.67424582104194355,
      -0.80745813428471001,
      -0.44925837484843441,
      -0.35865440981033403,
      -0.31322389111877305,
      -0.37615025315725483
    ], //
    [
      1157.50408145487200256,
      -2.0531423165804414,
      -1.4,
      -0.50687130033378396,
      -0.42708730624733904,
      -1.4856834539296244,
      -4.9209142884401604
    ], //
  ], null, TransformMode.dct),
  const DctParams([
    [
      15718.40830982518931456,
      -1.025,
      -0.98,
      -0.9012,
      -0.4,
      -0.48819395464,
      -0.421064,
      -0.27
    ], //
    [
      7305.7636810695983104,
      -0.8041958212306401,
      -0.7633036457487539,
      -0.55660379990111464,
      -0.49785304658857626,
      -0.43699592683512467,
      -0.40180866526242109,
      -0.27321683125358037
    ], //
    [
      3803.53173721215041536,
      -3.060733579805728,
      -2.0413270132490346,
      -2.0235650159727417,
      -0.5495389509954993,
      -0.4,
      -0.4,
      -0.3
    ], //
  ], null, TransformMode.dct),
  const DctParams([
    [7240.7734393502, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5],
    [1448.15468787004, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2],
    [506.854140754517, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6],
  ], null, TransformMode.dct),
  const DctParams([
    [
      16283.2494710648897,
      -1.7812845336559429,
      -1.6309059012653515,
      -1.0382179034313539,
      -0.85,
      -0.7,
      -0.9,
      -1.2360638576849587
    ], //
    [
      5089.15750884921511936,
      -0.320049391452786891,
      -0.35362849922161446,
      -0.30340000000000003,
      -0.61,
      -0.5,
      -0.5,
      -0.6
    ], //
    [
      3397.77603275308720128,
      -0.321327362693153371,
      -0.34507619223117997,
      -0.70340000000000003,
      -0.9,
      -1.0,
      -1.0,
      -1.1754605576265209
    ], //
  ], null, TransformMode.dct),
  const DctParams([
    [
      13844.97076442300573,
      -0.97113799999999995,
      -0.658,
      -0.42026,
      -0.22712,
      -0.2206,
      -0.226,
      -0.6
    ], //
    [
      4798.964084220744293,
      -0.61125308982767057,
      -0.83770786552491361,
      -0.79014862079498627,
      -0.2692727459704829,
      -0.38272769465388551,
      -0.22924222653091453,
      -0.20719098826199578
    ], //
    [1807.236946760964614, -1.2, -1.2, -0.7, -0.7, -0.7, -0.4, -0.5], //
  ], null, TransformMode.dct),
  const DctParams(
      _dct4x8Params,
      [
        [1.0],
        [1.0],
        [1.0],
      ],
      TransformMode.dct4x8),
  const DctParams(
      _dct4x8Params,
      [
        [3072, 3072, 256, 256, 256, 414, 0.0, 0.0, 0.0],
        [1024, 1024, 50.0, 50.0, 50.0, 58, 0.0, 0.0, 0.0],
        [384, 384, 12.0, 12.0, 12.0, 22, -0.25, -0.25, -0.25],
      ],
      TransformMode.afv,
      params4x4: _dct4x4Params),
  DctParams([
    _prepend(23966.1665298448605, _seqA),
    _prepend(8380.19148390090414, _seqB),
    _prepend(4493.02378009847706, _seqC),
  ], null, TransformMode.dct),
  DctParams([
    _prepend(15358.89804933239925, _seqA),
    _prepend(5597.360516150652990, _seqB),
    _prepend(2919.961618960011210, _seqC),
  ], null, TransformMode.dct),
  DctParams([
    _prepend(47932.3330596897210, _seqA),
    _prepend(16760.38296780180828, _seqB),
    _prepend(8986.04756019695412, _seqC),
  ], null, TransformMode.dct),
  DctParams([
    _prepend(30717.796098664792, _seqA),
    _prepend(11194.72103230130598, _seqB),
    _prepend(5839.92323792002242, _seqC),
  ], null, TransformMode.dct),
  DctParams([
    _prepend(95864.6661193794420, _seqA),
    _prepend(33520.76593560361656, _seqB),
    _prepend(17972.09512039390824, _seqC),
  ], null, TransformMode.dct),
  DctParams([
    _prepend(61435.5921973295970, _seqA),
    _prepend(24209.44206460261196, _seqB),
    _prepend(12979.84647584004484, _seqC),
  ], null, TransformMode.dct),
];

double _quantMult(double v) => v >= 0 ? 1.0 + v : 1.0 / (1.0 - v);

double _interpolate(double scaledPos, List<double> bands) {
  final len = bands.length - 1;
  if (len == 0) return bands[0];
  final scaledIndex = scaledPos.truncate();
  final fracIndex = scaledPos - scaledIndex;
  if (scaledIndex + 1 > len) return bands[len];
  final a = bands[scaledIndex];
  final b = bands[scaledIndex + 1];
  return a * math.pow(b / a, fracIndex);
}

List<Float32List> _getDCTQuantWeights(
    int height, int width, List<double> params) {
  final bands = List<double>.filled(params.length, 0);
  bands[0] = params[0];
  for (var i = 1; i < bands.length; i++) {
    bands[i] = bands[i - 1] * _quantMult(params[i]);
  }
  final weights =
      List.generate(height, (_) => Float32List(width), growable: false);
  final scale = (bands.length - 1) / (math.sqrt2 + 1e-6);
  for (var y = 0; y < height; y++) {
    final dy = y * scale / (height - 1);
    final dy2 = dy * dy;
    for (var x = 0; x < width; x++) {
      final dx = x * scale / (width - 1);
      final dist = math.sqrt(dx * dx + dy2);
      weights[y][x] = _interpolate(dist, bands);
    }
  }
  return weights;
}

/// HfGlobal: the 17 dequantization weight matrices plus the HF preset count.
final class HfGlobal {
  HfGlobal(BitReader reader, Frame frame) {
    final quantAllDefault = reader.readBool();
    if (quantAllDefault) {
      params = defaultDctParams;
    } else {
      params = List.generate(17, (i) => _setupDctParam(reader, frame, i));
    }
    weights =
        List.generate(17, (_) => List<List<Float32List>?>.filled(3, null));
    // Weight generation (incl. large-matrix interpolation) is deferred to
    // first use per parameter index: most images use few transform types.
    weightsFlat = List.generate(17, (_) => List<Float32List?>.filled(3, null));
    weightsFlatV =
        List.generate(17, (_) => List<Float32x4List?>.filled(3, null));
    weightsFlatTV =
        List.generate(17, (_) => List<Float32x4List?>.filled(3, null));
    weightsWidth = List<int>.filled(17, 0);
    numHfPresets = 1 + reader.readBits(ceilLog1p(frame.numGroups - 1));
  }

  late List<DctParams> params;
  final List<bool> _weightsReady = List<bool>.filled(17, false);

  /// Generates (once) and returns the flattened weight matrices for a
  /// parameter index.
  List<Float32List?> flatWeightsFor(int index) {
    if (!_weightsReady[index]) {
      _generateWeights(index);
      for (var ch = 0; ch < 3; ch++) {
        final w = weights[index][ch];
        if (w == null) continue;
        final rows = w.length;
        final cols = w[0].length;
        weightsWidth[index] = cols;
        final flat = Float32List(rows * cols);
        for (var y = 0; y < rows; y++) {
          flat.setRange(y * cols, (y + 1) * cols, w[y]);
        }
        weightsFlat[index][ch] = flat;
        weightsFlatV[index][ch] =
            Float32x4List.view(flat.buffer, 0, flat.length >> 2);
        // Transposed copy: flipped transforms read weights column-major,
        // which this turns back into row-major (y * pixelWidth + x).
        final flatT = Float32List(rows * cols);
        for (var y = 0; y < rows; y++) {
          for (var x = 0; x < cols; x++) {
            flatT[x * rows + y] = flat[y * cols + x];
          }
        }
        weightsFlatTV[index][ch] =
            Float32x4List.view(flatT.buffer, 0, flatT.length >> 2);
      }
      _weightsReady[index] = true;
    }
    return weightsFlat[index];
  }

  late final List<List<List<Float32List>?>> weights;
  late final List<List<Float32List?>> weightsFlat;
  late final List<List<Float32x4List?>> weightsFlatV;
  late final List<List<Float32x4List?>> weightsFlatTV;
  late final List<int> weightsWidth;
  late final int numHfPresets;

  static List<List<double>> _readDCTParams(BitReader reader) {
    final numParams = 1 + reader.readBits(4);
    return List.generate(3, (c) {
      final vals = List<double>.generate(numParams, (_) => reader.readF16());
      vals[0] *= 64.0;
      return vals;
    });
  }

  DctParams _setupDctParam(BitReader reader, Frame frame, int index) {
    final encodingMode = reader.readBits(3);
    TransformType.validateIndex(index, encodingMode);
    switch (encodingMode) {
      case TransformMode.library:
        return defaultDctParams[index];
      case TransformMode.hornuss:
        final m = List.generate(
            3, (_) => List<double>.generate(3, (_) => 64.0 * reader.readF16()));
        return DctParams(null, m, encodingMode);
      case TransformMode.dct2:
        final m = List.generate(
            3, (_) => List<double>.generate(6, (_) => 64.0 * reader.readF16()));
        return DctParams(null, m, encodingMode);
      case TransformMode.dct4:
        final m = List.generate(
            3, (_) => List<double>.generate(2, (_) => 64.0 * reader.readF16()));
        return DctParams(_readDCTParams(reader), m, encodingMode);
      case TransformMode.dct:
        return DctParams(_readDCTParams(reader), null, encodingMode);
      case TransformMode.raw:
        final den = reader.readF16();
        final tt = TransformType.byParameterIndex(index);
        final info = [
          ModularChannel(tt.matrixHeight, tt.matrixWidth, 0, 0),
          ModularChannel(tt.matrixHeight, tt.matrixWidth, 0, 0),
          ModularChannel(tt.matrixHeight, tt.matrixWidth, 0, 0),
        ];
        final stream = ModularStream.read(reader, frame.modularContext,
            streamIndex: 1 + 3 * frame.numLfGroups + index, channelArray: info);
        stream.decodeChannels(reader);
        final m = List.generate(
            3, (_) => List<double>.filled(tt.matrixHeight * tt.matrixWidth, 0));
        for (var c = 0; c < 3; c++) {
          final chan = stream.getChannel(c);
          final b = chan.buffer!;
          for (var i = 0; i < b.length; i++) {
            m[c][i] = b[i].toDouble();
          }
        }
        return DctParams(null, m, encodingMode, denominator: den);
      case TransformMode.dct4x8:
        final m = List.generate(
            3, (_) => List<double>.generate(1, (_) => reader.readF16()));
        return DctParams(_readDCTParams(reader), m, encodingMode);
      case TransformMode.afv:
        final m = List.generate(
            3,
            (_) => List<double>.generate(
                9, (x) => x < 6 ? 64.0 * reader.readF16() : reader.readF16()));
        final d = _readDCTParams(reader);
        final f = _readDCTParams(reader);
        return DctParams(d, m, encodingMode, params4x4: f);
      default:
        throw const JxlInvalidBitstreamException('invalid quant mode');
    }
  }

  List<Float32List> _getAFVTransformWeights(int index, int c) {
    final p = params[index];
    final weights4x8 = _getDCTQuantWeights(4, 8, p.dctParam![c]);
    final weights4x4 = _getDCTQuantWeights(4, 4, p.params4x4![c]);
    const low = 0.8517778890324296;
    const high = 12.97166202570235;
    final bands = List<double>.filled(4, 0);
    bands[0] = p.param![c][5];
    if (bands[0] < 0) {
      throw const JxlInvalidBitstreamException('negative band value');
    }
    for (var i = 1; i < 4; i++) {
      bands[i] = bands[i - 1] * _quantMult(p.param![c][i + 5]);
      if (bands[i] < 0) {
        throw const JxlInvalidBitstreamException('negative band value');
      }
    }
    final weight = floatMatrix(8, 8);
    weight[0][0] = 1.0;
    weight[1][0] = p.param![c][0];
    weight[0][1] = p.param![c][1];
    weight[2][0] = p.param![c][2];
    weight[0][2] = p.param![c][3];
    weight[2][2] = p.param![c][4];
    for (var y = 0; y < 4; y++) {
      for (var x = 0; x < 4; x++) {
        if (x < 2 && y < 2) continue;
        final pos = (_afvFreqs[y * 4 + x] - low) / (high - low);
        weight[2 * x][2 * y] = _interpolate(pos, bands);
      }
      for (var x = 0; x < 8; x++) {
        if (x == 0 && y == 0) continue;
        weight[2 * y + 1][x] = weights4x8[y][x];
      }
      for (var x = 0; x < 4; x++) {
        if (x == 0 && y == 0) continue;
        weight[2 * y][2 * x + 1] = weights4x4[y][x];
      }
    }
    return weight;
  }

  void _generateWeights(int index) {
    final tt = TransformType.byParameterIndex(index);
    final p = params[index];
    for (var c = 0; c < 3; c++) {
      switch (p.mode) {
        case TransformMode.dct:
          weights[index][c] = _getDCTQuantWeights(
              tt.matrixHeight, tt.matrixWidth, p.dctParam![c]);
        case TransformMode.dct4:
          final target = floatMatrix(8, 8);
          final w = _getDCTQuantWeights(4, 4, p.dctParam![c]);
          for (var y = 0; y < 8; y++) {
            for (var x = 0; x < 8; x++) {
              target[y][x] = w[y ~/ 2][x ~/ 2];
            }
          }
          target[1][0] /= p.param![c][0];
          target[0][1] /= p.param![c][0];
          target[1][1] /= p.param![c][1];
          weights[index][c] = target;
        case TransformMode.dct2:
          final w = floatMatrix(8, 8);
          w[0][0] = 1.0;
          w[0][1] = w[1][0] = p.param![c][0];
          w[1][1] = p.param![c][1];
          for (var y = 0; y < 2; y++) {
            for (var x = 0; x < 2; x++) {
              w[y][x + 2] = w[x + 2][y] = p.param![c][2];
              w[y + 2][x + 2] = p.param![c][3];
            }
          }
          for (var y = 0; y < 4; y++) {
            for (var x = 0; x < 4; x++) {
              w[y][x + 4] = w[x + 4][y] = p.param![c][4];
              w[y + 4][x + 4] = p.param![c][5];
            }
          }
          weights[index][c] = w;
        case TransformMode.hornuss:
          final w = floatMatrix(8, 8);
          for (var y = 0; y < 8; y++) {
            for (var x = 0; x < 8; x++) {
              w[y][x] = p.param![c][0];
            }
          }
          w[1][1] = p.param![c][2];
          w[0][1] = w[1][0] = p.param![c][1];
          w[0][0] = 1.0;
          weights[index][c] = w;
        case TransformMode.dct4x8:
          final target = floatMatrix(8, 8);
          final w = _getDCTQuantWeights(4, 8, p.dctParam![c]);
          for (var y = 0; y < 8; y++) {
            for (var x = 0; x < 8; x++) {
              target[y][x] = w[y ~/ 2][x];
            }
          }
          target[1][0] /= p.param![c][0];
          weights[index][c] = target;
        case TransformMode.afv:
          weights[index][c] = _getAFVTransformWeights(index, c);
        case TransformMode.raw:
          final w = floatMatrix(tt.matrixHeight, tt.matrixWidth);
          for (var y = 0; y < tt.matrixHeight; y++) {
            for (var x = 0; x < tt.matrixWidth; x++) {
              w[y][x] = p.param![c][y * tt.matrixWidth + x] * p.denominator;
            }
          }
          weights[index][c] = w;
        default:
          throw const JxlInvalidBitstreamException('invalid quant mode');
      }
    }
    if (p.mode != TransformMode.raw) {
      for (var c = 0; c < 3; c++) {
        final w = weights[index][c]!;
        for (var y = 0; y < tt.matrixHeight; y++) {
          for (var x = 0; x < tt.matrixWidth; x++) {
            if (w[y][x] <= 0 || !w[y][x].isFinite) {
              throw const JxlInvalidBitstreamException(
                  'negative or infinite quant weight');
            }
            w[y][x] = 1.0 / w[y][x];
          }
        }
      }
    }
  }
}
