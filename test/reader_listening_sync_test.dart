import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/pages/reader_page.dart';
import 'package:yomiru/reader/reader_language_segments.dart'
    show PlaybackSleepTimer;
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_tts_core.dart';
import 'package:yomiru/reader/reader_tts_resume.dart';
import 'package:yomiru/services/listening_now.dart';
import 'package:yomiru/services/reader_tts_preferences.dart';

import 'reader_controls_test.dart' as fixture;

class _FakeSpeechSynth implements SpeechAudioSynthesizer {
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

class _FakeSpeechHandler implements SpeechFilesHandler {
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
    await onSegmentChanged(0);
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

List<TtsSegment> _makeFixtureSegments() => const [
      TtsSegment(
        blockIndex: 20,
        startOffset: 0,
        endOffset: 47,
        text: '第20段：这是一段用于验证音量按键与无动画翻页的测试正文。阅读位置必须保持正确，切换时不得改变文字布局。',
      ),
      TtsSegment(
        blockIndex: 35,
        startOffset: 0,
        endOffset: 47,
        text: '第35段：这是一段用于验证音量按键与无动画翻页的测试正文。阅读位置必须保持正确，切换时不得改变文字布局。',
      ),
    ];

Future<({Directory temp, ReaderSpeechSession session})>
    _startAndAdoptSession({
  required int bookId,
  required int chapterId,
  String accountId = 'guest',
}) async {
  final temp = await Directory.systemTemp.createTemp('yomiru_sync_test_');
  final cache = SpeechAudioCache(
    temporaryDirectory: () async => temp,
    budgetBytes: 1024 * 1024,
  );
  final session = ReaderSpeechSession(
    handler: _FakeSpeechHandler(),
    synthesizer: _FakeSpeechSynth(),
    cache: cache,
  );
  const config = SpeechSynthesisConfig(
    source: 'edge',
    voice: 'zh-CN-XiaoxiaoNeural',
    language: 'zh-CN',
    rate: 1,
  );
  await session.start(
    _makeFixtureSegments(),
    accountId: accountId,
    config: config,
    title: 'fixture',
    artist: 'Controls fixture',
  );
  ListeningNow.instance.adopt(
    session: session,
    bookTitle: 'fixture',
    chapterTitle: 'Controls fixture',
    bookId: bookId,
    chapterId: chapterId,
    volumeId: 1,
    coverUrl: 'https://example.com/adopted-cover.jpg',
    config: config,
    accountId: accountId,
  );
  await Future<void>.delayed(const Duration(milliseconds: 60));
  return (temp: temp, session: session);
}

Future<void> _cleanupAdopted(
  WidgetTester tester,
  ReaderSpeechSession session,
  Directory temp,
) async {
  await tester.runAsync(() async {
    await ListeningNow.instance.stop();
    if (!session.isStopped) {
      await session.stop();
    }
    session.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (await temp.exists()) {
      for (var attempt = 0;; attempt++) {
        try {
          await temp.delete(recursive: true);
          break;
        } on FileSystemException catch (error) {
          final code = error.osError?.errorCode;
          if ((code != 32 && code != 145) || attempt >= 5) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  });
}

Finder _highlightedSegmentFinder(String marker) {
  return find.ancestor(
    of: find.textContaining(marker, findRichText: true),
    matching: find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).borderRadius ==
              BorderRadius.circular(8),
    ),
  );
}

Finder _anyHighlightedBlockFinder() {
  return find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).borderRadius ==
            BorderRadius.circular(8) &&
        (w.decoration as BoxDecoration).color ==
            const Color(0xFF2F6FBF).withValues(alpha: .12),
  );
}

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
  });

  test('ListeningNow matchesChapter and take transfer active session cleanly',
      () async {
    final started = await _startAndAdoptSession(
      bookId: 1338,
      chapterId: 317815,
      accountId: 'guest',
    );
    final session = started.session;
    try {
      expect(ListeningNow.instance.active, isTrue);
      expect(
        ListeningNow.instance.matchesChapter(
          bookId: 1338,
          chapterId: 317815,
          accountId: 'guest',
        ),
        isTrue,
      );
      expect(
        ListeningNow.instance.matchesChapter(
          bookId: 1338,
          chapterId: 999999,
          accountId: 'guest',
        ),
        isFalse,
      );
      expect(
        ListeningNow.instance.matchesChapter(
          bookId: 1338,
          chapterId: 317815,
          accountId: 'uid:42',
        ),
        isFalse,
      );
      expect(
        ListeningNow.instance.take(
          bookId: 1338,
          chapterId: 999999,
          accountId: 'guest',
        ),
        isNull,
      );
      expect(ListeningNow.instance.active, isTrue);

      final transfer = ListeningNow.instance.take(
        bookId: 1338,
        chapterId: 317815,
        accountId: 'guest',
      );
      expect(transfer, isNotNull);
      expect(identical(transfer!.session, session), isTrue);
      expect(transfer.config?.source, 'edge');
      expect(transfer.accountId, 'guest');
      expect(ListeningNow.instance.active, isFalse);
      expect(session.isStopped, isFalse);
      expect(session.currentSegment?.blockIndex, 20);
    } finally {
      await session.stop();
      session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (await started.temp.exists()) {
        await started.temp.delete(recursive: true);
      }
    }
  });

  testWidgets(
      'ReaderPage in scroll mode reclaims ListeningNow session, centers and highlights spoken block, follows next(), and hands back on pop',
      (tester) async {
    late Directory temp;
    late ReaderSpeechSession session;
    await tester.runAsync(() async {
      final started = await _startAndAdoptSession(
        bookId: 1338,
        chapterId: 317815,
      );
      temp = started.temp;
      session = started.session;
    });

    try {
      await fixture.withReader(
        tester,
        paged: false,
        platform: TargetPlatform.android,
        pushReader: true,
        run: (calls, key) async {
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(ListeningNow.instance.active, isFalse);
          expect(session.isStopped, isFalse);

          final scroll = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView).first)
              .controller!;
          final offsetAt20 = scroll.offset;
          expect(offsetAt20, greaterThan(100));
          expect(find.textContaining('第20段', findRichText: true), findsWidgets);
          expect(_highlightedSegmentFinder('第20段'), findsOneWidget);

          if (find.byTooltip('系统朗读').hitTestable().evaluate().isEmpty) {
            await tester.tapAt(const Offset(200, 350));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.byTooltip('系统朗读'));
          await tester.pumpAndSettle();
          expect(find.textContaining('正在朗读'), findsOneWidget);
          Navigator.of(tester.element(find.textContaining('正在朗读'))).pop();
          await tester.pumpAndSettle();

          await tester.runAsync(() async {
            await session.next();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          for (var i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 60));
          }
          expect(session.currentSegment?.blockIndex, 35);
          expect(scroll.offset, greaterThan(offsetAt20));
          expect(find.textContaining('第35段', findRichText: true), findsWidgets);
          expect(_highlightedSegmentFinder('第35段'), findsOneWidget);

          Navigator.of(tester.element(find.byType(ReaderPage))).pop();
          await tester.pumpAndSettle();
          expect(ListeningNow.instance.active, isTrue);
          expect(identical(ListeningNow.instance.session, session), isTrue);
          expect(ListeningNow.instance.config?.source, 'edge');
          expect(ListeningNow.instance.bookId, 1338);
          expect(ListeningNow.instance.chapterId, 317815);
        },
      );
    } finally {
      await _cleanupAdopted(tester, session, temp);
    }
  });

  testWidgets(
      'ReaderPage in paged mode reclaims ListeningNow session, jumps to spoken page, and highlights spoken block',
      (tester) async {
    late Directory temp;
    late ReaderSpeechSession session;
    await tester.runAsync(() async {
      final started = await _startAndAdoptSession(
        bookId: 1338,
        chapterId: 317815,
      );
      temp = started.temp;
      session = started.session;
    });

    try {
      await fixture.withReader(
        tester,
        paged: true,
        platform: TargetPlatform.android,
        pushReader: true,
        run: (calls, key) async {
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(ListeningNow.instance.active, isFalse);
          expect(session.isStopped, isFalse);
          final controller =
              tester.widget<PageView>(find.byType(PageView)).controller!;
          expect(controller.page, greaterThan(0));
          expect(find.textContaining('第20段', findRichText: true), findsWidgets);
          expect(_highlightedSegmentFinder('第20段'), findsOneWidget);

          Navigator.of(tester.element(find.byType(ReaderPage))).pop();
          await tester.pumpAndSettle();
          expect(ListeningNow.instance.active, isTrue);
          expect(identical(ListeningNow.instance.session, session), isTrue);
        },
      );
    } finally {
      await _cleanupAdopted(tester, session, temp);
    }
  });

  testWidgets(
      'ReaderPage does not reclaim ListeningNow session belonging to a different chapter',
      (tester) async {
    late Directory temp;
    late ReaderSpeechSession session;
    await tester.runAsync(() async {
      final started = await _startAndAdoptSession(
        bookId: 1338,
        chapterId: 999999,
      );
      temp = started.temp;
      session = started.session;
    });

    try {
      await fixture.withReader(
        tester,
        paged: false,
        platform: TargetPlatform.android,
        pushReader: true,
        run: (calls, key) async {
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(ListeningNow.instance.active, isTrue);
          expect(identical(ListeningNow.instance.session, session), isTrue);
          expect(_anyHighlightedBlockFinder(), findsNothing);
          expect(_highlightedSegmentFinder('第20段'), findsNothing);
        },
      );
    } finally {
      await _cleanupAdopted(tester, session, temp);
    }
  });

  test('ListeningNow persists background resume progress and applies updated preferences',
      () async {
    SharedPreferences.setMockInitialValues({});
    final started = await _startAndAdoptSession(
      bookId: 1338,
      chapterId: 317815,
      accountId: 'uid:42',
    );
    final session = started.session;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var saved = await ReaderTtsResumeStore.read(
        accountId: 'uid:42',
        bookId: 1338,
        chapterId: 317815,
      );
      expect(saved?.blockIndex, 20);

      await session.next();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      saved = await ReaderTtsResumeStore.read(
        accountId: 'uid:42',
        bookId: 1338,
        chapterId: 317815,
      );
      expect(saved?.blockIndex, 35);

      await ReaderTtsPreferences.save(
        const ReaderTtsPreferences(
          sourceMode: 'online',
          rate: 1.5,
          segmentInterval: Duration(milliseconds: 250),
          sleepTimer: PlaybackSleepTimer.minutes30,
          edgeVoiceByLanguage: {'chinese': 'zh-CN-YunxiNeural'},
        ),
        accountKey: 'uid:42',
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(session.segmentInterval, const Duration(milliseconds: 250));
      expect(session.sleepTimer, PlaybackSleepTimer.minutes30);
      final edgeVoices =
          ListeningNow.instance.config?.options['voiceByLanguage'] as Map?;
      expect(edgeVoices?['chinese'], 'zh-CN-YunxiNeural');
    } finally {
      await session.stop();
      session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (await started.temp.exists()) {
        await started.temp.delete(recursive: true);
      }
    }
  });

  test('ListeningNow preserves coverUrl across adopt, updateCoverUrl, and take',
      () async {
    final started = await _startAndAdoptSession(
      bookId: 1338,
      chapterId: 317815,
      accountId: 'guest',
    );
    try {
      expect(
        ListeningNow.instance.coverUrl,
        'https://example.com/adopted-cover.jpg',
      );
      ListeningNow.instance.updateCoverUrl(
        'https://example.com/updated-cover.jpg',
        bookId: 1338,
      );
      expect(
        ListeningNow.instance.coverUrl,
        'https://example.com/updated-cover.jpg',
      );
      final transfer = ListeningNow.instance.take(
        bookId: 1338,
        chapterId: 317815,
        accountId: 'guest',
      );
      expect(transfer?.coverUrl, 'https://example.com/updated-cover.jpg');
      expect(ListeningNow.instance.coverUrl, isEmpty);
    } finally {
      await started.session.stop();
      started.session.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      if (await started.temp.exists()) {
        await started.temp.delete(recursive: true);
      }
    }
  });
}
