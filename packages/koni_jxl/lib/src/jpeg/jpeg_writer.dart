import 'dart:typed_data';

import '../exceptions.dart';
import 'jpeg_data.dart';

/// Re-emits the exact original JPEG bytes from a fully populated [JpegData]
/// (structure from the jbrd box, quant values + coefficients from the decode).
/// Port of libjxl `lib/jxl/jpeg/dec_jpeg_data_writer.cc` (baseline sequential
/// path). Progressive scans are out of scope for this phase and throw.
Uint8List writeJpeg(JpegData jpg) {
  final state = _SerializationState(jpg);
  final out = BytesBuilder(copy: false);

  out.add(Uint8List.fromList(const [0xFF, 0xD8])); // SOI
  for (final marker in jpg.markerOrder) {
    _serializeSection(marker, state, out);
  }
  if (state.padBits != null && state.padBitsPos != jpg.paddingBits.length) {
    throw const JxlInvalidBitstreamException('unused JPEG padding bits');
  }
  return out.toBytes();
}

/// Canonical JPEG Huffman code table (per-symbol code + bit length).
final class _HuffTable {
  final Uint8List depth = Uint8List(256);
  final Int32List code = Int32List(256);
  bool initialized = false;
}

/// Builds [table] from a DHT definition. Port of `BuildHuffmanCodeTable`; the
/// final `values` entry (the synthetic 256 EOI sentinel) is intentionally left
/// uncoded — it is never emitted.
void _buildHuffTable(JpegHuffmanCode huff, _HuffTable table) {
  final huffSize = <int>[];
  for (var l = 1; l <= kJpegHuffmanMaxBitLength; l++) {
    for (var i = 0; i < huff.counts[l]; i++) {
      huffSize.add(l);
    }
  }
  final p = huffSize.length;
  if (p == 0) return;
  final lastP = p - 1;
  huffSize[lastP] = 0; // sentinel (drops the 256 EOI symbol)

  final huffCode = Int32List(p);
  var code = 0;
  var si = huffSize[0];
  var k = 0;
  while (huffSize[k] != 0) {
    while (huffSize[k] == si) {
      huffCode[k] = code;
      code++;
      k++;
    }
    code <<= 1;
    si++;
  }
  for (var i = 0; i < lastP; i++) {
    table.depth[huff.values[i]] = huffSize[i];
    table.code[huff.values[i]] = huffCode[i];
  }
}

/// Number of bits in the JPEG magnitude category of [v].
int _magnitudeBits(int v) {
  var a = v < 0 ? -v : v;
  var n = 0;
  while (a > 0) {
    n++;
    a >>= 1;
  }
  return n;
}

/// The `nbits` low bits JPEG stores for value [v] (one's-complement for
/// negatives): `v` for v>=0, `v-1` for v<0.
int _magnitudeValue(int v, int nbits) =>
    (v >= 0 ? v : v - 1) & ((1 << nbits) - 1);

/// MSB-first bit accumulator with JPEG 0xFF byte-stuffing. Reconstruction is
/// an archival path (not the decode hot loop), so a simple accumulator is used
/// rather than libjxl's 64-bit-word writer.
final class _JpegBitWriter {
  _JpegBitWriter(this._out);
  final BytesBuilder _out;
  int _acc = 0;
  int _nbits = 0;

  void writeBits(int nbits, int value) {
    if (nbits == 0) return;
    _acc = (_acc << nbits) | (value & ((1 << nbits) - 1));
    _nbits += nbits;
    while (_nbits >= 8) {
      _nbits -= 8;
      final b = (_acc >> _nbits) & 0xFF;
      _out.addByte(b);
      if (b == 0xFF) _out.addByte(0x00);
    }
    _acc &= (1 << _nbits) - 1;
  }

  void writeSymbol(int symbol, _HuffTable table) {
    writeBits(table.depth[symbol], table.code[symbol]);
  }

  /// Pads to the next byte boundary. When [padBits] is null, pads with 1-bits;
  /// otherwise consumes the exact stored padding bits. Returns the new
  /// pad-bit cursor.
  int jumpToByteBoundary(Uint8List? padBits, int padPos, int padEnd) {
    final need = (8 - (_nbits & 7)) & 7;
    if (need == 0) return padPos;
    int pattern;
    if (padBits == null) {
      pattern = (1 << need) - 1;
    } else {
      pattern = 0;
      for (var i = 0; i < need; i++) {
        if (padPos >= padEnd) {
          throw const JxlInvalidBitstreamException('too few JPEG padding bits');
        }
        final bit = padBits[padPos++];
        pattern = (pattern << 1) | bit;
      }
    }
    writeBits(need, pattern);
    return padPos;
  }
}

