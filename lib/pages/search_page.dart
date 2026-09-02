import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/pagination.dart';
import '../api/store.dart';
import '../widgets/common.dart';
import '../services/avatar_cache.dart';
import '../services/emoji_catalog.dart';
import '../widgets/emoji_text.dart';
import 'book_detail_page.dart';
import 'media_viewer_page.dart';
import 'user_profile_page.dart';

/// 搜索页:关键词 + 分类(轻小说/原创/同人/EPUB)+ 标签(含"最近更新"更新时间筛选)+ 排序(相关/最新)
class SearchPage extends StatefulWidget {
  /// 从详情页标签跳转时传入的初始标签
  final String? initialTag;
  const SearchPage({super.key, this.initialTag});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final List<dynamic> _items = [];

  /// 热门标签(tag_items):{title, jumpType, jumpValue}
  List<Map<String, String>> _tags = [];
  List<Map<String, String>> _channels = [];
  String? _tag; // 选中的标签 jumpValue
  String? _channel; // 选中的分类 code
  String _sort = 'relevance';
  String? _error;
  bool _loading = false;
  int _page = 0;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    _tag = widget.initialTag;
    _loadTaxonomy();
    if (widget.initialTag != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(0, false));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadTaxonomy() async {
    try {
      final t = await LKApi.searchTaxonomy();
      // 第一个 tab 的第一个 section = 热门标签(含"最近更新")
      final tags = <Map<String, String>>[];
      final tabs = (t['tabs'] as List?) ?? const [];
      for (final tab in tabs) {
        final groups = (tab['groups'] as List?) ?? const [];
        for (final g in groups) {
          final sections = (g['sections'] as List?) ?? const [];
          for (final s in sections) {
            final items = (s['tag_items'] as List?) ?? const [];
            for (final it in items) {
              final title = (it['title'] as String?) ?? '';
              final jt = (it['jump_type'] as String?) ?? 'tag';
              final jv = (it['jump_value'] as String?) ?? '';
              if (title.isNotEmpty && !tags.any((e) => e['title'] == title)) {
                tags.add({'title': title, 'jumpType': jt, 'jumpValue': jv});
              }
            }
            if (tags.isNotEmpty) break;
          }
          if (tags.isNotEmpty) break;
        }
        if (tags.isNotEmpty) break;
      }
      final channels = <Map<String, String>>[];
      for (final c in (t['channels'] as List?) ?? const []) {
        channels.add({
          'code': (c['code'] as String?) ?? '',
          'label': (c['label'] as String?) ?? '',
        });
      }
      if (!mounted) return;
      setState(() {
        _tags = tags;
        _channels = channels;
      });
    } catch (_) {
      // 分类加载失败不影响搜索
    }
  }

  Future<void> _search(int page, bool append) async {
    if (append && (_loading || !_hasMore)) return;
    var query = _controller.text.trim();
    if (query.isEmpty && _tag == null && _channel == null) return;
    var preset = '';
    var primaryTag = '';
    var channelCode = '';
    var workType = '';
    if (_tag != null) {
      final chip = _tags.firstWhere((e) => e['jumpValue'] == _tag,
          orElse: () => {'title': '', 'jumpType': 'tag', 'jumpValue': _tag!});
      if (chip['jumpType'] == 'keyword') {
        // "最近更新"等关键词预设:替换查询词
        query = _tag!;
        preset = _tag!;
      } else {
        primaryTag = _tag!;
      }
    }
    if (_channel != null) {
      channelCode = _channel!;
      workType = _channel!;
      primaryTag = '';
      preset = '';
    }
    setState(() => _loading = true);
    try {
      final items = await LKApi.search(
        query,
        page,
        sort: _sort,
        primaryTag: primaryTag,
        preset: preset,
        channelCode: channelCode,
        workType: workType,
      );
      if (!mounted) return;
      setState(() {
        if (append) {
          _items.addAll(items);
        } else {
          _items
            ..clear()
            ..addAll(items);
        }
        _page = page;
        _hasMore = items.length >= 20;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    await _loadTaxonomy();
    await _search(0, false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              floating: true,
              pinned: false,
              snap: false,
              titleSpacing: 0,
              title: Container(
                height: 38,
                margin: const EdgeInsets.only(right: 8),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(0, false),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '搜索书名 / 作者 / 标签',
                    isDense: true,
                    fillColor: isDark ? const Color(0xFF2A2C33) : Colors.white,
                    prefixIcon: const Icon(Icons.search_rounded, size: 19),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => _search(0, false),
                  child: const Text('搜索'),
                ),
              ],
            ),
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 排序
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        _segBtn('相关', 'relevance'),
                        const SizedBox(width: 8),
                        _segBtn('最新', 'new'),
                      ],
                    ),
                  ),
                  // 分类
                  SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      children: [
                        _chip('全部', _channel == null, () {
                          setState(() => _channel = null);
                          _search(0, false);
                        }),
                        for (final c in _channels)
                          _chip(c['label']!, _channel == c['code'], () {
                            setState(() {
                              _channel = c['code'];
                              _tag = null;
                            });
                            _search(0, false);
                          }),
                      ],
                    ),
                  ),
                  // 标签(含最近更新)
                  if (_tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _chip('全部标签', _tag == null, () {
                            setState(() => _tag = null);
                            _search(0, false);
                          }, trailingPadding: false),
                          for (final t in _tags)
                            _chip(
                              t['title']!,
                              _tag == t['jumpValue'],
                              () {
                                setState(() {
                                  _tag = t['jumpValue'];
                                  _channel = null;
                                });
                                _search(0, false);
                              },
                              trailingPadding: false,
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            ..._resultSlivers(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _resultSlivers(BuildContext context) {
    if (_error != null && _items.isEmpty) {
      return [_messageSliver(_error!)];
    }
    if (_items.isEmpty && _loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: LkLoadingIndicator()),
        ),
      ];
    }
    if (_items.isEmpty) {
      return [
        _messageSliver(
          _controller.text.isEmpty && _tag == null && _channel == null
              ? '输入关键词,或选择标签 / 分类 / 更新时间'
              : '没有找到相关作品',
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
            12, 4, 12, 12 + MediaQuery.of(context).padding.bottom),
        sliver: SliverGrid(
          gridDelegate: bookGridDelegate(),
          delegate: SliverChildBuilderDelegate(
            (_, i) {
              if (i >= _items.length) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _search(_page + 1, true);
                });
                return const LkLoadingIndicator();
              }
              final b = _items[i];
              return BookGridCard(
                book: b,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => BookDetailPage(bookId: b.bookId)),
                ),
              );
            },
            childCount: _items.length + (_hasMore ? 1 : 0),
          ),
        ),
      ),
    ];
  }

  Widget _messageSliver(String message) => SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
        ),
      );

  Widget _segBtn(String label, String value) {
    final sel = _sort == value;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () {
        setState(() => _sort = value);
        _search(0, false);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
            color: sel ? Colors.white : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap,
      {bool trailingPadding = true}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(right: trailingPadding ? 8 : 0),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary
                : (isDark ? const Color(0xFF1E2025) : Colors.white),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : (isDark ? Colors.grey.shade800 : Colors.grey.shade300),
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: selected ? Colors.white : Colors.grey.shade600,
            ),
          ),
        ),
      ),
    );
  }
}

