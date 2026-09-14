import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/services/daily_task_claims.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'retained page loses yesterday claims and reloads only current account/day',
      () async {
    var now = DateTime(2026, 9, 5, 23, 59);
    var uid = 1;
    final claims = DailyTaskClaims(uid: () => uid, now: () => now);
    await claims.record(['id:201'], expectedKey: claims.storageKey);
    expect(claims.contains('id:201'), isTrue);
    now = now.add(const Duration(minutes: 2));
    expect(claims.contains('id:201'), isFalse);
    await claims.load();
    expect(claims.contains('id:201'), isFalse);
    await claims.record(['id:202'], expectedKey: claims.storageKey);
    uid = 2;
    await claims.load();
    expect(claims.contains('id:202'), isFalse);
    uid = 1;
    await claims.load();
    expect(claims.contains('id:202'), isTrue);
  });

  test(
      'late successful response cannot mark next day or another account as claimed',
      () async {
    var now = DateTime(2026, 9, 5, 23, 59);
    var uid = 1;
    final claims = DailyTaskClaims(uid: () => uid, now: () => now);
    final key = claims.storageKey;
    now = now.add(const Duration(days: 1));
    await claims.record(['id:201'], expectedKey: key);
    expect(claims.contains('id:201'), isFalse);
    final nextDay = claims.storageKey;
    uid = 2;
    await claims.record(['id:201'], expectedKey: nextDay);
    expect(claims.contains('id:201'), isFalse);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('existing persisted claim format remains readable after upgrade',
      () async {
    SharedPreferences.setMockInitialValues({
      'welfare_daily_claimed_v1_8_20260905': ['cat:browse', 'id:701'],
    });
    final claims =
        DailyTaskClaims(uid: () => 8, now: () => DateTime(2026, 9, 5));
    await claims.load();
    expect(claims.contains('cat:browse'), isTrue);
    await claims.record(['id:702'], expectedKey: claims.storageKey);
    await claims.load();
    expect(claims.contains('id:702'), isTrue);
    expect(claims.contains('id:701'), isTrue);
  });
}
