import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/services/app_theme.dart';
import 'package:yomiru/widgets/common.dart';

void main() {
  test('inferLkNoticeTone classifies errors, successes, and neutral notices', () {
    expect(inferLkNoticeTone(StateError('boom')), LkNoticeTone.error);
    expect(inferLkNoticeTone('账号不存在，请确认登录邮箱是否正确'), LkNoticeTone.error);
    expect(inferLkNoticeTone('点赞操作失败，请重试'), LkNoticeTone.error);
    expect(inferLkNoticeTone('已加入书架'), LkNoticeTone.success);
    expect(inferLkNoticeTone('已复制动态链接'), LkNoticeTone.success);
    expect(inferLkNoticeTone('操作成功'), LkNoticeTone.success);
    expect(inferLkNoticeTone('两面包夹汉化组-『桌游咖03』翻译纪念'), LkNoticeTone.info);
    expect(inferLkNoticeTone('再按一次返回退出阅读'), LkNoticeTone.info);
    expect(
      inferLkNoticeTone('自定义错误文案', defaultError: true),
      LkNoticeTone.error,
    );
  });

  for (final scenario in [
    (name: 'light', brightness: Brightness.light, pureBlack: false),
    (name: 'dark', brightness: Brightness.dark, pureBlack: false),
    (name: 'pureBlack', brightness: Brightness.dark, pureBlack: true),
  ]) {
    testWidgets(
        'unified SnackBar adapts cleanly in ${scenario.name} mode without overflow',
        (tester) async {
      final theme = AppTheme.build(
        scenario.brightness,
        pureBlack: scenario.pureBlack,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2.0),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () =>
                        showFloatingPrompt(context, '两面包夹汉化组-『桌游咖03』翻译纪念'),
                    child: const Text('info'),
                  ),
                  TextButton(
                    onPressed: () => showFloatingPrompt(context, '已加入书架'),
                    child: const Text('success'),
                  ),
                  TextButton(
                    onPressed: () =>
                        showLkError(context, '账号不存在，请确认登录邮箱是否正确'),
                    child: const Text('error'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      for (final entry in [
        (button: 'info', icon: Icons.info_outline_rounded, text: '两面包夹汉化组-『桌游咖03』翻译纪念'),
        (button: 'success', icon: Icons.check_rounded, text: '已加入书架'),
        (button: 'error', icon: Icons.error_outline_rounded, text: '账号不存在，请确认登录邮箱是否正确'),
      ]) {
        await tester.tap(find.text(entry.button));
        await tester.pumpAndSettle();

        final bar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(bar.behavior, SnackBarBehavior.floating);
        expect(bar.dismissDirection, DismissDirection.horizontal);
        final shape = bar.shape as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(18));
        expect(shape.side.color.a, greaterThan(0));
        expect(
          bar.backgroundColor,
          scenario.brightness == Brightness.dark
              ? theme.colorScheme.surfaceContainerHigh
              : theme.colorScheme.surfaceContainerLowest,
        );
        expect(find.byIcon(entry.icon), findsOneWidget);
        expect(find.text(entry.text), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
