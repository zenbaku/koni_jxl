import 'dart:math' as math;
import 'dart:typed_data';

import '../io/bit_writer.dart';
import 'entropy_writer.dart';

/// Learns a per-image MA (meta-adaptive) context tree, the biggest lever for
/// lossless modular size after prediction: richer contexts condition the
/// residual histograms far better than a fixed handful.
///
/// The tree tests decoder property values (`_property` cases) against
/// thresholds; leaves are contexts. The predictor is chosen by the caller;
/// property 15 (the weighted predictor's max-error) is only meaningful when
/// the leaves use predictor 6, so the property set is predictor-dependent.

/// Property set for the clamped-gradient predictor (mirrors `_property`):
/// 4 = |N|, 5 = |W|, 6 = N, 7 = W, 8 = W's own gradient-prediction error,
/// 9 = the gradient prediction W+N-NW, 10 = W-NW, 11 = NW-N, 12 = N-NE,
/// 13 = N-NN, 14 = W-WW. Properties 8 and 9 (error-feedback and
/// predicted-value) are what libjxl's modular encoder leans on; the decoder
/// already computes them (`_property` cases 8/9) — they were simply never in
/// this encoder's learned-tree property set.
const gradProperties = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];

/// Property set for the weighted predictor: the gradient set plus 15
/// (max-error), which is where WP's advantage lives.
const wpProperties = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

/// Property sets for multi-channel RCT colour: the base sets plus channel
/// index (0) and the immediate prior channel's cross-channel properties
/// (16 = |value|, 17 = value, 18 = |gradient residual|, 19 = gradient
/// residual — the decoder's `_property` cases 16-19 for the nearest prior
/// same-size channel). Property 0 lets the tree specialise per channel
/// (Y/Co/Cg) instead of sharing one tree; 16-19 let Co/Cg condition on the
/// prior channel. Used only on the RCT path (three equal-size channels, no
/// meta channel, so channel index == plane index) — see `computeProps`'s
/// `channelIndex`/`prior` args and the encoder's callers.
const rctGradProperties = [
  4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0, 16, 17, 18, 19 //
];
const rctWpProperties = [
  4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 16, 17, 18, 19 //
];

/// Candidate split thresholds (the decoder walk is `property > value`).
const _thresholds = [
  -64, -32, -16, -8, -4, -2, -1, 0, 1, 2, 4, 8, 16, 32, 64, 128, //
];

