import 'dart:typed_data';

import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';

/// The HF block context model: cluster map over (channel, orderID,
/// qf-threshold bucket, lf-threshold bucket).
final class HfBlockContext {
  /// The built-in default (a single `true` bit on the wire): a 39-entry
  /// cluster map, 15 clusters, no LF/QF thresholds. Public so the lossy
  /// encoder can compute context ids against the same default object the
  /// decoder uses without re-parsing a bitstream.
  factory HfBlockContext.defaults() => HfBlockContext._(
        Int32List.fromList(const [
          0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6, //
          7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14, //
          7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
        ]),
        15,
        [Int32List(0), Int32List(0), Int32List(0)],
        Int32List(0),
        1,
      );

  factory HfBlockContext.read(BitReader reader) {
    if (reader.readBool()) {
      return HfBlockContext.defaults();
    }
    final nbLFThresh = List<int>.filled(3, 0);
    final lfThresholds = <Int32List>[];
    var lfCtx = 1;
    for (var i = 0; i < 3; i++) {
      nbLFThresh[i] = reader.readBits(4);
      lfCtx *= nbLFThresh[i] + 1;
      final t = Int32List(nbLFThresh[i]);
      for (var j = 0; j < nbLFThresh[i]; j++) {
        t[j] = unpackSigned(reader.readU32(0, 4, 16, 8, 272, 16, 65808, 32));
      }
      lfThresholds.add(t);
    }
    final nbQfThresh = reader.readBits(4);
    final qfThresholds = Int32List(nbQfThresh);
    // SPEC: the spec is missing the "1 +" here.
    for (var i = 0; i < nbQfThresh; i++) {
      qfThresholds[i] = 1 + reader.readU32(0, 2, 4, 3, 12, 5, 44, 8);
    }
    var bSize = 39 * (nbQfThresh + 1);
    for (var i = 0; i < 3; i++) {
      bSize *= nbLFThresh[i] + 1;
    }
    if (bSize > 39 * 64) {
      throw const JxlInvalidBitstreamException('HF block size too large');
    }
    final clusterMap = Int32List(bSize);
    final numClusters = EntropyStream.readClusterMap(reader, clusterMap, 16);
    return HfBlockContext._(
        clusterMap, numClusters, lfThresholds, qfThresholds, lfCtx);
  }

  HfBlockContext._(this.clusterMap, this.numClusters, this.lfThresholds,
      this.qfThresholds, this.numLFContexts);

  final Int32List clusterMap;
  final int numClusters;
  final List<Int32List> lfThresholds;
  final Int32List qfThresholds;
  final int numLFContexts;
}
