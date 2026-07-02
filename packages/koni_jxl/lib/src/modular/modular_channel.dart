import 'dart:typed_data';

import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';
import 'ma_tree.dart';
import 'wp_params.dart';

final Int32List _oneL24OverKP1 = () {
  final table = Int32List(64);
  for (var i = 0; i < 64; i++) {
    table[i] = (1 << 24) ~/ (i + 1);
  }
  return table;
}();

@pragma('vm:prefer-inline')
int _clamp3(int v, int a, int b) {
  final lower = a < b ? a : b;
  final upper = lower ^ a ^ b;
  return v < lower
      ? lower
      : v > upper
          ? upper
          : v;
}

@pragma('vm:prefer-inline')
int _clamp4(int v, int a, int b, int c) {
  var lower = a < b ? a : b;
  var upper = lower ^ a ^ b;
  lower = lower < c ? lower : c;
  upper = upper > c ? upper : c;
  return v < lower
      ? lower
      : v > upper
          ? upper
          : v;
}

/// Squeeze "tendency" (the smooth predictor of the squeeze transform).
int tendency(int a, int b, int c) {
  if (a >= b && b >= c) {
    var x = (4 * a - 3 * c - b + 6) ~/ 12;
    final d = 2 * (a - b);
    final e = 2 * (b - c);
    if (x - (x & 1) > d) x = d + 1;
    if (x + (x & 1) > e) x = e;
    return x;
  }
  if (a <= b && b <= c) {
    var x = (4 * a - 3 * c - b - 6) ~/ 12;
    final d = 2 * (a - b);
    final e = 2 * (b - c);
    if (x + (x & 1) < d) x = d - 1;
    if (x - (x & 1) < e) x = e;
    return x;
  }
  return 0;
}

/// One channel of a modular (sub-)stream: geometry, pixel buffer, and the
/// per-pixel decode loop with all 14 predictors including the
/// self-correcting weighted predictor.
final class ModularChannel {
  ModularChannel(this.height, this.width, this.vshift, this.hshift,
      {this.forceWp = false});

  ModularChannel.copy(ModularChannel other)
      : height = other.height,
        width = other.width,
        vshift = other.vshift,
        hshift = other.hshift,
        forceWp = other.forceWp,
        originX = other.originX,
        originY = other.originY,
        decoded = other.decoded {
    if (other.buffer != null) {
      buffer = Int32List.fromList(other.buffer!);
    }
  }

  int height;
  int width;
  int vshift;
  int hshift;
  int originX = 0;
  int originY = 0;
  bool forceWp;
  bool decoded = false;

  /// Flat pixel buffer, row stride == [width].
  Int32List? buffer;

  // Weighted-predictor state, live only during decode().
  Int32List? _err0, _err1, _err2, _err3, _err4;
  Int32List? _pred;
  final Int32List _subpred = Int32List(4);

  void allocate() {
    buffer ??= Int32List(height * width);
  }

  @pragma('vm:prefer-inline')
  int get(int y, int x) => buffer![y * width + x];

  void set(int y, int x, int value) => buffer![y * width + x] = value;

  bool sizeEquals(ModularChannel other) =>
      height == other.height && width == other.width;

  // Neighbor accessors with the spec's border fallbacks. o == y * width + x.
  @pragma('vm:prefer-inline')
  int _west(Int32List b, int o, int x, int y) => x > 0
      ? b[o - 1]
      : y > 0
          ? b[o - width]
          : 0;

  @pragma('vm:prefer-inline')
  int _north(Int32List b, int o, int x, int y) => y > 0
      ? b[o - width]
      : x > 0
          ? b[o - 1]
          : 0;

  @pragma('vm:prefer-inline')
  int _northWest(Int32List b, int o, int x, int y) => x > 0
      ? (y > 0 ? b[o - width - 1] : b[o - 1])
      : (y > 0 ? b[o - width] : 0);

  @pragma('vm:prefer-inline')
  int _northEast(Int32List b, int o, int x, int y) =>
      x + 1 < width && y > 0 ? b[o - width + 1] : _north(b, o, x, y);

  @pragma('vm:prefer-inline')
  int _northNorth(Int32List b, int o, int x, int y) =>
      y > 1 ? b[o - 2 * width] : _north(b, o, x, y);

