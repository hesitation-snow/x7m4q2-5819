import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/comments_page.dart';

Future<List<int>> _pixel(WidgetTester tester, Key key, Offset position) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final offset =
        (position.dy.floor() * image.width + position.dx.floor()) * 4;
    final pixel =
        data.buffer.asUint8List(data.offsetInBytes + offset, 4).toList();
    image.dispose();
    return pixel;
  }))!;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'code': 0,
            'data': request.url.path.contains('get-book-comments')
                ? {
                    'list': [
                      {
                        'comment_id': 1,
                        'user_uid': 7,
                        'nickname': '测试用户',
                        'content': '测试评论内容',
                        'avatar': ''
                      }
                    ],
                    'has_more': false
                  }
                : {'list': [], 'groups': []},
          })),
          200,
          headers: {'content-type': 'application/json'});
    }));
  });
  tearDown(() {
    LKApi.client = LKClient.shared;
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows
  ]) {
    testWidgets('persistent comment background respects $platform',
        (tester) async {
      const captureKey = ValueKey('capture');
      final originalStrategy = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
          () => FocusManager.instance.highlightStrategy = originalStrategy);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            platform: platform,
            hoverColor: Colors.red,
            focusColor: Colors.blue),
        home: const RepaintBoundary(
            key: captureKey, child: CommentsPage(bookId: 1)),
      ));
      await tester.pumpAndSettle();
      final content = find.text('测试评论内容');
      expect(content, findsOneWidget);
      final row =
          find.ancestor(of: content, matching: find.byType(InkWell)).first;
      final rect = tester.getRect(row);
      final position = Offset(rect.right - 3, rect.center.dy);
      final baseline = await _pixel(tester, captureKey, position);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(-1, -1));
      await mouse.moveTo(position);
      await tester.pumpAndSettle();
      final hover = await _pixel(tester, captureKey, position);
      expect(
          hover,
          platform == TargetPlatform.windows
              ? isNot(equals(baseline))
              : equals(baseline));
      await mouse.removePointer();
      await tester.pumpAndSettle();
      Focus.of(tester.element(content)).requestFocus();
      await tester.pumpAndSettle();
      final focus = await _pixel(tester, captureKey, position);
      expect(
          focus,
          platform == TargetPlatform.windows
              ? isNot(equals(baseline))
              : equals(baseline));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('touch long press still copies the comment', (tester) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const CommentsPage(bookId: 1)));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('测试评论内容'));
    await tester.pumpAndSettle();
    expect(copied, '测试评论内容');
    expect(find.text('已复制评论'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
