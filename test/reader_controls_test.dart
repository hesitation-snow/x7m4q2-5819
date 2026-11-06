import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:yomiru/reader/reader_indent.dart';
import 'package:yomiru/services/app_motion.dart';
import 'package:yomiru/services/reader_volume_keys.dart';
import 'package:yomiru/widgets/reader_typography_sheet.dart';
import 'package:yomiru/widgets/m3_controls.dart';
import 'package:yomiru/widgets/m3_menu_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('system TTS panel speaks rendered reader segments',
      (tester) async {
    const ttsChannel = MethodChannel('moe.yutro.yomiru/tts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final ttsCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ttsChannel, (call) async {
      ttsCalls.add(call);
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
        return {
          'accepted': true,
          'utteranceId': (call.arguments as Map)['utteranceId']
        };
      }
      return null;
    });
    try {
      await withReader(
        tester,
        paged: false,
        platform: TargetPlatform.android,
        run: (calls, key) async {
          await tester.tap(find.byTooltip('系统朗读'));
          await tester.pumpAndSettle();
          expect(find.text('听书与音色'), findsOneWidget);
          expect(find.text('系统未提供可用语音，请检查设备语音设置'), findsNothing);
          await tester.ensureVisible(find.byTooltip('从当前位置朗读'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('从当前位置朗读'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(
              ttsCalls.map((call) => call.method),
              containsAllInOrder([
                'getVoices',
                'setLanguage',
                'setVoice',
                'setSpeechRate',
                'speak'
              ]));
          expect(find.textContaining('正在朗读'), findsOneWidget);
          expect(
              tester
                  .widget<IconButton>(find.byWidgetPredicate(
                      (w) => w is IconButton && w.tooltip == '上一段'))
                  .onPressed,
              isNull);
          expect(
              tester
                  .widget<IconButton>(find.byWidgetPredicate(
                      (w) => w is IconButton && w.tooltip == '下一段'))
                  .onPressed,
              isNotNull);
          await tester.ensureVisible(find.byTooltip('下一段'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('下一段'));
          await tester.pump();
          expect(
              tester
                  .widget<IconButton>(find.byWidgetPredicate(
                      (w) => w is IconButton && w.tooltip == '上一段'))
                  .onPressed,
              isNotNull);
          await tester.ensureVisible(find.byTooltip('暂停朗读'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('暂停朗读'));
          await tester.pump();
          expect(find.byTooltip('恢复朗读'), findsOneWidget);
          expect(find.textContaining('暂停后从当前语段开头恢复'), findsOneWidget);
          final slider = find.descendant(
              of: find.byType(BottomSheet), matching: find.byType(Slider));
          tester.widget<Slider>(slider).onChanged!(1.5);
          await tester.pump();
          expect(find.text('语速 1.50×'), findsOneWidget);
        },
      );
    } finally {
      messenger.setMockMethodCallHandler(ttsChannel, null);
    }
  });

  testWidgets('TTS voice retry updates the open scrollable sheet',
      (tester) async {
    const channel = MethodChannel('moe.yutro.yomiru/tts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getEngines') {
        return [
          {'name': 'test.engine', 'label': '测试引擎', 'isSystem': true}
        ];
      }
      if (call.method == 'getVoices') {
        if (attempts++ == 0) throw PlatformException(code: 'INIT_FAILED');
        return [
          {'id': 'one', 'name': '语音一', 'locale': 'zh-CN'},
          {'id': 'two', 'name': '语音二', 'locale': 'zh-CN'},
        ];
      }
      return null;
    });
    try {
      await withReader(tester, paged: false, platform: TargetPlatform.android,
          run: (calls, key) async {
        await tester.tap(find.byTooltip('系统朗读'));
        await tester.pumpAndSettle();
        expect(find.text('系统语音引擎初始化失败'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('重新检测语音'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('重新检测语音'));
        await tester.pumpAndSettle();
        expect(find.text('系统语音引擎初始化失败'), findsNothing);
        expect(find.textContaining('语音一'), findsOneWidget);
        expect(
            find.descendant(
                of: find.byType(BottomSheet),
                matching: find.byType(SingleChildScrollView)),
            findsWidgets);
        await tester.tap(find.byWidgetPredicate((widget) =>
            widget is DropdownButtonFormField<String> &&
            widget.initialValue == 'one'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('语音二').last);
        await tester.pumpAndSettle();
        expect(find.textContaining('语音二'), findsOneWidget);
      });
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  for (final size in [const Size(320, 600), const Size(800, 390)]) {
    testWidgets('TTS panel remains usable at $size and large text',
        (tester) async {
      const channel = MethodChannel('moe.yutro.yomiru/tts');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
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
        return null;
      });
      try {
        await withReader(tester, paged: false, platform: TargetPlatform.android,
            run: (calls, key) async {
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = 1.7;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason: 'reader before TTS sheet');
          final entry = find.byTooltip('系统朗读');
          if (entry.hitTestable().evaluate().isEmpty) {
            await tester.tapAt(Offset(size.width / 2, size.height / 2));
            await tester.pumpAndSettle();
          }
          await tester.tap(entry);
          await tester.pumpAndSettle();
          expect(find.text('听书与音色'), findsOneWidget);
          await tester.ensureVisible(find.byTooltip('从当前位置朗读'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('从当前位置朗读').hitTestable(), findsOneWidget);
          final layoutError = tester.takeException();
          if (layoutError is FlutterError) {
            debugPrint(layoutError.toStringDeep());
          }
          expect(layoutError, isNull);
        });
      } finally {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  }

  for (final paged in [false, true]) {
    for (final enhanced in [false, true]) {
      testWidgets(
          'real reader indent and justify: paged=$paged enhanced=$enhanced',
          (tester) async {
        final previous = LKStore.enhancedContentStyleEnabled.value;
        LKStore.enhancedContentStyleEnabled.value = enhanced;
        try {
          await withReader(tester,
              paged: paged,
              platform: TargetPlatform.android,
              indentAndJustify: true, run: (calls, key) async {
            final paragraph = find.byWidgetPredicate((widget) =>
                widget is RichText &&
                widget.text.toPlainText().startsWith('\u3000\u3000第0段'));
            expect(paragraph, findsOneWidget);
            final render = tester.renderObject<RenderParagraph>(paragraph);
            final indents = <ReaderIndentSpan>[];
            render.text.visitChildren((span) {
              if (span is ReaderIndentSpan) indents.add(span);
              return true;
            });
            expect(indents, hasLength(2));
            final first = render
                .getBoxesForSelection(
                    const TextSelection(baseOffset: 2, extentOffset: 3))
                .first;
            expect(first.left, closeTo(indents.first.em * 2, 1));
            await key('next');
            await tester.pump();
            await key('previous');
            await tester.pump();
            expect(tester.takeException(), isNull);
          });
        } finally {
          LKStore.enhancedContentStyleEnabled.value = previous;
        }
      });
    }
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

  testWidgets(
      'Reader settings sheet has tabs: 外观 / 排版 / 操作 with correct contents',
      (tester) async {
    await withReader(tester, paged: true, platform: TargetPlatform.android,
        run: (calls, key) async {
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();

      expect(find.byType(M3SheetHeader), findsOneWidget);
      final header = tester.widget<M3SheetHeader>(find.byType(M3SheetHeader));
      expect(header.title, '阅读设置');
      expect(
          find.ancestor(
              of: find.byType(TabBarView),
              matching: find.byType(SingleChildScrollView)),
          findsNothing);
      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      final scheme =
          Theme.of(tester.element(find.byType(M3SheetHeader))).colorScheme;
      expect(sheet.backgroundColor, scheme.surfaceContainer);
      expect((sheet.shape as RoundedRectangleBorder).borderRadius,
          const BorderRadius.vertical(top: Radius.circular(28)));

      // Verify TabBar has 外观, 排版, 操作, and NO 边距
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('排版'), findsOneWidget);
      expect(find.text('操作'), findsOneWidget);
      expect(find.text('边距'), findsNothing);

      // Tab 0 (外观) does NOT contain 字号 slider or 行距 slider
      expect(find.text('字号'), findsNothing);
      expect(find.text('行距'), findsNothing);

      // Switch to Tab 1 (排版)
      await tester.tap(find.text('排版'));
      await tester.pumpAndSettle();
      expect(find.text('排版预览'), findsOneWidget);
      expect(find.text('字号大小'), findsOneWidget);
      expect(find.text('行间距'), findsOneWidget);
      expect(find.text('段落间距'), findsOneWidget);
      expect(find.text('字符间距'), findsOneWidget);
      expect(find.text('页边留白'), findsOneWidget);
      final typographySheet = tester
          .widget<ReaderTypographySheet>(find.byType(ReaderTypographySheet));
      expect(typographySheet.paged, isTrue);
      expect(
          tester
              .widget<M3ChoiceChip>(find.widgetWithText(M3ChoiceChip, '双栏'))
              .onSelected,
          isNotNull);
      expect(find.text('两端对齐'), findsOneWidget);
      expect(find.text('分栏模式'), findsOneWidget);

      // Switch to Tab 2 (操作)
      await tester.tap(find.text('操作'));
      await tester.pumpAndSettle();
      expect(find.textContaining('点击翻页'), findsOneWidget);
      expect(find.textContaining('翻页模式'), findsOneWidget);

      Navigator.of(tester.element(find.text('操作'))).pop();
      await tester.pumpAndSettle();
    });
  });

  testWidgets(
      'Reader typography sheet switches between single and double column mode dynamically',
      (tester) async {
    await withReader(tester, paged: true, platform: TargetPlatform.android,
        run: (calls, key) async {
      // By default in phone width (400), it's single column: no column gap SizedBox(width: 32)
      final colGapFinder =
          find.byWidgetPredicate((w) => w is SizedBox && w.width == 32);
      expect(colGapFinder, findsNothing);

      // Open settings and switch to double column
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排版'));
      await tester.pumpAndSettle();

      await tester.drag(
          find.byType(ReaderTypographySheet), const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('双栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('双栏'));
      await tester.pumpAndSettle();

      // Dismiss modal
      Navigator.of(tester.element(find.text('排版'))).pop();
      await tester.pumpAndSettle();

      // In double column mode, colGapFinder is now found
      expect(colGapFinder, findsWidgets);

      // Switch back to single column
      if (!find.byTooltip('阅读设置').hitTestable().evaluate().isNotEmpty) {
        await tester.tapAt(const Offset(200, 350));
        await tester.pump();
      }
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排版'));
      await tester.pumpAndSettle();

      await tester.drag(
          find.byType(ReaderTypographySheet), const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('单栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单栏'));
      await tester.pumpAndSettle();

      Navigator.of(tester.element(find.text('排版'))).pop();
      await tester.pumpAndSettle();

      expect(colGapFinder, findsNothing);
    });
  });
}

Future<void> withReader(WidgetTester tester,
    {required bool paged,
    required TargetPlatform platform,
    bool indentAndJustify = false,
    bool pushReader = false,
    Future<void> Function(Directory)? prepareLocal,
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
  SharedPreferences.setMockInitialValues({
    'r_paged': paged,
    'r_vol_turn': true,
    'r_indent': indentAndJustify ? 2.0 : 0.0,
    'r_justify': indentAndJustify
  });
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
    if (prepareLocal != null) await tester.runAsync(() => prepareLocal(root!));
    const reader = ReaderPage(
      bookId: 1338,
      bookTitle: 'fixture',
      chapterId: 317815,
      chapterTitle: 'Controls fixture',
      volumeId: 1,
    );
    await tester.pumpWidget(MaterialApp(
        navigatorObservers: [readerRouteObserver],
        theme: ThemeData(pageTransitionsTheme: AppMotion.noPageTransitions),
        home: pushReader
            ? Scaffold(
                body: Builder(
                    builder: (context) => TextButton(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => reader)),
                          child: const Text('打开测试阅读器'),
                        )))
            : reader));
    if (pushReader) {
      await tester.tap(find.text('打开测试阅读器'));
      await tester.pump();
    }
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
    await tester.runAsync(() async {
      // Windows may retain an async cache file handle for one completion turn.
      // Only retry a sharing violation; never suppress genuine teardown errors.
      for (var attempt = 0;; attempt++) {
        try {
          if (await root!.exists()) await root.delete(recursive: true);
          break;
        } on FileSystemException catch (error) {
          if (error.osError?.errorCode != 32 || attempt >= 5) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    });
  }
}
