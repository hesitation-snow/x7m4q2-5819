import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yomiru/services/gpt_sovits_voice_pack.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('yomiru_voice_test_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('GptSoVitsVoicePack parses voice.json and checks validity', () {
    final packDir = Directory(p.join(tempDir.path, 'ookura_resona'))
      ..createSync();
    final modelsDir = Directory(p.join(packDir.path, 'models'))..createSync();
    Directory(p.join(packDir.path, 'references')).createSync();
    Directory(p.join(packDir.path, 'features')).createSync();

    File(p.join(modelsDir.path, 't2s_encoder.onnx')).writeAsStringSync('dummy');
    File(p.join(modelsDir.path, 't2s_fsdec.onnx')).writeAsStringSync('dummy');
    File(p.join(modelsDir.path, 't2s_sdec.onnx')).writeAsStringSync('dummy');
    File(p.join(modelsDir.path, 'vits.onnx')).writeAsStringSync('dummy');

    final meta = {
      'version': 'yomiru-voice-v1',
      'voice_id': 'ookura_resona',
      'name': '大藏衣远',
      'model_version': 'v2Pro',
      'defaults': {
        'top_k': 10,
        'top_p': 0.75,
        'temperature': 0.65,
        'speed': 1.0,
        'sample_rate': 32000,
      },
      'references': [
        {
          'id': 'ref_normal1',
          'tag': 'normal1',
          'text': '测试参考文本',
          'lang': 'ja',
          'wav': 'references/ref1.wav',
          'spec': 'features/ref1_spec.npy',
          'sv': 'features/ref1_sv.npy',
          'ssl': 'features/ref1_ssl.npy',
        }
      ]
    };
    File(p.join(packDir.path, 'voice.json'))
        .writeAsStringSync(jsonEncode(meta));

    final pack = GptSoVitsVoicePack.fromFolder(packDir.path);
    expect(pack.name, '大藏衣远');
    expect(pack.topK, 10);
    expect(pack.topP, 0.75);
    expect(pack.temperature, 0.65);
    expect(pack.references.length, 1);
    expect(pack.references.first.tag, 'normal1');
    expect(pack.isValid, isTrue);
  });

  test('GptSoVitsVoicePackStore lists and discovers valid voice packs',
      () async {
    final store =
        GptSoVitsVoicePackStore(directoryProvider: () async => tempDir);
    final base = await store.getBaseDir();

    final packDir = Directory(p.join(base.path, 'ookura_resona'))..createSync();
    final modelsDir = Directory(p.join(packDir.path, 'models'))..createSync();
    File(p.join(modelsDir.path, 't2s_encoder.onnx')).writeAsStringSync('dummy');
    File(p.join(modelsDir.path, 't2s_fsdec.onnx')).writeAsStringSync('dummy');
    File(p.join(modelsDir.path, 't2s_sdec.onnx')).writeAsStringSync('dummy');
    File(p.join(modelsDir.path, 'vits.onnx')).writeAsStringSync('dummy');

    final meta = {
      'voice_id': 'ookura_resona',
      'name': '大藏衣远',
      'references': [
        {'tag': 'normal1'}
      ]
    };
    File(p.join(packDir.path, 'voice.json'))
        .writeAsStringSync(jsonEncode(meta));

    final list = await store.listVoicePacks();
    expect(list.length, 1);
    expect(list.first.voiceId, 'ookura_resona');

    await store.deleteVoicePack('ookura_resona');
    final afterDel = await store.listVoicePacks();
    expect(afterDel, isEmpty);
  });
}
