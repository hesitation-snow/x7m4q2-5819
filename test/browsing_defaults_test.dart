import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/dynamic_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  test('fresh preferences hide brave books and blur brave covers', () async {
    SharedPreferences.setMockInitialValues({});
    await LKStore.load();
    expect(LKStore.hideBraveBooks.value, isTrue);
    expect(LKStore.coverBlurMode.value, CoverBlurMode.brave);
    expect(LKStore.nsfwBlurCover.value, isTrue);
    expect(LKStore.enhancedContentStyleEnabled.value, isTrue);
  });

  test('explicit disabled preferences survive reload', () async {
    SharedPreferences.setMockInitialValues({});
    await LKStore.load();
    await LKStore.setHideBraveBooks(false);
    await LKStore.setCoverBlurMode(CoverBlurMode.none);
    await LKStore.setEnhancedContentStyleEnabled(false);
    await LKStore.load();
    expect(LKStore.hideBraveBooks.value, isFalse);
    expect(LKStore.coverBlurMode.value, CoverBlurMode.none);
    expect(LKStore.enhancedContentStyleEnabled.value, isFalse);
  });

  test('legacy cover preference remains respected', () async {
    SharedPreferences.setMockInitialValues({
      'nsfw_blur_cover': false,
      'hide_brave_books': false,
    });
    await LKStore.load();
    expect(LKStore.hideBraveBooks.value, isFalse);
    expect(LKStore.coverBlurMode.value, CoverBlurMode.none);
  });

  test('phone landscape is opt-in, persistent and uses wide feed', () async {
    SharedPreferences.setMockInitialValues({});
    await LKStore.load();
    expect(LKStore.landscapeEnabled.value, isFalse);
    expect(dynamicFeedColumnCount(const Size(800, 390)), 1);
    await LKStore.setLandscapeEnabled(true);
    await LKStore.load();
    expect(LKStore.landscapeEnabled.value, isTrue);
    expect(dynamicFeedColumnCount(const Size(800, 390)), 2);
    expect(dynamicFeedColumnCount(const Size(390, 800)), 1);
    await LKStore.setLandscapeEnabled(false);
    await LKStore.load();
    expect(LKStore.landscapeEnabled.value, isFalse);
    expect(dynamicFeedColumnCount(const Size(800, 1200)), 2);
  });

  test('legacy usage identifier and preference are removed', () async {
    SharedPreferences.setMockInitialValues({
      'anonymous_telemetry_reported_v1': true,
    });
    String? deletedKey;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method == 'delete') {
          deletedKey = (call.arguments as Map)['key'] as String?;
        }
        return null;
      },
    );

    await LKStore.removeLegacyUsageIdentifier();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('anonymous_telemetry_reported_v1'), isFalse);
    expect(deletedKey, 'anonymous_telemetry_installation_id_v1');
  });
}
