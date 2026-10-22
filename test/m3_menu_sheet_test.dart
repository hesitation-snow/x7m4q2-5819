import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/settings_page.dart';
import 'package:yomiru/widgets/common.dart';
import 'package:yomiru/widgets/m3_menu_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.themeMode.value = ThemeMode.system;
    LKStore.coverBlurMode.value = CoverBlurMode.brave;
    LKStore.gridColumnCount.value = 0;
  });

  Future<void> host(
      WidgetTester tester, Brightness brightness, Widget home) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo, brightness: brightness)),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              padding: const EdgeInsets.only(bottom: 24)),
          child: child!),
      home: home,
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('outside back and drag dismiss without selecting',
      (tester) async {
    var selections = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => M3MenuSheet(
                                title: '菜单',
                                icon: Icons.menu,
                                children: [
                                  ListTile(
                                      title: const Text('选择'),
                                      onTap: () => selections++)
                                ])),
                    child: const Text('open'))))));
    for (final method in ['outside', 'back', 'drag']) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      if (method == 'outside') {
        await tester.tapAt(const Offset(10, 10));
      } else if (method == 'back') {
        await tester.binding.handlePopRoute();
      } else {
        final top = tester.getTopLeft(find.byType(M3MenuSheet));
        await tester.flingFrom(
            top + const Offset(100, 18), const Offset(0, 400), 1200);
      }
      await tester.pumpAndSettle();
      expect(find.byType(M3MenuSheet), findsNothing);
      expect(selections, 0);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'grid closes without writing and scrolls to last option $brightness',
        (tester) async {
      await host(
          tester,
          brightness,
          Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => showGridColumnsSheet(context),
                      child: const Text('open')))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(LKStore.gridColumnCount.value, 0);
      expect(
          (await SharedPreferences.getInstance())
              .containsKey('grid_column_count'),
          isFalse);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('5 列'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 列'));
      await tester.pumpAndSettle();
      expect(LKStore.gridColumnCount.value, 5);
      expect(find.byType(M3MenuSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final spec in [('主题模式', '深色模式'), ('封面模糊', '关闭')]) {
      testWidgets('${spec.$1} close and select at 2x $brightness',
          (tester) async {
        await host(tester, brightness, const SettingsPage());
        await tester.scrollUntilVisible(find.text(spec.$1), 120);
        await tester.pumpAndSettle();
        await tester.tap(find.text(spec.$1).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.check_rounded), findsOneWidget);
        for (final element in find
            .descendant(
                of: find.byType(M3MenuSheet), matching: find.byType(InkWell))
            .evaluate()) {
          expect((element.renderObject as RenderBox).size.height,
              greaterThanOrEqualTo(48));
        }
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(LKStore.themeMode.value, ThemeMode.system);
        expect(LKStore.coverBlurMode.value, CoverBlurMode.brave);
        await tester.tap(find.text(spec.$1).first);
        await tester.pumpAndSettle();
        final option = find.descendant(
            of: find.byType(M3MenuSheet), matching: find.text(spec.$2));
        await tester.ensureVisible(option);
        await tester.pumpAndSettle();
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(find.byType(M3MenuSheet), findsNothing);
        if (spec.$1 == '主题模式') {
          expect(LKStore.themeMode.value, ThemeMode.dark);
        } else {
          expect(LKStore.coverBlurMode.value, CoverBlurMode.none);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
