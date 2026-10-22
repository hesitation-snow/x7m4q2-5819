import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/widgets/m3_menu_sheet.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final loggedIn in [false, true]) {
      testWidgets('dynamic close and callbacks $brightness login=$loggedIn',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        LKClient.shared.session.clear();
        if (loggedIn) {
          LKClient.shared.session.uid = 42;
          LKClient.shared.session.securityKey = 'mock';
        }
        final writes = <String>[];
        LKApi.client =
            LKClient.forTesting(httpClient: MockClient((request) async {
          if (request.url.path.contains('toggle')) writes.add(request.body);
          final data = request.url.path.endsWith('get-feed-v1')
              ? {
                  'list': [
                    {
                      'dynamic_id': 17,
                      'content': 'menu fixture',
                      'interaction_state': {'liked': true, 'favorited': true}
                    }
                  ],
                  'has_more': false
                }
              : <String, dynamic>{};
          return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
        addTearDown(() {
          LKApi.client = LKClient.shared;
          LKClient.shared.session.clear();
        });
        tester.view.physicalSize = const Size(320, 400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                    seedColor: Colors.indigo, brightness: brightness)),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!),
            home: const DynamicPage()));
        await tester.pumpAndSettle();
        await tester.longPress(find.text('menu fixture').first);
        await tester.pumpAndSettle();
        expect(find.byType(M3MenuSheet), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(writes, isEmpty);
        await tester.longPress(find.text('menu fixture').first);
        await tester.pumpAndSettle();
        final favorite = find.text('已收藏（点击取消）');
        if (loggedIn) {
          expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
          await tester.ensureVisible(favorite);
          await tester.pumpAndSettle();
          await tester.tap(favorite);
          await tester.pumpAndSettle();
          expect(writes, hasLength(1));
          expect(jsonDecode(writes.single)['dynamic_id'], 17);
          expect(jsonDecode(writes.single)['act'], 'unfavorite');
        } else {
          expect(favorite, findsNothing);
          expect(find.text('点赞此动态'), findsNothing);
          await tester.tap(find.byTooltip('关闭'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(M3MenuSheet), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