final class _SerializationState {
  _SerializationState(this.jpg) {
    if (jpg.hasZeroPaddingBit) {
      padBits = jpg.paddingBits;
    }
  }
  final JpegData jpg;
  final List<_HuffTable> dcHuff = List.generate(4, (_) => _HuffTable());
  final List<_HuffTable> acHuff = List.generate(4, (_) => _HuffTable());
  int dqtIndex = 0;
  int dhtIndex = 0;
  int appIndex = 0;
  int comIndex = 0;
  int dataIndex = 0;
  int scanIndex = 0;
  bool isProgressive = false;
  bool seenDri = false;
  Uint8List? padBits;
  int padBitsPos = 0;
}

void _serializeSection(int marker, _SerializationState st, BytesBuilder out) {
  switch (marker) {
    case 0xC0:
    case 0xC1:
    case 0xC2:
    case 0xC9:
    case 0xCA:
      _encodeSof(marker, st, out);
    case 0xC4:
      _encodeDht(st, out);
    case >= 0xD0 && <= 0xD7:
      out.add(Uint8List.fromList([0xFF, marker]));
    case 0xD9:
      out.add(Uint8List.fromList(const [0xFF, 0xD9]));
      out.add(st.jpg.tailData);
    case 0xDA:
      _encodeScan(st, out);
    case 0xDB:
      _encodeDqt(st, out);
    case 0xDD:
      st.seenDri = true;
      final ri = st.jpg.restartInterval;
      out.add(Uint8List.fromList([0xFF, 0xDD, 0, 4, ri >> 8, ri & 0xFF]));
    case >= 0xE0 && <= 0xEF:
      final i = st.appIndex++;
      out.addByte(0xFF);
      out.add(st.jpg.appData[i]);
    case 0xFE:
      final i = st.comIndex++;
      out.addByte(0xFF);
      out.add(st.jpg.comData[i]);
    case 0xFF:
      out.add(st.jpg.interMarkerData[st.dataIndex++]);
    default:
      throw JxlInvalidBitstreamException(
          'unexpected JPEG marker 0x${marker.toRadixString(16)}');
  }
}

void _encodeSof(int marker, _SerializationState st, BytesBuilder out) {
  if (marker <= 0xC2) st.isProgressive = marker == 0xC2;
  final jpg = st.jpg;
  final n = jpg.components.length;
  final len = 8 + 3 * n;
  final d = Uint8List(len + 2);
  var p = 0;
  d[p++] = 0xFF;
  d[p++] = marker;
  d[p++] = len >> 8;
  d[p++] = len & 0xFF;
  d[p++] = 8; // precision
  d[p++] = jpg.height >> 8;
  d[p++] = jpg.height & 0xFF;
  d[p++] = jpg.width >> 8;
  d[p++] = jpg.width & 0xFF;
  d[p++] = n;
  for (final c in jpg.components) {
    d[p++] = c.id;
    d[p++] = (c.hSampFactor << 4) | c.vSampFactor;
    d[p++] = jpg.quant[c.quantIdx].index;
  }
  out.add(d);
}

void _encodeSos(JpegScanInfo scan, _SerializationState st, BytesBuilder out) {
  final jpg = st.jpg;
  final n = scan.numComponents;
  final len = 6 + 2 * n;
  final d = Uint8List(len + 2);
  var p = 0;
  d[p++] = 0xFF;
  d[p++] = 0xDA;
  d[p++] = len >> 8;
  d[p++] = len & 0xFF;
  d[p++] = n;
  for (var i = 0; i < n; i++) {
    final si = scan.components[i];
    d[p++] = jpg.components[si.compIdx].id;
    d[p++] = (si.dcTblIdx << 4) + si.acTblIdx;
  }
  d[p++] = scan.ss;
  d[p++] = scan.se;
  d[p++] = (scan.ah << 4) | scan.al;
  out.add(d);
}

