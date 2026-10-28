import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';

const phone = Size(400, 800);
const tablet = Size(800, 1200);

Future<SharedPreferences> load(Map<String, Object> values) async {
  await LKStore.flushGlassConfiguration();
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  LKStore.loadGlassConfiguration(prefs);
  return prefs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fresh install and constructors use 70% on phone and tablet', () async {
    final prefs = await load({});
    expect(GlassConfiguration().tint, .7);
    expect(GlassConfiguration.defaults.tint, .7);
    expect(GlassConfiguration.tabletDefaults.tint, .7);
    expect(GlassConfiguration(tint: double.nan).tint, .7);
    expect(LKStore.glassConfiguration.value.tint, .7);
    for (final size in [phone, tablet]) {
      expect(GlassConfiguration.defaultsFor(size).tint, .7);
      expect(LKStore.glassConfigurationFor(size).tint, .7);
      await LKStore.ensureGlassDimensions(size);
      expect(LKStore.glassConfigurationFor(size).tint, .7);
    }
    expect(prefs.containsKey('glass_tint'), isFalse);
  });

  test('old saved default and explicit custom values remain unchanged', () async {
    for (final tint in [.5, 0.0, .09, .84, 1.0]) {
      final prefs = await load({'glass_tint': tint});
      for (final size in [phone, tablet]) {
        expect(LKStore.glassConfigurationFor(size).tint, tint);
        await LKStore.ensureGlassDimensions(size);
        expect(LKStore.glassConfigurationFor(size).tint, tint);
      }
      expect(prefs.getDouble('glass_tint'), tint);
    }
  });

  test('custom edit persists through reload on both device sizes', () async {
    final prefs = await load({});
    LKStore.updateGlassConfiguration(
      LKStore.glassConfiguration.value.copyWith(tint: .32),
    );
    await LKStore.flushGlassConfiguration();
    expect(prefs.getDouble('glass_tint'), .32);
    LKStore.loadGlassConfiguration(prefs);
    expect(LKStore.glassConfigurationFor(phone).tint, .32);
    expect(LKStore.glassConfigurationFor(tablet).tint, .32);
  });

  test('reset saves new default and survives reload on both sizes', () async {
    for (final size in [phone, tablet]) {
      final prefs = await load({'glass_tint': .19});
      LKStore.updateGlassConfiguration(GlassConfiguration.defaultsFor(size));
      await LKStore.flushGlassConfiguration();
      expect(prefs.getDouble('glass_tint'), .7);
      LKStore.loadGlassConfiguration(prefs);
      expect(LKStore.glassConfigurationFor(phone).tint, .7);
      expect(LKStore.glassConfigurationFor(tablet).tint, .7);
    }
  });
}
