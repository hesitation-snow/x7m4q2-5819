import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/services/dynamic_like_state.dart';

void main() {
  test('missing viewer field is distinct from explicit false', () {
    final missing = LKDynamicItem.fromJson({'dynamic_id': 17});
    final no = LKDynamicItem.fromJson({
      'dynamic_id': 17,
      'interaction_state': {'liked': false}
    });
    final yes = LKDynamicItem.fromJson({
      'dynamic_id': 17,
      'interaction_state': {'liked': true}
    });
    expect(missing.hasLikedState, isFalse);
    final invalid = LKDynamicItem.fromJson({
      'dynamic_id': 17,
      'interaction_state': {'liked': 'unknown'}
    });
    expect(invalid.hasLikedState, isFalse);
    expect(DynamicLikeState.resolve(invalid, {17: true}, authenticated: true),
        isTrue);
    expect(no.hasLikedState, isTrue);
    expect(DynamicLikeState.resolve(missing, {17: true}, authenticated: true),
        isTrue);
    expect(
        DynamicLikeState.resolve(no, {17: true}, authenticated: true), isFalse);
    expect(DynamicLikeState.resolve(yes, {}, authenticated: false), isFalse);
  });

  testWidgets('like action waits for the authenticated detail state',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session
      ..uid = 42
      ..securityKey = 'session-a';
    final detail = Completer<http.Response>();
    var toggleRequests = 0;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('get-detail-v1')) return detail.future;
      if (request.url.path.endsWith('toggle-like-v1')) toggleRequests++;
      final data = request.url.path.endsWith('get-feed-v1')
          ? {
              'list': [
                {'dynamic_id': 17, 'content': 'delayed fixture'}
              ],
              'has_more': false
            }
          : <String, dynamic>{};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200);
    }));
    addTearDown(() {
      LKApi.client = LKClient.shared;
      LKClient.shared.session.clear();
    });
    await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('delayed fixture').first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('正在确认点赞状态'), findsNothing);
    expect(find.text('点赞此动态'), findsOneWidget);
    expect(find.text('复制动态链接'), findsOneWidget);
    final pendingTile = tester.widget<ListTile>(find
        .ancestor(of: find.text('点赞此动态'), matching: find.byType(ListTile))
        .first);
    expect(pendingTile.onTap, isNull);
    await tester.tap(find.text('点赞此动态'));
    await tester.pump();
    expect(toggleRequests, 0);
    detail.complete(http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'dynamic': {
              'dynamic_id': 17,
              'interaction_state': {'liked': true}
            }
          }
        }),
        200));
    await tester.pumpAndSettle();
    expect(find.text('已点赞（点击取消）'), findsOneWidget);
    expect(toggleRequests, 0);
  });

  testWidgets('slow silent lookup falls back without blocking for 30 seconds',
      (tester) async {
    SharedPreferences.setMockInitialValues({'dynamic_like_v1_42_17': true});
    LKClient.shared.session
      ..uid = 42
      ..securityKey = 'session-a';
    final detail = Completer<http.Response>();
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('get-detail-v1')) return detail.future;
      final data = request.url.path.endsWith('get-feed-v1')
          ? {
              'list': [
                {'dynamic_id': 17, 'content': 'timeout fixture'}
              ],
              'has_more': false
            }
          : <String, dynamic>{};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200);
    }));
    addTearDown(() {
      LKApi.client = LKClient.shared;
      LKClient.shared.session.clear();
    });
    await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('timeout fixture').first);
    await tester.pump(const Duration(milliseconds: 350));
    final label = find.text('已点赞（点击取消）');
    expect(label, findsOneWidget);
    expect(
        tester
            .widget<ListTile>(
                find.ancestor(of: label, matching: find.byType(ListTile)).first)
            .onTap,
        isNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(
        tester
            .widget<ListTile>(
                find.ancestor(of: label, matching: find.byType(ListTile)).first)
            .onTap,
        isNotNull);
    expect(find.textContaining('正在确认点赞状态'), findsNothing);
    detail.complete(http.Response('{"code":0,"data":{}}', 200));
    await tester.pump();
  });

  testWidgets(
      'cached like is shown while detail is slow and failure falls back',
      (tester) async {
    SharedPreferences.setMockInitialValues({'dynamic_like_v1_42_17': true});
    LKClient.shared.session
      ..uid = 42
      ..securityKey = 'session-a';
    final detail = Completer<http.Response>();
    final acts = <String>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('get-detail-v1')) return detail.future;
      if (request.url.path.endsWith('toggle-like-v1')) {
        acts.add((jsonDecode(request.body) as Map<String, dynamic>)['act']
            as String);
      }
      final data = request.url.path.endsWith('get-feed-v1')
          ? {
              'list': [
                {'dynamic_id': 17, 'content': 'cached fixture'}
              ],
              'has_more': false
            }
          : <String, dynamic>{};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200);
    }));
    addTearDown(() {
      LKApi.client = LKClient.shared;
      LKClient.shared.session.clear();
    });
    await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('cached fixture').first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('已点赞（点击取消）'), findsOneWidget);
    expect(find.textContaining('正在确认点赞状态'), findsNothing);
    expect(
        tester
            .widget<ListTile>(find
                .ancestor(
                    of: find.text('已点赞（点击取消）'), matching: find.byType(ListTile))
                .first)
            .onTap,
        isNull);
    detail.complete(http.Response('server error', 500));
    await tester.pumpAndSettle();
    expect(find.text('已点赞（点击取消）'), findsOneWidget);
    await tester.tap(find.text('已点赞（点击取消）'));
    await tester.pumpAndSettle();
    expect(acts, ['unlike']);
  });

  testWidgets('authenticated detail explicit state overrides local fallback',
      (tester) async {
    SharedPreferences.setMockInitialValues({'dynamic_like_v1_42_17': true});
    LKClient.shared.session
      ..uid = 42
      ..securityKey = 'session-a';
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final data = request.url.path.endsWith('get-feed-v1')
          ? {
              'list': [
                {'dynamic_id': 17, 'content': 'detail fixture'}
              ],
              'has_more': false
            }
          : request.url.path.endsWith('get-detail-v1')
              ? {
                  'dynamic': {
                    'dynamic_id': 17,
                    'interaction_state': {'liked': false}
                  }
                }
              : <String, dynamic>{};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200);
    }));
    addTearDown(() {
      LKApi.client = LKClient.shared;
      LKClient.shared.session.clear();
    });
    await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('detail fixture').first);
    await tester.pumpAndSettle();
    expect(find.text('点赞此动态'), findsOneWidget);
  });

  testWidgets(
      'successful like survives refresh and restart, isolated per user; failed actions preserve state',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session
      ..uid = 42
      ..securityKey = 'session-a';
    var fail = false;
    final acts = <String>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('toggle-like-v1')) {
        acts.add((jsonDecode(request.body) as Map<String, dynamic>)['act']
            as String);
        if (fail) return http.Response('{"code":9,"message":"failed"}', 200);
      }
      final data = request.url.path.endsWith('get-feed-v1')
          ? {
              'list': [
                {'dynamic_id': 17, 'content': 'like fixture'}
              ],
              'has_more': false
            }
          : <String, dynamic>{};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200);
    }));
    addTearDown(() {
      LKApi.client = LKClient.shared;
      LKClient.shared.session.clear();
    });
    Future<void> open() async {
      await tester.longPress(find.text('like fixture').first);
      await tester.pumpAndSettle();
    }

    Future<void> close() async {
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
    await tester.pumpAndSettle();
    await open();
    expect(find.text('点赞此动态'), findsOneWidget);
    await tester.tap(find.text('点赞此动态'));
    await tester.pumpAndSettle();
    await open();
    expect(find.text('已点赞（点击取消）'), findsOneWidget);
    fail = true;
    await tester.tap(find.text('已点赞（点击取消）'));
    await tester.pumpAndSettle();
    await open();
    expect(find.text('已点赞（点击取消）'), findsOneWidget);
    await close();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: DynamicPage()));
    await tester.pumpAndSettle();
    await open();
    expect(find.text('已点赞（点击取消）'), findsOneWidget);
    await close();
    LKClient.shared.session
      ..uid = 43
      ..securityKey = 'session-b';
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    await open();
    expect(find.text('点赞此动态'), findsOneWidget);
    await tester.tap(find.text('点赞此动态'));
    await tester.pumpAndSettle();
    await open();
    expect(find.text('点赞此动态'), findsOneWidget);
    await close();
    LKClient.shared.session
      ..uid = 42
      ..securityKey = 'session-a';
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    await open();
    expect(find.text('已点赞（点击取消）'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('已点赞（点击取消）'));
    await tester.pumpAndSettle();
    await open();
    expect(find.text('点赞此动态'), findsOneWidget);
    expect(acts, ['like', 'unlike', 'like', 'unlike']);
    expect(await DynamicLikeState.load(42), {17: false});
    expect(await DynamicLikeState.load(43), isEmpty);
  });
}
