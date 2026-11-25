import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/home_page.dart';
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_tts_core.dart';
import 'package:yomiru/services/app_background.dart';
import 'package:yomiru/services/listening_now.dart';
import 'package:yomiru/widgets/liquid_glass_bottom_bar.dart';
import 'package:yomiru/widgets/listening_dock.dart';

class _TestSpeechSynth implements SpeechAudioSynthesizer {
  @override
  Future<File> synthesize(
    String text,
    SpeechSynthesisConfig config,
    String cachePath,
  ) async {
    final file = File(cachePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    return file;
  }
}

class _TestSpeechHandler implements SpeechFilesHandler {
  @override
  Future<void> playFiles(
    List<File> files, {
    required String title,
    String? artist,
    required int startIndex,
    required FutureOr<void> Function(int) onSegmentChanged,
    required FutureOr<void> Function() onCompleted,
  }) async {
    await onSegmentChanged(0);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}
}

Future<({Directory temp, ReaderSpeechSession session})>
    _startListeningSession() async {
  final temp = await Directory.systemTemp.createTemp('yomiru_listening_dock_');
  final cache = SpeechAudioCache(
    temporaryDirectory: () async => temp,
    budgetBytes: 1024 * 1024,
  );
  final session = ReaderSpeechSession(
    handler: _TestSpeechHandler(),
    synthesizer: _TestSpeechSynth(),
    cache: cache,
  );
  const text = '在这种时候还惦记着风纪相关的事，学生会长也太认真了。';
  await session.start(
    const [
      TtsSegment(
        blockIndex: 0,
        startOffset: 0,
        endOffset: text.length,
        text: text,
      ),
      TtsSegment(
        blockIndex: 1,
        startOffset: 0,
        endOffset: 5,
        text: '下一段内容',
      ),
    ],
    accountId: 'guest',
    config: const SpeechSynthesisConfig(
      source: 'edge',
      voice: 'zh-CN-XiaoxiaoNeural',
      language: 'zh-CN',
      rate: 1,
    ),
    title: '败犬女主太多了！',
    artist: '第一章',
  );
  ListeningNow.instance.adopt(
    session: session,
    bookTitle: '败犬女主太多了！',
    chapterTitle: '第一章',
    bookId: 1001,
    chapterId: 2001,
    volumeId: 10,
  );
  // Let opportunistic segment prefetch and cache eviction settle before tests run.
  await Future<void>.delayed(const Duration(milliseconds: 60));
  return (temp: temp, session: session);
}

Future<void> _cleanupListeningSession(WidgetTester tester, Directory temp) async {
  await tester.runAsync(() async {
    await ListeningNow.instance.stop();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (await temp.exists()) {
      try {
        await temp.delete(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Yomiru',
      packageName: 'moe.yutro.yomiru',
      version: '1.6.0',
      buildNumber: '2014',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
  });

  testWidgets(
      'ListeningDock liquidGlass renders LiquidGlassCapsule matching barWidth in light and dark themes',
      (tester) async {
    late Directory temp;
    await tester.runAsync(() async {
      final started = await _startListeningSession();
      temp = started.temp;
    });
    final oldGlass = LKStore.glassConfiguration.value;
    try {
      final optics = GlassConfiguration(
        blur: 12,
        tint: 0.7,
        barWidth: 292,
        barHeight: 60,
        floatingHeight: 18,
      );
      LKStore.glassConfiguration.value = optics;

      for (final brightness in Brightness.values) {
        late double expectedWidth;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: brightness),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(400, 800)),
              child: Scaffold(
                body: Builder(
                  builder: (context) {
                    expectedWidth = liquidGlassBarWidth(context, optics);
                    return Center(
                      child: ListeningDock(
                        liquidGlass: true,
                        glassConfiguration: optics,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(LiquidGlassCapsule), findsOneWidget);
        if (ui.ImageFilter.isShaderFilterSupported) {
          expect(
            find.byKey(const ValueKey('listening-dock-glass-refraction')),
            findsOneWidget,
          );
        } else {
          expect(
            find.byKey(const ValueKey('listening-dock-glass-blur')),
            findsOneWidget,
          );
        }
        final surface =
            find.byKey(const ValueKey('listening-dock-glass-surface'));
        expect(tester.getSize(surface).width, closeTo(expectedWidth, 0.01));
        expect(find.text('败犬女主太多了！'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    } finally {
      LKStore.glassConfiguration.value = oldGlass;
      await _cleanupListeningSession(tester, temp);
    }
  });

  testWidgets(
      'HomePage positions liquid glass ListeningDock cleanly above LiquidGlassBottomBar without double clearance',
      (tester) async {
    late Directory temp;
    late ReaderSpeechSession session;
    await tester.runAsync(() async {
      final started = await _startListeningSession();
      temp = started.temp;
      session = started.session;
    });

    final oldClient = LKApi.client;
    final oldGlassEnabled = LKStore.liquidGlassBottomBarEnabled.value;
    final oldConfig = LKStore.glassConfiguration.value;
    final oldUpdate = LKStore.autoCheckUpdateEnabled.value;

    try {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null,
      );

      LKApi.client = LKClient.forTesting(
        httpClient: MockClient(
          (_) async => http.Response(
            '{"code":0,"data":{"list":[],"has_more":false}}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      LKStore.autoCheckUpdateEnabled.value = false;
      LKStore.liquidGlassBottomBarEnabled.value = true;
      final optics = GlassConfiguration(
        blur: 8,
        tint: 0.7,
        barWidth: 280,
        barHeight: 60,
        floatingHeight: 18,
      );
      LKStore.glassConfiguration.value = optics;
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(412, 915),
              padding: EdgeInsets.only(bottom: 24),
            ),
            child: HomePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final barRect =
          tester.getRect(find.byKey(const ValueKey('liquid-glass-surface')));
      final dockRect = tester
          .getRect(find.byKey(const ValueKey('listening-dock-glass-surface')));

      expect(barRect.top - dockRect.bottom, closeTo(10.0, 0.5));
      expect(dockRect.left, closeTo(barRect.left, 0.5));
      expect(dockRect.right, closeTo(barRect.right, 0.5));

      expect(session.isPaused, isFalse);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(session.isPaused, isTrue);

      await tester.tap(find.byTooltip('继续'));
      await tester.pump();
      for (var i = 0; i < 25 && session.isLoading; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(session.isPaused, isFalse);
      expect(session.isLoading, isFalse);

      await tester.tap(find.byKey(const ValueKey('listening-dock')));
      await tester.pumpAndSettle();
      expect(find.byType(ListeningMenu), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      LKApi.client = oldClient;
      LKStore.liquidGlassBottomBarEnabled.value = oldGlassEnabled;
      LKStore.glassConfiguration.value = oldConfig;
      LKStore.autoCheckUpdateEnabled.value = oldUpdate;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
      await _cleanupListeningSession(tester, temp);
    }
  });

  testWidgets(
      'HomePage in standard M3 mode floats ListeningDock above NavigationBar with full-height feed behind it',
      (tester) async {
    late Directory temp;
    await tester.runAsync(() async {
      final started = await _startListeningSession();
      temp = started.temp;
    });

    final oldClient = LKApi.client;
    final oldGlassEnabled = LKStore.liquidGlassBottomBarEnabled.value;
    final oldConfig = LKStore.glassConfiguration.value;
    final oldUpdate = LKStore.autoCheckUpdateEnabled.value;

    try {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null,
      );

      LKApi.client = LKClient.forTesting(
        httpClient: MockClient(
          (_) async => http.Response(
            '{"code":0,"data":{"list":[],"has_more":false}}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      LKStore.autoCheckUpdateEnabled.value = false;
      LKStore.liquidGlassBottomBarEnabled.value = false;
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(412, 915),
              padding: EdgeInsets.only(bottom: 24),
            ),
            child: HomePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(ListeningDock), findsOneWidget);
      expect(find.byType(LiquidGlassBottomBar), findsNothing);
      expect(find.byType(LiquidGlassCapsule), findsNothing);

      final navBarRect = tester.getRect(find.byType(NavigationBar));
      final dockRect = tester.getRect(find.byType(ListeningDock));
      final indexedStackRect = tester.getRect(
        find
            .descendant(
              of: find.byType(HomePage),
              matching: find.byType(IndexedStack),
            )
            .first,
      );

      expect(indexedStackRect.bottom, closeTo(navBarRect.top, 0.5));
      expect(navBarRect.top - dockRect.bottom, closeTo(8.0, 0.5));
      expect(tester.takeException(), isNull);
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      LKApi.client = oldClient;
      LKStore.liquidGlassBottomBarEnabled.value = oldGlassEnabled;
      LKStore.glassConfiguration.value = oldConfig;
      LKStore.autoCheckUpdateEnabled.value = oldUpdate;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
      await _cleanupListeningSession(tester, temp);
    }
  });

  testWidgets('tapping horizontally outside liquid glass dock passes through',
      (tester) async {
    late Directory temp;
    await tester.runAsync(() async {
      final started = await _startListeningSession();
      temp = started.temp;
    });
    try {
      var backgroundTaps = 0;
      final optics = GlassConfiguration(
        barWidth: 240,
        barHeight: 60,
        floatingHeight: 18,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(400, 600)),
            child: Scaffold(
              body: Stack(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => backgroundTaps++,
                    child: const SizedBox.expand(),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Center(
                        child: ListeningDock(
                          liquidGlass: true,
                          glassConfiguration: optics,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final dockRect = tester
          .getRect(find.byKey(const ValueKey('listening-dock-glass-surface')));
      expect(dockRect.left, greaterThan(40));
      await tester.tapAt(Offset(dockRect.left - 24, dockRect.center.dy));
      await tester.pump();
      expect(backgroundTaps, 1);
    } finally {
      await _cleanupListeningSession(tester, temp);
    }
  });

  testWidgets(
      'ListeningDock renders cleanly in standard M3 mode, narrow viewport, and large text scale',
      (tester) async {
    late Directory temp;
    await tester.runAsync(() async {
      final started = await _startListeningSession();
      temp = started.temp;
    });
    try {
      final optics = GlassConfiguration(
        barWidth: 320,
        barHeight: 60,
        floatingHeight: 18,
      );

      final scenarios = <({bool liquidGlass, Size size, double textScale})>[
        (liquidGlass: false, size: const Size(400, 600), textScale: 1.0),
        (liquidGlass: true, size: const Size(220, 600), textScale: 1.0),
        (liquidGlass: true, size: const Size(400, 600), textScale: 2.0),
      ];

      for (final s in scenarios) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: MediaQuery(
              data: MediaQueryData(
                size: s.size,
                textScaler: TextScaler.linear(s.textScale),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: ListeningDock(
                    liquidGlass: s.liquidGlass,
                    glassConfiguration: optics,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('listening-dock')), findsOneWidget);
        if (s.liquidGlass) {
          final width = tester
              .getSize(
                  find.byKey(const ValueKey('listening-dock-glass-surface')))
              .width;
          expect(width, lessThanOrEqualTo(s.size.width - 32 + 0.01));
        } else {
          expect(find.byType(LiquidGlassCapsule), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
    } finally {
      await _cleanupListeningSession(tester, temp);
    }
  });

  testWidgets(
      'HomePage PopScope moves app to background on Android back while listening is active',
      (tester) async {
    late Directory temp;
    late ReaderSpeechSession session;
    await tester.runAsync(() async {
      final started = await _startListeningSession();
      temp = started.temp;
      session = started.session;
    });

    final oldClient = LKApi.client;
    final oldGlassEnabled = LKStore.liquidGlassBottomBarEnabled.value;
    final oldUpdate = LKStore.autoCheckUpdateEnabled.value;
    var backgroundCalls = 0;

    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AppBackground.overrideMoveToBackground = () async {
        backgroundCalls++;
        return true;
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (_) async => null,
      );
      LKApi.client = LKClient.forTesting(
        httpClient: MockClient(
          (_) async => http.Response(
            '{"code":0,"data":{"list":[],"has_more":false}}',
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      LKStore.autoCheckUpdateEnabled.value = false;
      LKStore.liquidGlassBottomBarEnabled.value = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const HomePage(),
        ),
      );
      await tester.pumpAndSettle();

      PopScope<dynamic> homePopScope() => tester.widget<PopScope<dynamic>>(
            find
                .descendant(
                  of: find.byType(HomePage),
                  matching: find.byWidgetPredicate((w) => w is PopScope),
                )
                .first,
          );

      expect(ListeningNow.instance.isPlayingOrLoading, isTrue);
      expect(homePopScope().canPop, isFalse);

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(backgroundCalls, 1);
      expect(find.byType(HomePage), findsOneWidget);

      await session.pause();
      await tester.pump();
      expect(ListeningNow.instance.isPlayingOrLoading, isFalse);
      expect(homePopScope().canPop, isTrue);

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(backgroundCalls, 1);
    } finally {
      AppBackground.overrideMoveToBackground = null;
      debugDefaultTargetPlatformOverride = null;
      LKApi.client = oldClient;
      LKStore.liquidGlassBottomBarEnabled.value = oldGlassEnabled;
      LKStore.autoCheckUpdateEnabled.value = oldUpdate;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
      await _cleanupListeningSession(tester, temp);
    }
  });
}