  @pragma('vm:prefer-inline')
  int _northEastEast(Int32List b, int o, int x, int y) =>
      x + 2 < width && y > 0 ? b[o - width + 2] : _northEast(b, o, x, y);

  @pragma('vm:prefer-inline')
  int _westWest(Int32List b, int o, int x, int y) =>
      x > 1 ? b[o - 2] : _west(b, o, x, y);

  @pragma('vm:prefer-inline')
  int _errWest(Int32List e, int o, int x) => x > 0 ? e[o - 1] : 0;

  @pragma('vm:prefer-inline')
  int _errNorth(Int32List e, int o, int y) => y > 0 ? e[o - width] : 0;

  @pragma('vm:prefer-inline')
  int _errWestWest(Int32List e, int o, int x) => x > 1 ? e[o - 2] : 0;

  @pragma('vm:prefer-inline')
  int _errNorthWest(Int32List e, int o, int x, int y) =>
      x > 0 && y > 0 ? e[o - width - 1] : _errNorth(e, o, y);

  @pragma('vm:prefer-inline')
  int _errNorthEast(Int32List e, int o, int x, int y) =>
      x + 1 < width && y > 0 ? e[o - width + 1] : _errNorth(e, o, y);

  /// Predictor k at (y, x). Used both during decode and by the palette
  /// transform's delta prediction.
  int prediction(int y, int x, int k) {
    final b = buffer!;
    final o = y * width + x;
    switch (k) {
      case 0:
        return 0;
      case 1:
        return x > 0
            ? b[o - 1]
            : y > 0
                ? b[o - width]
                : 0;
      case 2:
        return y > 0
            ? b[o - width]
            : x > 0
                ? b[o - 1]
                : 0;
      case 3:
        return (_west(b, o, x, y) + _north(b, o, x, y)) ~/ 2;
      case 4:
        final w = _west(b, o, x, y);
        final n = _north(b, o, x, y);
        final nw = _northWest(b, o, x, y);
        return (n - nw).abs() < (w - nw).abs() ? w : n;
      case 5:
        final w = _west(b, o, x, y);
        final n = _north(b, o, x, y);
        final v = w + n - _northWest(b, o, x, y);
        return _clamp3(v, n, w);
      case 6:
        return (_pred![o] + 3) >> 3;
      case 7:
        return _northEast(b, o, x, y);
      case 8:
        return _northWest(b, o, x, y);
      case 9:
        return _westWest(b, o, x, y);
      case 10:
        return (_west(b, o, x, y) + _northWest(b, o, x, y)) ~/ 2;
      case 11:
        return (_north(b, o, x, y) + _northWest(b, o, x, y)) ~/ 2;
      case 12:
        return (_north(b, o, x, y) + _northEast(b, o, x, y)) ~/ 2;
      case 13:
        return (6 * _north(b, o, x, y) -
                2 * _northNorth(b, o, x, y) +
                7 * _west(b, o, x, y) +
                _westWest(b, o, x, y) +
                _northEastEast(b, o, x, y) +
                3 * _northEast(b, o, x, y) +
                8) ~/
            16;
      default:
        throw const JxlInvalidBitstreamException('illegal predictor');
    }
  }

  @pragma('vm:prefer-inline')
  int _wpPlaneWeight(Int32List ep, int o, int x, int y, int wpWeight) {
    var eSum = _errNorth(ep, o, y) +
        _errWest(ep, o, x) +
        _errNorthWest(ep, o, x, y) +
        _errWestWest(ep, o, x) +
        _errNorthEast(ep, o, x, y);
    if (x + 1 == width) eSum += _errWest(ep, o, x);
    var shift = floorLog1p(eSum) - 5;
    if (shift < 0) shift = 0;
    return 4 + ((wpWeight * _oneL24OverKP1[eSum >> shift]) >> shift);
  }

  @pragma('vm:prefer-inline')
  int _wpPlaneWeightInterior(Int32List ep, int o, int wpWeight) {
    final eSum = ep[o - width] +
        ep[o - 1] +
        ep[o - width - 1] +
        ep[o - 2] +
        ep[o - width + 1];
    var shift = floorLog1p(eSum) - 5;
    if (shift < 0) shift = 0;
    return 4 + ((wpWeight * _oneL24OverKP1[eSum >> shift]) >> shift);
  }

