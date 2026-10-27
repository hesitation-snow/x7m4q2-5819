import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  String? secureKey;
  bool failDelete = false;
  Completer<void>? deleteStarted;
  Completer<void>? allowDelete;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session.clear();
    secureKey = null;
    failDelete = false;
    deleteStarted = null;
    allowDelete = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'read':
          return secureKey;
        case 'write':
          secureKey = (call.arguments as Map)['value'] as String?;
          return null;
        case 'delete':
          deleteStarted?.complete();
          await allowDelete?.future;
          if (failDelete) throw PlatformException(code: 'storage_failure');
          secureKey = null;
          return null;
      }
      return null;
    });
  });

  test('old cleanup does not erase a concurrent new login', () async {
    final session = LKClient.shared.session;
    session
      ..uid = 1
      ..securityKey = 'old'
      ..nickname = 'old name';
    await LKStore.save();
    deleteStarted = Completer<void>();
    allowDelete = Completer<void>();
    final clearing = LKStore.clear();
    expect(session.isLoggedIn, isFalse);
    await deleteStarted!.future;
    session
      ..uid = 2
      ..securityKey = 'new'
      ..nickname = 'new name';
    final saving = LKStore.save();
    allowDelete!.complete();
    await clearing;
    await saving;
    expect(session.securityKey, 'new');
    session.clear();
    await LKStore.load();
    expect(session.securityKey, 'new');
    expect(session.uid, 2);
    expect(session.nickname, 'new name');
  });

  test('failed secure deletion cannot restore login after restart', () async {
    final session = LKClient.shared.session;
    session
      ..uid = 3
      ..securityKey = 'secret'
      ..nickname = 'person';
    await LKStore.save();
    failDelete = true;
    await LKStore.clear();
    expect(secureKey, 'secret');
    failDelete = false;
    await LKStore.load();
    expect(session.isLoggedIn, isFalse);
    expect(session.uid, 0);
    expect(session.nickname, isEmpty);
  });

  test('clears account caches even if session was previously cleared',
      () async {
    SharedPreferences.setMockInitialValues({
      'uid': 7,
      'my_profile_cache_7': 'profile',
      'my_medals_cache_7': 'medals',
      'welfare_home_cache_v1_7': 'welfare',
      'my_profile_cache_8': 'another profile',
    });
    await LKStore.clear();
    final p = await SharedPreferences.getInstance();
    expect(p.containsKey('my_profile_cache_7'), isFalse);
    expect(p.containsKey('my_medals_cache_7'), isFalse);
    expect(p.containsKey('welfare_home_cache_v1_7'), isFalse);
    expect(p.getString('my_profile_cache_8'), 'another profile');
  });

  test('stale logout identity does not clear a new session', () async {
    final session = LKClient.shared.session;
    session
      ..uid = 2
      ..securityKey = 'new';
    await LKStore.clear(expectedSecurityKey: 'old', expectedUid: 1);
    expect(session.securityKey, 'new');
    expect(session.uid, 2);
  });
}