void _encodeDht(_SerializationState st, BytesBuilder out) {
  final huffs = st.jpg.huffmanCode;
  var len = 2;
  for (var i = st.dhtIndex; i < huffs.length; i++) {
    len += kJpegHuffmanMaxBitLength;
    for (final c in huffs[i].counts) {
      len += c;
    }
    if (huffs[i].isLast) break;
  }
  final d = Uint8List(len + 2);
  var p = 0;
  d[p++] = 0xFF;
  d[p++] = 0xC4;
  d[p++] = len >> 8;
  d[p++] = len & 0xFF;
  while (true) {
    final idx = st.dhtIndex++;
    if (idx >= huffs.length) {
      throw const JxlInvalidBitstreamException('DHT index past end');
    }
    final huff = huffs[idx];
    var index = huff.slotId;
    final _HuffTable table;
    if (index & 0x10 != 0) {
      index -= 0x10;
      table = st.acHuff[index];
    } else {
      table = st.dcHuff[index];
    }
    _buildHuffTable(huff, table);
    table.initialized = true;
    var totalCount = 0;
    var maxLength = 0;
    for (var i = 0; i < huff.counts.length; i++) {
      if (huff.counts[i] != 0) maxLength = i;
      totalCount += huff.counts[i];
    }
    totalCount--; // drop the synthetic 256 EOI symbol
    d[p++] = huff.slotId;
    for (var i = 1; i <= kJpegHuffmanMaxBitLength; i++) {
      d[p++] = (i == maxLength ? huff.counts[i] - 1 : huff.counts[i]);
    }
    for (var i = 0; i < totalCount; i++) {
      d[p++] = huff.values[i];
    }
    if (huff.isLast) break;
  }
  out.add(d);
}

void _encodeDqt(_SerializationState st, BytesBuilder out) {
  final tables = st.jpg.quant;
  var len = 2;
  for (var i = st.dqtIndex; i < tables.length; i++) {
    len += 1 + (tables[i].precision != 0 ? 2 : 1) * kDctBlockSize;
    if (tables[i].isLast) break;
  }
  final d = Uint8List(len + 2);
  var p = 0;
  d[p++] = 0xFF;
  d[p++] = 0xDB;
  d[p++] = len >> 8;
  d[p++] = len & 0xFF;
  while (true) {
    final idx = st.dqtIndex++;
    if (idx >= tables.length) {
      throw const JxlInvalidBitstreamException('DQT index past end');
    }
    final t = tables[idx];
    d[p++] = (t.precision << 4) + t.index;
    for (var i = 0; i < kDctBlockSize; i++) {
      final v = t.values[kJpegNaturalOrder[i]];
      if (t.precision != 0) d[p++] = v >> 8;
      d[p++] = v & 0xFF;
    }
    if (t.isLast) break;
  }
  out.add(d);
}

/// Baseline sequential entropy coding of one 8x8 block. [coeffs] is a 64-entry
/// natural-order (raster) quantized block. Port of `EncodeDCTBlockSequential`.
void _encodeBlockSequential(
  Int32List coeffs,
  int base,
  _HuffTable dcHuff,
  _HuffTable acHuff,
  int numZeroRuns,
  List<int> lastDc,
  int compIdx,
  _JpegBitWriter bw,
) {
  final dc = coeffs[base];
  final diff = dc - lastDc[compIdx];
  lastDc[compIdx] = dc;
  final dcNbits = _magnitudeBits(diff);
  bw.writeSymbol(dcNbits, dcHuff);
  if (dcNbits != 0) {
    bw.writeBits(dcNbits, _magnitudeValue(diff, dcNbits));
  }

  var r = 0;
  for (var i = 1; i < 64; i++) {
    final v = coeffs[base + kJpegNaturalOrder[i]];
    if (v == 0) {
      r++;
    } else {
      while (r > 15) {
        bw.writeSymbol(0xF0, acHuff); // ZRL
        r -= 16;
      }
      final nbits = _magnitudeBits(v);
      final symbol = (r << 4) + nbits;
      bw.writeSymbol(symbol, acHuff);
      bw.writeBits(nbits, _magnitudeValue(v, nbits));
      r = 0;
    }
  }
  for (var i = 0; i < numZeroRuns; i++) {
    bw.writeSymbol(0xF0, acHuff);
    r -= 16;
  }
  if (r > 0) {
    bw.writeSymbol(0, acHuff); // EOB
  }
}

