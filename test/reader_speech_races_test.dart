import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_tts_core.dart';

class _Request {
  _Request(this.text, this.config, this.path);
  final String text;
  final SpeechSynthesisConfig config;
  final String path;
  final release = Completer<void>();
}

class _GatedSynth implements SpeechAudioSynthesizer {
  final requests = <_Request>[];
  final changes = StreamController<int>.broadcast(sync: true);
  Future<void> waitFor(int count) async {
    if (requests.length >= count) return;
    await changes.stream
        .firstWhere((value) => value >= count)
        .timeout(const Duration(seconds: 5));
  }

  @override
  Future<File> synthesize(
      String text, SpeechSynthesisConfig config, String path) async {
    final request = _Request(text, config, path);
    requests.add(request);
    changes.add(requests.length);
    await request.release.future;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString('$text ${config.voice} ${config.rate}');
    return file;
  }
}

class _Handler implements SpeechFilesHandler {
  final played = <File>[];
  FutureOr<void> Function()? completed;
  @override
  Future<void> playFiles(List<File> files,
      {required String title,
      String? artist,
      required int startIndex,
      required FutureOr<void> Function(int) onSegmentChanged,
      required FutureOr<void> Function() onCompleted}) async {
    played.addAll(files);
    completed = onCompleted;
    await onSegmentChanged(startIndex);
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
  late Directory temp;
  late _GatedSynth synth;
  late _Handler handler;
  late ReaderSpeechSession session;
  const normal = SpeechSynthesisConfig(
      source: 'system', voice: 'voice-a', language: 'zh-CN', rate: 1);
  const faster = SpeechSynthesisConfig(
      source: 'system', voice: 'voice-b', language: 'zh-CN', rate: 1.5);
  final segments = List.generate(
      3,
      (i) => TtsSegment(
          blockIndex: i, startOffset: 0, endOffset: 3, text: '段落$i'));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('listening-races-');
    synth = _GatedSynth();
    handler = _Handler();
    session = ReaderSpeechSession(
        handler: handler,
        synthesizer: synth,
        prefetchCount: 0,
        cache: SpeechAudioCache(temporaryDirectory: () async => temp));
  });
  tearDown(() async {
    session.dispose();
    await synth.changes.close();
    await temp.delete(recursive: true);
  });

  test('changing voice/rate while loading plays only the new configuration',
      () async {
    final first = session.start(segments,
        accountId: 'user', config: normal, title: 'Book');
    await synth.waitFor(1);
    final changed = session.updateConfig(faster);
    await synth.waitFor(2);
    synth.requests[1].release.complete();
    await changed;
    synth.requests[0].release.complete();
    await first;
    expect(handler.played, hasLength(1));
    expect(await handler.played.single.readAsString(), contains('voice-b 1.5'));
    expect(session.error, isNull);
  });

  test('stop cancels delayed synthesis without restarting playback', () async {
    final start = session.start(segments,
        accountId: 'user', config: normal, title: 'Book');
    await synth.waitFor(1);
    await session.stop();
    synth.requests.single.release.complete();
    await start;
    expect(handler.played, isEmpty);
    expect(session.isStopped, isTrue);
    expect(session.isLoading, isFalse);
  });

  test(
      'pause and seek select silently; resume builds only the selected paragraph',
      () async {
    final start = session.start(segments,
        accountId: 'user', config: normal, title: 'Book');
    await synth.waitFor(1);
    synth.requests[0].release.complete();
    await start;
    await session.pause();
    await session.seek(2);
    expect(session.position, 2);
    expect(session.isPaused, isTrue);
    expect(synth.requests, hasLength(1));
    expect(handler.played, hasLength(1));
    final resumed = session.resume();
    await synth.waitFor(2);
    synth.requests[1].release.complete();
    await resumed;
    expect(handler.played, hasLength(2));
    expect(await handler.played.last.readAsString(), startsWith('段落2'));
  });

  test('rapid next ignores the earlier paragraph finishing last', () async {
    final start = session.start(segments,
        accountId: 'user', config: normal, title: 'Book');
    await synth.waitFor(1);
    synth.requests[0].release.complete();
    await start;
    final one = session.next();
    await synth.waitFor(2);
    final two = session.next();
    await synth.waitFor(3);
    synth.requests[2].release.complete();
    await two;
    synth.requests[1].release.complete();
    await one;
    expect(session.position, 2);
    expect(handler.played, hasLength(2));
    expect(await handler.played.last.readAsString(), startsWith('段落2'));
  });

  test(
      'resuming a paused paragraph gap advances once instead of replaying old audio',
      () async {
    session.setSegmentInterval(const Duration(hours: 1));
    final start = session.start(segments,
        accountId: 'user', config: normal, title: 'Book');
    await synth.waitFor(1);
    synth.requests[0].release.complete();
    await start;
    final oldCompletion = handler.completed!;
    await oldCompletion();
    await session.pause();
    final resume = session.resume();
    await synth.waitFor(2);
    synth.requests[1].release.complete();
    await resume;
    await oldCompletion();
    expect(session.position, 1);
    expect(handler.played, hasLength(2));
    expect(synth.requests, hasLength(2));
    await session.stop();
  });
}
