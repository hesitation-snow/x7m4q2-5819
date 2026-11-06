import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/home_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
  });
  tearDown(() {
    LKClient.shared.session.clear();
    LKApi.client = LKClient.shared;
  });

  test('experience parses nested profile and preserves user group', () {
    final profile = LKMyProfile.fromJson({
      'profile': {
        'uid': 42,
        'group_name': '测试组',
        'exp': 0,
        'next_exp': ' 123 '
      },
      'stats': {'fans_count': 4},
    });
    expect(profile.exp, 0);
    expect(profile.nextExp, 123);
    expect(profile.levelName, '测试组');
    expect(profile.followersCount, 4);
    final outer = LKMyProfile.fromJson({
      'profile': {'uid': 42},
      'exp': 5,
      'next_exp': 9,
    });
    expect(outer.exp, 5);
    expect(outer.nextExp, 9);
  });

  test('missing and invalid experience remains unknown', () {
    for (final value in [
      null,
      '',
      'bad',
      true,
      -1,
      1.5,
      double.infinity,
      {},
      []
    ]) {
      final profile = LKMyProfile.fromJson({'exp': value, 'next_exp': value});
      expect(profile.exp, isNull, reason: '$value');
      expect(profile.nextExp, isNull, reason: '$value');
    }
    final oldCache = LKMyProfile.fromJson({'uid': 42, 'level_name': '测试组'});
    expect(oldCache.exp, isNull);
    expect(oldCache.nextExp, isNull);
    expect(oldCache.levelName, '测试组');
  });

  test('API unwraps response data and cache round trips experience', () async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final data = request.url.path.contains('my-home-v1')
          ? {
              'profile': {
                'uid': 42,
                'user_group_name': '测试组',
                'exp': 7,
                'next_exp': 12
              }
            }
          : <String, dynamic>{};
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    final profile = await LKApi.myProfile();
    expect(profile.exp, 7);
    expect(profile.nextExp, 12);
    expect(profile.levelName, '测试组');
    await LKStore.cacheMyProfile(42, profile);
    final cached = await LKStore.cachedMyProfile(42);
    expect(cached?.exp, 7);
    expect(cached?.nextExp, 12);
    expect(cached?.levelName, '测试组');
  });

  testWidgets('my profile shows only known experience values', (tester) async {
    LKClient.shared.session
      ..securityKey = 'test-session'
      ..uid = 42;
    var data = <String, dynamic>{
      'uid': 42,
      'group_name': '测试组',
      'exp': 0,
      'next_exp': 12
    };
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': request.url.path.contains('my-home-v1')
                ? {'profile': data}
                : {},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MyTab())));
    await tester.pumpAndSettle();
    expect(find.text('测试组'), findsOneWidget);
    expect(find.text('经验 0'), findsOneWidget);
    expect(find.text('升级经验参考 12'), findsOneWidget);
    data = {'uid': 42, 'exp': 'invalid'};
    LKClient.sessionRev.value++;
    await tester.pumpAndSettle();
    expect(find.textContaining('经验 '), findsNothing);
    expect(find.textContaining('升级经验参考'), findsNothing);
  });
}
