import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/widgets/liquid_glass_bottom_bar.dart';

const _destinations = [
  LiquidGlassDestination(
      icon: Icons.home, selectedIcon: Icons.home, label: 'A'),
  LiquidGlassDestination(
      icon: Icons.book, selectedIcon: Icons.book, label: 'B'),
  LiquidGlassDestination(
      icon: Icons.star, selectedIcon: Icons.star, label: 'C'),
  LiquidGlassDestination(
      icon: Icons.person, selectedIcon: Icons.person, label: 'D'),
];

Widget _bar(Size size) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Scaffold(
              bottomNavigationBar: LiquidGlassBottomBar(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                destinations: _destinations,
              ),
            ),
          ),
        ),
      ),
    );

Future<SharedPreferences> _load(Map<String, Object> values) async {
  await LKStore.flushGlassConfiguration();
  SharedPreferences.setMockInitialValues(values);
  final p = await SharedPreferences.getInstance();
  LKStore.loadGlassConfiguration(p);
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('phone, tablet and narrow defaults use current viewport', () {
    expect(GlassConfiguration.defaultsFor(const Size(400, 800)).barWidth, 312);
    expect(GlassConfiguration.defaultsFor(const Size(500, 800)).barWidth, 320);
    expect(GlassConfiguration.defaultsFor(const Size(800, 1200)).barWidth, 360);
    expect(GlassConfiguration.defaultsFor(const Size(100, 500)).barWidth, 68);
    expect(GlassConfiguration.defaultsFor(const Size(400, 800)).barHeight, 60);
    expect(GlassConfiguration.defaultsFor(const Size(400, 800)).tint, .7);
  });

  test('fresh install persists only generated dimensions', () async {
    final p = await _load({});
    await LKStore.ensureGlassDimensions(const Size(400, 800));
    expect(p.getDouble('glass_bar_width'), 312);
    expect(p.getDouble('glass_bar_height'), 60);
    expect(p.containsKey('glass_tint'), isFalse);
  });

  test('only missing dimensions are saved, preserving old configuration',
      () async {
    final p = await _load({'glass_bar_width': 277.0, 'glass_tint': .09});
    await LKStore.ensureGlassDimensions(const Size(400, 800));
    expect(p.getDouble('glass_bar_width'), 277);
    expect(p.getDouble('glass_bar_height'), 60);
    expect(p.getDouble('glass_tint'), .09);
    expect(p.containsKey('glass_blur'), isFalse);
    await LKStore.ensureGlassDimensions(const Size(800, 1200));
    expect(p.getDouble('glass_bar_width'), 277);
    expect(LKStore.glassConfiguration.value.barHeight, 60);
  });

  test('concurrent initialization and custom edit persist in order', () async {
    final p = await _load({});
    final initial = LKStore.ensureGlassDimensions(const Size(400, 800));
    LKStore.updateGlassConfiguration(LKStore.glassConfiguration.value
        .copyWith(barWidth: 280, barHeight: 55));
    final edited = LKStore.flushGlassConfiguration();
    await Future.wait([initial, edited]);
    expect(p.getDouble('glass_bar_width'), 280);
    expect(p.getDouble('glass_bar_height'), 55);
  });

  test('reset saves current device defaults', () async {
    final p = await _load({'glass_bar_width': 280.0, 'glass_bar_height': 55.0});
    LKStore.updateGlassConfiguration(
        GlassConfiguration.defaultsFor(const Size(350, 800)));
    await LKStore.flushGlassConfiguration();
    expect(p.getDouble('glass_bar_width'), closeTo(273, .001));
    expect(p.getDouble('glass_bar_height'), 60);
    expect(p.getDouble('glass_tint'), .7);
  });

  testWidgets('first display persists dimensions; resize only shrinks display',
      (tester) async {
    await tester.runAsync(() => _load({}));
    await tester.pumpWidget(_bar(const Size(400, 600)));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final surface = find.byKey(const ValueKey('liquid-glass-surface'));
    expect(tester.getSize(surface).width, 312);
    expect(LKStore.glassConfiguration.value.barWidth, 312);
    expect(LKStore.glassConfiguration.value.barHeight, 60);
    await tester.pumpWidget(_bar(const Size(220, 600)));
    await tester.pumpAndSettle();
    expect(tester.getSize(surface).width, 188);
    expect(LKStore.glassConfiguration.value.barWidth, 312);
    await tester.pumpWidget(_bar(const Size(600, 400)));
    await tester.pumpAndSettle();
    expect(tester.getSize(surface).width, 312);
    expect(LKStore.glassConfiguration.value.barWidth, 312);
  });
}
