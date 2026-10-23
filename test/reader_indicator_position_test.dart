import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/reader/indicator_position.dart';
import 'package:yomiru/widgets/reader_indicators.dart';
import 'reader_controls_test.dart' show withReader;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('defaults, persistence, bounded values and reset', () async {
    SharedPreferences.setMockInitialValues({});
    var settings = await ReaderPrefs.loadAll();
    expect(settings.indicatorPosition.top, 6);
    expect(settings.indicatorPosition.bottom, 8);
    expect(settings.indicatorPosition.side, 16);
    expect(settings.indicatorPosition.titleAlignment, 0);
    await ReaderPrefs.saveIndicatorPosition(const IndicatorPosition(
        top: 30, bottom: 40, side: 24, titleAlignment: -1));
    await ReaderPrefs.setShowIndicators(false);
    settings = await ReaderPrefs.loadAll();
    expect(settings.showIndicators, false);
    expect(settings.indicatorPosition.top, 30);
    expect(settings.indicatorPosition.bottom, 40);
    expect(settings.indicatorPosition.side, 24);
    expect(settings.indicatorPosition.titleAlignment, -1);
    await ReaderPrefs.saveIndicatorPosition(
        const IndicatorPosition(top: 10000, bottom: -3, side: double.nan));
    settings = await ReaderPrefs.loadAll();
    expect(settings.indicatorPosition.top, 96);
    expect(settings.indicatorPosition.bottom, 0);
    expect(settings.indicatorPosition.side, 0);
    await ReaderPrefs.saveIndicatorPosition(const IndicatorPosition());
    settings = await ReaderPrefs.loadAll();
    expect(settings.indicatorPosition.top, 6);
    expect(settings.indicatorPosition.bottom, 8);
    expect(settings.showIndicators, false);
  });

  testWidgets('position controls trigger edit mode and display summary',
      (tester) async {
    var value = const IndicatorPosition();
    var editModeCalled = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, setState) => SingleChildScrollView(
                    child: IndicatorPositionSettings(
                        value: value,
                        onEnterEditMode: () => editModeCalled = true,
                        onChanged: (v) => setState(() => value = v)))))));
    expect(find.text('调整指示器位置'), findsOneWidget);
    expect(find.text('顶部 6dp · 底部 8dp · 边距 16dp'), findsOneWidget);
    await tester.tap(find.text('调整指示器位置'));
    expect(editModeCalled, isTrue);
  });

  testWidgets(
      'IndicatorEditOverlay interactive dragging, font size, and micro-tuning',
      (tester) async {
    var value = const IndicatorPosition();
    var saved = false;
    var canceled = false;
    var reset = false;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => IndicatorEditOverlay(
            position: value,
            title: '测试章节 标题',
            progress: const Text('50.0%'),
            deviceStatus: const Text('10:00'),
            onChanged: (v) => setState(() => value = v),
            onSave: () => saved = true,
            onCancel: () => canceled = true,
            onReset: () => reset = true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('测试章节 标题'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);
    expect(find.text('标题 · 可直接拖拽'), findsOneWidget);

    // Test dragging top title
    await tester.drag(find.text('标题 · 可直接拖拽'), const Offset(0, 50));
    await tester.pumpAndSettle();
    expect(value.top, greaterThan(6));
    final draggedTop = value.top;

    // Test +1 dp micro tuning for distance
    await tester.tap(find.text('+1').first);
    await tester.pumpAndSettle();
    expect(value.top, closeTo(draggedTop + 1, 0.1));

    // Test top font size tuning
    expect(value.topFontSize, 11);
    await tester.tap(find.text('+1').last);
    await tester.pumpAndSettle();
    expect(value.topFontSize, 12);
    await tester.tap(find.text('-1').last);
    await tester.pumpAndSettle();
    expect(value.topFontSize, 11);

    // Test actions
    await tester.tap(find.text('保存'));
    expect(saved, isTrue);

    await tester.tap(find.text('取消'));
    expect(canceled, isTrue);

    await tester.tap(find.text('默认'));
    expect(reset, isTrue);
  });

  for (final size in [
    const Size(320, 640),
    const Size(640, 240),
    const Size(180, 320)
  ]) {
    testWidgets('actual safe overlay geometry and large text $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> show(IndicatorPosition position,
              {double scale = 1,
              bool immersive = false,
              String caption = '标题'}) =>
          tester.pumpWidget(MaterialApp(
              home: MediaQuery(
                  data: MediaQueryData(
                      size: size,
                      padding: immersive
                          ? EdgeInsets.zero
                          : const EdgeInsets.fromLTRB(12, 40, 20, 24),
                      viewPadding: const EdgeInsets.fromLTRB(12, 40, 20, 24),
                      textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                      body: Stack(children: [
                    Positioned.fill(
                        child: DefaultTextStyle(
                            style: const TextStyle(fontSize: 11),
                            child: ReaderIndicators(
                                position: position,
                                title: caption,
                                progress: const Text('99.9%',
                                    key: ValueKey('progress')),
                                deviceStatus: const Text('12:34 100%',
                                    key: ValueKey('device'))))),
                  ])))));
      await show(const IndicatorPosition());
      final title = find.byKey(const ValueKey('reader-indicator-title'));
      expect(tester.getTopLeft(title).dy, 46);
      final originalX = tester.getTopLeft(title).dx;
      final originalBottom =
          tester.getBottomRight(find.byKey(const ValueKey('progress'))).dy;
      expect(originalBottom, closeTo(size.height - 24 - 8, .01));
      await show(
          const IndicatorPosition(
              top: 30, bottom: 36, side: 24, titleAlignment: -1),
          immersive: true);
      expect(tester.getTopLeft(title).dy, 70);
      expect(tester.getTopLeft(title).dx, lessThan(originalX));
      expect(tester.getBottomRight(find.byKey(const ValueKey('progress'))).dy,
          closeTo(originalBottom - 28, .01));
      await show(const IndicatorPosition(top: 96, bottom: 96, side: 96),
          scale: 3, caption: '这是用于横屏和大字号验证的超长章节标题，保持在安全区域内');
      expect(tester.takeException(), isNull);
      for (final key in ['reader-indicator-title', 'progress', 'device']) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.left, greaterThanOrEqualTo(12));
        expect(rect.right, lessThanOrEqualTo(size.width - 20));
        expect(rect.top, greaterThanOrEqualTo(40));
        expect(rect.bottom, lessThanOrEqualTo(size.height - 24));
      }
    });
  }

  for (final paged in [false, true]) {
    testWidgets(
        'real reader position, switch, reset preserve body paged=$paged',
        (tester) async {
      await withReader(tester, paged: paged, platform: TargetPlatform.android,
          run: (calls, key) async {
        Future<void> openSettings() async {
          if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
            await tester.tapAt(const Offset(200, 350));
            await tester.pump();
          }
          await tester.tap(find.byTooltip('阅读设置'));
          await tester.pumpAndSettle();
        }

        Future<void> closeSettings() async {
          Navigator.of(tester.element(find.byType(IndicatorPositionSettings)))
              .pop();
          await tester.pumpAndSettle();
          if (find.byType(ReaderIndicators).evaluate().isEmpty) {
            await tester.tapAt(const Offset(200, 350));
            await tester.pump();
          }
        }

        final pageController = paged
            ? tester.widget<PageView>(find.byType(PageView)).controller
            : null;
        final scrollController = paged
            ? null
            : tester
                .widget<CustomScrollView>(find.byType(CustomScrollView).first)
                .controller;
        double bodyOffset() => pageController?.page ?? scrollController!.offset;
        await key('next');
        await tester.pump();
        final originalOffset = bodyOffset();
        expect(originalOffset, greaterThan(0));
        await openSettings();
        final control = tester.widget<IndicatorPositionSettings>(
            find.byType(IndicatorPositionSettings));
        control.onChanged(const IndicatorPosition(top: 42, bottom: 35));
        await tester.pump();
        await closeSettings();
        expect(
            tester
                .widget<ReaderIndicators>(find.byType(ReaderIndicators))
                .position
                .top,
            42);
        final titleY = tester
            .getTopLeft(find.byKey(const ValueKey('reader-indicator-title')))
            .dy;
        expect(titleY, 42);
        expect(bodyOffset(), closeTo(originalOffset, .01));
        expect((await ReaderPrefs.loadAll()).indicatorPosition.bottom, 35);
        await openSettings();
        final toggle = find.widgetWithText(SwitchListTile, '正文指示器');
        tester.widget<SwitchListTile>(toggle).onChanged!(false);
        await tester.pump();
        await closeSettings();
        expect(find.byType(ReaderIndicators), findsNothing);
        expect((await ReaderPrefs.loadAll()).indicatorPosition.top, 42);
        await openSettings();
        tester
            .widget<IndicatorPositionSettings>(
                find.byType(IndicatorPositionSettings))
            .onChanged(const IndicatorPosition());
        await tester.pump();
        await closeSettings();
        expect((await ReaderPrefs.loadAll()).indicatorPosition.top, 6);
        expect(find.byType(ReaderIndicators), findsNothing);
      });
    });
  }
}
