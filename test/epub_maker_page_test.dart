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

    // 默认不全选，初始为 0 卷 · 0 章
    expect(find.text('已选择 0 卷 · 0 章'), findsOneWidget);
    expect(find.text('开始制作'), findsOneWidget);

    // 点击“全选”
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    // 全选 3 卷，总共 10+15+20 = 45 章
    expect(find.text('已选择 3 卷 · 45 章'), findsOneWidget);

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
    await tester.tap(find.widgetWithText(SwitchListTile, '包含封面与插画'));
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

    // 验证 5 阶段步进标签存在
    expect(find.text('获取目录'), findsOneWidget);
    expect(find.text('正文插画'), findsOneWidget);
    expect(find.text('封面标题'), findsOneWidget);
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

  testWidgets('EpubMakerPage renders illustration progress and speed during downloadingContent', (tester) async {
    final book = LKBook(bookId: 201, title: '带插画巨作');
    final volumes = [LKVolume(volumeId: 1, title: '第1卷', chapterCount: 5)];

    EpubDownloadService.shared.currentTask.value = EpubDownloadTask(
      bookId: 201,
      bookTitle: '带插画巨作',
      authorName: '名作家',
      ownerUid: 1,
      options: const EpubExportOptions(includeIllustrations: true),
      phase: EpubTaskPhase.downloadingContent,
      statusMessage: '正在下载插画 (2/5): 第 1 章 · 350.5 KB/s',
      chapters: List.generate(
        5,
        (i) => EpubChapterItem(
          chapterId: i + 1,
          chapterNo: i + 1,
          title: '第 ${i + 1} 章',
          volumeId: 1,
          volumeTitle: '第1卷',
        ),
      ),
      completedChapterIds: const {1},
      illustrationDownloadedCount: 6,
      currentIllustrationIndex: 2,
      currentIllustrationTotal: 5,
      speedText: '350.5 KB/s',
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

    expect(find.text('正在下载插画 (2/5): 第 1 章 · 350.5 KB/s'), findsOneWidget);
    expect(find.text('插画: 第 2 / 5 张 · 累计 6 张'), findsOneWidget);
    expect(find.text('350.5 KB/s'), findsOneWidget);
  });

  testWidgets('EpubMakerPage renders editingMetadata view with preset title and cover selection', (tester) async {
    final book = LKBook(bookId: 300, title: '魔法禁书目录', authorName: '镰池和马');
    final volumes = [
      LKVolume(volumeId: 10, title: '旧约 第一卷', chapterCount: 8),
    ];

    // 设置编辑封面与标题阶段任务
    EpubDownloadService.shared.currentTask.value = EpubDownloadTask(
      bookId: 300,
      bookTitle: '魔法禁书目录',
      authorName: '镰池和马',
      ownerUid: 1,
      selectedVolumes: volumes,
      phase: EpubTaskPhase.editingMetadata,
      statusMessage: '正文与插画下载完成，请确认封面与文件标题',
      customTitle: '魔法禁书目录  [旧约 第一卷]',
      availableIllustrationPaths: const ['/tmp/art_01.jpg', '/tmp/art_02.jpg'],
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

    // 验证 5 步进度条在第 3 步（封面标题）
    expect(find.text('获取目录'), findsOneWidget);
    expect(find.text('正文插画'), findsOneWidget);
    expect(find.text('封面标题'), findsOneWidget);
    expect(find.text('制作文件'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);

    // 验证标题输入框包含预设值
    expect(find.text('魔法禁书目录  [旧约 第一卷]'), findsOneWidget);
    expect(find.text('文件与书籍标题'), findsOneWidget);

    // 验证封面区域
    expect(find.text('电子书封面'), findsOneWidget);
    expect(find.text('当前封面'), findsOneWidget);
    expect(find.text('默认封面'), findsOneWidget);
    expect(find.text('自选本机'), findsOneWidget);
    expect(find.text('插画 1'), findsOneWidget);
    expect(find.text('插画 2'), findsOneWidget);

    // 验证底部操作按钮
    expect(find.text('取消制作'), findsOneWidget);
    expect(find.text('确认并生成 EPUB'), findsOneWidget);

    // 验证账号标识告知卡片
    expect(find.text('导出的 EPUB 元数据中包含可还原的发布者与当前导出账号 UID 标识'), findsOneWidget);

    // 修改标题输入框
    await tester.enterText(find.byType(TextField), '自定义测试标题');
    await tester.pumpAndSettle();
    expect(find.text('自定义测试标题'), findsOneWidget);

    // 点击“恢复预设”按钮
    await tester.tap(find.byTooltip('恢复预设标题'));
    await tester.pumpAndSettle();
    expect(find.text('魔法禁书目录  [旧约 第一卷]'), findsOneWidget);

    // 滚动并点击插画 1 切换封面
    await tester.ensureVisible(find.text('插画 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('插画 1'));
    await tester.pumpAndSettle();
  });

  testWidgets('EpubMakerPage handles TXT pure text export toggle and editing view', (tester) async {
    final book = LKBook(bookId: 400, title: '纯文本轻小说', authorName: '作家A');
    final volumes = [
      LKVolume(volumeId: 1, title: '第一卷', chapterCount: 3),
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

    // 默认未开启 TXT 导出
    expect(find.text('仅文本（保存为 TXT）'), findsOneWidget);
    expect(find.text('包含封面与插画'), findsWidgets);

    // 打开“仅文本（保存为 TXT）”
    await tester.tap(find.widgetWithText(SwitchListTile, '仅文本（保存为 TXT）'));
    await tester.pumpAndSettle();

    // 插画开关变灰提示不支持，底部文案更新
    expect(find.text('TXT 纯文本格式不支持图片与插画'), findsOneWidget);
    expect(find.text('导出为 TXT 纯文本'), findsOneWidget);

    // 模拟进入 TXT 模式的 editingMetadata 阶段
    EpubDownloadService.shared.currentTask.value = EpubDownloadTask(
      bookId: 400,
      bookTitle: '纯文本轻小说',
      authorName: '作家A',
      ownerUid: 1,
      selectedVolumes: volumes,
      options: const EpubExportOptions(exportAsTxt: true, includeIllustrations: false),
      phase: EpubTaskPhase.editingMetadata,
      statusMessage: '正文下载完成，请确认文件标题',
      customTitle: '纯文本轻小说  [第一卷]',
    );

    await tester.pumpAndSettle();

    // 步骤标签显示 TXT 专用文本
    expect(find.text('确认标题'), findsOneWidget);
    expect(find.text('TXT 标题'), findsOneWidget);
    // 不应展示电子书封面选择卡片
    expect(find.text('电子书封面'), findsNothing);
    // 底部生成按钮为 TXT
    expect(find.text('确认并生成 TXT'), findsOneWidget);
  });

  testWidgets('EpubMakerPage completed view renders separate save as file and share buttons', (tester) async {
    final book = LKBook(bookId: 500, title: '完成测试作品', authorName: '作者B');
    final volumes = [
      LKVolume(volumeId: 1, title: '第一卷', chapterCount: 5),
    ];

    EpubDownloadService.shared.currentTask.value = const EpubDownloadTask(
      bookId: 500,
      bookTitle: '完成测试作品',
      authorName: '作者B',
      ownerUid: 1,
      phase: EpubTaskPhase.completed,
      statusMessage: '制作完成',
      outputPath: '/fake/path/book.epub',
      outputSizeBytes: 1024 * 1024 * 2, // 2MB
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

    expect(find.text('EPUB 制作完成'), findsOneWidget);
    expect(find.text('book.epub'), findsOneWidget);
    expect(find.text('文件大小：2.00 MB'), findsOneWidget);
    expect(find.text('另存为文件'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('清理临时文件并退出'), findsOneWidget);
  });
}
