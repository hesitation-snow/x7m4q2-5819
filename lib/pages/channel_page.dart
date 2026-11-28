import 'dart:async';

import '../services/app_motion.dart';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/store.dart';
import '../widgets/common.dart';
import '../widgets/content_state_view.dart';
import '../widgets/filtered_list_continuation.dart';
import '../widgets/scrollable_status.dart';
import 'book_detail_page.dart';

/// 分区频道页(轻小说/原创/同人/EPUB/更新)
class ChannelPage extends StatefulWidget {
  final String path;
  final String label;
  const ChannelPage({super.key, required this.path, required this.label});

  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage> {
  final List<dynamic> _items = [];
  int _page = 0;
  bool _loading = true;
  bool _refreshing = false;
  bool _hasMore = true;
  int _requestSerial = 0;
  String? _error;
  String? _loadMoreError;
  bool _listMode = LKStore.feedListMode.value;

  @override
  void initState() {
    super.initState();
    LKClient.sessionRev.addListener(_onSessionChanged);
    LKStore.hideBraveBooks.addListener(_onHideBraveRev);
    LKStore.braveBookRevision.addListener(_onHideBraveRev);
    _loadPrefs();
    _load(1, false);
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onSessionChanged);
    LKStore.hideBraveBooks.removeListener(_onHideBraveRev);
    LKStore.braveBookRevision.removeListener(_onHideBraveRev);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    _requestSerial++;
    setState(() {
      _items.clear();
      _page = 0;
      _hasMore = true;
      _error = null;
      _loadMoreError = null;
      _loading = true;
      _refreshing = false;
    });
    unawaited(_load(1, false, forceRefresh: true));
  }

  void _onHideBraveRev() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPrefs() async {
    final v = await ReaderPrefs.feedListMode();
    if (mounted) setState(() => _listMode = v);
  }

  void _toggleListMode() {
    setState(() => _listMode = !_listMode);
    ReaderPrefs.setFeedListMode(_listMode);
  }

  Future<void> _load(int page, bool append, {bool forceRefresh = false}) async {
    if (!mounted || (append && !_hasMore)) return;
    if (append && (_loading || _refreshing)) return;
    if (!append && _refreshing && !forceRefresh) return;
    final request = ++_requestSerial;
    final hasExisting = _items.isNotEmpty;
    setState(() {
      if (append) {
        _loading = true;
        _loadMoreError = null;
      } else if (hasExisting) {
        _refreshing = true;
        _error = null;
        _loadMoreError = null;
      } else {
        _loading = true;
        _error = null;
        _loadMoreError = null;
      }
    });
    try {
      final items = widget.path == '/api/bff/home-feed-v1'
          ? await LKApi.homeFeed('hot', page, forceRefresh: forceRefresh)
          : await LKApi.channelFeed(widget.path, page,
              forceRefresh: forceRefresh);
      if (!mounted || request != _requestSerial) return;
      setState(() {
        if (append) {
          final existingIds =
              _items.whereType<LKBook>().map((b) => b.bookId).toSet();
          for (final book in items) {
            if (existingIds.add(book.bookId)) {
              _items.add(book);
            }
          }
        } else {
          _items
            ..clear()
            ..addAll(items);
        }
        _page = page;
        _hasMore = items.length >= 20;
        _error = null;
        _loadMoreError = null;
      });
    } catch (e) {
      if (mounted && request == _requestSerial) {
        if (append) {
          setState(() => _loadMoreError = e.toString());
        } else if (_items.isNotEmpty) {
          showLkError(context, e);
        } else {
          setState(() => _error = e.toString());
        }
      }
    } finally {
      if (mounted && request == _requestSerial) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hideBrave = LKStore.hideBraveBooks.value;
    final visibleItems = hideBrave
        ? _items.where((b) => b is! LKBook || !b.isBrave).toList()
        : _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.label),
        actions: [
          IconButton(
            icon: Icon(_listMode
                ? Icons.grid_view_rounded
                : Icons.view_agenda_outlined),
            tooltip: _listMode ? '切换到网格' : '切换到列表',
            onPressed: _toggleListMode,
          ),
        ],
      ),
      body: MotionRefreshIndicator(
        onRefresh: () => _load(1, false, forceRefresh: true),
        child: _error != null && _items.isEmpty
            ? ScrollableStatus(
                child: ContentStateView(
                  message: _error!,
                  onRetry: () => _load(1, false, forceRefresh: true),
                ),
              )
            : _loading && _items.isEmpty
                ? const ScrollableStatus(child: LkLoadingIndicator())
                : visibleItems.isEmpty && _items.isNotEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          FilteredListContinuation(
                            message: '当前列表作品已根据“隐藏勇者书籍”设置过滤',
                            hasMore: _hasMore,
                            loading: _loading || _refreshing,
                            error: _loadMoreError,
                            pageKey: _page,
                            onLoadMore: () => _load(_page + 1, true),
                          ),
                        ],
                      )
                    : Stack(
                        children: [
                          _listMode
                              ? ListView.builder(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: EdgeInsets.fromLTRB(
                                      8,
                                      8,
                                      8,
                                      12 +
                                          MediaQuery.of(context)
                                              .padding
                                              .bottom),
                                  itemCount:
                                      visibleItems.length + (_hasMore ? 1 : 0),
                                  itemBuilder: (_, i) {
                                    if (i >= visibleItems.length) {
                                      return ListContinuation(
                                          pageKey: _page,
                                          loading: _loading || _refreshing,
                                          error: _loadMoreError,
                                          onLoadMore: () =>
                                              _load(_page + 1, true));
                                    }
                                    final book = visibleItems[i];
                                    return BookCard(
                                      key: ValueKey(book.bookId),
                                      book: book,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => BookDetailPage(
                                                bookId: book.bookId)),
                                      ),
                                    );
                                  },
                                )
                              : GridView.builder(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: EdgeInsets.fromLTRB(
                                      12,
                                      8,
                                      12,
                                      12 +
                                          MediaQuery.of(context)
                                              .padding
                                              .bottom),
                                  gridDelegate: bookGridDelegate(context),
                                  itemCount:
                                      visibleItems.length + (_hasMore ? 1 : 0),
                                  itemBuilder: (_, i) {
                                    if (i >= visibleItems.length) {
                                      return ListContinuation(
                                          pageKey: _page,
                                          loading: _loading || _refreshing,
                                          error: _loadMoreError,
                                          onLoadMore: () =>
                                              _load(_page + 1, true));
                                    }
                                    final book = visibleItems[i];
                                    return BookGridCard(
                                      key: ValueKey(book.bookId),
                                      book: book,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => BookDetailPage(
                                                bookId: book.bookId)),
                                      ),
                                    );
                                  },
                                ),
                          if (_refreshing)
                            const Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: MotionLinearProgressIndicator(
                                minHeight: 2,
                              ),
                            ),
                        ],
                      ),
      ),
    );
  }
}

