import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/reading_session.dart';
import 'package:yomiru/pages/reader_page.dart';

import 'reader_controls_test.dart' as fixture;

void main() {
  for (final toolbar in [false, true]) {
    testWidgets('exit does not wait for slow reading report: toolbar=$toolbar',
        (tester) async {
      await fixture.withReader(tester,
          paged: false,
          pushReader: true,
          platform: TargetPlatform.android, run: (_, __) async {
        final gate = Completer<void>();
        var requests = 0;
        LKClient.shared.session.securityKey = 'test';
        LKClient.shared.session.uid = 12;
        LKReadingSession.shared.reset();
        LKReadingSession.shared.begin(
            bookId: 1338,
            volumeId: 1,
            chapterId: 317815,
            accountId: 12,
            accountRevision: LKClient.sessionRev.value);
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1100)));
        LKApi.client =
            LKClient.forTesting(httpClient: MockClient((request) async {
          requests++;
          await gate.future;
          return http.Response(jsonEncode({'code': 0, 'data': {}}), 200,
              headers: {'content-type': 'application/json'});
        }));
        try {
          if (toolbar) {
            await tester.tap(find.byTooltip('返回'));
          } else {
            await tester.binding.handlePopRoute();
            await tester.pump();
            await tester.binding.handlePopRoute();
          }
          await tester.pumpAndSettle();
          expect(gate.isCompleted, isFalse);
          expect(requests, 1);
          expect(find.byType(ReaderPage), findsNothing);
          expect(find.text('打开测试阅读器'), findsOneWidget);
        } finally {
          gate.complete();
          await tester.pumpAndSettle();
          LKClient.shared.session.clear();
          LKReadingSession.shared.reset();
        }
      });
    });
  }

  for (final toolbar in [false, true]) {
    testWidgets(
        'system back is guarded, toolbar exits directly: toolbar=$toolbar',
        (tester) async {
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
