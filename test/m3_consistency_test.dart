import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/pages/feedback_options_sheet.dart';
import 'package:yomiru/services/app_theme.dart';
import 'package:yomiru/widgets/common.dart';
import 'package:yomiru/widgets/m3_controls.dart';
import 'package:yomiru/widgets/m3_menu_sheet.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 640), const Size(640, 320)]) {
      testWidgets('shared menus fit $brightness $size at 2x', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        bool? logout;
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.build(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              padding: const EdgeInsets.only(bottom: 24),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
                builder: (context) => Column(children: [
                      TextButton(
                        onPressed: () => showFeedbackOptions(context),
                        child: const Text('feedback'),
                      ),
                      TextButton(
                        onPressed: () async {
                          logout = await showLogoutScopeDialog(context);
                        },
                        child: const Text('logout'),
                      ),
                    ])),
          ),
        ));
        await tester.tap(find.text('feedback'));
        await tester.pumpAndSettle();
        expect(find.byType(M3SheetHeader), findsOneWidget);
        expect(find.byType(M3OptionTile), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('logout'));
        await tester.pumpAndSettle();
        expect(find.byType(M3SheetHeader), findsOneWidget);
        expect(find.byType(M3OptionTile), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(logout, isNull);
        await tester.tap(find.text('logout'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('仅退出本机'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('仅退出本机'));
        await tester.pumpAndSettle();
        expect(logout, isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('shared chips keep selection semantics and touch targets',
      (tester) async {
    var selected = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.dark),
      home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
        return Wrap(children: [
          M3ChoiceChip(
            label: '仅作品',
            icon: Icons.menu_book_outlined,
            selected: selected,
            onSelected: (value) => setState(() => selected = value),
          ),
        ]);
      })),
    ));
    final chip = find.byType(ChoiceChip);
    expect(tester.widget<ChoiceChip>(chip).selected, isFalse);
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(40));
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(selected, isTrue);
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(selected, isFalse);
    expect(tester.takeException(), isNull);
  });
}
