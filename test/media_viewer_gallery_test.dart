import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/pages/media_viewer_page.dart';

void main() {
  testWidgets('single image remains compatible and double tap toggles zoom',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: MediaViewerPage(url: 'https://example.invalid/one.png')));
    expect(find.text('1 / 1'), findsOneWidget);
    final detector = tester.widget<GestureDetector>(find.byWidgetPredicate(
        (w) => w is GestureDetector && w.onDoubleTap != null));
    detector.onDoubleTapDown!(
        TapDownDetails(localPosition: const Offset(100, 100)));
    detector.onDoubleTap!();
    await tester.pump();
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 2.5);
    expect(tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>());
    detector.onDoubleTap!();
    await tester.pump();
    expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'chapter gallery starts at selected illustration and updates count',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: MediaViewerPage(url: 'https://example.invalid/2.png', urls: [
      'https://example.invalid/1.png',
      'https://example.invalid/2.png',
      'https://example.invalid/3.png',
    ])));
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('3 / 3'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
