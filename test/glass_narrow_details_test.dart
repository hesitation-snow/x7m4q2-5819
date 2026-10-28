import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/laboratory_page.dart';

void main() {
  testWidgets('details initialize defaults in a narrow window', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    LKStore.loadGlassConfiguration(preferences);
    tester.view.physicalSize = const Size(200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: LiquidGlassLabPage()));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('底栏宽度')), 200,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('glass-controls')),
            matching: find.byType(Scrollable)));
    final slider = tester.widget<Slider>(find.byKey(const ValueKey('底栏宽度')));
    expect(slider.value, closeTo(156, .01));
    expect(slider.min, lessThanOrEqualTo(slider.value));
    expect(LKStore.glassConfiguration.value.barWidth, closeTo(156, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
