import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/indicator_position.dart';
import 'package:yomiru/reader/reader_typography.dart';
import 'package:yomiru/widgets/reader_indicators.dart';
import 'package:yomiru/widgets/reader_typography_sheet.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('typography fits narrow large-text layout: $brightness',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var commits = 0;
      var colorPicks = 0;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: brightness),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: ReaderTypographySheet(
              initialTypography: ReaderTypography.standard(),
              fontSize: 28,
              textColor:
                  brightness == Brightness.dark ? Colors.white : Colors.black,
              backgroundColor:
                  brightness == Brightness.dark ? Colors.black : Colors.white,
              linkColor: Colors.blue,
              isDark: brightness == Brightness.dark,
              onPickTextColor: () => colorPicks++,
              onPreviewChange: (_) {},
              onCommit: (_) => commits++,
            ),
          ),
        ),
      ));
      Future<void> reveal(String label) async {
        for (var i = 0; i < 60; i++) {
          if (find.text(label).hitTestable().evaluate().isNotEmpty) return;
          await tester.drag(find.byType(ListView), const Offset(0, -160));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        fail('Control not reachable: $label');
      }

      expect(tester.takeException(), isNull);
      await tester.tap(find.text('文字颜色'));
      expect(colorPicks, 1);
      await reveal('紧凑');
      await tester.tap(find.text('紧凑'));
      await tester.pumpAndSettle();
      expect(commits, 1);
      await reveal('分栏模式');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await reveal('独立四周边距');
      await tester.tap(find.text('独立四周边距'));
      await tester.pumpAndSettle();
      await reveal('恢复默认排版');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('恢复默认排版'));
      expect(commits, 3);
    });
  }

  testWidgets(
      'IndicatorPositionSettings provides full-screen edit mode trigger',
      (tester) async {
    var editModeTriggered = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: IndicatorPositionSettings(
            value: const IndicatorPosition(),
            onChanged: (_) {},
            onEnterEditMode: () => editModeTriggered = true,
          ),
        ),
      ),
    ));
    expect(find.text('调整指示器位置'), findsOneWidget);
    await tester.tap(find.text('调整指示器位置'));
    expect(editModeTriggered, isTrue);
  });
}
