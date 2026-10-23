import '../widgets/m3_menu_sheet.dart';
import '../services/app_motion.dart';
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/pagination.dart';
import '../api/store.dart';
import '../services/avatar_cache.dart';
import '../services/emoji_catalog.dart';
import '../widgets/common.dart';
import '../widgets/emoji_text.dart';
import 'book_detail_page.dart';
import 'dynamic_publish_page.dart';
import 'media_viewer_page.dart';
import 'comments_page.dart';
import 'user_profile_page.dart';

/// 窄屏单列；平板和开启横屏适配的手机按可用宽度排列。
int dynamicFeedColumnCount(Size viewport) {
  final phoneLandscape =
      LKStore.landscapeEnabled.value && viewport.width > viewport.height;
  if ((!phoneLandscape && viewport.shortestSide < 600) ||
      viewport.width < 560) {
    return 1;
  }
  return viewport.width >= 1100 ? 3 : 2;
}

String normalizedDynamicFeedTab(String tab, {required bool loggedIn}) =>
    !loggedIn && tab == 'follow' ? 'mixed' : tab;

/// 默认广场使用官网游客「关注」数据源；显式关注保留账号关注关系。
({String tab, bool anonymous}) dynamicFeedSource(String tab,
        {required bool loggedIn,
        DynamicFeedMode mode = DynamicFeedMode.anonymousFollow}) =>
    tab == 'mixed' && mode == DynamicFeedMode.legacyMixed
        ? (tab: 'mixed', anonymous: !loggedIn)
        : (
            tab: tab == 'mixed' ? 'follow' : tab,
            anonymous: tab == 'mixed' || !loggedIn
          );

String dynamicFeedCacheVariant(({String tab, bool anonymous}) source) =>
    '${source.anonymous ? 'anonymous' : 'account'}_${source.tab}_v1';

/// 动态广场(本站动态 / 关注动态)
class DynamicPage extends StatefulWidget {
  /// 内嵌模式(作为底部 Tab 使用时无独立 Scaffold/AppBar)
  final bool embedded;
  const DynamicPage({super.key, this.embedded = false});

  @override
  State<DynamicPage> createState() => _DynamicPageState();
}

class _DynamicPageState extends State<DynamicPage> {
  List<LKDynamicItem> _items = [];
  String _cursor = '';
  int _page = 1;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  bool _errorFromAppend = false;
  String _feedTab = 'mixed';
  String _contentFilter = 'all';
  int _requestSerial = 0;
  int _unreadRequestSerial = 0;
  Map<int, List<LKMedal>> _globalMedals = {};
  Map<String, String> _emojiUrls = const {};
  int _unreadCount = 0;
  final ValueNotifier<double> _topBarFrac = ValueNotifier<double>(1.0);
  List<LKDynamicItem> _visibleItems = const [];
  // 与主页保持同一伸缩高度,确保筛选胶囊完整显示并让内容紧贴顶栏。
  static const double _topBarFlex = 100.0;

  String _dynamicKey(LKDynamicItem item) {
    if (item.dynamicId > 0) return 'id:${item.dynamicId}';
    return 'fallback:${item.authorUid}:${item.time}:${item.displayContent}';
  }

  int _compareDynamicItems(LKDynamicItem a, LKDynamicItem b) {
    final aTime = _parseDynamicTime(a.time);
    final bTime = _parseDynamicTime(b.time);
    if (aTime == null && bTime == null) {
      final rawOrder = b.time.compareTo(a.time);
      if (rawOrder != 0) return rawOrder;
    } else {
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      final timeOrder = bTime.compareTo(aTime);
      if (timeOrder != 0) return timeOrder;
    }
    return b.dynamicId.compareTo(a.dynamicId);
  }

