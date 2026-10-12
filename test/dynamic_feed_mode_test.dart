import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/pages/dynamic_feed_source_sheet.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dynamicFeedMode.value = DynamicFeedMode.anonymousFollow;
  });
  tearDown(
      () => LKStore.dynamicFeedMode.value = DynamicFeedMode.anonymousFollow);

  test('missing or unknown preference keeps the anonymous default', () {
    expect(LKStore.parseDynamicFeedMode(null), DynamicFeedMode.anonymousFollow);
    expect(LKStore.parseDynamicFeedMode('unknown'),
        DynamicFeedMode.anonymousFollow);
  });
  test('source selection is persisted and can be restored', () async {
    await LKStore.setDynamicFeedMode(DynamicFeedMode.legacyMixed);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('dynamic_feed_mode'), 'legacyMixed');
    expect(LKStore.parseDynamicFeedMode(prefs.getString('dynamic_feed_mode')),
        DynamicFeedMode.legacyMixed);
    expect(LKStore.dynamicFeedMode.value, DynamicFeedMode.legacyMixed);
    await LKStore.setDynamicFeedMode(DynamicFeedMode.anonymousFollow);
    expect(prefs.getString('dynamic_feed_mode'), 'anonymousFollow');
  });
  test(
      'legacy restores mixed with current authentication, without changing follow',
      () {
    for (final loggedIn in [true, false]) {
      final source = dynamicFeedSource('mixed',
          loggedIn: loggedIn, mode: DynamicFeedMode.legacyMixed);
      expect(source.tab, 'mixed');
      expect(source.anonymous, !loggedIn);
      expect(
          dynamicFeedSource('follow',
              loggedIn: loggedIn, mode: DynamicFeedMode.legacyMixed),
          dynamicFeedSource('follow', loggedIn: loggedIn));
    }
  });
  test('default and fallback sources never share a cache namespace', () {
    final anonymous = dynamicFeedSource('mixed', loggedIn: true);
    final authenticatedLegacy = dynamicFeedSource('mixed',
        loggedIn: true, mode: DynamicFeedMode.legacyMixed);
    final guestLegacy = dynamicFeedSource('mixed',
        loggedIn: false, mode: DynamicFeedMode.legacyMixed);
    expect({
      dynamicFeedCacheVariant(anonymous),
      dynamicFeedCacheVariant(authenticatedLegacy),
      dynamicFeedCacheVariant(guestLegacy)
    }, hasLength(3));
  });
  for (final largeText in [false, true]) {
    testWidgets('sheet switches and saves source, largeText=$largeText',
        (tester) async {
      tester.view.physicalSize = Size(390, largeText ? 280 : 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(largeText ? 2 : 1)),
              child: child!),
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          builder: (_) => const DynamicFeedSourceSheet()),
                      child: const Text('选择数据源'))))));
      await tester.tap(find.text('选择数据源'));
      await tester.pumpAndSettle();
      expect(find.text('匿名关注'), findsOneWidget);
      await tester.ensureVisible(find.text('旧版动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旧版动态'));
      await tester.pumpAndSettle();
      expect(LKStore.dynamicFeedMode.value, DynamicFeedMode.legacyMixed);
      expect(find.byType(DynamicFeedSourceSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
