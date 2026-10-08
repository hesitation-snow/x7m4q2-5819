import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/treasure_box.dart';
import 'package:yomiru/pages/treasure_box_page.dart';

http.Response _jsonResponse(Object data, {int status = 200}) => http.Response(
      jsonEncode(data),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

LKClient _createMockClient(
  Future<http.Response> Function(http.Request request) handler,
) {
  final client = LKClient.forTesting(httpClient: MockClient(handler));
  client.session.securityKey = 'test_token';
  client.session.uid = 12345;
  client.session.nickname = '测试用户';
  return client;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.securityKey = 'test_token';
    LKClient.shared.session.uid = 12345;
    LKClient.shared.session.nickname = '测试用户';
  });

  tearDown(() {
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
  });

  group('TreasureBox Model & State Tests', () {
    test('parses official box_index schema with prerequisites and target books', () {
      final detail = TreasureBoxDetail.fromMap({
        'code': 0,
        'data': {
          'detail': {
            'campaign_day': 1,
            'task_date': '2026-09-28',
            'opened_boxes': 1,
            'claimable_boxes': 1,
            'today_total_boxes': 3,
            'next_unlock_at': '2026-09-28T18:00:00Z',
            'boxes': [
              {
                'box_index': 1,
                'reward_coin': 200,
                'status': 'opened',
                'prerequisite_completed': 1,
                'prerequisite_text': '观看广告支持作者',
              },
              {
                'box_index': 2,
                'reward_coin': 300,
                'status': 'claimable',
                'claimable': true,
                'prerequisite_completed': 1,
                'prerequisite_type': 'read_book',
                'target_book': {
                  'book_id': 1338,
                  'title': '测试书籍',
                },
              },
              {
                'box_index': 3,
                'reward_coin': 500,
                'status': 'waiting',
                'unlock_at': '2026-09-29T10:00:00Z',
                'prerequisite_completed': 0,
                'prerequisite_type': 'watch_ad',
              },
            ],
          },
        },
      });

      expect(detail.opened, 1);
      expect(detail.claimable, 1);
      expect(detail.todayTotal, 3);
      expect(detail.boxes, hasLength(3));

      final now = DateTime.utc(2026, 9, 28, 12);

      // Box 1: opened
      expect(detail.boxes[0].boxIndex, 1);
      expect(detail.boxes[0].reward, 200);
      expect(detail.boxes[0].opened, isTrue);
      expect(detail.boxes[0].state(now), TreasureBoxState.claimed);
      expect(detail.boxes[0].canClaim(now), isFalse);

      // Box 2: claimable & target book
      expect(detail.boxes[1].boxIndex, 2);
      expect(detail.boxes[1].reward, 300);
      expect(detail.boxes[1].opened, isFalse);
      expect(detail.boxes[1].bookId, 1338);
      expect(detail.boxes[1].bookTitle, '测试书籍');
      expect(detail.boxes[1].state(now), TreasureBoxState.ready);
      expect(detail.boxes[1].canClaim(now), isTrue);

      // Box 3: future unlock
      expect(detail.boxes[2].boxIndex, 3);
      expect(detail.boxes[2].reward, 500);
      expect(detail.boxes[2].state(now), TreasureBoxState.waiting);
      expect(detail.boxes[2].canClaim(now), isFalse);
    });

    test('prerequisite requirement completed = false triggers prerequisite state', () {
      final now = DateTime.utc(2026, 9, 28, 12);
      final item = TreasureBoxItem.fromMap({
        'box_index': 4,
        'reward_coin': 150,
        'status': 'locked',
        'prerequisite_completed': 0,
        'prerequisite_type': 'read_book',
        'reader_target': {
          'book_id': 999,
          'title': '前置作品',
          'requirement_text': '阅读指定章节',
        },
      });

      expect(item.state(now), TreasureBoxState.prerequisite);
      expect(item.canClaim(now), isFalse);
      expect(item.bookId, 999);
      expect(item.description, '阅读指定章节');
    });

    test('merges claimable_boxes list into existing boxes', () {
      final detail = TreasureBoxDetail.fromMap({
        'detail': {
          'opened_boxes': 0,
          'boxes': [
            {'box_index': 1, 'reward_coin': 100, 'claimable': false},
          ],
          'claimable_boxes': [
            {'box_index': 1, 'reward_coin': 100},
          ],
        },
      });

      expect(detail.boxes, hasLength(1));
      expect(detail.boxes[0].claimable, isTrue);
    });

    test('parses real diagnostic response with card and complex task prerequisites', () {
      final detail = TreasureBoxDetail.fromMap({
        'format': 2,
        'response': {
          'task_id': 300007,
          'task_key': 'daily_treasure_box',
          'task_type': 'treasure_box',
          'source': 'welfare',
          'title': '每日开宝箱',
          'sub_title': '完成任务开宝箱',
          'icon': '',
          'status': 'in_progress',
          'button_text': '查看宝箱',
          'button_action': 'open_treasure_box_popup',
          'reward_amount': 936,
          'reward': {
            'coin': 936,
            'exp': 0,
            'balance': 1000,
          },
          'claimable': 0,
          'claimed': 0,
          'progress': 0,
          'total_progress': 3,
          'card': {
            'today_total_boxes': 3,
            'opened_boxes': 0,
            'claimable_boxes': 0,
            'next_unlock_at': '2026-09-28T18:00:00Z',
            'campaign_day': 1,
            'week_play_days': 1,
            'boxes': [
              {
                'box_index': 1,
                'status': 'waiting_task',
                'reward_coin': 244,
                'prerequisite_type': 'watch_ad',
                'prerequisite_completed': 0,
                'prerequisite_text': '先看一个广告，再开启这个宝箱',
                'button_text': '去完成任务',
                'button_action': 'watch_ad',
              },
              {
                'box_index': 2,
                'status': 'waiting_task',
                'reward_coin': 290,
                'prerequisite_type': 'read_book',
                'prerequisite_completed': 0,
                'prerequisite_text': '先去浏览《冰川日菜想要撒娇！》，再开启这个宝箱',
                'target_book': {
                  'book_id': 1338,
                  'title': '冰川日菜想要撒娇！',
                },
                'reader_target': {
                  'book_id': 1338,
                  'title': '冰川日菜想要撒娇！',
                  'volume_id': 1,
                  'chapter_id': 1,
                  'requirement_type': 'open_book',
                  'requirement_text': '打开并浏览《冰川日菜想要撒娇！》',
                },
                'button_text': '去完成任务',
                'button_action': 'open_reader',
              },
              {
                'box_index': 3,
                'status': 'waiting_time',
                'reward_coin': 402,
                'prerequisite_type': 'watch_ad',
                'prerequisite_completed': 0,
                'prerequisite_text': '先看一个广告，再开启这个宝箱',
                'button_text': '等待解锁',
                'button_action': 'none',
              },
            ],
          },
        },
      });

      expect(detail.todayTotal, 3);
      expect(detail.opened, 0);
      expect(detail.claimable, 0);
      expect(detail.boxes, hasLength(3));

      final now = DateTime.utc(2026, 9, 28, 12);

      // Box 1: Ad task
      final b1 = detail.boxes[0];
      expect(b1.boxIndex, 1);
      expect(b1.reward, 244);
      expect(b1.isAdTask, isTrue);
      expect(b1.state(now), TreasureBoxState.prerequisite);
      expect(b1.buttonText, '去完成任务');
      expect(b1.description, '先看一个广告，再开启这个宝箱');

      // Box 2: Read task
      final b2 = detail.boxes[1];
      expect(b2.boxIndex, 2);
      expect(b2.reward, 290);
      expect(b2.isReadTask, isTrue);
      expect(b2.bookId, 1338);
      expect(b2.bookTitle, '冰川日菜想要撒娇！');
      expect(b2.volumeId, 1);
      expect(b2.chapterId, 1);
      expect(b2.state(now), TreasureBoxState.prerequisite);
      expect(b2.buttonText, '去完成任务');
      expect(b2.description, '先去浏览《冰川日菜想要撒娇！》，再开启这个宝箱');

      // Box 3: Time locked
      final b3 = detail.boxes[2];
      expect(b3.boxIndex, 3);
      expect(b3.reward, 402);
      expect(b3.state(now), TreasureBoxState.waiting);
      expect(b3.buttonText, '等待解锁');
    });

    test('unopened box with empty opened_at string is not treated as opened', () {
      final now = DateTime.utc(2026, 9, 28, 12);
      final item = TreasureBoxItem.fromMap({
        'box_index': 1,
        'status': 'waiting_task',
        'reward_coin': 244,
        'prerequisite_type': 'watch_ad',
        'prerequisite_completed': 0,
        'opened_at': '',
        'unlock_at': '',
        'button_text': '去完成任务',
        'button_action': 'watch_ad',
      });

      expect(item.opened, isFalse);
      expect(item.state(now), TreasureBoxState.prerequisite);
      expect(item.isAdTask, isTrue);
    });
  });

  group('TreasureBox API Request Tests', () {
    test('claimWelfareTreasureBox sends all context parameters', () async {
      String? requestedPath;
      Map<String, dynamic>? requestBody;

      LKApi.client = _createMockClient((request) async {
        requestedPath = request.url.path;
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonResponse({
          'code': 0,
          'data': {
            'reward_coin': 250,
            'balance': 1000,
          },
        });
      });

      final res = await LKApi.claimWelfareTreasureBox(
        boxIndex: 2,
        campaignId: 10,
        campaignDay: 1,
        taskId: 300007,
        taskKey: 'daily_treasure_box',
      );
      expect(
        requestedPath?.endsWith('/api/bff/claim-welfare-treasure-box-v1'),
        isTrue,
      );
      expect(requestBody?['box_index'], 2);
      expect(requestBody?['boxIndex'], 2);
      expect(requestBody?['campaign_id'], 10);
      expect(requestBody?['campaign_day'], 1);
      expect(requestBody?['task_id'], 300007);
      expect(requestBody?['task_key'], 'daily_treasure_box');
      expect(requestBody?['security_key'], 'test_token');
      expect(res['reward_coin'], 250);
    });

    test('reportWelfareTreasureBoxProgress sends full parameters with duration', () async {
      String? requestedPath;
      Map<String, dynamic>? requestBody;

      LKApi.client = _createMockClient((request) async {
        requestedPath = request.url.path;
        requestBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonResponse({'code': 0, 'data': {}});
      });

      await LKApi.reportWelfareTreasureBoxProgress(
        boxIndex: 3,
        campaignId: 10,
        campaignDay: 1,
        taskId: 300007,
        taskKey: 'daily_treasure_box',
        adType: 'watch_ad',
        actionType: 'watch_ad',
        duration: 15,
        progress: 1,
      );
      expect(
        requestedPath?.endsWith('/api/bff/report-welfare-treasure-box-progress-v1'),
        isTrue,
      );
      expect(requestBody?['box_index'], 3);
      expect(requestBody?['boxIndex'], 3);
      expect(requestBody?['task_id'], 300007);
      expect(requestBody?['task_key'], 'daily_treasure_box');
      expect(requestBody?['ad_type'], 'watch_ad');
      expect(requestBody?['action_type'], 'watch_ad');
      expect(requestBody?['button_action'], 'watch_ad');
      expect(requestBody?['action'], 'complete');
      expect(requestBody?['duration'], 15);
      expect(requestBody?['read_duration_seconds'], 15);
      expect(requestBody?['progress'], 1);
    });

    test('TreasureBoxApi.reportProgress automatically probes and discovers valid action', () async {
      TreasureBoxApi.resetDiscoveredActionForTesting();
      final attemptedActions = <String>[];

      LKApi.client = _createMockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final action = body['action'] as String;
        attemptedActions.add(action);
        if (action == 'complete') {
          return _jsonResponse({'code': 1, 'message': 'Action是无效的。'}, status: 200);
        }
        if (action == 'finish') {
          return _jsonResponse({'code': 0, 'data': {'ok': true}});
        }
        return _jsonResponse({'code': 1, 'message': 'Action是无效的。'}, status: 200);
      });

      final item = TreasureBoxItem.fromMap({
        'box_index': 1,
        'prerequisite_type': 'watch_ad',
        'button_action': 'watch_ad',
        'task_id': 300007,
      });

      final res = await TreasureBoxApi.reportProgress(item);
      expect(res['ok'], isTrue);
      expect(attemptedActions, ['complete', 'finish']);
      expect(TreasureBoxApi.discoveredAction, 'finish');

      // Subsequent call should reuse discovered action directly without re-probing
      attemptedActions.clear();
      final res2 = await TreasureBoxApi.reportProgress(item);
      expect(res2['ok'], isTrue);
      expect(attemptedActions, ['finish']);
    });

    test('welfareTreasureBoxDetail requests detail endpoint', () async {
      String? requestedPath;

      LKApi.client = _createMockClient((request) async {
        requestedPath = request.url.path;
        return _jsonResponse({
          'code': 0,
          'data': {
            'detail': {
              'opened_boxes': 0,
              'boxes': [],
            },
          },
        });
      });

      final res = await LKApi.welfareTreasureBoxDetail();
      expect(
        requestedPath?.endsWith('/api/bff/welfare-treasure-box-detail-v1'),
        isTrue,
      );
      expect(res['detail'], isNotNull);
    });
  });

  group('TreasureBoxPage UI & Interaction Tests', () {
    testWidgets('renders progress summary and opens claimable box', (tester) async {
      int claimCalls = 0;
      LKApi.client = _createMockClient((request) async {
        if (request.url.path.endsWith('welfare-treasure-box-detail-v1')) {
          return _jsonResponse({
            'code': 0,
            'data': {
              'detail': {
                'opened_boxes': 1,
                'today_total_boxes': 3,
                'claimable_boxes': 1,
                'boxes': [
                  {
                    'box_index': 1,
                    'reward_coin': 100,
                    'status': 'opened',
                    'prerequisite_completed': 1,
                  },
                  {
                    'box_index': 2,
                    'reward_coin': 200,
                    'status': 'claimable',
                    'claimable': true,
                    'prerequisite_completed': 1,
                  },
                  {
                    'box_index': 3,
                    'reward_coin': 500,
                    'status': 'waiting',
                    'unlock_at': '2099-01-01 12:00',
                    'prerequisite_completed': 0,
                  },
                ],
              },
            },
          });
        }
        if (request.url.path.endsWith('claim-welfare-treasure-box-v1')) {
          claimCalls++;
          final body = jsonDecode(request.body);
          expect(body['box_index'], 2);
          return _jsonResponse({
            'code': 0,
            'data': {
              'reward_coin': 200,
            },
          });
        }
        return _jsonResponse({'code': 0, 'data': {}});
      });

      await tester.pumpWidget(const MaterialApp(home: TreasureBoxPage()));
      await tester.pumpAndSettle();

      // Verify header summary
      expect(find.text('今日宝箱进度'), findsOneWidget);
      expect(find.text('今日已开启 1 / 3 个宝箱'), findsOneWidget);
      expect(find.text('今日可领取 1 个宝箱'), findsOneWidget);

      // Verify box list cards and buttons
      expect(find.text('100 轻币'), findsOneWidget);
      expect(find.text('200 轻币'), findsOneWidget);
      expect(find.text('500 轻币'), findsOneWidget);

      expect(find.text('已领取'), findsOneWidget);
      expect(find.text('开宝箱'), findsOneWidget);
      expect(find.text('未到时间'), findsOneWidget);

      // Tap '开宝箱'
      await tester.tap(find.text('开宝箱'));
      await tester.pump();
      expect(claimCalls, 1);
      await tester.pumpAndSettle();

      // Floating prompt should show
      expect(find.text('宝箱开启成功，获得 200 轻币！'), findsOneWidget);
    });

    testWidgets('shows retry button when detail request fails', (tester) async {
      LKApi.client = _createMockClient((request) async {
        return http.Response('Server Error', 500);
      });

      await tester.pumpWidget(const MaterialApp(home: TreasureBoxPage()));
      await tester.pumpAndSettle();

      expect(find.text('宝箱详情加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets(
        'real diagnostic response displays tasks, opens CommunityAdDialog with 轻国交流群+132141941, copies and claims',
        (tester) async {
      int reportCalls = 0;
      int claimCalls = 0;

      final realData = {
        'format': 2,
        'response': {
          'task_id': 300007,
          'task_key': 'daily_treasure_box',
          'card': {
            'today_total_boxes': 3,
            'opened_boxes': 0,
            'claimable_boxes': 0,
            'boxes': [
              {
                'box_index': 1,
                'status': 'waiting_task',
                'reward_coin': 244,
                'prerequisite_type': 'watch_ad',
                'prerequisite_completed': 0,
                'prerequisite_text': '先看一个广告，再开启这个宝箱',
                'button_text': '去完成任务',
                'button_action': 'watch_ad',
              },
              {
                'box_index': 2,
                'status': 'waiting_task',
                'reward_coin': 290,
                'prerequisite_type': 'read_book',
                'prerequisite_completed': 0,
                'prerequisite_text': '先去浏览《冰川日菜想要撒娇！》，再开启这个宝箱',
                'target_book': {
                  'book_id': 1338,
                  'title': '冰川日菜想要撒娇！',
                },
                'button_text': '去完成任务',
                'button_action': 'open_reader',
              },
              {
                'box_index': 3,
                'status': 'waiting_time',
                'reward_coin': 402,
                'prerequisite_type': 'watch_ad',
                'prerequisite_completed': 0,
                'prerequisite_text': '先看一个广告，再开启这个宝箱',
                'button_text': '等待解锁',
                'button_action': 'none',
              },
            ],
          },
        },
      };

      LKApi.client = _createMockClient((request) async {
        if (request.url.path.endsWith('welfare-treasure-box-detail-v1')) {
          return _jsonResponse({'code': 0, 'data': realData});
        }
        if (request.url.path.endsWith('report-welfare-treasure-box-progress-v1')) {
          reportCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['box_index'], 1);
          expect(body['task_id'], 300007);
          expect(body['duration'], 15);
          expect(body['action_type'], 'watch_ad');
          final resp = realData['response'] as Map<String, dynamic>;
          final card = resp['card'] as Map<String, dynamic>;
          final boxes = card['boxes'] as List;
          boxes[0] = <String, Object>{
            ...Map<String, Object>.from(boxes[0] as Map),
            'status': 'claimable',
            'prerequisite_completed': 1,
            'claimable': true,
          };
          return _jsonResponse({'code': 0, 'data': {'status': 'ok'}});
        }
        if (request.url.path.endsWith('claim-welfare-treasure-box-v1')) {
          claimCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['box_index'], 1);
          expect(body['task_id'], 300007);
          return _jsonResponse({
            'code': 0,
            'data': {'reward_coin': 244},
          });
        }
        return _jsonResponse({'code': 0, 'data': {}});
      });

      await tester.pumpWidget(const MaterialApp(home: TreasureBoxPage()));
      await tester.pumpAndSettle();

      // Check displayed content
      expect(find.text('244 轻币'), findsOneWidget);
      expect(find.text('290 轻币'), findsOneWidget);
      expect(find.text('402 轻币'), findsOneWidget);
      expect(find.text('看广告开启'), findsOneWidget);
      expect(find.text('去阅读'), findsOneWidget);
      expect(find.text('等待解锁'), findsOneWidget);

      // Tap '看广告开启' (Box 1, watch_ad)
      await tester.tap(find.text('看广告开启'));
      await tester.pumpAndSettle();

      // Dialog verification
      expect(find.text('轻国交流群+132141941'), findsOneWidget);
      expect(find.textContaining('132141941'), findsWidgets);

      // Copy button test
      expect(find.text('复制群号: 132141941'), findsOneWidget);
      await tester.tap(find.text('复制群号: 132141941'));
      await tester.pump();
      await tester.pump();
      expect(find.text('群号已复制'), findsOneWidget);

      // Wait 3 seconds for countdown to finish
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.text('完成观看并开启宝箱'), findsOneWidget);
      await tester.tap(find.text('完成观看并开启宝箱'));
      await tester.pumpAndSettle();

      // Ensure both report progress and claim were called
      expect(reportCalls, 1);
      expect(claimCalls, 1);
      expect(find.text('宝箱开启成功，获得 244 轻币！'), findsOneWidget);
    });
  });
}
