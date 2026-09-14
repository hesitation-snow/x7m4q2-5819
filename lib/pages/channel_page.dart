import '../services/app_motion.dart';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/models.dart';
import '../api/store.dart';
import '../widgets/common.dart';
import '../widgets/filtered_list_continuation.dart';
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
  bool _loading = false;
  bool _hasMore = true;
  int _requestSerial = 0;
  String? _error;
  bool _listMode = false;

  @override
  void initState() {
    super.initState();
    LKStore.hideBraveBooks.addListener(_onHideBraveRev);
    _loadPrefs();
    _load(1, false);
  }

  @override
  void dispose() {
    LKStore.hideBraveBooks.removeListener(_onHideBraveRev);
    super.dispose();
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
    if (_loading && !forceRefresh) return;
    final request = ++_requestSerial;
    setState(() => _loading = true);
    try {
      final items = widget.path == '/api/bff/home-feed-v1'
          ? await LKApi.homeFeed('hot', page, forceRefresh: forceRefresh)
          : await LKApi.channelFeed(widget.path, page,
              forceRefresh: forceRefresh);
      if (!mounted || request != _requestSerial) return;
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
      if (mounted && request == _requestSerial) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && request == _requestSerial) {
        setState(() => _loading = false);
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
            icon: Icon(_listMode ? Icons.grid_view : Icons.view_list),
            tooltip: _listMode ? '切换到网格' : '切换到列表',
            onPressed: _toggleListMode,
          ),
        ],
      ),
      body: MotionRefreshIndicator(
        onRefresh: () => _load(1, false, forceRefresh: true),
        child: _error != null && _items.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.7,
                    child: Center(
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.grey))),
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
                : visibleItems.isEmpty && _items.isNotEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          FilteredListContinuation(
                            message: '当前列表作品已根据“隐藏勇者书籍”设置过滤',
                            hasMore: _hasMore,
                            loading: _loading,
                            error: _error,
                            pageKey: _page,
                            onLoadMore: () => _load(_page + 1, true),
                          ),
                        ],
                      )
                    : _listMode
                        ? ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: EdgeInsets.fromLTRB(8, 8, 8,
                                12 + MediaQuery.of(context).padding.bottom),
                            itemCount: visibleItems.length + (_hasMore ? 1 : 0),
                            itemBuilder: (_, i) {
                              if (i >= visibleItems.length) {
                                return ListContinuation(
                                    pageKey: _page,
                                    loading: _loading,
                                    error: _error,
                                    onLoadMore: () => _load(_page + 1, true));
                              }
                              final book = visibleItems[i];
                              return BookCard(
                                book: book,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          BookDetailPage(bookId: book.bookId)),
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
                                return ListContinuation(
                                    pageKey: _page,
                                    loading: _loading,
                                    error: _error,
                                    onLoadMore: () => _load(_page + 1, true));
                              }
                              final book = visibleItems[i];
                              return BookGridCard(
                                book: book,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          BookDetailPage(bookId: book.bookId)),
                                ),
                              );
                            },
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
  String? _error;
  bool _listMode = false;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    LKStore.hideBraveBooks.addListener(_onHideBraveRev);
    _loadPrefs();
    _load();
  }

  @override
  void dispose() {
    LKStore.hideBraveBooks.removeListener(_onHideBraveRev);
    super.dispose();
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
    try {
      final items =
          await LKApi.rank(1, pageSize: 50, forceRefresh: forceRefresh);
      if (!mounted || request != _requestSerial) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted && request == _requestSerial) {
        setState(() => _error = e.toString());
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
      body: _error != null && _items.isEmpty
          ? Center(
              child: Text(_error!, style: const TextStyle(color: Colors.grey)))
          : MotionRefreshIndicator(
              onRefresh: () => _load(forceRefresh: true),
              child: visibleItems.isEmpty && _items.isNotEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.65,
                          child: const Center(
                            child: Text('当前排行榜作品已根据“隐藏勇者书籍”设置过滤',
                                style: TextStyle(color: Colors.grey)),
                          ),
                        ),
                      ],
                    )
                  : _listMode
                      ? ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(8, 8, 8,
                              12 + MediaQuery.of(context).padding.bottom),
                          itemCount: visibleItems.length,
                          itemBuilder: (_, i) {
                            final book = visibleItems[i];
                            return BookCard(
                              book: book,
                              rank: i + 1,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        BookDetailPage(bookId: book.bookId)),
                              ),
                            );
                          },
                        )
                      : GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(12, 8, 12,
                              12 + MediaQuery.of(context).padding.bottom),
                          gridDelegate: bookGridDelegate(),
                          itemCount: visibleItems.length,
                          itemBuilder: (_, i) {
                            final book = visibleItems[i];
                            return BookGridCard(
                              book: book,
                              rank: i + 1,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        BookDetailPage(bookId: book.bookId)),
                              ),
                            );
                          },
                        ),
            ),
    );
  }
}
