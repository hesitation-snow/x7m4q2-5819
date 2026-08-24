import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_client.dart';

void main() {
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
