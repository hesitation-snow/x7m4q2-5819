import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lk_client.dart';
import 'home_channels.dart';
import 'medal_catalog.dart';
import 'models.dart';
import 'reader_cache.dart';
import 'reading_session.dart';
import '../reader/reading_position.dart';
import '../reader/reader_typography.dart';
import '../reader/indicator_position.dart';

/// 封面模糊模式
enum CoverBlurMode {
  all,
  brave,
  none,
}

/// 默认动态列表的数据源；不影响个人关注与交互操作。
enum DynamicFeedMode {
  anonymousFollow('匿名关注', '使用官网未登录状态的关注列表'),
  legacyMixed('旧版动态', '使用旧版动态列表，按当前登录状态加载');

  const DynamicFeedMode(this.label, this.description);
  final String label;
  final String description;
}

@immutable
class GlassConfiguration {
  const GlassConfiguration._(
    this.blur,
    this.tint,
    this.refraction,
    this.highlight,
    this.barWidth,
    this.barHeight,
    this.floatingHeight,
    this.keepVisibleOnScroll,
  );

  static const defaults = GlassConfiguration._(
    3,
    .09,
    .25,
    .74,
    252,
    59,
    18,
    false,
  );

  final double blur, tint, refraction, highlight;
  final double barWidth, barHeight, floatingHeight;
  final bool keepVisibleOnScroll;

  static double _v(Object? v, double d, double max) =>
      v is num && v.isFinite ? v.toDouble().clamp(0.0, max) : d;

  factory GlassConfiguration({
    Object? blur = 3,
    Object? tint = .09,
    Object? refraction = .25,
    Object? highlight = .74,
    Object? barWidth = 252,
    Object? barHeight = 59,
    Object? floatingHeight = 18,
    Object? keepVisibleOnScroll = false,
  }) =>
      GlassConfiguration._(
        _v(blur, defaults.blur, 40),
        _v(tint, defaults.tint, 1),
        _v(refraction, defaults.refraction, .25),
        _v(highlight, defaults.highlight, 1),
        _v(barWidth, defaults.barWidth, 360).clamp(220.0, 360.0).toDouble(),
        _v(barHeight, defaults.barHeight, 72).clamp(40.0, 72.0).toDouble(),
        _v(floatingHeight, defaults.floatingHeight, 48),
        keepVisibleOnScroll is bool ? keepVisibleOnScroll : false,
      );

  GlassConfiguration copyWith({
    double? blur,
    double? tint,
    double? refraction,
    double? highlight,
    double? barWidth,
    double? barHeight,
    double? floatingHeight,
    bool? keepVisibleOnScroll,
  }) =>
      GlassConfiguration(
        blur: blur ?? this.blur,
        tint: tint ?? this.tint,
        refraction: refraction ?? this.refraction,
        highlight: highlight ?? this.highlight,
        barWidth: barWidth ?? this.barWidth,
        barHeight: barHeight ?? this.barHeight,
        floatingHeight: floatingHeight ?? this.floatingHeight,
        keepVisibleOnScroll: keepVisibleOnScroll ?? this.keepVisibleOnScroll,
      );
}

/// 会话与主题持久化
class LKStore {
  /// 主题模式(ValueNotifier 让 MaterialApp 即时切换)
  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier(ThemeMode.system);

  /// 深色模式纯黑 (AMOLED)
  static final ValueNotifier<bool> pureBlackDark = ValueNotifier(false);

  /// 全局主题种子色 (ARGB32)
  static final ValueNotifier<int?> themeSeedColor = ValueNotifier(null);

  /// 液态玻璃底栏独立开关（旧强度偏好忽略）
  static final ValueNotifier<bool> liquidGlassBottomBarEnabled =
      ValueNotifier(false);

  /// 实验室功能开关：在任务中心显示每日开宝箱。
  static final ValueNotifier<bool> dailyTreasureEnabled = ValueNotifier(false);

  static Future<void> setDailyTreasureEnabled(bool enabled) async {
    dailyTreasureEnabled.value = enabled;
    final p = await SharedPreferences.getInstance();
    await p.setBool('laboratory_daily_treasure_enabled', enabled);
  }

  /// 实验室调试选项：加载勋章商城所有服务端分页。
  static final ValueNotifier<bool> allMedalsEnabled =
      ValueNotifier(allMedalsBuild);

  static Future<void> setAllMedalsEnabled(bool enabled) async {
    allMedalsEnabled.value = enabled;
    final p = await SharedPreferences.getInstance();
    await p.setBool('laboratory_all_medals_enabled', enabled);
  }

