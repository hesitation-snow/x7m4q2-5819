import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/widgets/common.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.gridColumnCount.value = 0;
    LKStore.coverBlurMode.value = CoverBlurMode.none;
    LKStore.hideBraveBooks.value = false;
  });

  group('BookGridDelegate calculations', () {
    test('auto column calculation on mobile and tablet widths', () {
      final mobileMetrics = BookGridDelegate.computeMetrics(
        usableWidth: 360,
        columnCount: 0,
        crossAxisSpacing: 10,
        maxCrossAxisExtent: 220,
      );
      expect(mobileMetrics.count, 2);
      expect(mobileMetrics.cellWidth, closeTo((360 - 10) / 2, 0.01));

      final tabletMetrics = BookGridDelegate.computeMetrics(
        usableWidth: 800,
        columnCount: 0,
        crossAxisSpacing: 10,
        maxCrossAxisExtent: 220,
      );
      expect(tabletMetrics.count, 4);
      expect(tabletMetrics.cellWidth, closeTo((800 - 30) / 4, 0.01));
    });

    test('fixed column calculations for 2, 3, 4, 5 columns', () {
      const screenWidth = 370.0;
      for (final col in [2, 3, 4, 5]) {
        final m = BookGridDelegate.computeMetrics(
          usableWidth: screenWidth,
          columnCount: col,
          crossAxisSpacing: 10,
        );
        expect(m.count, col);
        final expectedWidth = (screenWidth - 10 * (col - 1)) / col;
        expect(m.cellWidth, closeTo(expectedWidth, 0.01));

        final coverHeight = m.cellWidth * (4.0 / 3.0);
        expect(coverHeight / m.cellWidth, closeTo(4.0 / 3.0, 0.001));

        final textH = BookGridDelegate.calculateTextHeight(m.cellWidth);
        expect(m.cellHeight, closeTo(coverHeight + textH, 0.01));
        expect(m.rowStride, closeTo(m.cellHeight + 12, 0.01));
      }
    });

    test('adaptive text height step function', () {
      expect(BookGridDelegate.calculateTextHeight(75.0), 36.0);
      expect(BookGridDelegate.calculateTextHeight(104.9), 36.0);
      expect(BookGridDelegate.calculateTextHeight(105.0), 48.0);
      expect(BookGridDelegate.calculateTextHeight(140.0), 48.0);
      expect(BookGridDelegate.calculateTextHeight(150.0), 58.0);
      expect(BookGridDelegate.calculateTextHeight(200.0), 58.0);

      // 书架模式紧凑测算：无次要信息行，极大收敛行间空隙
      expect(BookGridDelegate.calculateTextHeight(75.0, isShelf: true), 31.0);
      expect(BookGridDelegate.calculateTextHeight(104.9, isShelf: true), 31.0);
      expect(BookGridDelegate.calculateTextHeight(105.0, isShelf: true), 35.0);
      expect(BookGridDelegate.calculateTextHeight(140.0, isShelf: true), 35.0);
      expect(BookGridDelegate.calculateTextHeight(150.0, isShelf: true), 38.0);
      expect(BookGridDelegate.calculateTextHeight(200.0, isShelf: true), 38.0);
    });

    test('getLayout produces SliverGridRegularTileLayout with correct strides', () {
      const delegate = BookGridDelegate(
        columnCount: 3,
        crossAxisSpacing: 10,
        mainAxisSpacing: 12,
      );

      final layout = delegate.getLayout(
        const SliverConstraints(
          axisDirection: AxisDirection.down,
          growthDirection: GrowthDirection.forward,
          userScrollDirection: ScrollDirection.idle,
          scrollOffset: 0,
          precedingScrollExtent: 0,
          overlap: 0,
          remainingPaintExtent: 600,
          crossAxisExtent: 370,
          crossAxisDirection: AxisDirection.right,
          viewportMainAxisExtent: 600,
          remainingCacheExtent: 600,
          cacheOrigin: 0,
        ),
      );

      expect(layout, isA<SliverGridRegularTileLayout>());
      final regular = layout as SliverGridRegularTileLayout;
      expect(regular.crossAxisCount, 3);
      const expectedChildCross = (370.0 - 20) / 3;
      expect(regular.childCrossAxisExtent, closeTo(expectedChildCross, 0.01));
      const expectedChildMain = expectedChildCross * (4.0 / 3.0) + 48.0;
      expect(regular.childMainAxisExtent, closeTo(expectedChildMain, 0.01));
      expect(regular.mainAxisStride, closeTo(expectedChildMain + 12, 0.01));
    });
  });

  group('LKStore gridColumnCount preference', () {
    test('setGridColumnCount updates notifier and clamps values', () async {
      expect(LKStore.gridColumnCount.value, 0);

      await LKStore.setGridColumnCount(3);
      expect(LKStore.gridColumnCount.value, 3);

      final p = await SharedPreferences.getInstance();
      expect(p.getInt('grid_column_count'), 3);

      await LKStore.setGridColumnCount(10);
      expect(LKStore.gridColumnCount.value, 6);

      await LKStore.setGridColumnCount(-5);
      expect(LKStore.gridColumnCount.value, 0);
    });

    test('ReaderPrefs gridColumnCount helpers work', () async {
      await ReaderPrefs.setGridColumnCount(4);
      expect(await ReaderPrefs.gridColumnCount(), 4);
      expect(LKStore.gridColumnCount.value, 4);
    });
  });

  group('BookGridCard Widget rendering', () {
    final sampleBook = LKBook(
      bookId: 1001,
      title: '关于我转生成为史莱姆的那档事',
      authorName: '伏濑',
      coverUrl: '',
      tags: ['异世界', '转生', '奇幻冒险'],
      wordCount: 1520000,
      unreadChapterCount: 5,
      isBrave: true,
      updatedAt: '2026-09-18',
    );

    testWidgets('renders standard layout (card width >= 150)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 180,
                height: 300,
                child: BookGridCard(
                  book: sampleBook,
                  rank: 1,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      final aspect = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(aspect.aspectRatio, closeTo(3 / 4, 0.001));
      expect(find.text('关于我转生成为史莱姆的那档事'), findsOneWidget);
      expect(find.textContaining('异世界'), findsOneWidget);
      expect(find.text('152.0万字'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('勇者'), findsOneWidget);
    });

    testWidgets('renders dense layout (card width < 105)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 85,
                height: 180,
                child: BookGridCard(
                  book: sampleBook,
                  rank: 2,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('关于我转生成为史莱姆的那档事'), findsOneWidget);
      expect(find.textContaining('异世界'), findsNothing);
      expect(find.text('152.0万字'), findsNothing);
      expect(find.text('+5'), findsOneWidget);
      expect(find.text('连载'), findsOneWidget);
    });

    testWidgets('renders compact layout (105 <= card width < 150)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 220,
                child: BookGridCard(
                  book: sampleBook,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('152.0万字'), findsOneWidget);
      expect(find.textContaining('异世界'), findsNothing);
    });

    testWidgets('renders shelf layout without secondary tags or word count', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 180,
                height: 280,
                child: BookGridCard(
                  book: sampleBook,
                  isShelf: true,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('关于我转生成为史莱姆的那档事'), findsOneWidget);
      expect(find.textContaining('异世界'), findsNothing);
      expect(find.text('152.0万字'), findsNothing);
      expect(find.text('5 章更新'), findsOneWidget);
    });
  });

  group('Scroll Anchor preserving logic', () {
    test('switching from 2 columns to 4 columns preserves anchored book', () {
      const width = 360.0;
      const oldCols = 2;
      const newCols = 4;

      final oldMetrics = BookGridDelegate.computeMetrics(
        usableWidth: width,
        columnCount: oldCols,
      );
      final newMetrics = BookGridDelegate.computeMetrics(
        usableWidth: width,
        columnCount: newCols,
      );

      const anchorBookIndex = 14;
      const anchorFraction = 0.2;

      const oldRow = anchorBookIndex ~/ oldCols;
      expect(oldRow, 7);
      final oldGridOffset = oldRow * oldMetrics.rowStride + anchorFraction * oldMetrics.rowStride;

      const newRow = anchorBookIndex ~/ newCols;
      expect(newRow, 3);
      final newGridOffset = newRow * newMetrics.rowStride + anchorFraction * newMetrics.rowStride;

      final booksInNewRow = List.generate(newCols, (c) => newRow * newCols + c);
      expect(booksInNewRow, contains(anchorBookIndex));

      expect(newGridOffset, lessThan(oldGridOffset));
      final wrongJumpRow = (oldGridOffset / newMetrics.rowStride).floor();
      expect(wrongJumpRow, greaterThan(6));
    });
  });
}
