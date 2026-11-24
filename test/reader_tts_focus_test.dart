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
import 'package:yomiru/reader/scroll_layout_index.dart';
import 'package:yomiru/services/app_motion.dart';
import 'package:yomiru/services/reader_volume_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ReaderScrollLayoutIndex centers normal and tall segments in viewport',
      () {
    final index = ReaderScrollLayoutIndex(
      itemExtents: const [100, 100, 80, 900],
      leadingPadding: 40,
    );

    // Block 2 starts at 40 + 100 + 100 = 240.
    // Segment [10, 50] has center at 240 + 30 = 270.
    // For viewport 800, centered scroll offset is 270 - 400 = -130.
    expect(
      index.centeredScrollOffsetForRange(
        rawIndex: 2,
        segmentTop: 10,
        segmentBottom: 50,
        viewportHeight: 800,
      ),
      closeTo(-130, 0.01),
    );

    // For viewport 300, centered scroll offset is 270 - 150 = 120.
    expect(
      index.centeredScrollOffsetForRange(
        rawIndex: 2,
        segmentTop: 10,
        segmentBottom: 50,
        viewportHeight: 300,
      ),
      closeTo(120, 0.01),
    );

    // Block 3 starts at 320 and has a very tall segment [0, 800] in 600px viewport.
    // Span is capped at 60% of 600 = 360, so effective center is 320 + 180 = 500,
    // scroll offset is 500 - 300 = 200 (leading lines stay visible, never pushed above top).
    expect(
      index.centeredScrollOffsetForRange(
        rawIndex: 3,
        segmentTop: 0,
        segmentBottom: 800,
        viewportHeight: 600,
      ),
      closeTo(200, 0.01),
    );
  });

  testWidgets(
      'starting TTS, advancing segment, and double-tapping another line center the spoken line',
      (tester) async {
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const wakeChannel =
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    const ttsChannel = MethodChannel('moe.yutro.yomiru/tts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final spokenTexts = <String>[];

    Directory? root;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('yomiru_tts_focus_');
    });

    messenger.setMockMethodCallHandler(pathChannel, (_) async => root!.path);
    messenger.setMockMessageHandler(wakeChannel,
        (_) async => const StandardMessageCodec().encodeMessage([null]));
    messenger.setMockMethodCallHandler(ReaderVolumeKeys.channel, (_) async => null);
    messenger.setMockMethodCallHandler(ttsChannel, (call) async {
      if (call.method == 'getEngines') {
        return [
          {'name': 'test.engine', 'label': '测试引擎', 'isSystem': true}
        ];
      }
      if (call.method == 'getVoices') {
        return [
          {'id': 'zh-CN-test', 'name': '测试中文', 'locale': 'zh-CN'}
        ];
      }
      if (call.method == 'setLanguage') return {'available': true};
      if (call.method == 'setVoice' || call.method == 'setSpeechRate') {
        return true;
      }
      if (call.method == 'speak') {
        final args = call.arguments as Map;
        spokenTexts.add(args['text'] as String);
        return {'accepted': true, 'utteranceId': args['utteranceId']};
      }
      return null;
    });

    SharedPreferences.setMockInitialValues({
      'r_paged': false,
      'r_vol_turn': false,
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    LKStore.animationsEnabled.value = false;
    LKClient.shared.session.clear();
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final data = <String, dynamic>{};
      if (request.url.path.endsWith('/get-chapter-detail')) {
        data.addAll({
          'chapter_id': 317999,
          'volume_id': 1,
          'chapter_no': 1,
          'title': 'TTS focus fixture',
          'body_snapshot': {
            'body_html': List.generate(
              60,
              (i) =>
                  '<p>段落编号$i：这是一段用于验证听书垂直居中聚焦的测试正文内容。</p>',
            ).join(),
          },
        });
      }
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json'});
    }));

    try {
      await tester.runAsync(ReaderContentCache.clear);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [readerRouteObserver],
          theme: ThemeData(pageTransitionsTheme: AppMotion.noPageTransitions),
          home: const ReaderPage(
            bookId: 1338,
            bookTitle: 'fixture',
            chapterId: 317999,
            chapterTitle: 'TTS focus fixture',
            volumeId: 1,
            initialTtsSource: 'system',
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
      }

      // Scroll down to mid-chapter so paragraph 20 is near the top of the viewport.
      final scrollable = find.byType(Scrollable).first;
      final scrollState = tester.state<ScrollableState>(scrollable);
      final viewportRect = tester.getRect(find.byType(CustomScrollView).first);
      final viewportCenterY = viewportRect.center.dy;

      scrollState.position.jumpTo(1400);
      await tester.pumpAndSettle();

      // Reveal reader chrome after scrolling, then open listening sheet.
      await tester.tapAt(viewportRect.center);
      await tester.pumpAndSettle();

      // Open listening sheet and start TTS from current reading position.
      await tester.tap(find.byTooltip('系统朗读'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('listening-source-system')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('listening-source-system')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('从当前位置朗读'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('从当前位置朗读'));
      await tester.pumpAndSettle();

      expect(spokenTexts, isNotEmpty);
      final firstSpokenText = spokenTexts.last;
      final firstMatch = RegExp(r'段落编号(\d+)：').firstMatch(firstSpokenText);
      expect(firstMatch, isNotNull);
      final firstBlockIndex = int.parse(firstMatch!.group(1)!);
      expect(firstBlockIndex, greaterThan(5));

      Finder readerBlockFinder(int index) => find.descendant(
            of: find.byType(CustomScrollView).first,
            matching:
                find.textContaining('段落编号$index：', findRichText: true),
          );

      final firstBlockFinder = readerBlockFinder(firstBlockIndex);
      expect(firstBlockFinder, findsOneWidget);
      final firstCenterY = tester.getCenter(firstBlockFinder).dy;
      expect(
        (firstCenterY - viewportCenterY).abs(),
        lessThan(35),
        reason:
            'Active TTS line (block=$firstBlockIndex, scroll=${scrollState.position.pixels}) should be vertically centered ($viewportCenterY), got $firstCenterY',
      );

      // Advance to the next segment and confirm it is centered too.
      await tester.ensureVisible(find.byTooltip('下一段'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一段'));
      await tester.pumpAndSettle();

      final secondBlockIndex = firstBlockIndex + 1;
      final secondBlockFinder = readerBlockFinder(secondBlockIndex);
      expect(secondBlockFinder, findsOneWidget);
      final secondCenterY = tester.getCenter(secondBlockFinder).dy;
      expect(
        (secondCenterY - viewportCenterY).abs(),
        lessThan(35),
        reason:
            'Next TTS line should stay vertically centered ($viewportCenterY), got $secondCenterY',
      );

      // Close the listening sheet so we can double-tap a different line below center.
      await tester.tap(find.byTooltip('关闭朗读'));
      await tester.pumpAndSettle();

      final tappedBlockIndex = secondBlockIndex + 3;
      final tappedBlockFinder = readerBlockFinder(tappedBlockIndex);
      expect(tappedBlockFinder, findsOneWidget);
      final beforeTapCenterY = tester.getCenter(tappedBlockFinder).dy;
      expect(
        beforeTapCenterY,
        greaterThan(viewportCenterY + 80),
        reason: 'Target line should initially sit well below viewport center',
      );

      // Double-tap that paragraph to jump TTS there.
      final tapPoint = tester.getCenter(tappedBlockFinder);
      await tester.tapAt(tapPoint);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(tapPoint);
      await tester.pumpAndSettle();

      expect(spokenTexts.last, contains('段落编号$tappedBlockIndex：'));
      final afterTapCenterY = tester.getCenter(tappedBlockFinder).dy;
      expect(
        (afterTapCenterY - viewportCenterY).abs(),
        lessThan(35),
        reason:
            'Double-tapped TTS line should scroll to viewport center ($viewportCenterY), got $afterTapCenterY',
      );
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
      messenger.setMockMethodCallHandler(ttsChannel, null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      debugDefaultTargetPlatformOverride = null;
      await tester.runAsync(() async {
        for (var attempt = 0;; attempt++) {
          try {
            if (await root!.exists()) await root!.delete(recursive: true);
            break;
          } on FileSystemException catch (error) {
            if (error.osError?.errorCode != 32 || attempt >= 5) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        }
      });
    }
  });
}
