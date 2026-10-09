import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/widgets/reader_settings_section.dart';
import 'package:yomiru/api/store.dart';

import 'reader_controls_test.dart' as fixture;

void main() {
  for (final paged in [false, true]) {
    testWidgets('bold affects real reader and persists: paged=$paged',
        (tester) async {
      await fixture.withReader(tester,
          paged: paged, platform: TargetPlatform.android, run: (_, __) async {
        await tester.tap(find.byTooltip('阅读设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('排版'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('加粗'));
        await tester.tap(find.text('加粗'));
        await tester.pumpAndSettle();
        expect((await ReaderPrefs.loadAll()).typography.bold, isTrue);
        await tester.tap(find.byTooltip('关闭阅读设置'));
        await tester.pumpAndSettle();
        final paragraph = find.byWidgetPredicate((widget) =>
            widget is RichText && widget.text.toPlainText().contains('第0段'));
        expect(paragraph, findsWidgets);
        expect(tester.widget<RichText>(paragraph.first).text.style?.fontWeight,
            FontWeight.bold);
      });
    });
  }

  testWidgets('reader settings save themes and fit landscape', (tester) async {
    await fixture.withReader(tester,
        paged: false, platform: TargetPlatform.android, run: (_, __) async {
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.text('主题'), findsOneWidget);
      expect(find.text('配色'), findsOneWidget);
      await tester.tap(find.text('米黄'));
      await tester.pumpAndSettle();
      expect(await ReaderPrefs.bgPreset(), 1);
      expect(await ReaderPrefs.bgFollowSystem(), isFalse);
      await tester.tap(find.byTooltip('关闭阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ReaderThemePicker>(find.byType(ReaderThemePicker))
              .selected,
          1);
      await tester.ensureVisible(find.text('跟随系统'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跟随系统'));
      await tester.pumpAndSettle();
      expect(await ReaderPrefs.bgFollowSystem(), isTrue);
      await tester.tap(find.byTooltip('关闭阅读设置'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      expect(find.text('翻页'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭阅读设置'));
      await tester.pumpAndSettle();
    });
  });

  const presets = [
    (Colors.white, Colors.black, '纯白'),
    (Color(0xFFF7F1E3), Colors.black, '米黄'),
    (Color(0xFF2A2D34), Colors.white, '深灰'),
    (Colors.black, Colors.white, '纯黑'),
  ];
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('theme card fits narrow screen: $brightness scale=$scale',
          (tester) async {
        int? selected = 0;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 280,
                  child: StatefulBuilder(builder: (context, setState) {
                    return ListView(children: [
                      ReaderSettingsSection(title: '主题', children: [
                        const Text('配色'),
                        ReaderThemePicker(
                          presets: presets,
                          selected: selected,
                          onSelected: (value) =>
                              setState(() => selected = value),
                        ),
                        const ListTile(
                            title: Text('文字颜色'), subtitle: Text('#333333')),
                      ]),
                    ]);
                  }),
                ),
              ),
            ),
          ),
        ));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('米黄'));
        await tester.pump();
        expect(selected, 1);
        final selectedCircle = tester.widget<Container>(find.byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).color == presets[1].$1));
        expect(
            ((selectedCircle.decoration as BoxDecoration).border as Border)
                .top
                .width,
            2.5);
        await tester.ensureVisible(find.text('跟随系统'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('跟随系统'));
        await tester.pump();
        expect(selected, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