/// 服务器书架
class ShelfPage extends StatefulWidget {
  final bool embedded;
  final bool? listMode;

  const ShelfPage({super.key, this.embedded = false, this.listMode});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

enum _ShelfSort { serverOrder, recentlyUpdated, title }

enum _ShelfFilter { all, unread, serializing, completed }

class _ShelfPageState extends State<ShelfPage> {
  List<LKBook> _items = [];
  String? _error;
  bool _errorFromAppend = false;
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _listMode = false;
  bool _localMode = false;
  bool _reloadAfterCurrent = false;
  int _statusVerificationGeneration = 0;
  _ShelfSort _sort = _ShelfSort.serverOrder;
  _ShelfFilter _filter = _ShelfFilter.all;
  int _loadSerial = 0;
  final ValueNotifier<double> _topBarFrac = ValueNotifier<double>(1.0);
  static const double _topBarFlex = 56.0;

  @override
  void initState() {
    super.initState();
    _localMode = !LKClient.shared.session.isLoggedIn;
    LKClient.sessionRev.addListener(_onSessionRev);
    LKStore.localShelfRev.addListener(_onLocalShelfRev);
    _loadListMode();
    unawaited(_startLoad());
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onSessionRev);
    LKStore.localShelfRev.removeListener(_onLocalShelfRev);
    _topBarFrac.dispose();
    super.dispose();
  }

  void _onSessionRev() {
    if (!mounted) return;
    _loadSerial++;
    _statusVerificationGeneration++;
    setState(() {
      _localMode = !LKClient.shared.session.isLoggedIn;
      _items = [];
      _page = 0;
      _hasMore = true;
      _error = null;
      _loading = false;
    });
    unawaited(_startLoad());
  }

  void _onLocalShelfRev() {
    if (!mounted) return;
    if (!_localMode && LKClient.shared.session.isLoggedIn) {
      if (_loading) {
        _reloadAfterCurrent = true;
      } else {
        unawaited(_load());
      }
      return;
    }
    // 本地书架不需要重新走完整加载流程;即使首次加载尚未结束,也直接同步最新数据。
    LKStore.localShelf().then((items) {
      if (!mounted || !_localMode) return;
      setState(() {
        _items = items;
        _page = 1;
        _hasMore = false;
        _error = null;
      });
    });
  }

  bool _onShelfScroll(ScrollNotification notification) {
    if (!widget.embedded || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final delta = notification.scrollDelta ?? 0;
      if (delta.abs() < 0.5) return false;
      final current = _topBarFrac.value;
      final next = (current - delta / _topBarFlex).clamp(0.0, 1.0);
      final diff = next - current;
      if (diff == 0 || !mounted) return false;
      _topBarFrac.value = next;
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

  Future<void> _loadListMode() async {
    if (widget.listMode != null) {
      if (mounted) setState(() => _listMode = widget.listMode!);
      return;
    }
    final value = await ReaderPrefs.feedListMode();
    if (mounted) setState(() => _listMode = value);
  }

  String _shelfCacheKey(int uid) => LKStore.pageCacheKey(
        kind: 'shelf',
        uid: uid,
        variant: 'cloud',
      );

  Future<void> _startLoad() async {
    final request = _loadSerial;
    if (_localMode || !LKClient.shared.session.isLoggedIn) {
      await _load();
      return;
    }
    final uid = LKClient.shared.session.uid;
    final cacheKey = _shelfCacheKey(uid);
    final cached = await LKStore.cachedBooksPage(cacheKey);
    if (!mounted ||
        request != _loadSerial ||
        _localMode ||
        LKClient.shared.session.uid != uid ||
        cacheKey != _shelfCacheKey(LKClient.shared.session.uid)) {
      return;
    }
    if (cached != null) {
      setState(() {
        _items = [...cached];
        _page = cached.isEmpty ? 0 : 1;
        _hasMore = true;
        _error = null;
      });
    }
    await _load(silent: _items.isNotEmpty);
  }

  @override
  void didUpdateWidget(ShelfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.listMode != null && widget.listMode != oldWidget.listMode) {
      setState(() => _listMode = widget.listMode!);
    }
  }

  Future<void> _load(
      {int page = 1,
      bool append = false,
      bool silent = false,
      bool forceRefresh = false}) async {
    if (append && (_loading || !_hasMore)) return;
    if (!append) _statusVerificationGeneration++;
    final requestSerial = ++_loadSerial;
    final localMode = _localMode || !LKClient.shared.session.isLoggedIn;
    final uid = LKClient.shared.session.uid;
    final cacheKey = _shelfCacheKey(uid);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (localMode) {
        final items = await LKStore.localShelf();
        if (!mounted || requestSerial != _loadSerial || !_localMode) return;
        setState(() {
          _items = items;
          _page = 1;
          _hasMore = false;
          _error = null;
        });
        return;
      }
      Future<LoadedPage<LKBook>> fetchPage(int number, String cursor) async {
        final items = await LKApi.bookshelf(number);
        return LoadedPage(
            items: items, page: number, hasMore: items.length >= 50);
      }

      final result = append
          ? await fetchPage(page, '')
          : await refreshPageWindow(
              loadPage: fetchPage,
              keyOf: (book) => book.bookId,
              targetItems: _items.length.clamp(0, 100),
              maxPages: 2,
              isCurrent: () => mounted && requestSerial == _loadSerial,
            );
      if (!mounted ||
          requestSerial != _loadSerial ||
          _localMode ||
          uid != LKClient.shared.session.uid) {
        return;
      }
      setState(() {
        _items = append
            ? mergePagedItems(_items, result.items,
                keyOf: (book) => book.bookId)
            : [...result.items];
        _page = result.page;
        _hasMore = result.hasMore;
        _error = null;
      });
      unawaited(LKStore.cacheBooksPage(cacheKey, _items));
      unawaited(
          _verifyServerBookStatuses(result.items, forceRefresh: forceRefresh));
    } catch (e) {
      if (mounted && requestSerial == _loadSerial) {
        setState(() {
          _error = e.toString();
          _errorFromAppend = append;
        });
        if ((silent || !append) && _items.isNotEmpty) {
          _showRefreshError();
        }
      }
    } finally {
      if (mounted && requestSerial == _loadSerial) {
        setState(() => _loading = false);
        if (_reloadAfterCurrent) {
          _reloadAfterCurrent = false;
          unawaited(_load());
        }
      }
    }
  }