  /// [_prePredictWp] for interior pixels (y > 1, 1 < x < width - 1):
  /// identical arithmetic with all border branches removed.
  int _prePredictWpInterior(WpParams wp, int x, int y) {
    final b = buffer!;
    final o = y * width + x;
    final n3 = b[o - width] << 3;
    final nw3 = b[o - width - 1] << 3;
    final ne3 = b[o - width + 1] << 3;
    final w3 = b[o - 1] << 3;
    final nn3 = b[o - 2 * width] << 3;
    final e4 = _err4!;
    final tN = e4[o - width];
    final tW = e4[o - 1];
    final tNE = e4[o - width + 1];
    final tNW = e4[o - width - 1];
    _subpred[0] = w3 + ne3 - n3;
    _subpred[1] = n3 - (((tW + tN + tNE) * wp.param1) >> 5);
    _subpred[2] = w3 - (((tW + tN + tNW) * wp.param2) >> 5);
    _subpred[3] = n3 -
        ((tNW * wp.param3a +
                tN * wp.param3b +
                tNE * wp.param3c +
                (nn3 - n3) * wp.param3d +
                (nw3 - w3) * wp.param3e) >>
            5);
    final wpw = wp.weight;
    final rw0 = _wpPlaneWeightInterior(_err0!, o, wpw[0]);
    final rw1 = _wpPlaneWeightInterior(_err1!, o, wpw[1]);
    final rw2 = _wpPlaneWeightInterior(_err2!, o, wpw[2]);
    final rw3 = _wpPlaneWeightInterior(_err3!, o, wpw[3]);
    final logWeight = floorLog1p(rw0 + rw1 + rw2 + rw3 - 1) - 4;
    final sw0 = rw0 >> logWeight;
    final sw1 = rw1 >> logWeight;
    final sw2 = rw2 >> logWeight;
    final sw3 = rw3 >> logWeight;
    final wSum = sw0 + sw1 + sw2 + sw3;
    var s = (wSum >> 1) - 1;
    s += _subpred[0] * sw0;
    s += _subpred[1] * sw1;
    s += _subpred[2] * sw2;
    s += _subpred[3] * sw3;
    var pred = (s * _oneL24OverKP1[wSum - 1]) >> 24;
    if (((tN ^ tW) | (tN ^ tNW)) <= 0) {
      pred = _clamp4(pred, w3, n3, ne3);
    }
    _pred![o] = pred;
    var maxError = tW;
    if (tN.abs() > maxError.abs()) maxError = tN;
    if (tNW.abs() > maxError.abs()) maxError = tNW;
    if (tNE.abs() > maxError.abs()) maxError = tNE;
    return maxError;
  }

  /// Computes the weighted-predictor subpredictions, weights, and prediction
  /// for pixel (y, x); returns maxError (MA-tree property 15).
  int _prePredictWp(WpParams wp, int x, int y) {
    final b = buffer!;
    final o = y * width + x;
    final n3 = _north(b, o, x, y) << 3;
    final nw3 = _northWest(b, o, x, y) << 3;
    final ne3 = _northEast(b, o, x, y) << 3;
    final w3 = _west(b, o, x, y) << 3;
    final nn3 = _northNorth(b, o, x, y) << 3;
    final e4 = _err4!;
    final tN = _errNorth(e4, o, y);
    final tW = _errWest(e4, o, x);
    final tNE = _errNorthEast(e4, o, x, y);
    final tNW = _errNorthWest(e4, o, x, y);
    _subpred[0] = w3 + ne3 - n3;
    _subpred[1] = n3 - (((tW + tN + tNE) * wp.param1) >> 5);
    _subpred[2] = w3 - (((tW + tN + tNW) * wp.param2) >> 5);
    _subpred[3] = n3 -
        ((tNW * wp.param3a +
                tN * wp.param3b +
                tNE * wp.param3c +
                (nn3 - n3) * wp.param3d +
                (nw3 - w3) * wp.param3e) >>
            5);
    final wpw = wp.weight;
    final rw0 = _wpPlaneWeight(_err0!, o, x, y, wpw[0]);
    final rw1 = _wpPlaneWeight(_err1!, o, x, y, wpw[1]);
    final rw2 = _wpPlaneWeight(_err2!, o, x, y, wpw[2]);
    final rw3 = _wpPlaneWeight(_err3!, o, x, y, wpw[3]);
    final logWeight = floorLog1p(rw0 + rw1 + rw2 + rw3 - 1) - 4;
    final sw0 = rw0 >> logWeight;
    final sw1 = rw1 >> logWeight;
    final sw2 = rw2 >> logWeight;
    final sw3 = rw3 >> logWeight;
    final wSum = sw0 + sw1 + sw2 + sw3;
    var s = (wSum >> 1) - 1;
    s += _subpred[0] * sw0;
    s += _subpred[1] * sw1;
    s += _subpred[2] * sw2;
    s += _subpred[3] * sw3;
    var pred = (s * _oneL24OverKP1[wSum - 1]) >> 24;
    if (((tN ^ tW) | (tN ^ tNW)) <= 0) {
      pred = _clamp4(pred, w3, n3, ne3);
    }
    _pred![o] = pred;
    var maxError = tW;
    if (tN.abs() > maxError.abs()) maxError = tN;
    if (tNW.abs() > maxError.abs()) maxError = tNW;
    if (tNE.abs() > maxError.abs()) maxError = tNE;
    return maxError;
  }