/// 排行榜页
class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  List<dynamic> _items = [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  bool _listMode = LKStore.feedListMode.value;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    LKClient.sessionRev.addListener(_onSessionChanged);
    LKStore.hideBraveBooks.addListener(_onHideBraveRev);
    LKStore.braveBookRevision.addListener(_onHideBraveRev);
    _loadPrefs();
    _load();
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onSessionChanged);
    LKStore.hideBraveBooks.removeListener(_onHideBraveRev);
    LKStore.braveBookRevision.removeListener(_onHideBraveRev);
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    _requestSerial++;
    setState(() {
      _items = [];
      _error = null;
      _loading = true;
      _refreshing = false;
    });
    unawaited(_load(forceRefresh: true));
  }

  void _onHideBraveRev() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPrefs() async {
    final v = await ReaderPrefs.feedListMode();
    if (mounted) setState(() => _listMode = v);
  }

  void _toggleListMode() {
    setState(() => _listMode = !_listMode);
    ReaderPrefs.setFeedListMode(_listMode);
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final request = ++_requestSerial;
    final hasExisting = _items.isNotEmpty;
    if (mounted) {
      setState(() {
        _error = null;
        if (hasExisting) {
          _refreshing = true;
        } else {
          _loading = true;
        }
      });
    }
    try {
      final items =
          await LKApi.rank(1, pageSize: 50, forceRefresh: forceRefresh);
      if (!mounted || request != _requestSerial) return;
      setState(() {
        _items = items;
        _error = null;
        _loading = false;
        _refreshing = false;
      });
    } catch (e) {
      if (mounted && request == _requestSerial) {
        setState(() {
          _loading = false;
          _refreshing = false;
          if (_items.isEmpty) _error = e.toString();
        });
        if (_items.isNotEmpty) {
          showLkError(context, e);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hideBrave = LKStore.hideBraveBooks.value;
    final visibleItems = hideBrave
        ? _items.where((b) => b is! LKBook || !b.isBrave).toList()
        : _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('排行榜'),
        actions: [
          IconButton(
            tooltip: _listMode ? '切换为网格' : '切换为列表',
            icon: Icon(_listMode
                ? Icons.grid_view_rounded
                : Icons.view_agenda_outlined),
            onPressed: _toggleListMode,
          ),
        ],
      ),
      body: MotionRefreshIndicator(
        onRefresh: () => _load(forceRefresh: true),
        child: _error != null && _items.isEmpty
            ? ScrollableStatus(
                child: ContentStateView(
                  message: _error!,
                  onRetry: () => _load(forceRefresh: true),
                ),
              )
            : _loading && _items.isEmpty
                ? const ScrollableStatus(child: LkLoadingIndicator())
                : visibleItems.isEmpty && _items.isNotEmpty
                    ? const ScrollableStatus(
                        child: ContentStateView(
                          message: '当前排行榜作品已根据“隐藏勇者书籍”设置过滤',
                          icon: Icons.visibility_off_outlined,
                        ),
                      )
                    : Stack(
                        children: [
                          _listMode
                              ? ListView.builder(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: EdgeInsets.fromLTRB(
                                      8,
                                      8,
                                      8,
                                      12 +
                                          MediaQuery.of(context)
                                              .padding
                                              .bottom),
                                  itemCount: visibleItems.length,
                                  itemBuilder: (_, i) {
                                    final book = visibleItems[i];
                                    return BookCard(
                                      book: book,
                                      rank: i + 1,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => BookDetailPage(
                                                bookId: book.bookId)),
                                      ),
                                    );
                                  },
                                )
                              : GridView.builder(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: EdgeInsets.fromLTRB(
                                      12,
                                      8,
                                      12,
                                      12 +
                                          MediaQuery.of(context)
                                              .padding
                                              .bottom),
                                  gridDelegate: bookGridDelegate(context),
                                  itemCount: visibleItems.length,
                                  itemBuilder: (_, i) {
                                    final book = visibleItems[i];
                                    return BookGridCard(
                                      book: book,
                                      rank: i + 1,
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => BookDetailPage(
                                                bookId: book.bookId)),
                                      ),
                                    );
                                  },
                                ),
                          if (_refreshing)
                            const Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: MotionLinearProgressIndicator(
                                minHeight: 2,
                              ),
                            ),
                        ],
                      ),
      ),
    );
  }
}
