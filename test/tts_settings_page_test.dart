import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/custom_tts_settings_page.dart';
import 'package:yomiru/pages/settings_page.dart';
import 'package:yomiru/pages/tts_settings_page.dart';
import 'package:yomiru/reader/reader_language_segments.dart';
import 'package:yomiru/services/app_theme.dart';
import 'package:yomiru/services/reader_tts_preferences.dart';

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
}
