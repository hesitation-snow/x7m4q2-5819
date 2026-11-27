import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/tts_settings_page.dart';
import 'package:yomiru/services/reader_tts_preferences.dart';

import 'reader_controls_test.dart' show withReader;

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

  testWidgets(
      'TtsSettingsPage on iOS loads system voices without Android engine picker',
      (tester) async {
    const ttsChannel = MethodChannel('moe.yutro.yomiru/tts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final ttsCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ttsChannel, (call) async {
      ttsCalls.add(call);
      if (call.method == 'getVoices') {
        return [
          {
            'id': 'com.apple.voice.compact.zh-CN.Tingting',
            'voiceId': 'com.apple.voice.compact.zh-CN.Tingting',
            'name': 'Tingting',
            'locale': 'zh-CN',
            'engine': 'com.apple.speech.synthesis',
            'networkRequired': false,
          },
          {
            'id': 'com.apple.voice.compact.ja-JP.Kyoko',
            'voiceId': 'com.apple.voice.compact.ja-JP.Kyoko',
            'name': 'Kyoko',
            'locale': 'ja-JP',
            'engine': 'com.apple.speech.synthesis',
            'networkRequired': false,
          },
        ];
      }
      return null;
    });

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    try {
      await tester.pumpWidget(const MaterialApp(home: TtsSettingsPage()));
      await tester.pumpAndSettle();

      expect(find.text('当前平台仅支持保存偏好'), findsNothing);

      final systemCard = find.byKey(const ValueKey('listening-source-system'));
      await tester.ensureVisible(systemCard);
      await tester.pumpAndSettle();
      await tester.tap(systemCard);
      await tester.pumpAndSettle();

      expect(ttsCalls.where((call) => call.method == 'getEngines'), isEmpty);
      expect(ttsCalls.where((call) => call.method == 'getVoices'), isNotEmpty);
      expect(find.byKey(const ValueKey('tts-system-engine-tile')), findsNothing);
      expect(find.textContaining('Tingting'), findsOneWidget);
      expect(find.text('分语言音色'), findsOneWidget);

      final persisted = await ReaderTtsPreferences.load('guest');
      expect(persisted.sourceMode, 'system');
      expect(
        persisted.systemVoiceId,
        'com.apple.voice.compact.zh-CN.Tingting',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(ttsChannel, null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('TtsSettingsPage on desktop shows unsupported notice and guard',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(430, 1200);
    tester.view.devicePixelRatio = 1;
    try {
      await tester.pumpWidget(const MaterialApp(home: TtsSettingsPage()));
      await tester.pumpAndSettle();

      expect(find.text('当前平台仅支持保存偏好'), findsOneWidget);
      expect(find.text('阅读器朗读播放目前支持 Android 与 iOS 设备。'), findsOneWidget);

      final systemCard = find.byKey(const ValueKey('listening-source-system'));
      await tester.ensureVisible(systemCard);
      await tester.pumpAndSettle();
      await tester.tap(systemCard);
      await tester.pumpAndSettle();

      expect(find.text('系统语音引擎仅在 Android 与 iOS 上可用'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
      'ReaderPage on iOS exposes listening toolbar action, shortcut, and voices',
      (tester) async {
    const ttsChannel = MethodChannel('moe.yutro.yomiru/tts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final ttsCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ttsChannel, (call) async {
      ttsCalls.add(call);
      if (call.method == 'getVoices') {
        return [
          {
            'id': 'com.apple.voice.compact.zh-CN.Tingting',
            'voiceId': 'com.apple.voice.compact.zh-CN.Tingting',
            'name': 'Tingting',
            'locale': 'zh-CN',
            'engine': 'com.apple.speech.synthesis',
            'networkRequired': false,
          },
        ];
      }
      return null;
    });

    try {
      await withReader(
        tester,
        paged: false,
        platform: TargetPlatform.iOS,
        run: (calls, key) async {
          expect(find.byTooltip('系统朗读'), findsOneWidget);

          await tester.tap(find.byTooltip('阅读设置'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('操作'));
          await tester.pumpAndSettle();

          final shortcut = find.text('听书与 TTS 设置');
          expect(shortcut, findsOneWidget);
          await tester.ensureVisible(shortcut);
          await tester.pumpAndSettle();
          await tester.tap(shortcut);
          await tester.pumpAndSettle();

          expect(find.text('听书'), findsOneWidget);

          final systemCard =
              find.byKey(const ValueKey('listening-source-system'));
          await tester.ensureVisible(systemCard);
          await tester.pumpAndSettle();
          await tester.tap(systemCard);
          await tester.pumpAndSettle();

          expect(
            ttsCalls.where((call) => call.method == 'getEngines'),
            isEmpty,
          );
          expect(
            ttsCalls.where((call) => call.method == 'getVoices'),
            isNotEmpty,
          );
          expect(
            find.byKey(const ValueKey('tts-system-engine-tile')),
            findsNothing,
          );
          expect(find.textContaining('Tingting'), findsOneWidget);
        },
      );
    } finally {
      messenger.setMockMethodCallHandler(ttsChannel, null);
    }
  });
}
