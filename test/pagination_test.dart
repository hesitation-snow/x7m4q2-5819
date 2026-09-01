import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/pagination.dart';

void main() {
  test('collectPaged loads through the first short page', () async {
    final requestedPages = <int>[];
    final result = await collectPaged<int>(
      pageSize: 3,
      loadPage: (page, pageSize) async {
        requestedPages.add(page);
        return switch (page) {
          1 => [1, 2, 3],
          2 => [4, 5],
          _ => const [],
        };
      },
      keyOf: (item) => item,
    );

    expect(result, [1, 2, 3, 4, 5]);
    expect(requestedPages, [1, 2]);
  });

  test('collectPaged removes overlap between pages', () async {
    final result = await collectPaged<int>(
      pageSize: 3,
      loadPage: (page, pageSize) async => switch (page) {
        1 => [1, 2, 3],
        2 => [3, 4],
        _ => const [],
      },
      keyOf: (item) => item,
    );

    expect(result, [1, 2, 3, 4]);
  });

  test('collectPaged stops when a full page repeats', () async {
    var calls = 0;
    final result = await collectPaged<int>(
      pageSize: 2,
      loadPage: (page, pageSize) async {
        calls++;
        return [1, 2];
      },
      keyOf: (item) => item,
    );

    expect(result, [1, 2]);
    expect(calls, 2);
  });
}
