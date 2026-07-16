@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koni_jxl/koni_jxl.dart';
import 'package:test/test.dart';

import '../util/compare.dart';
import '../util/pnm.dart';

/// Animation gate: all frames of animated files decode correctly.
///
/// The synthetic corpus animation must be bit-exact against its source
/// frames; conformance animations are checked for frame count and against
/// djxl's first-frame output.
final corpusDir = Directory('../../third_party/corpus');
final conformanceDir = Directory('../../third_party/conformance/testcases');

void main() {
  final haveCorpus = corpusDir.existsSync();
  final haveConformance = conformanceDir.existsSync();

  group('corpus animation', () {
    test('anim_d0 decodes all frames bit-exact', () {
      final file = File('${corpusDir.path}/jxl/anim_d0.jxl');
      final anim = JxlDecoder.decodeAnimation(
          Uint8List.fromList(file.readAsBytesSync()));
      expect(anim.frames.length, 4);
      expect(anim.durations, [10, 10, 10, 10]);
      expect(anim.tpsNumerator, 100);
      expect(anim.frameDuration(0), const Duration(milliseconds: 100));
      expect(anim.isAnimated, isTrue);
      for (var i = 0; i < 4; i++) {
        final ref = PnmImage.parse(
            File('${corpusDir.path}/golden/anim_frame_$i.ppm')
                .readAsBytesSync());
        final frame = anim.frames[i];
        expect(frame.width, ref.width);
        expect(frame.height, ref.height);
        for (var c = 0; c < 3; c++) {
          expect(
              channelAsInts(frame.channels[c], ref.maxValue), ref.intPlanes![c],
              reason: 'frame $i channel $c');
        }
      }
    }, skip: haveCorpus ? false : 'corpus not generated');

    test('decodeAnimation of a still image yields one frame', () {
      final file = File('${corpusDir.path}/jxl/screentone_256_d0_e5.jxl');
      final bytes = Uint8List.fromList(file.readAsBytesSync());
      final anim = JxlDecoder.decodeAnimation(bytes);
      expect(anim.frames.length, 1);
      expect(anim.isAnimated, isFalse);
      final still = JxlDecoder.decode(bytes);
      expect(channelAsInts(anim.frames.first.channels[0], 255),
          channelAsInts(still.channels[0], 255));
    }, skip: haveCorpus ? false : 'corpus not generated');
  });

  group('conformance animations', () {
    test('animation_spline: 60 frames, frame 0 within tolerance of djxl', () {
      final input = File('${conformanceDir.path}/animation_spline/input.jxl');
      final anim = JxlDecoder.decodeAnimation(
          Uint8List.fromList(input.readAsBytesSync()));
      expect(anim.frames.length, 60);
      final refPath = '${Directory.systemTemp.path}/koni_anim_spline_ref.ppm';
      final r =
          Process.runSync('djxl', [input.path, refPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final ref = PnmImage.parse(File(refPath).readAsBytesSync());
      var mx = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(anim.frames.first.channels[c], ref.maxValue);
        final theirs = ref.intPlanes![c];
        for (var i = 0; i < ours.length; i++) {
          final d = (ours[i] - theirs[i]).abs();
          if (d > mx) mx = d;
        }
      }
      expect(mx, lessThanOrEqualTo(2));
    }, skip: haveConformance ? false : 'conformance not available');

    test('newtons_cradle: 36 frames, frame 0 bit-exact vs djxl', () {
      final input =
          File('${conformanceDir.path}/animation_newtons_cradle/input.jxl');
      final anim = JxlDecoder.decodeAnimation(
          Uint8List.fromList(input.readAsBytesSync()));
      expect(anim.frames.length, 36);
      final refPath = '${Directory.systemTemp.path}/koni_anim_cradle_ref.ppm';
      final r =
          Process.runSync('djxl', [input.path, refPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final ref = PnmImage.parse(File(refPath).readAsBytesSync());
      for (var c = 0; c < 3; c++) {
        expect(channelAsInts(anim.frames.first.channels[c], ref.maxValue),
            ref.intPlanes![c],
            reason: 'channel $c');
      }
    }, skip: haveConformance ? false : 'conformance not available');

    test('icos4d: 48 frames, frame 0 within lossy tolerance of djxl', () {
      final input = File('${conformanceDir.path}/animation_icos4d/input.jxl');
      final anim = JxlDecoder.decodeAnimation(
          Uint8List.fromList(input.readAsBytesSync()));
      expect(anim.frames.length, 48);
      expect(anim.numLoops, 0);
      final refPath = '${Directory.systemTemp.path}/koni_anim_icos_ref.ppm';
      final r =
          Process.runSync('djxl', [input.path, refPath, '--num_threads', '1']);
      expect(r.exitCode, 0, reason: r.stderr.toString());
      final ref = PnmImage.parse(File(refPath).readAsBytesSync());
      var sq = 0;
      var n = 0;
      var mx = 0;
      for (var c = 0; c < 3; c++) {
        final ours = channelAsInts(anim.frames.first.channels[c], ref.maxValue);
        final theirs = ref.intPlanes![c];
        for (var i = 0; i < ours.length; i++) {
          final d = (ours[i] - theirs[i]).abs();
          if (d > mx) mx = d;
          sq += d * d;
          n++;
        }
      }
      expect(math.sqrt(sq / n), lessThan(2.0));
      expect(mx, lessThan(48));
    }, skip: haveConformance ? false : 'conformance not available');
  });
}
