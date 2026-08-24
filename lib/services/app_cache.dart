import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../api/lk_client.dart';
import '../api/reader_cache.dart';
import '../api/store.dart';
import 'avatar_cache.dart';

/// 统一清理可重新生成或从网络下载的缓存。
class YomiruAppCache {
  const YomiruAppCache._();

  static Future<void> clearAll() async {
    try {
      await Future.wait<void>([
        ReaderContentCache.clear(),
        LKClient.shared.clearResponseCache(),
        LKStore.clearContentCaches(),
        DefaultCacheManager().emptyCache(),
        YomiruAvatarCache.manager.emptyCache(),
        YomiruMedalCache.manager.emptyCache(),
      ]);
    } finally {
      // 磁盘清理后同步丢弃当前进程中已经解码的图片。
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    }
  }

  static Future<int> sizeBytes() async {
    final sizes = await Future.wait<int>([
      ReaderContentCache.sizeBytes(),
      _cacheManagerSize(DefaultCacheManager()),
      _cacheManagerSize(YomiruAvatarCache.manager),
      _cacheManagerSize(YomiruMedalCache.manager),
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
