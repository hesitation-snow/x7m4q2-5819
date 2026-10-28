import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/laboratory_page.dart';
import 'package:yomiru/widgets/liquid_glass_bottom_bar.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LKStore.loadGlassConfiguration(await SharedPreferences.getInstance());
    LKStore.liquidGlassBottomBarEnabled.value = false;
    LKStore.dailyTreasureEnabled.value = false;
    LKStore.allMedalsEnabled.value = false;
  });
  test('device presets and partial legacy preferences do not overwrite data',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final phonePortrait = LKStore.glassConfigurationFor(const Size(390, 844));
    expect(phonePortrait.tint, .7);
    expect(phonePortrait.barWidth, closeTo(304.2, .01));
    expect(phonePortrait.barHeight, 60);
    final phoneLandscape = LKStore.glassConfigurationFor(const Size(844, 390));
    expect([
      phoneLandscape.tint,
      phoneLandscape.barWidth,
      phoneLandscape.barHeight
    ], [
      .7,
      320,
      60
    ]);
    for (final size in [const Size(768, 1024), const Size(1024, 768)]) {
      final c = LKStore.glassConfigurationFor(size);
      expect([c.tint, c.barWidth, c.barHeight], [.7, 360, 60]);
    }
    await LKStore.flushGlassConfiguration();
    expect(prefs.getKeys(), isEmpty);
    await prefs.setDouble('glass_tint', .09);
    await prefs.setDouble('glass_bar_width', 277);
    LKStore.loadGlassConfiguration(prefs);
    final tablet = LKStore.glassConfigurationFor(const Size(1024, 768));
    expect([tablet.tint, tablet.barWidth, tablet.barHeight], [.09, 277, 60]);
    final phone = LKStore.glassConfigurationFor(const Size(844, 390));
    expect([phone.tint, phone.barWidth, phone.barHeight], [.09, 277, 60]);
    await LKStore.flushGlassConfiguration();
    expect(prefs.containsKey('glass_bar_height'), isFalse);
  });

  test('invalid preferences are finite and bounded; legacy strength ignored',
      () async {
    SharedPreferences.setMockInitialValues({
      'glass_blur': double.nan,
      'glass_tint': 5.0,
      'glass_refraction': -.1,
      'glass_highlight': 'bad',
      'glass_bar_width': 500.0,
      'glass_bar_height': 4.0,
      'glass_floating_height': -3.0,
      'glass_keep_visible_on_scroll': true,
      'liquid_glass_intensity': 2
    });
    LKStore.loadGlassConfiguration(await SharedPreferences.getInstance());
    final c = LKStore.glassConfiguration.value;
    expect(c.blur, 3);
    expect(c.tint, 1);
    expect(c.refraction, 0);
    expect(c.highlight, .74);
    expect(c.barWidth, 360);
    expect(c.barHeight, 40);
    expect(c.floatingHeight, 0);
    expect(c.keepVisibleOnScroll, isTrue);
  });
  test('custom bar geometry and visibility preferences persist and reload',
      () async {
    LKStore.updateGlassConfiguration(GlassConfiguration(
      barWidth: 248,
      barHeight: 60,
      floatingHeight: 24,
      keepVisibleOnScroll: true,
    ));
    await LKStore.flushGlassConfiguration();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('glass_bar_width'), 248);
    expect(prefs.getDouble('glass_bar_height'), 60);
    expect(prefs.getDouble('glass_floating_height'), 24);
    expect(prefs.getBool('glass_keep_visible_on_scroll'), isTrue);

    LKStore.glassConfiguration.value = GlassConfiguration.defaults;
    LKStore.loadGlassConfiguration(prefs);
    final loaded = LKStore.glassConfiguration.value;
    expect(loaded.barWidth, 248);
    expect(loaded.barHeight, 60);
    expect(loaded.floatingHeight, 24);
    expect(loaded.keepVisibleOnScroll, isTrue);
  });

  testWidgets(
      'live preview, continuous sliders, debounce, reset and dispose flush',
      (tester) async {
    tester.view.physicalSize = const Size(599, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: LiquidGlassLabPage()));
    expect(find.byType(LiquidGlassBottomBar), findsOneWidget);
    var slider = tester.widget<Slider>(find.byKey(const ValueKey('背景模糊')));
    expect(slider.divisions, isNull);
    slider.onChanged!(8);
    await tester.pump();
    expect(LKStore.glassConfiguration.value.blur, 8);
    if (!ui.ImageFilter.isShaderFilterSupported) {
      expect(
          tester
              .widget<BackdropFilter>(find.byType(BackdropFilter))
              .filter
              .toString(),
          contains('8.0'));
    }
    await tester.scrollUntilVisible(find.text('重置悬浮底栏默认参数'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(
        tester.widget<Slider>(find.byKey(const ValueKey('折射强度'))).onChanged !=
            null,
        ui.ImageFilter.isShaderFilterSupported);
    await tester.tap(find.text('重置悬浮底栏默认参数'));
    await tester.pump();
    expect(LKStore.glassConfiguration.value.blur, 3);
    LKStore.updateGlassConfiguration(GlassConfiguration(blur: 13));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(LKStore.glassConfiguration.value.blur, 13);
  });
  testWidgets('custom dimensions and keep-visible setting update live',
      (tester) async {
    tester.view.physicalSize = const Size(599, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: LiquidGlassLabPage()));

    expect(find.textContaining('底栏宽度：320 dp'), findsOneWidget);
    expect(find.textContaining('底栏高度：60 dp'), findsOneWidget);
    expect(find.textContaining('悬浮高度：18 dp'), findsOneWidget);
    expect(tester.widget<Slider>(find.byKey(const ValueKey('底栏宽度'))).min, 220);

    tester.widget<Slider>(find.byKey(const ValueKey('底栏宽度'))).onChanged!(248);
    await tester.pump();
    tester.widget<Slider>(find.byKey(const ValueKey('底栏高度'))).onChanged!(60);
    await tester.pump();
    tester.widget<Slider>(find.byKey(const ValueKey('悬浮高度'))).onChanged!(24);
    await tester.pump();

    expect(LKStore.glassConfiguration.value.barWidth, 248);
    expect(LKStore.glassConfiguration.value.barHeight, 60);
    expect(LKStore.glassConfiguration.value.floatingHeight, 24);
    expect(tester.getSize(find.byKey(const ValueKey('liquid-glass-surface'))),
        const Size(248, 60));
    final previewRect =
        tester.getRect(find.byKey(const ValueKey('liquid-glass-surface')));
    expect(2000 - previewRect.bottom, closeTo(24, 1));

    final keepVisible = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('glass-keep-visible-on-scroll')));
    keepVisible.onChanged!(true);
    await tester.pump();
    expect(LKStore.glassConfiguration.value.keepVisibleOnScroll, isTrue);
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('glass-keep-visible-on-scroll')))
            .value,
        isTrue);
  });

  testWidgets('narrow large text light and dark layouts', (tester) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(2)),
              child: LiquidGlassLabPage())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final controls = find.byKey(const ValueKey('glass-controls'));
      final scrollable =
          find.descendant(of: controls, matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('高光强度')), 200,
          scrollable: scrollable);
      await tester.pumpAndSettle();
      final preview = tester.getRect(find.byType(LiquidGlassBottomBar));
      expect(preview.bottom, lessThanOrEqualTo(1000));
      expect(preview.top, greaterThan(0));
      expect(find.byKey(const ValueKey('高光强度')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('laboratory feature and interface switches persist',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LaboratoryPage()));

    expect(find.text('功能实验'), findsOneWidget);
    final treasureSwitch =
        find.byKey(const ValueKey('laboratory-daily-treasure-switch'));
    expect(tester.widget<SwitchListTile>(treasureSwitch).value, isFalse);
    await tester.tap(treasureSwitch);
    await tester.pumpAndSettle();
    expect(LKStore.dailyTreasureEnabled.value, isTrue);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('laboratory_daily_treasure_enabled'),
        isTrue);

    final allMedalsSwitch =
        find.byKey(const ValueKey('laboratory-all-medals-switch'));
    expect(tester.widget<SwitchListTile>(allMedalsSwitch).value, isFalse);
    await tester.tap(allMedalsSwitch);
    await tester.pumpAndSettle();
    expect(LKStore.allMedalsEnabled.value, isTrue);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('laboratory_all_medals_enabled'),
        isTrue);

    expect(find.byKey(const ValueKey('laboratory-liquid-glass-switch')),
        findsNothing);
    expect(find.byKey(const ValueKey('laboratory-liquid-glass-details-entry')),
        findsNothing);
  });

  testWidgets('tablet preview and reset use device preset and save snapshot',
      (tester) async {
    tester.view.physicalSize = const Size(768, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: LiquidGlassLabPage()));
    expect(tester.getSize(find.byKey(const ValueKey('liquid-glass-surface'))),
        const Size(360, 60));
    expect(tester.widget<Slider>(find.byKey(const ValueKey('底色遮罩'))).value, .7);
    expect(
        tester.widget<Slider>(find.byKey(const ValueKey('底栏宽度'))).value, 360);
    tester.widget<Slider>(find.byKey(const ValueKey('底栏宽度'))).onChanged!(280);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('重置悬浮底栏默认参数'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置悬浮底栏默认参数'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('liquid-glass-surface'))),
        const Size(360, 60));
    expect(LKStore.glassConfiguration.value.barWidth, 360);
    expect(LKStore.glassConfigurationFor(const Size(844, 390)).barWidth, 360);
  });
}
