import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/widgets/common.dart';

void main() {
  setUp(() {
    LKStore.dataSaverMode.value = false;
  });

  tearDown(() => LKStore.coverBlurMode.value = CoverBlurMode.brave);

  testWidgets('peek is reset when a list slot receives a different cover',
      (tester) async {
    LKStore.coverBlurMode.value = CoverBlurMode.all;
    Widget cover(String url, {Key? key}) => MaterialApp(
            home: Scaffold(
          body: CoverImage(key: key, url: url, width: 100, height: 140),
        ));
    await tester.pumpWidget(cover('https://example.invalid/first'));
    await tester.tap(find.byIcon(Icons.visibility_off_rounded));
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing);
    await tester.pumpWidget(cover('https://example.invalid/second'));
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('same cover URL on different book identities does not reuse peek',
      (tester) async {
    LKStore.coverBlurMode.value = CoverBlurMode.all;
    Widget cover(int id) => MaterialApp(
            home: Scaffold(
                body: CoverImage(
          key: ValueKey(id),
          url: 'https://example.invalid/shared',
          width: 100,
          height: 140,
        )));
    await tester.pumpWidget(cover(1));
    await tester.tap(find.byIcon(Icons.visibility_off_rounded));
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing);
    await tester.pumpWidget(cover(2));
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets(
      'CoverImage renders placeholder with finite dimensions on empty url',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CoverImage(url: '', width: 76, height: 101),
        ),
      ),
    );

    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
  });

  testWidgets(
      'CoverImage renders placeholder safely inside infinite constraints (grid card)',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            height: 240,
            child: CoverImage(
              url: '',
              width: double.infinity,
              height: double.infinity,
              radius: 12,
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
  });

  testWidgets(
      'CoverImage respects data saver mode and renders placeholder in grid layout',
      (tester) async {
    LKStore.dataSaverMode.value = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            height: 240,
            child: CoverImage(
              url: 'https://example.com/cover.jpg',
              width: double.infinity,
              height: double.infinity,
              radius: 12,
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
  });
}