  /// MA-tree property k for pixel (y, x). Properties 0-2 are handled by
  /// tree compactification and never reach here.
  int _property(List<ModularChannel> parentChannels, int channelIndex,
      int streamIndex, int k, int maxError, int y, int x) {
    final b = buffer!;
    final o = y * width + x;
    switch (k) {
      case 0:
        return channelIndex;
      case 1:
        return streamIndex;
      case 2:
        return y;
      case 3:
        return x;
      case 4:
        return _north(b, o, x, y).abs();
      case 5:
        return _west(b, o, x, y).abs();
      case 6:
        return _north(b, o, x, y);
      case 7:
        return _west(b, o, x, y);
      case 8:
        if (x <= 0) return _west(b, o, x, y);
        return _west(b, o, x, y) -
            (_west(b, o - 1, x - 1, y) +
                _north(b, o - 1, x - 1, y) -
                _northWest(b, o - 1, x - 1, y));
      case 9:
        return _west(b, o, x, y) + _north(b, o, x, y) - _northWest(b, o, x, y);
      case 10:
        return _west(b, o, x, y) - _northWest(b, o, x, y);
      case 11:
        return _northWest(b, o, x, y) - _north(b, o, x, y);
      case 12:
        return _north(b, o, x, y) - _northEast(b, o, x, y);
      case 13:
        return _north(b, o, x, y) - _northNorth(b, o, x, y);
      case 14:
        return _west(b, o, x, y) - _westWest(b, o, x, y);
      case 15:
        return maxError;
      default:
        if (k - 16 >= 4 * channelIndex) return 0;
        var k2 = 16;
        for (var j = channelIndex - 1; j >= 0; j--) {
          final channel = parentChannels[j];
          if (!sizeEquals(channel) ||
              vshift != channel.vshift ||
              hshift != channel.hshift) {
            continue;
          }
          if (k2 + 4 <= k) {
            k2 += 4;
            continue;
          }
          final cb = channel.buffer!;
          final rC = cb[o];
          if (k2++ == k) return rC.abs();
          if (k2++ == k) return rC;
          final rW = x > 0 ? cb[o - 1] : 0;
          final rN = y > 0 ? cb[o - width] : rW;
          final rNW = x > 0 && y > 0 ? cb[o - width - 1] : rW;
          final rG = rC - _clamp3(rW + rN - rNW, rN, rW);
          if (k2++ == k) return rG.abs();
          if (k2++ == k) return rG;
        }
        return 0;
    }
  }

