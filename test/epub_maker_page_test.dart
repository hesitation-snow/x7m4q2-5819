import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/epub_maker_page.dart';
import 'package:yomiru/services/epub/epub_download_service.dart';
import 'package:yomiru/services/epub/epub_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = false;
    EpubDownloadService.shared.currentTask.value = null;
  });

  testWidgets('EpubMakerPage renders volumes and updates chapter summary', (tester) async {
    final book = LKBook(
      bookId: 999,
      title: '关于我转生成为史莱姆的那件事',
      authorName: '伏濑',
    );

    final volumes = [
      LKVolume(volumeId: 1, title: '第一卷 地位向上篇', chapterCount: 10),
      LKVolume(volumeId: 2, title: '第二卷 森林骚乱篇', chapterCount: 15),
      LKVolume(volumeId: 3, title: '第三卷 魔王袭来篇', chapterCount: 20),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: EpubMakerPage(
          book: book,
          initialVolumes: volumes,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 验证书名展示
    expect(find.text('关于我转生成为史莱姆的那件事'), findsOneWidget);
    expect(find.text('作者：伏濑'), findsOneWidget);

    // 默认全选 3 卷，总共 10+15+20 = 45 章
    expect(find.text('已选择 3 卷 · 45 章'), findsOneWidget);
    expect(find.text('开始制作'), findsOneWidget);

    // 点击“清空”
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.text('已选择 0 卷 · 0 章'), findsOneWidget);

    // 单选第一卷
    await tester.tap(find.text('第一卷 地位向上篇'));
    await tester.pumpAndSettle();

    expect(find.text('已选择 1 卷 · 10 章'), findsOneWidget);
  });

  testWidgets('EpubMakerPage prompts confirmation when dataSaverMode is active', (tester) async {
    LKStore.dataSaverMode.value = true;

    final book = LKBook(bookId: 100, title: '测试书名');
    final volumes = [
      LKVolume(volumeId: 1, title: '第一卷', chapterCount: 5),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: EpubMakerPage(
          book: book,
          initialVolumes: volumes,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 处于省流模式时，插画默认关闭
    expect(find.text('仅纯文本正文'), findsOneWidget);

    // 点击切换打开插画开关
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    // 应弹出流量提示对话框
    expect(find.text('流量提醒'), findsOneWidget);
    expect(find.text('当前已开启流量节省模式。下载包含插画的 EPUB 将消耗额外的网络流量，是否确认开启？'), findsOneWidget);

    // 点击确认开启
    await tester.tap(find.text('确认开启'));
    await tester.pumpAndSettle();

    expect(find.text('包含封面与插画'), findsWidgets);
  });

  testWidgets('EpubMakerPage renders 4-step progress and controls during active task', (tester) async {
    final book = LKBook(bookId: 200, title: '长篇巨作');
    final volumes = [LKVolume(volumeId: 1, title: '第1卷', chapterCount: 20)];

    // 设置进行中任务状态
    EpubDownloadService.shared.currentTask.value = EpubDownloadTask(
      bookId: 200,
      bookTitle: '长篇巨作',
      authorName: '名作家',
      ownerUid: 1,
      phase: EpubTaskPhase.downloadingContent,
      statusMessage: '正在下载: 第 5 章',
      chapters: List.generate(
        10,
        (i) => EpubChapterItem(
          chapterId: i + 1,
          chapterNo: i + 1,
          title: '第 ${i + 1} 章',
          volumeId: 1,
          volumeTitle: '第1卷',
        ),
      ),
      completedChapterIds: const {1, 2, 3, 4},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EpubMakerPage(
          book: book,
          initialVolumes: volumes,
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 验证 4 阶段步进标签存在
    expect(find.text('获取目录'), findsOneWidget);
    expect(find.text('正文插画'), findsOneWidget);
    expect(find.text('制作文件'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    // 验证进度卡片与章节数
    expect(find.text('正在下载: 第 5 章'), findsOneWidget);
    expect(find.text('已完成 4 / 10 章'), findsOneWidget);
    expect(find.text('40.0%'), findsOneWidget);

    // 验证控制按钮
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('取消制作'), findsOneWidget);
  });
}
