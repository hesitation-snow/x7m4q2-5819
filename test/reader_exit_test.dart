import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/pages/reader_page.dart';

import 'reader_controls_test.dart' as fixture;

void main() {
  for (final toolbar in [false, true]) {
    testWidgets('system back is guarded, toolbar exits directly: toolbar=$toolbar', (tester) async {
      await fixture.withReader(tester,
          paged: false,
          pushReader: true,
          platform: toolbar ? TargetPlatform.iOS : TargetPlatform.android,
          run: (_, __) async {
        Future<void> back() async {
          if (toolbar) {
            await tester.tap(find.byTooltip('返回'));
          } else {
            await tester.binding.handlePopRoute();
          }
          await tester.pump();
        }

        await back();
        if (!toolbar) {
          expect(find.byType(ReaderPage), findsOneWidget);
          expect(find.text('再按一次返回退出阅读'), findsOneWidget);
          await back();
        }
        await tester.pumpAndSettle();
        expect(find.byType(ReaderPage), findsNothing);
        expect(find.text('打开测试阅读器'), findsOneWidget);
        expect(find.text('再按一次返回退出阅读'), findsNothing);
      });
    });
  }

  testWidgets('expired confirmation requires two fresh back presses',
      (tester) async {
    await fixture.withReader(tester,
        paged: true,
        pushReader: true,
        platform: TargetPlatform.android, run: (_, __) async {
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(seconds: 3));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(ReaderPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsNothing);
    });
  });

  testWidgets('closing settings takes one back and resets pending reader exit',
      (tester) async {
    await fixture.withReader(tester,
        paged: false,
        pushReader: true,
        platform: TargetPlatform.android, run: (_, __) async {
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.text('操作'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('操作'), findsNothing);
      expect(find.byType(ReaderPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(find.text('再按一次返回退出阅读'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsNothing);
    });
  });

  testWidgets('backgrounding clears an armed exit', (tester) async {
    await fixture.withReader(tester,
        paged: false,
        pushReader: true,
        platform: TargetPlatform.android, run: (_, __) async {
      await tester.binding.handlePopRoute();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(ReaderPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsNothing);
    });
  });
}
