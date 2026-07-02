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
}
