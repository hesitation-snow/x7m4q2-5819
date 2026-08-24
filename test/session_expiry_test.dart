import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/lk_client.dart';

void main() {
  final client = LKClient.shared;
  Future<void> Function()? originalHandler;

  setUp(() {
    originalHandler = LKClient.sessionExpiredHandler;
    client.session.clear();
  });

  tearDown(() {
    LKClient.sessionExpiredHandler = originalHandler;
    client.session.clear();
  });

  test('current expired key clears the session and notifies once', () async {
    var handlerCalls = 0;
    final expiredRev = LKClient.sessionExpiredRev.value;
    client.session
      ..securityKey = 'expired-test-key'
      ..uid = 42
      ..nickname = 'Test User';
    LKClient.sessionExpiredHandler = () async {
      handlerCalls++;
      client.session.clear();
      LKClient.sessionRev.value++;
    };

    await client.expireSessionIfCurrent('expired-test-key');
    await client.expireSessionIfCurrent('expired-test-key');

    expect(client.session.isLoggedIn, isFalse);
    expect(client.session.uid, 0);
    expect(handlerCalls, 1);
    expect(LKClient.sessionExpiredRev.value, expiredRev + 1);
  });

  test('an old response cannot clear a newer session', () async {
    var handlerCalls = 0;
    final expiredRev = LKClient.sessionExpiredRev.value;
    client.session
      ..securityKey = 'new-test-key'
      ..uid = 99;
    LKClient.sessionExpiredHandler = () async => handlerCalls++;

    await client.expireSessionIfCurrent('old-test-key');

    expect(client.session.securityKey, 'new-test-key');
    expect(client.session.uid, 99);
    expect(handlerCalls, 0);
    expect(LKClient.sessionExpiredRev.value, expiredRev);
  });
}