  void _showRefreshError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _items.isEmpty) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('连接失败，已保留上次内容'),
          duration: Duration(seconds: 2),
        ),
      );
    });
  }

  Future<void> _verifyServerBookStatuses(List<LKBook> books,
      {bool forceRefresh = false}) async {
    final ownerUid = LKClient.shared.session.uid;
    final generation = _statusVerificationGeneration;
    if (ownerUid <= 0 || _localMode) return;
    final candidates = books
        .where((book) =>
            book.bookId > 0 &&
            book.isCompleted &&
            book.serialStatus.trim().isEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) return;

    // bookshelf-v1 only exposes is_completed and can disagree with the
    // authoritative detail response. Verify likely false positives in small
    // background batches so the shelf remains responsive.
    const batchSize = 3;
    for (var offset = 0; offset < candidates.length; offset += batchSize) {
      final end = (offset + batchSize).clamp(0, candidates.length);
      final batch = candidates.sublist(offset, end);
      final entries = await Future.wait<MapEntry<int, LKBook>?>(
        batch.map((book) async {
          try {
            return MapEntry(
                book.bookId,
                await LKApi.bookDetail(book.bookId,
                    forceRefresh: forceRefresh));
          } catch (_) {
            return null;
          }
        }),
      );
      if (!mounted ||
          _localMode ||
          LKClient.shared.session.uid != ownerUid ||
          generation != _statusVerificationGeneration) {
        return;
      }
      final verified = <int, LKBook>{
        for (final entry in entries)
          if (entry != null) entry.key: entry.value,
      };
      if (verified.isEmpty) continue;
      setState(() {
        _items = _items.map((book) {
          final detail = verified[book.bookId];
          if (detail == null) return book;
          return LKBook.fromJson({
            ...book.toJson(),
            'serial_status': detail.serialStatus,
            'is_completed': detail.isCompleted ? 1 : 0,
          });
        }).toList();
      });
      unawaited(LKStore.cacheBooksPage(_shelfCacheKey(ownerUid), _items));
    }
  }

  List<LKBook> get _visibleItems {
    final filtered = _items.where((book) {
      return switch (_filter) {
        _ShelfFilter.all => true,
        _ShelfFilter.unread => book.unreadChapterCount > 0,
        _ShelfFilter.serializing => bookStatusLabel(book) == '连载',
        _ShelfFilter.completed => bookStatusLabel(book) == '完结',
      };
    }).toList(growable: true);
    switch (_sort) {
      case _ShelfSort.serverOrder:
        break;
      case _ShelfSort.recentlyUpdated:
        filtered.sort((a, b) {
          final byTime = b.updatedAt.compareTo(a.updatedAt);
          return byTime != 0 ? byTime : a.title.compareTo(b.title);
        });
        break;
      case _ShelfSort.title:
        filtered.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
    }
    return filtered;
  }

  void _toggleShelfSource() {
    if (!LKClient.shared.session.isLoggedIn) {
      if (!_localMode) setState(() => _localMode = true);
      return;
    }
    if (_loading) return;
    _loadSerial++;
    setState(() {
      _localMode = !_localMode;
      _items = [];
      _page = 0;
      _hasMore = true;
      _error = null;
      _statusVerificationGeneration++;
    });
    unawaited(_startLoad());
  }

  Widget _shelfSourceButton() {
    return TextButton.icon(
      onPressed: _loading ? null : _toggleShelfSource,
      icon: Icon(
        _localMode ? Icons.smartphone_rounded : Icons.cloud_outlined,
        size: 18,
      ),
      label: Text(_localMode ? '本机书架' : '云端书架'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }

  Widget _shelfFilterButton() {
    final active =
        _filter != _ShelfFilter.all || _sort != _ShelfSort.serverOrder;
    return PopupMenuButton<String>(
      tooltip: '筛选与排序',
      icon: Badge(
        isLabelVisible: active,
        smallSize: 7,
        child: const Icon(Icons.tune_rounded),
      ),
      onSelected: (value) {
        setState(() {
          switch (value) {
            case 'filter:all':
              _filter = _ShelfFilter.all;
              break;
            case 'filter:unread':
              _filter = _ShelfFilter.unread;
              break;
            case 'filter:serializing':
              _filter = _ShelfFilter.serializing;
              break;
            case 'filter:completed':
              _filter = _ShelfFilter.completed;
              break;
            case 'sort:server':
              _sort = _ShelfSort.serverOrder;
              break;
            case 'sort:updated':
              _sort = _ShelfSort.recentlyUpdated;
              break;
            case 'sort:title':
              _sort = _ShelfSort.title;
              break;
          }
        });
      },
      itemBuilder: (_) => [
        const PopupMenuItem(enabled: false, child: Text('筛选')),
        CheckedPopupMenuItem(
          value: 'filter:all',
          checked: _filter == _ShelfFilter.all,
          child: const Text('全部作品'),
        ),
        CheckedPopupMenuItem(
          value: 'filter:unread',
          checked: _filter == _ShelfFilter.unread,
          child: const Text('有更新'),
        ),
        CheckedPopupMenuItem(
          value: 'filter:serializing',
          checked: _filter == _ShelfFilter.serializing,
          child: const Text('连载中'),
        ),
        CheckedPopupMenuItem(
          value: 'filter:completed',
          checked: _filter == _ShelfFilter.completed,
          child: const Text('已完结'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(enabled: false, child: Text('排序')),
        CheckedPopupMenuItem(
          value: 'sort:server',
          checked: _sort == _ShelfSort.serverOrder,
          child: const Text('默认顺序'),
        ),
        CheckedPopupMenuItem(
          value: 'sort:updated',
          checked: _sort == _ShelfSort.recentlyUpdated,
          child: const Text('最近更新'),
        ),
        CheckedPopupMenuItem(
          value: 'sort:title',
          checked: _sort == _ShelfSort.title,
          child: const Text('按书名'),
        ),
      ],
    );
  }

  Widget _shelfLoadMoreFooter() {
    if (_error != null) {
      return Center(
        child: TextButton.icon(
          onPressed: () => _errorFromAppend
              ? _load(page: _page + 1, append: true)
              : _load(forceRefresh: true),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('加载失败，点击重试'),
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_loading && _hasMore && _error == null) {
        unawaited(_load(page: _page + 1, append: true));
      }
    });
    return const LkLoadingIndicator();
  }

  @override
  Widget build(BuildContext context) {
    final visibleItems = _visibleItems;
    final body = _error != null && _items.isEmpty
        ? Center(
            child: Text(_error!, style: const TextStyle(color: Colors.grey)))
        : RefreshIndicator(
            onRefresh: () => _load(forceRefresh: true),
            child: _loading && _items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      SizedBox(
                        height: MediaQuery.sizeOf(context).height * 0.65,
                        child: const Center(child: LkLoadingIndicator()),
                      ),
                    ],
                  )
                : visibleItems.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: MediaQuery.sizeOf(context).height * 0.55,
                            child: Center(
                              child: Text(
                                _items.isEmpty ? '书架还是空的' : '没有符合当前筛选的作品',
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ),
                          ),
                          if (_hasMore) _shelfLoadMoreFooter(),
                        ],
                      )
                    : _listMode
                        ? ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.fromLTRB(8, 4, 8,
                                12 + MediaQuery.of(context).padding.bottom),
                            itemCount: visibleItems.length + (_hasMore ? 1 : 0),
                            itemBuilder: (_, i) {
                              if (i >= visibleItems.length) {
                                return _shelfLoadMoreFooter();
                              }
                              final b = visibleItems[i];
                              return BookCard(
                                book: b,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          BookDetailPage(bookId: b.bookId)),
                                ),
                              );
                            },
                          )
                        : GridView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.fromLTRB(12, 8, 12,
                                12 + MediaQuery.of(context).padding.bottom),
                            gridDelegate: bookGridDelegate(),
                            itemCount: visibleItems.length + (_hasMore ? 1 : 0),
                            itemBuilder: (_, i) {
                              if (i >= visibleItems.length) {
                                return _shelfLoadMoreFooter();
                              }
                              final b = visibleItems[i];
                              return BookGridCard(
                                book: b,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          BookDetailPage(bookId: b.bookId)),
                                ),
                              );
                            },
                          ),
          );
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(
          title: Text(_localMode ? '本机书架' : '我的书架'),
          actions: [
            _shelfSourceButton(),
            _shelfFilterButton(),
            IconButton(
              tooltip: _listMode ? '切换为网格排版' : '切换为单列排版',
              icon: Icon(_listMode
                  ? Icons.grid_view_rounded
                  : Icons.view_agenda_outlined),
              onPressed: () {
                final value = !_listMode;
                setState(() => _listMode = value);
                ReaderPrefs.setFeedListMode(value);
              },
            ),
          ],
        ),
        body: body,
      );
    }
    final embeddedBody = NotificationListener<ScrollNotification>(
      onNotification: _onShelfScroll,
      child: body,
    );
    return Column(
      children: [
        ValueListenableBuilder<double>(
          valueListenable: _topBarFrac,
          builder: (context, topBarFrac, _) => ClipRect(
            child: SizedBox(
              height: _topBarFlex * topBarFrac,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    top: -_topBarFlex * (1 - topBarFrac),
                    left: 0,
                    right: 0,
                    height: _topBarFlex,
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: Padding(
                        // 与动态顶栏的外层间距一致；标题自身再保留 8px
                        // 内边距，避免书架文字比“动态”向左错位。
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                        child: Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              child: Text(
                                _localMode ? '本机书架' : '书架',
                                style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSurface,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const Spacer(),
                            _shelfSourceButton(),
                            _shelfFilterButton(),
                            IconButton(
                              tooltip: _listMode ? '切换为网格排版' : '切换为单列排版',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(_listMode
                                  ? Icons.grid_view_rounded
                                  : Icons.view_agenda_outlined),
                              onPressed: () {
                                final value = !_listMode;
                                setState(() => _listMode = value);
                                ReaderPrefs.setFeedListMode(value);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: embeddedBody),
      ],
    );
  }
}

/// 书评 / 本卷评论
class CommentsPage extends StatefulWidget {
  final int bookId;
  final String bookTitle;

  /// 0 = 整书评论;>0 = 本卷评论
  final int volumeId;
  final int dynamicId;
  final LKDynamicItem? dynamicPreview;
  const CommentsPage(
      {super.key,
      this.bookId = 0,
      this.bookTitle = '',
      this.volumeId = 0,
      this.dynamicId = 0,
      this.dynamicPreview});

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  static const int _pageSize = 20;
  List<LKComment> _comments = [];
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;
  String? _loadMoreError;
  int _page = 0;
  String _cursor = '';
  bool _hasMore = true;
  int _loadSerial = 0;
  final _input = TextEditingController();

  /// 表情包(code → 图片地址),评论渲染与表情面板共用
  final Map<String, String> _emojiUrl = {};
  List<LKEmojiGroup> _emojiGroups = [];
  final _picker = ImagePicker();
  final List<LKDynamicMedia> _pendingMedia = [];
  LKDynamicItem? _dynamicDetail;
  bool _uploadingImage = false;
  final Set<String> _selectedPollOptions = <String>{};
  bool _pollSubmitting = false;
  final Map<int, List<LKComment>> _repliesByComment = {};
  final Set<int> _expandedReplies = <int>{};
  final Set<int> _loadingReplies = <int>{};
  final Map<int, String> _replyErrors = <int, String>{};
  final Map<int, int> _replyPages = <int, int>{};
  final Map<int, String> _replyCursors = <int, String>{};
  final Map<int, bool> _replyHasMore = <int, bool>{};
  LKComment? _replyTarget;
  int _replyParentCommentId = 0;

  bool get _isVolume => widget.volumeId > 0;
  bool get _isDynamic => widget.dynamicId > 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadEmojis();
    if (_isDynamic) _loadDynamicDetail();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _loadEmojis() async {
    try {
      final groups = await YomiruEmojiCatalog.load();
      if (!mounted) return;
      setState(() {
        _emojiGroups = groups;
        _emojiUrl
          ..clear()
          ..addAll(YomiruEmojiCatalog.urls);
      });
    } catch (_) {}
  }

  Future<LKCommentPage> _requestCommentPage({
    required int page,
    required String cursor,
    int commentId = 0,
  }) {
    if (_isDynamic) {
      return LKApi.dynamicCommentPage(
        widget.dynamicId,
        commentId: commentId,
        cursor: cursor,
        page: page,
        pageSize: _pageSize,
      );
    }
    if (_isVolume) {
      return LKApi.volumeCommentPage(
        widget.bookId,
        widget.volumeId,
        page,
        pageSize: _pageSize,
        commentId: commentId,
      );
    }
    return LKApi.bookCommentPage(
      widget.bookId,
      page,
      pageSize: _pageSize,
      commentId: commentId,
    );
  }

  static List<LKComment> _mergeComments(
      Iterable<LKComment> first, Iterable<LKComment> second) {
    final seen = <int>{};
    return [...first, ...second]
        .where(
            (comment) => comment.commentId <= 0 || seen.add(comment.commentId))
        .toList(growable: false);
  }

  void _seedReplyPreviews(Iterable<LKComment> comments) {
    for (final comment in comments) {
      if (comment.commentId <= 0 ||
          comment.replies.isEmpty ||
          _repliesByComment.containsKey(comment.commentId)) {
        continue;
      }
      _repliesByComment[comment.commentId] = comment.replies;
      _replyPages[comment.commentId] = 0;
      _replyCursors[comment.commentId] = '';
      _replyHasMore[comment.commentId] =
          comment.replyCount > comment.replies.length;
      _expandedReplies.add(comment.commentId);
    }
  }

  Future<void> _load({bool reset = true}) async {
    if (!reset && (_loading || _loadingMore || !_hasMore)) return;
    final requestSerial = reset ? ++_loadSerial : _loadSerial;
    final targetPage = reset ? 1 : _page + 1;
    final targetCursor = reset ? '' : _cursor;
    setState(() {
      if (reset) {
        _loading = _comments.isEmpty;
        _error = null;
        _loadMoreError = null;
      } else {
        _loadingMore = true;
        _loadMoreError = null;
      }
    });
    try {
      final result =
          await _requestCommentPage(page: targetPage, cursor: targetCursor);
      if (!mounted || requestSerial != _loadSerial) return;
      setState(() {
        if (reset) {
          _comments = result.items;
          _repliesByComment.clear();
          _expandedReplies.clear();
          _replyErrors.clear();
          _replyPages.clear();
          _replyCursors.clear();
          _replyHasMore.clear();
          _seedReplyPreviews(result.items);
        } else {
          final before = _comments.length;
          _comments = _mergeComments(_comments, result.items);
          _seedReplyPreviews(result.items);
          if (_comments.length == before && result.items.isNotEmpty) {
            _hasMore = false;
          }
        }
        _page = result.page;
        _cursor = result.nextCursor;
        if (reset || _hasMore) _hasMore = result.hasMore;
        _error = null;
      });
    } catch (e) {
      if (mounted && requestSerial == _loadSerial) {
        setState(() {
          if (reset && _comments.isEmpty) {
            _error = e.toString();
          } else {
            _loadMoreError = e.toString();
          }
        });
      }
    } finally {
      if (mounted && requestSerial == _loadSerial) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _loadDynamicDetail() async {
    try {
      final detail = await LKApi.dynamicDetail(widget.dynamicId);
      if (!mounted) return;
      setState(() {
        _dynamicDetail = detail;
        _selectedPollOptions
          ..clear()
          ..addAll(detail.poll?.options
                  .where((option) => option.selected)
                  .map((option) => option.id) ??
              const []);
      });
      await LKApi.markDynamicRead(dynamicId: widget.dynamicId);
    } catch (_) {
      // 详情失败时仍保留信息流传入的预览内容。
    }
  }

  Future<void> _publish() async {
    final content = _input.text.trim();
    if (content.isEmpty) return;
    final replyTarget = _replyTarget;
    final replyIds = replyTarget == null
        ? (rootCommentId: 0, replyCommentId: 0)
        : resolveBookCommentReplyIds(
            replyTarget,
            parentCommentId: _replyParentCommentId,
          );
    final replyRootId = replyTarget == null
        ? 0
        : _isDynamic
            ? (_replyParentCommentId > 0
                ? _replyParentCommentId
                : replyTarget.rootCommentId > 0
                    ? replyTarget.rootCommentId
                    : replyTarget.commentId)
            : replyIds.rootCommentId;
    try {
      if (_isDynamic) {
        await LKApi.publishDynamicComment(widget.dynamicId, content,
            replyCommentId: replyTarget?.commentId ?? 0, media: _pendingMedia);
      } else if (_isVolume) {
        await LKApi.publishBookComment(widget.bookId, content,
            volumeId: widget.volumeId,
            rootCommentId: replyIds.rootCommentId,
            replyCommentId: replyIds.replyCommentId,
            media: _pendingMedia);
      } else {
        await LKApi.publishBookComment(widget.bookId, content,
            rootCommentId: replyIds.rootCommentId,
            replyCommentId: replyIds.replyCommentId,
            media: _pendingMedia);
      }
      _input.clear();
      _pendingMedia.clear();
      if (mounted) {
        setState(() {
          _replyTarget = null;
          _replyParentCommentId = 0;
        });
      }
      if (replyRootId > 0 && mounted) {
        LKComment? root;
        for (final comment in _comments) {
          if (comment.commentId == replyRootId) {
            root = comment;
            break;
          }
        }
        if (root != null) {
          setState(() => _expandedReplies.add(replyRootId));
          await _loadReplies(root, reset: true);
        } else {
          await _load();
        }
      } else {
        await _load();
      }
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  Future<void> _pickImage() async {
    if (_uploadingImage || _pendingMedia.length >= 9) return;
    final file = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 88, maxWidth: 2048);
    if (file == null) return;
    setState(() => _uploadingImage = true);
    try {
      final media = await LKApi.uploadCommentImage(file.path);
      if (mounted) setState(() => _pendingMedia.add(media));
    } catch (e) {
      if (mounted) showLkError(context, e);
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  Future<void> _toggleReplies(LKComment comment) async {
    if (comment.commentId <= 0 || _loadingReplies.contains(comment.commentId)) {
      return;
    }
    if (_expandedReplies.contains(comment.commentId)) {
      setState(() => _expandedReplies.remove(comment.commentId));
      return;
    }
    setState(() => _expandedReplies.add(comment.commentId));
    if (_repliesByComment.containsKey(comment.commentId) &&
        (_replyPages[comment.commentId] ?? 0) > 0) {
      return;
    }
    await _loadReplies(comment, reset: true);
  }

  Future<void> _loadReplies(LKComment comment, {bool reset = false}) async {
    final commentId = comment.commentId;
    if (commentId <= 0 || _loadingReplies.contains(commentId)) return;
    if (!reset && !(_replyHasMore[commentId] ?? false)) return;
    final page = reset ? 1 : (_replyPages[commentId] ?? 0) + 1;
    final cursor = reset ? '' : (_replyCursors[commentId] ?? '');
    setState(() {
      _loadingReplies.add(commentId);
      _replyErrors.remove(commentId);
    });
    try {
      final result = await _requestCommentPage(
          page: page, cursor: cursor, commentId: commentId);
      if (!mounted) return;
      setState(() {
        final existing = _repliesByComment[commentId] ?? const <LKComment>[];
        final merged = reset
            ? _mergeComments(result.items, existing)
            : _mergeComments(existing, result.items);
        _repliesByComment[commentId] = merged;
        _replyPages[commentId] = result.page;
        _replyCursors[commentId] = result.nextCursor;
        _replyHasMore[commentId] = result.hasMore;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _replyErrors[commentId] = e.toString());
    } finally {
      if (mounted) setState(() => _loadingReplies.remove(commentId));
    }
  }

  /// 渲染评论内容:把表情代码({:xx:} / [s:数字] 等)替换为表情图片
  Widget _renderContent(String content) =>
      LkEmojiText(text: content, emojiUrls: _emojiUrl);

  String _formatCommentTime(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final number = int.tryParse(value);
    final date = number == null
        ? DateTime.tryParse(value.replaceFirst(' ', 'T'))
        : DateTime.fromMillisecondsSinceEpoch(
            number > 20000000000 ? number : number * 1000);
    if (date == null) return value.replaceFirst('T', ' ').split('.').first;
    String two(int n) => n.toString().padLeft(2, '0');
    final local = date.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// 点赞/取消点赞(乐观更新,失败回滚)
  Future<void> _toggleLike(dynamic c) async {
    final wasLiked = c.liked as bool;
    final rootIndex = _comments.indexOf(c);
    var replyIndex = -1;
    var replyParentId = 0;
    if (rootIndex < 0) {
      for (final entry in _repliesByComment.entries) {
        final index = entry.value.indexOf(c);
        if (index >= 0) {
          replyParentId = entry.key;
          replyIndex = index;
          break;
        }
      }
    }
    if (rootIndex < 0 && replyIndex < 0) return;
    final updated = LKComment(
      commentId: c.commentId,
      rootCommentId: c.rootCommentId,
      replyToCommentId: c.replyToCommentId,
      userUid: c.userUid,
      nickname: c.nickname,
      replyToNickname: c.replyToNickname,
      avatar: c.avatar,
      content: c.content,
      time: c.time,
      likeCount: (c.likeCount as int) + (wasLiked ? -1 : 1),
      liked: !wasLiked,
      media: c.media,
      replyCount: c.replyCount,
      replies: c.replies,
    );
    setState(() {
      if (rootIndex >= 0) {
        _comments[rootIndex] = updated;
      } else {
        final replies = List<LKComment>.from(_repliesByComment[replyParentId]!);
        replies[replyIndex] = updated;
        _repliesByComment[replyParentId] = replies;
      }
    });
    try {
      if (_isDynamic) {
        await LKApi.toggleDynamicCommentLike(
            widget.dynamicId, c.commentId, !wasLiked);
      } else {
        await LKApi.likeBookComment(widget.bookId, c.commentId, !wasLiked,
            volumeId: widget.volumeId,
            rootCommentId:
                c.rootCommentId > 0 ? c.rootCommentId : replyParentId);
      }
    } catch (e) {
      // 失败回滚
      if (!mounted) return;
      setState(() {
        if (rootIndex >= 0) {
          _comments[rootIndex] = c;
        } else {
          final replies =
              List<LKComment>.from(_repliesByComment[replyParentId]!);
          replies[replyIndex] = c;
          _repliesByComment[replyParentId] = replies;
        }
      });
      showLkError(context, e);
    }
  }

  Widget _likeButton(dynamic c) {
    final liked = c.liked as bool;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('${c.likeCount}',
          style: TextStyle(
              fontSize: 11,
              color: liked ? Colors.redAccent : Colors.grey.shade500)),
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(
          liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          size: 18,
          color: liked ? Colors.redAccent : Colors.grey.shade500,
        ),
        onPressed: () => _toggleLike(c),
      ),
    ]);
  }

  /// 长按复制评论
  Future<void> _copyComment(dynamic c) async {
    // 去掉表情代码,复制纯文本
    final text = (c.content as String)
        .replaceAll(RegExp(r'\{:[^:]+:\}|\[[a-zA-Z]+:\d+\]'), '');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showLkError(context, '已复制评论');
  }

  Widget _mediaGallery(List<LKDynamicMedia> media) {
    if (media.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: media
            .map((item) => GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => MediaViewerPage(url: item.url)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedNetworkImage(
                      imageUrl: item.url,
                      width: 92,
                      height: 92,
                      memCacheWidth: imageCacheDimension(context, 92),
                      fit: BoxFit.cover,
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _dynamicHeader() {
    final item = _dynamicDetail ?? widget.dynamicPreview;
    if (item == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: LkLoadingIndicator(minHeight: 180),
      );
    }
    final poll = item.poll;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: InkWell(
        onLongPress: () => _copyDynamicUrl(item),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                CircleAvatar(
                  radius: 18,
                  backgroundImage: item.avatar.isNotEmpty
                      ? YomiruAvatarCache.provider(item.avatar)
                      : null,
                  child: item.avatar.isEmpty ? const Icon(Icons.person) : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(item.nickname.isEmpty ? '未知用户' : item.nickname,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(item.time,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ]),
              const SizedBox(height: 12),
              if (item.title.isNotEmpty && item.summary.trim().isNotEmpty) ...[
                Text(item.title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
              ],
              if (item.displayContent.trim().isNotEmpty)
                _renderContent(item.displayContent),
              _mediaGallery(item.media),
              if (poll != null) _pollCard(poll),
              const SizedBox(height: 8),
              Text('评论 ${item.commentCount} · 赞 ${item.likeCount}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyDynamicUrl(LKDynamicItem item) async {
    if (item.dynamicId <= 0) return;
    await Clipboard.setData(
        ClipboardData(text: dynamicWebsiteUrl(item.dynamicId)));
    if (mounted) showLkError(context, '已复制动态链接');
  }

  Widget _pollCard(LKDynamicPoll poll) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(poll.title.isEmpty ? '投票' : poll.title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (poll.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(poll.description,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
            ...poll.options.map((option) {
              final selected = _selectedPollOptions.contains(option.id);
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: selected,
                title: Text(option.text),
                subtitle: poll.voted || poll.ended
                    ? Text(
                        '${option.voteCount} 票${option.percent > 0 ? ' · ${option.percent.toStringAsFixed(1)}%' : ''}')
                    : null,
                onChanged: poll.voted || poll.ended
                    ? null
                    : (value) {
                        setState(() {
                          if (value == true) {
                            if (!poll.multiple) _selectedPollOptions.clear();
                            _selectedPollOptions.add(option.id);
                          } else {
                            _selectedPollOptions.remove(option.id);
                          }
                        });
                      },
              );
            }),
            if (!poll.voted && !poll.ended)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _pollSubmitting || _selectedPollOptions.isEmpty
                      ? null
                      : () async {
                          setState(() => _pollSubmitting = true);
                          try {
                            await LKApi.submitDynamicPollVote(widget.dynamicId,
                                _selectedPollOptions.toList());
                            await _loadDynamicDetail();
                          } catch (e) {
                            if (mounted) showLkError(context, e);
                          } finally {
                            if (mounted) {
                              setState(() => _pollSubmitting = false);
                            }
                          }
                        },
                  child: Text(_pollSubmitting ? '提交中' : '投票'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _replyControls(LKComment comment,
      {bool isReply = false, int parentCommentId = 0}) {
    final expanded = !isReply && _expandedReplies.contains(comment.commentId);
    final loading = !isReply && _loadingReplies.contains(comment.commentId);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: () => setState(() {
              _replyTarget = comment;
              _replyParentCommentId = isReply ? parentCommentId : 0;
            }),
            icon: const Icon(Icons.reply_rounded, size: 17),
            label: Text(
                _replyTarget?.commentId == comment.commentId ? '正在回复' : '回复'),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
          if (!isReply &&
              (comment.replyCount > 0 ||
                  (_repliesByComment[comment.commentId]?.isNotEmpty ?? false)))
            TextButton.icon(
              onPressed: loading ? null : () => _toggleReplies(comment),
              icon: Icon(expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded),
              label: Text(loading
                  ? '加载回复…'
                  : expanded
                      ? '收起回复'
                      : '查看 ${comment.replyCount} 条回复'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _replyList(LKComment parent) {
    if (!_expandedReplies.contains(parent.commentId)) {
      return const SizedBox.shrink();
    }
    final replies = _repliesByComment[parent.commentId] ?? const <LKComment>[];
    final loading = _loadingReplies.contains(parent.commentId);
    final error = _replyErrors[parent.commentId];
    if (replies.isEmpty) {
      if (loading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: LkLoadingIndicator()),
        );
      }
      if (error != null) {
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _loadReplies(parent, reset: true),
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('回复加载失败，点击重试'),
          ),
        );
      }
    }
    if (replies.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text('暂时没有可显示的回复',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          ...replies.map((reply) => _commentItem(reply,
              isReply: true, parentCommentId: parent.commentId)),
          if (error != null)
            TextButton.icon(
              onPressed: () => _loadReplies(parent),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('继续加载失败，点击重试'),
            )
          else if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(child: LkLoadingIndicator()),
            )
          else if (_replyHasMore[parent.commentId] ?? false)
            TextButton.icon(
              onPressed: () => _loadReplies(parent),
              icon: const Icon(Icons.expand_more_rounded, size: 18),
              label: const Text('加载更多回复'),
            ),
        ],
      ),
    );
  }

  bool _onCommentScroll(ScrollNotification notification) {
    if (notification.metrics.axis == Axis.vertical &&
        notification.metrics.extentAfter < 480 &&
        !_loading &&
        !_loadingMore &&
        _hasMore) {
      unawaited(_load(reset: false));
    }
    return false;
  }

  Widget _commentPageFooter() {
    if (_loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: TextButton.icon(
            onPressed: () => _load(reset: false),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('加载更多失败，点击重试'),
          ),
        ),
      );
    }
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loadingMore && _hasMore) {
          unawaited(_load(reset: false));
        }
      });
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Center(child: LkLoadingIndicator()),
    );
  }

  /// 评论采用左侧头像 + 右侧正文布局，日期统一放在昵称下方。
  Widget _commentItem(dynamic c,
      {bool isReply = false, int parentCommentId = 0}) {
    final avatar = CircleAvatar(
      radius: 24,
      backgroundImage:
          c.avatar.isNotEmpty ? YomiruAvatarCache.provider(c.avatar) : null,
      child: c.avatar.isEmpty ? const Icon(Icons.person) : null,
    );
    final author = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(c.nickname,
            style: TextStyle(fontSize: 13, color: Colors.indigo.shade400)),
        if (c.replyToNickname.isNotEmpty)
          Text('回复 @${c.replyToNickname}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        if (c.time.isNotEmpty)
          Text(
            _formatCommentTime(c.time),
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500),
          ),
      ],
    );
    return InkWell(
      onTap: c.userUid > 0 ? () => openUserProfile(context, c.userUid) : null,
      onLongPress: () => _copyComment(c),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Align(alignment: Alignment.topCenter, child: avatar),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: author),
                      _likeButton(c),
                    ],
                  ),
                  const SizedBox(height: 5),
                  _renderContent(c.content),
                  _mediaGallery(c.media),
                  _replyControls(c,
                      isReply: isReply, parentCommentId: parentCommentId),
                  if (!isReply) _replyList(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 键盘 inset 只由输入行处理:动画期间评论列表不重建,交互更流畅
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
          title: Text(_isDynamic
              ? '动态详情'
              : _isVolume
                  ? '本卷评论 · ${widget.bookTitle}'
                  : '书评 · ${widget.bookTitle}')),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const LkLoadingIndicator()
              : RefreshIndicator(
                  onRefresh: () => _load(),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onCommentScroll,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                          bottom: MediaQuery.paddingOf(context).bottom),
                      itemCount: (_isDynamic ? 1 : 0) +
                          (_comments.isEmpty ? 1 : _comments.length) +
                          (_hasMore || _loadingMore || _loadMoreError != null
                              ? 1
                              : 0),
                      itemBuilder: (_, i) {
                        if (_isDynamic && i == 0) return _dynamicHeader();
                        final contentIndex = i - (_isDynamic ? 1 : 0);
                        if (_comments.isEmpty && contentIndex == 0) {
                          return SizedBox(
                            height: 240,
                            child: Center(
                              child: Text(
                                _error ??
                                    (_isDynamic
                                        ? '还没有评论'
                                        : _isVolume
                                            ? '本卷还没有评论'
                                            : '还没有书评，来抢沙发'),
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ),
                          );
                        }
                        if (contentIndex >= _comments.length) {
                          return _commentPageFooter();
                        }
                        final c = _comments[contentIndex];
                        return _commentItem(c);
                      },
                    ),
                  ),
                ),
        ),
        _CommentsInputBar(
          controller: _input,
          emojiGroups: _emojiGroups,
          isVolume: _isVolume,
          hintText: _isDynamic ? '写下你的动态评论…' : null,
          replyLabel: _replyTarget == null
              ? null
              : '回复 @${_replyTarget!.nickname.isEmpty ? '用户' : _replyTarget!.nickname}',
          onCancelReply: _replyTarget == null
              ? null
              : () => setState(() {
                    _replyTarget = null;
                    _replyParentCommentId = 0;
                  }),
          onPickImage: _pickImage,
          pendingImageUrl:
              _pendingMedia.isEmpty ? null : _pendingMedia.last.url,
          onRemoveImage: _pendingMedia.isEmpty
              ? null
              : () => setState(() => _pendingMedia.removeLast()),
          onPublish: _publish,
        ),
      ]),
    );
  }
}

