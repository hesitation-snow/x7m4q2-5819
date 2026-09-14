import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/widgets/common.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.resetBraveBookIdsForTesting();
    setBraveBookChecker(LKStore.isBraveBook);
  });

  group('Brave Book Discrimination (1338 vs 14162)', () {
    test('Normal book 1338 is NOT brave and not miskilled', () {
      final json1338 = {
        'book_id': 1338,
        'title': '败犬女主太多了！',
        'compat': {
          'legacy_sid': 1775,
          'legacy_gid': 106,
          'legacy_parent_gid': 3,
          'legacy_status': 1,
        },
        'tags': ['校园', '恋爱', '轻小说'],
        'display_badge_code': 'high_score',
        'display_badge_text': '高分',
      };

      final book = LKBook.fromJson(json1338);
      expect(book.isBrave, isFalse,
          reason: 'Legacy gid 106 (日轻文库) must not cause normal books to be flagged as brave');
    });

    test('Brave book 14162 is recognized as brave', () {
      final json14162 = {
        'book_id': 14162,
        'title': '翠櫻皇國的仙術使',
        'compat': {
          'legacy_sid': 0,
          'legacy_gid': 0,
          'legacy_parent_gid': 0,
          'legacy_status': 0,
        },
        'tags': ['校园', '奇幻'],
      };

      final book = LKBook.fromJson(json14162);
      expect(book.isBrave, isTrue,
          reason: 'Book 14162 should be recognized as brave');
    });

    test('LKChapter correctly identifies brave chapters', () {
      final publicCh = LKChapter.fromJson({
        'chapter_id': 276838,
        'title': '第一章',
        'access_type': 'public',
        'locked': 0,
        'brave_required': 0,
      });
      expect(publicCh.braveOnly, isFalse);

      final braveCh = LKChapter.fromJson({
        'chapter_id': 232115,
        'title': '第一章',
        'access_type': 'brave',
        'locked': 1,
        'brave_required': 1,
      });
      expect(braveCh.braveOnly, isTrue);

      final braveRequiredCh = LKChapter.fromJson({
        'chapter_id': 232116,
        'title': '第二章',
        'access_type': '',
        'locked': 1,
        'brave_required': 1,
      });
      expect(braveRequiredCh.braveOnly, isTrue);
    });

    test('Dynamically marking a book as brave reflects across models', () async {
      final book999 = LKBook.fromJson({'book_id': 9999, 'title': '未知小说'});
      expect(book999.isBrave, isFalse);

      await LKStore.markBookBrave(9999);
      expect(LKStore.isBraveBook(9999), isTrue);

      final updatedBook999 = LKBook.fromJson({'book_id': 9999, 'title': '未知小说'});
      expect(updatedBook999.isBrave, isTrue);
    });

    test('hideBraveBooks filters brave books while keeping normal books', () {
      final book1338 = LKBook.fromJson({'book_id': 1338, 'title': '败犬女主太多了！'});
      final book14162 = LKBook.fromJson({'book_id': 14162, 'title': '翠櫻皇國的仙術使'});

      final allBooks = [book1338, book14162];

      final filtered = allBooks.where((b) => !b.isBrave).toList();
      expect(filtered.length, 1);
      expect(filtered.first.bookId, 1338);
    });

    test('LKPublicBook (author profile publication/bookshelf) inherits brave status', () {
      final pub1338 = LKPublicBook.fromJson({'book_id': 1338, 'title': '败犬女主太多了！'});
      expect(pub1338.isBrave, isFalse);

      final pub14162 = LKPublicBook.fromJson({'book_id': 14162, 'title': '翠櫻皇國的仙術使'});
      expect(pub14162.isBrave, isTrue);
    });
  });

  group('CoverImage Anti-social Blur & Tap to Peek', () {
    setUp(() {
      LKStore.dataSaverMode.value = false;
      LKStore.nsfwBlurCover.value = true;
    });

    testWidgets(
        'Brave cover renders blur and resident eye button without center badge',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CoverImage(
              url: 'https://example.com/nsfw_cover.jpg',
              width: 100,
              height: 140,
              isBrave: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // No center "勇者" text on the cover
      expect(find.text('勇者'), findsNothing);
      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
      expect(find.byType(ImageFiltered), findsOneWidget);

      // Tap on resident eye button to peek
      await tester.tap(find.byIcon(Icons.visibility_off_rounded));
      await tester.pump();

      expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);

      // Tap resident eye button to hide/blur again
      await tester.tap(find.byIcon(Icons.visibility_rounded));
      await tester.pump();

      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
      expect(find.text('勇者'), findsNothing);
    });

    testWidgets(
        'Small or showPeekButton:false cover has only blur and no eye button',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CoverImage(
              url: 'https://example.com/nsfw_cover.jpg',
              width: 40,
              height: 54,
              isBrave: true,
              showPeekButton: false,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_rounded), findsNothing);
      expect(find.byIcon(Icons.visibility_rounded), findsNothing);
      expect(find.text('勇者'), findsNothing);
    });

    testWidgets(
        'CoverBlurMode.brave blurs brave covers but does not blur normal covers',
        (tester) async {
      LKStore.coverBlurMode.value = CoverBlurMode.brave;

      // Normal book
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CoverImage(
              url: 'https://example.com/normal_cover.jpg',
              width: 100,
              height: 140,
              isBrave: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.byIcon(Icons.visibility_off_rounded), findsNothing);

      // Brave book
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CoverImage(
              url: 'https://example.com/brave_cover.jpg',
              width: 100,
              height: 140,
              isBrave: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
    });

    testWidgets(
        'CoverBlurMode.all blurs ALL covers including normal books and supports peek',
        (tester) async {
      LKStore.coverBlurMode.value = CoverBlurMode.all;

      // Normal book is now blurred in CoverBlurMode.all
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CoverImage(
              url: 'https://example.com/normal_cover.jpg',
              width: 100,
              height: 140,
              isBrave: false,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);

      // Tap to peek normal book cover
      await tester.tap(find.byIcon(Icons.visibility_off_rounded));
      await tester.pump();

      expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
    });

    testWidgets('CoverBlurMode.none disables blur on all covers',
        (tester) async {
      LKStore.coverBlurMode.value = CoverBlurMode.none;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CoverImage(
              url: 'https://example.com/nsfw_cover.jpg',
              width: 100,
              height: 140,
              isBrave: true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.byIcon(Icons.visibility_off_rounded), findsNothing);
      expect(find.byIcon(Icons.visibility_rounded), findsNothing);
    });

    test('LKStore.setCoverBlurMode persists mode and synchronizes nsfwBlurCover',
        () async {
      await LKStore.setCoverBlurMode(CoverBlurMode.all);
      expect(LKStore.coverBlurMode.value, CoverBlurMode.all);
      expect(LKStore.nsfwBlurCover.value, isTrue);

      final p = await SharedPreferences.getInstance();
      expect(p.getString('cover_blur_mode'), 'all');

      await LKStore.setCoverBlurMode(CoverBlurMode.none);
      expect(LKStore.coverBlurMode.value, CoverBlurMode.none);
      expect(LKStore.nsfwBlurCover.value, isFalse);
      expect(p.getString('cover_blur_mode'), 'none');
    });
  });
}
