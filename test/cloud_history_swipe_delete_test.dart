import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/home_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mockHistoryItems = [
    {
      'book_id': 101,
      'title': '测试历史作品一',
      'author_name': '作者一',
      'cover_url': '',
      'volume_id': 1,
      'chapter_id': 10,
      'chapter_title': '第十章 精彩高潮',
      'progress_percent': 65,
      'last_read_at': '2026-10-20 18:30:00',
      'unread_chapters': 0,
      'is_brave': 0,
    },
    {
      'book_id': 102,
      'title': '测试历史作品二',
      'author_name': '作者二',
      'cover_url': '',
      'volume_id': 2,
      'chapter_id': 20,
      'chapter_title': '第二十章 结局',
      'progress_percent': 100,
      'last_read_at': '2026-10-21 12:00:00',
      'unread_chapters': 0,
      'is_brave': 0,
    },
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session
      ..securityKey = 'test-security-key'
      ..uid = 12345;
    LKStore.dataSaverMode.value = true;
  });

  tearDown(() {
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
    LKStore.dataSaverMode.value = false;
  });

  Future<void> pumpHistoryTab(
    WidgetTester tester, {
    required Future<http.Response> Function(http.Request) handler,
  }) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient(handler));
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CloudHistoryTab(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders history items with swipe to delete support',
      (tester) async {
    await pumpHistoryTab(
      tester,
      handler: (req) async {
        if (req.url.path.endsWith('/history-v1')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'list': mockHistoryItems}
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
      },
    );

    expect(find.text('测试历史作品一 · 作者一'), findsOneWidget);
    expect(find.text('测试历史作品二 · 作者二'), findsOneWidget);

    final dismissibles = find.byType(Dismissible);
    expect(dismissibles, findsNWidgets(2));

    final firstDismissible = tester.widget<Dismissible>(dismissibles.first);
    expect(firstDismissible.direction, DismissDirection.endToStart);
  });

  testWidgets('swiping item from right to left deletes reading history',
      (tester) async {
    final deletedBookIds = <int>[];

    await pumpHistoryTab(
      tester,
      handler: (req) async {
        if (req.url.path.endsWith('/history-v1')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'list': mockHistoryItems}
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path.endsWith('/delete-book-history')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          deletedBookIds.add(body['book_id'] as int);
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'status': 'success'}
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
      },
    );

    // Swipe first item to the left
    await tester.drag(find.text('测试历史作品一 · 作者一'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(deletedBookIds, [101]);
    expect(find.text('测试历史作品一 · 作者一'), findsNothing);
    expect(find.text('测试历史作品二 · 作者二'), findsOneWidget);
    expect(find.text('已删除《测试历史作品一》的阅读记录'), findsOneWidget);
  });

  testWidgets(
      'swipe deletion failure restores the history item and shows error',
      (tester) async {
    await pumpHistoryTab(
      tester,
      handler: (req) async {
        if (req.url.path.endsWith('/history-v1')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'list': mockHistoryItems}
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path.endsWith('/delete-book-history')) {
          return http.Response(
            jsonEncode({'code': 500, 'message': '网络繁忙，删除历史记录失败'}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
      },
    );

    await tester.drag(find.text('测试历史作品一 · 作者一'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // Item should be restored upon failure
    expect(find.text('测试历史作品一 · 作者一'), findsOneWidget);
  });

  testWidgets('deleting all history items displays empty state',
      (tester) async {
    final singleItem = [mockHistoryItems.first];

    await pumpHistoryTab(
      tester,
      handler: (req) async {
        if (req.url.path.endsWith('/history-v1')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'list': singleItem}
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (req.url.path.endsWith('/delete-book-history')) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'status': 'success'}
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
      },
    );

    expect(find.text('测试历史作品一 · 作者一'), findsOneWidget);

    await tester.drag(find.text('测试历史作品一 · 作者一'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('暂无阅读历史'), findsOneWidget);
  });
  http.Response response(Object data) => http.Response(jsonEncode(data), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});

  testWidgets(
      'long press does not delete and brave visibility remains reactive',
      (tester) async {
    var deletes = 0;
    LKStore.hideBraveBooks.value = false;
    addTearDown(() => LKStore.hideBraveBooks.value = false);
    await pumpHistoryTab(tester, handler: (req) async {
      if (req.url.path.endsWith('/history-v1')) {
        return response({
          'code': 0,
          'data': {
            'list': [
              mockHistoryItems.first,
              {...mockHistoryItems.last, 'is_brave': 1},
            ]
          }
        });
      }
      if (req.url.path.endsWith('/delete-book-history')) deletes++;
      return response({'code': 0, 'data': {}});
    });
    await tester.longPress(find.text('测试历史作品一 · 作者一'));
    await tester.pumpAndSettle();
    expect(deletes, 0);
    // InkWell may recognize release as a tap; return from detail if so.
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    if (navigator.canPop()) {
      navigator.pop();
      await tester.pumpAndSettle();
    }
    expect(find.text('测试历史作品一 · 作者一'), findsOneWidget);
    LKStore.hideBraveBooks.value = true;
    await tester.pumpAndSettle();
    expect(find.text('测试历史作品二 · 作者二'), findsNothing);
    LKStore.hideBraveBooks.value = false;
    await tester.pumpAndSettle();
    expect(find.text('测试历史作品二 · 作者二'), findsOneWidget);
  });

  Future<void> swipe(WidgetTester tester, int id) async {
    await tester.drag(find.text(id == 101 ? '测试历史作品一 · 作者一' : '测试历史作品二 · 作者二'),
        const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
      'pending delete disappears before response and stale refresh stays hidden',
      (tester) async {
    final pending = Completer<http.Response>();
    await pumpHistoryTab(tester, handler: (req) async {
      if (req.url.path.endsWith('/history-v1')) {
        return response({
          'code': 0,
          'data': {'list': mockHistoryItems}
        });
      }
      return pending.future;
    });
    await swipe(tester, 101);
    expect(pending.isCompleted, isFalse);
    expect(find.text('测试历史作品一 · 作者一'), findsNothing);
    final refresh =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    await refresh.onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('测试历史作品一 · 作者一'), findsNothing);
    pending.complete(response({'code': 0, 'data': {}}));
    await tester.pumpAndSettle();
    expect(find.text('已删除《测试历史作品一》的阅读记录'), findsOneWidget);
  });

  testWidgets('immediate failure creates fresh dismissible and supports retry',
      (tester) async {
    var requests = 0;
    await pumpHistoryTab(tester, handler: (req) async {
      if (req.url.path.endsWith('/history-v1')) {
        return response({
          'code': 0,
          'data': {'list': mockHistoryItems}
        });
      }
      requests++;
      return response({'code': 500, 'message': '删除失败'});
    });
    await swipe(tester, 101);
    expect(find.text('测试历史作品一 · 作者一'), findsOneWidget);
    await swipe(tester, 101);
    expect(requests, 2);
    expect(find.text('测试历史作品一 · 作者一'), findsOneWidget);
  });

  testWidgets(
      'concurrent failures restore original order without duplicates and retry',
      (tester) async {
    final pending = <int, Completer<http.Response>>{};
    await pumpHistoryTab(tester, handler: (req) async {
      if (req.url.path.endsWith('/history-v1')) {
        return response({
          'code': 0,
          'data': {'list': mockHistoryItems}
        });
      }
      final id = jsonDecode(req.body)['book_id'] as int;
      return (pending[id] = Completer<http.Response>()).future;
    });
    await swipe(tester, 101);
    await swipe(tester, 102);
    expect(find.text('暂无阅读历史'), findsOneWidget);
    pending[102]!.complete(response({'code': 500, 'message': '删除失败'}));
    await tester.pumpAndSettle();
    pending[101]!.complete(response({'code': 500, 'message': '删除失败'}));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('测试历史作品一 · 作者一'), findsOneWidget);
    expect(find.text('测试历史作品二 · 作者二'), findsOneWidget);
    expect(tester.getTopLeft(find.text('测试历史作品一 · 作者一')).dy,
        lessThan(tester.getTopLeft(find.text('测试历史作品二 · 作者二')).dy));
    await swipe(tester, 101);
    pending[101]!.complete(response({'code': 0, 'data': {}}));
    await tester.pumpAndSettle();
  });

  for (final logout in [false, true]) {
    testWidgets(
        'old pending completion ignored after ${logout ? 'logout' : 'account switch'}',
        (tester) async {
      final pending = Completer<http.Response>();
      await pumpHistoryTab(tester, handler: (req) async {
        if (req.url.path.endsWith('/history-v1')) {
          return response({
            'code': 0,
            'data': {
              'list':
                  LKClient.shared.session.uid == 12345 ? mockHistoryItems : []
            }
          });
        }
        return pending.future;
      });
      await swipe(tester, 101);
      if (logout) {
        LKClient.shared.session.clear();
      } else {
        LKClient.shared.session
          ..uid = 67890
          ..securityKey = 'other-key';
      }
      LKClient.sessionRev.value++;
      await tester.pumpAndSettle();
      pending.complete(response({'code': 500, 'message': '旧请求失败'}));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('测试历史作品一 · 作者一'), findsNothing);
      expect(find.textContaining('旧请求失败'), findsNothing);
    });
  }

  testWidgets('pending failure after disposal does not update disposed state',
      (tester) async {
    final pending = Completer<http.Response>();
    await pumpHistoryTab(tester, handler: (req) async {
      if (req.url.path.endsWith('/history-v1')) {
        return response({
          'code': 0,
          'data': {'list': mockHistoryItems}
        });
      }
      return pending.future;
    });
    await swipe(tester, 101);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(response({'code': 500, 'message': '删除失败'}));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling to bottom loads next page of reading history',
      (tester) async {
    final requestedPages = <int>[];
    await pumpHistoryTab(tester, handler: (req) async {
      if (req.url.path.endsWith('/history-v1')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final page = body['page'] as int? ?? 1;
        requestedPages.add(page);
        if (page == 1) {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'list': List.generate(
                  20,
                  (i) => {
                    'book_id': 1000 + i,
                    'title': '第一页书目 $i',
                    'author_name': '作者',
                    'cover_url': '',
                    'progress_percent': 50,
                  },
                ),
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } else {
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'list': [
                  {
                    'book_id': 2001,
                    'title': '第二页书目 1',
                    'author_name': '第二页作者',
                    'cover_url': '',
                    'progress_percent': 80,
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
      }
      return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
    });

    expect(find.text('第一页书目 0 · 作者'), findsOneWidget);
    expect(requestedPages, [1]);

    // Scroll to bottom
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pumpAndSettle();

    expect(requestedPages, [1, 2]);
    expect(find.text('第二页书目 1 · 第二页作者'), findsOneWidget);
  });
}
