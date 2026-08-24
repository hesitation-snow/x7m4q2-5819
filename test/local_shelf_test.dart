import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('local shelf can add and remove the first book', () async {
    final book = LKBook(bookId: 123, title: '测试作品');

    await LKStore.setLocalShelf(book, true);
    expect((await LKStore.localShelf()).map((item) => item.bookId), [123]);

    await LKStore.setLocalShelf(book, false);
    expect(await LKStore.localShelf(), isEmpty);
  });

  test('content cache clearing preserves shelf and reading progress', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('my_profile_cache_1', '{}');
    await prefs.setString('my_medals_cache_1', '[]');
    await prefs.setString('global_user_medals_cache_v1', '{}');
    await prefs.setString('home_recommend_v2', '[]');
    await LKStore.setLocalShelf(LKBook(bookId: 321, title: '保留在本机书架'), true);
    await ReaderPrefs.setReadPosFrac(99, 0.42);

    await LKStore.clearContentCaches();

    expect(prefs.containsKey('my_profile_cache_1'), isFalse);
    expect(prefs.containsKey('my_medals_cache_1'), isFalse);
    expect(prefs.containsKey('global_user_medals_cache_v1'), isFalse);
    expect(prefs.containsKey('home_recommend_v2'), isFalse);
    expect((await LKStore.localShelf()).single.bookId, 321);
    expect(await ReaderPrefs.readPosFrac(99), 0.42);
  });
}
