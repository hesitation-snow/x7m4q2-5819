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

  static final Map<String, double> _aspectRatios = {};

  /// 获取指定插画的已知宽高比 (width / height)
  static double? getAspect(String url) {
    final clean = url.trim();
    if (clean.isEmpty) return null;
    return _aspectRatios[clean] ?? _aspectRatios[keyFor(clean)];
  }

  /// 缓存指定插画的已知宽高比
  static void setAspect(String url, double aspect) {
    final clean = url.trim();
    if (clean.isEmpty || aspect <= 0 || !aspect.isFinite) return;
    _aspectRatios[clean] = aspect;
    _aspectRatios[keyFor(clean)] = aspect;
  }

  /// 从图片二进制数据头极速解析原始宽高比 (width / height)
  static double? parseAspectFromBytes(List<int> bytes) {
    if (bytes.length < 24) return null;
    try {
      // 1. PNG: 89 50 4E 47 0D 0A 1A 0A
      if (bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        if (bytes.length >= 24) {
          final w = (bytes[16] << 24) |
              (bytes[17] << 16) |
              (bytes[18] << 8) |
              bytes[19];
          final h = (bytes[20] << 24) |
              (bytes[21] << 16) |
              (bytes[22] << 8) |
              bytes[23];
          if (w > 0 && h > 0) return w / h;
        }
      }

      // 2. GIF: GIF87a / GIF89a
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
        if (bytes.length >= 10) {
          final w = bytes[6] | (bytes[7] << 8);
          final h = bytes[8] | (bytes[9] << 8);
          if (w > 0 && h > 0) return w / h;
        }
      }

      // 3. WebP: RIFF ... WEBP
      if (bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes.length >= 30 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        if (bytes[12] == 0x56 &&
            bytes[13] == 0x50 &&
            bytes[14] == 0x38 &&
            bytes[15] == 0x58) {
          final w = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
          final h = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
          if (w > 0 && h > 0) return w / h;
        }
        if (bytes[12] == 0x56 &&
            bytes[13] == 0x50 &&
            bytes[14] == 0x38 &&
            bytes[15] == 0x20) {
          if (bytes.length >= 30 &&
              bytes[23] == 0x9D &&
              bytes[24] == 0x01 &&
              bytes[25] == 0x2A) {
            final w = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
            final h = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
            if (w > 0 && h > 0) return w / h;
          }
        }
        if (bytes[12] == 0x56 &&
            bytes[13] == 0x50 &&
            bytes[14] == 0x38 &&
            bytes[15] == 0x4C) {
          if (bytes.length >= 25 && bytes[20] == 0x2F) {
            final b1 = bytes[21];
            final b2 = bytes[22];
            final b3 = bytes[23];
            final b4 = bytes[24];
            final w = 1 + (((b2 & 0x3F) << 8) | b1);
            final h = 1 + (((b4 & 0xF) << 10) | (b3 << 2) | ((b2 & 0xC0) >> 6));
            if (w > 0 && h > 0) return w / h;
          }
        }
      }

      // 4. JPEG: FF D8 ...
      if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
        var idx = 2;
        while (idx < bytes.length - 8) {
          if (bytes[idx] != 0xFF) {
            idx++;
            continue;
          }
          final marker = bytes[idx + 1];
          if ((marker >= 0xC0 && marker <= 0xC3) ||
              (marker >= 0xC5 && marker <= 0xC7) ||
              (marker >= 0xC9 && marker <= 0xCB) ||
              (marker >= 0xCD && marker <= 0xCF)) {
            final h = (bytes[idx + 5] << 8) | bytes[idx + 6];
            final w = (bytes[idx + 7] << 8) | bytes[idx + 8];
            if (w > 0 && h > 0) return w / h;
            break;
          }
          if (marker == 0xDA || marker == 0xD9) {
            break;
          }
          final length = (bytes[idx + 2] << 8) | bytes[idx + 3];
          if (length < 2) break;
          idx += 2 + length;
        }
      }
    } catch (_) {}
    return null;
  }

  /// 异步从本地缓存中检测并解析插画宽高比
  static Future<double?> resolveAspect(String url) async {
    final clean = url.trim();
    if (clean.isEmpty) return null;
    final cached = getAspect(clean);
    if (cached != null) return cached;
    try {
      final fileInfo = await manager.getFileFromCache(keyFor(clean));
      final file = fileInfo?.file;
      if (file != null && await file.exists()) {
        final bytes = await file.openRead(0, 4096).expand((b) => b).toList();
        final aspect = parseAspectFromBytes(bytes);
        if (aspect != null) {
          setAspect(clean, aspect);
          return aspect;
        }
      }
    } catch (_) {}
    return null;
  }

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
      r'''<img[^>]*\bsrc\s*=\s*["']?([^"'>\s]+)["']?[^>]*>''',
      caseSensitive: false);

  /// 从章节 HTML 正文中提取所有合法的插画 URL（支持 &amp; 转义与 http/https）
  static List<String> extractImageUrls(String html) {
    if (html.isEmpty) return const [];
    final urls = <String>[];
    for (final m in _imageTagRe.allMatches(html)) {
      var raw = m.group(1)?.trim() ?? '';
      if (raw.isEmpty) continue;
      raw = raw.replaceAll('&amp;', '&');
      if (raw.startsWith('//')) {
        raw = 'https:$raw';
      }
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
