import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/reader_cache.dart';
import 'package:yomiru/widgets/content_state_view.dart';
import 'reader_controls_test.dart' show withReader;

void main() {
  testWidgets('ordinary reader cache survives network refresh failure',
      (tester) async {
    await withReader(tester, paged: false, platform: TargetPlatform.android,
        prepareLocal: (_) async {
      await ReaderContentCache.write(
          1338,
          LKChapterDetail(
              chapterId: 317815,
              volumeId: 1,
              bodyText: '已缓存的正文',
              bodyHtml: '<p>已缓存的正文</p>'),
          ownerUid: 0);
      LKApi.client = LKClient.forTesting(
          httpClient: MockClient(
              (_) async => throw const SocketException('test failure')));
    }, run: (calls, key) async {
      expect(find.textContaining('已缓存的正文', findRichText: true), findsWidgets);
      expect(find.text('正在阅读本地缓存，联网刷新失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
  testWidgets('failed load remains a retry state, not a body paragraph',
      (tester) async {
    await withReader(tester, paged: false, platform: TargetPlatform.android,
        prepareLocal: (_) async {
      LKApi.client = LKClient.forTesting(
          httpClient: MockClient(
              (_) async => throw const SocketException('test failure')));
    }, run: (calls, key) async {
      expect(find.byType(ContentStateView), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('去登录'), findsNothing);
      expect(find.byType(CustomScrollView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
