import '../services/app_motion.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/store.dart';
import '../widgets/common.dart';
import '../widgets/filtered_list_continuation.dart';
import 'book_detail_page.dart';

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
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    LKStore.hideBraveBooks.addListener(_onHideBraveRev);
    _tag = widget.initialTag;
    _loadTaxonomy();
    if (widget.initialTag != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(0, false));
    }
  }

  @override
  void dispose() {
    LKStore.hideBraveBooks.removeListener(_onHideBraveRev);
    _controller.dispose();
    super.dispose();
  }

  void _onHideBraveRev() {
    if (mounted) setState(() {});
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
    if (!mounted) return;
    if (append && (_loading || !_hasMore)) return;
    var query = _controller.text.trim();
    if (query.isEmpty && _tag == null && _channel == null) return;
    final request = ++_requestSerial;
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

  Future<void> _refresh() async {
    await _loadTaxonomy();
    await _search(0, false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: MotionRefreshIndicator(
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
    final hideBrave = LKStore.hideBraveBooks.value;
    final visibleItems =
        hideBrave ? _items.where((b) => !b.isBrave).toList() : _items;
    if (visibleItems.isEmpty) {
      return [
        SliverToBoxAdapter(
            child: FilteredListContinuation(
          message: '当前搜索结果已根据“隐藏勇者书籍”设置过滤',
          hasMore: _hasMore,
          loading: _loading,
          error: _error,
          pageKey: _page,
          onLoadMore: () => _search(_page + 1, true),
        )),
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
              if (i >= visibleItems.length) {
                return ListContinuation(
                    pageKey: _page,
                    loading: _loading,
                    error: _error,
                    onLoadMore: () => _search(_page + 1, true));
              }
              final b = visibleItems[i];
              return BookGridCard(
                book: b,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => BookDetailPage(bookId: b.bookId)),
                ),
              );
            },
            childCount: visibleItems.length + (_hasMore ? 1 : 0),
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
          duration: AppMotion.duration(context, 150),
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
