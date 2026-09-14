import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/welfare_page.dart';
import 'package:yomiru/api/reading_session.dart';
import 'package:yomiru/services/reading_progress_reporter.dart';

http.Response _jsonResponse(Map<String, dynamic> data, [int status = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(data)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WelfarePage.clearClaimedTestingState();
    LKClient.shared.session.securityKey = 'mock_token';
    LKClient.shared.session.uid = 12345;
    LKClient.shared.session.nickname = '测试用户';
  });

  tearDown(() {
    WelfarePage.clearClaimedTestingState();
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
  });

  testWidgets(
      'task refresh waits for reading acknowledgement without sending duration twice',
      (tester) async {
    var now = DateTime(2026, 9, 5);
    final session = LKReadingSession(now: () => now);
    session.begin(bookId: 1, volumeId: 1, chapterId: 1, accountId: 12345);
    now = now.add(const Duration(seconds: 16));
    session.pause();
    final gate = Completer<void>();
    final deltas = <int>[];
    var earnQueries = 0;
    final reporter = ReadingProgressReporter(
        session: session,
        owner: () => (12345, 0),
        send: (_, delta) async {
          deltas.add(delta);
          await gate.future;
        });
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('welfare-earn-coin-detail-v1')) {
        earnQueries++;
        expect(session.reportedSeconds, 16);
      }
      return _jsonResponse({'code': 0, 'data': <String, dynamic>{}});
    }));
    await tester
        .pumpWidget(MaterialApp(home: WelfarePage(readingReporter: reporter)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(deltas, [16]);
    expect(earnQueries, 0);
    gate.complete();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(earnQueries, 1);
    final refresh =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    final work = refresh.onRefresh();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await work;
    expect(earnQueries, 2);
    expect(deltas, [16]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'task center omits the removed treasure task even when returned by the server',
      (tester) async {
    final paths = <String>[];
    const treasureTask = {
      'task_id': 300007,
      'task_key': 'daily_treasure_box',
      'title': '每日开宝箱'
    };
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      paths.add(request.url.path);
      return _jsonResponse({
        'code': 0,
        'data': {
          'tasks': [treasureTask]
        }
      });
    }));
    expect(WelfarePage.filterVisibleTasks([treasureTask]), isEmpty);
    await tester.pumpWidget(const MaterialApp(home: WelfarePage()));
    await tester.pumpAndSettle();
    expect(find.text('每日开宝箱'), findsNothing);
    expect(find.text('每日签到'), findsOneWidget);
    expect(paths.where((path) => path.contains('treasure')), isEmpty);
    expect(tester.takeException(), isNull);
  });

  group('WelfarePage Task Detection Unit Tests', () {
    test('Identifies claimed tasks via various flags and statuses', () {
      // 1. Numerical status = 2
      expect(
        WelfarePage.isTaskClaimed({'status': 2, 'task_id': 1}),
        isTrue,
      );

      // 2. button_action = 'claimed' / 'received'
      expect(
        WelfarePage.isTaskClaimed({'button_action': 'claimed', 'task_id': 2}),
        isTrue,
      );
      expect(
        WelfarePage.isTaskClaimed({'button_action': 'received', 'task_id': 3}),
        isTrue,
      );

      // 3. button_text = '已领取'
      expect(
        WelfarePage.isTaskClaimed({'button_text': '已领取', 'task_id': 4}),
        isTrue,
      );

      // 4. Boolean flags
      expect(
        WelfarePage.isTaskClaimed({'claimed': true, 'task_id': 5}),
        isTrue,
      );
      expect(
        WelfarePage.isTaskClaimed({'is_claimed': true, 'task_id': 6}),
        isTrue,
      );
      expect(
        WelfarePage.isTaskClaimed({'taskClaimedToday': true, 'task_id': 7}),
        isTrue,
      );

      // 5. Unclaimed task should not be claimed
      expect(
        WelfarePage.isTaskClaimed(
            {'status': 0, 'button_action': 'browse', 'task_id': 8}),
        isFalse,
      );
    });

    test('Identifies claimable tasks via status, action, text, and progress',
        () {
      // 1. Numerical status = 1
      expect(
        WelfarePage.isTaskClaimable({'status': 1, 'task_id': 10}),
        isTrue,
      );

      // 2. button_action = 'claim'
      expect(
        WelfarePage.isTaskClaimable({'button_action': 'claim', 'task_id': 11}),
        isTrue,
      );

      // 3. button_text = '领取' / '去领取'
      expect(
        WelfarePage.isTaskClaimable({'button_text': '领取', 'task_id': 12}),
        isTrue,
      );
      expect(
        WelfarePage.isTaskClaimable({'button_text': '去领取', 'task_id': 13}),
        isTrue,
      );

      // 4. Boolean flags: can_claim, is_completed
      expect(
        WelfarePage.isTaskClaimable({'can_claim': true, 'task_id': 14}),
        isTrue,
      );
      expect(
        WelfarePage.isTaskClaimable({'is_completed': true, 'task_id': 15}),
        isTrue,
      );
      expect(
        WelfarePage.isTaskClaimable(
            {'taskCompletedToday': true, 'task_id': 16}),
        isTrue,
      );

      // 5. Progress completion
      expect(
        WelfarePage.isTaskClaimable({
          'task_id': 17,
          'current_progress': 15,
          'total_progress': 15,
        }),
        isTrue,
      );

      // 6. If already claimed, isTaskClaimable must return false
      expect(
        WelfarePage.isTaskClaimable({
          'task_id': 18,
          'status': 2,
          'button_text': '已领取',
          'is_completed': true,
        }),
        isFalse,
      );

      // 7. Not completed progress
      expect(
        WelfarePage.isTaskClaimable({
          'task_id': 19,
          'status': 0,
          'current_progress': 5,
          'total_progress': 15,
        }),
        isFalse,
      );
    });

    test('Resolves correct actionable button text based on task type and title',
        () {
      // Reading task
      expect(
        WelfarePage.taskButtonText({
          'task_id': 20,
          'task_type': 'read_book',
          'title': '阅读书籍',
        }),
        '去阅读',
      );

      // Share task
      expect(
        WelfarePage.taskButtonText({
          'task_id': 21,
          'task_type': 'share_app',
          'title': '分享给好友',
        }),
        '去分享',
      );

      // Comment task
      expect(
        WelfarePage.taskButtonText({
          'task_id': 22,
          'task_type': 'comment',
          'title': '发表书评',
        }),
        '去评论',
      );

      // Browse task
      expect(
        WelfarePage.taskButtonText({
          'task_id': 23,
          'task_type': 'browse',
          'title': '发现好书',
        }),
        '去浏览',
      );

      // Collect task
      expect(
        WelfarePage.taskButtonText({
          'task_id': 28,
          'task_type': 'collect',
          'title': '收藏一个作品',
        }),
        '去收藏',
      );

      // Fallback
      expect(
        WelfarePage.taskButtonText({
          'task_id': 24,
          'task_type': 'other',
          'title': '未知任务',
        }),
        '去完成',
      );

      // Custom button_text preserved if provided
      expect(
        WelfarePage.taskButtonText({
          'task_id': 25,
          'button_text': '去探索',
        }),
        '去探索',
      );

      // Claimable -> '领取'
      expect(
        WelfarePage.taskButtonText({
          'task_id': 26,
          'status': 1,
        }),
        '领取',
      );

      // Claimed -> '已领取'
      expect(
        WelfarePage.taskButtonText({
          'task_id': 27,
          'status': 2,
        }),
        '已领取',
      );
    });

    test('Sorts tasks with smart weighting: claimable -> actionable -> claimed',
        () {
      final t1 = {
        'task_id': 101,
        'title': '已领取任务',
        'status': 2,
      };
      final t2 = {
        'task_id': 102,
        'title': '可领取任务A',
        'status': 1,
      };
      final t3 = {
        'task_id': 103,
        'status': 0,
        'title': '阅读书籍',
      };
      final t4 = {
        'task_id': 104,
        'title': '可领取任务B',
        'status': 1,
      };

      expect(WelfarePage.taskOrderWeight(t2), 0); // claimable
      expect(WelfarePage.taskOrderWeight(t3), 1); // actionable
      expect(WelfarePage.taskOrderWeight(t1), 2); // claimed

      final sorted = WelfarePage.orderTasks([t1, t3, t4, t2]);
      final sortedIds = sorted.map((t) => t['task_id']).toList();

      // t2 and t4 first (claimable, sorted by id: 102, 104)
      // t3 next (actionable: 103)
      // t1 last (claimed: 101)
      expect(sortedIds, [102, 104, 103, 101]);
    });
    test(
        'Strictly filters reward tasks: only allows browse and collect work, rejects test tasks',
        () {
      final browseTask = {'task_id': 301, 'title': '浏览一个作品', 'status': 0};
      final otherTask = {'task_id': 302, 'title': '其它任务', 'status': 0};
      final collectTask = {'task_id': 303, 'title': '收藏一个作品', 'status': 0};
      final collectAlt = {'task_id': 304, 'title': '收藏作品', 'status': 1};
      final testTask1 = {'task_id': 305, 'title': '网站测试任务', 'status': 0};
      final testTask2 = {
        'task_id': 306,
        'title': '访问问卷调查网站',
        'jump_url': 'http://test.com',
        'status': 0
      };

      expect(WelfarePage.isAllowedRewardTask(browseTask), isTrue);
      expect(WelfarePage.isAllowedRewardTask(otherTask), isTrue);
      expect(WelfarePage.isAllowedRewardTask(collectTask), isTrue);
      expect(WelfarePage.isAllowedRewardTask(collectAlt), isTrue);
      expect(WelfarePage.isAllowedRewardTask(testTask1), isFalse);
      expect(WelfarePage.isAllowedRewardTask(testTask2), isFalse);

      final visible = WelfarePage.filterVisibleTasks([
        browseTask,
        otherTask,
        collectTask,
        collectAlt,
        testTask1,
        testTask2,
      ]);

      // At most 2 tasks (1 browse and 1 collect, with collectAlt preferred due to claimable status)
      expect(visible.length, 2);
      expect(visible.any((t) => t['task_id'] == 301 || t['task_id'] == 302),
          isTrue);
      expect(visible.any((t) => t['task_id'] == 304), isTrue);
      expect(visible.any((t) => t['task_id'] == 305), isFalse);
      expect(visible.any((t) => t['task_id'] == 306), isFalse);
    });

    test(
        'Local today claimed record overrides stale claimable/actionable payloads',
        () {
      final browseTask = {
        'task_id': 501,
        'title': '浏览一个作品',
        'status': 1,
        'button_text': '领取',
        'current_progress': 1,
        'total_progress': 1,
      };

      // Before marking: claimable
      expect(WelfarePage.isTaskClaimed(browseTask), isFalse);
      expect(WelfarePage.isTaskClaimable(browseTask), isTrue);
      expect(WelfarePage.taskButtonText(browseTask), '领取');

      // Mark as claimed today
      WelfarePage.markTaskClaimedTodayForTesting(browseTask);

      // After marking: claimed
      expect(WelfarePage.isTaskClaimed(browseTask), isTrue);
      expect(WelfarePage.isTaskClaimable(browseTask), isFalse);
      expect(WelfarePage.taskButtonText(browseTask), '已领取');
    });

    test(
        'filterVisibleTasks retains claimed status even when stale duplicate is claimable',
        () {
      final claimedBrowse = {
        'task_id': 601,
        'title': '浏览一个作品',
        'status': 2,
        'button_text': '已领取',
      };
      final staleClaimableBrowse = {
        'task_id': 602,
        'title': '浏览作品',
        'status': 1,
        'button_text': '领取',
      };

      // Regardless of list order, claimed should win over claimable!
      final listA =
          WelfarePage.filterVisibleTasks([claimedBrowse, staleClaimableBrowse]);
      expect(listA.length, 1);
      expect(WelfarePage.isTaskClaimed(listA.first), isTrue);
      expect(listA.first['button_text'], '已领取');

      final listB =
          WelfarePage.filterVisibleTasks([staleClaimableBrowse, claimedBrowse]);
      expect(listB.length, 1);
      expect(WelfarePage.isTaskClaimed(listB.first), isTrue);
      expect(listB.first['button_text'], '已领取');
    });
  });

  group('WelfarePage Widget & Cache Tests', () {
    testWidgets('Renders error view with standardized message on failure',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final mock = MockClient((request) async {
        return _jsonResponse(
            {'code': 500, 'message': 'Internal Server Error'}, 500);
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WelfarePage(),
          ),
        ),
      );

      // Step frames for async load
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Error message should be standardized
      expect(find.text('连接失败，请检查网络连接'), findsOneWidget);
      expect(find.text('重新加载'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('Restores tasks from cache immediately', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final cachedData = {
        'cached_at': DateTime.now().millisecondsSinceEpoch,
        'coin': 888,
        'tasks': [
          {
            'task_id': 999,
            'title': '浏览一个作品',
            'desc': '离线缓存读取验证',
            'status': 1,
            'reward_coin': 10,
          }
        ],
      };

      SharedPreferences.setMockInitialValues({
        'welfare_home_cache_v1_12345': jsonEncode(cachedData),
      });

      // Network returns error to prove it displays cached data
      final mock = MockClient((request) async {
        return _jsonResponse({'code': 500, 'message': 'Net Error'}, 500);
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WelfarePage(),
          ),
        ),
      );

      // Right after initial frame, cache is loaded
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('浏览一个作品'), findsOneWidget);
      expect(find.text('领取'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets(
        'Renders tasks and actionable buttons correctly on successful network load',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final mock = MockClient((request) async {
        if (request.url.path.contains('welfare-home')) {
          return _jsonResponse({
            'code': 0,
            'data': {
              'coin': 666,
              'tasks': [
                {
                  'task_id': 201,
                  'title': '浏览一个作品',
                  'desc': '浏览一部感兴趣的作品',
                  'task_type': 'browse',
                  'status': 0,
                  'reward_coin': 5,
                },
                {
                  'task_id': 202,
                  'title': '收藏一个作品',
                  'desc': '收藏一部喜欢的作品到书架',
                  'task_type': 'collect',
                  'status': 1,
                  'reward_coin': 10,
                },
                {
                  'task_id': 203,
                  'title': '无效网站测试任务',
                  'desc': '点击访问第三方测试网页',
                  'task_type': 'website',
                  'jump_url': 'https://test-website.invalid',
                  'status': 0,
                  'reward_coin': 1,
                },
              ],
            },
          });
        }
        return _jsonResponse({'code': 0, 'data': {}});
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WelfarePage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('浏览一个作品'), findsOneWidget);
      expect(find.text('去浏览'), findsOneWidget);
      expect(find.text('收藏一个作品'), findsOneWidget);
      expect(find.text('领取'), findsOneWidget);
      expect(find.text('无效网站测试任务'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets(
        'Preserves claimed status across refresh when server returns stale progress',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now();
      final todayKey =
          '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      SharedPreferences.setMockInitialValues({
        'welfare_daily_claimed_v1_12345_$todayKey': ['cat:browse', 'id:701'],
      });

      // Server simulates cache lag: still returns status: 1 and "领取"
      final mock = MockClient((request) async {
        if (request.url.path.contains('welfare-home')) {
          return _jsonResponse({
            'code': 0,
            'data': {
              'tasks': [
                {
                  'task_id': 701,
                  'title': '浏览一个作品',
                  'status': 1,
                  'button_text': '领取',
                  'current_progress': 1,
                  'total_progress': 1,
                },
                {
                  'task_id': 702,
                  'title': '收藏一个作品',
                  'status': 1,
                  'button_text': '领取',
                  'current_progress': 1,
                  'total_progress': 1,
                },
              ],
            },
          });
        }
        return _jsonResponse({'code': 0, 'data': {}});
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WelfarePage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Browse task was claimed today in SharedPreferences, so it must show "已领取"
      expect(find.text('已领取'), findsOneWidget);
      // Collect task was NOT claimed today, so it shows "领取"
      expect(find.text('领取'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets(
        'Claim action updates local storage and stays claimed upon server refresh',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var claimedCalled = false;

      final mock = MockClient((request) async {
        if (request.url.path.contains('claim-welfare-task')) {
          claimedCalled = true;
          return _jsonResponse({'code': 0, 'message': '领取成功', 'data': {}});
        }
        if (request.url.path.contains('welfare-home')) {
          // Server returns stale status 1 on refresh (simulating delay)
          return _jsonResponse({
            'code': 0,
            'data': {
              'tasks': [
                {
                  'task_id': 801,
                  'title': '浏览一个作品',
                  'status': 1,
                  'button_text': '领取',
                  'current_progress': 1,
                  'total_progress': 1,
                },
              ],
            },
          });
        }
        return _jsonResponse({'code': 0, 'data': {}});
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WelfarePage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('浏览一个作品'), findsOneWidget);
      expect(find.text('领取'), findsOneWidget);

      // Tap '领取'
      await tester.tap(find.text('领取'));
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(claimedCalled, isTrue);
      // Even though welfare-home returned stale status 1 on refresh, UI must now show '已领取'
      expect(find.text('已领取'), findsOneWidget);
      expect(find.text('领取'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets(
        'Claim error indicating already claimed flips button to claimed',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final mock = MockClient((request) async {
        if (request.url.path.contains('claim-welfare-task')) {
          return _jsonResponse({
            'code': -1,
            'message': '今日已领取',
            'data': {'msg': '今日已领取'},
          });
        }
        if (request.url.path.contains('welfare-home')) {
          return _jsonResponse({
            'code': 0,
            'data': {
              'tasks': [
                {
                  'task_id': 802,
                  'title': '收藏一个作品',
                  'status': 1,
                  'button_text': '领取',
                  'current_progress': 1,
                  'total_progress': 1,
                },
              ],
            },
          });
        }
        return _jsonResponse({'code': 0, 'data': {}});
      });
      LKApi.client = LKClient.forTesting(httpClient: mock);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WelfarePage(),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('收藏一个作品'), findsOneWidget);
      expect(find.text('领取'), findsOneWidget);

      // Tap '领取'
      await tester.tap(find.text('领取'));
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Error message "今日已领取" handled, flips to '已领取'
      expect(find.text('已领取'), findsOneWidget);
      expect(find.text('领取'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
