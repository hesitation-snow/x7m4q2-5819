import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/brave_quiz_page.dart';
import 'package:yomiru/pages/custom_tts_settings_page.dart';
import 'package:yomiru/pages/settings_page.dart';
import 'package:yomiru/pages/tts_settings_page.dart';
import 'package:yomiru/reader/reader_language_segments.dart'
    show PlaybackSleepTimer, ReaderLanguageFilter;
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_tts_core.dart';
import 'package:yomiru/services/app_theme.dart';
import 'package:yomiru/services/listening_now.dart';
import 'package:yomiru/services/reader_tts_preferences.dart';
import 'package:yomiru/services/slider_haptics.dart';
import 'package:yomiru/widgets/listening_dock.dart';
import 'package:yomiru/widgets/m3_menu_sheet.dart';
import 'package:yomiru/widgets/reader_listening_sheet.dart';

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

  tearDown(() {
    LKClient.shared.session.clear();
    debugDefaultTargetPlatformOverride = null;
  });

  test('ReaderTtsPreferences persists per account and migrates legacy source',
      () async {
    const saved = ReaderTtsPreferences(
      sourceMode: 'system',
      rate: 1.5,
      systemEngineId: 'com.example.tts',
      systemVoiceId: 'zh-CN-voice',
      systemVoiceByLanguage: {'chinese': 'zh-CN-voice'},
      edgeVoiceByLanguage: {'chinese': 'zh-CN-XiaoxiaoNeural'},
      languageFilter: ReaderLanguageFilter.chineseOnly,
      segmentInterval: Duration(milliseconds: 500),
      sleepTimer: PlaybackSleepTimer.minutes30,
      continuousChapter: true,
    );
    await ReaderTtsPreferences.save(saved, accountKey: 'uid:42');

    final loaded = await ReaderTtsPreferences.load('uid:42');
    expect(loaded.sourceMode, 'system');
    expect(loaded.rate, 1.5);
    expect(loaded.systemEngineId, 'com.example.tts');
    expect(loaded.systemVoiceId, 'zh-CN-voice');
    expect(loaded.systemVoiceByLanguage, {'chinese': 'zh-CN-voice'});
    expect(loaded.edgeVoiceByLanguage, {'chinese': 'zh-CN-XiaoxiaoNeural'});
    expect(loaded.languageFilter, ReaderLanguageFilter.chineseOnly);
    expect(loaded.segmentInterval, const Duration(milliseconds: 500));
    expect(loaded.sleepTimer, PlaybackSleepTimer.minutes30);
    expect(loaded.continuousChapter, isTrue);

    final guest = await ReaderTtsPreferences.load('guest');
    expect(guest.sourceMode, 'online');
    expect(guest.rate, 1.0);

    final migrated = ReaderTtsPreferences.fromJson(const {
      'source': 'gpt_sovits',
      'rate': 1.25,
    });
    expect(migrated.sourceMode, 'online');
    expect(migrated.rate, 1.25);
  });

  test('AppTheme uses gapped capsule slider without dotted tick marks', () {
    for (final theme in [
      AppTheme.build(Brightness.light),
      AppTheme.build(Brightness.dark, pureBlack: true),
    ]) {
      final sliderTheme = theme.sliderTheme;
      expect(sliderTheme.trackShape, isA<GappedSliderTrackShape>());
      expect(sliderTheme.thumbShape, isA<HandleThumbShape>());
      expect(sliderTheme.tickMarkShape, SliderTickMarkShape.noTickMark);
    }
  });

  testWidgets(
      'SettingsPage opens TtsSettingsPage and persists live summary changes',
      (tester) async {
    const ttsChannel = MethodChannel('moe.yutro.yomiru/tts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
      if (call.method == 'setEngine') return true;
      return null;
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      messenger.setMockMethodCallHandler(ttsChannel, null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    try {
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();

      final ttsTile = find.byKey(const ValueKey('settings-tts-tile'));
      await tester.ensureVisible(ttsTile);
      await tester.pumpAndSettle();
      expect(ttsTile, findsOneWidget);
      expect(find.text('听书与 TTS'), findsOneWidget);
      expect(find.text('当前：在线自然音 · 1.00×'), findsOneWidget);

      await tester.tap(ttsTile);
      await tester.pumpAndSettle();
      expect(find.byType(TtsSettingsPage), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);

      // Tap quick speed preset chip 1.5x, then verify modern SliderTheme and ±0.1x step buttons.
      final sliderTheme = SliderTheme.of(tester.element(find.byType(Slider)));
      expect(sliderTheme.trackShape, isA<GappedSliderTrackShape>());
      expect(sliderTheme.thumbShape, isA<HandleThumbShape>());
      expect(sliderTheme.tickMarkShape, SliderTickMarkShape.noTickMark);

      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();
      expect(find.text('1.50×'), findsOneWidget);

      await tester.tap(find.byTooltip('加速'));
      await tester.pumpAndSettle();
      expect(find.text('1.60×'), findsOneWidget);

      await tester.tap(find.byTooltip('减速'));
      await tester.pumpAndSettle();
      expect(find.text('1.50×'), findsOneWidget);

      // Switch voice source to system engine.
      final systemCard = find.byKey(const ValueKey('listening-source-system'));
      await tester.ensureVisible(systemCard);
      await tester.pumpAndSettle();
      await tester.tap(systemCard);
      await tester.pumpAndSettle();
      expect(find.textContaining('测试中文'), findsOneWidget);

      // Change language filter via M3MenuSheet picker.
      final langTile = find.byKey(const ValueKey('tts-playback-language-tile'));
      await tester.ensureVisible(langTile);
      await tester.pumpAndSettle();
      await tester.tap(langTile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅中文'));
      await tester.pumpAndSettle();
      expect(find.text('仅中文'), findsOneWidget);

      // Toggle continuous chapter reading.
      final continuousSwitch =
          find.byKey(const ValueKey('tts-settings-continuous-switch'));
      await tester.drag(
        find.byKey(const ValueKey('tts-settings-list')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(continuousSwitch);
      await tester.pumpAndSettle();
      await tester.tap(continuousSwitch);
      await tester.pumpAndSettle();

      // Navigate back and confirm SettingsPage summary updated automatically.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('当前：系统引擎 · 1.50×'), findsOneWidget);

      final persisted = await ReaderTtsPreferences.load('guest');
      expect(persisted.sourceMode, 'system');
      expect(persisted.rate, 1.5);
      expect(persisted.systemVoiceId, 'zh-CN-test');
      expect(persisted.languageFilter, ReaderLanguageFilter.chineseOnly);
      expect(persisted.continuousChapter, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(ttsChannel, null);
    }
  });

  testWidgets('TtsSettingsPage opens custom SSML settings cleanly',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    try {
      await tester.pumpWidget(const MaterialApp(home: TtsSettingsPage()));
      await tester.pumpAndSettle();

      final customCard = find.byKey(const ValueKey('listening-source-custom'));
      await tester.ensureVisible(customCard);
      await tester.pumpAndSettle();
      await tester.tap(customCard);
      await tester.pumpAndSettle();

      final configTile = find.byKey(const ValueKey('tts-custom-config-tile'));
      await tester.ensureVisible(configTile);
      await tester.pumpAndSettle();
      await tester.tap(configTile);
      await tester.pumpAndSettle();

      expect(find.byType(CustomTtsSettingsPage), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
      'SliderHapticFeedback and ListeningRateControl emit subtle haptics per notch',
      (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final haptics = <String?>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String?);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final helper = SliderHapticFeedback()
      ..sync(1.0, min: 0.5, max: 3.0, divisions: 25);
    helper.onChanged(1.0, min: 0.5, max: 3.0, divisions: 25);
    helper.onChanged(1.02, min: 0.5, max: 3.0, divisions: 25);
    expect(haptics, isEmpty);

    helper.onChanged(1.1, min: 0.5, max: 3.0, divisions: 25);
    helper.onChanged(1.1, min: 0.5, max: 3.0, divisions: 25);
    helper.onChanged(1.2, min: 0.5, max: 3.0, divisions: 25);
    await tester.pump();
    expect(haptics, [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.selectionClick',
    ]);

    haptics.clear();
    var rate = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListeningRateControl(
              rate: rate,
              onChanged: (value) => setState(() => rate = value),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart?.call(1.0);
    slider.onChanged!(1.1);
    await tester.pump();
    expect(haptics, ['HapticFeedbackType.selectionClick']);

    // Staying on the same notch should not trigger duplicate haptics.
    tester.widget<Slider>(find.byType(Slider)).onChanged!(1.1);
    await tester.pump();
    expect(haptics, hasLength(1));

    // Crossing to 1.2x triggers one subtle selection click.
    tester.widget<Slider>(find.byType(Slider)).onChanged!(1.2);
    await tester.pump();
    expect(haptics, hasLength(2));

    // Stepper buttons and preset chips also emit a subtle selection click.
    await tester.tap(find.byTooltip('加速'));
    await tester.pump();
    expect(rate, closeTo(1.3, 0.001));
    expect(haptics, hasLength(3));

    await tester.tap(find.byTooltip('减速'));
    await tester.pump();
    expect(rate, closeTo(1.2, 0.001));
    expect(haptics, hasLength(4));

    await tester.tap(find.text('1.5×'));
    await tester.pump();
    expect(rate, closeTo(1.5, 0.001));
    expect(haptics, hasLength(5));
    expect(
      haptics,
      everyElement('HapticFeedbackType.selectionClick'),
    );
  });

  testWidgets('ListeningMenu displays M3SheetHeader and ListeningPlaybackCard',
      (tester) async {
    late Directory temp;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('yomiru_listening_menu_');
      final cache = SpeechAudioCache(
        temporaryDirectory: () async => temp,
        budgetBytes: 1024 * 1024,
      );
      final session = ReaderSpeechSession(
        handler: _TestSpeechHandler(),
        synthesizer: _TestSpeechSynth(),
        cache: cache,
      );
      const text = '第一段后台听书内容测试';
      await session.start(
        const [
          TtsSegment(
            blockIndex: 0,
            startOffset: 0,
            endOffset: text.length,
            text: text,
          ),
        ],
        accountId: 'guest',
        config: const SpeechSynthesisConfig(
          source: 'system',
          voice: 'v1',
          language: 'zh-CN',
          rate: 1,
        ),
        title: '测试轻小说',
        artist: '第一章',
      );
      ListeningNow.instance.adopt(
        session: session,
        bookTitle: '测试轻小说',
        chapterTitle: '第一章',
        bookId: 1001,
        chapterId: 2001,
        volumeId: 10,
      );
    });

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showListeningMenu(context),
                child: const Text('打开听书菜单'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开听书菜单'));
      await tester.pumpAndSettle();

      expect(find.byType(M3SheetHeader), findsOneWidget);
      expect(find.byType(ListeningPlaybackCard), findsOneWidget);
      expect(find.text('正在听书'), findsOneWidget);
      expect(find.text('测试轻小说 · 第一章'), findsOneWidget);
      expect(find.text('第一段后台听书内容测试'), findsOneWidget);
      expect(find.text('回到阅读'), findsOneWidget);
      expect(find.text('停止'), findsOneWidget);
      expect(find.byTooltip('听书设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.runAsync(() async {
        await ListeningNow.instance.stop();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
    }
  });

  testWidgets('BraveQuizPage logged-out view renders M3 medallion and CTA',
      (tester) async {
    LKClient.shared.session.clear();
    await tester.pumpWidget(const MaterialApp(home: BraveQuizPage()));
    await tester.pumpAndSettle();

    expect(find.text('勇者考试'), findsOneWidget);
    expect(find.text('登录后才能参加勇者考试'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
