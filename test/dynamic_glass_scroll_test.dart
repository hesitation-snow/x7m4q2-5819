import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/pages/home_page.dart';
import 'package:yomiru/pages/laboratory_page.dart';

void main() {
  testWidgets('dynamic feed remains scrollable across runtime glass changes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final oldClient = LKApi.client;
    final oldEnabled = LKStore.liquidGlassBottomBarEnabled.value;
    final oldConfig = LKStore.glassConfiguration.value;
    addTearDown(() {
      LKApi.client = oldClient;
      LKStore.liquidGlassBottomBarEnabled.value = oldEnabled;
      LKStore.glassConfiguration.value = oldConfig;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/api/dynamic/get-feed-v1')) {
        return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'list': [
                  for (var i = 0; i < 80; i++)
                    {
                      'dynamic_id': i + 1,
                      'content': 'dynamic item $i ' * 12,
                      'time': '2025-01-01'
                    }
                ],
                'has_more': false
              }
            }),
            200);
      }
      return http.Response('{"code":0,"data":{"list":[]}}', 200);
    }));
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1;
    LKStore.liquidGlassBottomBarEnabled.value = false;
    LKStore.glassConfiguration.value =
        oldConfig.copyWith(keepVisibleOnScroll: false);
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('动态').last);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }

    final scrollable = find.descendant(
        of: find.descendant(
            of: find.byType(DynamicPage),
            matching: find.byType(CustomScrollView)),
        matching: find.byType(Scrollable));
    ScrollPosition position() =>
        tester.state<ScrollableState>(scrollable).position;
    expect(position().maxScrollExtent, greaterThan(500));

    Future<void> drag(double step) async {
      final viewport = tester.getRect(scrollable);
      final gesture = await tester.startGesture(viewport.center);
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(Offset(0, step));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
    }

    Future<void> dragUp() => drag(-25);
    Future<void> dragDown() => drag(25);

    await dragUp();
    expect(position().pixels, greaterThan(100));
    final initialPageState = tester.state(find.byType(DynamicPage));
    final beforeGlass = position().pixels;
    // Keep HomePage mounted below the real laboratory routes while switching
    // settings, as happens when the user returns from the settings screen.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator
        .push(MaterialPageRoute<void>(builder: (_) => const LaboratoryPage()));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.tap(
        find.byKey(const ValueKey('laboratory-liquid-glass-details-entry')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    final glassSwitch = find.ancestor(
        of: find.text('液态玻璃底栏 (测试)'), matching: find.byType(SwitchListTile));
    await tester.ensureVisible(glassSwitch);
    await tester.tap(glassSwitch);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    final keepSwitch = find.ancestor(
        of: find.text('滚动时保持底栏显示'), matching: find.byType(SwitchListTile));
    await tester.ensureVisible(keepSwitch);
    await tester.tap(keepSwitch);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(LKStore.liquidGlassBottomBarEnabled.value, isTrue);
    expect(LKStore.glassConfiguration.value.keepVisibleOnScroll, isTrue);
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    navigator.pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(tester.state(find.byType(DynamicPage)), same(initialPageState));
    expect(position().pixels, closeTo(beforeGlass, 1));
    var beforeDown = position().pixels;
    await dragDown();
    expect(position().pixels, lessThan(beforeDown));
    await dragUp();
    expect(position().pixels, greaterThan(100));

    // Exercise changes at a nonzero offset, including turning glass off/on.
    LKStore.glassConfiguration.value =
        oldConfig.copyWith(keepVisibleOnScroll: false);
    await tester.pump();
    LKStore.glassConfiguration.value =
        oldConfig.copyWith(keepVisibleOnScroll: true);
    await tester.pump();
    var previous = position().pixels;
    await dragUp();
    expect(position().pixels, greaterThan(previous));
    LKStore.liquidGlassBottomBarEnabled.value = false;
    await tester.pump();
    LKStore.liquidGlassBottomBarEnabled.value = true;
    await tester.pump();
    previous = position().pixels;
    await dragUp();
    expect(position().pixels, greaterThan(previous));

    // Rotate while the same page is mounted; query the current position after
    // rebuilds rather than retaining an obsolete ScrollPosition reference.
    tester.view.physicalSize = const Size(1024, 768);
    await tester.pump();
    previous = position().pixels;
    await dragUp();
    expect(position().pixels, greaterThan(previous));
    expect(tester.takeException(), isNull);
  });
}
