@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';

/// Streaming decoder gates: state transitions on chunked input, preview
/// availability and sanity, and final-decode equivalence.
final corpusDir = Directory('../../third_party/corpus/jxl');

Uint8List _read(String name) =>
    File('${corpusDir.path}/$name').readAsBytesSync();

/// Wraps a bare codestream in an ISOBMFF container split across two jxlp
/// boxes (exercises the partial-box demuxer).
Uint8List _containerize(Uint8List codestream) {
  final half = codestream.length ~/ 2;
  final out = BytesBuilder();
  out.add([0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]);
  void box(String tag, List<int> payload) {
    final size = 8 + payload.length;
    out.add([size >> 24, (size >> 16) & 255, (size >> 8) & 255, size & 255]);
    out.add(tag.codeUnits);
    out.add(payload);
  }

  box('jxlp', [0, 0, 0, 0, ...codestream.sublist(0, half)]);
  box('jxlp', [0x80, 0, 0, 1, ...codestream.sublist(half)]);
  return out.toBytes();
}

void _feedAndCheck(Uint8List bytes,
    {required bool expectPreview, int chunkSize = 997}) {
  final dec = JxlStreamingDecoder();
  var lastState = JxlStreamState.needsBytes;
  var lastProgress = 0.0;
  for (var off = 0; off < bytes.length; off += chunkSize) {
    dec.addBytes(bytes.sublist(off, math.min(off + chunkSize, bytes.length)));
    final s = dec.state;
    expect(s.index, greaterThanOrEqualTo(lastState.index),
        reason: 'state must be monotone');
    lastState = s;
    final p = dec.progress;
    expect(p, inInclusiveRange(0, 1));
    expect(p, greaterThanOrEqualTo(lastProgress - 1e-9),
        reason: 'progress must be monotone');
    lastProgress = p;
    if (s == JxlStreamState.headersReady || s == JxlStreamState.dcReady) {
      expect(dec.info, isNotNull);
    }
  }
  expect(dec.state, JxlStreamState.complete);
  expect(dec.progress, 1.0);
  final info = dec.info!;

  final preview = dec.decodePreview();
  if (expectPreview) {
    expect(preview, isNotNull);
    expect(preview!.isPreview, isTrue);
    expect(preview.width, (info.width + 7) ~/ 8);
    expect(preview.height, (info.height + 7) ~/ 8);
    // Preview must resemble the box-downscaled final image.
    final full = dec.decodeFinal();
    final fullRgba = full.toRgba8();
    final prevRgba = preview.toRgba8();
    var sq = 0.0;
    var n = 0;
    for (var y = 0; y < preview.height; y++) {
      for (var x = 0; x < preview.width; x++) {
        for (var c = 0; c < 3; c++) {
          var sum = 0;
          var cnt = 0;
          for (var dy = 0; dy < 8; dy++) {
            for (var dx = 0; dx < 8; dx++) {
              final fy = y * 8 + dy;
              final fx = x * 8 + dx;
              if (fy < full.height && fx < full.width) {
                sum += fullRgba[(fy * full.width + fx) * 4 + c];
                cnt++;
              }
            }
          }
          final d = prevRgba[(y * preview.width + x) * 4 + c] - sum / cnt;
          sq += d * d;
          n++;
        }
      }
    }
    expect(math.sqrt(sq / n), lessThan(16.0),
        reason: 'preview must resemble the downscaled image');
  } else {
    expect(preview, isNull);
  }

  // Final decode must be identical to the one-shot decoder.
  final streamed = dec.decodeFinal();
  final oneShot = JxlDecoder.decode(bytes);
  expect(channelAsInts(streamed.channels[0], 255),
      channelAsInts(oneShot.channels[0], 255));
}

void main() {
  final haveCorpus = corpusDir.existsSync();
  final skip = haveCorpus ? false : 'corpus not generated';

  test('VarDCT bare codestream streams to preview and final', () {
    _feedAndCheck(_read('color_cover_d1.0_e7.jxl'), expectPreview: true);
  }, skip: skip);

  test('progressive-DC file previews from its LF frame', () {
    final bytes = _read('gray_screentone_d1.0_e5_progdc2.jxl');
    final dec = JxlStreamingDecoder();
    var dcAt = -1;
    const chunk = 2048;
    for (var off = 0; off < bytes.length; off += chunk) {
      dec.addBytes(bytes.sublist(off, math.min(off + chunk, bytes.length)));
      if (dcAt < 0 && dec.state.index >= JxlStreamState.dcReady.index) {
        dcAt = dec.bytesReceived;
      }
    }
    // The whole point: the preview becomes available early in the stream.
    expect(dcAt, greaterThan(0));
    expect(dcAt, lessThan(bytes.length ~/ 10),
        reason: 'LF-frame preview should need <10% of the file');
    _feedAndCheck(bytes, expectPreview: true);
  }, skip: skip);

  test('modular (lossless) file has no preview but streams to complete', () {
    _feedAndCheck(_read('gray_screentone_d0_e7.jxl'), expectPreview: false);
  }, skip: skip);

  test('container with split jxlp boxes streams correctly', () {
    final bytes = _containerize(_read('color_cover_d1.0_e7.jxl'));
    final dec = JxlStreamingDecoder();
    for (var off = 0; off < bytes.length; off += 1013) {
      dec.addBytes(bytes.sublist(off, math.min(off + 1013, bytes.length)));
    }
    expect(dec.state, JxlStreamState.complete);
    expect(dec.decodePreview(), isNotNull);
    final streamed = dec.decodeFinal();
    final oneShot = JxlDecoder.decode(bytes);
    expect(channelAsInts(streamed.channels[0], 255),
        channelAsInts(oneShot.channels[0], 255));
  }, skip: skip);

  test('decodeFinal before complete throws StateError', () {
    final bytes = _read('color_cover_d1.0_e7.jxl');
    final dec = JxlStreamingDecoder()
      ..addBytes(bytes.sublist(0, bytes.length ~/ 2));
    expect(dec.state, isNot(JxlStreamState.complete));
    expect(dec.decodeFinal, throwsStateError);
  }, skip: skip);

  test('animation streams to complete and decodes all frames', () {
    final bytes = _read('anim_d0.jxl');
    final dec = JxlStreamingDecoder();
    for (var off = 0; off < bytes.length; off += 97) {
      dec.addBytes(bytes.sublist(off, math.min(off + 97, bytes.length)));
    }
    expect(dec.state, JxlStreamState.complete);
    expect(dec.decodeFinalAnimation().frames.length, 4);
  }, skip: skip);
}
