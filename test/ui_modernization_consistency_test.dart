import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/channel_page.dart';
import 'package:yomiru/pages/login_page.dart';
import 'package:yomiru/pages/medal_center_page.dart';
import 'package:yomiru/pages/search_page.dart';
import 'package:yomiru/services/app_theme.dart';
import 'package:yomiru/widgets/common.dart';
import 'package:yomiru/widgets/content_state_view.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.animationsEnabled.value = true;
    LKStore.dataSaverMode.value = true;
    LKClient.shared.session.clear();
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = false;
  });

  test('AppTheme defines unified dialogTheme and tabBarTheme across modes', () {
    for (final scenario in [
      (brightness: Brightness.light, pureBlack: false),
      (brightness: Brightness.dark, pureBlack: false),
      (brightness: Brightness.dark, pureBlack: true),
    ]) {
      final theme = AppTheme.build(
        scenario.brightness,
        seedColor: const Color(0xFF009688),
        pureBlack: scenario.pureBlack,
      );
      expect(theme.dialogTheme.backgroundColor,
          theme.colorScheme.surfaceContainerHigh);
      final dialogShape = theme.dialogTheme.shape as RoundedRectangleBorder;
      expect(dialogShape.borderRadius, BorderRadius.circular(24));
      expect(theme.tabBarTheme.labelColor, theme.colorScheme.primary);
      expect(theme.tabBarTheme.indicatorColor, theme.colorScheme.primary);
      expect(
        theme.pageTransitionsTheme.builders[TargetPlatform.iOS],
        isNot(isNull),
      );
    }
  });

  test('inferLkNoticeTone treats medal equip and unequip as success', () {
    expect(inferLkNoticeTone('已佩戴', defaultError: true), LkNoticeTone.success);
    expect(inferLkNoticeTone('已取下', defaultError: true), LkNoticeTone.success);
  });

  testWidgets('CoverImage placeholder and BookCard follow ColorScheme tokens',
      (tester) async {
    final theme = AppTheme.build(
      Brightness.dark,
      seedColor: const Color(0xFF009688),
      pureBlack: true,
    );
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: BookCard(
          book: LKBook(
            bookId: 9,
            title: '主题色测试作品',
            authorName: '作者',
            serialStatus: 'completed',
            isCompleted: true,
            isBrave: true,
          ),
          onTap: () {},
        ),
      ),
    ));
    await tester.pump();

    final placeholderIcon =
        tester.widget<Icon>(find.byIcon(Icons.menu_book_rounded));
    expect(placeholderIcon.color,
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.65));

    final titleText = tester.widget<Text>(find.text('主题色测试作品'));
    expect(titleText.style?.color, theme.colorScheme.onSurface);
  });

  testWidgets('LoginPage centers 64x64 header icon and toggles password visibility',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: const LoginPage(),
    ));
    await tester.pumpAndSettle();

    final iconFinder = find.byIcon(Icons.menu_book_outlined);
    final boxFinder = find.ancestor(
      of: iconFinder,
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.constraints == const BoxConstraints.tightFor(width: 64, height: 64),
      ),
    );
    expect(boxFinder, findsOneWidget);
    expect(tester.getSize(boxFinder), const Size(64, 64));

    final pwdFieldBefore = tester.widget<TextField>(find.byType(TextField).last);
    expect(pwdFieldBefore.obscureText, isTrue);

    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();

    final pwdFieldAfter = tester.widget<TextField>(find.byType(TextField).last);
    expect(pwdFieldAfter.obscureText, isFalse);
  });

  testWidgets('SearchPage preserves 20px border radius when focused',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.dark, pureBlack: true),
      home: const SearchPage(),
    ));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    final enabled = field.decoration?.enabledBorder as OutlineInputBorder;
    final focused = field.decoration?.focusedBorder as OutlineInputBorder;
    expect(enabled.borderRadius, BorderRadius.circular(20));
    expect(focused.borderRadius, BorderRadius.circular(20));
  });

  testWidgets('RankPage shows ContentStateView with retry action on error',
      (tester) async {
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((_) async => http.Response('error', 500)),
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: const RankPage(),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ContentStateView), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('MedalCenterPage renders ContentStateView with retry on failure',
      (tester) async {
    LKClient.shared.session.uid = 12;
    LKClient.shared.session.securityKey = 'token';
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((_) async => http.Response('error', 500)),
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.build(Brightness.light),
      home: const MedalCenterPage(),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ContentStateView), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
