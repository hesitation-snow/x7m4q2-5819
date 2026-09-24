import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
    LKStore.epubDownloadEnabled.value = false;
    LKStore.enhancedContentStyleEnabled.value = true;
  });
  tearDown(() => LKClient.shared.session.clear());

  Future<void> showSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('settings order and reading style work without login',
      (tester) async {
    await showSettings(tester);

    final headings = ['显示', '浏览', '阅读', '应用', '账号与信息'];
    for (var i = 1; i < headings.length; i++) {
      expect(tester.getTopLeft(find.text(headings[i - 1])).dy,
          lessThan(tester.getTopLeft(find.text(headings[i])).dy));
    }
    expect(find.text('实验性功能'), findsNothing);
    expect(find.text('书籍导出'), findsNothing);
    expect(find.text('反馈问题'), findsOneWidget);
    final style = find.widgetWithText(SwitchListTile, '原文格式');
    expect(tester.widget<SwitchListTile>(style).value, isTrue);
    expect(find.text('如原文支持，显示注音、文字样式与注释'), findsOneWidget);

    await tester.tap(style);
    await tester.pump();
    expect(LKStore.enhancedContentStyleEnabled.value, isFalse);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('reader_enhanced_content_style'),
        isFalse);
  });

  testWidgets('book export is visible only when logged in and keeps notice',
      (tester) async {
    LKClient.shared.session
      ..securityKey = 'test-session'
      ..uid = 42;
    await showSettings(tester);

    final export = find.widgetWithText(SwitchListTile, '书籍导出');
    expect(export, findsOneWidget);
    await tester.tap(export);
    await tester.pumpAndSettle();
    expect(find.text('使用须知'), findsOneWidget);

    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(LKStore.epubDownloadEnabled.value, isFalse);

    await tester.tap(export);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(LKStore.epubDownloadEnabled.value, isTrue);

    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    expect(find.text('书籍导出'), findsNothing);
    expect(find.text('原文格式'), findsOneWidget);
  });
}
