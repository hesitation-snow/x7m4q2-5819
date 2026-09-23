import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/user_profile_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = true;
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final data = request.url.path.endsWith('/public-user-home-v1')
          ? {
              'profile': {
                'uid': 42,
                'nickname': '测试用户',
                'level_name': '皇帝',
                'passer': true,
                'medals': [
                  for (var i = 1; i <= 5; i++)
                    {
                      'medal_id': i,
                      'name': '勋章 $i',
                      'image': 'https://example.invalid/medal-$i.png',
                    },
                ],
              },
            }
          : <String, dynamic>{'list': []};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKStore.dataSaverMode.value = false;
  });

  testWidgets('five medals stay on one scrollable line on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: const UserProfilePage(uid: 42),
    ));
    await tester.pumpAndSettle();

    expect(find.text('测试用户'), findsWidgets);
    final medalTooltips = [
      for (var i = 1; i <= 5; i++) find.byTooltip('勋章 $i'),
    ];
    for (var i = 0; i < medalTooltips.length; i++) {
      expect(medalTooltips[i], findsOneWidget, reason: '勋章 ${i + 1}');
    }
    final firstTop = tester.getTopLeft(medalTooltips.first).dy;
    for (final medal in medalTooltips.skip(1)) {
      expect(tester.getTopLeft(medal).dy, firstTop);
    }
    final strip = find.ancestor(
      of: medalTooltips.first,
      matching: find.byType(SingleChildScrollView),
    );
    expect(strip, findsOneWidget);
    expect(tester.getRect(medalTooltips.last).right,
        greaterThan(tester.getRect(strip).right));
    await tester.drag(strip, const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(medalTooltips.last).right,
        lessThanOrEqualTo(tester.getRect(strip).right));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 700));
  });
}