  void _rebuildVisibleItems() {
    final visible = _contentFilter == 'book'
        ? _items.where((item) => item.isWorkPost).toList()
        : [..._items];
    final indexed = visible.asMap().entries.toList();
    indexed.sort((a, b) {
      final order = _compareDynamicItems(a.value, b.value);
      return order == 0 ? a.key.compareTo(b.key) : order;
    });
    _visibleItems = indexed.map((entry) => entry.value).toList();
  }

  @override
  void initState() {
    super.initState();
    LKClient.sessionRev.addListener(_onSessionChanged);
    LKStore.dynamicFeedMode.addListener(_onFeedSourceChanged);
    _loadGlobalMedals();
    _loadEmojis();
    _loadUnread();
    unawaited(_startLoad());
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onSessionChanged);
    LKStore.dynamicFeedMode.removeListener(_onFeedSourceChanged);
    _topBarFrac.dispose();
    super.dispose();
  }

  void _onFeedSourceChanged() {
    if (_feedTab == 'mixed') _onSessionChanged();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    _requestSerial++;
    _unreadRequestSerial++;
    setState(() {
      _feedTab = normalizedDynamicFeedTab(_feedTab,
          loggedIn: LKClient.shared.session.isLoggedIn);
      _items = [];
      _visibleItems = const [];
      _cursor = '';
      _page = 1;
      _hasMore = true;
      _loading = false;
      _unreadCount = 0;
      _error = null;
      _errorFromAppend = false;
    });
    unawaited(_startLoad());
    _loadUnread();
  }

  String _dynamicCacheKey({int? uid, String? feedTab}) {
    final source = dynamicFeedSource(feedTab ?? _feedTab,
        loggedIn: LKClient.shared.session.isLoggedIn,
        mode: LKStore.dynamicFeedMode.value);
    return LKStore.pageCacheKey(
      kind: 'dynamic_feed',
      uid: source.anonymous ? 0 : uid ?? LKClient.shared.session.uid,
      variant: dynamicFeedCacheVariant(source),
    );
  }

  Future<void> _startLoad() async {
    final request = _requestSerial;
    final uid = LKClient.shared.session.uid;
    final feedTab = _feedTab;
    final cacheKey = _dynamicCacheKey(uid: uid, feedTab: feedTab);
    final cached = await LKStore.cachedDynamicPage(cacheKey);
    if (!mounted ||
        request != _requestSerial ||
        uid != LKClient.shared.session.uid ||
        feedTab != _feedTab ||
        cacheKey != _dynamicCacheKey()) {
      return;
    }
    if (cached != null) {
      setState(() {
        _items = [...cached];
        _visibleItems = const [];
        _cursor = '';
        _page = 1;
        _hasMore = true;
        _error = null;
        _rebuildVisibleItems();
      });
    }
    await _load(silent: _items.isNotEmpty);
  }

  Future<void> _loadUnread() async {
    if (!LKClient.shared.session.isLoggedIn) return;
    final request = ++_unreadRequestSerial;
    final sessionRevision = LKClient.sessionRev.value;
    final securityKey = LKClient.shared.session.securityKey;
    try {
      final data = await LKApi.dynamicUnread();
      final raw = data['unread_count'] ??
          data['unreadCount'] ??
          data['count'] ??
          data['total_unread'];
      final count = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
      if (!mounted ||
          request != _unreadRequestSerial ||
          sessionRevision != LKClient.sessionRev.value ||
          securityKey != LKClient.shared.session.securityKey ||
          !LKClient.shared.session.isLoggedIn) {
        return;
      }
      setState(() => _unreadCount = count.clamp(0, 99));
    } catch (_) {}
  }

  Future<void> _loadGlobalMedals() async {
    final cached = await LKStore.cachedGlobalMedals();
    if (mounted) setState(() => _globalMedals = cached);
  }

  Future<void> _loadEmojis() async {
    try {
      await YomiruEmojiCatalog.load();
      if (mounted) setState(() => _emojiUrls = YomiruEmojiCatalog.urls);
    } catch (_) {
      // 表情目录不可用时保留原始代码，不影响动态正文加载。
    }
  }

  Future<void> _load({bool append = false, bool silent = false}) async {
    if (append && (_loading || !_hasMore)) return;
    final requestSerial = ++_requestSerial;
    final feedTab = _feedTab;
    final page = append ? _page + 1 : 1;
    final source = dynamicFeedSource(feedTab,
        loggedIn: LKClient.shared.session.isLoggedIn,
        mode: LKStore.dynamicFeedMode.value);
    final previousCursor = _cursor;
    final cacheKey = _dynamicCacheKey();
    if (mounted) {
      setState(() {
        _loading = true;
        if (!append) {
          _error = null;
          _errorFromAppend = false;
        }
      });
    }
    try {
      Future<LoadedPage<LKDynamicItem>> fetchPage(
          int number, String cursor) async {
        final result = await LKApi.dynamicFeedPage(
            tab: source.tab,
            anonymous: source.anonymous,
            cursor: cursor,
            page: number,
            pageSize: 20);
        return LoadedPage(
            items: result.items,
            page: number,
            hasMore: result.hasMore,
            cursor: result.cursor);
      }

      final result = append
          ? await fetchPage(page, previousCursor)
          : await refreshPageWindow(
              loadPage: fetchPage,
              keyOf: _dynamicKey,
              targetItems: _items.length.clamp(0, 100),
              isCurrent: () => mounted && requestSerial == _requestSerial,
            );
      if (!mounted || requestSerial != _requestSerial || feedTab != _feedTab) {
        return;
      }
      final medalUpdates = <int, List<LKMedal>>{};
      for (final item in result.items) {
        if (item.authorUid > 0 && item.authorMedals.isNotEmpty) {
          medalUpdates[item.authorUid] = item.authorMedals;
        }
      }
      YomiruAvatarCache.precache(
          context, result.items.map((item) => item.avatar));
      setState(() {
        if (append) {
          _items = mergePagedItems(_items, result.items, keyOf: _dynamicKey);
        } else {
          _items = [...result.items];
        }
        _cursor = result.cursor;
        _page = result.page;
        _hasMore = result.hasMore &&
            !(append &&
                result.items.isEmpty &&
                result.cursor == previousCursor);
        _error = null;
        _errorFromAppend = false;
        if (medalUpdates.isNotEmpty) {
          _globalMedals = {..._globalMedals, ...medalUpdates};
        }
        _rebuildVisibleItems();
      });
      if (medalUpdates.isNotEmpty) {
        unawaited(LKStore.cacheGlobalMedals(medalUpdates));
      }
      unawaited(LKStore.cacheDynamicPage(cacheKey, _items));
    } catch (e) {
      if (mounted && requestSerial == _requestSerial) {
        setState(() {
          _error = e.toString();
          _errorFromAppend = append;
        });
        if ((silent || !append) && _items.isNotEmpty) {
          _showRefreshError();
        }
      }
    } finally {
      if (mounted && requestSerial == _requestSerial) {
        setState(() => _loading = false);
      }
    }
  }

  void _switchFeedTab(String tab) {
    if (_feedTab == tab) return;
    _requestSerial++;
    setState(() {
      _feedTab = tab;
      _items = [];
      _cursor = '';
      _page = 1;
      _hasMore = true;
      _error = null;
      _errorFromAppend = false;
      _loading = false;
      _rebuildVisibleItems();
    });
    _topBarFrac.value = 1.0;
    unawaited(_startLoad());
  }

  void _switchContentFilter(String filter) {
    if (_contentFilter == filter) return;
    setState(() {
      _contentFilter = filter;
      _rebuildVisibleItems();
    });
    _topBarFrac.value = 1.0;
  }

  void _showRefreshError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _items.isEmpty) return;
      showFloatingPrompt(context, '连接失败，请检查网络连接');
    });
  }

  List<LKMedal> _medalsFor(LKDynamicItem item) => item.authorMedals.isNotEmpty
      ? item.authorMedals
      : (_globalMedals[item.authorUid] ?? const <LKMedal>[]);

  Widget _dynamicTitle({bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _feedTab == 'mixed' ? null : () => _switchFeedTab('mixed'),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8, vertical: 4),
        child: Badge(
          isLabelVisible: _unreadCount > 0,
          label: Text('$_unreadCount'),
          child: Text(
            '动态',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _pillButton({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: selected
          ? (isDark
              ? scheme.primary.withValues(alpha: 0.22)
              : scheme.primary.withValues(alpha: 0.12))
          : (isDark
              ? const Color(0xFF1E2025)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5)),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _feedControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: Row(
        children: [
          _pillButton(
            icon: _feedTab == 'follow'
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            label: '关注',
            selected: _feedTab == 'follow',
            onTap: () =>
                _switchFeedTab(_feedTab == 'follow' ? 'mixed' : 'follow'),
          ),
          const SizedBox(width: 8),
          _pillButton(
            icon: Icons.menu_book_rounded,
            label: '仅作品',
            selected: _contentFilter == 'book',
            onTap: () =>
                _switchContentFilter(_contentFilter == 'book' ? 'all' : 'book'),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  /// 与主页相同的让渡式收合:顶栏吸收手指滚动距离,内容不会突然跳动。
  Widget _scrollingHeader() {
    return ValueListenableBuilder<double>(
      valueListenable: _topBarFrac,
      builder: (context, topBarFrac, _) => ClipRect(
        child: SizedBox(
          height: _topBarFlex * topBarFrac,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                top: -_topBarFlex * (1.0 - topBarFrac),
                left: 0,
                right: 0,
                height: _topBarFlex,
                child: ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                          child: Row(children: [
                            _dynamicTitle(),
                            const Spacer(),
                            if (LKClient.shared.session.isLoggedIn)
                              IconButton(
                                tooltip: '发布动态',
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.edit_note_rounded),
                                onPressed: () async {
                                  final published = await Navigator.push<bool>(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const DynamicPublishPage()),
                                  );
                                  if (published == true && mounted) _load();
                                },
                              ),
                          ]),
                        ),
                        _feedControls(),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState(String message) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: 260,
          child: Center(
              child: Text(message, style: const TextStyle(color: Colors.grey))),
        ),
      ],
    );
  }

  double _previewRatio(LKDynamicMedia media) {
    if (media.width <= 0 || media.height <= 0) return 1.45;
    // 信息流不直接按原图像素高度排版,只保留大致方向并限制预览高度。
    return (media.width / media.height).clamp(0.65, 1.8).toDouble();
  }

  Widget _mediaTile(LKDynamicMedia media, {double? width, double? height}) {
    if (media.url.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final isDataSaver = LKStore.dataSaverMode.value;
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: isDataSaver
          ? Container(
              width: width,
              height: height,
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.image_outlined,
                        size: 28, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 4),
                    Text(
                      '流量节省模式\n点击查看大图',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          : CachedNetworkImage(
              fadeOutDuration: AppMotion.duration(context, 1000),
              fadeInDuration: AppMotion.duration(context, 500),
              imageUrl: media.url,
              width: width,
              height: height,
              memCacheWidth:
                  width == null ? null : imageCacheDimension(context, width),
              fit: BoxFit.cover,
              placeholder: (_, __) => ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(child: LkLoadingIndicator(size: 22)),
              ),
              errorWidget: (_, __, ___) => ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
    );
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MediaViewerPage(url: media.url)),
      ),
      child: image,
    );
  }

  Widget _mediaGallery(List<LKDynamicMedia> media) {
    final visible = media.where((item) => item.url.isNotEmpty).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (visible.length == 1) {
            final item = visible.first;
            final height = (constraints.maxWidth / _previewRatio(item))
                .clamp(140.0, 280.0)
                .toDouble();
            return _mediaTile(item,
                width: constraints.maxWidth, height: height);
          }
          final size = (constraints.maxWidth - 12) / 3;
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            children: visible
                .map((item) => _mediaTile(item, width: size, height: size))
                .toList(),
          );
        },
      ),
    );
  }

  bool _onFeedScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final delta = notification.scrollDelta ?? 0.0;
      if (delta.abs() < 0.5) return false;
      final current = _topBarFrac.value;
      final next = (current - delta / _topBarFlex).clamp(0.0, 1.0);
      final diff = next - current;
      if (diff == 0 || !mounted) return false;
      _topBarFrac.value = next;
      // 顶栏吸收的位移从列表滚动位置中抵消,保持与主页一样跟手。
      Scrollable.of(notification.context!)
          .position
          .correctBy(diff * _topBarFlex);
    } else if (notification is OverscrollNotification) {
      final current = _topBarFrac.value;
      final next =
          (current - notification.overscroll / _topBarFlex).clamp(0.0, 1.0);
      if (next != current && mounted) _topBarFrac.value = next;
    }
    return false;
  }

  Widget _paginationFooter() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: LkLoadingIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: TextButton.icon(
            onPressed: () => _load(append: _errorFromAppend),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(append: true);
    });
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: LkLoadingIndicator()),
    );
  }

  Widget _feedBody() {
    final visibleItems = _visibleItems;
    final columns = dynamicFeedColumnCount(MediaQuery.sizeOf(context));
    final itemIndices = <String, int>{
      for (var i = 0; i < visibleItems.length; i++)
        _dynamicKey(visibleItems[i]): i,
    };
    return NotificationListener<ScrollNotification>(
      onNotification: _onFeedScroll,
      child: MotionRefreshIndicator(
        onRefresh: _load,
        child: _error != null && _items.isEmpty
            ? _emptyState(_error!)
            : _loading && visibleItems.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: MediaQuery.sizeOf(context).height * 0.65,
                        child: const Center(child: LkLoadingIndicator()),
                      ),
                    ],
                  )
                : visibleItems.isEmpty && !_hasMore && !_loading
                    ? _emptyState(
                        _contentFilter == 'book' ? '暂无作品发布动态' : '暂无动态')
                    : CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverMasonryGrid(
                            gridDelegate:
                                SliverSimpleGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                            ),
                            mainAxisSpacing: 0,
                            crossAxisSpacing: 0,
                            delegate: SliverChildBuilderDelegate((_, i) {
                              Widget buildCard(int itemIndex) {
                                final d = visibleItems[itemIndex];
                                final hasBook = d.bookId > 0 &&
                                    d.bookTitle.trim().isNotEmpty;
                                final medals = _medalsFor(d);
                                return Padding(
                                  key: ValueKey<String>(_dynamicKey(d)),
                                  padding:
                                      const EdgeInsets.fromLTRB(8, 0, 8, 4),
                                  child: Card(
                                    margin: EdgeInsets.zero,
                                    clipBehavior: Clip.antiAlias,
                                    child: InkWell(
                                      onTap: d.dynamicId > 0
                                          ? () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                  builder: (_) => CommentsPage(
                                                    dynamicId: d.dynamicId,
                                                    dynamicPreview: d,
                                                  ),
                                                ),
                                              )
                                          : null,
                                      onLongPress: () => _actions(d),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  GestureDetector(
                                                    onTap: d.authorUid > 0
                                                        ? () => openUserProfile(
                                                            context,
                                                            d.authorUid)
                                                        : null,
                                                    child: CircleAvatar(
                                                        radius: 16,
                                                        backgroundImage:
                                                            YomiruAvatarCache
                                                                .providerOrNull(
                                                                    d.avatar),
                                                        child: YomiruAvatarCache
                                                                    .providerOrNull(d
                                                                        .avatar) ==
                                                                null
                                                            ? const Icon(
                                                                Icons.person,
                                                                size: 18)
                                                            : null),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Wrap(
                                                      spacing: 5,
                                                      runSpacing: 3,
                                                      crossAxisAlignment:
                                                          WrapCrossAlignment
                                                              .center,
                                                      children: [
                                                        GestureDetector(
                                                          onTap: d.authorUid > 0
                                                              ? () =>
                                                                  openUserProfile(
                                                                      context,
                                                                      d.authorUid)
                                                              : null,
                                                          child: Text(
                                                              d.nickname.isEmpty
                                                                  ? '用户 ${d.authorUid}'
                                                                  : d.nickname,
                                                              style: TextStyle(
                                                                  color: Colors
                                                                      .indigo
                                                                      .shade400,
                                                                  fontSize:
                                                                      13)),
                                                        ),
                                                        ...medals
                                                            .take(5)
                                                            .map(
                                                                (medal) =>
                                                                    Tooltip(
                                                                      message: medal
                                                                          .name,
                                                                      child:
                                                                          GestureDetector(
                                                                        onTap: () => showFloatingPrompt(
                                                                            context,
                                                                            medal.name.isEmpty
                                                                                ? '未知勋章'
                                                                                : medal.name),
                                                                        child:
                                                                            CircleAvatar(
                                                                          radius:
                                                                              10,
                                                                          backgroundColor: Theme.of(context)
                                                                              .colorScheme
                                                                              .surfaceContainerHighest,
                                                                          backgroundImage:
                                                                              YomiruMedalCache.providerOrNull(medal.image),
                                                                          child: YomiruMedalCache.providerOrNull(medal.image) == null
                                                                              ? const Icon(Icons.military_tech, size: 10)
                                                                              : null,
                                                                        ),
                                                                      ),
                                                                    )),
                                                        if (d.eventType
                                                            .isNotEmpty)
                                                          Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal:
                                                                        6,
                                                                    vertical:
                                                                        2),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: Theme.of(context)
                                                                          .brightness ==
                                                                      Brightness
                                                                          .dark
                                                                  ? Colors.grey
                                                                      .shade800
                                                                  : Colors.grey
                                                                      .shade300,
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          4),
                                                            ),
                                                            child: Text(
                                                                _eventLabel(d
                                                                    .eventType),
                                                                style: const TextStyle(
                                                                    fontSize:
                                                                        10,
                                                                    color: Colors
                                                                        .white)),
                                                          ),
                                                      ],
                                                    ),
                                                  ),
                                                ]),
                                            const SizedBox(height: 6),
                                            LkEmojiText(
                                              text: d.displayContent,
                                              emojiUrls: _emojiUrls,
                                            ),
                                            if (hasBook)
                                              InkWell(
                                                onTap: () => Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                      builder: (_) =>
                                                          BookDetailPage(
                                                              bookId:
                                                                  d.bookId)),
                                                ),
                                                child: Container(
                                                  margin: const EdgeInsets.only(
                                                      top: 8),
                                                  padding:
                                                      const EdgeInsets.all(8),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        activityBookReferenceColor(
                                                            Theme.of(context)
                                                                .brightness),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6),
                                                  ),
                                                  child: Row(children: [
                                                    CoverImage(
                                                        url: d.bookCover,
                                                        width: 40,
                                                        height: 53),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Text(d.bookTitle,
                                                          maxLines: 2,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: const TextStyle(
                                                              fontSize: 13,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600)),
                                                    ),
                                                  ]),
                                                ),
                                              ),
                                            _mediaGallery(d.media),
                                            const SizedBox(height: 6),
                                            Row(children: [
                                              Text(
                                                  '赞 ${d.likeCount} · 评论 ${d.commentCount}',
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color: Colors
                                                          .grey.shade500)),
                                              const Spacer(),
                                              Text(_shortTime(d.time),
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color: Colors
                                                          .grey.shade400)),
                                            ]),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }

                              return buildCard(i);
                            },
                                childCount: visibleItems.length,
                                findChildIndexCallback: (key) =>
                                    key is ValueKey<String>
                                        ? itemIndices[key.value]
                                        : null),
                          ),
                          if (_hasMore)
                            SliverToBoxAdapter(child: _paginationFooter()),
                        ],
                      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.embedded) {
      return Scaffold(
        body: Column(
          children: [
            SafeArea(bottom: false, child: _scrollingHeader()),
            Expanded(child: _feedBody()),
          ],
        ),
      );
    }
    // 内嵌模式:状态栏区域由 HomePage 的状态栏背景条负责,这里不再加 SafeArea
    return Column(children: [
      _scrollingHeader(),
      Expanded(child: _feedBody()),
    ]);
  }

  String _eventLabel(String e) {
    return dynamicEventLabel(e);
  }

  DateTime? _parseDynamicTime(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    final number = int.tryParse(value);
    if (number != null && number > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
          number > 20000000000 ? number : number * 1000);
    }
    final normalized = value.replaceAll('/', '-').replaceFirst(' ', 'T');
    return DateTime.tryParse(value) ?? DateTime.tryParse(normalized);
  }

  String _shortTime(String raw) {
    final parsed = _parseDynamicTime(raw)?.toLocal();
    if (parsed == null) {
      return raw.replaceFirst('T', ' ').split('.').first;
    }
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    if (parsed.year == now.year &&
        parsed.month == now.month &&
        parsed.day == now.day) {
      return '${two(parsed.hour)}:${two(parsed.minute)}';
    }
    if (parsed.year == now.year) {
      return '${two(parsed.month)}-${two(parsed.day)} ${two(parsed.hour)}:${two(parsed.minute)}';
    }
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} ${two(parsed.hour)}:${two(parsed.minute)}';
  }

  void _actions(LKDynamicItem d) {
    if (d.dynamicId <= 0) return;
    final loggedIn = LKClient.shared.session.isLoggedIn;
    showModalBottomSheet<void>(
      sheetAnimationStyle: AppMotion.style(context),
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return M3MenuSheet(
          title: '动态操作',
          icon: Icons.more_horiz_rounded,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await Clipboard.setData(
                        ClipboardData(text: dynamicWebsiteUrl(d.dynamicId)));
                    if (mounted) showLkError(context, '已复制动态链接');
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 14),
                    child: Row(
                      children: [
                        Icon(Icons.link_rounded,
                            size: 20, color: scheme.onSurface),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            '复制动态链接',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded,
                            size: 18, color: scheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (loggedIn) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color:
                      d.liked ? scheme.secondaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () async {
                      Navigator.pop(sheetContext);
                      await LKApi.toggleDynamicLike(d.dynamicId, !d.liked);
                      _load();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      child: Row(
                        children: [
                          Icon(
                            d.liked
                                ? Icons.thumb_up_rounded
                                : Icons.thumb_up_outlined,
                            size: 20,
                            color: d.liked
                                ? scheme.onSecondaryContainer
                                : scheme.onSurface,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              d.liked ? '已点赞（点击取消）' : '点赞此动态',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight:
                                    d.liked ? FontWeight.bold : FontWeight.w500,
                                color: d.liked
                                    ? scheme.onSecondaryContainer
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                          if (d.liked)
                            Icon(Icons.check_rounded,
                                size: 20, color: scheme.onSecondaryContainer),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: d.favorited
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () async {
                      Navigator.pop(sheetContext);
                      await LKApi.toggleDynamicFavorite(
                          d.dynamicId, !d.favorited);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      child: Row(
                        children: [
                          Icon(
                            d.favorited
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            size: 20,
                            color: d.favorited
                                ? Colors.amber.shade700
                                : scheme.onSurface,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              d.favorited ? '已收藏（点击取消）' : '收藏此动态',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: d.favorited
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                color: d.favorited
                                    ? scheme.onSecondaryContainer
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                          if (d.favorited)
                            Icon(Icons.check_rounded,
                                size: 20, color: scheme.onSecondaryContainer),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
