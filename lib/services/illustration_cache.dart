import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../api/store.dart';
import 'background_work_queue.dart';
import 'illustration_cache_manager.dart';
import 'illustration_identity.dart';

/// 全局小说插画专属持久化缓存：
/// - 独立磁盘缓存，已确认的临时签名不影响命中，不自动联网重新验证；
/// - 只预取阅读位置附近最多两张插画，与展示共用下载队列；
/// - 30 天是未使用文件的清理期限，不是联网刷新周期。
class YomiruIllustrationCache {
  static final IllustrationCacheManager _defaultManager =
      IllustrationCacheManager(
    Config(
      'yomiru_illustration_cache',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 2000,
    ),
  );

  static IllustrationCacheManager? _testingManager;
  static IllustrationCacheManager get manager =>
      _testingManager ?? _defaultManager;

  @visibleForTesting
  static void useManagerForTesting(IllustrationCacheManager? value) {
    _testingManager = value;
  }

  static final _decodes = BackgroundWorkQueue(concurrency: 1);
  static int get generation => manager.generation;
  static String keyFor(String url) => illustrationCacheKey(url);

  /// 检查指定插画在内存中是否已知已在磁盘缓存中（用于即时秒开判断）
  static bool isKnownCached(String url) => manager.isKnownCached(url.trim());

  /// 显式标记插画已缓存
  static void markKnownCached(String url) {
    final clean = url.trim();
    if (clean.isNotEmpty) {
      manager.markKnownCached(clean);
    }
  }

  /// 仅清空内存索引
  static void clearMemoryIndex() {
    manager.clearMemoryIndex();
  }

  /// 清空内存状态与磁盘缓存
  static Future<void> clear() async {
    await manager.emptyCache();
  }

  static final RegExp _imageTagRe = RegExp(
      r'''<img[^>]*src\s*=\s*["']([^"']+)["'][^>]*>''',
      caseSensitive: false);

  /// 从章节 HTML 正文中提取所有合法的 https 插画 URL
  static List<String> extractImageUrls(String html) {
    if (html.isEmpty) return const [];
    final urls = <String>[];
    for (final m in _imageTagRe.allMatches(html)) {
      final raw = m.group(1)?.trim() ?? '';
      final uri = Uri.tryParse(raw);
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        urls.add(raw);
      }
    }
    return urls;
  }

  /// 获取对应的 CachedNetworkImageProvider
  static ImageProvider provider(
    String url, {
    int? maxWidth,
    int? maxHeight,
  }) =>
      ResizeImage.resizeIfNeeded(
          maxWidth,
          maxHeight,
          CachedNetworkImageProvider(url,
              cacheManager: manager, cacheKey: keyFor(url)));

  /// 检查指定插画是否已经完整缓存于本地磁盘
  static Future<bool> isCached(String url) async {
    final clean = url.trim();
    if (clean.isEmpty) return false;
    try {
      return await manager.cachedFile(clean) != null;
    } catch (_) {
      return false;
    }
  }

  /// 批量检测已缓存于本地的插画 URL 集合
  static Future<Set<String>> filterCached(Iterable<String> urls) async {
    final cached = <String>{};
    for (final u in urls) {
      if (await isCached(u)) {
        cached.add(u);
      }
    }
    return cached;
  }

  /// 单张插画后台静默下载并缓存，已存在则直接返回本地文件
  static Future<File?> prefetch(String url,
      {bool Function()? isCurrent}) async {
    final clean = url.trim();
    if (clean.isEmpty) return null;
    try {
      return (await manager.obtain(clean, isCurrent: isCurrent))?.file;
    } catch (_) {
      return null;
    }
  }

  /// 批量并发节流预取插画列表，保证网络通畅且不阻塞主线程
  static Future<void> prefetchUrls(
    Iterable<String> urls, {
    int concurrency = 2,
    bool Function()? isCurrent,
  }) async {
    final cacheGeneration = generation;
    bool wanted() =>
        cacheGeneration == generation &&
        !LKStore.dataSaverMode.value &&
        (isCurrent == null || isCurrent());
    final cleanUrls = urls
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toSet()
        .take(2)
        .toList(growable: false);
    if (cleanUrls.isEmpty) return;

    var next = 0;
    Future<void> worker() async {
      while (next < cleanUrls.length && wanted()) {
        final currentUrl = cleanUrls[next++];
        await prefetch(currentUrl, isCurrent: wanted);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency.clamp(1, cleanUrls.length); i++) worker(),
    ]);
  }

  /// 预加载并预热当前正文中的插画（解码至内存供快速渲染）
  static void precache(
    BuildContext context,
    Iterable<String> urls, {
    int? maxWidth,
    int? maxHeight,
    bool Function()? isCurrent,
  }) {
    if (LKStore.dataSaverMode.value || !context.mounted || maxWidth == null) {
      return;
    }
    final cacheGeneration = generation;
    bool wanted() =>
        context.mounted &&
        cacheGeneration == generation &&
        !LKStore.dataSaverMode.value &&
        (isCurrent == null || isCurrent());
    final unique = urls
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toSet()
        .take(2);
    for (final url in unique) {
      unawaited(_decodes.run<void>(() async {
        try {
          // 内存预热仅使用磁盘就绪的图片，不额外开启一组网络请求。
          if (!await isCached(url) || !wanted() || !context.mounted) return;
          await precacheImage(
              provider(url, maxWidth: maxWidth, maxHeight: maxHeight), context,
              onError: (_, __) {});
        } catch (_) {
          // 按需展示仍可正常重试。
        }
      }, isCurrent: wanted));
    }
  }
}
