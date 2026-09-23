import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/experimental_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.epubDownloadEnabled.value = false;
    LKStore.enhancedContentStyleEnabled.value = false;
  });

  testWidgets('ExperimentalSettingsPage displays book export and prompts copyright dialog on enable', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ExperimentalSettingsPage(),
      ),
    );

    await tester.pumpAndSettle();

    // 验证「书籍导出」与「正文样式增强」存在，而「书籍导入」已被移除
    expect(find.text('书籍导出'), findsOneWidget);
    expect(find.text('正文样式增强'), findsOneWidget);
    expect(find.text('书籍导入'), findsNothing);

    // 点击开启「书籍导出」
    await tester.tap(find.widgetWithText(SwitchListTile, '书籍导出'));
    await tester.pumpAndSettle();

    // 应弹出使用须知对话框
    expect(find.text('使用须知'), findsOneWidget);
    expect(
      find.text('作品版权归原作者或相应权利人所有。请遵守站点规则及作品授权要求，未经许可，请勿上传、分享、售卖或用于其他商业用途。'),
      findsOneWidget,
    );

    // 点击「拒绝」
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();

    // 未开启
    expect(LKStore.epubDownloadEnabled.value, isFalse);

    // 再次点击开启「书籍导出」
    await tester.tap(find.widgetWithText(SwitchListTile, '书籍导出'));
    await tester.pumpAndSettle();

    // 点击「确认」
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // 成功开启
    expect(LKStore.epubDownloadEnabled.value, isTrue);

    // 再次点击关闭「书籍导出」无需弹窗直接关闭
    await tester.tap(find.widgetWithText(SwitchListTile, '书籍导出'));
    await tester.pumpAndSettle();

    expect(LKStore.epubDownloadEnabled.value, isFalse);
    expect(find.text('使用须知'), findsNothing);
  });
}
