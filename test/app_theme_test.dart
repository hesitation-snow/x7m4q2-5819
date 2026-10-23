import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/services/app_theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('shared surfaces and accessible controls $brightness',
        (tester) async {
      final theme = AppTheme.build(brightness);
      expect(theme.useMaterial3, isTrue);
      expect(theme.scaffoldBackgroundColor, theme.colorScheme.surface);
      expect(theme.cardTheme.color, theme.colorScheme.surfaceContainerLow);
      expect(theme.navigationBarTheme.indicatorColor,
          theme.colorScheme.secondaryContainer);
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('书架')),
          body: SingleChildScrollView(
              child: Column(children: [
            const Card(
                child:
                    ListTile(title: Text('继续阅读'), subtitle: Text('上次读到 第一章'))),
            const TextField(decoration: InputDecoration(labelText: '搜索作品')),
            FilledButton(onPressed: () {}, child: const Text('开始阅读')),
            OutlinedButton(onPressed: () {}, child: const Text('加入书架')),
          ])),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(FilledButton)).height,
          greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });
  }
}
