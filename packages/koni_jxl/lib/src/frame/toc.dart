import 'dart:typed_data';

import '../entropy/entropy_stream.dart';
import '../exceptions.dart';
import '../io/bit_reader.dart';
import '../util/math_helper.dart';

/// Reads an entropy-coded Lehmer-sequence permutation of [size] entries
/// (used by the TOC and by VarDCT coefficient orders).
List<int> readPermutation(
    BitReader reader, EntropyStream stream, int size, int skip) {
  int ctx(int x) {
    final v = ceilLog1p(x);
    return v < 7 ? v : 7;
  }

  final end = stream.readSymbol(reader, ctx(size));
  if (end > size - skip) {
    throw const JxlInvalidBitstreamException('illegal lehmer end value');
  }
  final lehmer = List<int>.filled(size, 0);
  for (var i = skip; i < end + skip; i++) {
    lehmer[i] = stream.readSymbol(reader, ctx(i > skip ? lehmer[i - 1] : 0));
    if (lehmer[i] >= size - i) {
      throw const JxlInvalidBitstreamException('illegal lehmer value');
    }
  }
  final temp = List<int>.generate(size, (i) => i);
  final permutation = List<int>.filled(size, 0);
  for (var i = 0; i < size; i++) {
    permutation[i] = temp.removeAt(lehmer[i]);
  }
  return permutation;
}

/// The frame's table of contents: section lengths (in file order), the
/// optional permutation, and the section payload bytes.
final class Toc {
  factory Toc.read(BitReader reader, int tocEntries) {
    List<int>? permutation;
    if (reader.readBool()) {
      final tocStream = EntropyStream.read(reader, 8);
      permutation = readPermutation(reader, tocStream, tocEntries, 0);
      if (!tocStream.validateFinalState()) {
        throw const JxlInvalidBitstreamException('invalid TOC entropy state');
      }
    }
    reader.zeroPadToByte();
    final lengths = List<int>.generate(tocEntries,
        (_) => reader.readU32(0, 10, 1024, 14, 17408, 22, 4211712, 30));
    reader.zeroPadToByte();

    final starts = List<int>.filled(tocEntries, 0);
    var total = 0;
    for (var i = 0; i < tocEntries; i++) {
      starts[i] = total;
      total += lengths[i];
    }
    // Capture the section payload region, then advance the global reader
    // past it so the next frame can be read.
    final data = reader.remainingBytes();
    if (data.length < total) {
      throw const JxlTruncatedException('frame sections extend past input');
    }
    reader.skipBits(total << 3);
    return Toc._(
        lengths, permutation, starts, Uint8List.sublistView(data, 0, total));
  }

  Toc._(this.lengths, this.permutation, this._starts, this._data);

  final List<int> lengths;
  final List<int>? permutation;
  final List<int> _starts;
  final Uint8List _data;
  final Map<int, BitReader> _readers = {};

  /// Section reader for logical section [index]; repeated calls return the
  /// same reader (single-section frames share one reader across stages).
  BitReader sectionReader(int index) {
    final i = lengths.length <= 1 ? 0 : (permutation?[index] ?? index);
    return _readers.putIfAbsent(
        i, () => BitReader.view(_data, _starts[i], _starts[i] + lengths[i]));
  }
}
