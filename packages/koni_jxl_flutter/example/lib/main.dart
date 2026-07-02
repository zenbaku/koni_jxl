import 'package:flutter/material.dart';
import 'package:koni_jxl_flutter/koni_jxl_flutter.dart';

void main() => runApp(const JxlExampleApp());

class JxlExampleApp extends StatelessWidget {
  const JxlExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'koni_jxl demo',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const JxlGalleryPage(),
    );
  }
}

class JxlGalleryPage extends StatefulWidget {
  const JxlGalleryPage({super.key});

  @override
  State<JxlGalleryPage> createState() => _JxlGalleryPageState();
}

class _JxlGalleryPageState extends State<JxlGalleryPage> {
  static const samples = [
    ('Manga page (lossless, 1536×2200)', 'assets/manga_page.jxl'),
    ('Alpha compositing', 'assets/alpha.jxl'),
    ('Palette image', 'assets/palette.jxl'),
  ];

  var _index = 0;

  @override
  Widget build(BuildContext context) {
    final (title, asset) = samples[_index];
    return Scaffold(
      appBar: AppBar(title: Text('koni_jxl — $title')),
      body: Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE8EAF6), Color(0xFFC5CAE9)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: InteractiveViewer(
          maxScale: 8,
          child: Image(
            image: JxlImageProvider.asset(asset),
            fit: BoxFit.contain,
            frameBuilder: (context, child, frame, _) => frame == null
                ? const Center(child: CircularProgressIndicator())
                : child,
            errorBuilder: (context, error, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Decode failed: $error'),
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.menu_book), label: 'Manga'),
          NavigationDestination(icon: Icon(Icons.layers), label: 'Alpha'),
          NavigationDestination(icon: Icon(Icons.palette), label: 'Palette'),
        ],
      ),
    );
  }
}
