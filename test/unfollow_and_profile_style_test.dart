import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/widgets/common.dart';
import 'package:yomiru/pages/shelf_page.dart';

void main() {
  group('confirmUnfollowUser dialog', () {
    testWidgets('shows dialog with nickname and returns false on cancel',
        (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await confirmUnfollowUser(context, nickname: '测试用户');
              },
              child: const Text('Unfollow'),
            ),
          ),
        ),
      );

      // Click unfollow button to trigger dialog
      await tester.tap(find.text('Unfollow'));
      await tester.pumpAndSettle();

      // Verify dialog is shown
      expect(find.text('取消关注'), findsOneWidget);
      expect(find.text('确定不再关注 “测试用户” 吗？'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('确定取关'), findsOneWidget);

      // Tap Cancel
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // Dialog dismissed and result is false
      expect(find.text('取消关注'), findsNothing);
      expect(result, isFalse);
    });

    testWidgets('returns true on confirm', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await confirmUnfollowUser(context);
              },
              child: const Text('Unfollow'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Unfollow'));
      await tester.pumpAndSettle();

      expect(find.text('确定不再关注 该用户 吗？'), findsOneWidget);

      // Tap Confirm
      await tester.tap(find.text('确定取关'));
      await tester.pumpAndSettle();

      expect(find.text('取消关注'), findsNothing);
      expect(result, isTrue);
    });
  });

  group('ShelfPage refresh indicator', () {
    testWidgets('has RefreshIndicator wrapping body', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ShelfPage(embedded: true),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(RefreshIndicator), findsWidgets);
    });
  });
}
