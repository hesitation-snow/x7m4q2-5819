import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_speech_synthesizers.dart';
import 'package:yomiru/services/edge_protocol.dart';
import 'package:yomiru/services/edge_speech.dart';

class _FakeEdge extends EdgeSpeechClient {
  EdgeVoice? last;
  @override
  Future<Uint8List> synthesize(String text, EdgeVoice voice) async {
    last = voice;
    return Uint8List.fromList(List<int>.filled(120, 1));
  }
}

void main() {
  test('time proof is stable inside one five-minute window', () {
    final now = DateTime.utc(2026, 1, 1, 0, 1, 30);
    final again = DateTime.utc(2026, 1, 1, 0, 3, 10);
    final first = EdgeProtocol.timeProof(now);
    final second = EdgeProtocol.timeProof(again);
    expect(first, second);
    expect(first, matches(RegExp(r'^[0-9A-F]{16}-[0-9A-F]{64}$')));
  });

  test('binary audio frame splits the header from the payload', () {
    final header = 'Path:audio\r\n';
    final bytes = <int>[0, header.length, ...header.codeUnits, 9, 8, 7];
    final frame = EdgeSpeechClient.binaryAudio(bytes);
    expect(frame.path, 'audio');
    expect(frame.audio, [9, 8, 7]);
  });

  test('japanese text uses the japanese voice and speed is not a cache key',
      () async {
    final cache = SpeechAudioCache();
    final slow = edgeSpeechConfig();
    final fast = edgeSpeechConfig();
    expect(slow.rate, 1);
    expect(
      cache.cachePath('account', 'こんにちは', slow),
      cache.cachePath('account', 'こんにちは', fast),
    );
    final client = _FakeEdge();
    final directory = await Directory.systemTemp.createTemp('edge-speech-');
    try {
      final path = '${directory.path}/line.mp3';
      final config = edgeSpeechConfig(
        voiceByLanguage: const {'japanese': 'ja-JP-KeitaNeural'},
      );
      final file = await EdgeFileSpeechSynthesizer(client: client).synthesize(
        'こんにちは',
        config,
        path,
      );
      expect(client.last?.id, 'ja-JP-KeitaNeural');
      expect(await file.length(), 120);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('chinese override does not steal a japanese sentence', () {
    final voice = edgeVoiceForText(
      'こんにちは',
      edgeSpeechConfig(voiceByLanguage: const {'chinese': 'zh-CN-YunxiNeural'}),
    );
    expect(voice.id, 'ja-JP-NanamiNeural');
  });
}