/// 底部评论输入区。独立于评论列表，避免键盘 inset 动画触发整页重建。
class _CommentsInputBar extends StatefulWidget {
  final TextEditingController controller;
  final List<LKEmojiGroup> emojiGroups;
  final bool isVolume;
  final String? hintText;
  final String? replyLabel;
  final VoidCallback? onCancelReply;
  final VoidCallback? onPickImage;
  final String? pendingImageUrl;
  final VoidCallback? onRemoveImage;
  final VoidCallback onPublish;

  const _CommentsInputBar({
    required this.controller,
    required this.emojiGroups,
    required this.isVolume,
    this.hintText,
    this.replyLabel,
    this.onCancelReply,
    this.onPickImage,
    this.pendingImageUrl,
    this.onRemoveImage,
    required this.onPublish,
  });

  @override
  State<_CommentsInputBar> createState() => _CommentsInputBarState();
}

class _CommentsInputBarState extends State<_CommentsInputBar> {
  final _focus = FocusNode();
  bool _showEmoji = false;
  bool _keyboardReturning = false;
  double _keyboardTransitionHeight = 0;
  Timer? _keyboardTransitionTimer;

  @override
  void dispose() {
    _keyboardTransitionTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  double _emojiPanelHeight() =>
      (MediaQuery.sizeOf(context).height * 0.42).clamp(300.0, 360.0).toDouble();

  void _returnToKeyboard() {
    _keyboardTransitionTimer?.cancel();
    final reserveHeight = _emojiPanelHeight();
    setState(() {
      _showEmoji = false;
      _keyboardReturning = true;
      _keyboardTransitionHeight = reserveHeight;
    });
    _focus.requestFocus();
    // 输入法出现期间继续占住表情面板高度，避免输入栏先落底再弹起。
    _keyboardTransitionTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() => _keyboardReturning = false);
    });
  }

  void _toggleEmoji() {
    if (widget.emojiGroups.isEmpty) {
      showLkError(context, '表情加载中,请稍后再试');
      return;
    }
    if (_showEmoji) {
      _returnToKeyboard();
    } else {
      _keyboardTransitionTimer?.cancel();
      _focus.unfocus();
      setState(() {
        _showEmoji = true;
        _keyboardReturning = false;
      });
    }
  }

  void _pickEmoji(String code) {
    final sel = widget.controller.selection;
    final text = widget.controller.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    widget.controller.text = text.replaceRange(start, end, code);
    widget.controller.selection =
        TextSelection.collapsed(offset: start + code.length);
  }

  @override
  Widget build(BuildContext context) {
    // 系统已经在动画中逐帧更新 viewInsets，不再叠加 AnimatedPadding。
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final panelH = _showEmoji ? _emojiPanelHeight() : 0.0;
    final double bottomPad;
    if (_showEmoji) {
      bottomPad = panelH;
    } else if (_keyboardReturning) {
      bottomPad =
          inset > _keyboardTransitionHeight ? inset : _keyboardTransitionHeight;
    } else {
      bottomPad = inset;
    }

    return Stack(children: [
      if (_showEmoji)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: panelH,
          child: Material(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF1E2025)
                : Colors.white,
            child: SafeArea(
              top: false,
              child: _EmojiPanel(
                groups: widget.emojiGroups,
                onPick: _pickEmoji,
              ),
            ),
          ),
        ),
      Padding(
        padding: EdgeInsets.only(bottom: bottomPad),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              if (widget.replyLabel != null && widget.replyLabel!.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6, left: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.replyLabel!,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '取消回复',
                          icon: const Icon(Icons.close, size: 17),
                          onPressed: widget.onCancelReply,
                        ),
                      ],
                    ),
                  ),
                ),
              if (widget.pendingImageUrl != null &&
                  widget.pendingImageUrl!.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            imageUrl: widget.pendingImageUrl!,
                            width: 56,
                            height: 56,
                            memCacheWidth: imageCacheDimension(context, 56),
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          right: -8,
                          top: -8,
                          child: IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.cancel, size: 18),
                            onPressed: widget.onRemoveImage,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Row(children: [
                IconButton(
                  tooltip: _showEmoji ? '键盘' : '表情',
                  icon: Icon(_showEmoji
                      ? Icons.keyboard_alt_outlined
                      : Icons.emoji_emotions_outlined),
                  onPressed: _toggleEmoji,
                ),
                if (widget.onPickImage != null)
                  IconButton(
                    tooltip: '添加图片',
                    icon: const Icon(Icons.image_outlined),
                    onPressed: widget.onPickImage,
                  ),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focus,
                    onTap: () {
                      if (_showEmoji) {
                        _returnToKeyboard();
                      }
                    },
                    decoration: InputDecoration(
                        hintText: widget.hintText ??
                            (widget.isVolume ? '写下本卷评论…' : '写下你的书评…'),
                        isDense: true,
                        border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: widget.onPublish, child: const Text('发布')),
              ]),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// 评论表情选择面板(分组页签 + 网格)
