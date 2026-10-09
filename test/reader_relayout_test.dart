import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/reader/reader_typography.dart';
import 'package:yomiru/widgets/reader_typography_sheet.dart';
import 'reader_controls_test.dart' show withReader;

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final paged in [false, true]) {
      testWidgets(
          'logical location survives rapid font and viewport changes: $platform paged=$paged',
          (tester) async {
        await withReader(tester, paged: paged, platform: platform,
            run: (calls, key) async {
          if (platform == TargetPlatform.iOS) {
            if (paged) {
              tester
                  .widget<PageView>(find.byType(PageView))
                  .controller!
                  .jumpToPage(5);
            } else {
              final controller = tester
                  .widget<CustomScrollView>(find.byType(CustomScrollView))
                  .controller!;
              controller.jumpTo(controller.position.maxScrollExtent * .3);
            }
            await tester.pump();
          } else {
            for (var i = 0; i < 5; i++) {
              await key('next');
              await tester.pump();
            }
          }
          await tester.pump(const Duration(milliseconds: 600));
          final before = await ReaderPrefs.readPosition(317815);
          expect(before, isNotNull);
          expect(before!.blockIndex, greaterThan(0));
          if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
            await tester.tapAt(const Offset(200, 350));
            await tester.pump();
          }
          await tester.tap(find.byTooltip('阅读设置'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('排版'));
          await tester.pumpAndSettle();
          final sheet = tester.widget<ReaderTypographySheet>(
              find.byType(ReaderTypographySheet));
          sheet.onFontSizeChanged!(23);
          expect(sheet.paged, paged);
          final columns = tester.widget<SegmentedButton<ReaderColumnMode>>(
              find.byType(SegmentedButton<ReaderColumnMode>));
          expect(columns.onSelectionChanged, paged ? isNotNull : isNull);
          sheet.onFontSizeChanged!(24);
          sheet.onFontSizeChanged!(25);
          await tester.pumpAndSettle();
          sheet.onPreviewChange(sheet.initialTypography.copyWith(
              lineHeight: 1.3,
              paragraphSpacing: 8,
              justify: true,
              firstLineIndentChars: 2));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('关闭阅读设置'));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 600));
          final afterFont = await ReaderPrefs.readPosition(317815);
          expect(afterFont!.blockIndex, closeTo(before.blockIndex, 1));
          tester.view.physicalSize = const Size(800, 400);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 600));
          final landscape = await ReaderPrefs.readPosition(317815);
          expect(landscape!.blockIndex, closeTo(afterFont.blockIndex, 1));
          tester.view.physicalSize = const Size(400, 800);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 600));
          final portrait = await ReaderPrefs.readPosition(317815);
          expect(portrait!.blockIndex, closeTo(landscape.blockIndex, 1));
          expect(tester.takeException(), isNull);
        });
      });
    }
  }
}
