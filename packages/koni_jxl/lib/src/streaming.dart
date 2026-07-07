import 'dart:math' as math;
import 'dart:typed_data';

import 'decoder.dart';
import 'exceptions.dart';
import 'frame/frame.dart';
import 'frame/frame_flags.dart';
import 'header/image_header.dart';
import 'icc/icc_codec.dart';
import 'io/bit_reader.dart';
import 'io/container.dart';
import 'jxl_image.dart';
import 'jxl_info.dart';
import 'render/dc_image.dart';
import 'util/image_buffer.dart';

/// What a [JxlStreamingDecoder] can produce with the bytes seen so far.
enum JxlStreamState {
  /// Not enough bytes for anything yet.
  needsBytes,

  /// The image header is parsed: [JxlStreamingDecoder.info] is available.
  headersReady,

  /// The DC sections are buffered: [JxlStreamingDecoder.decodePreview]
  /// returns a 1:8 preview.
  dcReady,

  /// All frames are buffered: [JxlStreamingDecoder.decodeFinal] works
  /// (and the preview stays available for VarDCT images).
  complete,
}

/// Incremental decoding of a JPEG XL byte stream.
///
/// Feed bytes as they arrive with [addBytes]; [state] reports what is
/// achievable right now. For VarDCT images the DC sections (typically
/// 1–2% of the file) yield a 1:8 preview via [decodePreview] — the classic
/// blurry-then-sharp progressive experience. Modular (lossless) images
/// have no DC concept: they go straight from [JxlStreamState.headersReady]
/// to [JxlStreamState.complete], with [progress] still advancing.
///
/// [addBytes] only buffers; parsing happens lazily on [state]/[progress]/
/// [info] queries (headers and TOC only, cheap) and pixel decoding only in
/// [decodePreview]/[decodeFinal]. Malformed data throws
/// [JxlInvalidBitstreamException] from any of those.
final class JxlStreamingDecoder {
  Uint8List _data = Uint8List(64 * 1024);
  int _length = 0;
  _Probe? _probeCache;
  int _probeCacheLength = -1;
  JxlImage? _cachedPreview;

  /// Appends a chunk of the file. Cheap: no parsing happens here.
  void addBytes(List<int> chunk) {
    if (_length + chunk.length > _data.length) {
      var capacity = _data.length * 2;
      while (capacity < _length + chunk.length) {
        capacity *= 2;
      }
      final grown = Uint8List(capacity);
      grown.setRange(0, _length, _data);
      _data = grown;
    }
    _data.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
  }

  /// Total bytes buffered so far.
  int get bytesReceived => _length;

  JxlStreamState get state => _probe().state;

  /// Parsed header info, once [state] is at least
  /// [JxlStreamState.headersReady].
  JxlInfo? get info => _probe().info;

  /// Fraction of the codestream buffered, in [0, 1]. Exact (and monotone)
  /// once the last frame's table of contents has been seen — for
  /// single-frame stills that is the first table of contents. Until the
  /// total extent is known it stays 0.
  double get progress {
    final p = _probe();
    if (p.state == JxlStreamState.complete) return 1.0;
    if (!p.sawLastFrame || p.knownEndByte <= 0) return 0.0;
    return math.min(1.0, p.codestreamLength / p.knownEndByte);
  }

  /// Decodes the 1:8 DC preview. Returns null until [JxlStreamState.dcReady]
  /// (and always for images without a DC image, e.g. lossless modular).
  /// The result is cached; repeated calls are free.
  JxlImage? decodePreview() {
    if (_cachedPreview != null) return _cachedPreview;
    final p = _probe();
    if (!p.dcAvailable) return null;
    return _cachedPreview = _decodePreview(p);
  }

  /// Decodes the complete image (first visible frame). Throws [StateError]
  /// unless [state] is [JxlStreamState.complete].
  JxlImage decodeFinal() {
    _requireComplete();
    return JxlDecoder.decode(_bytesCopy());
  }

  /// Decodes all frames of the complete image.
  JxlAnimation decodeFinalAnimation() {
    _requireComplete();
    return JxlDecoder.decodeAnimation(_bytesCopy());
  }

  void _requireComplete() {
    if (_probe().state != JxlStreamState.complete) {
      throw StateError('stream is not complete yet '
          '(${(progress * 100).toStringAsFixed(0)}% buffered)');
    }
  }

  Uint8List _bytesCopy() {
    final out = Uint8List(_length);
    out.setRange(0, _length, _data);
    return out;
  }

  Uint8List get _view => Uint8List.sublistView(_data, 0, _length);

  _Probe _probe() {
    if (_probeCacheLength == _length) return _probeCache!;
    final probe = _computeProbe();
    _probeCache = probe;
    _probeCacheLength = _length;
    return probe;
  }

