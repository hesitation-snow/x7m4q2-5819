import '../services/app_motion.dart';
import '../services/background_work_queue.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/pagination.dart';
import '../api/store.dart';
import '../widgets/common.dart';
import 'book_detail_page.dart';

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
  static final _statusQueue = BackgroundWorkQueue(concurrency: 3);
  final _verifiedStatuses = <int, LKBook>{};
  _ShelfSort _sort = _ShelfSort.serverOrder;
  _ShelfFilter _filter = _ShelfFilter.all;
  int _loadSerial = 0;
  final ValueNotifier<double> _topBarFrac = ValueNotifier<double>(1.0);
  static const double _topBarFlex = 56.0;

  int _lastGridColumnCount = LKStore.gridColumnCount.value;
  int _anchorBookIndex = 0;
  double _anchorFraction = 0.0;
  final ScrollController _gridScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _localMode = !LKClient.shared.session.isLoggedIn;
    LKClient.sessionRev.addListener(_onSessionRev);
    LKStore.localShelfRev.addListener(_onLocalShelfRev);
    LKStore.hideBraveBooks.addListener(_onHideBraveRev);
    LKStore.gridColumnCount.addListener(_onGridColumnsChanged);
    _loadListMode();
    unawaited(_startLoad());
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onSessionRev);
    LKStore.localShelfRev.removeListener(_onLocalShelfRev);
    LKStore.hideBraveBooks.removeListener(_onHideBraveRev);
    LKStore.gridColumnCount.removeListener(_onGridColumnsChanged);
    _gridScrollController.dispose();
    _topBarFrac.dispose();
    super.dispose();
  }

  void _onHideBraveRev() {
    if (mounted) setState(() {});
  }

  void _updateGridAnchor() {
    final visibleItems = _visibleItems;
    if (!_gridScrollController.hasClients || visibleItems.isEmpty) return;
    final offset = _gridScrollController.offset;
    const topPad = 8.0;
    if (offset <= topPad) {
      _anchorBookIndex = 0;
      _anchorFraction = 0.0;
      return;
    }
    final gridOffset = offset - topPad;
    final width = MediaQuery.sizeOf(context).width - 24;
    final metrics = BookGridDelegate.computeMetrics(
      usableWidth: width,
      columnCount: _lastGridColumnCount,
    );
    if (metrics.rowStride > 0 && metrics.count > 0) {
      final row = (gridOffset / metrics.rowStride).floor();
      _anchorBookIndex =
          (row * metrics.count).clamp(0, visibleItems.length - 1);
      _anchorFraction = ((gridOffset % metrics.rowStride) / metrics.rowStride)
          .clamp(0.0, 1.0);
    }
  }

  void _onGridColumnsChanged() {
    final newCount = LKStore.gridColumnCount.value;
    if (newCount == _lastGridColumnCount) return;
    if (!mounted) return;

    final visibleItems = _visibleItems;
    _updateGridAnchor();
    _lastGridColumnCount = newCount;
    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_gridScrollController.hasClients ||
          visibleItems.isEmpty) {
        return;
      }
      const topPad = 8.0;
      final width = MediaQuery.sizeOf(context).width - 24;
      final newMetrics = BookGridDelegate.computeMetrics(
        usableWidth: width,
        columnCount: newCount,
      );
      if (newMetrics.rowStride > 0 && newMetrics.count > 0) {
        final newRow = _anchorBookIndex ~/ newMetrics.count;
        final newGridOffset = newRow * newMetrics.rowStride +
            _anchorFraction * newMetrics.rowStride;
        final targetOffset = (topPad + newGridOffset)
            .clamp(0.0, _gridScrollController.position.maxScrollExtent);
        _gridScrollController.jumpTo(targetOffset);
      }
    });
  }

  void _onSessionRev() {
    if (!mounted) return;
    _loadSerial++;
    _statusVerificationGeneration++;
    _verifiedStatuses.clear();
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
    if (notification is ScrollUpdateNotification) {
      if (!_listMode) _updateGridAnchor();
      if (notification.dragDetails != null) {
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
      }
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
    if (forceRefresh) _verifiedStatuses.clear();
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
      showFloatingPrompt(context, '连接失败，请检查网络连接');
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
    bool current() =>
        mounted &&
        !_localMode &&
        LKClient.shared.session.uid == ownerUid &&
        generation == _statusVerificationGeneration;
    var changed = false;
    const batchSize = 3;
    for (var offset = 0; offset < candidates.length; offset += batchSize) {
      if (!current()) return;
      final end = (offset + batchSize).clamp(0, candidates.length);
      final batch = candidates.sublist(offset, end);
      final entries = await Future.wait<MapEntry<int, LKBook>?>(
        batch.map((book) async {
          try {
            final cached = _verifiedStatuses[book.bookId];
            if (cached != null) return MapEntry(book.bookId, cached);
            final detail = await _statusQueue.run<LKBook>(
              () => LKApi.bookDetail(book.bookId, forceRefresh: forceRefresh),
              isCurrent: current,
            );
            if (detail == null || !current()) return null;
            if (_verifiedStatuses.length >= 256) {
              _verifiedStatuses.remove(_verifiedStatuses.keys.first);
            }
            _verifiedStatuses[book.bookId] = detail;
            return MapEntry(book.bookId, detail);
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
      changed = true;
    }
    if (changed && current()) {
      await LKStore.cacheBooksPage(_shelfCacheKey(ownerUid), _items);
    }
  }

  List<LKBook> get _visibleItems {
    final hideBrave = LKStore.hideBraveBooks.value;
    final filtered = _items.where((book) {
      if (hideBrave && book.isBrave) return false;
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
        : MotionRefreshIndicator(
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
                            scrollCacheExtent:
                                const ScrollCacheExtent.viewport(1.0),
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
                            controller: _gridScrollController,
                            scrollCacheExtent:
                                const ScrollCacheExtent.viewport(1.0),
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
          title: Text(_localMode ? '本机书架' : '云端书架'),
          actions: [
            _shelfSourceButton(),
            _shelfFilterButton(),
            GestureDetector(
              onLongPress: () => showGridColumnsSheet(context),
              child: IconButton(
                tooltip: _listMode
                    ? '切换为网格（长按设置列数）'
                    : '切换为列表（长按设置列数）',
                icon: Icon(_listMode
                    ? Icons.grid_view_rounded
                    : Icons.view_agenda_outlined),
                onPressed: () {
                  final value = !_listMode;
                  setState(() => _listMode = value);
                  ReaderPrefs.setFeedListMode(value);
                },
              ),
            ),
          ],
        ),
        body: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollUpdateNotification && !_listMode) {
              _updateGridAnchor();
            }
            return false;
          },
          child: body,
        ),
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
                                _localMode ? '本机书架' : '云端书架',
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
                            GestureDetector(
                              onLongPress: () => showGridColumnsSheet(context),
                              child: IconButton(
                                tooltip: _listMode
                                    ? '切换为网格（长按设置列数）'
                                    : '切换为列表（长按设置列数）',
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
