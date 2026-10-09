import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/widgets/content_state_view.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('error state is readable on short viewport: $brightness',
        (tester) async {
      var retries = 0;
      tester.view.physicalSize = const Size(400, 180);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: ContentStateView(
                    message: '正文加载失败，请检查网络连接后重试。原来的正文不会被错误提示替换。',
                    onRetry: () => retries++)),
          )));
      await tester.ensureVisible(find.text('重试'));
      await tester.tap(find.text('重试'));
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
