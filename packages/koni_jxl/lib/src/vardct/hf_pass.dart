import 'dart:typed_data';

import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../frame/frame.dart';
import '../frame/toc.dart';
import '../io/bit_reader.dart';

import 'transform_type.dart';

/// Natural coefficient orders per orderID, as packed (y << 16 | x) values.
final List<Int32List?> _naturalOrderCache = List.filled(13, null);

/// Public so the lossy encoder can scan coefficients in the exact same
/// (cached) order the decoder reads them in.
Int32List getNaturalOrder(int i) {
  final cached = _naturalOrderCache[i];
  if (cached != null) return cached;
  final tt = TransformType.byOrderID(i);
  final len = tt.pixelHeight * tt.pixelWidth;
  final coords = List<int>.generate(len, (j) {
    final y = j ~/ tt.pixelWidth;
    final x = j % tt.pixelWidth;
    return (y << 16) | x;
  });
  final maxDim = tt.dctSelectHeight > tt.dctSelectWidth
      ? tt.dctSelectHeight
      : tt.dctSelectWidth;
  coords.sort((a, b) {
    final ay = a >> 16, ax = a & 0xFFFF;
    final by = b >> 16, bx = b & 0xFFFF;
    final aLLF = ay < tt.dctSelectHeight && ax < tt.dctSelectWidth;
    final bLLF = by < tt.dctSelectHeight && bx < tt.dctSelectWidth;
    if (aLLF && !bLLF) return -1;
    if (bLLF && !aLLF) return 1;
    if (aLLF && bLLF) {
      if (by != ay) return ay - by;
      return ax - bx;
    }
    final aSY = ay * maxDim ~/ tt.dctSelectHeight;
    final aSX = ax * maxDim ~/ tt.dctSelectWidth;
    final bSY = by * maxDim ~/ tt.dctSelectHeight;
    final bSX = bx * maxDim ~/ tt.dctSelectWidth;
    final aKey1 = aSY + aSX;
    final bKey1 = bSY + bSX;
    if (aKey1 != bKey1) return aKey1 - bKey1;
    var aKey2 = aSX - aSY;
    var bKey2 = bSX - bSY;
    if (aKey1 & 1 == 1) aKey2 = -aKey2;
    if (bKey1 & 1 == 1) bKey2 = -bKey2;
    return aKey2 - bKey2;
  });
  return _naturalOrderCache[i] = Int32List.fromList(coords);
}

/// Per-pass VarDCT data: coefficient orders and the shared AC context
/// entropy stream.
final class HfPass {
  HfPass(BitReader reader, Frame frame, int passIndex) {
    usedOrders = reader.readU32(0x5F, 0, 0x13, 0, 0, 0, 0, 13);
    final stream = usedOrders != 0 ? EntropyStream.read(reader, 8) : null;
    // Permuted orders must be read from the bitstream now; natural orders
    // for unused IDs are built lazily on first use (the big zigzag sorts
    // are expensive and most images touch only a few transform types).
    for (var b = 0; b < 13; b++) {
      if (usedOrders & (1 << b) == 0) continue;
      final naturalOrder = getNaturalOrder(b);
      final len = naturalOrder.length;
      _order[b] = List.generate(3, (c) {
        final perm = readPermutation(reader, stream!, len, len ~/ 64);
        final o = Int32List(len);
        for (var i = 0; i < len; i++) {
          o[i] = naturalOrder[perm[i]];
        }
        return o;
      }, growable: false);
    }
    if (stream != null && !stream.validateFinalState()) {
      throw JxlInvalidBitstreamException(
          'ANS state decoding HFPass perms: $passIndex');
    }
    final numContexts = 495 *
        frame.hfGlobal!.numHfPresets *
        frame.lfGlobal.hfBlockCtx!.numClusters;
    contextStream = EntropyStream.read(reader, numContexts);
  }

  late final int usedOrders;

  final List<List<Int32List>?> _order = List.filled(13, null);
  late final EntropyStream contextStream;

  /// orderFor(orderID)[channel] -> packed (y << 16 | x) coefficient
  /// positions.
  List<Int32List> orderFor(int orderID) {
    final cached = _order[orderID];
    if (cached != null) return cached;
    final naturalOrder = getNaturalOrder(orderID);
    return _order[orderID] = List.filled(3, naturalOrder, growable: false);
  }
}
