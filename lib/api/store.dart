import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lk_client.dart';
import 'models.dart';
import 'reader_cache.dart';
import 'reading_session.dart';
import '../reader/reading_position.dart';

/// 封面模糊模式
enum CoverBlurMode {
  all,
  brave,
  none,
}

/// 会话与主题持久化
class LKStore {
  /// 主题模式(ValueNotifier 让 MaterialApp 即时切换)
  static final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier(ThemeMode.system);

  /// 流量节省模式(ValueNotifier 让全局图片加载即时响应)
  static final ValueNotifier<bool> dataSaverMode = ValueNotifier(false);
  static final ValueNotifier<bool> animationsEnabled = ValueNotifier(true);
  static final ValueNotifier<bool> landscapeEnabled = ValueNotifier(false);

  /// 书籍封面高斯模糊模式（全部书籍 / 勇者书籍 / 关闭）
  static final ValueNotifier<CoverBlurMode> coverBlurMode =
      ValueNotifier(CoverBlurMode.brave);

  /// 防社死封面高斯模糊模式(ValueNotifier 让全局封面即时响应，与 coverBlurMode 保持联动)
  static final ValueNotifier<bool> nsfwBlurCover = ValueNotifier(true);

  /// 隐藏勇者书籍模式(ValueNotifier 让列表和书架即时响应)
  static final ValueNotifier<bool> hideBraveBooks = ValueNotifier(true);

  /// 书籍网格列数偏好（0 表示“自动”，2/3/4/5 表示每行固定本数）
  static final ValueNotifier<int> gridColumnCount = ValueNotifier(0);

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

  static Future<void> load() async {
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
    if (secureStorageReady) {
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
    LKClient.shared.session
      ..securityKey = securityKey
      ..uid = p.getInt('uid') ?? 0
      ..nickname = p.getString('nickname') ?? ''
      ..avatar = p.getString('avatar') ?? '';
    themeMode.value = _parseTheme(p.getString('theme_mode'));
    dataSaverMode.value = p.getBool('data_saver_mode') ?? false;
    animationsEnabled.value = p.getBool('animations_enabled') ?? true;
    landscapeEnabled.value = p.getBool('landscape_enabled') ?? false;
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
    setBraveBookChecker(isBraveBook);
    final storedBraveIds = p.getStringList('known_brave_book_ids');
    if (storedBraveIds != null) {
      _braveBookIds.addAll(storedBraveIds.map(int.tryParse).whereType<int>());
    }
    unawaited(LKClient.shared.trimResponseCache());
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    final s = LKClient.shared.session;
    if (s.securityKey.isEmpty) {
      await _secure.delete(key: 'security_key');
    } else {
      await _secure.write(key: 'security_key', value: s.securityKey);
    }
    // 清理旧版本可能留下的明文副本。
    await p.remove('security_key');
    await p.setInt('uid', s.uid);
    await p.setString('nickname', s.nickname);
    await p.setString('avatar', s.avatar);
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    final p = await SharedPreferences.getInstance();
    await p.setString('theme_mode', mode.name);
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

  static Future<void> clear() async {
    final oldUid = LKClient.shared.session.uid;
    LKReadingSession.shared.reset();
    // Invalidate reader content before any awaited account cleanup so an
    // in-flight chapter response cannot repopulate the previous scope.
    final readerCacheClear = ReaderContentCache.clear();
    final p = await SharedPreferences.getInstance();
    try {
      await _secure.delete(key: 'security_key');
    } catch (_) {
      // 安全存储暂不可用时仍清理内存会话和其他本地账号资料。
    }
    await p.remove('security_key');
    await p.remove('uid');
    await p.remove('nickname');
    await p.remove('avatar');
    if (oldUid > 0) {
      await p.remove(_profileCacheKey(oldUid));
      await p.remove(_medalCacheKey(oldUid));
      await p.remove('welfare_home_cache_v1_$oldUid');
      final accountPageCaches = p
          .getKeys()
          .where((key) =>
              key.startsWith(_pageCachePrefix) && key.contains('_u${oldUid}_'))
          .toList(growable: false);
      await Future.wait(accountPageCaches.map(p.remove));
    }
    await LKClient.shared.clearResponseCache();
    await readerCacheClear;
    LKClient.shared.session.clear();
    LKClient.sessionRev.value++;
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
    await (await SharedPreferences.getInstance()).setString(
        _localShelfKey, jsonEncode(books.map((e) => e.toJson()).toList()));
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
    await (await SharedPreferences.getInstance())
        .setString(_profileCacheKey(uid), jsonEncode(data));
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
    final prefs = await SharedPreferences.getInstance();
    if (isCurrent != null && !isCurrent()) return;
    await prefs.setString(_medalCacheKey(uid), jsonEncode(data));
    if (isCurrent != null && !isCurrent()) return;
    await cacheGlobalMedals({uid: medals});
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
    return ReaderSettings(
      fontSize: prefs.getDouble('r_font') ?? 17,
      lineHeight: prefs.getDouble('r_lh') ?? 1.7,
      bgPreset: prefs.getInt('r_bg') ?? -1,
      bgFollowSystem: prefs.getBool('r_bg_sys') ?? false,
      keepScreenOn: prefs.getBool('r_keep_on') ?? false,
      hideStatusBar: prefs.getBool('r_hide_bar') ?? false,
      tapTurnPage: prefs.getBool('r_tap_turn') ?? false,
      volumeTurnPage: prefs.getBool('r_vol_turn') ?? false,
      autoMargin: prefs.getBool('r_auto_margin') ?? true,
      marginTop: prefs.getDouble('r_mt') ?? 56,
      marginBottom: prefs.getDouble('r_mb') ?? 70,
      marginLeft: prefs.getDouble('r_ml') ?? 20,
      marginRight: prefs.getDouble('r_mr') ?? 20,
      showIndicators: prefs.getBool('r_ind') ?? true,
      traditional: prefs.getBool('r_trad') ?? false,
      simplified: prefs.getBool('r_simp') ?? false,
      pagedMode: prefs.getBool('r_paged') ?? false,
    );
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
  final double lineHeight;
  final int bgPreset;
  final bool bgFollowSystem;
  final bool keepScreenOn;
  final bool hideStatusBar;
  final bool tapTurnPage;
  final bool autoMargin;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;
  final bool showIndicators;
  final bool traditional;
  final bool simplified;
  final bool pagedMode;
  final bool volumeTurnPage;

  const ReaderSettings({
    this.volumeTurnPage = false,
    required this.fontSize,
    required this.lineHeight,
    required this.bgPreset,
    required this.bgFollowSystem,
    required this.keepScreenOn,
    required this.hideStatusBar,
    required this.tapTurnPage,
    required this.autoMargin,
    required this.marginTop,
    required this.marginBottom,
    required this.marginLeft,
    required this.marginRight,
    required this.showIndicators,
    required this.traditional,
    required this.simplified,
    required this.pagedMode,
  });
}
