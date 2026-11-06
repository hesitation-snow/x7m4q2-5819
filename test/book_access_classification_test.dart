import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.resetBraveBookIdsForTesting({});
  });

  final positiveCases = <String, Map<String, dynamic>>{
    'snake case': {'is_brave': true},
    'trimmed boolean': {'is_brave': ' TRUE '},
    'numeric string': {'brave_required': ' 1 '},
    'camel case': {'braveRequired': 1},
    'conflicting flag aliases': {'is_brave': 0, 'isBrave': 1},
    'conflicting required aliases': {
      'brave_required': 0,
      'braveRequired': true
    },
    'normalized access type': {'access_type': ' Brave '},
    'positive alias wins public': {
      'access_type': 'public',
      'accessType': 'brave'
    },
    'map metadata': {
      'meta_json': {'brave_scope': ' BRAVE '}
    },
    'encoded metadata compatibility': {
      'meta_json': jsonEncode({'brave_scope': 'brave'})
    },
    'typed tag': {
      'tags': ['普通标签', '勇者可读']
    },
    'badge': {'display_badge_code': 'brave_required'},
  };
  for (final entry in positiveCases.entries) {
    test('book/public/history classify ${entry.key} independently of account',
        () {
      final json = <String, dynamic>{'book_id': 880001, ...entry.value};
      expect(classifyBookAccess(json), BookAccessStatus.brave);
      expect(LKBook.fromJson(json).isBrave, isTrue);
      expect(LKPublicBook.fromJson(json).isBrave, isTrue);
      expect(LKHistoryItem.fromJson(json).isBrave, isTrue);
    });
  }

  test(
      'missing flags, ordinary locks and user roles remain unknown and visible',
      () {
    for (final fields in <Map<String, dynamic>>[
      {},
      {'is_brave': 0},
      {'brave_required': false},
      {'locked': 1},
      {'coin_price': 100},
      {
        'compat': {'legacy_gid': 106}
      },
      {'display_badge_code': 'not_brave'},
      {'display_badge_code': 'unbrave'},
      {
        'tags': ['校园', '奇幻']
      },
      {'meta_json': '{broken'},
      {'meta_json': '[]'},
      {
        'publisher': {'is_brave': true}
      },
      {
        'profile': {'is_brave': true},
        'user': {'passer': 1}
      },
    ]) {
      final book = LKBook.fromJson({'book_id': 880002, ...fields});
      expect(book.accessStatus, BookAccessStatus.unknown, reason: '$fields');
      expect(book.isBrave, isFalse, reason: '$fields');
      expect([book].where((book) => !book.isBrave), hasLength(1));
    }
  });

  test(
      'public book entry stays unknown; chapter public is local; positive wins',
      () {
    expect(
        LKBook.fromJson({'book_id': 880003, 'access_type': ' Public '})
            .accessStatus,
        BookAccessStatus.unknown);
    expect(classifyChapterAccess({'access_type': 'public'}),
        BookAccessStatus.public);
    expect(
        classifyBookAccess({'access_type': 'public', 'brave_required': true}),
        BookAccessStatus.brave);
  });

  test(
      'chapter classification shares flags, metadata and normalization, not lock state',
      () {
    for (final fields in <Map<String, dynamic>>[
      {'access_type': ' Brave '},
      {'accessType': 'BRAVE'},
      {'brave_required': 0, 'braveRequired': true},
      {
        'meta_json': {'brave_scope': 'brave'}
      },
      {
        'meta_json': jsonEncode({'brave_scope': 'brave'})
      },
    ]) {
      final chapter =
          LKChapter.fromJson({'chapter_id': 1, 'unlocked': true, ...fields});
      expect(chapter.braveOnly, isTrue, reason: '$fields');
      expect(chapter.unlocked, isTrue);
    }
    expect(
        LKChapter.fromJson({'locked': 1, 'coin_price': 50}).braveOnly, isFalse);
  });

  test(
      'later positive evidence updates existing models including alternate IDs',
      () async {
    const id = 880004;
    final book = LKBook.fromJson({'book_id': id});
    final publication = LKPublicBook.fromJson({'article_id': id});
    final history = LKHistoryItem.fromJson({'bookId': '$id'});
    expect(book.isBrave, isFalse);
    expect(publication.isBrave, isFalse);
    expect(history.isBrave, isFalse);
    final before = LKStore.braveBookRevision.value;
    await LKStore.markBookBrave(id);
    expect(LKStore.braveBookRevision.value, before + 1);
    expect(book.isBrave, isTrue);
    expect(publication.isBrave, isTrue);
    expect(history.isBrave, isTrue);
    expect(book.accessStatus, BookAccessStatus.brave);
    await LKStore.markBookBrave(id);
    expect(LKStore.braveBookRevision.value, before + 1);
  });

  test('unknown survives cache serialization without becoming public', () {
    final book = LKBook.fromJson({'book_id': 880005, 'title': '权限未知'});
    final decoded = LKBook.fromJson(
        jsonDecode(jsonEncode(book.toJson())) as Map<String, dynamic>);
    expect(decoded.accessStatus, BookAccessStatus.unknown);
    expect(decoded.isBrave, isFalse);
  });

  test('parallel positive observations persist all IDs and reload consistently',
      () async {
    await Future.wait(
        [LKStore.markBookBrave(880006), LKStore.markBookBrave(880007)]);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('known_brave_book_ids'),
        containsAll(['880006', '880007']));
    LKStore.resetBraveBookIdsForTesting({});
    // Load is integration-tested elsewhere with secure storage; verify the
    // exact persisted representation can rebuild the positive-only registry.
    await LKStore.markBooksBrave(
        preferences.getStringList('known_brave_book_ids')!.map(int.parse));
    expect(LKStore.isBraveBook(880006), isTrue);
    expect(LKStore.isBraveBook(880007), isTrue);
  });
}
