import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/medal_catalog.dart';

Map<String, dynamic> page(int cur, List<int> ids,
        {int total = 5, int size = 2, bool grouped = false}) =>
    {
      'page_info': {'cur': cur, 'count': total, 'size': size},
      'task_medals': [
        {'task_id': 10, 'name': '任务'}
      ],
      'exchange_medals': grouped
          ? [
              {
                'title': '兑换',
                'items': [
                  for (final id in ids) {'goods_id': id, 'name': '测试勋章 $id'}
                ]
              }
            ]
          : [
              for (final id in ids) {'goods_id': id, 'name': '测试勋章 $id'}
            ],
    };

void main() {
  test('zero-based count metadata does not request an extra empty page',
      () async {
    final calls = <int>[];
    final result = await loadAllMedalPages((number) async {
      calls.add(number);
      if (number > 1) throw StateError('Unexpected extra page');
      return page(number, number == 0 ? [1, 2] : [3], total: 3);
    });
    expect(calls, [0, 1]);
    expect((result['exchange_medals'] as List).length, 3);
  });

  test('normalizes first cursor and keeps test medals on every page', () async {
    final calls = <int>[];
    final result = await loadAllMedalPages((number) async {
      calls.add(number);
      return switch (number) {
        0 => page(1, [1, 2]),
        2 => page(2, [3, 4]),
        3 => page(3, [5]),
        _ => throw StateError('Unexpected page'),
      };
    });
    expect(calls, [0, 2, 3]);
    expect((result['exchange_medals'] as List).length, 5);
    expect((result['exchange_medals'] as List).last['name'], '测试勋章 5');
    expect((result['task_medals'] as List).length, 1);
  });

  test('merges grouped lists and duplicate entries', () async {
    final result = await loadAllMedalPages((number) async => number == 0
        ? page(1, [1, 2], total: 4, grouped: true)
        : page(2, [2, 3, 4], total: 4, grouped: true));
    final groups = result['exchange_medals'] as List;
    expect(groups.length, 1);
    expect((groups.single['items'] as List).length, 4);
  });

  test('does not filter an unpaginated response', () async {
    final result = await loadAllMedalPages((_) async => {
          'goods': [
            {'name': '测试'}
          ]
        });
    expect((result['goods'] as List).single['name'], '测试');
  });

  test('propagates page failures instead of returning partial success',
      () async {
    await expectLater(loadAllMedalPages((number) async {
      if (number == 0) return page(1, [1, 2]);
      throw StateError('offline');
    }), throwsStateError);
  });

  test('rejects repeated pages rather than looping', () async {
    var calls = 0;
    await expectLater(loadAllMedalPages((_) async {
      calls++;
      return page(1, [1, 2]);
    }), throwsStateError);
    expect(calls, 2);
  });

  test('supports explicit final page with zero-based cursor', () async {
    final calls = <int>[];
    final result = await loadAllMedalPages((number) async {
      calls.add(number);
      return {
        ...page(number, [number + 1]),
        'page_info': {'cur': number, 'has_next': number == 0 ? 1 : 0}
      };
    });
    expect(calls, [0, 1]);
    expect((result['exchange_medals'] as List).length, 2);
  });
}
