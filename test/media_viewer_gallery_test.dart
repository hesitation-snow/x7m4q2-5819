import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/pages/media_viewer_page.dart';

void main() {
  testWidgets('assistive gallery has named image and explicit controls',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(const MaterialApp(
          home: MediaViewerPage(
        url: 'https://example.invalid/1.png',
        urls: [
          'https://example.invalid/1.png',
          'https://example.invalid/2.png',
        ],
      )));
      expect(find.bySemanticsLabel('图片，第 1 张，共 2 张'), findsOneWidget);
      expect(
          tester
              .widget<IconButton>(find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '上一张图片'))
              .onPressed,
          isNull);
      await tester.tap(find.text('放大图片'));
      await tester.pump();
      expect(find.text('恢复原始大小'), findsOneWidget);
      await tester.tap(find.byTooltip('下一张图片'));
      await tester.pump();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('放大图片'), findsOneWidget);
      expect(
          tester
              .widget<IconButton>(find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '下一张图片'))
              .onPressed,
          isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });
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
