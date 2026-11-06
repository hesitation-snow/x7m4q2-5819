import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:yomiru/services/system_tts.dart';

class _FakePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => r'C:\app\cache';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.system_tts/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final originalPathProvider = PathProviderPlatform.instance;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    PathProviderPlatform.instance = _FakePathProvider();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'setLanguage':
          return {'available': true};
        case 'getEngines':
          return [
            {
              'name': 'com.example.tts',
              'label': 'Example Voice',
              'isSystem': true
            }
          ];
        case 'setEngine':
          return true;
        case 'setVoice':
        case 'setSpeechRate':
          return true;
        case 'synthesizeToFile':
          final args = call.arguments as Map;
          return {'completed': true, 'path': args['filePath']};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    PathProviderPlatform.instance = originalPathProvider;
  });

  test('lists installed engines and selects one by package ID', () async {
    final tts = SystemTts(methodChannel: channel);
    addTearDown(tts.dispose);
    final engines = await tts.getEngines();
    expect(engines.single.id, 'com.example.tts');
    expect(engines.single.label, 'Example Voice');
    expect(engines.single.isSystem, isTrue);
    await tts.setEngine('com.example.tts');
    expect(calls.last.method, 'setEngine');
    expect(calls.last.arguments, {'id': 'com.example.tts'});
  });

  test('synthesizes to requested app-cache file and validates completion',
      () async {
    final tts = SystemTts(methodChannel: channel);
    addTearDown(tts.dispose);
    final path = await tts.synthesizeToFile(
        '你好', r'C:\app\cache\speech.wav', 'zh-CN', 'voice-1', 0.9);

    expect(path.toLowerCase(), r'c:\app\cache\speech.wav');
    expect(calls.map((call) => call.method), ['synthesizeToFile']);
    expect(calls.last.arguments, {
      'text': '你好',
      'filePath': r'c:\app\cache\speech.wav',
      'locale': 'zh-CN',
      'voiceId': 'voice-1',
      'rate': 0.9,
      'utteranceId': isA<String>(),
    });
  });

  test('rejects paths outside app cache without invoking native channel',
      () async {
    final tts = SystemTts(methodChannel: channel);
    addTearDown(tts.dispose);
    await expectLater(
      tts.synthesizeToFile('你好', r'C:\app\other\speech.wav', null, null, 1),
      throwsA(isA<SystemTtsException>()
          .having((error) => error.code, 'code', 'INVALID_OUTPUT_PATH')),
    );
    expect(calls, isEmpty);
  });

  test('rejects native response without completion or matching output path',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'synthesizeToFile') {
        return {'completed': false, 'path': r'C:\app\cache\speech.wav'};
      }
      return true;
    });
    final tts = SystemTts(methodChannel: channel);
    addTearDown(tts.dispose);
    await expectLater(
      tts.synthesizeToFile('你好', r'C:\app\cache\speech.wav', null, null, 1),
      throwsA(isA<SystemTtsException>()
          .having((error) => error.code, 'code', 'SYNTHESIS_FAILED')),
    );
  });
}
