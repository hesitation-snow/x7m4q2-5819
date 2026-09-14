import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';

void main() {
  test('welfare display cache is counted and cleared, task claim guard is preserved', () async {
    SharedPreferences.setMockInitialValues({
      'welfare_home_cache_v1_42': '{"tasks":[]}',
      'welfare_daily_claimed_v1_42_20260905': ['id:201'],
      'theme_mode': 'dark',
    });
    expect(await LKStore.contentCacheSizeBytes(), greaterThan(0));
    await LKStore.clearContentCaches();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('welfare_home_cache_v1_42'), isFalse);
    expect(prefs.getStringList('welfare_daily_claimed_v1_42_20260905'), ['id:201']);
    expect(prefs.getString('theme_mode'), 'dark');
  });
  test('response cache clearing keeps unrelated preferences', () async {
    SharedPreferences.setMockInitialValues({
      'lk_response_cache_v1_home_feed': '{"saved_at":1,"data":{}}',
      'uid': 42,
      'theme_mode': 'dark',
    });
    final prefs = await SharedPreferences.getInstance();

    await LKClient.shared.clearResponseCache();

    expect(prefs.containsKey('lk_response_cache_v1_home_feed'), isFalse);
    expect(prefs.getInt('uid'), 42);
    expect(prefs.getString('theme_mode'), 'dark');
  });
}