  void decode(
      BitReader reader,
      EntropyStream stream,
      WpParams? wpParams,
      MaTree tree,
      List<ModularChannel> parentChannels,
      int channelIndex,
      int streamIndex,
      int distMultiplier) {
    if (decoded) throw StateError('channel decoded twice');
    decoded = true;
    allocate();
    final useWp = forceWp || tree.usesWeightedPredictor;
    if (useWp) {
      final n = height * width;
      _err0 = Int32List(n);
      _err1 = Int32List(n);
      _err2 = Int32List(n);
      _err3 = Int32List(n);
      _err4 = Int32List(n);
      _pred = Int32List(n);
    }
    final wp = useWp ? wpParams : null;
    final b = buffer!;
    for (var y = 0; y < height; y++) {
      final refinedTree = tree.compactify(channelIndex, streamIndex, y);
      for (var x = 0; x < width; x++) {
        final maxError = wp == null
            ? 0
            : (y > 1 && x > 1 && x + 1 < width
                ? _prePredictWpInterior(wp, x, y)
                : _prePredictWp(wp, x, y));
        var node = refinedTree;
        while (!node.isLeaf) {
          final p = _property(parentChannels, channelIndex, streamIndex,
              node.property, maxError, y, x);
          node = p > node.value ? node.left! : node.right!;
        }
        final diff = stream.readSymbol(reader, node.context,
            distanceMultiplier: distMultiplier);
        final diff2 = unpackSigned(diff) * node.multiplier + node.offset;
        final trueValue = diff2 + prediction(y, x, node.predictor);
        final o = y * width + x;
        b[o] = trueValue;
        if (useWp) {
          final tv3 = trueValue << 3;
          _err0![o] = ((_subpred[0] - tv3).abs() + 3) >> 3;
          _err1![o] = ((_subpred[1] - tv3).abs() + 3) >> 3;
          _err2![o] = ((_subpred[2] - tv3).abs() + 3) >> 3;
          _err3![o] = ((_subpred[3] - tv3).abs() + 3) >> 3;
          _err4![o] = _pred![o] - tv3;
        }
      }
    }
    // Free the error planes, but keep _pred: the delta-palette transform
    // (dPred == 6) reads prediction(y, x, 6) after decoding.
    _err0 = _err1 = _err2 = _err3 = _err4 = null;
  }

  /// Inverse horizontal squeeze: interleaves `orig` (averages) and `res`
  /// (residues) into `channel`.
  static ModularChannel inverseHorizontalSqueeze(
      ModularChannel channel, ModularChannel orig, ModularChannel res) {
    if (channel.width != orig.width + res.width ||
        orig.width != res.width && orig.width != 1 + res.width ||
        channel.height != orig.height ||
        res.height != orig.height) {
      throw const JxlInvalidBitstreamException('corrupted squeeze transform');
    }
    channel.allocate();
    final cb = channel.buffer!;
    final ob = orig.buffer!;
    final rb = res.buffer!;
    for (var y = 0; y < channel.height; y++) {
      final oRow = y * orig.width;
      final rRow = y * res.width;
      final cRow = y * channel.width;
      for (var x = 0; x < res.width; x++) {
        final avg = ob[oRow + x];
        final residu = rb[rRow + x];
        final nextAvg = x + 1 < orig.width ? ob[oRow + x + 1] : avg;
        final left = x > 0 ? cb[cRow + 2 * x - 1] : avg;
        final diff = residu + tendency(left, avg, nextAvg);
        final first = avg + diff ~/ 2;
        cb[cRow + 2 * x] = first;
        cb[cRow + 2 * x + 1] = first - diff;
      }
    }
    if (orig.width > res.width) {
      final xs = 2 * res.width;
      for (var y = 0; y < channel.height; y++) {
        cb[y * channel.width + xs] = ob[y * orig.width + res.width];
      }
    }
    return channel;
  }

  /// Inverse vertical squeeze.
  static ModularChannel inverseVerticalSqueeze(
      ModularChannel channel, ModularChannel orig, ModularChannel res) {
    if (channel.height != orig.height + res.height ||
        orig.height != res.height && orig.height != 1 + res.height ||
        channel.width != orig.width ||
        res.width != orig.width) {
      throw const JxlInvalidBitstreamException('corrupted squeeze transform');
    }
    channel.allocate();
    final cb = channel.buffer!;
    final ob = orig.buffer!;
    final rb = res.buffer!;
    final w = channel.width;
    for (var y = 0; y < res.height; y++) {
      for (var x = 0; x < w; x++) {
        final avg = ob[y * w + x];
        final residu = rb[y * w + x];
        final nextAvg = y + 1 < orig.height ? ob[(y + 1) * w + x] : avg;
        final top = y > 0 ? cb[(2 * y - 1) * w + x] : avg;
        final diff = residu + tendency(top, avg, nextAvg);
        final first = avg + diff ~/ 2;
        cb[2 * y * w + x] = first;
        cb[(2 * y + 1) * w + x] = first - diff;
      }
    }
    if (orig.height > res.height) {
      cb.setRange(
          2 * res.height * w, (2 * res.height + 1) * w, ob, res.height * w);
    }
    return channel;
  }
}
