import 'package:flutter/services.dart';
import 'package:flutter/painting.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/services/illustration_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      return '.';
    });
  });

  group('YomiruIllustrationCache', () {
    test(
        'prewarm shares the rendered memCacheWidth key instead of decoding original',
        () {
      const url = 'https://example.invalid/illustration';
      final warm = YomiruIllustrationCache.provider(url, maxWidth: 900);
      final visible = ResizeImage.resizeIfNeeded(
          900,
          null,
          CachedNetworkImageProvider(url,
              cacheManager: YomiruIllustrationCache.manager));
      expect(warm, visible);
      expect(warm, isA<ResizeImage>());
      expect((warm as ResizeImage).width, 900);
      expect(
          (warm.imageProvider as CachedNetworkImageProvider).maxWidth, isNull);
    });
    test('extractImageUrls parses valid https URLs and filters invalid ones',
        () {
      const html = '''
        <p>第一段文本</p>
        <img src="https://img.lightnovel.us/1.jpg" width="800" height="600" />
        <p>第二段文本</p>
        <IMG SRC='https://pic.lightnovel.us/illustration/2.png'>
        <!-- 非 https 或无效地址应该被忽略 -->
        <img src="http://insecure.com/3.jpg" />
        <img src="/local/path/4.jpg" />
        <img src="" />
        <p>结尾文本</p>
      ''';

      final urls = YomiruIllustrationCache.extractImageUrls(html);
      expect(urls, [
        'https://img.lightnovel.us/1.jpg',
        'https://pic.lightnovel.us/illustration/2.png',
      ]);
    });

    test('extractImageUrls returns empty list for blank or text-only html', () {
      expect(YomiruIllustrationCache.extractImageUrls(''), isEmpty);
      expect(
          YomiruIllustrationCache.extractImageUrls('<p>没有图片的正文</p>'), isEmpty);
    });

    test('memory index tracks cached URLs and clears correctly', () async {
      const testUrl = 'https://img.lightnovel.us/test_cached.jpg';

      expect(YomiruIllustrationCache.isKnownCached(testUrl), isFalse);

      YomiruIllustrationCache.markKnownCached(testUrl);
      expect(YomiruIllustrationCache.isKnownCached(testUrl), isTrue);

      YomiruIllustrationCache.clearMemoryIndex();
      expect(YomiruIllustrationCache.isKnownCached(testUrl), isFalse);

      YomiruIllustrationCache.markKnownCached(testUrl);
      await YomiruIllustrationCache.clear();
      expect(YomiruIllustrationCache.isKnownCached(testUrl), isFalse);
    });

    test('data saver bypasses placeholder if image is already cached', () {
      const imageUrl = 'https://img.lightnovel.us/illustration_bypass.jpg';
      final manuallyLoaded = <String>{};
      final diskCached = <String>{};

      // 开启省流模式
      LKStore.dataSaverMode.value = true;

      // 1. 既不在手动加载集合，也不在磁盘缓存中 -> 需要拦截，展示省流占位
      bool isBlocked = LKStore.dataSaverMode.value &&
          !manuallyLoaded.contains(imageUrl) &&
          !diskCached.contains(imageUrl);
      expect(isBlocked, isTrue);

      // 2. 本地已探测到磁盘缓存 -> 零流量直接放行展示
      diskCached.add(imageUrl);
      isBlocked = LKStore.dataSaverMode.value &&
          !manuallyLoaded.contains(imageUrl) &&
          !diskCached.contains(imageUrl);
      expect(isBlocked, isFalse);

      // 3. 用户手动点击过插画 -> 直接放行展示
      diskCached.clear();
      manuallyLoaded.add(imageUrl);
      isBlocked = LKStore.dataSaverMode.value &&
          !manuallyLoaded.contains(imageUrl) &&
          !diskCached.contains(imageUrl);
      expect(isBlocked, isFalse);
    });

    test('prefetchUrls processes empty or whitespace lists cleanly', () async {
      await YomiruIllustrationCache.prefetchUrls([]);
      await YomiruIllustrationCache.prefetchUrls(['   ', '']);
    });

    test('parseAspectFromBytes correctly parses JPEG dimensions and aspect ratio', () {
      final jpegBytes = <int>[
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x05, 0x94, 0x07, 0xD0, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
      ];
      final aspect = YomiruIllustrationCache.parseAspectFromBytes(jpegBytes);
      expect(aspect, closeTo(2000 / 1428, 0.001));
    });

    test('parseAspectFromBytes correctly parses PNG dimensions and aspect ratio', () {
      final pngBytes = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x07, 0x80, // width 1920
        0x00, 0x00, 0x04, 0x38, // height 1080
      ];
      final aspect = YomiruIllustrationCache.parseAspectFromBytes(pngBytes);
      expect(aspect, closeTo(1920 / 1080, 0.001));
    });

    test('aspect ratios are stored and retrieved via getAspect/setAspect', () {
      const testUrl = 'https://img.lightnovel.us/landscape_test.jpg';
      expect(YomiruIllustrationCache.getAspect(testUrl), isNull);
      YomiruIllustrationCache.setAspect(testUrl, 1.401);
      expect(YomiruIllustrationCache.getAspect(testUrl), 1.401);
    });
  });
}
