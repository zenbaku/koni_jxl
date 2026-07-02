import 'dart:math' as math;
import 'dart:typed_data';

import '../io/bit_writer.dart';
import 'entropy_writer.dart';

/// Learns a per-image MA (meta-adaptive) context tree, the biggest lever for
/// lossless modular size after prediction: richer contexts condition the
/// residual histograms far better than a fixed handful.
///
/// The tree tests decoder property values (`_property` cases) against
/// thresholds; leaves are contexts. All leaves use the clamped-gradient
/// predictor (5); the residual is computed by the caller.

/// Decoder property ids this learner may split on (mirrors `_property`):
/// 4 = |N|, 5 = |W|, 6 = N, 7 = W, 10 = W-NW, 11 = NW-N, 12 = N-NE,
/// 13 = N-NN, 14 = W-WW.
const treeProperties = [4, 5, 6, 7, 10, 11, 12, 13, 14];

/// Candidate split thresholds (the decoder walk is `property > value`).
const _thresholds = [
  -64, -32, -16, -8, -4, -2, -1, 0, 1, 2, 4, 8, 16, 32, 64, 128, //
];

/// Computes [treeProperties] for pixel (y, x) of a tile into [out] (length
/// treeProperties.length), mirroring the decoder's `_property`.
void _propsAt(Int32List tile, int tw, int th, int y, int x, Int32List out) {
  final o = y * tw + x;
  final n = y > 0
      ? tile[o - tw]
      : x > 0
          ? tile[o - 1]
          : 0;
  final w = x > 0
      ? tile[o - 1]
      : y > 0
          ? tile[o - tw]
          : 0;
  final nw = x > 0
      ? (y > 0 ? tile[o - tw - 1] : tile[o - 1])
      : (y > 0 ? tile[o - tw] : 0);
  final ne = x + 1 < tw && y > 0 ? tile[o - tw + 1] : n;
  final nn = y > 1 ? tile[o - 2 * tw] : n;
  final ww = x > 1 ? tile[o - 2] : w;
  out[0] = n.abs(); // 4
  out[1] = w.abs(); // 5
  out[2] = n; // 6
  out[3] = w; // 7
  out[4] = w - nw; // 10
  out[5] = nw - n; // 11
  out[6] = n - ne; // 12
  out[7] = n - nn; // 13
  out[8] = w - ww; // 14
}

double _log2(double x) => math.log(x) * 1.4426950408889634;

final class _Node {
  int propIndex = -1; // index into treeProperties; < 0 => leaf
  int value = 0;
  int context = -1;
  _Node? left;
  _Node? right;
  List<int> samples; // sample indices (training)
  int splitProp = -2; // -2 = not computed, -1 = no useful split
  int splitThr = 0;
  double splitGain = 0;
  _Node(this.samples);
}

/// A learned tree ready to serialize and to assign contexts with.
final class ContextTree {
  ContextTree._(this._root, this.numContexts, this._nodesInOrder);

  final _Node _root;
  final int numContexts;
  final List<_Node> _nodesInOrder; // BFS order for serialization

  /// Number of distinct contexts (tree leaves).
  int get contexts => numContexts;
}

double _countsEntropy(List<int> counts, int total) {
  if (total == 0) return 0;
  var bits = 0.0;
  final lt = total.toDouble();
  for (final c in counts) {
    if (c > 0) bits += c * _log2(lt / c);
  }
  return bits;
}

