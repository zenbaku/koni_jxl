import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'jxl_codec.dart';

/// Plays a (possibly animated) JPEG XL image.
///
/// Frame timing follows the stream's tick durations; [JxlUiAnimation.numLoops]
/// is honored (0 loops forever). Still images render as a plain [RawImage].
class JxlAnimationView extends StatefulWidget {
  const JxlAnimationView(this.bytes,
      {super.key,
      this.fit = BoxFit.contain,
      this.filterQuality = FilterQuality.medium});

  final Uint8List bytes;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  State<JxlAnimationView> createState() => _JxlAnimationViewState();
}

class _JxlAnimationViewState extends State<JxlAnimationView> {
  JxlUiAnimation? _animation;
  int _frame = 0;
  int _loopsDone = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final anim = await decodeJxlAnimation(widget.bytes);
    if (!mounted) {
      anim.dispose();
      return;
    }
    setState(() => _animation = anim);
    if (anim.isAnimated) _schedule();
  }

  void _schedule() {
    final anim = _animation!;
    _timer = Timer(anim.frameDurations[_frame], () {
      if (!mounted) return;
      var next = _frame + 1;
      if (next == anim.frames.length) {
        _loopsDone++;
        if (anim.numLoops != 0 && _loopsDone >= anim.numLoops) return;
        next = 0;
      }
      setState(() => _frame = next);
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animation?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final anim = _animation;
    if (anim == null) return const SizedBox.expand();
    return FittedBox(
      fit: widget.fit,
      child: RawImage(
        image: anim.frames[_frame],
        filterQuality: widget.filterQuality,
      ),
    );
  }
}
