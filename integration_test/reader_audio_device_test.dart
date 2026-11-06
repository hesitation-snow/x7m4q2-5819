import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yomiru/services/reader_audio_bootstrap.dart';
import 'package:yomiru/services/system_tts.dart';

Uint8List _wav() {
  const sampleRate = 16000;
  const samples = sampleRate * 2;
  final data = ByteData(44 + samples * 2);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(
        44 + i * 2,
        (math.sin(i * 2 * math.pi * 330 / sampleRate) * 1200).round(),
        Endian.little);
  }
  return bytes;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final evidence = <String, dynamic>{};
  binding.reportData = evidence;

  testWidgets('device decodes private WAV and supports pause resume completion',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: Text('Yomiru 音频链路测试')))));
    final handler =
        await ensureReaderAudioHandler().timeout(const Duration(seconds: 20));
    final root = await getTemporaryDirectory();
    final file = File('${root.path}/device-smoke.wav');
    await file.writeAsBytes(_wav());
    final done = Completer<void>();
    try {
      await handler.playFiles([file],
          title: 'Yomiru 独立测试',
          startIndex: 0,
          onSegmentChanged: (_) {}, onCompleted: () {
        if (!done.isCompleted) done.complete();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.updatePosition.inMilliseconds,
          greaterThan(0));
      await handler.pause();
      expect(handler.playbackState.value.playing, isFalse);
      await handler.play();
      await done.future.timeout(const Duration(seconds: 10));
      evidence['private_wav_playback'] = {
        'status': 'passed',
        'bytes': await file.length(),
        'pause_resume': true
      };
      // This is the same path used by SSML preview, without any localhost HTTP proxy.
      await handler.playBytes(_wav(),
          title: '试听文件链路', contentType: 'audio/wav');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(handler.playbackState.value.playing, isTrue);
      evidence['preview_private_file'] = {'status': 'passed'};
      debugPrint('DEVICE_AUDIO_EVIDENCE ${jsonEncode(evidence)}');
    } catch (error) {
      evidence['private_wav_playback'] = {
        'status': 'failed',
        'errorType': error.runtimeType.toString()
      };
      rethrow;
    } finally {
      await handler.stop();
      if (await file.exists()) await file.delete();
    }
  });

  testWidgets('installed system TTS synthesizes an actual WAV file',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: Text('系统语音合成测试')))));
    final tts = SystemTts();
    final root = await getTemporaryDirectory();
    final file = File('${root.path}/system-smoke.wav');
    try {
      final engines = await tts.getEngines();
      expect(engines, isNotEmpty,
          reason: 'Install an Android TextToSpeech engine first.');
      await tts
          .setEngine(engines.first.id)
          .timeout(const Duration(seconds: 20));
      final voices = await tts.getVoices();
      final offline = voices.where((voice) =>
          voice.networkRequired != true &&
          (voice.locale?.startsWith('zh') ?? false));
      final voice = offline.isNotEmpty ? offline.first : voices.firstOrNull;
      final locale = voice?.locale ?? 'zh-CN';
      final path = await tts.synthesizeToFile(
          '这是一段用于验证听书功能的语音。', file.path, locale, voice?.id, 1);
      expect(path, file.path);
      final audio = await file.readAsBytes();
      expect(audio.length, greaterThan(44),
          reason: 'A header alone is not synthesized speech.');
      expect(String.fromCharCodes(audio.take(4)), 'RIFF');
      expect(String.fromCharCodes(audio.skip(8).take(4)), 'WAVE');
      final handler = await ensureReaderAudioHandler();
      final done = Completer<void>();
      await handler.playFiles([file],
          title: '真实系统 TTS',
          startIndex: 0,
          onSegmentChanged: (_) {}, onCompleted: () {
        if (!done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 30));
      evidence['system_tts'] = {
        'status': 'passed',
        'engine': engines.first.id,
        'locale': locale,
        'bytes': audio.length
      };
      debugPrint('DEVICE_AUDIO_EVIDENCE ${jsonEncode(evidence)}');
    } catch (error) {
      evidence['system_tts'] = {
        'status': 'failed',
        'error': error is SystemTtsException
            ? error.code
            : error.runtimeType.toString()
      };
      debugPrint('DEVICE_AUDIO_EVIDENCE ${jsonEncode(evidence)}');
      rethrow;
    } finally {
      try {
        await tts.stop();
      } catch (_) {}
      await tts.dispose();
      if (await file.exists()) await file.delete();
    }
  });
}
