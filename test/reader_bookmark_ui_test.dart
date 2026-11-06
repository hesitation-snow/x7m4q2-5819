import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/reader_bookmarks.dart';
import 'package:yomiru/api/lk_client.dart';

import 'reader_controls_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final paged in [true, false]) {
    testWidgets(
        'reader bookmark save, jump and delete in ${paged ? 'paged' : 'scroll'} mode',
        (tester) async {
      await fixture.withReader(tester,
          paged: paged,
          platform: TargetPlatform.android, run: (calls, key) async {
        await tester.tap(find.byTooltip('本章书签'));
        await tester.pumpAndSettle();
        if (find.byType(BottomSheet).evaluate().isEmpty) {
          await tester.pump(const Duration(seconds: 1));
          await tester.tap(find.byTooltip('本章书签'));
          await tester.pumpAndSettle();
        }
        expect(find.text('本章暂无书签'), findsOneWidget);
        await tester.tap(find.text('保存当前位置'));
        await tester.pumpAndSettle();
        final saved = await ReaderBookmarkStore.list(
            uid: 0, bookId: 1338, chapterId: 317815);
        expect(saved, hasLength(1));
        final page = paged
            ? tester.widget<PageView>(find.byType(PageView)).controller
            : null;
        final scroll = !paged
            ? tester
                .widget<CustomScrollView>(find.byType(CustomScrollView).first)
                .controller
            : null;
        double offset() => page?.page ?? scroll!.offset;
        final initial = offset();
        Navigator.of(tester.element(find.text('保存当前位置'))).pop();
        await tester.pumpAndSettle();
        await key('next');
        await tester.pumpAndSettle();
        if (!find.byTooltip('本章书签').hitTestable().evaluate().isNotEmpty) {
          await tester.tapAt(const Offset(200, 350));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('本章书签'));
        await tester.pumpAndSettle();
        final moved = offset();
        expect(moved, greaterThan(initial));
        await tester.tap(find.text(saved.single.context));
        await tester.pumpAndSettle();
        expect(offset(), lessThan(moved));
        expect(offset(), closeTo(initial, paged ? 2 : 100));
        if (find.byTooltip('本章书签').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(const Offset(200, 350));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('本章书签'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('删除书签'));
        await tester.pumpAndSettle();
        expect(find.text('本章暂无书签'), findsOneWidget);
      });
    });
  }
  testWidgets('account change hides bookmark summaries immediately',
      (tester) async {
    await fixture.withReader(tester,
        paged: false,
        platform: TargetPlatform.android, run: (calls, key) async {
      await tester.tap(find.byTooltip('本章书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存当前位置'));
      await tester.pumpAndSettle();
      final saved = (await ReaderBookmarkStore.list(
              uid: 0, bookId: 1338, chapterId: 317815))
          .single;
      expect(find.text(saved.context), findsOneWidget);
      LKClient.shared.session.securityKey = 'test-session';
      LKClient.shared.session.uid = 42;
      LKClient.sessionRev.value++;
      await tester.pump();
      expect(find.text(saved.context), findsNothing);
      expect(find.text('账户已切换'), findsOneWidget);
      LKClient.shared.session.clear();
      LKClient.sessionRev.value++;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
    });
  });
  testWidgets('logged-in session without uid cannot use anonymous bookmarks',
      (tester) async {
    await fixture.withReader(tester,
        paged: false,
        platform: TargetPlatform.android, run: (calls, key) async {
      LKClient.shared.session.securityKey = 'test-session';
      LKClient.shared.session.uid = 0;
      LKClient.sessionRev.value++;
      await tester.tap(find.byTooltip('本章书签'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(
          await ReaderBookmarkStore.list(
              uid: 0, bookId: 1338, chapterId: 317815),
          isEmpty);
      LKClient.shared.session.clear();
      LKClient.sessionRev.value++;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
    });
  });
}
