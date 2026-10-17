import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/structured_content.dart';
import 'reader_controls_test.dart' show withReader;

void main() {
  testWidgets('footnote exposes a named accessible activation', (tester) async {
    final block = StructuredContentParser.parseHtml(
            '<p>正文<sup class="ln-footnote-ref">[1]</sup>后文</p>')
        .single;
    String? opened;
    const style = TextStyle(fontSize: 20);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StructuredRubyText(
      block: block,
      span: block.buildTextSpan(
          baseStyle: style,
          linkColor: Colors.blue,
          backgroundColor: Colors.white),
      baseStyle: style,
      linkColor: Colors.blue,
      backgroundColor: Colors.white,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      locale: const Locale('zh'),
      textAlign: TextAlign.start,
      onFootnoteTap: (reference) => opened = reference,
    ))));
    final marker = tester.widget<Semantics>(find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == '注释 1'));
    expect(marker.properties.button, isTrue);
    marker.properties.onTap!();
    expect(opened, '1');
  });
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final paged in [false, true]) {
      testWidgets(
          'accessible reader keeps controls reachable: $platform $paged',
          (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
        final semantics = tester.ensureSemantics();
        try {
          await withReader(tester, paged: paged, platform: platform,
              run: (_, __) async {
            expect(find.text('下一屏').hitTestable(), findsOneWidget);
            await tester.tap(find.text('下一屏'));
            await tester.pumpAndSettle();
            expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
            expect(find.text('上一屏').hitTestable(), findsOneWidget);
            expect(
                tester
                    .getSemantics(find.byTooltip('阅读设置'))
                    .getSemanticsData()
                    .tooltip,
                '阅读设置');
            // Tapping the body must not activate invisible page-turn zones when
            // TalkBack/VoiceOver owns touch exploration.
            await tester.tapAt(const Offset(200, 350));
            await tester.pump();
            expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
            tester.platformDispatcher.accessibilityFeaturesTestValue =
                const FakeAccessibilityFeatures();
            await tester.pump();
            expect(find.text('下一屏'), findsNothing);
            expect(tester.takeException(), isNull);
          });
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