  static final glassConfiguration = ValueNotifier(GlassConfiguration.defaults);
  static Timer? _glassSaveTimer;
  static void updateGlassConfiguration(GlassConfiguration value) {
    glassConfiguration.value = value;
    _glassSaveTimer?.cancel();
    _glassSaveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(flushGlassConfiguration());
    });
  }

  static Future<void> _glassSaveQueue = Future<void>.value();
  static Future<void> flushGlassConfiguration() {
    _glassSaveTimer?.cancel();
    _glassSaveTimer = null;
    final c = glassConfiguration.value;
    return _glassSaveQueue = _glassSaveQueue.then((_) async {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('glass_blur', c.blur);
      await p.setDouble('glass_tint', c.tint);
      await p.setDouble('glass_refraction', c.refraction);
      await p.setDouble('glass_highlight', c.highlight);
      await p.setDouble('glass_bar_width', c.barWidth);
      await p.setDouble('glass_bar_height', c.barHeight);
      await p.setDouble('glass_floating_height', c.floatingHeight);
      await p.setBool('glass_keep_visible_on_scroll', c.keepVisibleOnScroll);
    }).catchError((Object error) {
      debugPrint('Glass preferences save failed: $error');
    });
  }

  static void loadGlassConfiguration(SharedPreferences p) {
    glassConfiguration.value = GlassConfiguration(
      blur: p.get('glass_blur') ?? GlassConfiguration.defaults.blur,
      tint: p.get('glass_tint') ?? GlassConfiguration.defaults.tint,
      refraction:
          p.get('glass_refraction') ?? GlassConfiguration.defaults.refraction,
      highlight:
          p.get('glass_highlight') ?? GlassConfiguration.defaults.highlight,
      barWidth:
          p.get('glass_bar_width') ?? GlassConfiguration.defaults.barWidth,
      barHeight:
          p.get('glass_bar_height') ?? GlassConfiguration.defaults.barHeight,
      floatingHeight: p.get('glass_floating_height') ??
          GlassConfiguration.defaults.floatingHeight,
      keepVisibleOnScroll: p.get('glass_keep_visible_on_scroll') ?? false,
    );
  }

  /// 流量节省模式(ValueNotifier 让全局图片加载即时响应)
  static final ValueNotifier<bool> dataSaverMode = ValueNotifier(false);
  static final ValueNotifier<bool> animationsEnabled = ValueNotifier(true);
  static final ValueNotifier<bool> landscapeEnabled = ValueNotifier(false);
  static final ValueNotifier<DynamicFeedMode> dynamicFeedMode =
      ValueNotifier(DynamicFeedMode.anonymousFollow);

  static DynamicFeedMode parseDynamicFeedMode(String? value) =>
      value == DynamicFeedMode.legacyMixed.name
          ? DynamicFeedMode.legacyMixed
          : DynamicFeedMode.anonymousFollow;

  static Future<void> setDynamicFeedMode(DynamicFeedMode mode) async {
    final p = await SharedPreferences.getInstance();
    if (!await p.setString('dynamic_feed_mode', mode.name)) {
      throw StateError('无法保存动态数据源设置，请重试');
    }
    dynamicFeedMode.value = mode;
  }

  /// 书籍封面高斯模糊模式（全部书籍 / 勇者书籍 / 关闭）
  static final ValueNotifier<CoverBlurMode> coverBlurMode =
      ValueNotifier(CoverBlurMode.brave);

  /// 防社死封面高斯模糊模式(ValueNotifier 让全局封面即时响应，与 coverBlurMode 保持联动)
  static final ValueNotifier<bool> nsfwBlurCover = ValueNotifier(true);

  /// 隐藏勇者书籍模式(ValueNotifier 让列表和书架即时响应)
  static final ValueNotifier<bool> hideBraveBooks = ValueNotifier(true);

  /// 书籍网格列数偏好（0 表示“自动”，2/3/4/5 表示每行固定本数）
  static final ValueNotifier<int> gridColumnCount = ValueNotifier(0);

  /// 首页频道顺序；前三项显示为顶栏标签，其余频道留在分类入口。
  static final ValueNotifier<List<String>> homeChannelOrder =
      ValueNotifier(defaultHomeChannelOrder);

  /// 书籍导出开关（入口仍需登录）
  static final ValueNotifier<bool> epubDownloadEnabled = ValueNotifier(false);

  /// 原文格式显示，首次安装默认开启，保留用户后续选择。
  static final ValueNotifier<bool> enhancedContentStyleEnabled =
      ValueNotifier(true);

  /// 自动检查更新开关，默认开启
  static final ValueNotifier<bool> autoCheckUpdateEnabled = ValueNotifier(true);

  /// 已确认需勇者权限的小说 ID 缓存（内置预置 14162 标杆书籍）
  static final Set<int> _braveBookIds = {14162};

  static final bool _braveCheckerHooked = () {
    setBraveBookChecker(isBraveBook);
    return true;
  }();

  static bool isBraveBook(int bookId) {
    // Ensure static hook is triggered
    assert(_braveCheckerHooked);
    return _braveBookIds.contains(bookId);
  }

  static Future<void> markBookBrave(int bookId) async {
    if (bookId <= 0 || _braveBookIds.contains(bookId)) return;
    _braveBookIds.add(bookId);
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
      'known_brave_book_ids',
      _braveBookIds.map((e) => e.toString()).toList(),
    );
  }

  @visibleForTesting
  static void resetBraveBookIdsForTesting([Set<int>? seed]) {
    _braveBookIds
      ..clear()
      ..addAll(seed ?? {14162});
  }

  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static const _sessionInvalidatedKey = 'session_invalidated_v1';
  static Future<void> _sessionWrites = Future<void>.value();
  static int _sessionGeneration = 0;

  // Keep failed writes from poisoning later operations, while reporting each
  // failure to its own caller. Snapshots are captured before entering the queue.
  static Future<void> _queueSessionWrite(Future<void> Function() action) {
    final operation = _sessionWrites.then((_) => action());
    _sessionWrites = operation.catchError((Object _) {});
    return operation;
  }

  /// Remove identifiers left by versions that reported automatic usage data.
  /// Run asynchronously after runApp so cleanup never delays startup.
  static Future<void> removeLegacyUsageIdentifier() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('anonymous_telemetry_reported_v1');
    } catch (_) {
      // Best effort: preferences may be temporarily unavailable.
    }
    try {
      await _secure.delete(key: 'anonymous_telemetry_installation_id_v1');
    } catch (_) {
      // Retry on a future launch if secure storage is unavailable.
    }
  }

  static Future<void> load() {
    final generation = _sessionGeneration;
    return _queueSessionWrite(() => _load(generation));
  }

  static Future<void> _load(int generation) async {
    // 两个独立存储并行打开,缩短启动首屏前的等待时间。
    final preferencesFuture = SharedPreferences.getInstance();
    final secureKeyFuture = (() async {
      try {
        return (await _secure.read(key: 'security_key') ?? '', true);
      } catch (_) {
        return ('', false);
      }
    })();
    final p = await preferencesFuture;
    var (securityKey, secureStorageReady) = await secureKeyFuture;
    final invalidated = p.getBool(_sessionInvalidatedKey) ?? false;
    if (invalidated) {
      // A previous logout may have failed to delete the secure value. Never
      // restore it, even when the secure store is available again.
      securityKey = '';
    }
    if (secureStorageReady && !invalidated) {
      // 一次性迁移旧版本写入 SharedPreferences 的会话凭据。
      if (securityKey.isEmpty) {
        final legacyKey = p.getString('security_key') ?? '';
        if (legacyKey.isNotEmpty) {
          try {
            await _secure.write(key: 'security_key', value: legacyKey);
            securityKey = legacyKey;
          } catch (_) {
            secureStorageReady = false;
          }
        }
      }
    }
    // Keychain/Keystore 不可用时不回退读取明文偏好，避免重新暴露凭据。
    if (secureStorageReady) await p.remove('security_key');
    if (generation == _sessionGeneration) {
      LKClient.shared.session
        ..securityKey = securityKey
        ..uid = invalidated ? 0 : (p.getInt('uid') ?? 0)
        ..nickname = invalidated ? '' : (p.getString('nickname') ?? '')
        ..avatar = invalidated ? '' : (p.getString('avatar') ?? '');
    }
    themeMode.value = _parseTheme(p.getString('theme_mode'));
    pureBlackDark.value = p.getBool('pure_black_dark') ?? false;
    themeSeedColor.value = p.getInt('theme_seed_color');
    liquidGlassBottomBarEnabled.value =
        p.getBool('liquid_glass_bottom_bar_enabled') ?? false;
    dailyTreasureEnabled.value =
        p.getBool('laboratory_daily_treasure_enabled') ?? false;
    allMedalsEnabled.value =
        p.getBool('laboratory_all_medals_enabled') ?? allMedalsBuild;
    loadGlassConfiguration(p);
    dataSaverMode.value = p.getBool('data_saver_mode') ?? false;
    animationsEnabled.value = p.getBool('animations_enabled') ?? true;
    landscapeEnabled.value = p.getBool('landscape_enabled') ?? false;
    dynamicFeedMode.value =
        parseDynamicFeedMode(p.getString('dynamic_feed_mode'));
    final savedBlurMode = p.getString('cover_blur_mode');
    if (savedBlurMode != null) {
      coverBlurMode.value = switch (savedBlurMode) {
        'all' => CoverBlurMode.all,
        'brave' => CoverBlurMode.brave,
        'none' => CoverBlurMode.none,
        _ => CoverBlurMode.brave,
      };
    } else {
      final legacyNsfw = p.getBool('nsfw_blur_cover') ?? true;
      coverBlurMode.value =
          legacyNsfw ? CoverBlurMode.brave : CoverBlurMode.none;
    }
    nsfwBlurCover.value = coverBlurMode.value != CoverBlurMode.none;
    hideBraveBooks.value = p.getBool('hide_brave_books') ?? true;
    gridColumnCount.value = p.getInt('grid_column_count') ?? 0;
    homeChannelOrder.value =
        normalizeHomeChannelOrder(p.getStringList('home_channel_order'));
    epubDownloadEnabled.value = p.getBool('epub_download_enabled') ?? false;
    enhancedContentStyleEnabled.value =
        p.getBool('reader_enhanced_content_style') ?? true;
    autoCheckUpdateEnabled.value =
        p.getBool('auto_check_update_enabled') ?? true;
    setBraveBookChecker(isBraveBook);
    final storedBraveIds = p.getStringList('known_brave_book_ids');
    if (storedBraveIds != null) {
      _braveBookIds.addAll(storedBraveIds.map(int.tryParse).whereType<int>());
    }
    unawaited(LKClient.shared.trimResponseCache());
  }

  static Future<void> save() {
    final s = LKClient.shared.session;
    final key = s.securityKey;
    final uid = s.uid;
    final nickname = s.nickname;
    final avatar = s.avatar;
    _sessionGeneration++;
    return _queueSessionWrite(() async {
      final p = await SharedPreferences.getInstance();
      // Fail closed if a write is interrupted midway.
      if (!await p.setBool(_sessionInvalidatedKey, true)) {
        throw StateError('会话状态保存失败');
      }
      if (key.isEmpty) {
        await _secure.delete(key: 'security_key');
      } else {
        await _secure.write(key: 'security_key', value: key);
      }
      await p.remove('security_key');
      await p.setInt('uid', uid);
      await p.setString('nickname', nickname);
      await p.setString('avatar', avatar);
      if (key.isNotEmpty && !await p.setBool(_sessionInvalidatedKey, false)) {
        throw StateError('会话状态保存失败');
      }
    });
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    final p = await SharedPreferences.getInstance();
    await p.setString('theme_mode', mode.name);
  }

  static Future<void> setLiquidGlassBottomBarEnabled(bool enabled) async {
    liquidGlassBottomBarEnabled.value = enabled;
    final p = await SharedPreferences.getInstance();
    await p.setBool('liquid_glass_bottom_bar_enabled', enabled);
  }

  static Future<void> setPureBlackDark(bool enabled) async {
    pureBlackDark.value = enabled;
    final p = await SharedPreferences.getInstance();
    await p.setBool('pure_black_dark', enabled);
  }

  static Future<void> setThemeSeedColor(int? color) async {
    themeSeedColor.value = color;
    final p = await SharedPreferences.getInstance();
    if (color == null) {
      await p.remove('theme_seed_color');
    } else {
      await p.setInt('theme_seed_color', color);
    }
  }

  static Future<void> setAnimationsEnabled(bool enabled) async {
    animationsEnabled.value = enabled;
    final p = await SharedPreferences.getInstance();
    await p.setBool('animations_enabled', enabled);
  }

  static Future<void> setLandscapeEnabled(bool enabled) async {
    landscapeEnabled.value = enabled;
    final p = await SharedPreferences.getInstance();
    await p.setBool('landscape_enabled', enabled);
  }

  static Future<void> setDataSaverMode(bool enable) async {
    if (dataSaverMode.value == enable) return;
    dataSaverMode.value = enable;
    final p = await SharedPreferences.getInstance();
    await p.setBool('data_saver_mode', enable);
  }

  static Future<void> setCoverBlurMode(CoverBlurMode mode) async {
    if (coverBlurMode.value == mode) return;
    coverBlurMode.value = mode;
    nsfwBlurCover.value = mode != CoverBlurMode.none;
    final p = await SharedPreferences.getInstance();
    await p.setString('cover_blur_mode', mode.name);
    await p.setBool('nsfw_blur_cover', mode != CoverBlurMode.none);
  }

  static Future<void> setNsfwBlurCover(bool enable) async {
    await setCoverBlurMode(enable ? CoverBlurMode.brave : CoverBlurMode.none);
  }

  static Future<void> setHideBraveBooks(bool enable) async {
    if (hideBraveBooks.value == enable) return;
    hideBraveBooks.value = enable;
    final p = await SharedPreferences.getInstance();
    await p.setBool('hide_brave_books', enable);
  }

  static Future<void> setGridColumnCount(int count) async {
    final sanitized = count.clamp(0, 6);
    if (gridColumnCount.value == sanitized) return;
    gridColumnCount.value = sanitized;
    final p = await SharedPreferences.getInstance();
    await p.setInt('grid_column_count', sanitized);
  }

  static Future<void> setHomeChannelOrder(List<String> order) async {
    final normalized = normalizeHomeChannelOrder(order);
    homeChannelOrder.value = normalized;
    final p = await SharedPreferences.getInstance();
    await p.setStringList('home_channel_order', normalized);
  }

  static Future<void> setEpubDownloadEnabled(bool enable) async {
    if (epubDownloadEnabled.value == enable) return;
    epubDownloadEnabled.value = enable;
    final p = await SharedPreferences.getInstance();
    await p.setBool('epub_download_enabled', enable);
  }

  static Future<void> setEnhancedContentStyleEnabled(bool enable) async {
    if (enhancedContentStyleEnabled.value == enable) return;
    enhancedContentStyleEnabled.value = enable;
    final p = await SharedPreferences.getInstance();
    await p.setBool('reader_enhanced_content_style', enable);
  }

  static Future<void> setAutoCheckUpdateEnabled(bool enable) async {
    if (autoCheckUpdateEnabled.value == enable) return;
    autoCheckUpdateEnabled.value = enable;
    final p = await SharedPreferences.getInstance();
    await p.setBool('auto_check_update_enabled', enable);
  }

  static Future<void> clear({String? expectedSecurityKey, int? expectedUid}) {
    final session = LKClient.shared.session;
    if ((expectedSecurityKey != null &&
            session.securityKey != expectedSecurityKey) ||
        (expectedUid != null && session.uid != expectedUid)) {
      return Future<void>.value();
    }
    final oldUid = session.uid;
    _sessionGeneration++;
    session.clear();
    LKClient.sessionRev.value++;
    LKReadingSession.shared.reset();
    // Invalidate in-flight responses immediately, before a new login starts.
    final readerCacheClear = ReaderContentCache.clear();
    final responseCacheClear = LKClient.shared.clearResponseCache();
    return _queueSessionWrite(() async {
      final p = await SharedPreferences.getInstance();
      // Record logout before attempting deletion; the marker survives a
      // Keychain/Keystore failure and prevents resurrection on next launch.
      if (!await p.setBool(_sessionInvalidatedKey, true)) {
        throw StateError('退出状态保存失败');
      }
      final cacheUid = oldUid > 0 ? oldUid : (p.getInt('uid') ?? 0);
      try {
        await _secure.delete(key: 'security_key');
      } catch (_) {
        // The durable invalidation marker still prevents restoring this key.
      }
      await p.remove('security_key');
      await p.remove('uid');
      await p.remove('nickname');
      await p.remove('avatar');
      if (cacheUid > 0) {
        await p.remove(_profileCacheKey(cacheUid));
        await p.remove(_medalCacheKey(cacheUid));
        await p.remove('welfare_home_cache_v1_$cacheUid');
        final accountPageCaches = p
            .getKeys()
            .where((key) =>
                key.startsWith(_pageCachePrefix) &&
                key.contains('_u${cacheUid}_'))
            .toList(growable: false);
        await Future.wait(accountPageCaches.map(p.remove));
      }
      await responseCacheClear;
      await readerCacheClear;
    });
  }

  /// 清除可重新从网络取得的资料缓存，保留账号、主题、书架与阅读进度。
  static Future<void> clearContentCaches() async {
    _globalMedalsWriteTimer?.cancel();
    _globalMedalsWriteTimer = null;
    _globalMedalsMemory = null;
    _globalMedalsLoad = null;
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((key) =>
            key == _globalMedalsKey ||
            key.startsWith('home_recommend_v2') ||
            key.startsWith('section_latest_') ||
            key.startsWith('my_profile_cache_') ||
            key.startsWith('my_medals_cache_') ||
            key.startsWith('welfare_home_cache_v1_') ||
            key.startsWith(_pageCachePrefix))
        .toList(growable: false);
    final removed = await Future.wait(keys.map(prefs.remove));
    if (removed.any((success) => !success)) throw StateError('部分页面缓存未清除');
  }

  static Future<int> contentCacheSizeBytes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((key) =>
          key == _globalMedalsKey ||
          key.startsWith('home_recommend_v2') ||
          key.startsWith('section_latest_') ||
          key.startsWith('my_profile_cache_') ||
          key.startsWith('my_medals_cache_') ||
          key.startsWith('welfare_home_cache_v1_') ||
          key.startsWith(_pageCachePrefix));
      var total = 0;
      for (final key in keys) {
        final value = prefs.get(key);
        if (value is String) total += utf8.encode(value).length;
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static String _medalCacheKey(int uid) => 'my_medals_cache_$uid';
  static String _profileCacheKey(int uid) => 'my_profile_cache_$uid';
  static const _globalMedalsKey = 'global_user_medals_cache_v1';
  static const _pageCachePrefix = 'page_cache_v1_';
  static Map<int, List<LKMedal>>? _globalMedalsMemory;
  static Future<Map<int, List<LKMedal>>>? _globalMedalsLoad;
  static Timer? _globalMedalsWriteTimer;
  static const _localShelfKey = 'local_shelf_books_v1';
  static final ValueNotifier<int> localShelfRev = ValueNotifier<int>(0);

  /// 页面缓存键始终包含账号范围,避免登录切换后短暂展示上一个账号的数据。
  static String pageCacheKey({
    required String kind,
    required int uid,
    required String variant,
  }) {
    return [
      _pageCachePrefix,
      kind,
      '_u',
      uid.toString(),
      '_',
      Uri.encodeComponent(variant),
    ].join();
  }

  static Future<List<LKBook>?> cachedBooksPage(String key) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((item) => LKBook.fromJson(Map<String, dynamic>.from(item)))
          .where((book) => book.bookId > 0)
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  static Future<void> cacheBooksPage(String key, List<LKBook> books) async {
    try {
      // 限制单个偏好值的体积,保留足够内容恢复上次浏览画面。
      final data =
          books.take(100).map((book) => book.toJson()).toList(growable: false);
      await (await SharedPreferences.getInstance())
          .setString(key, jsonEncode(data));
    } catch (_) {
      // 缓存失败不影响在线内容。
    }
  }

  static Future<List<LKDynamicItem>?> cachedDynamicPage(String key) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map(
              (item) => LKDynamicItem.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  static Future<void> cacheDynamicPage(
      String key, List<LKDynamicItem> items) async {
    try {
      final data =
          items.take(100).map(_dynamicCacheJson).toList(growable: false);
      await (await SharedPreferences.getInstance())
          .setString(key, jsonEncode(data));
    } catch (_) {
      // 缓存失败不影响在线内容。
    }
  }

  static Map<String, dynamic> _dynamicCacheJson(LKDynamicItem item) => {
        'dynamic_id': item.dynamicId,
        'author_uid': item.authorUid,
        'target_type': item.targetType,
        'event_type': item.eventType,
        'nickname': item.nickname,
        'avatar': item.avatar,
        'author': {
          'uid': item.authorUid,
          'nickname': item.nickname,
          'avatar': item.avatar,
          'medals': item.authorMedals
              .map((medal) => {
                    'medal_id': medal.medalId,
                    'name': medal.name,
                    'image': medal.image,
                    'equipped': medal.equipped,
                  })
              .toList(growable: false),
        },
        'title': item.title,
        'summary': item.summary,
        'stats': {
          'like_count': item.likeCount,
          'comment_count': item.commentCount,
          'favorite_count': item.favoriteCount,
        },
        'interaction_state': {
          'liked': item.liked,
          'favorited': item.favorited,
          'read': item.read,
        },
        'read': item.read,
        'feed_time': item.time,
        'target_brief': {
          'book_id': item.bookId,
          'title': item.bookTitle,
          'cover_url': item.bookCover,
        },
        'media': item.media
            .map((media) => {
                  'url': media.url,
                  'width': media.width,
                  'height': media.height,
                  'res_id': media.resId,
                  'res_url': media.resUrl,
                  'res_path': media.resPath,
                  'stored_url': media.storedUrl,
                  'source_url': media.sourceUrl,
                })
            .toList(growable: false),
        'poll': item.poll == null
            ? null
            : {
                'poll_id': item.poll!.pollId,
                'title': item.poll!.title,
                'description': item.poll!.description,
                'deadline_at': item.poll!.deadlineAt,
                'participant_count': item.poll!.participantCount,
                'ended': item.poll!.ended,
                'viewer_voted': item.poll!.voted,
                'allow_multiple': item.poll!.multiple,
                'options': item.poll!.options
                    .map((option) => {
                          'option_id': option.id,
                          'text': option.text,
                          'image': option.image,
                          'vote_count': option.voteCount,
                          'percent': option.percent,
                          'voted': option.selected,
                        })
                    .toList(growable: false),
              },
      };

  /// 未登录时使用的本地书架,只保存公开的书籍展示字段。
  static Future<List<LKBook>> localShelf() async {
    final raw =
        (await SharedPreferences.getInstance()).getString(_localShelfKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => LKBook.fromJson(Map<String, dynamic>.from(e)))
          .where((book) => book.bookId > 0)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> isLocalShelf(int bookId) async {
    if (bookId <= 0) return false;
    final books = await localShelf();
    return books.any((book) => book.bookId == bookId);
  }

  static Future<void> setLocalShelf(LKBook book, bool added) async {
    if (book.bookId <= 0) return;
    // localShelf() 在空数据时可能返回 const [],这里必须复制为可变列表。
    final books = (await localShelf()).toList();
    books.removeWhere((item) => item.bookId == book.bookId);
    if (added) books.insert(0, book);
    final saved = await (await SharedPreferences.getInstance()).setString(
        _localShelfKey, jsonEncode(books.map((e) => e.toJson()).toList()));
    if (!saved) throw StateError('本机书架保存失败');
    localShelfRev.value++;
  }

  /// 读取当前账号上次成功获取的个人资料；null 表示尚未缓存或缓存已损坏。
  static Future<LKMyProfile?> cachedMyProfile(int uid) async {
    if (uid <= 0) return null;
    final raw = (await SharedPreferences.getInstance())
        .getString(_profileCacheKey(uid));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final profile = LKMyProfile.fromJson(Map<String, dynamic>.from(decoded));
      return profile.uid == uid ? profile : null;
    } catch (_) {
      return null;
    }
  }

  /// 缓存资料展示所需字段，不包含 security_key、cookie 等会话凭据。
  static Future<void> cacheMyProfile(int uid, LKMyProfile profile) async {
    if (uid <= 0 || profile.uid != uid) return;
    final data = <String, dynamic>{
      'uid': profile.uid,
      'nickname': profile.nickname,
      'avatar': profile.avatar,
      'signature': profile.signature,
      'level_name': profile.levelName,
      'level': profile.level,
      'coin': profile.coin,
      'isBrave': profile.isBrave,
      'followers': profile.followersCount,
      'following': profile.followingCount,
      'post_count': profile.postCount,
      'bookshelf_count': profile.bookshelfCount,
      'history_count': profile.historyCount,
      'medals': profile.medals
          .take(5)
          .map((medal) => {
                'medal_id': medal.medalId,
                'name': medal.name,
                'image': medal.image,
                'equipped': medal.equipped,
              })
          .toList(),
    };
    final generation = _sessionGeneration;
    await _queueSessionWrite(() async {
      if (generation != _sessionGeneration) return;
      final prefs = await SharedPreferences.getInstance();
      if (generation != _sessionGeneration) return;
      await prefs.setString(_profileCacheKey(uid), jsonEncode(data));
    });
  }

  /// 读取当前账号上次成功获取的勋章列表；null 表示尚未缓存。
  static Future<List<LKMedal>?> cachedMedals(int uid) async {
    if (uid <= 0) return null;
    final raw =
        (await SharedPreferences.getInstance()).getString(_medalCacheKey(uid));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((e) => LKMedal.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<void> cacheMedals(int uid, List<LKMedal> medals,
      {bool Function()? isCurrent}) async {
    if (uid <= 0 || (isCurrent != null && !isCurrent())) return;
    final data = medals
        .map((medal) => {
              'medal_id': medal.medalId,
              'name': medal.name,
              'image': medal.image,
              'equipped': medal.equipped,
            })
        .toList();
    final generation = _sessionGeneration;
    await _queueSessionWrite(() async {
      if (generation != _sessionGeneration ||
          (isCurrent != null && !isCurrent())) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      if (generation != _sessionGeneration ||
          (isCurrent != null && !isCurrent())) {
        return;
      }
      await prefs.setString(_medalCacheKey(uid), jsonEncode(data));
      if (generation != _sessionGeneration ||
          (isCurrent != null && !isCurrent())) {
        return;
      }
      await cacheGlobalMedals({uid: medals});
    });
  }

  /// 读取所有动态/公开资料共用的用户勋章缓存，避免每个页面重复请求。
  static Future<Map<int, List<LKMedal>>> cachedGlobalMedals() async {
    final memory = _globalMedalsMemory;
    if (memory != null) return Map<int, List<LKMedal>>.from(memory);
    return _globalMedalsLoad ??= _loadGlobalMedals().whenComplete(() {
      _globalMedalsLoad = null;
    });
  }

  static Future<Map<int, List<LKMedal>>> _loadGlobalMedals() async {
    final raw =
        (await SharedPreferences.getInstance()).getString(_globalMedalsKey);
    if (raw == null || raw.isEmpty) {
      _globalMedalsMemory = <int, List<LKMedal>>{};
      return {};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <int, List<LKMedal>>{};
      for (final entry in decoded.entries) {
        final uid = int.tryParse(entry.key.toString());
        final list = entry.value;
        if (uid == null || uid <= 0 || list is! List) continue;
        final medals = list
            .whereType<Map>()
            .map((e) => LKMedal.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.image.isNotEmpty)
            .take(5)
            .toList();
        if (medals.isNotEmpty) result[uid] = medals;
      }
      _globalMedalsMemory = result;
      return Map<int, List<LKMedal>>.from(result);
    } catch (_) {
      _globalMedalsMemory = <int, List<LKMedal>>{};
      return {};
    }
  }

  static Future<void> cacheGlobalMedals(
      Map<int, List<LKMedal>> incoming) async {
    final updates = incoming.entries
        .where((entry) => entry.key > 0 && entry.value.isNotEmpty)
        .toList();
    if (updates.isEmpty) return;
    try {
      final merged = Map<int, List<LKMedal>>.from(
          _globalMedalsMemory ?? await cachedGlobalMedals());
      for (final entry in updates) {
        // 已更新用户移动到 Map 末尾，使容量限制保留最近出现的用户。
        merged.remove(entry.key);
        merged[entry.key] = entry.value.take(5).toList();
      }
      // 控制缓存体积，只保留最近出现的最多 500 个用户。
      final keys = merged.keys.toList();
      if (keys.length > 500) {
        for (final key in keys.take(keys.length - 500)) {
          merged.remove(key);
        }
      }
      _globalMedalsMemory = merged;
      _globalMedalsWriteTimer?.cancel();
      _globalMedalsWriteTimer = Timer(
        const Duration(milliseconds: 600),
        () => unawaited(_persistGlobalMedals()),
      );
    } catch (_) {
      // 缓存失败不影响动态内容显示。
    }
  }

  static Future<void> _persistGlobalMedals() async {
    final memory = _globalMedalsMemory;
    if (memory == null) return;
    final encoded = <String, dynamic>{
      for (final entry in memory.entries)
        '${entry.key}': entry.value
            .take(5)
            .map((medal) => {
                  'medal_id': medal.medalId,
                  'name': medal.name,
                  'image': medal.image,
                  'equipped': medal.equipped,
                })
            .toList(),
    };
    try {
      await (await SharedPreferences.getInstance())
          .setString(_globalMedalsKey, jsonEncode(encoded));
    } catch (_) {
      // 后台持久化失败不影响当前进程内缓存。
    }
  }

  static ThemeMode _parseTheme(String? s) => switch (s) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}

/// 阅读器偏好(持久化)
class ReaderPrefs {
  static Future<SharedPreferences> _p() => SharedPreferences.getInstance();

  static Future<ReaderSettings> loadAll() async {
    final prefs = await _p();
    final autoMargin = prefs.getBool('r_auto_margin') ?? true;
    final customMargins = prefs.getBool('r_custom_margins') ?? (!autoMargin);
    final typography = ReaderTypography(
      lineHeight: prefs.getDouble('r_lh') ?? 1.7,
      paragraphSpacing: prefs.getDouble('r_para_spacing') ?? 12.0,
      letterSpacing: prefs.getDouble('r_letter_spacing') ?? 0.3,
      wordSpacing: prefs.getDouble('r_word_spacing') ?? 0.0,
      firstLineIndentChars: prefs.getDouble('r_indent') ?? 0.0,
      justify: prefs.getBool('r_justify') ?? false,
      weight: ReaderFontWeight.parse(prefs.getString('r_font_weight'),
          legacyBold: prefs.getBool('r_bold') ?? false),
      autoMargin: autoMargin,
      marginHorizontal:
          prefs.getDouble('r_margin_h') ?? (prefs.getDouble('r_ml') ?? 20.0),
      customMargins: customMargins,
      marginTop: prefs.getDouble('r_mt') ?? 56.0,
      marginBottom: prefs.getDouble('r_mb') ?? 70.0,
      marginLeft: prefs.getDouble('r_ml') ?? 20.0,
      marginRight: prefs.getDouble('r_mr') ?? 20.0,
      columnMode: ReaderColumnMode.values.firstWhere(
        (m) => m.name == prefs.getString('r_col_mode'),
        orElse: () => ReaderColumnMode.auto,
      ),
    );
    final customTextColor = prefs.containsKey('r_text_color')
        ? (prefs.getInt('r_text_color') == -1
            ? null
            : prefs.getInt('r_text_color'))
        : null;
    return ReaderSettings(
      fontSize: prefs.getDouble('r_font') ?? 17,
      typography: typography,
      textColor: customTextColor,
      bgPreset: prefs.getInt('r_bg') ?? -1,
      bgFollowSystem: prefs.getBool('r_bg_sys') ?? false,
      keepScreenOn: prefs.getBool('r_keep_on') ?? false,
      hideStatusBar: prefs.getBool('r_hide_bar') ?? false,
      tapTurnPage: prefs.getBool('r_tap_turn') ?? false,
      volumeTurnPage: prefs.getBool('r_vol_turn') ?? false,
      showIndicators: prefs.getBool('r_ind') ?? true,
      indicatorPosition: const IndicatorPosition().copyWith(
          top: prefs.getDouble('r_ind_top'),
          bottom: prefs.getDouble('r_ind_bottom'),
          side: prefs.getDouble('r_ind_side'),
          titleAlignment: prefs.getDouble('r_ind_align'),
          topFontSize: prefs.getDouble('r_ind_top_size') ??
              prefs.getDouble('r_ind_size'),
          bottomFontSize: prefs.getDouble('r_ind_bot_size') ??
              prefs.getDouble('r_ind_size')),
      traditional: prefs.getBool('r_trad') ?? false,
      simplified: prefs.getBool('r_simp') ?? false,
      pagedMode: prefs.getBool('r_paged') ?? false,
    );
  }

  static Future<void> saveTypography(ReaderTypography t) async {
    final prefs = await _p();
    await Future.wait([
      prefs.setDouble('r_lh', t.lineHeight),
      prefs.setDouble('r_para_spacing', t.paragraphSpacing),
      prefs.setDouble('r_letter_spacing', t.letterSpacing),
      prefs.setDouble('r_word_spacing', t.wordSpacing),
      prefs.setDouble('r_indent', t.firstLineIndentChars),
      prefs.setBool('r_justify', t.justify),
      prefs.setBool('r_bold', t.bold),
      prefs.setString('r_font_weight', t.weight.name),
      prefs.setBool('r_auto_margin', t.autoMargin),
      prefs.setDouble('r_margin_h', t.marginHorizontal),
      prefs.setBool('r_custom_margins', t.customMargins),
      prefs.setDouble('r_mt', t.marginTop),
      prefs.setDouble('r_mb', t.marginBottom),
      prefs.setDouble('r_ml', t.marginLeft),
      prefs.setDouble('r_mr', t.marginRight),
      prefs.setString('r_col_mode', t.columnMode.name),
    ]);
  }

  static Future<double> fontSize() async =>
      (await _p()).getDouble('r_font') ?? 17;
  static Future<void> setFontSize(double v) async =>
      (await _p()).setDouble('r_font', v);

  static Future<double> lineHeight() async =>
      (await _p()).getDouble('r_lh') ?? 1.7;
  static Future<void> setLineHeight(double v) async =>
      (await _p()).setDouble('r_lh', v);

  static Future<int> bgPreset() async => (await _p()).getInt('r_bg') ?? -1;
  static Future<void> setBgPreset(int v) async =>
      (await _p()).setInt('r_bg', v);

  static const String _keyTextColor = 'r_text_color';

  /// 自定义文字颜色(32位 ARGB int), null 表示使用当前背景预设默认文字颜色
  static Future<int?> textColor() async {
    final p = await _p();
    if (!p.containsKey(_keyTextColor)) return null;
    final val = p.getInt(_keyTextColor);
    if (val == null || val == -1) return null;
    return val;
  }

  static Future<void> setTextColor(int? v) async {
    final p = await _p();
    if (v == null || v == -1) {
      await p.remove(_keyTextColor);
    } else {
      await p.setInt(_keyTextColor, v);
    }
  }

  static Future<bool> bgFollowSystem() async =>
      (await _p()).getBool('r_bg_sys') ?? false;
  static Future<void> setBgFollowSystem(bool v) async =>
      (await _p()).setBool('r_bg_sys', v);

  static Future<bool> keepScreenOn() async =>
      (await _p()).getBool('r_keep_on') ?? false;
  static Future<void> setKeepScreenOn(bool v) async =>
      (await _p()).setBool('r_keep_on', v);

  static Future<bool> hideStatusBar() async =>
      (await _p()).getBool('r_hide_bar') ?? false;
  static Future<void> setHideStatusBar(bool v) async =>
      (await _p()).setBool('r_hide_bar', v);

  static Future<bool> tapTurnPage() async =>
      (await _p()).getBool('r_tap_turn') ?? false;
  static Future<void> setTapTurnPage(bool v) async =>
      (await _p()).setBool('r_tap_turn', v);

  static Future<bool> volumeTurnPage() async =>
      (await _p()).getBool('r_vol_turn') ?? false;
  static Future<void> setVolumeTurnPage(bool v) async =>
      (await _p()).setBool('r_vol_turn', v);

  static Future<bool> autoMargin() async =>
      (await _p()).getBool('r_auto_margin') ?? true;
  static Future<void> setAutoMargin(bool v) async =>
      (await _p()).setBool('r_auto_margin', v);

  static Future<double> marginTop() async =>
      (await _p()).getDouble('r_mt') ?? 56;
  static Future<void> setMarginTop(double v) async =>
      (await _p()).setDouble('r_mt', v);
  static Future<double> marginBottom() async =>
      (await _p()).getDouble('r_mb') ?? 70;
  static Future<void> setMarginBottom(double v) async =>
      (await _p()).setDouble('r_mb', v);
  static Future<double> marginLeft() async =>
      (await _p()).getDouble('r_ml') ?? 20;
  static Future<void> setMarginLeft(double v) async =>
      (await _p()).setDouble('r_ml', v);
  static Future<double> marginRight() async =>
      (await _p()).getDouble('r_mr') ?? 20;
  static Future<void> setMarginRight(double v) async =>
      (await _p()).setDouble('r_mr', v);

  static Future<void> saveIndicatorPosition(IndicatorPosition value) async {
    final prefs = await _p();
    final v = value.copyWith();
    await Future.wait([
      prefs.setDouble('r_ind_top', v.top),
      prefs.setDouble('r_ind_bottom', v.bottom),
      prefs.setDouble('r_ind_side', v.side),
      prefs.setDouble('r_ind_align', v.titleAlignment),
      prefs.setDouble('r_ind_top_size', v.topFontSize),
      prefs.setDouble('r_ind_bot_size', v.bottomFontSize),
    ]);
  }

  static Future<bool> showIndicators() async =>
      (await _p()).getBool('r_ind') ?? true;
  static Future<void> setShowIndicators(bool v) async =>
      (await _p()).setBool('r_ind', v);

  static Future<bool> traditional() async =>
      (await _p()).getBool('r_trad') ?? false;
  static Future<void> setTraditional(bool v) async =>
      (await _p()).setBool('r_trad', v);

  static Future<bool> simplified() async =>
      (await _p()).getBool('r_simp') ?? false;
  static Future<void> setSimplified(bool v) async =>
      (await _p()).setBool('r_simp', v);

  static Future<bool> pagedMode() async =>
      (await _p()).getBool('r_paged') ?? false;
  static Future<void> setPagedMode(bool v) async =>
      (await _p()).setBool('r_paged', v);

  static Future<bool> feedListMode() async =>
      (await _p()).getBool('feed_list') ?? false;
  static Future<void> setFeedListMode(bool v) async =>
      (await _p()).setBool('feed_list', v);

  static Future<int> gridColumnCount() async =>
      (await _p()).getInt('grid_column_count') ?? 0;
  static Future<void> setGridColumnCount(int v) async =>
      LKStore.setGridColumnCount(v);

  /// 章节阅读位置(0~1 进度),用于重新打开时自动跳转到上次阅读处
  static Future<double> readPosFrac(int chapterId) async =>
      (await _p()).getDouble('r_pos_$chapterId') ?? 0;
  static Future<void> setReadPosFrac(int chapterId, double frac) async =>
      (await _p()).setDouble('r_pos_$chapterId', frac.clamp(0.0, 1.0));

  /// 正文锚点位置。旧版只保存百分比，保留旧键作为兼容回退。
  static Future<ReadingPosition?> readPosition(int chapterId) async {
    final raw = (await _p()).getString('r_pos_v2_$chapterId');
    if (raw == null || raw.isEmpty) return null;
    try {
      return ReadingPosition.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> setPosition(
      int chapterId, ReadingPosition position) async {
    await (await _p())
        .setString('r_pos_v2_$chapterId', jsonEncode(position.toJson()));
  }
}

class ReaderSettings {
  final double fontSize;
  final ReaderTypography typography;
  final int? textColor;
  final int bgPreset;
  final bool bgFollowSystem;
  final bool keepScreenOn;
  final bool hideStatusBar;
  final bool tapTurnPage;
  final bool showIndicators;
  final IndicatorPosition indicatorPosition;
  final bool traditional;
  final bool simplified;
  final bool pagedMode;
  final bool volumeTurnPage;

  double get lineHeight => typography.lineHeight;
  bool get autoMargin => typography.autoMargin;
  double get marginTop => typography.marginTop;
  double get marginBottom => typography.marginBottom;
  double get marginLeft => typography.marginLeft;
  double get marginRight => typography.marginRight;

  ReaderSettings({
    this.volumeTurnPage = false,
    required this.fontSize,
    ReaderTypography? typography,
    this.textColor,
    double? lineHeight,
    bool? autoMargin,
    double? marginTop,
    double? marginBottom,
    double? marginLeft,
    double? marginRight,
    required this.bgPreset,
    required this.bgFollowSystem,
    required this.keepScreenOn,
    required this.hideStatusBar,
    required this.tapTurnPage,
    required this.showIndicators,
    this.indicatorPosition = const IndicatorPosition(),
    required this.traditional,
    required this.simplified,
    required this.pagedMode,
  }) : typography = typography ??
            ReaderTypography(
              lineHeight: lineHeight ?? 1.70,
              autoMargin: autoMargin ?? true,
              marginTop: marginTop ?? 56.0,
              marginBottom: marginBottom ?? 70.0,
              marginLeft: marginLeft ?? 20.0,
              marginRight: marginRight ?? 20.0,
            );
}
