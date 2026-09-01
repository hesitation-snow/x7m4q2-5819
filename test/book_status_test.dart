import 'package:flutter_test/flutter_test.dart';

import 'package:yomiru/api/models.dart';

void main() {
  test('serializing is displayed as 连载', () {
    expect(bookStatusLabel(LKBook(serialStatus: 'serializing')), '连载');
  });

  test('completed status is displayed as 完结', () {
    expect(bookStatusLabel(LKBook(serialStatus: 'completed')), '完结');
  });

  test('explicit serial status wins over a conflicting completion flag', () {
    expect(
      bookStatusLabel(
        LKBook(serialStatus: 'serializing', isCompleted: true),
      ),
      '连载',
    );
  });

  test('completion flag is used when no explicit status is available', () {
    expect(bookStatusLabel(LKBook(isCompleted: true)), '完结');
  });

  test('book parser accepts camelCase and localized status fields', () {
    final camelCase = LKBook.fromJson({
      'book_id': 1,
      'serialStatus': 'ongoing',
      'isCompleted': true,
    });
    final localized = LKBook.fromJson({
      'book_id': 2,
      'status_text': '已完结',
    });

    expect(bookStatusLabel(camelCase), '连载');
    expect(bookStatusLabel(localized), '完结');
  });
}
