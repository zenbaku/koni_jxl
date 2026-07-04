import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:koni_jxl_flutter/koni_jxl_flutter.dart';

/// A manga-reader-style demo of [JxlPagePrefetcher]: a horizontally
/// swipeable "chapter" that decodes upcoming pages on background isolates
/// while the current one is displayed. There's only one manga-styled asset
/// in this example app, so the same bytes stand in for several distinct
/// "pages" - the prefetcher doesn't care that the content repeats, it's
/// still exercising real window/cancel/evict bookkeeping across page
/// turns.
class JxlReaderDemo extends StatefulWidget {
  const JxlReaderDemo({super.key});

  @override
  State<JxlReaderDemo> createState() => _JxlReaderDemoState();
}

class _JxlReaderDemoState extends State<JxlReaderDemo> {
  static const _pageCount = 12;

  late final _prefetcher = JxlPagePrefetcher.fromAssets(
    [for (var i = 0; i < _pageCount; i++) 'assets/manga_page.jxl'],
    aheadCount: 2,
    behindCount: 1,
  );
  late final _controller = PageController();
  var _index = 0;

  @override
  void initState() {
    super.initState();
    _prefetcher.setCurrentIndex(0);
  }

  @override
  void dispose() {
    _controller.dispose();
    _prefetcher.dispose();
    super.dispose();
  }

  void _jumpTo(int index) {
    _controller.jumpToPage(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Reader demo — page ${_index + 1} of $_pageCount'),
        actions: [
          IconButton(
            tooltip: 'Jump to first page',
            icon: const Icon(Icons.first_page),
            onPressed: () => _jumpTo(0),
          ),
          IconButton(
            tooltip: 'Jump to last page',
            icon: const Icon(Icons.last_page),
            onPressed: () => _jumpTo(_pageCount - 1),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: _pageCount,
        onPageChanged: (i) {
          setState(() => _index = i);
          _prefetcher.setCurrentIndex(i);
        },
        itemBuilder: (context, i) =>
            _ReaderPage(prefetcher: _prefetcher, index: i),
      ),
    );
  }
}

class _ReaderPage extends StatefulWidget {
  const _ReaderPage({required this.prefetcher, required this.index});

  final JxlPagePrefetcher prefetcher;
  final int index;

  @override
  State<_ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<_ReaderPage> {
  ui.Image? _image;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.prefetcher != widget.prefetcher) {
      _image?.dispose();
      _image = null;
      _error = null;
      _load();
    }
  }

  void _load() {
    widget.prefetcher.imageFor(widget.index).then(
      (image) {
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() => _error = error);
      },
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Decode failed: $error'),
        ),
      );
    }
    final image = _image;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return InteractiveViewer(
      maxScale: 8,
      child: Center(child: RawImage(image: image, fit: BoxFit.contain)),
    );
  }
}
