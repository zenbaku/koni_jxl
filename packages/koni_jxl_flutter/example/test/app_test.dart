import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koni_jxl_example/main.dart';
import 'package:koni_jxl_flutter/koni_jxl_flutter.dart';

void main() {
  testWidgets('gallery renders the decoded manga page', (tester) async {
    await tester.pumpWidget(const JxlExampleApp());
    expect(find.byType(Image), findsOneWidget);
    // Let the async decode complete and the image frame arrive.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<JxlImageProvider>());
  });

  testWidgets(
      'reader demo prefetch pool: forward swipe, jump ahead, jump back all '
      'render without crashing', (tester) async {
    await tester.pumpWidget(const JxlExampleApp());
    await tester.tap(find.text('Reader'));
    await tester.pump();

    // Let the first page's background isolate decode actually complete
    // (compute()/Isolate.spawn need real async work, not the fake clock).
    Future<void> settle() => tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)));

    await settle();
    await tester.pump();
    expect(find.textContaining('page 1 of 12'), findsOneWidget);

    // Swipe forward: exercises setCurrentIndex advancing the window.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pump();
    await settle();
    await tester.pump();
    expect(find.textContaining('page 2 of 12'), findsOneWidget);

    // Jump to the last page: cancels every page prefetched around page 2.
    await tester.tap(find.byTooltip('Jump to last page'));
    await tester.pump();
    await settle();
    await tester.pump();
    expect(find.textContaining('page 12 of 12'), findsOneWidget);
    expect(find.textContaining('Decode failed'), findsNothing);

    // Jump straight back to the first page: exercises the
    // cancelled-then-revisited retry path for pages near index 0.
    await tester.tap(find.byTooltip('Jump to first page'));
    await tester.pump();
    await settle();
    await tester.pump();
    expect(find.textContaining('page 1 of 12'), findsOneWidget);
    expect(find.textContaining('Decode failed'), findsNothing);
  });
}
