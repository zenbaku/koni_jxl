import 'dart:typed_data';

import 'package:koni_jxl/src/encode/context_tree.dart';
import 'package:test/test.dart';

/// Unit tests for `learnContextTree` and its `trainingBits` — the tree's
/// achieved zeroth-order entropy over the training set, used to pick the
/// gradient vs weighted predictor before the expensive Pass B / entropy
/// coding runs (see encoder.dart's predictor selection).
void main() {
  group('ContextTree.trainingBits', () {
    test('equals the token entropy when no split helps', () {
      // One property, held constant so no split is possible; tokens are
      // exactly uniform over {0,1,2,3} → a single leaf whose entropy is 2 bits
      // per sample.
      const n = 8000;
      final props = Int32List(n); // property 6 (N), all zero → no useful split
      final tokens = Int32List(n);
      for (var i = 0; i < n; i++) {
        tokens[i] = i & 3; // 0,1,2,3 repeating → exactly 25% each
      }
      final tree = learnContextTree(props, tokens, const [6]);
      expect(tree.contexts, 1, reason: 'a constant property cannot split');
      expect(tree.trainingBits, closeTo(2.0 * n, 1.0));
    });

    test('drops to ~zero when a property perfectly predicts the token', () {
      // The token is a deterministic function of property 6's sign, so one
      // split yields two pure (zero-entropy) leaves.
      const n = 8000;
      final props = Int32List(n);
      final tokens = Int32List(n);
      for (var i = 0; i < n; i++) {
        final even = (i & 1) == 0;
        props[i] = even ? 100 : -100;
        tokens[i] = even ? 5 : 7;
      }
      final tree = learnContextTree(props, tokens, const [6]);
      expect(tree.contexts, greaterThan(1), reason: 'the split is worthwhile');
      expect(tree.trainingBits, lessThan(1.0));
    });

    test('is non-negative and finite for random content', () {
      const n = 4000;
      final props = Int32List(n);
      final tokens = Int32List(n);
      var state = 12345;
      int next() {
        state = (state * 1103515245 + 12345) & 0x7fffffff;
        return state;
      }

      for (var i = 0; i < n; i++) {
        props[i] = (next() % 200) - 100;
        tokens[i] = next() % 8;
      }
      final tree = learnContextTree(props, tokens, const [6]);
      expect(tree.trainingBits, greaterThanOrEqualTo(0.0));
      expect(tree.trainingBits.isFinite, isTrue);
    });
  });
}
