import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../api/lk_client.dart';
import '../api/reader_cache.dart';
import '../api/store.dart';
import 'avatar_cache.dart';
import 'illustration_cache.dart';

/// 统一清理可重新生成或从网络下载的缓存。
class YomiruAppCache {
  const YomiruAppCache._();

  static Future<void> clearAll() async {
    try {
      await clearGroups({
        '小说正文': ReaderContentCache.clear,
        '网络响应': LKClient.shared.clearResponseCache,
        '页面数据': LKStore.clearContentCaches,
        '图片': DefaultCacheManager().emptyCache,
        '头像与勋章': SmallImagePreloads.clear,
        '小说插画': YomiruIllustrationCache.clear,
      });
    } finally {
      // 磁盘清理后同步丢弃当前进程中已经解码的图片。
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    }
  }

  /// Finish every group even if another fails; report only failed categories.
  static Future<void> clearGroups(
      Map<String, Future<void> Function()> groups) async {
    final failed = <String>[];
    await Future.wait(groups.entries.map((entry) async {
      try {
        await entry.value();
      } catch (_) {
        failed.add(entry.key);
      }
    }));
    if (failed.isNotEmpty) throw CacheClearException(failed);
  }

  static Future<int> sizeBytes() async {
    final sizes = await Future.wait<int>([
      ReaderContentCache.sizeBytes(),
      _cacheManagerSize(DefaultCacheManager()),
      _cacheManagerSize(YomiruAvatarCache.manager),
      _cacheManagerSize(YomiruMedalCache.manager),
      _cacheManagerSize(YomiruIllustrationCache.manager),
      LKClient.shared.responseCacheSizeBytes(),
      LKStore.contentCacheSizeBytes(),
    ]);
    return sizes.fold<int>(0, (total, size) => total + size);
  }

  static Future<int> _cacheManagerSize(CacheManager manager) async {
    try {
      return await manager.store.getCacheSize();
    } catch (_) {
      return 0;
    }
  }
}

class CacheClearException implements Exception {
  CacheClearException(this.groups);
  final List<String> groups;
  @override
  String toString() => '${groups.join('、')}未完全清除，请稍后重试';
}
