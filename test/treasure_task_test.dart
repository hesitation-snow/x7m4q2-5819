import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/reading_session.dart';
import 'package:yomiru/pages/book_detail_page.dart';
import 'package:yomiru/pages/welfare_page.dart';
import 'package:yomiru/services/reading_progress_reporter.dart';
import 'package:yomiru/services/treasure_task.dart';

http.Response response(Map<String, dynamic> data, {int code = 0}) =>
    http.Response.bytes(
        utf8.encode(jsonEncode({
          'code': code,
          'data': code == 0 ? data : null,
          if (code != 0) 'message': 'mock eligibility denied',
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});

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

  test('detail accepts root and known wrappers, not arbitrary nested metadata',
      () {
    final root = {
      'boxes': [
        <String, dynamic>{'box_index': 2}
      ]
    };
    expect(TreasureTask.detail(root), root);
    expect(
        TreasureTask.detail({
          'data': {'detail': root}
        }),
        root);
    expect(TreasureTask.detail({'target_book': root}), isEmpty);
  });
  test('prerequisite completion is not unlock/claim confirmation', () {
    expect(TreasureTask.isClaimable({'prerequisite_completed': 1}), isFalse);
    expect(
        TreasureTask.isClaimable(
            {'status': 'locked', 'button_action': 'claim'}),
        isFalse);
    expect(TreasureTask.isClaimable({'status': 'claimable'}), isTrue);
    expect(TreasureTask.isClaimable({'button_action': 'claim'}), isTrue);
  });
  test('explicit collect type wins over browsing text', () {
    expect(
        TreasureTask.prerequisite({
          'prerequisite_type': 'collect_book',
          'prerequisite_text': '浏览并收藏一个作品'
        }),
        'collect_book');
    expect(
        TreasureTask.prerequisite(
            {'prerequisite_type': 'other', 'prerequisite_text': '阅读'}),
        'other');
  });
  test('target never joins fallback book with another book chapter', () {
    final target = TreasureTask.target({
      'reader_target': {'volume_id': 55, 'chapter_id': 66},
      'target_book': {'book_id': 42, 'title': 'target'},
    });
    expect(target.bookId, 42);
    expect(target.chapterId, 0);
    expect(target.volumeId, 0);
    expect(
        TreasureTask.target({
          'reader_target': {
            'book_id': 7,
            'volume_id': 8,
            'chapter_id': 9,
          }
        }).chapterId,
        9);
  });
  test('treasure provenance remains distinct from daily collect 300002', () {
    expect(
        TreasureTask.routeContext({'task_key': 'treasure', 'source': 'event'},
            {'task_key': 'box-key'}, 2),
        {
          'task_id': 300007,
          'task_key': 'box-key',
          'source': 'event',
          'box_index': 2,
        });
    expect(
        WelfarePage.filterVisibleTasks([
          {
            'task_id': 300002,
            'task_key': 'daily_add_bookshelf_v1',
            'title': '收藏一个作品'
          },
          {
            'task_id': 300007,
            'task_key': 'daily_treasure_box',
            'title': '每日开宝箱'
          },
        ]).map((t) => t['task_id']),
        [300002]);
  });

  Future<void> showPage(WidgetTester tester,
      {ReadingProgressReporter? reporter}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester
        .pumpWidget(MaterialApp(home: WelfarePage(readingReporter: reporter)));
    await tester.pumpAndSettle();
  }

  for (final type in ['read_book', 'collect_book']) {
    testWidgets('$type: before real behavior refresh never writes or claims',
        (tester) async {
      final paths = <String>[];
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.contains('welfare-treasure-box-detail')) {
          return response({
            'task_id': 300007,
            'task_key': 'treasure',
            'boxes': [
              {
                'box_index': 2,
                'status': 'pending',
                'prerequisite_type': type,
                'prerequisite_text': '浏览并收藏作品',
                'prerequisite_completed': 1,
                'target_book': {'book_id': 42},
              }
            ]
          });
        }
        return response({});
      }));
      await showPage(tester);
      expect(find.text('提交开启'), findsOneWidget);
      expect(find.text('开宝箱'), findsNothing);
      await tester.tap(find.text('提交开启'));
      await tester.pumpAndSettle();
      expect(
          paths.any((p) => p.contains('claim-welfare-treasure-box')),
          isTrue);
      paths.clear();
      // An incomplete chapter target routes to book detail, never chapter 1.
      await tester.tap(find.widgetWithText(
          OutlinedButton, type == 'read_book' ? '去浏览' : '去收藏'));
      await tester.pumpAndSettle();
      expect(tester.widget<BookDetailPage>(find.byType(BookDetailPage)).bookId,
          42);
      final context = tester.element(find.byType(BookDetailPage));
      expect(ModalRoute.of(context)!.settings.arguments, {
        'task_id': 300007,
        'task_key': 'treasure',
        'box_index': 2,
      });
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(
          paths.where((p) =>
              p.contains('claim-') ||
              p.contains('save-book-history') ||
              p.contains('toggle-book-shelf')),
          isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    for (final succeeds in [true, false]) {
      testWidgets(
          '$type: confirmed eligibility claim ${succeeds ? 'success' : 'code6 stays failure'}',
          (tester) async {
        var claims = 0;
        var detailQueries = 0;
        final paths = <String>[];
        LKApi.client =
            LKClient.forTesting(httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.contains('claim-welfare-treasure-box')) {
            claims++;
            expect(jsonDecode(request.body), {'box_index': 2});
            return response({
              'reward': {'coin': 12}
            }, code: succeeds ? 0 : 6);
          }
          if (request.url.path.contains('welfare-treasure-box-detail')) {
            detailQueries++;
            return response({
              'boxes': [
                {
                  'box_index': 2,
                  'status': claims > 0 && succeeds ? 'claimed' : 'claimable',
                  'prerequisite_type': type,
                }
              ]
            });
          }
          return response({});
        }));
        await showPage(tester);
        await tester.tap(find.text('开宝箱'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(claims, 1);
        expect(detailQueries, 2);
        if (succeeds) {
          expect(find.textContaining('宝箱开启成功'), findsOneWidget);
          expect(find.text('开宝箱'), findsNothing);
        } else {
          expect(find.textContaining('code 6'), findsOneWidget);
          expect(find.textContaining('宝箱开启成功'), findsNothing);
          expect(find.text('开宝箱'), findsOneWidget);
        }
        expect(
            paths.where((p) =>
                p.contains('save-book-history') ||
                p.contains('toggle-book-shelf') ||
                p.contains('claim-welfare-task') ||
                p.contains('report-welfare-treasure')),
            isEmpty);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final added in [true, false]) {
    testWidgets(
        'real collect ${added ? 'success' : 'failure'} only refreshes on return',
        (tester) async {
      var shelfRequests = 0;
      var claims = 0;
      var detailQueries = 0;
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.contains('toggle-book-shelf')) {
          shelfRequests++;
          expect(jsonDecode(request.body),
              {'book_id': 42, 'action': 'add', 'source': 'android'});
          return response({}, code: added ? 0 : 6);
        }
        if (path.contains('claim-welfare-treasure-box')) claims++;
        if (path.contains('welfare-treasure-box-detail')) {
          detailQueries++;
          return response({
            'boxes': [
              {
                'box_index': 2,
                'status': shelfRequests > 0 && added ? 'claimable' : 'pending',
                'prerequisite_type': 'collect_book',
                'target_book': {'book_id': 42},
              }
            ]
          });
        }
        if (path.endsWith('/get-book-detail')) {
          return response({'book_id': 42, 'title': 'mock book'});
        }
        return response({'list': []});
      }));
      await showPage(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, '去收藏'));
      await tester.pumpAndSettle();
      expect(shelfRequests, 0);
      await tester.tap(find.text('加入书架'));
      await tester.pumpAndSettle();
      expect(shelfRequests, 1);
      expect(find.text(added ? '已加书架' : '加入书架'), findsOneWidget);
      final context = tester.element(find.byType(BookDetailPage));
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      expect(detailQueries, 2);
      expect(claims, 0);
      expect(find.text(added ? '开宝箱' : '提交开启'), findsOneWidget);
      expect(find.textContaining('宝箱开启成功'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final succeeds in [true, false]) {
    testWidgets(
        'treasure query waits for real reading acknowledgement (${succeeds ? 'success' : 'failure'})',
        (tester) async {
      var now = DateTime(2026, 9, 5);
      final session = LKReadingSession(now: () => now);
      session.begin(bookId: 1, volumeId: 2, chapterId: 3, accountId: 12345);
      now = now.add(const Duration(seconds: 16));
      session.pause();
      final gate = Completer<void>();
      final reporter = ReadingProgressReporter(
          session: session,
          owner: () => (12345, 0),
          send: (_, delta) async {
            expect(delta, 16);
            await gate.future;
          });
      var queries = 0;
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        if (request.url.path.contains('welfare-treasure-box-detail')) queries++;
        return response({});
      }));
      await tester.pumpWidget(
          MaterialApp(home: WelfarePage(readingReporter: reporter)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(queries, 0);
      if (succeeds) {
        gate.complete();
      } else {
        gate.completeError(Exception('mock sync failed'));
      }
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(queries, 1);
      expect(session.reportedSeconds, succeeds ? 16 : 0);
      expect(find.textContaining('宝箱开启成功'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
