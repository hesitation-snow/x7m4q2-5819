import 'dart:async';

import 'package:file/file.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'background_work_queue.dart';
import 'illustration_identity.dart';

/// 小说插画按稳定资源标识复用磁盘文件，不因临时签名或过期标记重复联网。
/// 同 URL 的更新由显式刷新/清除缓存触发，不改变头像等可变图片的策略。
class IllustrationCacheManager extends CacheManager {
  IllustrationCacheManager(super.config, {int maxConcurrentDownloads = 3})
      : _downloads = BackgroundWorkQueue(concurrency: maxConcurrentDownloads);

  final BackgroundWorkQueue _downloads;
  final _requests = <(String, bool), _ImageRequest>{};
  final _knownCached = <String>{};
  int _generation = 0;
  Future<void>? _clearing;
  Future<Map<String, List<String>>>? _legacyAliases;

  int get generation => _generation;
  bool isKnownCached(String url) =>
      _knownCached.contains(illustrationCacheKey(url));
  void markKnownCached(String url) =>
      _knownCached.add(illustrationCacheKey(url));
  void clearMemoryIndex() => _knownCached.clear();

  Future<FileInfo?> cachedFile(String key) async {
    key = illustrationCacheKey(key);
    final generation = _generation;
    var cached = await getFileFromCache(key);
    if (generation != _generation || _clearing != null) return null;
    if (cached == null && isSiteIllustrationUrl(key)) {
      // 升级前以完整签名网址保存的文件仍可复用，不复制图片或批量重下。
      // 只索引一次已有元数据；每次使用仍检查实际文件是否存在。
      final aliases = await (_legacyAliases ??= _readLegacyAliases());
      for (final alias in aliases[key] ?? const <String>[]) {
        if (generation != _generation || _clearing != null) return null;
        cached = await getFileFromCache(alias);
        if (cached != null) break;
      }
    }
    if (cached != null && await cached.file.exists()) {
      if (generation != _generation || _clearing != null) return null;
      _knownCached.add(key);
      return cached;
    }
    _knownCached.remove(key);
    return null;
  }

  Future<Map<String, List<String>>> _readLegacyAliases() async {
    final aliases = <String, List<String>>{};
    try {
      final objects = await config.repo.getAllObjects();
      for (final object in objects) {
        final key = illustrationCacheKey(object.key);
        if (key != object.key) (aliases[key] ??= []).add(object.key);
      }
    } catch (_) {
      // 旧索引不可读时仍允许按需下载，不让兼容读取阻塞正常展示。
    }
    return aliases;
  }

  /// 展示、预取和保存共用单飞请求；取消某页预取不会取消另一页的展示。
  Future<FileInfo?> obtain(String url,
      {String? key,
      Map<String, String>? headers,
      bool force = false,
      bool Function()? isCurrent}) async {
    key = illustrationCacheKey(key ?? url);
    final generation = _generation;
    bool wanted() =>
        generation == _generation &&
        _clearing == null &&
        (isCurrent == null || isCurrent());
    if (!wanted()) return null;
    // 缓存读取不排在下载队列后面，弱网也不影响已保存插画的显示。
    if (!force) {
      final cached = await cachedFile(key);
      if (!wanted()) return null;
      if (cached != null) return cached;
    }
    final requestKey = (key, force);
    var request = _requests[requestKey];
    if (request == null) {
      request = _ImageRequest()..listeners.add(wanted);
      _requests[requestKey] = request;
      final job = request;
      request.future = _downloads.run<FileInfo?>(() async {
        // 入队期间其他入口可能已经把文件下载完成。
        if (!force) {
          final cached = await cachedFile(key!);
          if (!job.isWanted) return null;
          if (cached != null) return cached;
        }
        if (!job.isWanted) return null;
        final file = await super
            .downloadFile(url, key: key, authHeaders: headers, force: force);
        if (generation != _generation) return null;
        _knownCached.add(key!);
        return file;
      }, isCurrent: () => job.isWanted);
    } else {
      request.listeners.add(wanted);
    }
    try {
      final file = await request.future;
      return wanted() ? file : null;
    } finally {
      request.listeners.remove(wanted);
      if (identical(_requests[requestKey], request)) {
        _requests.remove(requestKey);
      }
    }
  }

  @override
  Stream<FileResponse> getFileStream(String url,
      {String? key, Map<String, String>? headers, bool withProgress = false}) {
    var active = true;
    late final StreamController<FileResponse> controller;
    controller = StreamController<FileResponse>(
      onListen: () async {
        try {
          final file = await obtain(url,
              key: key, headers: headers, isCurrent: () => active);
          if (active) {
            if (file == null) {
              controller.addError(StateError('插画请求已取消'));
            } else {
              controller.add(file);
            }
          }
        } catch (error, stack) {
          if (active) controller.addError(error, stack);
        } finally {
          unawaited(controller.close());
        }
      },
      onCancel: () {
        active = false;
      },
    );
    return controller.stream;
  }

  @override
  Future<File> getSingleFile(String url,
      {String? key, Map<String, String>? headers}) async {
    final file = await obtain(url, key: key, headers: headers);
    if (file == null) throw StateError('插画请求已取消');
    return file.file;
  }

  @override
  Future<FileInfo> downloadFile(String url,
      {String? key,
      Map<String, String>? authHeaders,
      bool force = false}) async {
    final file =
        await obtain(url, key: key, headers: authHeaders, force: force);
    if (file == null) throw StateError('插画请求已取消');
    return file;
  }

  @override
  Future<void> emptyCache() async {
    final existing = _clearing;
    if (existing != null) return existing;
    _generation++;
    _knownCached.clear();
    _legacyAliases = null;
    final work = _finishAndClear();
    _clearing = work;
    try {
      await work;
    } finally {
      _clearing = null;
    }
  }

  Future<void> _finishAndClear() async {
    final pending = _requests.values.map((request) => request.future).toList();
    await Future.wait(pending.map((future) async {
      try {
        await future;
      } catch (_) {/* 失败的下载同样需要清理。 */}
    }));
    await super.emptyCache();
  }
}

class _ImageRequest {
  final listeners = <bool Function()>{};
  late final Future<FileInfo?> future;
  bool get isWanted => listeners.any((listener) => listener());
}
