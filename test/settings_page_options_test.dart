import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/feedback_options_sheet.dart';
import 'package:yomiru/pages/settings_page.dart';
import 'package:yomiru/widgets/app_theme_color_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Yomiru',
      packageName: 'moe.yutro.yomiru',
      version: '1.5.1',
      buildNumber: '2013',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
    LKStore.epubDownloadEnabled.value = false;
    LKStore.enhancedContentStyleEnabled.value = true;
  });
  tearDown(() {
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
  });

  http.Response response(Map<String, dynamic> data) => http.Response(
        jsonEncode({'code': 0, 'data': data}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
  void mockProfile(Future<http.Response> Function() profile) {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('my-home-v1')) return profile();
      return response({});
    }));
  }

  Future<void> showSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 2200);
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
    expect(find.text('如原文支持，显示文字样式'), findsOneWidget);

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

  testWidgets('feedback offers GitHub and Telegram without an in-app form',
      (tester) async {
    await showSettings(tester);

    await tester.tap(find.text('反馈问题'));
    await tester.pumpAndSettle();

    expect(find.text('在 GitHub 提交 Issue'), findsOneWidget);
    expect(find.text('加入 Telegram 群组'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(githubIssuesUrl, 'https://github.com/hesitation-snow/Yomiru/issues');
    expect(telegramFeedbackUrl, 'https://t.me/FurippuFurappazu');
  });

  testWidgets(
      'about dialog displays project repo and settings has expandable disclaimer',
      (tester) async {
    await showSettings(tester);

    final aboutTile = find.text('关于');
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(aboutTile);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('项目仓库'), findsOneWidget);
    await tester.tap(find.text('好'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    expect(find.text('免责声明'), findsOneWidget);
    expect(find.textContaining('非官方声明'), findsNothing);

    await tester.tap(find.text('免责声明'));
    await tester.pumpAndSettle();

    expect(find.textContaining('非官方声明'), findsOneWidget);
    expect(find.textContaining('非商业用途'), findsOneWidget);
    expect(find.textContaining('数据与网络'), findsOneWidget);
    expect(find.textContaining('云书架与阅读历史'), findsOneWidget);
    expect(find.textContaining('仅存储在您的设备本地'), findsNothing);
    expect(find.textContaining('所有网络请求均直接发送至官方服务器'), findsNothing);
    expect(find.textContaining('版权与内容归属'), findsOneWidget);
    expect(find.textContaining('账号安全'), findsOneWidget);
    expect(find.textContaining('官方协议准则'), findsOneWidget);
    expect(find.textContaining('声明认可'), findsOneWidget);

    final item1X = tester.getTopLeft(find.text('1. 非官方声明')).dx;
    final item2X = tester.getTopLeft(find.text('2. 非商业用途')).dx;
    final item6X = tester.getTopLeft(find.text('6. 官方协议准则')).dx;
    expect(item1X, item2X);
    expect(item1X, item6X);

    await tester.tap(find.text('免责声明'));
    await tester.pumpAndSettle();
    expect(find.textContaining('非官方声明'), findsNothing);
  });

  testWidgets('auto check update switch toggles store and shared preferences',
      (tester) async {
    await showSettings(tester);

    final autoUpdate = find.widgetWithText(SwitchListTile, '自动检查更新');
    expect(autoUpdate, findsOneWidget);
    expect(tester.widget<SwitchListTile>(autoUpdate).value, isTrue);
    expect(find.text('启动时自动检测新版本'), findsOneWidget);

    await tester.tap(autoUpdate);
    await tester.pump();
    expect(LKStore.autoCheckUpdateEnabled.value, isFalse);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('auto_check_update_enabled'),
        isFalse);

    await tester.tap(autoUpdate);
    await tester.pump();
    expect(LKStore.autoCheckUpdateEnabled.value, isTrue);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('auto_check_update_enabled'),
        isTrue);
  });

  testWidgets('theme color palette stays inline in settings', (tester) async {
    await showSettings(tester);

    final pureBlack = find.widgetWithText(SwitchListTile, '深色模式使用纯黑主题');
    expect(pureBlack, findsOneWidget);
    expect(tester.widget<SwitchListTile>(pureBlack).value, isFalse);

    await tester.tap(pureBlack);
    await tester.pump();
    expect(LKStore.pureBlackDark.value, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('pure_black_dark'),
        isTrue);

    final themeColorTile = find.text('主题配色');
    expect(themeColorTile, findsOneWidget);
    await tester.tap(themeColorTile);
    await tester.pumpAndSettle();

    expect(find.text('配色'), findsNothing);
    expect(find.text('深色模式使用纯黑主题'), findsOneWidget);
    expect(find.byType(AppThemeColorSection), findsOneWidget);
  });

  testWidgets('liquid glass bottom bar toggles and persists', (tester) async {
    SharedPreferences.setMockInitialValues({'liquid_glass_intensity': 2});
    await showSettings(tester);

    expect(find.text('实验室'), findsNothing);
    expect(find.byKey(const ValueKey('laboratory-liquid-glass-switch')),
        findsNothing);

    final aboutTile = find.text('关于');
    await tester.ensureVisible(aboutTile);
    await tester.pumpAndSettle();
    expect(aboutTile, findsOneWidget);

    var gesture = await tester.startGesture(tester.getCenter(aboutTile));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('laboratory-liquid-glass-switch')),
        findsNothing);

    LKClient.shared.session
      ..securityKey = 'test-token'
      ..uid = 42;
    await (await SharedPreferences.getInstance()).setString(
        'my_profile_cache_42', jsonEncode({'uid': 42, 'isBrave': true}));

    mockProfile(() async => response({'uid': 42, 'isBrave': true}));
    gesture = await tester.startGesture(tester.getCenter(aboutTile));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('laboratory-liquid-glass-details-entry')),
        findsNothing);
    expect(find.byKey(const ValueKey('laboratory-liquid-glass-switch')),
        findsNothing);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final glassSwitch =
        find.byKey(const ValueKey('settings-liquid-glass-switch'));
    await tester.ensureVisible(glassSwitch);
    expect(glassSwitch, findsOneWidget);
    expect(tester.widget<Switch>(glassSwitch).value, isFalse);

    await tester.tap(glassSwitch);
    await tester.pumpAndSettle();
    expect(LKStore.liquidGlassBottomBarEnabled.value, isTrue);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('liquid_glass_bottom_bar_enabled'),
        isTrue);
    for (final label in ['柔和', '标准', '强烈']) {
      expect(find.text(label), findsNothing);
    }
    await tester.tap(glassSwitch);
    await tester.pumpAndSettle();
    expect(LKStore.liquidGlassBottomBarEnabled.value, isFalse);

    final glassTile = find.byKey(const ValueKey('settings-liquid-glass-tile'));
    await tester.ensureVisible(glassTile);
    await tester.tap(find.text('液态玻璃底栏 (测试)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('液态玻璃'), findsOneWidget);
    expect(find.byKey(const ValueKey('glass-controls')), findsOneWidget);
    expect(find.byKey(const ValueKey('glass-keep-visible-on-scroll')),
        findsOneWidget);
    expect(find.text('首页已启用；下方预览始终开启'), findsNothing);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  });
  testWidgets('moving beyond touch slop cancels hidden entry', (tester) async {
    LKClient.shared.session
      ..securityKey = 'token'
      ..uid = 42;
    var calls = 0;
    mockProfile(() async {
      calls++;
      return response({'uid': 42, 'isBrave': true});
    });
    await showSettings(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于'));
    await tester.pumpAndSettle();
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('关于')));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(seconds: 3));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('实验室'), findsNothing);
  });

  testWidgets('cached identity follows current account without network',
      (tester) async {
    var calls = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      calls++;
      return http.Response('offline', 500);
    }));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'my_profile_cache_42', jsonEncode({'uid': 42, 'isBrave': true}));
    await prefs.setString(
        'my_profile_cache_43', jsonEncode({'uid': 43, 'isBrave': false}));
    LKClient.shared.session
      ..securityKey = 'brave'
      ..uid = 42;
    await showSettings(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于'));
    await tester.pumpAndSettle();

    Future<void> press() async {
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('关于')));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await press();
    expect(find.text('实验室'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    LKClient.shared.session
      ..securityKey = 'ordinary'
      ..uid = 43;
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    await press();
    expect(find.text('实验室'), findsNothing);

    LKClient.shared.session
      ..securityKey = 'new'
      ..uid = 44;
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    await press();
    expect(find.text('实验室'), findsNothing);
    expect(find.textContaining('个人资料尚未加载'), findsOneWidget);

    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    await press();
    expect(find.text('实验室'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('updated cache is used without a network request',
      (tester) async {
    var calls = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      calls++;
      return response({'uid': 42, 'isBrave': true});
    }));
    LKClient.shared.session
      ..securityKey = 'token'
      ..uid = 42;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'my_profile_cache_42', jsonEncode({'uid': 42, 'isBrave': true}));
    await showSettings(tester);
    await prefs.setString(
        'my_profile_cache_42', jsonEncode({'uid': 42, 'isBrave': false}));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于'));
    await tester.pumpAndSettle();
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('关于')));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('实验室'), findsNothing);
    expect(calls, 0);
  });

  testWidgets(
      'account change while export notice is open does not enable export',
      (tester) async {
    LKClient.shared.session
      ..securityKey = 'old'
      ..uid = 42;
    await showSettings(tester);
    await tester.tap(find.widgetWithText(SwitchListTile, '书籍导出'));
    await tester.pumpAndSettle();
    LKClient.shared.session
      ..securityKey = 'new'
      ..uid = 43;
    LKClient.sessionRev.value++;
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(LKStore.epubDownloadEnabled.value, isFalse);
  });
}
