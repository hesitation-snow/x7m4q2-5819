import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../api/store.dart';
import 'background_work_queue.dart';

/// 全局头像缓存：优先显示本地文件，并在缓存过期后后台重新获取。
class YomiruAvatarCache {
  static final CacheManager manager = CacheManager(
    Config(
      'yomiru_avatar_cache',
      stalePeriod: const Duration(hours: 12),
      maxNrOfCacheObjects: 500,
    ),
  );

  static ImageProvider provider(String url) =>
      ResizeImage(CachedNetworkImageProvider(url, cacheManager: manager),
          width: 256, height: 256, policy: ResizeImagePolicy.fit);

  static ImageProvider? providerOrNull(String url) {
    if (LKStore.dataSaverMode.value || url.trim().isEmpty) return null;
    return provider(url);
  }

  /// 预加载当前页面的头像。失败时静默处理，不阻塞页面内容。
  static void precache(BuildContext context, Iterable<String> urls) {
    if (LKStore.dataSaverMode.value) return;
    final unique = urls
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toSet()
        .take(16);
    SmallImagePreloads.precache(context, unique, provider, 'avatar');
  }
}

/// 勋章图使用独立缓存，避免和头像缓存互相挤占；网络可用时会按缓存策略后台更新。
class YomiruMedalCache {
  static final CacheManager manager = CacheManager(
    Config(
      'yomiru_medal_cache',
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 1000,
    ),
  );

  static ImageProvider provider(String url) =>
      ResizeImage(CachedNetworkImageProvider(url, cacheManager: manager),
          width: 256, height: 256, policy: ResizeImagePolicy.fit);

  static ImageProvider? providerOrNull(String url) {
    if (LKStore.dataSaverMode.value || url.trim().isEmpty) return null;
    return provider(url);
  }

  /// 预加载勋章图到本地缓存，失败时不影响商城页面。
  static void precache(BuildContext context, Iterable<String> urls) {
    if (LKStore.dataSaverMode.value) return;
    final unique = urls
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toSet()
        .take(60);
    SmallImagePreloads.precache(context, unique, provider, 'medal');
  }
}

/// All pages share a small prefetch budget; visible images still load on demand.
class SmallImagePreloads {
  static final _queue = BackgroundWorkQueue(concurrency: 3);
  static final _pending = <String>{};
  static int _generation = 0;
  static bool _paused = false;

  static void precache(BuildContext context, Iterable<String> urls,
      ImageProvider Function(String) provider, String kind) {
    if (_paused || !context.mounted || LKStore.dataSaverMode.value) return;
    final generation = _generation;
    bool current() =>
        !_paused &&
        generation == _generation &&
        context.mounted &&
        !LKStore.dataSaverMode.value;
    for (final url in urls) {
      final key = '$kind|$url';
      if (!_pending.add(key)) continue;
      unawaited(_queue
          .run<void>(() async {
            await precacheImage(provider(url), context, onError: (_, __) {});
          }, isCurrent: current)
          .catchError((_) {})
          .whenComplete(() {
            _pending.remove(key);
          }));
    }
  }

  static Future<void> clear() async {
    _paused = true;
    _generation++;
    try {
      // Do not report a successful clear while old preloads can write it back.
      await _queue.whenIdle.timeout(const Duration(seconds: 20));
      await Future.wait([
        YomiruAvatarCache.manager.emptyCache(),
        YomiruMedalCache.manager.emptyCache(),
      ]);
    } finally {
      _paused = false;
    }
  }
}
