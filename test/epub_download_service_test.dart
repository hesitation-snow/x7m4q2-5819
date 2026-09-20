import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/services/epub/epub_download_service.dart';
import 'package:yomiru/services/epub/epub_models.dart';
import 'package:yomiru/services/illustration_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
          EpubChapterItem(chapterId: 1, chapterNo: 1, title: '第1章', volumeId: 1, volumeTitle: '卷1'),
          EpubChapterItem(chapterId: 2, chapterNo: 2, title: '第2章', volumeId: 1, volumeTitle: '卷1'),
          EpubChapterItem(chapterId: 3, chapterNo: 3, title: '第3章', volumeId: 1, volumeTitle: '卷1'),
          EpubChapterItem(chapterId: 4, chapterNo: 4, title: '第4章', volumeId: 1, volumeTitle: '卷1'),
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

    test('Concurrency limiter enforces maximum concurrent executions of 2', () async {
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

    test('Catalog deduplication and ordering maintains official reading order', () {
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
      expect(collected.map((c) => c.chapterId).toList(), equals([10, 11, 12, 13]));
      expect(collected[2].title, equals('第3章')); // 保留首次出现的正规项
    });

    test('Unauthorized chapters are recorded in failure list without crashing task', () {
      const task = EpubDownloadTask(
        bookId: 101,
        bookTitle: '勇者小说',
        authorName: '测试作者',
        ownerUid: 123,
        chapters: [
          EpubChapterItem(chapterId: 1, chapterNo: 1, title: '公开试读章', volumeId: 1, volumeTitle: '卷1'),
          EpubChapterItem(chapterId: 2, chapterNo: 2, title: '勇者专享章', volumeId: 1, volumeTitle: '卷1', braveRequired: true),
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

    test('extractImageUrls properly extracts and unescapes illustration urls', () {
      const html = '''
        <p>正文段落</p>
        <img src="https://api.lightnovel.fun/upload-files/images/260731/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg?m=abc&amp;t=1700000000" />
        <img class="lazy" src='https://api.lightnovel.fun/upload-files/images/260731/c44ecc6d854642742676d5226c9cb343.jpg' width="400" />
        <p>后文</p>
      ''';

      final urls = YomiruIllustrationCache.extractImageUrls(html);
      expect(urls.length, equals(2));
      expect(urls[0], equals('https://api.lightnovel.fun/upload-files/images/260731/6bda583f9cf992ba5ab8b0e6f2773cf0.jpg?m=abc&t=1700000000'));
      expect(urls[1], equals('https://api.lightnovel.fun/upload-files/images/260731/c44ecc6d854642742676d5226c9cb343.jpg'));
    });

    test('computeDefaultEpubTitle formats preset title strictly as [书名]  [卷名]', () {
      // 单卷情况
      final singleVol = [
        LKVolume(volumeId: 1, title: '第一卷 地位向上篇'),
      ];
      expect(
        computeDefaultEpubTitle('关于我转生成为史莱姆的那件事', singleVol),
        equals('[关于我转生成为史莱姆的那件事]  [第一卷 地位向上篇]'),
      );

      // 单卷标题为空回退为 [正文]
      final emptyTitleVol = [
        LKVolume(volumeId: 1, title: ''),
      ];
      expect(
        computeDefaultEpubTitle('无头骑士异闻录', emptyTitleVol),
        equals('[无头骑士异闻录]  [正文]'),
      );

      // 多卷情况（首卷与末卷）
      final multiVol = [
        LKVolume(volumeId: 1, title: '第一卷'),
        LKVolume(volumeId: 2, title: '第二卷'),
        LKVolume(volumeId: 3, title: '第三卷'),
      ];
      expect(
        computeDefaultEpubTitle('加速世界', multiVol),
        equals('[加速世界]  [第一卷 - 第三卷]'),
      );

      // 空列表
      expect(
        computeDefaultEpubTitle('狼与香辛料', const []),
        equals('[狼与香辛料]'),
      );
    });

    test('EpubDownloadTask supports custom metadata and effectiveTitle resolution', () {
      const task = EpubDownloadTask(
        bookId: 88,
        bookTitle: '原始书名',
        authorName: '作者',
        ownerUid: 1,
        phase: EpubTaskPhase.editingMetadata,
        customTitle: '[原始书名]  [自定义卷名]',
        customCoverPath: '/tmp/test_cover.jpg',
        availableIllustrationPaths: ['/tmp/img1.jpg', '/tmp/img2.jpg'],
      );

      expect(task.effectiveTitle, equals('[原始书名]  [自定义卷名]'));
      expect(task.customCoverPath, equals('/tmp/test_cover.jpg'));
      expect(task.availableIllustrationPaths.length, equals(2));
      expect(task.isRunning, isTrue);

      final json = task.toJson();
      expect(json['custom_title'], equals('[原始书名]  [自定义卷名]'));
      expect(json['custom_cover_path'], equals('/tmp/test_cover.jpg'));
      expect(json['available_illustration_paths'], contains('/tmp/img1.jpg'));
    });
  });
}
