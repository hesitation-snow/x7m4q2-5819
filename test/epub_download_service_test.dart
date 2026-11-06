import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/services/epub/epub_download_service.dart';
import 'package:yomiru/services/epub/epub_models.dart';
import 'package:yomiru/services/illustration_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pause/resume worker barrier', () {
    late Directory dir;
    EpubDownloadService? serviceForCleanup;
    const chapter = EpubChapterItem(
        chapterId: 1,
        chapterNo: 1,
        title: 'chapter',
        volumeId: 1,
        volumeTitle: 'volume');
    const task = EpubDownloadTask(
        bookId: 1,
        bookTitle: 'book',
        authorName: 'author',
        ownerUid: 0,
        options: EpubExportOptions(includeIllustrations: false),
        phase: EpubTaskPhase.downloadingContent,
        chapters: [chapter]);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('epub_race_');
      await Directory('${dir.path}/chapters').create();
      await Directory('${dir.path}/images').create();
    });
    tearDown(() async {
      await serviceForCleanup?.waitForIdleForTesting();
      serviceForCleanup = null;
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 300 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue, reason: 'timed out waiting for service');
    }

    test(
        'immediate repeated resume waits for old fetch before starting one worker',
        () async {
      final oldFetch = Completer<LKChapterDetail>();
      final newFetch = Completer<LKChapterDetail>();
      var calls = 0;
      var running = 0;
      var peak = 0;
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async => dir,
        chapterDetail: (_, __) async {
          calls++;
          running++;
          if (running > peak) peak = running;
          try {
            return await (calls == 1 ? oldFetch.future : newFetch.future);
          } finally {
            running--;
          }
        },
      );
      service.startDownloadForTesting(task);
      await until(() => calls == 1);
      final pause = service.pauseTask();
      final resume = service.resumeTask();
      final duplicateResume = service.resumeTask();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 1);
      expect(service.currentTask.value!.phase, EpubTaskPhase.paused);
      oldFetch.complete(
          LKChapterDetail(chapterId: 1, title: 'old', bodyText: 'stale'));
      await Future.wait([pause, resume, duplicateResume]);
      await until(() => calls == 2);
      expect(peak, 1);
      expect(await File('${dir.path}/chapters/1.json').exists(), isFalse);
      newFetch.complete(
          LKChapterDetail(chapterId: 1, title: 'new', bodyText: 'fresh'));
      await until(() =>
          service.currentTask.value!.phase == EpubTaskPhase.editingMetadata);
      expect(service.currentTask.value!.completedChapterIds, {1});
      expect(await File('${dir.path}/chapters/1.json').readAsString(),
          contains('fresh'));
      expect(calls, 2);
    });

    test('resume waits for all parallel chapter workers', () async {
      final old = List.generate(3, (_) => Completer<LKChapterDetail>());
      var calls = 0;
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async => dir,
        chapterDetail: (_, id) {
          final n = calls++;
          if (n < 3) return old[n].future;
          return Future.value(
              LKChapterDetail(chapterId: id, bodyText: 'new $id'));
        },
      );
      final multiTask = task.copyWith(chapters: [
        for (var i = 1; i <= 3; i++)
          EpubChapterItem(
              chapterId: i,
              chapterNo: i,
              title: '$i',
              volumeId: 1,
              volumeTitle: 'v'),
      ]);
      service.startDownloadForTesting(multiTask);
      await until(() => calls == 3);
      final pause = service.pauseTask();
      final resume = service.resumeTask();
      old[0].complete(LKChapterDetail(chapterId: 1, bodyText: 'stale'));
      old[1].complete(LKChapterDetail(chapterId: 2, bodyText: 'stale'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, 3);
      expect(service.currentTask.value!.phase, EpubTaskPhase.paused);
      old[2].complete(LKChapterDetail(chapterId: 3, bodyText: 'stale'));
      await Future.wait([pause, resume]);
      await until(() =>
          service.currentTask.value!.phase == EpubTaskPhase.editingMetadata);
      expect(calls, 6);
      expect(service.currentTask.value!.completedChapterIds, {1, 2, 3});
      for (var i = 1; i <= 3; i++) {
        expect(await File('${dir.path}/chapters/$i.json').readAsString(),
            contains('new $i'));
      }
    });

    test('hanging request times out and resume makes progress', () async {
      final never = Completer<LKChapterDetail>();
      var calls = 0;
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async => dir,
        chapterTimeout: const Duration(milliseconds: 80),
        chapterDetail: (_, __) {
          calls++;
          return calls == 1
              ? never.future
              : Future.value(
                  LKChapterDetail(chapterId: 1, bodyText: 'after timeout'));
        },
      );
      service.startDownloadForTesting(task);
      await until(() => calls == 1);
      await service.pauseTask();
      expect(service.currentTask.value!.phase, EpubTaskPhase.paused);
      await service.resumeTask().timeout(const Duration(seconds: 2));
      await until(() =>
          service.currentTask.value!.phase == EpubTaskPhase.editingMetadata);
      expect(calls, 2);
      never.complete(LKChapterDetail(chapterId: 1, bodyText: 'late'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await File('${dir.path}/chapters/1.json').readAsString(),
          contains('after timeout'));
    });

    test('pause snapshot waits behind an in-flight checkpoint', () async {
      final checkpointEntered = Completer<void>();
      final releaseCheckpoint = Completer<void>();
      final phases = <EpubTaskPhase>[];
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async => dir,
        chapterDetail: (_, __) async =>
            LKChapterDetail(chapterId: 1, bodyText: 'body'),
        beforeCheckpoint: (snapshot) async {
          phases.add(snapshot.phase);
          if (phases.length == 1) {
            checkpointEntered.complete();
            await releaseCheckpoint.future;
          }
        },
      );
      service.startDownloadForTesting(task);
      await checkpointEntered.future.timeout(const Duration(seconds: 2));
      final pause = service.pauseTask();
      final resume = service.resumeTask();
      expect(service.currentTask.value!.phase, EpubTaskPhase.paused);
      releaseCheckpoint.complete();
      await Future.wait([pause, resume]);
      await until(() =>
          service.currentTask.value!.phase == EpubTaskPhase.editingMetadata);
      expect(phases.take(2).toList(),
          [EpubTaskPhase.downloadingContent, EpubTaskPhase.paused]);
      expect(service.currentTask.value!.completedChapterIds, {1});
    });

    test('cancel waits for incomplete export preparation before a new task',
        () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var blockDirectory = true;
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async {
          if (blockDirectory) {
            blockDirectory = false;
            entered.complete();
            await release.future;
          }
          return dir;
        },
        chapterDetail: (_, __) async => LKChapterDetail(),
      );
      service.currentTask.value =
          task.copyWith(phase: EpubTaskPhase.paused, completedChapterIds: {1});
      final export = service.exportCompletedContent();
      await entered.future.timeout(const Duration(seconds: 2));
      final cancel = service.cancelTask();
      await expectLater(
        service.startTask(
            book: LKBook(bookId: 2, title: 'new'),
            selectedVolumes: const [],
            options: const EpubExportOptions()),
        throwsStateError,
      );
      release.complete();
      await Future.wait([export, cancel]).timeout(const Duration(seconds: 2));
      expect(service.currentTask.value!.phase, EpubTaskPhase.canceled);
      await service.startTask(
          book: LKBook(bookId: 2, title: 'new'),
          selectedVolumes: const [],
          options: const EpubExportOptions());
      await service.waitForIdleForTesting();
      expect(service.currentTask.value!.bookId, 2);
      expect(service.currentTask.value!.phase, EpubTaskPhase.failed);
    });

    test('pause during packaging setup keeps the paused phase', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var directoryCalls = 0;
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async {
          directoryCalls++;
          if (directoryCalls == 3) {
            entered.complete();
            await release.future;
          }
          return dir;
        },
        chapterDetail: (_, __) async => LKChapterDetail(),
      );
      service.currentTask.value =
          task.copyWith(phase: EpubTaskPhase.editingMetadata);
      await service.confirmMetadataAndPackage();
      await entered.future.timeout(const Duration(seconds: 2));
      final pause = service.pauseTask();
      release.complete();
      await pause;
      await service.waitForIdleForTesting();
      expect(service.currentTask.value!.phase, EpubTaskPhase.paused);
      expect(service.currentTask.value!.statusMessage, '制作已暂停');
    });

    test('cancel during metadata checkpoint cannot restart packaging',
        () async {
      final checkpointEntered = Completer<void>();
      final releaseCheckpoint = Completer<void>();
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async => dir,
        chapterDetail: (_, __) async => LKChapterDetail(),
        beforeCheckpoint: (snapshot) async {
          if (snapshot.phase == EpubTaskPhase.packaging) {
            checkpointEntered.complete();
            await releaseCheckpoint.future;
          }
        },
      );
      service.currentTask.value =
          task.copyWith(phase: EpubTaskPhase.editingMetadata);
      final confirm = service.confirmMetadataAndPackage();
      await checkpointEntered.future.timeout(const Duration(seconds: 2));
      final cancel = service.cancelTask();
      expect(service.currentTask.value!.phase, EpubTaskPhase.canceled);
      releaseCheckpoint.complete();
      await Future.wait([confirm, cancel]).timeout(const Duration(seconds: 2));
      await service.waitForIdleForTesting();
      expect(service.currentTask.value!.phase, EpubTaskPhase.canceled);
      expect(await dir.exists(), isFalse);
    });

    test(
        'cancel while resume is waiting preserves cancellation and deletes files',
        () async {
      final fetch = Completer<LKChapterDetail>();
      var calls = 0;
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async => dir,
        chapterDetail: (_, __) {
          calls++;
          return fetch.future;
        },
      );
      service.startDownloadForTesting(task);
      await until(() => calls == 1);
      final pause = service.pauseTask();
      final resume = service.resumeTask();
      final cancel = service.cancelTask();
      fetch.complete(LKChapterDetail(chapterId: 1, bodyText: 'late'));
      await Future.wait([pause, resume, cancel]);
      expect(service.currentTask.value!.phase, EpubTaskPhase.canceled);
      expect(await dir.exists(), isFalse);
      expect(calls, 1);
    });

    test(
        'failure from paused fetch is ignored; failure after resume is retained',
        () async {
      final oldFetch = Completer<LKChapterDetail>();
      var calls = 0;
      final service = serviceForCleanup = EpubDownloadService.forTesting(
        taskDirectory: (_) async => dir,
        chapterDetail: (_, __) {
          calls++;
          if (calls == 1) return oldFetch.future;
          throw LKException(403, 'denied', accessRestricted: true);
        },
      );
      service.startDownloadForTesting(task);
      await until(() => calls == 1);
      final pause = service.pauseTask();
      final resume = service.resumeTask();
      oldFetch
          .completeError(LKException(403, 'old error', accessRestricted: true));
      await Future.wait([pause, resume]);
      await until(() =>
          service.currentTask.value!.phase == EpubTaskPhase.paused &&
          calls == 2);
      expect(service.currentTask.value!.failedChapters[1], contains('无权限'));
      expect(service.currentTask.value!.completedCount, 0);
    });
  });

  group('EpubDownloadService Logic & Concurrency Tests', () {
    test('EpubChapterItem models serialization and deserialization', () {
      const item = EpubChapterItem(
        chapterId: 888,
        chapterNo: 1,
        title: '测试章节',
        volumeId: 10,
        volumeTitle: '第 1 卷',
        locked: true,
        unlocked: false,
        braveRequired: true,
      );

      final json = item.toJson();
      final revived = EpubChapterItem.fromJson(json);

      expect(revived.chapterId, equals(888));
      expect(revived.chapterNo, equals(1));
      expect(revived.title, equals('测试章节'));
      expect(revived.volumeId, equals(10));
      expect(revived.volumeTitle, equals('第 1 卷'));
      expect(revived.locked, isTrue);
      expect(revived.unlocked, isFalse);
      expect(revived.braveRequired, isTrue);
    });

    test('EpubDownloadTask tracks progress, counts and terminal states', () {
      const task = EpubDownloadTask(
        bookId: 1001,
        bookTitle: '测试书',
        authorName: '测试作者',
        ownerUid: 999,
        chapters: [
          EpubChapterItem(
              chapterId: 1,
              chapterNo: 1,
              title: '第1章',
              volumeId: 1,
              volumeTitle: '卷1'),
          EpubChapterItem(
              chapterId: 2,
              chapterNo: 2,
              title: '第2章',
              volumeId: 1,
              volumeTitle: '卷1'),
          EpubChapterItem(
              chapterId: 3,
              chapterNo: 3,
              title: '第3章',
              volumeId: 1,
              volumeTitle: '卷1'),
          EpubChapterItem(
              chapterId: 4,
              chapterNo: 4,
              title: '第4章',
              volumeId: 1,
              volumeTitle: '卷1'),
        ],
        completedChapterIds: {1, 2},
        failedChapters: {3: '无权限访问'},
      );

      expect(task.totalChapters, equals(4));
      expect(task.completedCount, equals(2));
      expect(task.failedCount, equals(1));
      expect(task.downloadProgress, equals(0.5));
      expect(task.isTerminal, isFalse);
    });

    test('Concurrency limiter enforces maximum concurrent executions of 2',
        () async {
      var running = 0;
      var peakRunning = 0;
      var allowJobsToFinish = false;

      final limiter = ConcurrencyLimiter(2);

      Future<void> mockNetworkJob() async {
        running++;
        if (running > peakRunning) {
          peakRunning = running;
        }
        while (!allowJobsToFinish) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        running--;
      }

      final activeJobs = List.generate(6, (_) => limiter.run(mockNetworkJob));

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(running, equals(2));
      expect(peakRunning, equals(2));
      expect(limiter.currentRunning, equals(2));

      allowJobsToFinish = true;
      await Future.wait(activeJobs);
      expect(peakRunning, equals(2));
      expect(running, equals(0));
      expect(limiter.currentRunning, equals(0));
    });

    test('Catalog deduplication and ordering maintains official reading order',
        () {
      // 模拟两页返回中存在重复章节以及不同卷的情况
      final page1 = [
        LKChapter(chapterId: 10, chapterNo: 1, title: '第1章'),
        LKChapter(chapterId: 11, chapterNo: 2, title: '第2章'),
        LKChapter(chapterId: 12, chapterNo: 3, title: '第3章'),
      ];
      final page2 = [
        LKChapter(chapterId: 12, chapterNo: 3, title: '第3章(重复)'),
        LKChapter(chapterId: 13, chapterNo: 4, title: '第4章'),
      ];

      final collected = <EpubChapterItem>[];
      final seenIds = <int>{};

      for (final ch in [...page1, ...page2]) {
        if (ch.chapterId > 0 && seenIds.add(ch.chapterId)) {
          collected.add(EpubChapterItem(
            chapterId: ch.chapterId,
            chapterNo: ch.chapterNo,
            title: ch.title,
            volumeId: 1,
            volumeTitle: '第 1 卷',
          ));
        }
      }

      expect(collected.length, equals(4));
      expect(
          collected.map((c) => c.chapterId).toList(), equals([10, 11, 12, 13]));
      expect(collected[2].title, equals('第3章')); // 保留首次出现的正规项
    });

    test(
        'Unauthorized chapters are recorded in failure list without crashing task',
        () {
      const task = EpubDownloadTask(
        bookId: 101,
        bookTitle: '勇者小说',
        authorName: '测试作者',
        ownerUid: 123,
        chapters: [
          EpubChapterItem(
              chapterId: 1,
              chapterNo: 1,
              title: '公开试读章',
              volumeId: 1,
              volumeTitle: '卷1'),
          EpubChapterItem(
              chapterId: 2,
              chapterNo: 2,
              title: '勇者专享章',
              volumeId: 1,
              volumeTitle: '卷1',
              braveRequired: true),
        ],
      );

      final completed = <int>{1};
      final failed = <int, String>{
        2: '无权限或需要勇者等级',
      };

      final updated = task.copyWith(
        completedChapterIds: completed,
        failedChapters: failed,
      );

      expect(updated.completedCount, equals(1));
      expect(updated.failedCount, equals(1));
      expect(updated.failedChapters[2], contains('无权限'));
    });

    test('extractImageUrls properly extracts and unescapes illustration urls',
        () {
      const html = '''
        <p>正文段落</p>
        <img src="https://api.lightnovel.fun/upload-files/images/260731/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg?m=abc&amp;t=1700000000" />
        <img class="lazy" src='https://api.lightnovel.fun/upload-files/images/260731/c44ecc6d854642742676d5226c9cb343.jpg' width="400" />
        <p>后文</p>
      ''';

      final urls = YomiruIllustrationCache.extractImageUrls(html);
      expect(urls.length, equals(2));
      expect(
          urls[0],
          equals(
              'https://api.lightnovel.fun/upload-files/images/260731/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg?m=abc&t=1700000000'));
      expect(
          urls[1],
          equals(
              'https://api.lightnovel.fun/upload-files/images/260731/c44ecc6d854642742676d5226c9cb343.jpg'));
    });

    test('computeDefaultEpubTitle formats preset title strictly as 书名  [卷名]',
        () {
      // 单卷情况
      final singleVol = [
        LKVolume(volumeId: 1, title: '第一卷 地位向上篇'),
      ];
      expect(
        computeDefaultEpubTitle('关于我转生成为史莱姆的那件事', singleVol),
        equals('关于我转生成为史莱姆的那件事  [第一卷 地位向上篇]'),
      );

      // 单卷标题为空回退为 [正文]
      final emptyTitleVol = [
        LKVolume(volumeId: 1, title: ''),
      ];
      expect(
        computeDefaultEpubTitle('无头骑士异闻录', emptyTitleVol),
        equals('无头骑士异闻录  [正文]'),
      );

      // 多卷情况（首卷与末卷）
      final multiVol = [
        LKVolume(volumeId: 1, title: '第一卷'),
        LKVolume(volumeId: 2, title: '第二卷'),
        LKVolume(volumeId: 3, title: '第三卷'),
      ];
      expect(
        computeDefaultEpubTitle('加速世界', multiVol),
        equals('加速世界  [第一卷 - 第三卷]'),
      );

      // 空列表
      expect(
        computeDefaultEpubTitle('狼与香辛料', const []),
        equals('狼与香辛料'),
      );
    });

    test(
        'EpubDownloadTask supports custom metadata, speed and illustration progress',
        () {
      const task = EpubDownloadTask(
        bookId: 88,
        bookTitle: '原始书名',
        authorName: '作者',
        ownerUid: 1,
        phase: EpubTaskPhase.editingMetadata,
        customTitle: '原始书名  [自定义卷名]',
        customCoverPath: '/tmp/test_cover.jpg',
        availableIllustrationPaths: ['/tmp/img1.jpg', '/tmp/img2.jpg'],
        illustrationDownloadedCount: 15,
        currentIllustrationIndex: 2,
        currentIllustrationTotal: 5,
        speedText: '420.5 KB/s',
      );

      expect(task.effectiveTitle, equals('原始书名  [自定义卷名]'));
      expect(task.customCoverPath, equals('/tmp/test_cover.jpg'));
      expect(task.availableIllustrationPaths.length, equals(2));
      expect(task.illustrationDownloadedCount, equals(15));
      expect(task.currentIllustrationIndex, equals(2));
      expect(task.currentIllustrationTotal, equals(5));
      expect(task.speedText, equals('420.5 KB/s'));
      expect(task.isRunning, isTrue);

      final json = task.toJson();
      expect(json['custom_title'], equals('原始书名  [自定义卷名]'));
      expect(json['custom_cover_path'], equals('/tmp/test_cover.jpg'));
      expect(json['available_illustration_paths'], contains('/tmp/img1.jpg'));
      expect(json['illustration_downloaded_count'], equals(15));
      expect(json['current_illustration_index'], equals(2));
      expect(json['current_illustration_total'], equals(5));
      expect(json['speed_text'], equals('420.5 KB/s'));
    });

    test(
        'EpubDownloadTask preserves publisherUid and exporterUid across serialization',
        () {
      const task = EpubDownloadTask(
        bookId: 88,
        bookTitle: '原始书名',
        authorName: '作者',
        publisherUid: 123456,
        ownerUid: 654321,
        phase: EpubTaskPhase.paused,
      );

      expect(task.publisherUid, equals(123456));
      expect(task.ownerUid, equals(654321));
      expect(task.exporterUid, equals(654321));

      final json = task.toJson();
      expect(json['publisher_uid'], equals(123456));
      expect(json['owner_uid'], equals(654321));
      expect(json['exporter_uid'], equals(654321));

      final restored = EpubDownloadTask.fromJson(json);
      expect(restored.publisherUid, equals(123456));
      expect(restored.ownerUid, equals(654321));
      expect(restored.exporterUid, equals(654321));
    });

    test(
        'resumeTask validates account ownership and rejects mismatched account',
        () async {
      final service = EpubDownloadService.shared;

      // 模拟任务创建时的绑定账号 654321
      const task = EpubDownloadTask(
        bookId: 88,
        bookTitle: '原始书名',
        authorName: '作者',
        publisherUid: 123456,
        ownerUid: 654321,
        phase: EpubTaskPhase.paused,
      );
      service.currentTask.value = task;

      // 当前登录账号切换为 999999
      LKClient.shared.session.securityKey = 'fake_key';
      LKClient.shared.session.uid = 999999;

      // 尝试恢复任务
      await service.resumeTask();

      // 任务应该被终止并标记为失败，而不是以新账号继续
      final current = service.currentTask.value;
      expect(current, isNotNull);
      expect(current!.phase, equals(EpubTaskPhase.failed));
      expect(current.statusMessage, contains('账号已切换'));

      // 清理会话
      LKClient.shared.session.clear();
      service.currentTask.value = null;
    });
  });
}
