import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/pages/home_page.dart';
import 'package:yomiru/pages/shelf_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final loggedIn in [false, true]) {
    for (final config in [
      (1.0, const Size(390, 844)),
      (1.5, const Size(1024, 768)),
      (2.0, const Size(320, 720)),
    ]) {
      final scale = config.$1;
      final size = config.$2;
      final device = size.width < 350 ? '窄屏' : (size.width < 600 ? '手机' : '平板');
      testWidgets(
          '$device(${size.width.toInt()}x${size.height.toInt()}) ${loggedIn ? '登录' : '未登录'} 字号 $scale 标题坐标一致',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        final sharedSession = LKClient.shared.session;
        final oldUid = sharedSession.uid;
        final oldKey = sharedSession.securityKey;
        final oldNickname = sharedSession.nickname;
        final oldAvatar = sharedSession.avatar;
        final oldClient = LKApi.client;
        final oldUpdate = LKStore.autoCheckUpdateEnabled.value;
        final oldGlass = LKStore.liquidGlassBottomBarEnabled.value;
        final requests = <Uri>[];
        final client =
            LKClient.forTesting(httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {'list': [], 'has_more': false}
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }));
        sharedSession
          ..uid = loggedIn ? 42 : 0
          ..securityKey = loggedIn ? 'test-session' : ''
          ..nickname = ''
          ..avatar = '';
        client.session
          ..uid = sharedSession.uid
          ..securityKey = sharedSession.securityKey;
        LKApi.client = client;
        LKStore.autoCheckUpdateEnabled.value = false;
        LKStore.liquidGlassBottomBarEnabled.value = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          sharedSession
            ..uid = oldUid
            ..securityKey = oldKey
            ..nickname = oldNickname
            ..avatar = oldAvatar;
          LKApi.client = oldClient;
          LKStore.autoCheckUpdateEnabled.value = oldUpdate;
          LKStore.liquidGlassBottomBarEnabled.value = oldGlass;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          );
        });

        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 24, bottom: 20),
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: const HomePage(),
        ));
        await tester.pumpAndSettle();

        Future<void> selectTab(String label) async {
          final destination = find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(label),
          );
          expect(destination, findsOneWidget);
          await tester.tap(destination);
          await tester.pumpAndSettle();
        }

        void expectUnscrolled(Finder page) {
          final scrollables = find.descendant(
            of: page,
            matching: find.byType(Scrollable),
          );
          final vertical = scrollables
              .evaluate()
              .map((element) => tester.state<ScrollableState>(
                  find.byElementPredicate((e) => e == element)))
              .where((state) => state.position.axis == Axis.vertical)
              .toList();
          expect(vertical, isNotEmpty);
          for (final state in vertical) {
            expect(state.position.pixels,
                closeTo(state.position.minScrollExtent, 0.01));
          }
        }

        await selectTab('书架');
        final shelfPage = find.byType(ShelfPage);
        final shelfTitle =
            find.descendant(of: shelfPage, matching: find.text('书架'));
        expect(shelfTitle, findsOneWidget);
        expectUnscrolled(shelfPage);
        final shelfOffset = tester.getTopLeft(shelfTitle);

        await selectTab('动态');
        final dynamicPage = find.byType(DynamicPage);
        final dynamicTitle =
            find.descendant(of: dynamicPage, matching: find.text('动态'));
        expect(dynamicTitle, findsOneWidget);
        expectUnscrolled(dynamicPage);
        final dynamicOffset = tester.getTopLeft(dynamicTitle);
        expect(dynamicOffset.dx, closeTo(shelfOffset.dx, 0.01),
            reason: '标题横坐标');
        expect(dynamicOffset.dy, closeTo(shelfOffset.dy, 0.01),
            reason: '标题纵坐标');
        expect(tester.takeException(), isNull);
        expect(
            requests
                .any((uri) => uri.path.endsWith('/api/dynamic/get-feed-v1')),
            isTrue,
            reason: '动态请求须经模拟客户端');
      });
    }
  }
}
