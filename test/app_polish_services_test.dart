import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/layout_cache.dart';
import 'package:yomiru/reader/pagination_key.dart';
import 'package:yomiru/services/app_cache.dart';
import 'package:yomiru/services/avatar_cache.dart';
import 'package:yomiru/services/background_work_queue.dart';
import 'package:yomiru/services/deadline_countdown.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary =
        await Directory.systemTemp.createTemp('yomiru-small-image-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => temporary.path);
  });
  tearDownAll(() async {
    await YomiruAvatarCache.manager.dispose();
    await YomiruMedalCache.manager.dispose();
    if (temporary.path.startsWith(Directory.systemTemp.path) &&
        await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  test('deadline catches up after background time; expiry only fires once', () {
    var now = DateTime(2026, 9, 14, 12);
    final clock = DeadlineCountdown(now: () => now);
    addTearDown(clock.dispose);
    var expired = 0;
    clock.onElapsed = () => expired++;
    clock.start(60);
    now = now.add(const Duration(seconds: 43));
    clock.refresh();
    expect(clock.value, 17);
    now = now.add(const Duration(seconds: 30));
    clock.refresh();
    clock.refresh();
    expect(clock.value, 0);
    expect(expired, 1);
    clock.start(20);
    clock.stop();
    now = now.add(const Duration(seconds: 30));
    clock.refresh();
    expect(expired, 1);
  });

  test(
      'layout cache reuses recent layouts, bounds memory and invalidates content',
      () {
    final cache = ReaderLayoutCache<ReaderPaginationKey, Object>();
    final content = Object();
    var builds = 0;
    Object build() {
      builds++;
      return Object();
    }

    ReaderPaginationKey key(Object content, String metrics) =>
        ReaderPaginationKey(content: content, layout: metrics);
    final portrait = cache.resolve(key(content, 'portrait'), build);
    cache.resolve(key(content, 'landscape'), build);
    expect(cache.resolve(key(content, 'portrait'), build), same(portrait));
    expect(builds, 2);
    cache.resolve(key(content, 'larger text'), build);
    cache.resolve(key(content, 'landscape'), build);
    expect(builds, 4);
    cache.resolve(key(Object(), 'landscape'), build);
    expect(builds, 5);
    cache.clear();
    cache.resolve(key(content, 'landscape'), build);
    expect(builds, 6);
  });

  test('clearing waits for all groups and reports only failed categories',
      () async {
    final gate = Completer<void>();
    var completed = false;
    final clear = YomiruAppCache.clearGroups({
      '小说插画': () async => throw StateError('disk denied'),
      '页面数据': () async {
        await gate.future;
        completed = true;
      },
    });
    final assertion = expectLater(
        clear,
        throwsA(isA<CacheClearException>()
            .having((error) => error.groups, 'failed groups', ['小说插画'])));
    gate.complete();
    await assertion;
    expect(completed, isTrue);
  });

  test('queue idle barrier includes pending work and releases on failure',
      () async {
    final queue = BackgroundWorkQueue(concurrency: 1);
    final gate = Completer<void>();
    final first = queue.run<void>(() => gate.future);
    final second = queue.run<void>(() async => throw StateError('failed'));
    final failed = expectLater(second, throwsStateError);
    var idle = false;
    final drained = queue.whenIdle.then((_) => idle = true);
    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse);
    gate.complete();
    await Future.wait([first, failed, drained]);
    expect(idle, isTrue);
    await queue.whenIdle;
  });

  test('avatars and medals use stable bounded decode providers', () {
    for (final provider in [
      YomiruAvatarCache.provider,
      YomiruMedalCache.provider
    ]) {
      final image =
          provider('https://example.invalid/image.png') as ResizeImage;
      expect(image.width, 256);
      expect(image.height, 256);
      expect(image.policy, ResizeImagePolicy.fit);
      expect(image, provider('https://example.invalid/image.png'));
    }
  });
}
