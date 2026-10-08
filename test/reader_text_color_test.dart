import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/reader/reader_typography.dart';
import 'package:yomiru/widgets/reader_text_color_picker.dart';
import 'package:yomiru/widgets/reader_typography_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Hex Color Parsing and Formatting', () {
    test('parseHexColor parses standard 6-digit hex with and without hash', () {
      expect(parseHexColor('#FFFFFF'), equals(const Color(0xFFFFFFFF)));
      expect(parseHexColor('FFFFFF'), equals(const Color(0xFFFFFFFF)));
      expect(parseHexColor('#000000'), equals(const Color(0xFF000000)));
      expect(parseHexColor('#333333'), equals(const Color(0xFF333333)));
      expect(parseHexColor('F7F1E3'), equals(const Color(0xFFF7F1E3)));
    });

    test('parseHexColor expands 3-digit hex shorthand (#RGB and RGB)', () {
      // #F00 -> #FF0000
      expect(parseHexColor('#F00'), equals(const Color(0xFFFF0000)));
      expect(parseHexColor('F00'), equals(const Color(0xFFFF0000)));
      // #333 -> #333333
      expect(parseHexColor('#333'), equals(const Color(0xFF333333)));
      expect(parseHexColor('333'), equals(const Color(0xFF333333)));
      // #ABC -> #AABBCC
      expect(parseHexColor('#ABC'), equals(const Color(0xFFAABBCC)));
      expect(parseHexColor('abc'), equals(const Color(0xFFAABBCC)));
    });

    test('parseHexColor handles 4-digit and 8-digit hex', () {
      // #RGBA 4-digit -> expand #F123 to #FF112233
      expect(parseHexColor('#F123'), equals(const Color(0xFF112233)));
      // 8-digit ARGB
      expect(parseHexColor('#80FF0000'), equals(const Color(0x80FF0000)));
    });

    test('parseHexColor returns null for invalid strings', () {
      expect(parseHexColor(''), isNull);
      expect(parseHexColor('#'), isNull);
      expect(parseHexColor('#GGGGGG'), isNull);
      expect(parseHexColor('#12'), isNull);
      expect(parseHexColor('#12345'), isNull);
      expect(parseHexColor('not_a_color'), isNull);
    });

    test('formatHexColor outputs uppercase #RRGGBB', () {
      expect(formatHexColor(const Color(0xFF333333)), equals('#333333'));
      expect(formatHexColor(const Color(0xFFFFFFFF)), equals('#FFFFFF'));
      expect(formatHexColor(const Color(0xFFFF0000)), equals('#FF0000'));
      expect(formatHexColor(const Color(0xFF1E2D4A)), equals('#1E2D4A'));
      expect(formatHexColor(const Color(0xFF333333), leadingHash: false),
          equals('333333'));
    });
  });

  group('ReaderPrefs Text Color Persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('textColor returns null by default and saves properly', () async {
      expect(await ReaderPrefs.textColor(), isNull);

      const colorVal = 0xFF123456;
      await ReaderPrefs.setTextColor(colorVal);
      expect(await ReaderPrefs.textColor(), equals(colorVal));

      final all = await ReaderPrefs.loadAll();
      expect(all.textColor, equals(colorVal));

      // Resetting to null removes the preference
      await ReaderPrefs.setTextColor(null);
      expect(await ReaderPrefs.textColor(), isNull);
      final allReset = await ReaderPrefs.loadAll();
      expect(allReset.textColor, isNull);
    });
  });

  group('ReaderTextColorDialog Widget Tests', () {
    testWidgets('Renders dialog with preview, palette, hex input, and swatches',
        (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      ReaderTextColorResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showReaderTextColorDialog(
                    context: context,
                    initialColor: const Color(0xFF333333),
                    defaultColor: const Color(0xFF333333),
                    backgroundColor: const Color(0xFFFFFFFF),
                    isCustom: false,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Verify components exist
      expect(find.text('文字颜色'), findsOneWidget);
      expect(find.text('效果预览 (#333333 · 默认)'), findsOneWidget);
      expect(find.text('落霞与孤鹜齐飞，秋水共长天一色。'), findsOneWidget);
      expect(find.text('十六进制色号'), findsOneWidget);
      expect(find.text('推荐常用色'), findsOneWidget);
      expect(find.text('恢复默认'), findsOneWidget);
      expect(find.text('确定'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      // Tap cancel
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('Entering 3-digit shorthand hex (#F00) updates preview and commits',
        (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      ReaderTextColorResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showReaderTextColorDialog(
                    context: context,
                    initialColor: const Color(0xFF333333),
                    defaultColor: const Color(0xFF333333),
                    backgroundColor: const Color(0xFFFFFFFF),
                    isCustom: false,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Enter #F00 in TextField
      final textField = find.byType(TextField);
      expect(textField, findsOneWidget);
      await tester.enterText(textField, '#F00');
      await tester.pumpAndSettle();

      // Preview should show #FF0000
      expect(find.text('效果预览 (#FF0000)'), findsOneWidget);

      // Tap confirm
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.resetToDefault, isFalse);
      expect(result!.color, equals(const Color(0xFFFF0000)));
    });

    testWidgets('Tapping quick swatch updates color and commits', (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      ReaderTextColorResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showReaderTextColorDialog(
                    context: context,
                    initialColor: const Color(0xFF333333),
                    defaultColor: const Color(0xFF333333),
                    backgroundColor: const Color(0xFFFFFFFF),
                    isCustom: false,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Find quick swatches container or circles
      // Tap on the pure black swatch (first swatch in kQuickReadingTextColors)
      final swatchesFinder = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFF000000));
      expect(swatchesFinder, findsOneWidget);
      await tester.tap(swatchesFinder);
      await tester.pumpAndSettle();

      expect(find.text('效果预览 (#000000)'), findsOneWidget);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.resetToDefault, isFalse);
      expect(result!.color, equals(const Color(0xFF000000)));
    });

    testWidgets('Clicking 恢复默认 resets to default color', (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      ReaderTextColorResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showReaderTextColorDialog(
                    context: context,
                    initialColor: const Color(0xFFFF0000), // Custom red
                    defaultColor: const Color(0xFF333333),
                    backgroundColor: const Color(0xFFFFFFFF),
                    isCustom: true,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('效果预览 (#FF0000)'), findsOneWidget);

      // Tap 恢复默认
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();

      expect(find.text('效果预览 (#333333 · 默认)'), findsOneWidget);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.resetToDefault, isTrue);
    });

    testWidgets('ReaderTypographySheet onPickTextColor callback can be invoked',
        (tester) async {
      bool picked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderTypographySheet(
              initialTypography: const ReaderTypography(),
              fontSize: 17.0,
              textColor: const Color(0xFF112233),
              backgroundColor: const Color(0xFFFFFFFF),
              linkColor: const Color(0xFF1E88E5),
              isDark: false,
              onPickTextColor: () => picked = true,
              onPreviewChange: (_) {},
              onCommit: (_) {},
            ),
          ),
        ),
      );

      final colorEntry = find.text('文字颜色');
      expect(colorEntry, findsOneWidget);
      await tester.tap(colorEntry);
      await tester.pumpAndSettle();
      expect(picked, isTrue);
    });
  });
}
