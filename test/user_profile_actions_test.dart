import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/models.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => LKApi.client = LKClient.shared);

  test('Error message is consistently updated to 连接失败，请检查网络连接', () {
    final dynamicPageContent =
        File('lib/pages/dynamic_page.dart').readAsStringSync();
    final homePageContent = File('lib/pages/home_page.dart').readAsStringSync();
    final shelfPageContent =
        File('lib/pages/shelf_page.dart').readAsStringSync();

    expect(dynamicPageContent.contains('连接失败，请检查网络连接'), isTrue);
    expect(homePageContent.contains('连接失败，请检查网络连接'), isTrue);
    expect(shelfPageContent.contains('连接失败，请检查网络连接'), isTrue);

    expect(dynamicPageContent.contains('连接失败，已保留上次内容'), isFalse);
    expect(homePageContent.contains('连接失败，已保留上次内容'), isFalse);
    expect(shelfPageContent.contains('连接失败，已保留上次内容'), isFalse);
  });

  test('LKApi.dmMarkRead posts to /api/bff/dm-mark-read-v1 with peer_uid', () async {
    Map<String, dynamic>? postedBody;
    String? requestedPath;

    final mockClient = MockClient((request) async {
      requestedPath = request.url.path;
      postedBody = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
    });

    final testClient = LKClient.forTesting(httpClient: mockClient);
    testClient.session
      ..securityKey = 'test_key'
      ..uid = 100;

    LKApi.client = testClient;
    await LKApi.dmMarkRead(200);

    expect(requestedPath, endsWith('/api/bff/dm-mark-read-v1'));
    expect(postedBody?['peer_uid'], 200);
    expect(postedBody?['security_key'], 'test_key');
  });

  test('UserProfilePage contains follow and DM icon buttons and no AppBar follow TextButton', () {
    final profileCode = File('lib/pages/user_profile_page.dart').readAsStringSync();

    // Verify AppBar does not have follow TextButton
    expect(profileCode.contains('actions: ['), isFalse);
    expect(profileCode.contains('Text(_followed ? \'取消关注\' : \'关注\')'), isFalse);

    // Verify profile card has follow and DM icon buttons
    expect(profileCode.contains('Icons.how_to_reg_rounded'), isTrue);
    expect(profileCode.contains('Icons.person_add_alt_1_outlined'), isTrue);
    expect(profileCode.contains('Icons.mail_outline_rounded'), isTrue);
    expect(profileCode.contains('tooltip: \'私信\''), isTrue);
    expect(profileCode.contains('_openDm(profile)'), isTrue);
    expect(profileCode.contains('DMChatPage('), isTrue);
  });

  test('LKMessageSummary clears dmCount and recalculates total unread', () {
    const summary = LKMessageSummary(
      unreadCount: 15,
      replyCount: 2,
      mentionCount: 1,
      likeCount: 3,
      fanCount: 1,
      systemCount: 2,
      dmCount: 6,
    );

    final clearedDm = summary.clearCategory('dm');
    expect(clearedDm.dmCount, 0);
    expect(clearedDm.unreadCount, 9);

    final partialDm = summary.clearDm(2);
    expect(partialDm.dmCount, 4);
    expect(partialDm.unreadCount, 13);
  });
}