class _EmojiPanel extends StatefulWidget {
  final List<LKEmojiGroup> groups;
  final void Function(String code) onPick;
  const _EmojiPanel({required this.groups, required this.onPick});

  @override
  State<_EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<_EmojiPanel> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final g = widget.groups[_tab];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(children: [
      SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: widget.groups.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final sel = i == _tab;
            return GestureDetector(
              onTap: () => setState(() => _tab = i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: sel
                      ? Theme.of(context).colorScheme.primary
                      : (isDark
                          ? const Color(0xFF2A2C33)
                          : Colors.grey.shade100),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  widget.groups[i].name,
                  style: TextStyle(
                    fontSize: 13,
                    color: sel ? Colors.white : Colors.grey.shade700,
                  ),
                ),
              ),
            );
          },
        ),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 8,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: g.items.length,
          itemBuilder: (_, i) {
            final it = g.items[i];
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => widget.onPick(it.code),
              child: it.isImage
                  ? CachedNetworkImage(
                      imageUrl: it.url.replaceFirst(
                          'api.lightnovel.fun/static/',
                          'static.lightnovel.fun/'),
                      width: 32,
                      height: 32,
                      memCacheWidth: imageCacheDimension(context, 32),
                      fit: BoxFit.contain,
                      errorWidget: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          size: 20,
                          color: Colors.grey),
                    )
                  : Center(
                      child:
                          Text(it.code, style: const TextStyle(fontSize: 22))),
            );
          },
        ),
      ),
    ]);
  }
}