/// Computes [properties] for pixel (y, x) of a tile into [out] (same length),
/// mirroring the decoder's `_property`. Property 15 (WP max-error) is not
/// derivable from the tile, so its value is supplied as [maxError].
///
/// [channelIndex] supplies property 0 (the decoder's channel index). When
/// [prior] (the immediate prior same-size channel's tile, same [tw]/[th]) is
/// given and [channelIndex] >= 1, properties 16-19 are the decoder's
/// cross-channel values for that prior channel at (y, x): 16 = |value|,
/// 17 = value, 18 = |gradient residual|, 19 = gradient residual. Grayscale /
/// palette / the first RCT channel pass no prior, so those props stay 0 —
/// exactly what the decoder returns there (`k - 16 >= 4 * channelIndex`).
void computeProps(Int32List tile, int tw, int th, int y, int x,
    List<int> properties, int maxError, Int32List out,
    {int channelIndex = 0, Int32List? prior}) {
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
  // Property 9: the clamped-gradient prediction value W+N-NW.
  // Property 8: W minus its *own* gradient prediction — the prediction error
  // at the west neighbour. Both mirror the decoder's `_property` cases 9/8
  // (including their signed-32 truncation) exactly, so a tree that splits on
  // them decodes identically. Case 8 reads the W pixel's neighbours (its W,
  // N, NW), with the decoder's edge handling at x==1/y==0.
  final grad9 = (w + n - nw).toSigned(32);
  final int err8;
  if (x <= 0) {
    err8 = w; // decoder returns _west(o) here
  } else {
    final westW = x > 1 ? tile[o - 2] : (y > 0 ? tile[o - tw - 1] : 0);
    final northW = y > 0 ? tile[o - tw - 1] : (x > 1 ? tile[o - 2] : 0);
    final nwW = x > 1
        ? (y > 0 ? tile[o - tw - 2] : tile[o - 2])
        : (y > 0 ? tile[o - tw - 1] : 0);
    err8 = (w - (westW + northW - nwW).toSigned(32)).toSigned(32);
  }
  // Cross-channel (16-19): the immediate prior channel's value and its own
  // clamped-gradient residual at (y, x). Mirrors the decoder's `_property`
  // cases 16-19 (including `_clamp3` and signed-32 truncation, and the
  // rW=0-at-left-edge / rN=rW-at-top-edge / rNW=rW edge handling) for the
  // nearest prior same-size channel. Only the first prior is exposed here
  // (props 16-19); the decoder's further-back channels (20+) aren't used.
  var cx16 = 0, cx17 = 0, cx18 = 0, cx19 = 0;
  if (channelIndex >= 1 && prior != null) {
    final rC = prior[o];
    final rW = x > 0 ? prior[o - 1] : 0;
    final rN = y > 0 ? prior[o - tw] : rW;
    final rNW = x > 0 && y > 0 ? prior[o - tw - 1] : rW;
    final lo = rW < rN ? rW : rN;
    final hi = rW < rN ? rN : rW;
    final g = (rW + rN - rNW).toSigned(32);
    final pred = g < lo ? lo : (g > hi ? hi : g);
    final rG = (rC - pred).toSigned(32);
    cx16 = rC.abs();
    cx17 = rC;
    cx18 = rG.abs();
    cx19 = rG;
  }
  for (var i = 0; i < properties.length; i++) {
    out[i] = switch (properties[i]) {
      0 => channelIndex,
      4 => n.abs(),
      5 => w.abs(),
      6 => n,
      7 => w,
      8 => err8,
      9 => grad9,
      10 => w - nw,
      11 => nw - n,
      12 => n - ne,
      13 => n - nn,
      14 => w - ww,
      15 => maxError,
      16 => cx16,
      17 => cx17,
      18 => cx18,
      19 => cx19,
      _ => 0,
    };
  }
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
  ContextTree._(this._root, this.numContexts, this._nodesInOrder,
      this.properties, this.trainingBits);

  final _Node _root;
  final int numContexts;
  final List<_Node> _nodesInOrder; // BFS order for serialization

  /// The decoder property ids this tree splits on (index order).
  final List<int> properties;

  /// Total zeroth-order entropy (bits) this tree's leaves achieve on the
  /// strided training set — the sum over leaves of each leaf's token-histogram
  /// entropy. A predictor-independent, context-modelled cost signal available
  /// the moment the tree is learned (before Pass B / entropy coding); used to
  /// compare the gradient vs weighted-predictor pipelines cheaply.
  final double trainingBits;

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
ContextTree learnContextTree(
    Int32List props, Int32List tokens, List<int> properties,
    {int maxContexts = 64, double minGainBits = 96}) {
  final p = properties.length;
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

  // Training entropy: sum of each leaf's token-histogram entropy. `frontier`
  // holds exactly the leaves (split nodes were removed as they split).
  var trainingBits = 0.0;
  final leafHist = List<int>.filled(alpha, 0);
  for (final leaf in frontier) {
    for (final s in leaf.samples) {
      leafHist[tokens[s]]++;
    }
    trainingBits += _countsEntropy(leafHist, leaf.samples.length);
    for (final s in leaf.samples) {
      leafHist[tokens[s]] = 0;
    }
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
  return ContextTree._(root, nextContext, ordered, properties, trainingBits);
}

/// Serializes the tree in the decoder's MA-tree format: a 6-context entropy
/// stream carrying, per node in BFS order, (property+1, value) for inner
/// nodes and (0, predictor, offset, mulLog, mulBits) for leaves. [predictor]
/// is the decoder predictor id a leaf uses (5 = clamped gradient,
/// 6 = self-correcting weighted) unless [leafPredictors] is given, in which
/// case each leaf uses `leafPredictors[leaf.context]` (per-leaf predictor
/// selection). The decoder reads a predictor per leaf and maintains WP state
/// for every pixel whenever any leaf is WP, so gradient and WP leaves may
/// coexist in one tree.
void serializeContextTree(BitWriter w, ContextTree tree, int predictor,
    [List<int>? leafPredictors]) {
  final tokens = EntropyWriter(6);
  for (final node in tree._nodesInOrder) {
    if (node.propIndex < 0) {
      tokens.write(1, 0); // property + 1 == 0 -> leaf
      tokens.write(
          2, leafPredictors != null ? leafPredictors[node.context] : predictor);
      tokens.write(3, 0); // offset
      tokens.write(4, 0); // mul_log
      tokens.write(5, 0); // mul_bits
    } else {
      tokens.write(1, tree.properties[node.propIndex] + 1);
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
