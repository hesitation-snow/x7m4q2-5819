import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/widgets/reader_listening_sheet.dart';

void main() {
  const previewKey = ValueKey('listening-ui-preview');

  Future<void> mount(WidgetTester tester,
      {Size size = const Size(400, 850),
      double scale = 1,
      Brightness brightness = Brightness.light,
      String status = '正在朗读 · 第 3/18 段',
      bool loading = false,
      bool hasError = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var source = 'system';
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          useMaterial3: true,
          fontFamily: Platform.environment['YOMIRU_CAPTURE_UI'] == 'true'
              ? 'PreviewCjk'
              : null,
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF607566), brightness: brightness)),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: RepaintBoundary(
        key: previewKey,
        child: Scaffold(
            backgroundColor: const Color(0xFFF5F2EB),
            body: Align(
                alignment: Alignment.bottomCenter,
                child: Material(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(28)),
                    clipBehavior: Clip.antiAlias,
                    child: StatefulBuilder(
                        builder: (context, update) => ReaderListeningSheet(
                              onClose: () {},
                              controls: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    IconButton.filledTonal(
                                        tooltip: '上一段',
                                        onPressed: () {},
                                        icon: const Icon(
                                            Icons.skip_previous_rounded)),
                                    const SizedBox(width: 8),
                                    IconButton.filled(
                                        tooltip: '暂停朗读',
                                        onPressed: () {},
                                        icon: const Icon(Icons.pause_rounded),
                                        iconSize: 32,
                                        style: IconButton.styleFrom(
                                            minimumSize: const Size(64, 56))),
                                    const SizedBox(width: 8),
                                    IconButton.filledTonal(
                                        tooltip: '下一段',
                                        onPressed: () {},
                                        icon: const Icon(
                                            Icons.skip_next_rounded)),
                                    const SizedBox(width: 8),
                                    IconButton.filledTonal(
                                        tooltip: '停止朗读',
                                        onPressed: () {},
                                        icon: const Icon(Icons.stop_rounded)),
                                  ]),
                              content: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    ListeningPlaybackCard(
                                        title: '午后的图书馆 · 第一章',
                                        status: status,
                                        position: 2,
                                        segmentCount: 18,
                                        loading: loading,
                                        hasError: hasError,
                                        text:
                                            '阳光透过窗边的树叶，落在翻开的书页上。她放轻了声音，继续读着那个尚未结束的故事。'),
                                    const SizedBox(height: 16),
                                    const Text('语速 1.00×'),
                                    Slider(
                                        value: 1,
                                        min: .5,
                                        max: 3,
                                        onChanged: (_) {}),
                                    ListeningSection(
                                        title: '语音来源',
                                        child: ListeningSourcePicker(
                                            value: source,
                                            onChanged: (value) =>
                                                update(() => source = value))),
                                    ListeningSection(
                                        title: '音色与引擎',
                                        child: Column(children: [
                                          const TextField(
                                              readOnly: true,
                                              decoration: InputDecoration(
                                                  labelText: '系统朗读引擎',
                                                  hintText: '系统默认引擎',
                                                  border:
                                                      OutlineInputBorder())),
                                          const SizedBox(height: 12),
                                          const TextField(
                                              readOnly: true,
                                              decoration: InputDecoration(
                                                  labelText: '系统语音',
                                                  hintText: '中文 · 使用已安装的音色',
                                                  border:
                                                      OutlineInputBorder())),
                                          for (var i = 0; i < 6; i++)
                                            ListTile(title: Text('高级选项 $i')),
                                        ])),
                                  ]),
                            ))))),
      ),
    ));
    await tester.pump();
  }

  testWidgets('controls stay reachable before and after scrolling the settings',
      (tester) async {
    await mount(tester);
    final before = tester.getRect(find.byTooltip('暂停朗读'));
    expect(find.byTooltip('停止朗读').hitTestable(), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('listening-settings-scroll')),
        const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byTooltip('暂停朗读')), before);
    expect(find.byTooltip('停止朗读').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final entry in [
    (const Size(320, 568), 2.0),
    (const Size(800, 390), 1.7)
  ]) {
    testWidgets('fixed controls fit ${entry.$1} at text scale ${entry.$2}',
        (tester) async {
      await mount(tester, size: entry.$1, scale: entry.$2);
      expect(find.byTooltip('暂停朗读').hitTestable(), findsOneWidget);
      expect(find.byTooltip('停止朗读').hitTestable(), findsOneWidget);
      await tester.drag(find.byKey(const ValueKey('listening-settings-scroll')),
          const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭朗读').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('source cards use live selection and accessible radio state',
      (tester) async {
    await mount(tester);
    await tester
        .ensureVisible(find.byKey(const ValueKey('listening-source-custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('listening-source-custom')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ListeningSourcePicker>(find.byType(ListeningSourcePicker))
            .value,
        'custom');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'loading and failed playback never hide stop or emit invalid progress semantics',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await mount(tester, status: '正在准备语音…', loading: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          tester
              .widget<LinearProgressIndicator>(
                  find.byType(LinearProgressIndicator))
              .value,
          isNull);
      expect(find.byTooltip('停止朗读').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await mount(tester,
          status: '朗读失败：此引擎未安装对应语言包，请选择其他音色后重试。', hasError: true);
      expect(find.textContaining('朗读失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  if (Platform.environment['YOMIRU_CAPTURE_UI'] == 'true') {
    for (final brightness in Brightness.values) {
      testWidgets('capture listening ${brightness.name} visual fixture',
          (tester) async {
        final font = Platform.environment['CJK_PREVIEW_FONT'];
        if (font != null) {
          await tester.runAsync(() async {
            final bytes = await File(font).readAsBytes();
            final loader = FontLoader('PreviewCjk')
              ..addFont(Future.value(ByteData.sublistView(bytes)));
            await loader.load();
          });
        }
        final iconFont = Platform.environment['MATERIAL_ICON_PREVIEW_FONT'];
        if (iconFont != null) {
          await tester.runAsync(() async {
            final bytes = await File(iconFont).readAsBytes();
            final loader = FontLoader('MaterialIcons')
              ..addFont(Future.value(ByteData.sublistView(bytes)));
            await loader.load();
          });
        }
        await mount(tester, brightness: brightness);
        await tester.pumpAndSettle();
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(previewKey));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file =
              File('build/ui-previews/listening-${brightness.name}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      });
    }
  }
}
