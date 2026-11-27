import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/reader/reader_language_segments.dart'
    show PlaybackSleepTimer, ReaderLanguageFilter;
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_tts_core.dart';
import 'package:yomiru/services/listening_now.dart';
import 'package:yomiru/services/speech_chapter_loader.dart';

class _TestSynth implements SpeechAudioSynthesizer {
  @override
  Future<File> synthesize(
    String text,
    SpeechSynthesisConfig config,
    String cachePath,
  ) async {
    final file = File(cachePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
    return file;
  }
}

class _SeamlessHandler implements SeamlessSpeechFilesHandler {
  int stopCalls = 0;
  int transitionCalls = 0;
  final List<String?> artists = [];
  FutureOr<void> Function()? _completed;

  @override
  Future<void> prepareSegmentTransition() async {
    transitionCalls++;
  }

  @override
  Future<void> playFiles(
    List<File> files, {
    required String title,
    String? artist,
    Uri? artUri,
    required int startIndex,
    required FutureOr<void> Function(int) onSegmentChanged,
    required FutureOr<void> Function() onCompleted,
  }) async {
    artists.add(artist);
    _completed = onCompleted;
    await onSegmentChanged(0);
  }

  Future<void> finishCurrent() async {
    final cb = _completed;
    _completed = null;
    if (cb != null) await cb();
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}
}

TtsSegment _seg(String text, {int block = 0}) => TtsSegment(
      blockIndex: block,
      startOffset: 0,
      endOffset: text.length,
      text: text,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const speechConfig = SpeechSynthesisConfig(
    source: 'edge',
    voice: 'zh-CN-XiaoxiaoNeural',
    language: 'zh-CN',
    rate: 1.0,
  );

  late Directory tempDir;
  late SpeechAudioCache cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
    ListeningNow.instance.nextChapterLoaderForTesting = null;
    await ListeningNow.instance.stop();
    tempDir = await Directory.systemTemp.createTemp('bg_tts_auto_next_');
    cache = SpeechAudioCache(
      temporaryDirectory: () async => tempDir,
      budgetBytes: 2 * 1024 * 1024,
    );
  });

  tearDown(() async {
    ListeningNow.instance.nextChapterLoaderForTesting = null;
    await ListeningNow.instance.stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  test(
      'ReaderSpeechSession keeps handler alive via prepareSegmentTransition across chapter change',
      () async {
    final handler = _SeamlessHandler();
    final session = ReaderSpeechSession(
      handler: handler,
      synthesizer: _TestSynth(),
      cache: cache,
    );
    addTearDown(session.dispose);

    var invoked = 0;
    session.onChapterCompleted = () async {
      invoked++;
      await session.start(
        [_seg('第二章第一句')],
        accountId: 'guest',
        config: speechConfig,
        title: '测试书',
        artist: '第二章',
      );
      return true;
    };

    await session.start(
      [_seg('第一章最后一句')],
      accountId: 'guest',
      config: speechConfig,
      title: '测试书',
      artist: '第一章',
    );
    expect(handler.stopCalls, 0);

    await handler.finishCurrent();

    expect(invoked, 1);
    expect(handler.stopCalls, 0);
    expect(handler.transitionCalls, 3); // Initial start + chapter end + next start
    expect(handler.artists, ['第一章', '第二章']);
    expect(session.isStopped, isFalse);
    expect(session.isCompleted, isFalse);
  });

  test(
      'ReaderSpeechSession skips chapter auto-advance when sleepTimer is chapterEnd',
      () async {
    final handler = _SeamlessHandler();
    final session = ReaderSpeechSession(
      handler: handler,
      synthesizer: _TestSynth(),
      cache: cache,
    );
    addTearDown(session.dispose);

    var invoked = 0;
    session.onChapterCompleted = () async {
      invoked++;
      return true;
    };
    session.setSleepTimer(PlaybackSleepTimer.chapterEnd);

    await session.start(
      [_seg('睡前本章内容')],
      accountId: 'guest',
      config: speechConfig,
      title: '测试书',
      artist: '第一章',
    );

    await handler.finishCurrent();

    expect(invoked, 0);
    expect(handler.stopCalls, 1);
    expect(session.isStopped, isTrue);
    expect(session.isCompleted, isTrue);
  });

  test(
      'SpeechChapterLoader resolves across volumes, skips image-only chapter, and detects locked next chapter',
      () async {
    final details = <int, LKChapterDetail>{
      101: LKChapterDetail(
        chapterId: 101,
        chapterNo: 1,
        volumeId: 10,
        title: '第一卷终章',
        bodyText: '内容一',
        nextChapterId: null,
      ),
      102: LKChapterDetail(
        chapterId: 102,
        chapterNo: 1,
        volumeId: 20,
        title: '卷末插画',
        bodyText: '',
        bodyHtml: '<img src="https://example.com/art.jpg"/>',
        nextChapterId: 103,
        nextTitle: '第二卷第一章',
        nextVolumeId: 20,
      ),
      103: LKChapterDetail(
        chapterId: 103,
        chapterNo: 2,
        volumeId: 20,
        title: '第二卷第一章',
        bodyText: '新的开始。第二句。',
        nextChapterId: 104,
        nextTitle: '付费章',
        nextVolumeId: 20,
      ),
      104: LKChapterDetail(
        chapterId: 104,
        chapterNo: 3,
        volumeId: 20,
        title: '付费章',
        bodyText: '',
        locked: true,
        unlocked: false,
      ),
    };

    final volumes = [
      LKVolume(volumeId: 10, title: '第一卷', chapterCount: 1),
      LKVolume(volumeId: 20, title: '第二卷', chapterCount: 3),
    ];
    final pages = <String, LKChapterPage>{
      '10:1': LKChapterPage(
        items: [LKChapter(chapterId: 101, chapterNo: 1, title: '第一卷终章')],
        page: 1,
        hasMore: false,
        total: 1,
      ),
      '20:1': LKChapterPage(
        items: [
          LKChapter(chapterId: 102, chapterNo: 1, title: '卷末插画'),
          LKChapter(chapterId: 103, chapterNo: 2, title: '第二卷第一章'),
          LKChapter(chapterId: 104, chapterNo: 3, title: '付费章'),
        ],
        page: 1,
        hasMore: false,
        total: 3,
      ),
    };

    final res1 = await SpeechChapterLoader.loadNextChapter(
      bookId: 99,
      currentChapterId: 101,
      currentVolumeId: 10,
      languageFilter: ReaderLanguageFilter.automatic,
      isCurrent: () => true,
      useContentCache: false,
      fetchChapterDetail: (_, cid) async => details[cid]!,
      fetchVolumes: (_) async => volumes,
      fetchChapterPage: (_, vid, p) async => pages['$vid:$p']!,
    );
    expect(res1.status, SpeechNextChapterStatus.loaded);
    expect(res1.chapter!.chapterId, 103);
    expect(res1.chapter!.volumeId, 20);
    expect(res1.chapter!.nextChapterId, 104);
    expect(res1.chapter!.segments.length, 2);

    final res2 = await SpeechChapterLoader.loadNextChapter(
      bookId: 99,
      currentChapterId: 103,
      currentVolumeId: 20,
      nextChapterId: 104,
      languageFilter: ReaderLanguageFilter.automatic,
      isCurrent: () => true,
      useContentCache: false,
      fetchChapterDetail: (_, cid) async => details[cid]!,
    );
    expect(res2.status, SpeechNextChapterStatus.locked);

    final cancelled = await SpeechChapterLoader.loadNextChapter(
      bookId: 99,
      currentChapterId: 103,
      currentVolumeId: 20,
      nextChapterId: 104,
      languageFilter: ReaderLanguageFilter.automatic,
      isCurrent: () => false,
      useContentCache: false,
      fetchChapterDetail: (_, cid) async => details[cid]!,
    );
    expect(cancelled.status, SpeechNextChapterStatus.cancelled);
  });

  test(
      'ListeningNow automatically advances Chapter 1 -> Chapter 2 -> Chapter 3 in background',
      () async {
    final handler = _SeamlessHandler();
    final session = ReaderSpeechSession(
      handler: handler,
      synthesizer: _TestSynth(),
      cache: cache,
    );

    await session.start(
      [_seg('第一章句子')],
      accountId: 'guest',
      config: speechConfig,
      title: '测试书',
      artist: '第一章',
    );

    ListeningNow.instance.nextChapterLoaderForTesting = ({
      required int bookId,
      required int currentChapterId,
      required int currentVolumeId,
      int? nextChapterId,
      String nextChapterTitle = '',
      int? nextVolumeId,
      required ReaderLanguageFilter languageFilter,
      required bool Function() isCurrent,
    }) async {
      if (currentChapterId == 1001) {
        return SpeechNextChapterResult.loaded(
          LoadedSpeechChapter(
            chapterId: 1002,
            title: '第二章',
            volumeId: 10,
            nextChapterId: 1003,
            nextChapterTitle: '第三章',
            nextVolumeId: 11,
            segments: [_seg('第二章句子')],
          ),
        );
      }
      if (currentChapterId == 1002) {
        return SpeechNextChapterResult.loaded(
          LoadedSpeechChapter(
            chapterId: 1003,
            title: '第三章',
            volumeId: 11,
            nextChapterId: null,
            nextChapterTitle: '',
            nextVolumeId: null,
            segments: [_seg('第三章句子')],
          ),
        );
      }
      return const SpeechNextChapterResult.noNext();
    };

    ListeningNow.instance.adopt(
      session: session,
      bookTitle: '测试书',
      chapterTitle: '第一章',
      bookId: 500,
      chapterId: 1001,
      volumeId: 10,
      config: speechConfig,
      accountId: 'guest',
      nextChapterId: 1002,
      nextChapterTitle: '第二章',
      nextVolumeId: 10,
      continuousChapter: true,
    );

    // Chapter 1 ends -> auto-loads Chapter 2
    await handler.finishCurrent();
    expect(ListeningNow.instance.active, isTrue);
    expect(ListeningNow.instance.chapterId, 1002);
    expect(ListeningNow.instance.chapterTitle, '第二章');
    expect(ListeningNow.instance.nextChapterId, 1003);
    expect(handler.stopCalls, 0);

    // Chapter 2 ends -> auto-loads Chapter 3
    await handler.finishCurrent();
    expect(ListeningNow.instance.active, isTrue);
    expect(ListeningNow.instance.chapterId, 1003);
    expect(ListeningNow.instance.chapterTitle, '第三章');
    expect(ListeningNow.instance.volumeId, 11);
    expect(handler.stopCalls, 0);

    // Chapter 3 ends (no next chapter) -> stops cleanly
    await handler.finishCurrent();
    expect(ListeningNow.instance.active, isFalse);
    expect(handler.stopCalls, 1);
  });

  test(
      'ListeningNow aborts background auto-advance on account change or locked chapter',
      () async {
    final handler = _SeamlessHandler();
    final session = ReaderSpeechSession(
      handler: handler,
      synthesizer: _TestSynth(),
      cache: cache,
    );

    await session.start(
      [_seg('第一章句子')],
      accountId: 'guest',
      config: speechConfig,
      title: '测试书',
      artist: '第一章',
    );

    final gate = Completer<SpeechNextChapterResult>();
    ListeningNow.instance.nextChapterLoaderForTesting = ({
      required int bookId,
      required int currentChapterId,
      required int currentVolumeId,
      int? nextChapterId,
      String nextChapterTitle = '',
      int? nextVolumeId,
      required ReaderLanguageFilter languageFilter,
      required bool Function() isCurrent,
    }) =>
        gate.future;

    ListeningNow.instance.adopt(
      session: session,
      bookTitle: '测试书',
      chapterTitle: '第一章',
      bookId: 500,
      chapterId: 1001,
      volumeId: 10,
      config: speechConfig,
      accountId: 'guest',
      nextChapterId: 1002,
      continuousChapter: true,
    );

    final finishing = handler.finishCurrent();
    await Future<void>.delayed(Duration.zero);
    // Simulate account switch while chapter 2 fetch is in-flight
    LKClient.sessionRev.value++;
    gate.complete(
      SpeechNextChapterResult.loaded(
        LoadedSpeechChapter(
          chapterId: 1002,
          title: '第二章',
          volumeId: 10,
          nextChapterId: null,
          nextChapterTitle: '',
          nextVolumeId: null,
          segments: [_seg('不应播放')],
        ),
      ),
    );
    await finishing;
    expect(ListeningNow.instance.active, isFalse);
    expect(handler.artists, ['第一章']);

    // Also test locked chapter message retention
    final handler2 = _SeamlessHandler();
    final session2 = ReaderSpeechSession(
      handler: handler2,
      synthesizer: _TestSynth(),
      cache: cache,
    );
    await session2.start(
      [_seg('免费章')],
      accountId: 'guest',
      config: speechConfig,
      title: '测试书',
      artist: '免费章',
    );
    ListeningNow.instance.nextChapterLoaderForTesting = ({
      required int bookId,
      required int currentChapterId,
      required int currentVolumeId,
      int? nextChapterId,
      String nextChapterTitle = '',
      int? nextVolumeId,
      required ReaderLanguageFilter languageFilter,
      required bool Function() isCurrent,
    }) async =>
        const SpeechNextChapterResult.locked('下一章需要解锁，已停止连续朗读');

    ListeningNow.instance.adopt(
      session: session2,
      bookTitle: '测试书',
      chapterTitle: '免费章',
      bookId: 500,
      chapterId: 2001,
      volumeId: 10,
      config: speechConfig,
      accountId: 'guest',
      nextChapterId: 2002,
      continuousChapter: true,
    );

    await handler2.finishCurrent();
    expect(ListeningNow.instance.active, isFalse);
    expect(ListeningNow.instance.lastError, '下一章需要解锁，已停止连续朗读');
  });
}
