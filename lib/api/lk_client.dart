import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 接口异常(code != 0 / HTTP 错误 / 网络错误)
class LKException implements Exception {
  final int code;
  final String message;
  final bool accessRestricted;
  LKException(this.code, this.message, {this.accessRestricted = false});
  @override
  String toString() => message.isEmpty ? '请求失败(错误码 $code)' : message;
}

/// 登录会话(持久化字段由上层保存)
class LKSession {
  String securityKey = '';
  int uid = 0;
  String nickname = '';
  String avatar = '';
  bool get isLoggedIn => securityKey.isNotEmpty;

  void clear() {
    securityKey = '';
    uid = 0;
    nickname = '';
    avatar = '';
  }
}

/// lightnovel.fun 正式服 API 客户端
/// 统一走站点提供的 pc-proxy 网关,全部 POST + JSON。
class LKClient {
  LKClient._() : _http = http.Client();

  @visibleForTesting
  LKClient.forTesting({required http.Client httpClient}) : _http = httpClient;
  static final LKClient shared = LKClient._();

  /// 登录态版本号:登录/登出/会话变更时自增,UI 监听刷新(如"我的"页用户卡片)
  static final ValueNotifier<int> sessionRev = ValueNotifier<int>(0);

  /// 会话被服务端判定失效后的全局通知，由应用根节点负责提示用户。
  static final ValueNotifier<int> sessionExpiredRev = ValueNotifier<int>(0);
  static Future<void> Function()? sessionExpiredHandler;

  final String base = 'https://www.lightnovel.fun/api/pc-proxy';
  final LKSession session = LKSession();
  final http.Client _http;
  bool _expiringSession = false;

  // 仅供公开、只读接口使用的响应缓存。缓存键不包含 security_key、cookie
  // 或其他会话凭据；私信、消息、福利和个人资料等敏感接口不会传入 cacheKey。
  static const _responseCachePrefix = 'lk_response_cache_v1_';
  Future<SharedPreferences>? _cachePrefs;
  final Map<String, _CachedResponse> _memoryCache = {};
  final Map<String, Future<Map<String, dynamic>>> _inFlight = {};
  final Map<String, int> _cacheVersions = {};
  // 只在本次进程成功请求过的数据可直接复用。磁盘缓存跨启动保留，
  // 下一次启动首次访问时重新验证，不再按几分钟的 TTL 反复加载。
  final Set<String> _validatedCacheKeys = {};
  Future<void> _cacheWriteQueue = Future<void>.value();
  Map<String, ({int savedAt, int bytes})>? _diskCacheIndex;
  static const _maxMemoryCacheEntries = 128;
  static const _maxDiskCacheEntries = 256;
  static const _maxDiskCacheBytes = 8 * 1024 * 1024;
  static const _maxDiskCacheEntryBytes = 512 * 1024;
  static const _errorCodeCatalogPath = '/api/bff/pc-error-code-list-v1';
  static const _errorCodeCatalogCacheKey = 'error_code_catalog_v1';
  static Map<int, String> _remoteErrorHints = const {};
  Future<void>? _errorCodeWarmup;

  Future<SharedPreferences> _responsePrefs() =>
      _cachePrefs ??= SharedPreferences.getInstance();

