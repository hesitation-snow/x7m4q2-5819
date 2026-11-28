import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as file;
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/account_access.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/reading_session.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/account_access_page.dart';
import 'package:yomiru/pages/custom_tts_settings_page.dart';
import 'package:yomiru/pages/login_page.dart';
import 'package:yomiru/reader/reader_language_segments.dart' show ReaderLanguageFilter;
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_tts_core.dart';
import 'package:yomiru/services/custom_ssml_tts.dart';
import 'package:yomiru/services/epub/epub_download_service.dart';
import 'package:yomiru/services/epub/epub_models.dart';
import 'package:yomiru/services/illustration_cache_manager.dart';
import 'package:yomiru/services/listening_now.dart';
import 'package:yomiru/services/reading_progress_reporter.dart';
import 'package:yomiru/services/speech_chapter_loader.dart';
import 'package:yomiru/widgets/filtered_list_continuation.dart';
import 'package:yomiru/widgets/listening_dock.dart';
import 'package:yomiru/widgets/topic_picker_sheet.dart';

http.Response _okJson(Object data) => http.Response.bytes(
      utf8.encode(jsonEncode({'code': 0, 'data': data})),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _FakeSpeechSynth implements SpeechAudioSynthesizer {
  @override
  Future<File> synthesize(
    String text,
    SpeechSynthesisConfig config,
    String cachePath,
  ) async {
    final f = File(cachePath);
    await f.parent.create(recursive: true);
    await f.writeAsString(text);
    return f;
  }
}

class _FailingPlayHandler implements SpeechFilesHandler {
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
    throw StateError('audio device failed');
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

class _SilentPlayHandler implements SpeechFilesHandler {
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

class _MemFiles implements cache.FileSystem {
  final fs = MemoryFileSystem();
  @override
  Future<file.File> createFile(String name) async => fs.file('/$name');
}

class _MemRepo extends cache.NonStoringObjectProvider {
  final objects = <String, cache.CacheObject>{};
  int _id = 0;
  @override
  Future<cache.CacheObject?> get(String key) async => objects[key];
  @override
  Future<cache.CacheObject> insert(cache.CacheObject object,
      {bool setTouchedToNow = true}) async {
    final stored = object.copyWith(id: object.id ?? ++_id);
    objects[stored.key] = stored;
    return stored;
  }

  @override
  Future<int> update(cache.CacheObject object,
      {bool setTouchedToNow = true}) async {
    objects[object.key] = object;
    return 1;
  }

  @override
  Future<dynamic> updateOrInsert(cache.CacheObject object) => insert(object);
  @override
  Future<List<cache.CacheObject>> getAllObjects() async =>
      objects.values.toList();
  @override
  Future<int> delete(int id) async {
    objects.removeWhere((_, obj) => obj.id == id);
    return 1;
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    objects.removeWhere((_, obj) => ids.contains(obj.id));
    return ids.length;
  }
}

class _FakeFileResponse implements cache.FileServiceResponse {
  final List<int> bytes;
  _FakeFileResponse(this.bytes);
  @override
  Stream<List<int>> get content => Stream.value(bytes);
  @override
  int get contentLength => bytes.length;
  @override
  int get statusCode => 200;
  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 1));
  @override
  String get fileExtension => '.png';
  @override
  String? get eTag => null;
}

class _FakeFileService extends cache.FileService {
  Completer<void>? gate;
  int calls = 0;
  @override
  Future<cache.FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    calls++;
    if (calls == 1 && gate != null) {
      await gate!.future;
    }
    return _FakeFileResponse(const [1, 2, 3, 4]);
  }
}

