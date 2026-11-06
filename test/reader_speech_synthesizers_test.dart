import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_speech_synthesizers.dart';
import 'package:yomiru/services/system_tts.dart';

void main() {
  test('system cache separates engines even if voice names are equal', () {
    final cache = SpeechAudioCache();
    final first = systemSpeechConfig(
        engineId: 'engine.a', voice: 'voice', language: 'zh-CN', rate: 1);
    final second = systemSpeechConfig(
        engineId: 'engine.b', voice: 'voice', language: 'zh-CN', rate: 1);
    expect(cache.cachePath('account', '同一句话', first),
        isNot(cache.cachePath('account', '同一句话', second)));
  });

  test(
      'mutating language preferences does not mutate an in-flight configuration',
      () {
    final voices = {'japanese': 'voice-before'};
    final config = systemSpeechConfig(
        voice: 'default', language: 'zh-CN', rate: 1, voiceByLanguage: voices);
    final cache = SpeechAudioCache();
    final before = cache.cachePath('account', 'こんにちは', config);
    voices['japanese'] = 'voice-after';
    expect(cache.cachePath('account', 'こんにちは', config), before);
    expect(
        (config.options['voiceByLanguage'] as Map)['japanese'], 'voice-before');
  });

  test(
      'unimplemented local GPT-SoVITS never writes fake audio or falls back to HTTP',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('local-gpt-unimplemented-');
    try {
      final path = '${directory.path}/speech.wav';
      await expectLater(
          GptSoVitsSpeechSynthesizer().synthesize(
              '测试',
              gptSoVitsSpeechConfig(
                  voiceId: 'test',
                  language: 'zh',
                  rate: 1,
                  packDir: directory.path),
              path),
          throwsA(isA<SystemTtsException>().having((error) => error.code,
              'code', 'LOCAL_GPTSOVITS_NOT_IMPLEMENTED')));
      expect(await File(path).exists(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
