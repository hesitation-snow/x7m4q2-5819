import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../widgets/common.dart';
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

  @override
  void initState() {
    super.initState();
    _tag = widget.initialTag;
    _loadTaxonomy();
    if (widget.initialTag != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _search(0, false));
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
    var query = _controller.text.trim();
    if (query.isEmpty && _tag == null && _channel == null) return;
    var preset = '';
    var primaryTag = '';
    var channelCode = '';
    var workType = '';
    if (_tag != null) {
      final chip = _tags.firstWhere(
          (e) => e['jumpValue'] == _tag,
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
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
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
      body: Column(
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  _chip('全部标签', _tag == null, () {
                    setState(() => _tag = null);
                    _search(0, false);
                  }),
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
                    ),
                ],
              ),
            ),
          Expanded(
            child: _error != null && _items.isEmpty
                ? Center(
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.grey)))
                : _items.isEmpty && !_loading
                    ? Center(
                        child: Text(
                          _controller.text.isEmpty &&
                                  _tag == null &&
                                  _channel == null
                              ? '输入关键词,或选择标签 / 分类 / 更新时间'
                              : '没有找到相关作品',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : GridView.builder(
                        padding: EdgeInsets.fromLTRB(12, 4, 12,
                            12 + MediaQuery.of(context).padding.bottom),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.56,
                        ),
                        itemCount: _items.length,
                        itemBuilder: (_, i) {
                          final b = _items[i];
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
          ),
        ],
      ),
    );
  }

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

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          alignment: Alignment.center,
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
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  List<dynamic> _items = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await LKApi.bookshelf(1);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的书架')),
      body: _error != null && _items.isEmpty
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.grey)))
          : RefreshIndicator(
              onRefresh: _load,
              child: GridView.builder(
                padding: EdgeInsets.fromLTRB(12, 8, 12,
                    12 + MediaQuery.of(context).padding.bottom),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.56,
                ),
                itemCount: _items.length,
                itemBuilder: (_, i) {
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
              ),
            ),
    );
  }
}

/// 书评 / 本卷评论
class CommentsPage extends StatefulWidget {
  final int bookId;
  final String bookTitle;
  /// 0 = 整书评论;>0 = 本卷评论
  final int volumeId;
  const CommentsPage(
      {super.key,
      required this.bookId,
      required this.bookTitle,
      this.volumeId = 0});

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  List<dynamic> _comments = [];
  String? _error;
  final _input = TextEditingController();

  bool get _isVolume => widget.volumeId > 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cs = _isVolume
          ? await LKApi.volumeComments(widget.bookId, widget.volumeId, 1)
          : await LKApi.bookComments(widget.bookId, 1);
      if (!mounted) return;
      setState(() => _comments = cs);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _publish() async {
    final content = _input.text.trim();
    if (content.isEmpty) return;
    try {
      if (_isVolume) {
        await LKApi.publishBookComment(widget.bookId, content,
            volumeId: widget.volumeId);
      } else {
        await LKApi.publishBookComment(widget.bookId, content);
      }
      _input.clear();
      _load();
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_isVolume
              ? '本卷评论 · ${widget.bookTitle}'
              : '书评 · ${widget.bookTitle}')),
      body: Column(children: [
        Expanded(
          child: _comments.isEmpty
              ? Center(
                  child: Text(_error ?? (_isVolume ? '本卷还没有评论' : '还没有书评,来抢沙发'),
                      style: const TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: _comments.length,
                  itemBuilder: (_, i) {
                    final c = _comments[i];
                    return ListTile(
                      leading: CircleAvatar(
                          backgroundImage:
                              c.avatar.isNotEmpty ? NetworkImage(c.avatar) : null),
                      title: Text(c.nickname,
                          style: TextStyle(
                              fontSize: 13, color: Colors.indigo.shade400)),
                      subtitle: Text(c.content),
                      trailing: Text('赞 ${c.likeCount}',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                    );
                  },
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: InputDecoration(
                      hintText: _isVolume ? '写下本卷评论…' : '写下你的书评…',
                      isDense: true,
                      border: const OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _publish, child: const Text('发布')),
            ]),
          ),
        ),
      ]),
    );
  }
}
