import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/pagination.dart';

void main() {
  test('appending to a fixed-length shelf returns an updatable growable list',
      () {
    final previous = [
      (id: 1, value: 'first'),
      (id: 2, value: 'old'),
    ].toList(growable: false);
    final result = mergePagedItems(
        previous, [(id: 2, value: 'updated'), (id: 3, value: 'new')],
        keyOf: (item) => item.id);
    result.add((id: 4, value: 'more'));
    expect(result.map((item) => item.id), [1, 2, 3, 4]);
    expect(result[1].value, 'updated');
    expect(previous[1].value, 'old');
  });

  test('a complete short refresh removes deleted cached entries', () async {
    var visible = [1, 2, 3, 4];
    final result = await refreshPageWindow<int>(
      targetItems: visible.length,
      loadPage: (page, cursor) async =>
          LoadedPage(items: [2, 4], page: page, hasMore: false),
      keyOf: (item) => item,
    );
    visible = result.items;
    expect(visible, [2, 4]);
    expect(result.hasMore, isFalse);
  });

  test('an empty server shelf clears the old snapshot', () async {
    final result = await refreshPageWindow<int>(
      targetItems: 50,
      loadPage: (page, cursor) async =>
          LoadedPage(items: [], page: page, hasMore: false),
      keyOf: (item) => item,
    );
    expect(result.items, isEmpty);
    expect(result.page, 1);
  });

  test('a multi-page snapshot stays visible until its replacement is ready',
      () async {
    var visible = [90, 91, 92];
    final secondPage = Completer<LoadedPage<int>>();
    final loadingSecond = Completer<void>();
    final request = refreshPageWindow<int>(
      targetItems: visible.length,
      loadPage: (page, cursor) async {
        if (page == 1) {
          return const LoadedPage(
              items: [1, 2], page: 1, hasMore: true, cursor: 'next');
        }
        expect(cursor, 'next');
        loadingSecond.complete();
        return secondPage.future;
      },
      keyOf: (item) => item,
    ).then((page) => visible = page.items);
    await loadingSecond.future;
    expect(visible, [90, 91, 92]);
    secondPage.complete(const LoadedPage(items: [3], page: 2, hasMore: false));
    await request;
    expect(visible, [1, 2, 3]);
  });

  test('a failed later page leaves the previous snapshot intact', () async {
    var visible = [90, 91, 92];
    final request = refreshPageWindow<int>(
      targetItems: visible.length,
      loadPage: (page, cursor) async {
        if (page == 1) {
          return const LoadedPage(items: [1, 2], page: 1, hasMore: true);
        }
        throw StateError('offline');
      },
      keyOf: (item) => item,
    ).then((page) => visible = page.items);
    await expectLater(request, throwsStateError);
    expect(visible, [90, 91, 92]);
  });

  test('refresh is bounded and preserves the next-page cursor', () async {
    final calls = <(int, String)>[];
    final result = await refreshPageWindow<int>(
      targetItems: 100,
      maxPages: 2,
      loadPage: (page, cursor) async {
        calls.add((page, cursor));
        return LoadedPage(
            items: [page], page: page, hasMore: true, cursor: 'cursor$page');
      },
      keyOf: (item) => item,
    );
    expect(calls, [(1, ''), (2, 'cursor1')]);
    expect(result.items, [1, 2]);
    expect(result.page, 2);
    expect(result.cursor, 'cursor2');
    expect(result.hasMore, isTrue);
  });

  test('a repeated page cannot keep a refresh running indefinitely', () async {
    var calls = 0;
    final result = await refreshPageWindow<int>(
      targetItems: 100,
      loadPage: (page, cursor) async {
        calls++;
        return LoadedPage(items: [1, 2], page: page, hasMore: true);
      },
      keyOf: (item) => item,
    );
    expect(calls, 2);
    expect(result.hasMore, isFalse);
  });

  test('a superseded refresh stops requesting further pages', () async {
    var calls = 0;
    await refreshPageWindow<int>(
      targetItems: 100,
      isCurrent: () => false,
      loadPage: (page, cursor) async {
        calls++;
        return LoadedPage(items: [page], page: page, hasMore: true);
      },
      keyOf: (item) => item,
    );
    expect(calls, 1);
  });
}