/// Learns a tree from (properties, token) training samples. [props] is
/// flat: sample s uses props[s*P .. s*P+P). Splits stop at [maxContexts]
/// leaves or when a split saves fewer than [minGainBits] bits.
ContextTree learnContextTree(Int32List props, Int32List tokens,
    {int maxContexts = 64, double minGainBits = 96}) {
  final p = treeProperties.length;
  final n = tokens.length;
  var maxToken = 0;
  for (final t in tokens) {
    if (t > maxToken) maxToken = t;
  }
  final alpha = maxToken + 1;
  final nb = _thresholds.length; // bins = thresholds + 1

  int binOf(int v) {
    var lo = 0, hi = nb;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (v > _thresholds[mid]) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo; // in [0, nb]
  }

  void computeSplit(_Node node) {
    node.splitProp = -1;
    if (node.samples.length < 1024) return;
    final parent = List<int>.filled(alpha, 0);
    for (final s in node.samples) {
      parent[tokens[s]]++;
    }
    final total = node.samples.length;
    final parentBits = _countsEntropy(parent, total);
    for (var pi = 0; pi < p; pi++) {
      final binHist = List<List<int>>.generate(
          nb + 1, (_) => List<int>.filled(alpha, 0),
          growable: false);
      final binTotal = List<int>.filled(nb + 1, 0);
      for (final s in node.samples) {
        final b = binOf(props[s * p + pi]);
        binHist[b][tokens[s]]++;
        binTotal[b]++;
      }
      final right = List<int>.filled(alpha, 0);
      var rightTotal = 0;
      for (var i = 0; i < nb; i++) {
        for (var t = 0; t < alpha; t++) {
          right[t] += binHist[i][t];
        }
        rightTotal += binTotal[i];
        final leftTotal = total - rightTotal;
        if (rightTotal == 0 || leftTotal == 0) continue;
        var leftBits = 0.0;
        final llt = leftTotal.toDouble();
        for (var t = 0; t < alpha; t++) {
          final lc = parent[t] - right[t];
          if (lc > 0) leftBits += lc * _log2(llt / lc);
        }
        final rightBits = _countsEntropy(right, rightTotal);
        final gain = parentBits - leftBits - rightBits;
        if (gain > node.splitGain) {
          node.splitGain = gain;
          node.splitProp = pi;
          node.splitThr = _thresholds[i];
        }
      }
    }
    if (node.splitGain < minGainBits) node.splitProp = -1;
  }

  final root = _Node([for (var i = 0; i < n; i++) i]);
  computeSplit(root);
  var leaves = 1;
  final frontier = <_Node>[root];
  while (leaves < maxContexts) {
    _Node? pick;
    var pickGain = 0.0;
    for (final node in frontier) {
      if (node.splitProp >= 0 && node.splitGain > pickGain) {
        pickGain = node.splitGain;
        pick = node;
      }
    }
    if (pick == null) break;
    final pi = pick.splitProp;
    final thr = pick.splitThr;
    final leftS = <int>[];
    final rightS = <int>[];
    for (final s in pick.samples) {
      if (props[s * p + pi] > thr) {
        leftS.add(s);
      } else {
        rightS.add(s);
      }
    }
    pick
      ..propIndex = pi
      ..value = thr
      ..left = _Node(leftS)
      ..right = _Node(rightS)
      ..samples = const []
      ..splitProp = -1;
    computeSplit(pick.left!);
    computeSplit(pick.right!);
    frontier
      ..remove(pick)
      ..add(pick.left!)
      ..add(pick.right!);
    leaves++;
  }

  final ordered = <_Node>[];
  var nextContext = 0;
  final queue = <_Node>[root];
  while (queue.isNotEmpty) {
    final node = queue.removeAt(0);
    ordered.add(node);
    if (node.propIndex < 0) {
      node.context = nextContext++;
    } else {
      queue.add(node.left!);
      queue.add(node.right!);
    }
  }
  return ContextTree._(root, nextContext, ordered);
}

/// Serializes the tree in the decoder's MA-tree format: a 6-context entropy
/// stream carrying, per node in BFS order, (property+1, value) for inner
/// nodes and (0, predictor, offset, mulLog, mulBits) for leaves.
void serializeContextTree(BitWriter w, ContextTree tree) {
  final tokens = EntropyWriter(6);
  for (final node in tree._nodesInOrder) {
    if (node.propIndex < 0) {
      tokens.write(1, 0); // property + 1 == 0 -> leaf
      tokens.write(2, 5); // predictor: clamped gradient
      tokens.write(3, 0); // offset
      tokens.write(4, 0); // mul_log
      tokens.write(5, 0); // mul_bits
    } else {
      tokens.write(1, treeProperties[node.propIndex] + 1);
      tokens.write(0, _packSigned(node.value));
    }
  }
  tokens.finalize(w);
}

int _packSigned(int v) => v >= 0 ? v << 1 : (-v << 1) - 1;

/// Assigns the context (leaf id) for a property vector by walking the tree.
int contextFor(ContextTree tree, Int32List propsAt) {
  var node = tree._root;
  while (node.propIndex >= 0) {
    node = propsAt[node.propIndex] > node.value ? node.left! : node.right!;
  }
  return node.context;
}

/// Computes the property vector for pixel (y, x) into [out].
void computePropsAt(
    Int32List tile, int tw, int th, int y, int x, Int32List out) {
  _propsAt(tile, tw, th, y, x, out);
}
