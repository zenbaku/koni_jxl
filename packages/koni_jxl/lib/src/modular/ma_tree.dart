import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';

/// A meta-adaptive tree: inner nodes test a property against a value, leaves
/// carry (context, predictor, offset, multiplier).
final class MaTree {
  MaTree._();

  /// Reads the tree and its associated entropy stream (used later to decode
  /// the actual pixel residuals).
  factory MaTree.read(BitReader reader) {
    final nodes = <MaTree>[];
    final stream = EntropyStream.read(reader, 6);
    var contextId = 0;
    var nodesRemaining = 1;
    MaTree? root;
    while (nodesRemaining-- > 0) {
      if (nodes.length > 1 << 20) {
        throw const JxlInvalidBitstreamException('MA tree too large');
      }
      final property = stream.readSymbol(reader, 1) - 1;
      final node = MaTree._();
      root ??= node;
      if (property >= 0) {
        node.property = property;
        node.value = unpackSigned(stream.readSymbol(reader, 0));
        final leftChild = nodes.length + nodesRemaining + 1;
        node._leftChildIndex = leftChild;
        node._rightChildIndex = leftChild + 1;
        nodes.add(node);
        nodesRemaining += 2;
      } else {
        node.context = contextId++;
        node.predictor = stream.readSymbol(reader, 2);
        if (node.predictor > 13) {
          throw const JxlInvalidBitstreamException('invalid predictor value');
        }
        node.offset = unpackSigned(stream.readSymbol(reader, 3));
        final mulLog = stream.readSymbol(reader, 4);
        if (mulLog > 30) {
          throw const JxlInvalidBitstreamException('mulLog too large');
        }
        final mulBits = stream.readSymbol(reader, 5);
        if (mulBits > (1 << (31 - mulLog)) - 2) {
          throw const JxlInvalidBitstreamException('mulBits too large');
        }
        node.multiplier = (mulBits + 1) << mulLog;
        nodes.add(node);
      }
    }
    if (!stream.validateFinalState()) {
      throw const JxlInvalidBitstreamException('illegal MA tree entropy state');
    }

    root!.stream = EntropyStream.read(reader, (nodes.length + 1) ~/ 2);
    for (final node in nodes) {
      node.stream = root.stream;
      if (!node.isLeaf) {
        node.left = nodes[node._leftChildIndex];
        node.right = nodes[node._rightChildIndex];
      }
    }
    return root;
  }

  /// Inner-node fields; property < 0 marks a leaf.
  int property = -1;
  int value = 0;
  int _leftChildIndex = 0;
  int _rightChildIndex = 0;
  MaTree? left;
  MaTree? right;

  /// Leaf fields.
  int context = 0;
  int predictor = -1;
  int offset = 0;
  int multiplier = 1;

  /// The residual entropy stream (shared by all nodes of one tree).
  EntropyStream? stream;

  bool get isLeaf => property < 0;

  bool get usesWeightedPredictor {
    if (isLeaf) return predictor == 6;
    return property == 15 ||
        left!.usesWeightedPredictor ||
        right!.usesWeightedPredictor;
  }

  bool? _needsResolution;

  /// Whether this subtree tests channel index, stream index or y (properties
  /// 0-2) anywhere — i.e. whether [compactify] can do anything but return
  /// `this` unchanged. Real learned trees (this project's own encoder and,
  /// empirically, cjxl's) split almost exclusively on spatial/gradient
  /// properties (3+), so this is `false` for entire trees in practice.
  bool get needsResolution {
    final cached = _needsResolution;
    if (cached != null) return cached;
    final result = !isLeaf &&
        (property <= 2 || left!.needsResolution || right!.needsResolution);
    return _needsResolution = result;
  }

  /// Resolves properties that are constant across a channel row
  /// (channel index, stream index, y), returning a smaller tree. Called once
  /// per row of every channel decode, so subtrees that don't test properties
  /// 0-2 anywhere must short-circuit rather than reallocate a full copy of
  /// themselves on every call (see [needsResolution]).
  MaTree compactify(int channelIndex, int streamIndex, int y) {
    if (isLeaf || !needsResolution) return this;
    final prop = switch (property) {
      0 => channelIndex,
      1 => streamIndex,
      2 => y,
      _ => -1,
    };
    if (prop >= 0) {
      final branch = prop > value ? left! : right!;
      return branch.compactify(channelIndex, streamIndex, y);
    }
    final tree = MaTree._();
    tree.property = property;
    tree.value = value;
    tree.left = left!.compactify(channelIndex, streamIndex, y);
    tree.right = right!.compactify(channelIndex, streamIndex, y);
    return tree;
  }
}
