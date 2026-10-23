import '../widgets/m3_menu_sheet.dart';
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
  bool _loading = true;
  bool _listMode = false;
  bool _localMode = false;
  bool _reloadAfterCurrent = false;
  int _statusVerificationGeneration = 0;
  static final _statusQueue = BackgroundWorkQueue(concurrency: 3);
  final _verifiedStatuses = <int, LKBook>{};
  _ShelfSort _sort = _ShelfSort.serverOrder;
  _ShelfFilter _filter = _ShelfFilter.all;
  int _loadSerial = 0;
  final _removing = <int>{};
  bool _updatingLocalShelf = false;
  final ValueNotifier<double> _topBarFrac = ValueNotifier<double>(1.0);
  final _toolbarKey = GlobalKey();
  double get _topBarFlex => _toolbarKey.currentContext?.size?.height ?? 112;

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
      textScaler: MediaQuery.textScalerOf(context),
      isShelf: true,
      mainAxisSpacing: 8,
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
        textScaler: MediaQuery.textScalerOf(context),
        isShelf: true,
        mainAxisSpacing: 8,
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
    if (_updatingLocalShelf) return;
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
      final items = await LKStore.localShelf();
      if (!mounted || request != _loadSerial || !_localMode) return;
      setState(() {
        _items = items;
        _page = 1;
        _hasMore = false;
        _error = null;
        _loading = false;
      });
      if (items.isNotEmpty) {
        unawaited(_verifyServerBookStatuses(items));
      }
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
    if (cached != null && cached.isNotEmpty) {
      setState(() {
        _items = [...cached];
        _page = cached.isEmpty ? 0 : 1;
        _hasMore = true;
        _error = null;
        _loading = false;
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
      _loading = !silent || _items.isEmpty;
      if (!silent) _error = null;
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
        if (items.isNotEmpty) {
          unawaited(
              _verifyServerBookStatuses(items, forceRefresh: forceRefresh));
        }
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
        if (!silent || _items.isEmpty) {
          setState(() {
            _error = e.toString();
            _errorFromAppend = append;
          });
        }
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
    if (_removing.isNotEmpty) return;
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

  Widget _viewModeButton() => GestureDetector(
        onLongPress: () => showGridColumnsSheet(context),
        child: IconButton(
          tooltip: _listMode ? '切换为网格（长按设置列数）' : '切换为列表（长按设置列数）',
          icon: Icon(
              _listMode ? Icons.grid_view_rounded : Icons.view_agenda_outlined),
          onPressed: () {
            final value = !_listMode;
            setState(() => _listMode = value);
            ReaderPrefs.setFeedListMode(value);
          },
        ),
      );

  Widget _shelfToolbar(int count) {
    final theme = Theme.of(context);
    final sortLabel = switch (_sort) {
      _ShelfSort.serverOrder => '默认顺序',
      _ShelfSort.recentlyUpdated => '最近更新',
      _ShelfSort.title => '按书名',
    };
    return Material(
      key: _toolbarKey,
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                  child: Align(
                alignment: Alignment.centerLeft,
                child: _shelfSourceButton(),
              )),
              _shelfFilterButton(),
              _viewModeButton(),
            ]),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final filter in _ShelfFilter.values) ...[
                  ChoiceChip(
                    label: Text(switch (filter) {
                      _ShelfFilter.all => '全部作品',
                      _ShelfFilter.unread => '有更新',
                      _ShelfFilter.serializing => '连载中',
                      _ShelfFilter.completed => '已完结',
                    }),
                    selected: _filter == filter,
                    onSelected: (_) => setState(() => _filter = filter),
                  ),
                  const SizedBox(width: 8),
                ],
              ]),
            ),
            const SizedBox(height: 8),
            Text('$count 部作品 · $sortLabel',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _shelfMessage({required bool error}) {
    final theme = Theme.of(context);
    final filtered = _items.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(error ? Icons.cloud_off_outlined : Icons.auto_stories_outlined,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
                error
                    ? '书架加载失败'
                    : filtered
                        ? '暂无匹配作品'
                        : '书架还是空的',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
                error
                    ? '请检查网络连接后重试'
                    : filtered
                        ? '试试其他筛选，或查看全部作品。'
                        : '将喜欢的作品加入书架，随时回来继续阅读。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            if (error)
              FilledButton.tonalIcon(
                  onPressed: () => _load(forceRefresh: true),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'))
            else if (filtered)
              TextButton(
                  onPressed: () => setState(() => _filter = _ShelfFilter.all),
                  child: const Text('查看全部作品')),
          ],
        ),
      ),
    );
  }

  Widget _shelfFilterButton() {
    final active =
        _filter != _ShelfFilter.all || _sort != _ShelfSort.serverOrder;
    return PopupMenuButton<String>(
      tooltip: '筛选与排序',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 8),
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
      constraints: const BoxConstraints(minWidth: 224, maxWidth: 288),
      padding: const EdgeInsets.all(8),
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      itemBuilder: (_) => [
        _menuHeading('筛选'),
        _menuChoice('filter:all', '全部作品', Icons.library_books_outlined,
            _filter == _ShelfFilter.all),
        _menuChoice('filter:unread', '有更新', Icons.new_releases_outlined,
            _filter == _ShelfFilter.unread),
        _menuChoice('filter:serializing', '连载中', Icons.edit_note_rounded,
            _filter == _ShelfFilter.serializing),
        _menuChoice('filter:completed', '已完结', Icons.task_alt_rounded,
            _filter == _ShelfFilter.completed),
        const PopupMenuDivider(height: 16),
        _menuHeading('排序'),
        _menuChoice('sort:server', '默认顺序', Icons.format_list_numbered_rounded,
            _sort == _ShelfSort.serverOrder),
        _menuChoice('sort:updated', '最近更新', Icons.update_rounded,
            _sort == _ShelfSort.recentlyUpdated),
        _menuChoice('sort:title', '按书名', Icons.sort_by_alpha_rounded,
            _sort == _ShelfSort.title),
      ],
    );
  }

  PopupMenuItem<String> _menuHeading(String label) {
    final theme = Theme.of(context);
    return PopupMenuItem<String>(
      enabled: false,
      height: 32,
      child: Text(label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          )),
    );
  }

  PopupMenuItem<String> _menuChoice(
      String value, String label, IconData icon, bool selected) {
    final colors = Theme.of(context).colorScheme;
    final foreground =
        selected ? colors.onSecondaryContainer : colors.onSurface;
    return PopupMenuItem<String>(
      value: value,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      height: 48,
      child: Semantics(
        selected: selected,
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? colors.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: TextStyle(color: foreground))),
            const SizedBox(width: 8),
            Icon(selected ? Icons.check_rounded : null,
                size: 20, color: foreground),
          ]),
        ),
      ),
    );
  }

  Widget _shelfBookRow(LKBook book) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card.filled(
      key: ValueKey('shelf-book-${book.bookId}'),
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => BookDetailPage(bookId: book.bookId))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverImage(
                url: book.coverUrl,
                width: 64,
                height: 92,
                radius: 8,
                isBrave: book.isBrave),
            const SizedBox(width: 16),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(book.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(book.authorName.isEmpty ? '佚名' : book.authorName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(bookStatusLabel(book),
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                    if (book.isBrave)
                      Text('勇者可读',
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: scheme.tertiary)),
                    if (book.unreadChapterCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8)),
                        child: Text('${book.unreadChapterCount} 章更新',
                            style: theme.textTheme.labelMedium
                                ?.copyWith(color: scheme.onPrimaryContainer)),
                      ),
                  ],
                ),
                if (book.updatedAt.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                      '更新于 ${book.updatedAt.length > 16 ? book.updatedAt.substring(0, 16) : book.updatedAt}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ],
            )),
          ]),
        ),
      ),
    );
  }

  Widget _withShelfActions(LKBook book, Widget child) => Semantics(
        hint: '长按管理书架',
        child: GestureDetector(
          onLongPress: () => _showBookActions(book),
          child: child,
        ),
      );

  Future<void> _showBookActions(LKBook book) async {
    if (_removing.isNotEmpty) return;
    final remove = await showModalBottomSheet<bool>(
      context: context,
      sheetAnimationStyle: AppMotion.style(context),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        final scheme = Theme.of(sheetCtx).colorScheme;
        return M3MenuSheet(
          title: '书架操作',
          icon: Icons.library_books_outlined,
          children: [
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => Navigator.pop(sheetCtx, true),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(
                    children: [
                      Icon(Icons.playlist_remove_rounded,
                          size: 22, color: scheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '从书架移除',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: scheme.error,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              book.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          size: 18, color: scheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    if (remove != true || !mounted || !_removing.add(book.bookId)) return;
    final local = _localMode;
    final uid = LKClient.shared.session.uid;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('从书架移除？'),
          content: Text(
              '将《${book.title}》移出${local ? '本机' : '云端及本机'}书架。\n仅移出书架，不删除阅读记录、正文或下载文件。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认移除')),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          local != _localMode ||
          uid != LKClient.shared.session.uid) {
        return;
      }
      if (!local) await LKApi.toggleShelf(book.bookId, false);
      if (!mounted || uid != LKClient.shared.session.uid) return;
      _updatingLocalShelf = true;
      try {
        await LKStore.setLocalShelf(book, false);
      } finally {
        _updatingLocalShelf = false;
      }
      if (!mounted ||
          local != _localMode ||
          uid != LKClient.shared.session.uid) {
        return;
      }
      // Discard an older in-flight snapshot rather than restoring the removed book.
      _loadSerial++;
      setState(() {
        _items = _items.where((item) => item.bookId != book.bookId).toList();
        // Offset-based pages shift after deletion. Overlap the next existing
        // load by one page; mergePagedItems deduplicates without a new request now.
        if (!local && _hasMore) _page = (_page - 1).clamp(0, _page);
        _loading = false;
      });
      if (!local) await LKStore.cacheBooksPage(_shelfCacheKey(uid), _items);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('移除失败，请重试'),
          action: SnackBarAction(
              label: '重试', onPressed: () => _showBookActions(book)),
        ));
      }
    } finally {
      _removing.remove(book.bookId);
    }
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
    final body = MotionRefreshIndicator(
      onRefresh: () => _load(forceRefresh: true),
      child: _error != null && _items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                      minHeight: MediaQuery.sizeOf(context).height * 0.4),
                  child: _shelfMessage(error: true),
                ),
              ],
            )
          : _loading && _items.isEmpty
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
                        ConstrainedBox(
                          constraints: BoxConstraints(
                              minHeight:
                                  MediaQuery.sizeOf(context).height * 0.4),
                          child: _shelfMessage(error: false),
                        ),
                        if (_hasMore) _shelfLoadMoreFooter(),
                      ],
                    )
                  : _listMode
                      ? ListView.builder(
                          scrollCacheExtent:
                              const ScrollCacheExtent.viewport(1.0),
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(12, 8, 12,
                              12 + MediaQuery.of(context).padding.bottom),
                          itemCount: visibleItems.length + (_hasMore ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i >= visibleItems.length) {
                              return _shelfLoadMoreFooter();
                            }
                            final b = visibleItems[i];
                            return _withShelfActions(b, _shelfBookRow(b));
                          },
                        )
                      : GridView.builder(
                          controller: _gridScrollController,
                          scrollCacheExtent:
                              const ScrollCacheExtent.viewport(1.0),
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(12, 8, 12,
                              12 + MediaQuery.of(context).padding.bottom),
                          gridDelegate:
                              bookGridDelegate(context, isShelf: true),
                          itemCount: visibleItems.length + (_hasMore ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i >= visibleItems.length) {
                              return _shelfLoadMoreFooter();
                            }
                            final b = visibleItems[i];
                            return _withShelfActions(
                                b,
                                BookGridCard(
                                  book: b,
                                  isShelf: true,
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            BookDetailPage(bookId: b.bookId)),
                                  ),
                                ));
                          },
                        ),
    );
    final toolbar = _shelfToolbar(visibleItems.length);
    if (!widget.embedded) {
      return Scaffold(
        appBar: AppBar(title: const Text('书架')),
        body: Column(children: [
          toolbar,
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification && !_listMode) {
                  _updateGridAnchor();
                }
                return false;
              },
              child: body,
            ),
          ),
        ]),
      );
    }
    return Column(
      children: [
        ValueListenableBuilder<double>(
          valueListenable: _topBarFrac,
          child: toolbar,
          builder: (context, fraction, child) => ClipRect(
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: fraction,
              child: child,
            ),
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onShelfScroll,
            child: body,
          ),
        ),
      ],
    );
  }
}
