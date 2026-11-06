import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test the backend failure contract without changing production dependencies.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';

class _ControlledPreferences extends InMemorySharedPreferencesStore {
  _ControlledPreferences() : super.empty();

  final started = Completer<void>();
  final release = Completer<void>();
  bool failFirst = false;
  int writes = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.local_shelf_books_v1' && ++writes == 1) {
      started.complete();
      await release.future;
      if (failFirst) throw StateError('simulated write failure');
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('overlapping writes preserve invocation order', () async {
    final backend = _ControlledPreferences();
    SharedPreferencesStorePlatform.instance = backend;
    final revision = LKStore.localShelfRev.value;
    final first = LKStore.setLocalShelf(LKBook(bookId: 1, title: 'one'), true);
    await backend.started.future;
    final second = LKStore.setLocalShelf(LKBook(bookId: 2, title: 'two'), true);
    expect(backend.writes, 1);
    backend.release.complete();
    await first;
    await second;
    expect((await LKStore.localShelf()).map((b) => b.bookId), [2, 1]);
    await LKStore.setLocalShelf(LKBook(bookId: 1, title: 'one'), false);
    expect((await LKStore.localShelf()).map((b) => b.bookId), [2]);
    expect(LKStore.localShelfRev.value, revision + 3);
  });

  test('a failed write reports its error and the queue continues', () async {
    final backend = _ControlledPreferences()..failFirst = true;
    SharedPreferencesStorePlatform.instance = backend;
    final revision = LKStore.localShelfRev.value;
    final first = LKStore.setLocalShelf(LKBook(bookId: 1, title: 'one'), true);
    final failure = expectLater(first, throwsStateError);
    await backend.started.future;
    final second = LKStore.setLocalShelf(LKBook(bookId: 2, title: 'two'), true);
    backend.release.complete();
    await failure;
    await second;
    expect(await LKStore.isLocalShelf(2), isTrue);
    expect(LKStore.localShelfRev.value, revision + 1);
  });

  test('account changes do not change the device shelf storage key', () async {
    final backend = _ControlledPreferences();
    SharedPreferencesStorePlatform.instance = backend;
    final session = LKClient.shared.session;
    addTearDown(session.clear);
    session.uid = 1;
    final first = LKStore.setLocalShelf(LKBook(bookId: 1, title: 'one'), true);
    await backend.started.future;
    session.uid = 2;
    final second = LKStore.setLocalShelf(LKBook(bookId: 2, title: 'two'), true);
    backend.release.complete();
    await Future.wait([first, second]);
    expect((await LKStore.localShelf()).map((b) => b.bookId), [2, 1]);
    final keys = (await backend.getAll()).keys;
    expect(keys, ['flutter.local_shelf_books_v1']);
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