class _FakeCustomTts extends CustomSsmlTts {
  @override
  Future<List<AzureSpeechVoice>> listAzureVoices({
    required String endpoint,
    String? locale,
    String? credentialOverride,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    return const [
      AzureSpeechVoice(
        id: 'zh-CN-XiaoxiaoNeural',
        name: 'Xiaoxiao',
        locale: 'zh-CN',
        gender: 'Female',
      ),
    ];
  }

  @override
  Future<void> saveCredential(String credential) async {}

  @override
  Future<void> clearCredential() async {}
}

class _IdlePreviewPlayer implements CustomTtsPreviewPlayer {
  @override
  Future<void> dispose() async {}
  @override
  Future<void> play(Uint8List mp3Bytes) async {}
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  String? storedSecureKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LKApi.client = LKClient.shared;
    LKApi.clearTopicTagsCache();
    LKClient.shared.session.clear();
    await LKClient.shared.clearResponseCache();
    LKClient.sessionRev.value++;
    LKStore.contentCacheEpoch++;
    LKReadingSession.shared.reset();
    EpubDownloadService.shared.currentTask.value = null;
    await ListeningNow.instance.stop();
    storedSecureKey = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      switch (call.method) {
        case 'read':
          return storedSecureKey;
        case 'write':
          storedSecureKey = (call.arguments as Map)['value'] as String?;
          return null;
        case 'delete':
          storedSecureKey = null;
          return null;
      }
      return null;
    });
  });

  tearDown(() async {
    LKApi.client = LKClient.shared;
    LKApi.clearTopicTagsCache();
    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
    LKStore.contentCacheEpoch++;
    LKReadingSession.shared.reset();
    EpubDownloadService.shared.currentTask.value = null;
    await ListeningNow.instance.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  test(
      'LKClient invalidateCacheKey is exact and invalidation blocks stale fallback',
      () async {
    var networkCalls = 0;

    final client = LKClient.forTesting(httpClient: MockClient((request) async {
      networkCalls++;
      return _okJson({'path': request.url.path, 'call': networkCalls});
    }));

    await client.post('/detail/12', {}, cacheKey: 'book_detail_1-12');
    await client.post('/detail/120', {}, cacheKey: 'book_detail_1-120');
    expect(networkCalls, 2);

    await client.invalidateCacheKey('book_detail_1-12');

    // book_detail_1-120 stays cached, book_detail_1-12 re-fetches
    final r120 =
        await client.post('/detail/120', {}, cacheKey: 'book_detail_1-120');
    expect(r120['call'], 2);
    expect(networkCalls, 2);

    SharedPreferences.setMockInitialValues({
      'lk_response_cache_v1_feed_x': jsonEncode({
        'saved_at': 1,
        'data': {'v': 'stale'}
      })
    });
    final holdCall = Completer<http.Response>();
    final client2 = LKClient.forTesting(httpClient: MockClient((_) {
      return holdCall.future;
    }));
    final req = client2.post('/feed', {}, cacheKey: 'feed_x');
    await Future<void>.delayed(Duration.zero);
    await client2.invalidateCachePrefix('feed_');
    holdCall.complete(http.Response('unavailable', 503));
    await expectLater(req, throwsA(isA<LKException>()));
  });

  test('LKClient uploadMultipart wraps parse and timeout failures in LKException',
      () async {
    final temp = await Directory.systemTemp.createTemp('upload_err_');
    final file = File('${temp.path}/img.png')..writeAsBytesSync([1, 2, 3]);
    addTearDown(() => temp.delete(recursive: true));

    final htmlClient = LKClient.forTesting(
      httpClient: MockClient(
        (_) async => http.Response('<html>502</html>', 200),
      ),
    )..session.securityKey = 'k';
    await expectLater(
      htmlClient.uploadMultipart('/api/upload', file.path, const {}),
      throwsA(
        isA<LKException>().having((e) => e.message, 'message', '响应解析失败'),
      ),
    );

    final timeoutClient = LKClient.forTesting(
      httpClient: MockClient(
        (_) => Future<http.Response>.error(TimeoutException('timed out')),
      ),
    )..session.securityKey = 'k';
    await expectLater(
      timeoutClient.uploadMultipart('/api/upload', file.path, const {}),
      throwsA(
        isA<LKException>()
            .having((e) => e.message, 'message', '上传超时，请检查网络后重试'),
      ),
    );
  });

  test(
      'LKStore.save on account switch clears previous user caches and reading session',
      () async {
    SharedPreferences.setMockInitialValues({
      'uid': 1,
      'my_profile_cache_1': 'profile_1',
      'medal_shop_cache_v1_1_default': '{}',
      'lk_response_cache_v1_book_detail_1-1':
          jsonEncode({'saved_at': 1, 'data': {'id': 1}}),
    });
    LKReadingSession.shared.begin(
      bookId: 9,
      volumeId: 1,
      chapterId: 2,
      accountId: 1,
      accountRevision: LKClient.sessionRev.value,
    );
    expect(LKReadingSession.shared.snapshot(), isNotNull);

    LKClient.shared.session
      ..uid = 2
      ..securityKey = 'sec-2'
      ..nickname = 'User2';
    await LKStore.save();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('uid'), 2);
    expect(prefs.containsKey('my_profile_cache_1'), isFalse);
    expect(prefs.containsKey('medal_shop_cache_v1_1_default'), isFalse);
    expect(prefs.containsKey('lk_response_cache_v1_book_detail_1-1'), isFalse);
    expect(LKReadingSession.shared.snapshot(), isNull);
  });

  test(
      'ReadingProgressReporter.flush(force: true) runs after prior heartbeat error',
      () async {
    var now = DateTime(2026, 9, 5);
    final session = LKReadingSession(now: () => now)
      ..begin(
        bookId: 1,
        volumeId: 1,
        chapterId: 1,
        accountId: 10,
        accountRevision: 1,
      );
    final firstSend = Completer<void>();
    final deltas = <int>[];
    var call = 0;
    final reporter = ReadingProgressReporter(
      session: session,
      owner: () => (10, 1),
      send: (_, delta) async {
        call++;
        if (call == 1) return firstSend.future;
        deltas.add(delta);
      },
    );

    now = now.add(const Duration(seconds: 20));
    final firstFlush = reporter.flush(force: false);
    await Future<void>.delayed(Duration.zero);

    now = now.add(const Duration(seconds: 10));
    session.pause();
    final forcedFlush = reporter.flush(force: true);

    firstSend.completeError(StateError('heartbeat failed'));
    await expectLater(firstFlush, throwsStateError);
    await forcedFlush;
    expect(deltas, [30]);
  });

  testWidgets(
      'ListeningNow stops on sessionRev and preserves error banner for ListeningDock/ListeningMenu',
      (tester) async {
    late Directory temp;
    late SpeechAudioCache audioCache;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('listen_err_');
      audioCache = SpeechAudioCache(
        temporaryDirectory: () async => temp,
        budgetBytes: 1024 * 1024,
      );
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await ListeningNow.instance.stop();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
    });

    // 1. sessionRev switch stops active playback
    final s1 = ReaderSpeechSession(
      handler: _SilentPlayHandler(),
      synthesizer: _FakeSpeechSynth(),
      cache: audioCache,
    );
    await tester.runAsync(() async {
      await s1.start(
        const [
          TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 4, text: '测试文本')
        ],
        accountId: '1',
        config: const SpeechSynthesisConfig(
          source: 'edge',
          voice: 'zh-CN-XiaoxiaoNeural',
          language: 'zh-CN',
          rate: 1,
        ),
        title: '测试书籍',
        artist: '第一章',
      );
    });
    ListeningNow.instance.adopt(
      session: s1,
      bookTitle: '测试书籍',
      chapterTitle: '第一章',
      bookId: 10,
      chapterId: 100,
      volumeId: 1,
      accountId: '1',
    );
    expect(ListeningNow.instance.active, isTrue);

    LKClient.sessionRev.value++;
    await tester.pump();
    expect(ListeningNow.instance.active, isFalse);

    // 2. Background error exposes ListeningDock & ListeningMenu error banner
    final s2 = ReaderSpeechSession(
      handler: _FailingPlayHandler(),
      synthesizer: _FakeSpeechSynth(),
      cache: audioCache,
    );
    ListeningNow.instance.adopt(
      session: s2,
      bookTitle: '错误测试书',
      chapterTitle: '第二章',
      bookId: 20,
      chapterId: 200,
      volumeId: 2,
      accountId: '1',
    );
    await tester.runAsync(() async {
      await s2.start(
        const [
          TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 4, text: '失败文本')
        ],
        accountId: '1',
        config: const SpeechSynthesisConfig(
          source: 'edge',
          voice: 'zh-CN-XiaoxiaoNeural',
          language: 'zh-CN',
          rate: 1,
        ),
        title: '错误测试书',
        artist: '第二章',
      );
    });
    expect(ListeningNow.instance.active, isFalse);
    expect(ListeningNow.instance.hasErrorBanner, isTrue);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ListeningDock())),
    );
    await tester.pump();
    expect(find.text('朗读失败，点击查看'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('listening-dock')));
    await tester.pumpAndSettle();
    expect(find.textContaining('朗读失败：'), findsOneWidget);
    expect(find.text('回到阅读'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(ListeningNow.instance.hasErrorBanner, isFalse);
    expect(find.text('朗读失败，点击查看'), findsNothing);
  });

  test(
      'SpeechChapterLoader resolves next chapter across >50 chapter pages when chapterNo is 0',
      () async {
    final result = await SpeechChapterLoader.loadNextChapter(
      bookId: 1,
      currentChapterId: 2001,
      currentVolumeId: 5,
      languageFilter: ReaderLanguageFilter.automatic,
      useContentCache: false,
      isCurrent: () => true,
      fetchVolumes: (_) async => [
        LKVolume(volumeId: 5, title: '长卷', chapterCount: 60),
      ],
      fetchChapterPage: (_, __, page) async {
        if (page == 1) {
          return LKChapterPage(
            items: List.generate(
              50,
              (i) => LKChapter(chapterId: 1000 + i, title: 'Ch ${i + 1}'),
            ),
            page: 1,
            pageSize: 50,
            total: 60,
            hasMore: true,
          );
        }
        return LKChapterPage(
          items: [
            LKChapter(chapterId: 2001, title: 'Ch 51'),
            LKChapter(chapterId: 2002, title: 'Ch 52'),
          ],
          page: 2,
          pageSize: 50,
          total: 60,
          hasMore: false,
        );
      },
      fetchChapterDetail: (_, id) async => LKChapterDetail(
        chapterId: id,
        volumeId: 5,
        title: 'Ch $id',
        chapterNo: 0,
        bodyText: '正文内容 $id',
      ),
    );

    expect(result.status, SpeechNextChapterStatus.loaded);
    expect(result.chapter?.chapterId, 2002);
  });

  test(
      'IllustrationCacheManager.obtain waits for emptyCache instead of failing',
      () async {
    final files = _MemFiles();
    final repo = _MemRepo();
    final service = _FakeFileService()..gate = Completer<void>();
    final manager = IllustrationCacheManager(
      cache.Config(
        'audit_ill_test',
        repo: repo,
        fileSystem: files,
        fileService: service,
      ),
    );
    addTearDown(manager.dispose);

    final firstFuture = manager.obtain('https://example.invalid/a.png');
    await Future<void>.delayed(Duration.zero);
    final clearFuture = manager.emptyCache();
    final secondFuture = manager.obtain('https://example.invalid/b.png');
    service.gate!.complete();

    await clearFuture;
    final firstInfo = await firstFuture;
    final secondInfo = await secondFuture;
    expect(firstInfo, isNull);
    expect(secondInfo, isNotNull);
  });

  testWidgets(
      'FilteredListContinuation and ListContinuation reset cleanly and cap auto-loads',
      (tester) async {
    var filteredCalls = 0;
    var filteredPage = 1;
    var filteredLoading = false;
    late void Function(VoidCallback) outerSetState;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              outerSetState = setState;
              return FilteredListContinuation(
                message: '已过滤',
                hasMore: true,
                loading: filteredLoading,
                pageKey: filteredPage,
                onLoadMore: () {
                  setState(() {
                    filteredCalls++;
                    filteredPage++;
                  });
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(filteredCalls, 2);

    // Simulate pull-to-refresh resetting back to page 1 (loading true -> false)
    outerSetState(() {
      filteredPage = 1;
      filteredLoading = true;
    });
    await tester.pump();
    outerSetState(() {
      filteredLoading = false;
    });
    await tester.pumpAndSettle();
    expect(filteredCalls, 4);

    // ListContinuation caps unbounded auto-loads at 3 & resets on error clear
    var listCalls = 0;
    var listPage = 1;
    String? listError;
    late void Function(VoidCallback) listSetState;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              listSetState = setState;
              return ListContinuation(
                pageKey: listPage,
                loading: false,
                error: listError,
                onLoadMore: () {
                  setState(() {
                    listCalls++;
                    listPage++;
                  });
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(listCalls, 3);

    // Clear error resets auto-load gate (and remains capped at 3)
    listSetState(() => listError = 'err');
    await tester.pump();
    listSetState(() => listError = null);
    await tester.pumpAndSettle();
    expect(listCalls, 6);
  });

  test(
      'EpubDownloadService clears completed task on account switch, protects active temp files, and retries 429',
      () async {
    final tempRoot = await Directory.systemTemp.createTemp('epub_temp_root_');
    final dir = await Directory.systemTemp.createTemp('epub_429_');
    await Directory('${dir.path}/chapters').create();
    await Directory('${dir.path}/images').create();
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return tempRoot.path;
      return null;
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, null);
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    // 1. Account switch clears completed task
    LKClient.shared.session
      ..uid = 10
      ..securityKey = 'k10';
    EpubDownloadService.shared.currentTask.value = const EpubDownloadTask(
      bookId: 50,
      bookTitle: '已完成书籍',
      authorName: '作者',
      ownerUid: 10,
      phase: EpubTaskPhase.completed,
    );
    LKClient.shared.session
      ..uid = 20
      ..securityKey = 'k20';
    LKClient.sessionRev.value++;
    expect(EpubDownloadService.shared.currentTask.value, isNull);

    // 2. clearAllTempFiles() preserves active editingMetadata task files while cleaning everything when includeActiveTask=true
    final activeChapterFile =
        File('${tempRoot.path}/epub_maker/tasks/20_51/chapters/1.json');
    await activeChapterFile.parent.create(recursive: true);
    await activeChapterFile.writeAsString('{"body_text":"keep me"}');
    EpubDownloadService.shared.currentTask.value = const EpubDownloadTask(
      bookId: 51,
      bookTitle: '活跃编辑书',
      authorName: '作者',
      ownerUid: 20,
      phase: EpubTaskPhase.editingMetadata,
    );
    await EpubDownloadService.clearAllTempFiles();
    expect(await activeChapterFile.exists(), isTrue);

    await EpubDownloadService.clearAllTempFiles(includeActiveTask: true);
    expect(await activeChapterFile.exists(), isFalse);
    EpubDownloadService.shared.currentTask.value = null;

    // 3. 429 pauses without adding chapter to failedChapters, so resumeTask retries it
    var attempts = 0;
    final service = EpubDownloadService.forTesting(
      taskDirectory: (_) async => dir,
      chapterDetail: (_, id) async {
        attempts++;
        if (attempts == 1) {
          throw LKException(429, '请求过于频繁');
        }
        return LKChapterDetail(
          chapterId: id,
          volumeId: 1,
          title: '恢复后的章节',
          bodyText: '正文内容',
        );
      },
    );

    const chapter = EpubChapterItem(
      chapterId: 1,
      chapterNo: 1,
      title: '第1章',
      volumeId: 1,
      volumeTitle: '卷1',
    );
    service.startDownloadForTesting(const EpubDownloadTask(
      bookId: 1,
      bookTitle: '限流测试',
      authorName: '作者',
      ownerUid: 0,
      options: EpubExportOptions(includeIllustrations: false),
      phase: EpubTaskPhase.downloadingContent,
      chapters: [chapter],
    ));
    await service.waitForIdleForTesting();
    final paused = service.currentTask.value!;
    expect(paused.phase, EpubTaskPhase.paused);
    expect(paused.failedChapters, isEmpty);

    await service.resumeTask();
    await service.waitForIdleForTesting();
    final finished = service.currentTask.value!;
    expect(attempts, 2);
    expect(finished.completedChapterIds, contains(1));
  });

  testWidgets(
      'TopicPickerSheet shows error and retry when searching uncached keyword offline',
      (tester) async {
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if ((body['q'] ?? '') == '') {
          return _okJson({
            'list': [
              {'topic_tag_id': 1, 'name': '奇幻', 'status': 1},
            ],
          });
        }
        return http.Response('err', 500);
      }),
    );

    // Populate cachedTopicTags
    await LKApi.dynamicTopicTags(q: '');
    expect(LKApi.cachedTopicTags, isNotEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showTopicPickerSheet(context),
                child: const Text('OpenTopics'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('OpenTopics'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('topic-search-input')), '不存在的词');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('暂时无法加载话题'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets(
      'CustomTtsSettingsPage save preserves voices, LoginPage updates on sessionRev, AccountAccessPage shows info tone',
      (tester) async {
    // 1. CustomTtsSettingsPage save preserves Azure voices
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MaterialApp(
        home: CustomTtsSettingsPage(
          tts: _FakeCustomTts(),
          preferences: prefs,
          metadataStorageKey: 'custom_tts_test',
          createPlayer: _IdlePreviewPlayer.new,
          initialConfig: const CustomSsmlTtsConfig(
            endpoint: 'https://eastasia.tts.speech.microsoft.com/cognitiveservices/v1',
            voiceId: 'zh-CN-XiaoxiaoNeural',
            displayName: 'Azure',
            locale: 'zh-CN',
            authMode: CustomTtsAuthMode.azureKey,
            audioFormat: 'audio-24khz-48kbitrate-mono-mp3',
            timeout: Duration(seconds: 30),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey('custom-tts-load-voices')));
    await tester.tap(find.byKey(const ValueKey('custom-tts-load-voices')));
    await tester.pumpAndSettle();
    expect(find.text('选择 Azure 音色'), findsOneWidget);

    await tester.tap(find.byTooltip('保存设置'));
    await tester.pumpAndSettle();
    expect(find.text('选择 Azure 音色'), findsOneWidget);

    // 2. LoginPage reacts to sessionRev
    LKClient.shared.session
      ..uid = 50
      ..securityKey = 'sec-50'
      ..nickname = 'Nick50';
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pumpAndSettle();
    expect(find.text('退出登录(当前: Nick50)'), findsOneWidget);

    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    expect(find.textContaining('退出登录'), findsNothing);

    // 3. AccountAccessPage renders verification code notice with secondaryContainer (not errorContainer)
    final api = AccountAccessApi(
      client: LKClient.forTesting(
        httpClient: MockClient((_) async => _okJson({'registered': false})),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: AccountAccessPage(register: false, api: api)),
    );
    await tester.enterText(find.byType(TextFormField).first, 'user@example.com');
    await tester.tap(find.text('发送验证码'));
    await tester.pumpAndSettle();

    expect(find.text('验证码已发送，请检查邮箱及垃圾邮件'), findsOneWidget);
    final scheme = Theme.of(tester.element(find.text('验证码已发送，请检查邮箱及垃圾邮件'))).colorScheme;
    final bannerContainer = tester.widget<Container>(
      find.ancestor(
        of: find.text('验证码已发送，请检查邮箱及垃圾邮件'),
        matching: find.byType(Container),
      ).first,
    );
    final decoration = bannerContainer.decoration as BoxDecoration;
    expect(decoration.color, equals(scheme.secondaryContainer.withValues(alpha: 0.7)));
  });
}
