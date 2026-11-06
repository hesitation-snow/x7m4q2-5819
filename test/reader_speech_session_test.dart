import 'dart:async';
import 'dart:io';

import 'package:yomiru/reader/reader_language_segments.dart' show PlaybackSleepTimer, ReaderLanguageFilter;

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_tts_core.dart';

class _Synth implements SpeechAudioSynthesizer {
  int calls = 0;
  @override
  Future<File> synthesize(String text, SpeechSynthesisConfig config, String cachePath) async {
    calls++;
    final file = File(cachePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    return file;
  }
}

class _Handler implements SpeechFilesHandler {
  final played = <File>[];
  final enqueued = <File>[];
  FutureOr<void> Function(int)? segmentChanged;
  FutureOr<void> Function()? completed;
  bool paused = false, stopped = false;
  @override
  Future<void> playFiles(List<File> files, {required String title, String? artist, required int startIndex, required FutureOr<void> Function(int) onSegmentChanged, required FutureOr<void> Function() onCompleted}) async { played.addAll(files); segmentChanged = onSegmentChanged; completed = onCompleted; await onSegmentChanged(0); }
  Future<void> finishCurrent() async { final callback = completed; if (callback != null) await callback(); }
  @override Future<void> pause() async { paused = true; }
  @override Future<void> stop() async { stopped = true; }
  @override Future<void> skipToNext() async {}
  @override Future<void> skipToPrevious() async {}
}

TtsSegment _seg(String text, int index) => TtsSegment(blockIndex: index, startOffset: 0, endOffset: text.length, text: text);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late SpeechAudioCache cache;
  setUp(() async { temp = await Directory.systemTemp.createTemp('speech-cache-test'); cache = SpeechAudioCache(temporaryDirectory: () async => temp, budgetBytes: 1024 * 1024); });
  tearDown(() async { if (await temp.exists()) await temp.delete(recursive: true); });
  const config = SpeechSynthesisConfig(source: 'system', voice: 'v1', language: 'zh-CN', rate: 1);

  test('cache identities separate account, voice, language, rate and text; clear account', () async {
    final synth = _Synth();
    final a = await cache.put('account-A', 'hello', config, (path) => synth.synthesize('hello', config, path));
    final hit = await cache.get('account-A', 'hello', config);
    expect(hit?.path, a.path);
    expect(await cache.get('account-B', 'hello', config), isNull);
    expect(a.path, endsWith('.wav'));
    expect(cache.cachePath('account-A', 'hello', const SpeechSynthesisConfig(source: 'custom', voice: 'v1', language: 'zh-CN', rate: 1)), endsWith('.mp3'));
    expect(await cache.get('account-A', 'hello', const SpeechSynthesisConfig(source: 'system', voice: 'v2', language: 'zh-CN', rate: 1)), isNull);
    await cache.clear('account-A');
    expect(await cache.get('account-A', 'hello', config), isNull);
  });

  test('plays only the current file and caches two successors without enqueueing', () async {
    final synth = _Synth(), handler = _Handler();
    final session = ReaderSpeechSession(handler: handler, synthesizer: synth, cache: cache);
    await session.start(List.generate(5, (i) => _seg('segment $i', i)), accountId: 'user', config: config, title: 'Book');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(synth.calls, 3);
    expect(handler.played, hasLength(1));
    expect(handler.played.single.path, contains('reader_speech_cache'));
    await handler.finishCurrent();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(handler.played, hasLength(2));
    expect(session.position, 1);
    await session.seek(4);
    expect(session.position, 4);
    expect(handler.played, hasLength(3));
    await session.pause();
    expect(session.isPaused, isTrue);
    expect(handler.paused, isTrue);
    await session.resume();
    expect(session.isPaused, isFalse);
    await session.stop();
    expect(session.isStopped, isTrue);
    session.dispose();
  });

  test('completion waits for configured interval before next segment', () async {
    final handler = _Handler(), session = ReaderSpeechSession(handler: handler, synthesizer: _Synth(), cache: cache);
    session.setSegmentInterval(const Duration(milliseconds: 40));
    await session.start([_seg('one', 0), _seg('two', 1)], accountId: 'user', config: config, title: 'Book');
    await handler.finishCurrent();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(handler.played, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handler.played, hasLength(2));
    expect(session.position, 1);
    session.dispose();
  });

  test('chapter-end sleep stops only after the final segment', () async {
    final handler = _Handler(), session = ReaderSpeechSession(handler: handler, synthesizer: _Synth(), cache: cache);
    session.setSleepTimer(PlaybackSleepTimer.chapterEnd);
    await session.start([_seg('one', 0), _seg('two', 1)], accountId: 'user', config: config, title: 'Book');
    await handler.finishCurrent();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(session.position, 1);
    expect(session.isStopped, isFalse);
    await handler.finishCurrent();
    expect(session.isStopped, isTrue);
    session.dispose();
  });

  test('account generation prevents stale synthesis and preserves cache separation', () async {
    final synth = _Synth(), handler = _Handler(), session = ReaderSpeechSession(handler: handler, synthesizer: synth, cache: cache);
    await session.start([_seg('hello', 0)], accountId: 'one', config: config, title: 'Book');
    await session.stop();
    await session.start([_seg('hello', 0)], accountId: 'two', config: config, title: 'Book');
    expect(synth.calls, 2);
    expect(handler.played, hasLength(2));
    await session.clearAccount('one');
    expect(await cache.get('one', 'hello', config), isNull);
    expect(await cache.get('two', 'hello', config), isNotNull);
    session.dispose();
  });

  test('language filter removes Japanese segments', () async {
    final handler = _Handler(), synth = _Synth();
    final session = ReaderSpeechSession(handler: handler, synthesizer: synth, cache: cache);
    await session.start([_seg('你好。', 0), _seg('こんにちは。', 1)], accountId: 'user', config: config, title: 'Book', languageFilter: ReaderLanguageFilter.chineseOnly);
    expect(handler.played, hasLength(1));
    session.dispose();
  });
}
