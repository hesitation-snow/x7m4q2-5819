import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/pages/custom_tts_settings_page.dart';
import 'package:yomiru/services/custom_ssml_tts.dart';

class _FakePlayer implements CustomTtsPreviewPlayer {
  bool disposed = false;
  int playCount = 0;
  int stopCount = 0;
  Completer<void>? stopGate;
  Completer<void>? playGate;

  @override
  Future<void> play(Uint8List mp3Bytes) async {
    playCount++;
    await playGate?.future;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    await stopGate?.future;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeTts extends CustomSsmlTts {
  final requests = <Completer<CustomTtsResult>>[];
  final aborts = <Completer<void>?>[];
  final configs = <CustomSsmlTtsConfig>[];
  final credentials = <String?>[];
  final voiceRequests = <Completer<List<AzureSpeechVoice>>>[];
  final voiceCredentials = <String?>[];
  final voiceEndpoints = <String>[];
  int saved = 0;
  int cleared = 0;
  bool deferPreview = false;
  bool saveFails = false;
  Completer<void>? saveGate;

  @override
  Future<CustomTtsResult> synthesize({
    required CustomSsmlTtsConfig config,
    required String text,
    Completer<void>? abortTrigger,
    String? credentialOverride,
    double rate = 1.0,
  }) async {
    configs.add(config);
    aborts.add(abortTrigger);
    credentials.add(credentialOverride);
    if (!deferPreview) {
      return const CustomTtsResult.failure(CustomTtsError(
          CustomTtsErrorCode.http, '试听服务返回 HTTP 401。',
          statusCode: 401));
    }
    final request = Completer<CustomTtsResult>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<List<AzureSpeechVoice>> listAzureVoices({
    required String endpoint,
    String? locale,
    String? credentialOverride,
    Duration timeout = const Duration(seconds: 20),
  }) {
    voiceCredentials.add(credentialOverride);
    voiceEndpoints.add(endpoint);
    final request = Completer<List<AzureSpeechVoice>>();
    voiceRequests.add(request);
    return request.future;
  }

  @override
  Future<void> saveCredential(String credential) async {
    saved++;
    await saveGate?.future;
    if (saveFails) throw StateError('Secure storage write failed.');
  }

  @override
  Future<void> clearCredential() async {
    cleared++;
  }
}

const _initial = CustomSsmlTtsConfig(
  endpoint: 'https://speech.example.test/custom/path?version=1',
  voiceId: 'en-US-Voice',
  displayName: 'Voice',
  locale: 'en-US',
  authMode: CustomTtsAuthMode.bearer,
  audioFormat: 'audio-48khz-192kbitrate-mono-mp3',
  timeout: Duration(seconds: 45),
  voiceByLanguage: {'japanese': 'ja-JP-NanamiNeural', 'other': 'other-voice'},
  localeByLanguage: {'japanese': 'ja-JP'},
);

Finder _key(String id) => find.byKey(ValueKey('custom-tts-$id'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> mount(
    WidgetTester tester, {
    CustomSsmlTtsConfig? initial,
    _FakeTts? tts,
    CustomTtsPreviewPlayerFactory? createPlayer,
    double textScale = 1,
    Map<String, Object> metadata = const {},
  }) async {
    SharedPreferences.setMockInitialValues(metadata);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: CustomTtsSettingsPage(
        tts: tts ?? _FakeTts(),
        preferences: prefs,
        createPlayer: createPlayer ?? _FakePlayer.new,
        initialConfig: initial,
      ),
    ));
    return prefs;
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester, String id, String text) async {
    await tester.ensureVisible(_key(id));
    await tester.enterText(_key(id), text);
    await tester.pump();
  }

  testWidgets('M3 groups default to Azure region with privacy guidance',
      (tester) async {
    await mount(tester);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('音色'), findsOneWidget);
    expect(find.text('认证'), findsOneWidget);
    expect(find.text('试听'), findsNWidgets(2));
    expect(_key('region'), findsOneWidget);
    expect(
        tester.widget<TextField>(_key('region')).controller!.text, 'eastasia');
    expect(find.textContaining('计费提示'), findsOneWidget);
    expect(find.textContaining('正文文本会发送至该 endpoint'), findsOneWidget);
    expect(find.textContaining('无需先保存'), findsOneWidget);
  });

  testWidgets('save marks each missing input and invalid full HTTPS endpoint',
      (tester) async {
    await mount(tester, initial: _initial);
    await enter(tester, 'endpoint', 'http://speech.example.test/tts');
    await enter(tester, 'voice', '');
    await enter(tester, 'name', '');
    await enter(tester, 'locale', '');
    await tap(tester, _key('save'));
    expect(find.textContaining('请输入有效 HTTPS endpoint'), findsOneWidget);
    expect(find.text('请填写音色 ID。'), findsOneWidget);
    expect(find.text('请填写便于识别的显示名称。'), findsOneWidget);
    expect(find.text('请填写语言，例如 zh-CN。'), findsOneWidget);
    expect(find.text('请检查标记的输入项后再保存。'), findsOneWidget);
  });

  testWidgets('region validates names rather than accepting a URL',
      (tester) async {
    final tts = _FakeTts();
    await mount(tester, tts: tts);
    await enter(tester, 'region', 'https://eastasia.example');
    await tap(tester, _key('load-voices'));
    expect(find.text('请输入 Azure 区域名称，例如 eastasia。'), findsOneWidget);
    expect(tts.voiceRequests, isEmpty);
  });

  testWidgets('preview uses draft key without saving and surfaces HTTP error',
      (tester) async {
    final tts = _FakeTts();
    final prefs = await mount(tester, initial: _initial, tts: tts);
    await enter(tester, 'credential', 'draft-preview-key');
    await enter(tester, 'name', ''); // Preview does not require a display name.
    await tap(tester, _key('preview'));
    await tester.pump();
    expect(find.text('试听服务返回 HTTP 401。'), findsOneWidget);
    expect(tts.credentials, ['draft-preview-key']);
    expect(tts.saved, 0);
    expect(prefs.getString('custom_ssml_tts_metadata'), isNull);
    expect(tester.widget<TextField>(_key('credential')).controller!.text,
        'draft-preview-key');
    expect(tts.configs.single.audioFormat, _initial.audioFormat);
    expect(tts.configs.single.endpoint, _initial.endpoint);
  });

  testWidgets('secret toggles visibility and uses done keyboard action',
      (tester) async {
    await mount(tester, initial: _initial);
    await enter(tester, 'credential', 'draft-key');
    expect(tester.widget<TextField>(_key('credential')).obscureText, isTrue);
    expect(tester.widget<TextField>(_key('credential')).textInputAction,
        TextInputAction.done);
    await tap(tester, find.byTooltip('显示密钥'));
    expect(tester.widget<TextField>(_key('credential')).obscureText, isFalse);
    await tap(tester, find.byTooltip('隐藏密钥'));
    expect(tester.widget<TextField>(_key('credential')).obscureText, isTrue);
    expect(tester.widget<TextField>(_key('endpoint')).keyboardType,
        TextInputType.url);
  });

  testWidgets('save preserves existing URL, format, timeout and language data',
      (tester) async {
    final tts = _FakeTts();
    final prefs = await mount(tester, initial: _initial, tts: tts);
    await enter(tester, 'name', 'Updated name');
    await enter(tester, 'credential', 'draft-key');
    await tap(tester, _key('save'));
    await tester.pump();
    final metadata = prefs.getString('custom_ssml_tts_metadata')!;
    final saved =
        CustomSsmlTtsConfig.fromMetadata(decodeCustomTtsMetadata(metadata));
    expect(saved.endpoint, _initial.endpoint);
    expect(saved.audioFormat, _initial.audioFormat);
    expect(saved.timeout, _initial.timeout);
    expect(saved.voiceByLanguage, _initial.voiceByLanguage);
    expect(saved.localeByLanguage, _initial.localeByLanguage);
    expect(saved.displayName, 'Updated name');
    expect(metadata, isNot(contains('draft-key')));
    expect(tts.saved, 1);
    expect(
        tester.widget<TextField>(_key('credential')).controller!.text, isEmpty);
    expect(find.textContaining('设置已保存'), findsOneWidget);
  });

  testWidgets('persisted metadata is loaded and its format survives saving',
      (tester) async {
    final prefs = await mount(tester, metadata: {
      'custom_ssml_tts_metadata': encodeCustomTtsMetadata(_initial),
    });
    await tap(tester, _key('save'));
    await tester.pump();
    expect(
        decodeCustomTtsMetadata(
            prefs.getString('custom_ssml_tts_metadata')!)['audioFormat'],
        _initial.audioFormat);
  });

  testWidgets('saving is busy, blocks double save and retains failed draft',
      (tester) async {
    final tts = _FakeTts()
      ..saveGate = Completer<void>()
      ..saveFails = true;
    final prefs = await mount(tester, initial: _initial, tts: tts);
    await enter(tester, 'credential', 'draft-key');
    await tap(tester, _key('save'));
    expect(find.text('正在保存…'), findsOneWidget);
    expect(tester.widget<FilledButton>(_key('save')).onPressed, isNull);
    expect(tester.widget<TextField>(_key('endpoint')).enabled, isFalse);
    expect(tester.widget<OutlinedButton>(_key('preview')).onPressed, isNull);
    tts.saveGate!.complete();
    await tester.pump();
    expect(find.text('保存失败，请检查设备存储后重试。草稿已保留。'), findsOneWidget);
    expect(tester.widget<TextField>(_key('credential')).controller!.text,
        'draft-key');
    expect(prefs.getString('custom_ssml_tts_metadata'), isNull);
    expect(tts.saved, 1);
    expect(tester.widget<FilledButton>(_key('save')).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Azure catalog uses draft credential and failure persists nothing',
      (tester) async {
    final tts = _FakeTts();
    final prefs = await mount(tester, tts: tts);
    await enter(tester, 'credential', 'catalog-draft-key');
    await tap(tester, _key('load-voices'));
    expect(tts.voiceCredentials, ['catalog-draft-key']);
    expect(tts.voiceEndpoints.single,
        'https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1');
    tts.voiceRequests.single.completeError(const CustomTtsError(
        CustomTtsErrorCode.http, 'Azure voice list returned HTTP 401.',
        statusCode: 401));
    await tester.pump();
    expect(find.textContaining('HTTP 401'), findsOneWidget);
    expect(tts.saved, 0);
    expect(prefs.getString('custom_ssml_tts_metadata'), isNull);
    expect(tester.widget<TextField>(_key('credential')).controller!.text,
        'catalog-draft-key');
  });

  testWidgets('catalog results are discarded after connection draft changes',
      (tester) async {
    final tts = _FakeTts();
    await mount(tester, tts: tts);
    await tap(tester, _key('load-voices'));
    await enter(tester, 'region', 'eastus');
    tts.voiceRequests.single.complete(const [
      AzureSpeechVoice(id: 'stale', name: '旧音色', locale: 'en-US'),
    ]);
    await tester.pump();
    expect(find.text('选择 Azure 音色'), findsNothing);
    expect(find.text('已获取 1 个音色。'), findsNothing);
  });

  testWidgets('Azure catalog success populates voice, name and locale',
      (tester) async {
    final tts = _FakeTts();
    await mount(tester, tts: tts);
    await tap(tester, _key('load-voices'));
    tts.voiceRequests.single.complete(const [
      AzureSpeechVoice(id: 'ja-JP-NanamiNeural', name: '七海', locale: 'ja-JP'),
    ]);
    await tester.pump();
    await tap(tester, find.text('选择 Azure 音色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('七海 · ja-JP').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_key('voice')).controller!.text,
        'ja-JP-NanamiNeural');
    expect(tester.widget<TextField>(_key('name')).controller!.text, '七海');
    expect(tester.widget<TextField>(_key('locale')).controller!.text, 'ja-JP');
    expect(tts.saved, 0);
  });

  testWidgets('cancel ignores a late synthesis error and disposes player',
      (tester) async {
    final tts = _FakeTts()..deferPreview = true;
    final player = _FakePlayer();
    await mount(tester,
        initial: _initial, tts: tts, createPlayer: () => player);
    await tap(tester, _key('preview'));
    await tap(tester, find.text('取消试听'));
    expect(tts.aborts.single!.isCompleted, isTrue);
    tts.requests.single.complete(const CustomTtsResult.failure(
        CustomTtsError(CustomTtsErrorCode.http, 'stale error')));
    await tester.pump();
    expect(find.text('试听已取消。'), findsOneWidget);
    expect(find.text('stale error'), findsNothing);
    expect(player.disposed, isTrue);
    expect(player.playCount, 0);
  });

  testWidgets('repeated preview ignores old result and keeps newer state',
      (tester) async {
    final tts = _FakeTts()..deferPreview = true;
    final players = <_FakePlayer>[];
    await mount(tester, initial: _initial, tts: tts, createPlayer: () {
      final player = _FakePlayer();
      players.add(player);
      return player;
    });
    await tap(tester, _key('preview'));
    await tap(tester, _key('preview'));
    expect(tts.requests, hasLength(2));
    expect(tts.aborts.first!.isCompleted, isTrue);
    tts.requests[1]
        .complete(CustomTtsResult.success(Uint8List.fromList([1, 2, 3])));
    await tester.pump();
    tts.requests[0].complete(const CustomTtsResult.failure(
        CustomTtsError(CustomTtsErrorCode.http, 'stale error')));
    await tester.pump();
    expect(find.text('试听音频已生成，正在播放。'), findsOneWidget);
    expect(find.text('stale error'), findsNothing);
    expect(players.first.playCount, 0);
    expect(players.first.disposed, isTrue);
    expect(players.last.playCount, 1);
  });

  testWidgets('rapid restarts wait for slow old player cleanup',
      (tester) async {
    final tts = _FakeTts()..deferPreview = true;
    final oldPlayer = _FakePlayer()..stopGate = Completer<void>();
    final nextPlayer = _FakePlayer();
    var created = 0;
    await mount(tester,
        initial: _initial,
        tts: tts,
        createPlayer: () => created++ == 0 ? oldPlayer : nextPlayer);
    await tap(tester, _key('preview'));
    await tap(tester, _key('preview'));
    await tap(tester, _key('preview'));
    expect(tts.requests, hasLength(1));
    oldPlayer.stopGate!.complete();
    await tester.pump();
    expect(tts.requests, hasLength(2));
    tts.requests.last
        .complete(CustomTtsResult.success(Uint8List.fromList([1])));
    tts.requests.first
        .complete(CustomTtsResult.success(Uint8List.fromList([2])));
    await tester.pump();
    expect(nextPlayer.playCount, 1);
    expect(oldPlayer.playCount, 0);
    expect(oldPlayer.disposed, isTrue);
  });

  testWidgets('late playback completion cannot change replacement busy state',
      (tester) async {
    final tts = _FakeTts()..deferPreview = true;
    final oldPlayer = _FakePlayer()..playGate = Completer<void>();
    var created = 0;
    await mount(tester,
        initial: _initial,
        tts: tts,
        createPlayer: () => created++ == 0 ? oldPlayer : _FakePlayer());
    await tap(tester, _key('preview'));
    tts.requests.first
        .complete(CustomTtsResult.success(Uint8List.fromList([1])));
    await tester.pump();
    await tap(tester, _key('preview'));
    oldPlayer.playGate!.complete();
    await tester.pump();
    expect(find.text('再次试听'), findsOneWidget);
    expect(find.text('正在生成试听…'), findsOneWidget);
    tts.requests.last.complete(const CustomTtsResult.failure(
        CustomTtsError(CustomTtsErrorCode.http, 'new request error')));
    await tester.pump();
    expect(find.text('new request error'), findsOneWidget);
  });

  testWidgets('disposal cancels preview and suppresses late result',
      (tester) async {
    final tts = _FakeTts()..deferPreview = true;
    final player = _FakePlayer();
    await mount(tester,
        initial: _initial, tts: tts, createPlayer: () => player);
    await tap(tester, _key('preview'));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    tts.requests.single
        .complete(CustomTtsResult.success(Uint8List.fromList([1])));
    await tester.pump();
    expect(tts.aborts.single!.isCompleted, isTrue);
    expect(player.disposed, isTrue);
    expect(player.playCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid stored metadata shows recovery message without crashing',
      (tester) async {
    await mount(tester, metadata: {'custom_ssml_tts_metadata': '{invalid'});
    expect(find.text('旧语音配置格式无效，请重新填写并保存。'), findsOneWidget);
    expect(_key('region'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Azure setup remains usable on small screen at large text scale',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tts = _FakeTts();
    await mount(tester, tts: tts, textScale: 2.5);
    await enter(tester, 'credential', 'draft-key');
    await tap(tester, _key('load-voices'));
    tts.voiceRequests.single.complete(const []);
    await tester.pump();
    expect(find.text('此语言没有返回可用音色。'), findsOneWidget);
    await tap(tester, _key('save'));
    expect(find.text('请填写音色 ID。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screen and large text remain scrollable without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, initial: _initial, textScale: 2);
    expect(tester.takeException(), isNull);
    await enter(tester, 'credential', 'draft-key');
    await tap(tester, find.byTooltip('显示密钥'));
    await tap(tester, _key('preview'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tap(tester, _key('save'));
    await tester.pump();
    expect(find.textContaining('设置已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
