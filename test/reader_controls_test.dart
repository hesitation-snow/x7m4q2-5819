import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/reader_cache.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/reader_page.dart';
import 'package:yomiru/services/app_motion.dart';
import 'package:yomiru/services/reader_volume_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final paged in [false, true]) {
    testWidgets(
        'real ${paged ? 'paged' : 'scroll'} reader volume keys, modal and lifecycle',
        (tester) async {
      await withReader(tester, paged: paged, platform: TargetPlatform.android,
          run: (calls, key) async {
        expect(calls.last['enabled'], isTrue);
        final page = paged
            ? tester.widget<PageView>(find.byType(PageView)).controller!
            : null;
        final scroll = !paged
            ? tester
                .widget<CustomScrollView>(find.byType(CustomScrollView).first)
                .controller!
            : null;
        double offset() => page?.page ?? scroll!.offset;
        final start = offset();
        await key('next');
        await tester.pump();
        expect(offset(), greaterThan(start));
        final after = offset();
        await tester.pump(const Duration(seconds: 1));
        expect(
            offset(), after); // no intermediate animation or later correction
        await key('previous');
        await tester.pump();
        expect(offset(), closeTo(start, 0.01));

        if (!find.byTooltip('阅读设置').hitTestable().evaluate().isNotEmpty) {
          await tester.tapAt(const Offset(200, 350));
          await tester.pump();
        }
        await tester.tap(find.byTooltip('阅读设置'));
        await tester.pumpAndSettle();
        expect(calls.last['enabled'], isFalse);
        await tester.tap(find.text('操作'));
        await tester.pumpAndSettle();
        expect(find.textContaining('音量键翻页'), findsOneWidget);
        final beforeModalKey = offset();
        await key('next');
        await tester.pump();
        expect(offset(), beforeModalKey);
        Navigator.of(tester.element(find.text('操作'))).pop();
        await tester.pumpAndSettle();
        expect(calls.last['enabled'], isTrue);

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        expect(calls.last['enabled'], isFalse);
        await key('next');
        expect(offset(), beforeModalKey);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(calls.last['enabled'], isTrue);
        if (paged) {
          await tester.drag(find.byType(PageView), const Offset(-180, 0));
          await tester.pump();
          expect(page!.page, 1);
          expect(page.position.isScrollingNotifier.value, isFalse);
        }
      });
    });
  }

  testWidgets(
      'iOS reader hides volume option even with a saved Android preference',
      (tester) async {
    await withReader(tester, paged: false, platform: TargetPlatform.iOS,
        run: (calls, key) async {
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      expect(find.textContaining('音量键翻页'), findsNothing);
      expect(calls, isEmpty);
      Navigator.of(tester.element(find.text('操作'))).pop();
      await tester.pumpAndSettle();
    });
  });
}

Future<void> withReader(WidgetTester tester,
    {required bool paged,
    required TargetPlatform platform,
    required Future<void> Function(
            List<Map<dynamic, dynamic>>, Future<void> Function(String))
        run}) async {
  final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('yomiru-reader-controls-'));
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const wakeChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  final calls = <Map<dynamic, dynamic>>[];
  messenger.setMockMethodCallHandler(pathChannel, (_) async => root!.path);
  messenger.setMockMessageHandler(wakeChannel,
      (_) async => const StandardMessageCodec().encodeMessage([null]));
  messenger.setMockMethodCallHandler(ReaderVolumeKeys.channel, (call) async {
    calls.add(call.arguments as Map);
    return null;
  });
  SharedPreferences.setMockInitialValues(
      {'r_paged': paged, 'r_vol_turn': true});
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  LKStore.animationsEnabled.value = false;
  LKClient.shared.session.clear();
  LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
    final data = <String, dynamic>{};
    if (request.url.path.endsWith('/get-chapter-detail')) {
      data.addAll({
        'chapter_id': 317815,
        'volume_id': 1,
        'chapter_no': 1,
        'title': 'Controls fixture',
        'body_snapshot': {
          'body_html': List.generate(
                  60,
                  (i) =>
                      '<p>第$i段：这是一段用于验证音量按键与无动画翻页的测试正文。阅读位置必须保持正确，切换时不得改变文字布局。</p>')
              .join()
        },
      });
    }
    return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
        headers: {'content-type': 'application/json'});
  }));
  try {
    await tester.runAsync(ReaderContentCache.clear);
    await tester.pumpWidget(MaterialApp(
        navigatorObservers: [readerRouteObserver],
        theme: ThemeData(pageTransitionsTheme: AppMotion.noPageTransitions),
        home: const ReaderPage(
            bookId: 1338,
            bookTitle: 'fixture',
            chapterId: 317815,
            chapterTitle: 'Controls fixture',
            volumeId: 1)));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    await run(calls, (direction) async {
      if (calls.isEmpty) return;
      await messenger.handlePlatformMessage(
          ReaderVolumeKeys.channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall('volumeKey',
              {'owner': calls.last['owner'], 'direction': direction})),
          (_) {});
    });
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(ReaderContentCache.clear);
    LKApi.client = LKClient.shared;
    LKStore.animationsEnabled.value = true;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(ReaderVolumeKeys.channel, null);
    messenger.setMockMessageHandler(wakeChannel, null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    debugDefaultTargetPlatformOverride = null;
    await tester.runAsync(() => root!.delete(recursive: true));
  }
}
