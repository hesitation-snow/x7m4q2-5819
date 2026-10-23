import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/dm_chat_page.dart';
import 'package:yomiru/pages/messages_page.dart';
import 'package:yomiru/pages/welfare_page.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.securityKey = 'mock';
    LKClient.shared.session.uid = 12345;
  });
  tearDown(() {
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
  });

  for (final brightness in Brightness.values) {
    for (final page in ['messages', 'chat', 'welfare']) {
      testWidgets('$page $brightness narrow screen with large text',
          (tester) async {
        tester.view.physicalSize = const Size(360, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        LKApi.client =
            LKClient.forTesting(httpClient: MockClient((request) async {
          final path = request.url.path;
          Map<String, dynamic> data = {};
          if (path.contains('dm-messages')) {
            data = {
              'list': [
                {
                  'id': 1,
                  'sender_uid': 12345,
                  'content_text': '自己的长消息，保持清晰可读且可以自然换行。'
                },
                {'id': 2, 'sender_uid': 2, 'content_text': '对方的消息'},
              ]
            };
          } else if (path.contains('dm-conversations')) {
            data = {
              'list': [
                {
                  'peer_uid': 2,
                  'peer_name': '很长的书友名称需要换行',
                  'last_message': '会话摘要',
                  'updated_at': '2026-09-05 10:00:00',
                  'unread': 3
                },
              ]
            };
          } else if (path.contains('message-replies')) {
            data = {
              'list': [
                {
                  'id': 1,
                  'nickname': '书友',
                  'content': '回复正文与引用文字保持层级',
                  'quote_text': '被回复的内容',
                  'time': '2026-09-05 10:00:00'
                },
              ]
            };
          } else if (path.contains('welfare-treasure-box-detail')) {
            data = {
              'boxes': [
                {
                  'box_index': 1,
                  'status': 'pending',
                  'prerequisite_type': 'read_book',
                  'prerequisite_text': '完成指定作品阅读后，刷新查看真实资格',
                  'reward_coin': 12
                },
                {'box_index': 2, 'status': 'claimed', 'reward_coin': 12},
                {'box_index': 3, 'status': 'waiting_time', 'reward_coin': 12},
              ]
            };
          }
          return http.Response.bytes(
              utf8.encode(jsonEncode({'code': 0, 'data': data})), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
        final scheme = ColorScheme.fromSeed(
            seedColor: Colors.indigo, brightness: brightness);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: true, colorScheme: scheme),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: switch (page) {
            'messages' => const MessagesPage(),
            'chat' => const DMChatPage(peerUid: 2, peerName: '书友'),
            _ => const WelfarePage(),
          },
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (page == 'messages') {
          await tester.ensureVisible(find.text('私信').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('私信').first);
          await tester.pumpAndSettle();
          expect(find.text('会话摘要'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } else if (page == 'chat') {
          final text = tester.widget<Text>(find.text('对方的消息'));
          expect(text.style!.color, scheme.onSurface);
          final mine = tester.widget<Text>(find.text('自己的长消息，保持清晰可读且可以自然换行。'));
          expect(mine.style!.color, scheme.onPrimaryContainer);
          await tester.enterText(find.byType(TextField), '多行输入\n第二行');
          await tester.pump();
          expect(tester.takeException(), isNull);
        } else {
          await tester.scrollUntilVisible(find.byTooltip('刷新达标状态'), 200);
          expect(find.text('提交开启'), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