void _encodeScan(_SerializationState st, BytesBuilder out) {
  final jpg = st.jpg;
  final scan = jpg.scanInfo[st.scanIndex];
  if (st.isProgressive &&
      !(scan.ah == 0 && scan.al == 0 && scan.ss == 0 && scan.se == 63)) {
    throw JxlUnsupportedException('jpeg-progressive-scan');
  }
  _encodeSos(scan, st, out);

  final bw = _JpegBitWriter(out);
  final restartInterval = st.seenDri ? jpg.restartInterval : 0;
  final lastDc = List<int>.filled(4, 0);
  final isInterleaved = scan.numComponents > 1;

  final mcu = _calculateMcuSize(jpg, scan);
  final mcusPerRow = mcu.$1;
  final mcuRows = mcu.$2;

  var restartsToGo = restartInterval;
  var nextRestartMarker = 0;
  var blockScanIndex = 0;
  var extraZeroPos = 0;
  var nextExtraZeroIndex = extraZeroPos < scan.extraZeroRuns.length
      ? scan.extraZeroRuns[0].blockIdx
      : -1;
  var nextResetPointPos = 0;
  var nextResetPoint = nextResetPointPos < scan.resetPoints.length
      ? scan.resetPoints[nextResetPointPos++]
      : -1;

  for (var mcuY = 0; mcuY < mcuRows; mcuY++) {
    for (var mcuX = 0; mcuX < mcusPerRow; mcuX++) {
      if (restartInterval > 0 && restartsToGo == 0) {
        st.padBitsPos = bw.jumpToByteBoundary(
            st.padBits, st.padBitsPos, jpg.paddingBits.length);
        _emitMarker(out, bw, 0xD0 + nextRestartMarker);
        nextRestartMarker = (nextRestartMarker + 1) & 0x7;
        restartsToGo = restartInterval;
        for (var i = 0; i < 4; i++) {
          lastDc[i] = 0;
        }
      }
      for (var i = 0; i < scan.numComponents; i++) {
        final si = scan.components[i];
        final c = jpg.components[si.compIdx];
        final dcHuff = st.dcHuff[si.dcTblIdx];
        final acHuff = st.acHuff[si.acTblIdx];
        final nBlocksY = isInterleaved ? c.vSampFactor : 1;
        final nBlocksX = isInterleaved ? c.hSampFactor : 1;
        for (var iy = 0; iy < nBlocksY; iy++) {
          for (var ix = 0; ix < nBlocksX; ix++) {
            final blockY = mcuY * nBlocksY + iy;
            final blockX = mcuX * nBlocksX + ix;
            final blockIdx = blockY * c.widthInBlocks + blockX;
            if (blockScanIndex == nextResetPoint) {
              nextResetPoint = nextResetPointPos < scan.resetPoints.length
                  ? scan.resetPoints[nextResetPointPos++]
                  : -1;
            }
            var numZeroRuns = 0;
            if (blockScanIndex == nextExtraZeroIndex) {
              numZeroRuns = scan.extraZeroRuns[extraZeroPos].numExtraZeroRuns;
              extraZeroPos++;
              nextExtraZeroIndex = extraZeroPos < scan.extraZeroRuns.length
                  ? scan.extraZeroRuns[extraZeroPos].blockIdx
                  : -1;
            }
            _encodeBlockSequential(c.coeffs, blockIdx << 6, dcHuff, acHuff,
                numZeroRuns, lastDc, si.compIdx, bw);
            blockScanIndex++;
          }
        }
      }
      restartsToGo--;
    }
  }
  st.padBitsPos =
      bw.jumpToByteBoundary(st.padBits, st.padBitsPos, jpg.paddingBits.length);
  st.scanIndex++;
}

void _emitMarker(BytesBuilder out, _JpegBitWriter bw, int marker) {
  // The bit writer flushes complete bytes eagerly and is byte-aligned here
  // (a restart is always preceded by jumpToByteBoundary), so appending the
  // marker directly to the output is correct.
  out.add(Uint8List.fromList([0xFF, marker]));
}

/// Port of `JPEGData::CalculateMcuSize`. Returns (MCUs per row, MCU rows).
(int, int) _calculateMcuSize(JpegData jpg, JpegScanInfo scan) {
  final isInterleaved = scan.numComponents > 1;
  final base = jpg.components[scan.components[0].compIdx];
  final hGroup = isInterleaved ? 1 : base.hSampFactor;
  final vGroup = isInterleaved ? 1 : base.vSampFactor;
  var maxH = 1, maxV = 1;
  for (final c in jpg.components) {
    if (c.hSampFactor > maxH) maxH = c.hSampFactor;
    if (c.vSampFactor > maxV) maxV = c.vSampFactor;
  }
  final mcusPerRow = _divCeil(jpg.width * hGroup, 8 * maxH);
  final mcuRows = _divCeil(jpg.height * vGroup, 8 * maxV);
  return (mcusPerRow, mcuRows);
}

int _divCeil(int a, int b) => (a + b - 1) ~/ b;