  static final Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36 LKFlutter/0.1',
    'Origin': 'https://www.lightnovel.fun',
    'Referer': 'https://www.lightnovel.fun/',
    // Android 复用连接以减少连续请求的 DNS/TCP/TLS 开销；iOS 继续使用
    // 已验证更稳定的短连接策略，避免部分系统版本复用连接时挂起。
    if (Platform.isIOS) 'Connection': 'close',
  };

  /// 自动附加 security_key(登录态接口用)
  Map<String, dynamic> authed([Map<String, dynamic> extra = const {}]) {
    final b = Map<String, dynamic>.from(extra);
    if (session.securityKey.isNotEmpty) b['security_key'] = session.securityKey;
    return b;
  }

  /// POST → 校验 code==0 → 返回 data
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body,
      {String? accessErrorMessage,
      String? cacheKey,
      bool forceRefresh = false,
      bool allowCachedFallback = true,
      Duration requestTimeout = const Duration(seconds: 30)}) async {
    if (cacheKey != null) {
      _cacheVersions.putIfAbsent(cacheKey, () => 0);
      if (forceRefresh) {
        // 手动刷新优先于旧的后台请求，旧响应不能覆盖新缓存。
        _cacheVersions[cacheKey] = _cacheVersions[cacheKey]! + 1;
        _validatedCacheKeys.remove(cacheKey);
        _inFlight.remove(cacheKey);
      }
    }
    final cacheVersion = cacheKey == null ? 0 : (_cacheVersions[cacheKey] ?? 0);
    final cachedCandidate =
        cacheKey == null ? null : await _readCached(cacheKey);
    final cached =
        cacheKey == null || (_cacheVersions[cacheKey] ?? 0) == cacheVersion
            ? cachedCandidate
            : null;
    if (cached != null &&
        !forceRefresh &&
        _validatedCacheKeys.contains(cacheKey)) {
      return cached.data;
    }
    final requestSecurityKey = (body['security_key'] ?? '').toString();

    Future<Map<String, dynamic>> fetch() async {
      late final http.Response resp;
      try {
        resp = await _http
            .post(Uri.parse('$base$path'),
                headers: _headers, body: jsonEncode(body))
            .timeout(requestTimeout);
      } on TimeoutException {
        if (cached != null && !forceRefresh && allowCachedFallback) {
          return cached.data;
        }
        throw LKException(-1, '连接超时，请检查网络后重试');
      } catch (_) {
        if (cached != null && !forceRefresh && allowCachedFallback) {
          return cached.data;
        }
        throw LKException(-1, '连接失败，请检查网络后重试');
      }
      if (resp.statusCode >= 400) {
        // 不记录响应正文:错误响应可能包含账号信息或服务端回显内容。
        debugPrint('LKHTTP status=${resp.statusCode} path=$path');
        if (cached != null &&
            !forceRefresh &&
            allowCachedFallback &&
            resp.statusCode >= 500) {
          return cached.data;
        }
        if (resp.statusCode == 401) {
          await expireSessionIfCurrent(requestSecurityKey);
        }
        throw LKException(resp.statusCode, '网络异常(HTTP ${resp.statusCode})');
      }
      final Object? obj;
      try {
        obj = jsonDecode(utf8.decode(resp.bodyBytes));
      } catch (_) {
        throw LKException(-1, '响应解析失败');
      }
      if (obj is! Map<String, dynamic>) throw LKException(-1, '响应格式错误');
      final code = (obj['code'] as num?)?.toInt() ?? -1;
      if (code != 0) {
        if (cached != null &&
            !forceRefresh &&
            allowCachedFallback &&
            code >= 500) {
          return cached.data;
        }
        final msg = _extractMessage(obj['data']);
        if (code == 8) await expireSessionIfCurrent(requestSecurityKey);
        throw LKException(code, msg.isNotEmpty ? msg : _codeHint(code));
      }
      final data = obj['data'];
      if (data is Map<String, dynamic>) {
        if (cacheKey != null) _writeCached(cacheKey, data, cacheVersion);
        return data;
      }
      if (accessErrorMessage != null) {
        throw LKException(403, accessErrorMessage, accessRestricted: true);
      }
      throw LKException(-1, '响应格式错误');
    }

    // 同一公开资源被多个页面同时请求时共享网络任务，避免重复 TLS 与 JSON 解析。
    if (cacheKey != null) {
      final running = forceRefresh ? null : _inFlight[cacheKey];
      if (running != null) return running;
      final request = fetch();
      _inFlight[cacheKey] = request;
      try {
        return await request;
      } finally {
        if (identical(_inFlight[cacheKey], request)) {
          _inFlight.remove(cacheKey);
        }
      }
    }
    return fetch();
  }

  /// 在后台读取官网维护的错误码说明。
  ///
  /// 目录属于公开只读数据，使用普通响应缓存且不携带登录凭据。刷新失败时
  /// 保留内置提示，不影响应用启动或其他请求。
  Future<void> warmErrorCodeHints({bool forceRefresh = false}) {
    final running = _errorCodeWarmup;
    if (running != null) return running;
    final future = () async {
      try {
        final data = await post(
          _errorCodeCatalogPath,
          const {},
          cacheKey: _errorCodeCatalogCacheKey,
          forceRefresh: forceRefresh,
          requestTimeout: const Duration(seconds: 12),
        );
        final parsed = parseErrorCodeCatalog(data);
        if (parsed.isNotEmpty) _remoteErrorHints = parsed;
      } catch (_) {
        // 错误码目录不可用时继续使用内置提示。
      }
    }();
    _errorCodeWarmup = future;
    return future.whenComplete(() {
      if (identical(_errorCodeWarmup, future)) _errorCodeWarmup = null;
    });
  }

  /// 兼容官网当前的 list 结构以及早期键值表结构。
  @visibleForTesting
  static Map<int, String> parseErrorCodeCatalog(Map<String, dynamic> data) {
    final result = <int, String>{};
    final list = data['list'];
    if (list is List) {
      for (final raw in list.whereType<Map>()) {
        final codeValue = raw['code'];
        final code = codeValue is num
            ? codeValue.toInt()
            : int.tryParse(codeValue?.toString() ?? '');
        final message = raw['message']?.toString().trim() ?? '';
        if (code != null && message.isNotEmpty) result[code] = message;
      }
    }
    if (result.isNotEmpty) return result;

    for (final entry in data.entries) {
      final code = int.tryParse(entry.key);
      final value = entry.value;
      final message = value is Map
          ? value['message']?.toString().trim() ?? ''
          : value?.toString().trim() ?? '';
      if (code != null && message.isNotEmpty) result[code] = message;
    }
    return result;
  }

  /// 只处理发出请求时仍对应当前会话的失效响应，防止旧请求清除新登录态。
  Future<void> expireSessionIfCurrent(String expectedSecurityKey) async {
    if (expectedSecurityKey.isEmpty ||
        session.securityKey != expectedSecurityKey ||
        _expiringSession) {
      return;
    }
    _expiringSession = true;
    try {
      try {
        await sessionExpiredHandler?.call();
      } catch (_) {
        // 即使持久化清理失败，也必须先清除当前进程中的失效会话。
      }
      if (session.securityKey == expectedSecurityKey) {
        session.clear();
        sessionRev.value++;
      }
      sessionExpiredRev.value++;
    } finally {
      _expiringSession = false;
    }
  }

  Future<_CachedResponse?> _readCached(String key) async {
    final memory = _memoryCache.remove(key);
    if (memory != null) {
      _memoryCache[key] = memory;
      return memory;
    }
    try {
      final raw =
          (await _responsePrefs()).getString('$_responseCachePrefix$key');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final savedAt = (decoded['saved_at'] as num?)?.toInt() ?? 0;
      final data = decoded['data'];
      if (savedAt <= 0 || data is! Map) return null;
      final cached = _CachedResponse(savedAt, Map<String, dynamic>.from(data));
      _rememberCached(key, cached);
      return cached;
    } catch (_) {
      return null;
    }
  }

  void _writeCached(
      String key, Map<String, dynamic> data, int expectedVersion) {
    if ((_cacheVersions[key] ?? 0) != expectedVersion) return;
    final savedAt = DateTime.now().millisecondsSinceEpoch;
    final cached = _CachedResponse(savedAt, Map<String, dynamic>.from(data));
    _validatedCacheKeys.add(key);
    _rememberCached(key, cached);
    unawaited(_persistCached(key, cached, expectedVersion));
  }

  void _rememberCached(String key, _CachedResponse cached) {
    if (!_memoryCache.containsKey(key) &&
        _memoryCache.length >= _maxMemoryCacheEntries) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[key] = cached;
  }

  /// 写操作后清理相关只读缓存，避免页面在缓存有效期内回显旧状态。
  Future<void> invalidateCachePrefix(String keyPrefix) async {
    final affectedKeys = <String>{
      ..._memoryCache.keys.where((key) => key.startsWith(keyPrefix)),
      ..._inFlight.keys.where((key) => key.startsWith(keyPrefix)),
      ..._cacheVersions.keys.where((key) => key.startsWith(keyPrefix)),
    };
    for (final key in affectedKeys) {
      _cacheVersions[key] = (_cacheVersions[key] ?? 0) + 1;
    }
    _memoryCache.removeWhere((key, _) => key.startsWith(keyPrefix));
    _inFlight.removeWhere((key, _) => key.startsWith(keyPrefix));
    _validatedCacheKeys.removeWhere((key) => key.startsWith(keyPrefix));
    try {
      await _queueCacheWrite(() async {
        final prefs = await _responsePrefs();
        final storedPrefix = '$_responseCachePrefix$keyPrefix';
        final keys =
            prefs.getKeys().where((key) => key.startsWith(storedPrefix));
        for (final key in keys) {
          await prefs.remove(key);
          _diskCacheIndex?.remove(key);
        }
      });
    } catch (_) {
      // Cache invalidation failure must not undo the completed mutation.
    }
  }

  /// 清除全部公开接口响应缓存，不影响登录会话或安全存储中的凭据。
  Future<void> clearResponseCache() async {
    final affectedKeys = <String>{
      ..._memoryCache.keys,
      ..._inFlight.keys,
      ..._cacheVersions.keys,
    };
    for (final key in affectedKeys) {
      _cacheVersions[key] = (_cacheVersions[key] ?? 0) + 1;
    }
    _memoryCache.clear();
    _inFlight.clear();
    _validatedCacheKeys.clear();
    try {
      await _queueCacheWrite(() async {
        final prefs = await _responsePrefs();
        final keys = prefs
            .getKeys()
            .where((key) => key.startsWith(_responseCachePrefix));
        await Future.wait(keys.map(prefs.remove));
        _diskCacheIndex = {};
      });
    } catch (_) {
      // 缓存清理失败由统一清理入口继续处理其他缓存。
    }
  }

  Future<int> responseCacheSizeBytes() async {
    try {
      final prefs = await _responsePrefs();
      var total = 0;
      for (final key in prefs
          .getKeys()
          .where((key) => key.startsWith(_responseCachePrefix))) {
        final value = prefs.getString(key);
        if (value != null) total += utf8.encode(value).length;
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _persistCached(
      String key, _CachedResponse cached, int expectedVersion) async {
    try {
      await _queueCacheWrite(() async {
        if ((_cacheVersions[key] ?? 0) != expectedVersion) return;
        final prefs = await _responsePrefs();
        final index = await _readDiskCacheIndex(prefs);
        final storedKey = '$_responseCachePrefix$key';
        final raw = jsonEncode({
          'saved_at': cached.savedAt,
          'data': cached.data,
        });
        final bytes = utf8.encode(raw).length;
        if (bytes > _maxDiskCacheEntryBytes) {
          await prefs.remove(storedKey);
          index.remove(storedKey);
          return;
        }
        if ((_cacheVersions[key] ?? 0) != expectedVersion) return;
        await prefs.setString(storedKey, raw);
        index[storedKey] = (savedAt: cached.savedAt, bytes: bytes);
        if ((_cacheVersions[key] ?? 0) != expectedVersion) {
          await prefs.remove(storedKey);
          index.remove(storedKey);
        }
        await _pruneDiskCache(prefs, index);
      });
    } catch (_) {
      // 缓存写入失败不影响正常请求结果。
    }
  }

  Future<void> _queueCacheWrite(Future<void> Function() action) {
    final next = _cacheWriteQueue.then((_) => action());
    _cacheWriteQueue = next.catchError((Object _) {});
    return next;
  }

  Future<Map<String, ({int savedAt, int bytes})>> _readDiskCacheIndex(
      SharedPreferences prefs) async {
    final existing = _diskCacheIndex;
    if (existing != null) return existing;
    final index = <String, ({int savedAt, int bytes})>{};
    for (final key in prefs
        .getKeys()
        .where((key) => key.startsWith(_responseCachePrefix))) {
      final raw = prefs.getString(key) ?? '';
      var savedAt = 0;
      try {
        final value = jsonDecode(raw);
        if (value is Map && value['data'] is Map) {
          savedAt = (value['saved_at'] as num?)?.toInt() ?? 0;
        }
      } catch (_) {}
      index[key] = (savedAt: savedAt, bytes: utf8.encode(raw).length);
    }
    return _diskCacheIndex = index;
  }

  Future<void> _pruneDiskCache(SharedPreferences prefs,
      Map<String, ({int savedAt, int bytes})> index) async {
    var totalBytes =
        index.values.fold<int>(0, (sum, entry) => sum + entry.bytes);
    final oldestFirst = index.keys.toList()
      ..sort((a, b) => index[a]!.savedAt.compareTo(index[b]!.savedAt));
    for (final key in oldestFirst) {
      final entry = index[key]!;
      if (entry.savedAt > 0 &&
          entry.bytes <= _maxDiskCacheEntryBytes &&
          index.length <= _maxDiskCacheEntries &&
          totalBytes <= _maxDiskCacheBytes) {
        continue;
      }
      await prefs.remove(key);
      index.remove(key);
      totalBytes -= entry.bytes;
    }
  }

  /// 只淘汰过大的、损坏的或超出容量上限的旧响应，不按时间删除首屏缓存。
  Future<void> trimResponseCache() async {
    try {
      await _queueCacheWrite(() async {
        final prefs = await _responsePrefs();
        await _pruneDiskCache(prefs, await _readDiskCacheIndex(prefs));
      });
    } catch (_) {
      // 缓存维护失败不阻塞应用启动。
    }
  }

  @visibleForTesting
  Future<void> flushResponseCache() => _cacheWriteQueue;

  /// POST → 返回 data(不做模型转换)
  Future<void> postVoid(String path, Map<String, dynamic> body) async {
    await post(path, body);
  }

  static String _extractMessage(dynamic data) {
    if (data is String && data.trim().isNotEmpty) return data.trim();
    if (data is List) {
      for (final value in data) {
        final message = _extractMessage(value);
        if (message.isNotEmpty) return message;
      }
    }
    if (data is Map<String, dynamic>) {
      final m = data['message'];
      if (m is String && m.isNotEmpty) return m;
      for (final v in data.values) {
        if (v is List && v.isNotEmpty && v.first is String) {
          return v.first as String;
        }
        if (v is String && v.isNotEmpty) return v;
      }
    }
    return '';
  }

  /// 常见错误码的友好提示
  static String _codeHint(int code) =>
      _remoteErrorHints[code] ??
      switch (code) {
        2 => '密码错误，请重新输入',
        3 => '参数错误，请检查输入内容',
        6 => '权限不足，无法执行此操作',
        8 => '登录状态已失效，请重新登录',
        403 => '没有权限执行此操作',
        404 => '内容不存在或已删除',
        429 => '操作太频繁，请稍后再试',
        500 => '服务器开小差了，请稍后再试',
        1001 => '用户不存在',
        _ => '请求失败(错误码 $code)',
      };

  /// pageSize 服务端上限 50
  static int clampPageSize(int n) => n < 1 ? 1 : (n > 50 ? 50 : n);

  /// multipart 头像上传,返回新头像 URL
  Future<String> uploadAvatar(String filePath, String md5Hex) async {
    final key = session.securityKey;
    if (key.isEmpty) throw LKException(8, '未登录');
    final req = http.MultipartRequest(
        'POST', Uri.parse('$base/api/bff/upload-my-avatar-v1'));
    req.headers.addAll({
      'User-Agent': _headers['User-Agent']!,
      'Origin': _headers['Origin']!,
      'Referer': _headers['Referer']!,
    });
    req.fields['security_key'] = key;
    req.fields['scene'] = 'user_avatar';
    req.fields['md5'] = md5Hex;
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final resp = await _http.send(req).timeout(const Duration(seconds: 40));
    final bytes = await resp.stream.toBytes();
    if (resp.statusCode >= 400) {
      if (resp.statusCode == 401) await expireSessionIfCurrent(key);
      throw LKException(resp.statusCode, '网络异常(HTTP ${resp.statusCode})');
    }
    final obj = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final code = (obj['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      if (code == 8) await expireSessionIfCurrent(key);
      final message = _extractMessage(obj['data']);
      throw LKException(code, message.isEmpty ? _codeHint(code) : message);
    }
    final d = (obj['data'] as Map<String, dynamic>?) ?? {};
    return (d['url'] as String?) ?? (d['avatar'] as String?) ?? '';
  }

  /// 上传动态/评论图片,统一返回站点 data 对象。
  Future<Map<String, dynamic>> uploadMultipart(
      String path, String filePath, Map<String, String> fields) async {
    final key = session.securityKey;
    if (key.isEmpty) throw LKException(8, '未登录');
    final req = http.MultipartRequest('POST', Uri.parse('$base$path'));
    req.headers.addAll({
      'Accept': 'application/json',
      'User-Agent': _headers['User-Agent']!,
      'Origin': _headers['Origin']!,
      'Referer': _headers['Referer']!,
    });
    req.fields['security_key'] = key;
    req.fields.addAll(fields);
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final resp = await _http.send(req).timeout(const Duration(seconds: 40));
    final bytes = await resp.stream.toBytes();
    if (resp.statusCode >= 400) {
      if (resp.statusCode == 401) await expireSessionIfCurrent(key);
      throw LKException(resp.statusCode, '网络异常(HTTP ${resp.statusCode})');
    }
    final obj = jsonDecode(utf8.decode(bytes));
    if (obj is! Map<String, dynamic>) throw LKException(-1, '响应格式错误');
    final code = (obj['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      final message = _extractMessage(obj['data']);
      if (code == 8) await expireSessionIfCurrent(key);
      throw LKException(code, message.isEmpty ? _codeHint(code) : message);
    }
    final data = obj['data'];
    if (data is Map<String, dynamic>) return data;
    throw LKException(-1, '响应格式错误');
  }
}

class _CachedResponse {
  final int savedAt;
  final Map<String, dynamic> data;

  const _CachedResponse(this.savedAt, this.data);
}