  _Probe _computeProbe() {
    final Uint8List codestream;
    try {
      codestream = demuxContainerPartial(_view);
    } on JxlTruncatedException {
      return _Probe.needsBytes();
    }

    final reader = BitReader(codestream);
    final ImageHeader header;
    try {
      // Probe permissively at level 10; the real decode enforces the
      // container's declared level.
      header = ImageHeader.read(reader, level: 10);
      if (header.iccEncodedSize != null) {
        IccCodec.readEncodedStream(reader, header.iccEncodedSize!);
        reader.zeroPadToByte();
      }
    } on JxlTruncatedException {
      return _Probe.needsBytes();
    } on RangeError {
      return _Probe.needsBytes();
    }

    final probe = _Probe(header, codestream.length);
    try {
      if (header.previewSize != null) {
        final preview = Frame(reader, header);
        preview.readFrameHeader();
        preview.readToc();
      }
      var sawRegularFrame = false;
      for (var i = 0; i < 1 << 20; i++) {
        final frame = Frame(reader, header);
        final fh = frame.readFrameHeader();
        frame.readToc(allowTruncated: true);
        final toc = frame.toc;
        final frameComplete = toc.availableBytes >= toc.totalBytes;
        // In truncated mode the reader is left at the payload start;
        // otherwise it has been advanced past the payload.
        probe.knownEndByte = frameComplete
            ? reader.bitsRead >> 3
            : (reader.bitsRead >> 3) + toc.totalBytes;
        final isRegular = fh.type == FrameFlags.regularFrame ||
            fh.type == FrameFlags.skipProgressive;
        // A completed level-1 LF frame IS a 1:8 image (progressive-DC
        // files); every frame before it in the walk is already complete.
        if (!probe.dcAvailable &&
            fh.type == FrameFlags.lfFrame &&
            fh.lfLevel == 1 &&
            frameComplete) {
          probe.dcAvailable = true;
          probe.previewFromLfFrame = true;
        }
        if (!sawRegularFrame && isRegular) {
          sawRegularFrame = true;
          if (!probe.dcAvailable) {
            probe.dcAvailable = _dcSectionsAvailable(frame, header);
          }
        }
        if (fh.isLast) probe.sawLastFrame = true;
        if (!frameComplete) break;
        if (fh.isLast) {
          probe.allFramesBuffered = true;
          break;
        }
      }
    } on JxlTruncatedException {
      // A later frame header/TOC is not buffered yet; keep what we have.
    } on RangeError {
      // Same: partial bytes mid-structure.
    }
    return probe;
  }

  static bool _dcSectionsAvailable(Frame frame, ImageHeader header) {
    final fh = frame.header;
    if (fh.encoding != FrameFlags.vardct) return false;
    if (fh.flags & FrameFlags.useLfFrame != 0) return false;
    // A frame that doesn't cover the canvas would make a misleading preview.
    if (fh.x0 != 0 ||
        fh.y0 != 0 ||
        fh.width < header.size.width ||
        fh.height < header.size.height) {
      return false;
    }
    if (frame.tocEntryCount <= 1) return false;
    for (var i = 0; i <= frame.numLfGroups; i++) {
      if (!frame.toc.sectionAvailable(i)) return false;
    }
    return true;
  }

  JxlImage _decodePreview(_Probe probe) {
    final codestream = demuxContainerPartial(_view);
    final reader = BitReader(codestream);
    final header = ImageHeader.read(reader, level: 10);
    Uint8List? iccProfile;
    if (header.iccEncodedSize != null) {
      final encoded =
          IccCodec.readEncodedStream(reader, header.iccEncodedSize!);
      reader.zeroPadToByte();
      iccProfile = IccCodec.decompress(encoded);
    }
    if (header.previewSize != null) {
      final preview = Frame(reader, header);
      preview.readFrameHeader();
      preview.readToc();
    }
    // Walk to the preview source: the level-1 LF frame when present,
    // otherwise the first regular frame. Frames preceding the source were
    // fully buffered, or the probe would not have reported dcAvailable.
    final lfBuffers = List<List<ImageBuffer>?>.filled(5, null);
    for (var i = 0; i < 1 << 20; i++) {
      final frame = Frame(reader, header);
      final fh = frame.readFrameHeader();
      frame.readToc(allowTruncated: true);
      if (probe.previewFromLfFrame && fh.type == FrameFlags.lfFrame) {
        frame.decodeFrame(lfFrame: lfBuffers[fh.lfLevel]);
        if (fh.lfLevel == 1) {
          return buildDcImageFromRows(
            [for (var c = 0; c < 3; c++) frame.buffer[c].floatRows],
            frame.paddedFrameSize.height,
            frame.paddedFrameSize.width,
            frame.header.doYCbCr,
            header,
            iccProfile,
          );
        }
        lfBuffers[fh.lfLevel - 1] = frame.buffer;
        continue;
      }
      if (fh.type == FrameFlags.regularFrame ||
          fh.type == FrameFlags.skipProgressive) {
        frame.decodeLfOnly();
        return buildDcImage(frame, header, iccProfile);
      }
    }
    throw const JxlInvalidBitstreamException('no visible frame found');
  }
}

final class _Probe {
  _Probe(ImageHeader header, this.codestreamLength)
      : info = JxlInfo.internal(header, false);

  _Probe.needsBytes()
      : info = null,
        codestreamLength = 0;

  final JxlInfo? info;
  final int codestreamLength;
  int knownEndByte = 0;
  bool dcAvailable = false;
  bool previewFromLfFrame = false;
  bool sawLastFrame = false;
  bool allFramesBuffered = false;

  JxlStreamState get state {
    if (info == null) return JxlStreamState.needsBytes;
    if (allFramesBuffered) return JxlStreamState.complete;
    if (dcAvailable) return JxlStreamState.dcReady;
    return JxlStreamState.headersReady;
  }
}
