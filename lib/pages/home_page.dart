import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../widgets/common.dart';
import 'book_detail_page.dart';
import 'channel_page.dart';
import 'dm_chat_page.dart';
import 'dynamic_page.dart';
import 'login_page.dart';
import 'reader_page.dart';
import 'search_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  /// 顶栏/底栏可见比例 0..1,随首页滚动 1:1 伸缩(滑一点露一点)
  double _barFrac = 1.0;
  /// 顶栏可伸缩部分的高度(不含状态栏区域)
  static const double _barFlex = 104.0;

  static const _channels = [
    ('hot', '热门', '/api/bff/home-feed-v1'),
    ('new', '最新', '/api/bff/home-feed-v1'),
  ];
  int _channel = 0;

  /// 首页滚动时按滚动增量伸缩顶栏(只有首页参与;其它 Tab 保持完整)
  void _onFeedScroll(ScrollUpdateNotification n) {
    if (_tab != 0) return;
    final delta = n.scrollDelta ?? 0.0;
    // 忽略启动时的初始滚动通知(位置为 0 却带正向 delta,会导致顶栏被瞬间收起)
    if (delta > 0 && n.metrics.pixels <= 0) return;
    final frac = (_barFrac - delta / _barFlex).clamp(0.0, 1.0);
    if (frac != _barFrac) setState(() => _barFrac = frac);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padTop = MediaQuery.of(context).padding.top;
    final double barHeight =
        _tab == 0 ? padTop + _barFlex * _barFrac : padTop;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark
          ? const SystemUiOverlayStyle(
              statusBarColor: Color(0xFF1B1C21),
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            )
          : const SystemUiOverlayStyle(
              statusBarColor: Colors.white,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
      child: Scaffold(
      body: Column(
        children: [
          // 顶栏:仅首页显示(搜索框 + 头像 + 频道胶囊),高度随滚动 1:1 伸缩;
          // 其它 Tab 只留状态栏背景
          ClipRect(
            child: Container(
              width: double.infinity,
              height: barHeight,
              color: _tab == 0
                  ? (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF1B1C21)
                      : Colors.white)
                  : (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF121316)
                      : const Color(0xFFF6F7FB)),
              // 用不可滚动的 ScrollView 吸收高度变化中间帧的约束,避免溢出警告;
              // 内容自底部被裁剪,形成"伸缩"效果
              child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(20),
                                      onTap: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  const SearchPage())),
                                      child: Container(
                                        height: 40,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14),
                                        alignment: Alignment.centerLeft,
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                                      .brightness ==
                                                  Brightness.dark
                                              ? const Color(0xFF1E2025)
                                              : Colors.grey.shade100,
                                          borderRadius:
                                              BorderRadius.circular(20),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.search_rounded,
                                                size: 19,
                                                color:
                                                    Colors.grey.shade500),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                '搜索书名 / 作者',
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 13.5,
                                                    color: Colors
                                                        .grey.shade500),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  // LK 用户头像:点击跳转"我的"
                                  GestureDetector(
                                    onTap: () => setState(() {
                                      _tab = 3;
                                      _barFrac = 1.0;
                                    }),
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                            color: isDark
                                                ? Colors.white54
                                                : Colors.indigo.shade200,
                                            width: 1.6),
                                      ),
                                      child: CircleAvatar(
                                        radius: 15,
                                        backgroundColor:
                                            Colors.indigo.shade100,
                                        backgroundImage: LKClient.shared
                                                .session.avatar.isNotEmpty
                                            ? NetworkImage(LKClient.shared
                                                .session.avatar)
                                            : null,
                                        child: LKClient.shared
                                                .session.avatar.isNotEmpty
                                            ? null
                                            : const Icon(Icons.person,
                                                size: 18,
                                                color: Colors.indigo),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // 频道胶囊(热门/最新),随顶栏一起隐藏
                          SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(
                          left: 12, right: 12, bottom: 4),
                      itemCount: _channels.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final sel = i == _channel;
                        final scheme = Theme.of(context).colorScheme;
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;
                        return GestureDetector(
                          onTap: () {
                            setState(() => _channel = i);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 5),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: sel
                                  ? scheme.primary
                                  : (isDark
                                      ? const Color(0xFF2A2C33)
                                      : Colors.grey.shade100),
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: sel
                                  ? [
                                      BoxShadow(
                                          color: scheme.primary
                                              .withValues(alpha: 0.3),
                                          blurRadius: 6,
                                          offset: const Offset(0, 2)),
                                    ]
                                  : null,
                            ),
                            child: Text(
                              _channels[i].$2,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: sel
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: sel
                                    ? Colors.white
                                    : (isDark
                                        ? Colors.grey.shade300
                                        : Colors.grey.shade700),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              ),
            ),
          ),
          Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  // 顶栏随滚动 1:1 伸缩:下滑收起、上滑露出
                  if (n is ScrollUpdateNotification) _onFeedScroll(n);
                  return false;
                },
                child: IndexedStack(
                  index: _tab,
                  children: [
                    FeedTab(
                      channelCode: _channels[_channel].$1,
                      path: _channels[_channel].$3,
                    ),
                    const SectionTab(),
                    const DynamicPage(embedded: true),
                    const MyTab(),
                  ],
                ),
              ),
            ),
          ],
        ),
      bottomNavigationBar: ClipRect(
        // 底栏随顶栏一起 1:1 伸缩(仅首页;切 Tab 时重置为完整显示)
        child: SizedBox(
          height: (64 + MediaQuery.of(context).padding.bottom) * _barFrac,
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) {
              setState(() {
                _tab = i;
                _barFrac = 1.0;
              });
            },
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '首页'),
              NavigationDestination(
                  icon: Icon(Icons.grid_view_outlined),
                  selectedIcon: Icon(Icons.grid_view_rounded),
                  label: '分区'),
              NavigationDestination(
                  icon: Icon(Icons.dynamic_feed_outlined),
                  selectedIcon: Icon(Icons.dynamic_feed),
                  label: '动态'),
              NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '我的'),
            ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

// ==================== 首页信息流 ====================

class FeedTab extends StatefulWidget {
  final String channelCode;
  final String path;
  const FeedTab({super.key, required this.channelCode, required this.path});

  @override
  State<FeedTab> createState() => _FeedTabState();
}

class _FeedTabState extends State<FeedTab> {
  final List<dynamic> _items = [];
  int _page = 0;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(1, false);
  }

  @override
  void didUpdateWidget(FeedTab old) {
    super.didUpdateWidget(old);
    if (old.channelCode != widget.channelCode || old.path != widget.path) {
      _load(1, false);
    }
  }

  Future<void> _load(int page, bool append) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = widget.path == '/api/bff/home-feed-v1'
          ? await LKApi.homeFeed(widget.channelCode, page)
          : await LKApi.channelFeed(widget.path, page);
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

  @override
  Widget build(BuildContext context) {
    // 注意:IndexedStack 的子组件不能包 Expanded(非法 ParentDataWidget,
    // release 模式会抛类型转换异常导致整个信息流区域空白),直接返回即可。
    return _error != null && _items.isEmpty
        ? _feedHint(icon: Icons.wifi_off_rounded, text: _error!, onRetry: () => _load(1, false))
        : _items.isEmpty
            ? (_loading
                ? const Center(child: CircularProgressIndicator())
                : _feedHint(
                    icon: Icons.inbox_outlined,
                    text: '没有获取到内容,请点击重试',
                    onRetry: () => _load(1, false)))
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.56,
                ),
                itemCount: _items.length + (_hasMore ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i >= _items.length) {
                    // 触底加载更多(延迟到帧后,避免 build 期间 setState)
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _load(_page + 1, true));
                    return const Center(child: CircularProgressIndicator());
                  }
                  final book = _items[i];
                  return BookGridCard(
                    book: book,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => BookDetailPage(bookId: book.bookId)),
                    ),
                  );
                },
              );
  }

  /// 首页信息流的错误/空状态提示(带重试)
  Widget _feedHint(
      {required IconData icon,
      required String text,
      required VoidCallback onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 分区 ====================

class SectionTab extends StatelessWidget {
  const SectionTab({super.key});

  static const _sections = [
    (Icons.auto_stories_rounded, '轻小说', '日轻翻译 / 文库本', '/api/bff/home-lightnovel-feed-v1'),
    (Icons.lightbulb_outline_rounded, '原创', '站内原创作品', '/api/bff/home-original-feed-v1'),
    (Icons.groups_2_outlined, '同人', '同人 / 二创', '/api/bff/home-fanfic-feed-v1'),
    (Icons.menu_book_outlined, 'EPUB', 'EPUB 电子书', '/api/bff/home-epub-feed-v1'),
    (Icons.bolt_rounded, '更新', '最近更新', '/api/bff/home-recent-updates-feed-v1'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('分区',
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : const Color(0xFF263238))),
        const SizedBox(height: 4),
        Text('按类型浏览作品',
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
        const SizedBox(height: 14),
        ..._sections.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: isDark ? const Color(0xFF1E2025) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ChannelPage(path: s.$4, label: s.$2)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(s.$1, color: scheme.primary, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.$2,
                                  style: const TextStyle(
                                      fontSize: 15.5,
                                      fontWeight: FontWeight.w600)),
                              Text(s.$3,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade500)),
                            ]),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          color: Colors.grey.shade400),
                    ]),
                  ),
                ),
              ),
            )),
        // 排行榜入口
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: isDark ? const Color(0xFF1E2025) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const RankPage())),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          colors: [Colors.orange.shade300, Colors.deepOrange.shade400]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.emoji_events_rounded,
                        color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('排行榜',
                              style: TextStyle(
                                  fontSize: 15.5, fontWeight: FontWeight.w600)),
                          Text('每日热度榜单',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                        ]),
                  ),
                  Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400),
                ]),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ==================== 云端历史 ====================

class CloudHistoryTab extends StatefulWidget {
  const CloudHistoryTab({super.key});

  @override
  State<CloudHistoryTab> createState() => _CloudHistoryTabState();
}

class _CloudHistoryTabState extends State<CloudHistoryTab> {
  List<dynamic> _items = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      if (!LKClient.shared.session.isLoggedIn) {
        setState(() {
          _error = '未登录';
          _items = [];
        });
        return;
      }
      final items = await LKApi.cloudHistory(1);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error == '未登录') {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('登录后可同步网页端阅读记录', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          FilledButton(
              onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const LoginPage()))
                  .then((_) => _load()),
              child: const Text('去登录')),
        ]),
      );
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.grey)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: (_, i) {
          final h = _items[i];
          return InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ReaderPage(
                        bookId: h.bookId,
                        bookTitle: h.title,
                        chapterId: h.chapterId,
                        chapterTitle: h.chapterTitle,
                        volumeId: h.volumeId,
                      )),
            ),
            onLongPress: () async {
              try {
                await LKApi.deleteHistory(h.bookId);
                _load();
              } catch (e) {
                if (context.mounted) showLkError(context, e);
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Material(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF1E2025)
                    : Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ReaderPage(
                              bookId: h.bookId,
                              bookTitle: h.title,
                              chapterId: h.chapterId,
                              chapterTitle: h.chapterTitle,
                              volumeId: h.volumeId,
                            )),
                  ),
                  onLongPress: () async {
                    try {
                      await LKApi.deleteHistory(h.bookId);
                      _load();
                    } catch (e) {
                      if (context.mounted) showLkError(context, e);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      CoverImage(url: h.coverUrl, width: 50, height: 66, radius: 8),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${h.title} · ${h.authorName}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      height: 1.3)),
                              const SizedBox(height: 4),
                              if (h.chapterTitle.isNotEmpty)
                                Text('读到 ${h.chapterTitle}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.indigo.shade400)),
                              const SizedBox(height: 6),
                              if (h.progressPercent > 0)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: (h.progressPercent / 100).clamp(0.0, 1.0),
                                    minHeight: 5,
                                    backgroundColor: Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.grey.shade800
                                        : Colors.grey.shade200,
                                  ),
                                ),
                              const SizedBox(height: 5),
                              Text(
                                [
                                  if (h.progressPercent > 0) '进度 ${h.progressPercent}%',
                                  if (h.lastReadAt.isNotEmpty) h.lastReadAt,
                                  if (h.unreadChapters > 0) '未读 ${h.unreadChapters} 章',
                                ].join(' · '),
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey.shade500),
                              ),
                            ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ==================== 我的 ====================

class MyTab extends StatelessWidget {
  const MyTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = LKClient.shared.session;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 右上角:通知入口(消息中心/私信)
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: '消息中心 / 私信',
            icon: Icon(
              Icons.notifications_none_rounded,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey.shade300
                  : const Color(0xFF263238),
            ),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MessagesPage())),
          ),
        ),
        // 头部卡片
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.indigo.shade400, Colors.indigo.shade600],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: Colors.indigo.shade200.withValues(alpha: 0.5),
                  blurRadius: 10,
                  offset: const Offset(0, 4)),
            ],
          ),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white70, width: 2),
              ),
              child: CircleAvatar(
                radius: 28,
                backgroundColor: Colors.white24,
                backgroundImage:
                    s.avatar.isNotEmpty ? NetworkImage(s.avatar) : null,
                child: s.avatar.isEmpty
                    ? const Icon(Icons.person, size: 30, color: Colors.white)
                    : null,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.isLoggedIn ? s.nickname : '未登录',
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 3),
                Text(
                    s.isLoggedIn
                        ? 'UID: ${s.uid}'
                        : '登录后可同步书架、阅读进度、书评与消息',
                    style: TextStyle(
                        fontSize: 12, color: Colors.white.withValues(alpha: 0.9))),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white70),
          ]),
        ),
        const SizedBox(height: 16),
        if (!s.isLoggedIn)
          FilledButton(
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const LoginPage())),
            child: const Text('登录 / 注册'),
          )
        else
          OutlinedButton(
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const LoginPage())),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('退出登录'),
          ),
        const SizedBox(height: 8),
        _row(context, Icons.collections_bookmark_outlined, '我的书架',
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ShelfPage()))),
        _row(context, Icons.history_rounded, '云端阅读历史(网页同步)',
            () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('云端阅读历史')),
                          body: const CloudHistoryTab(),
                        )))),
        _row(context, Icons.dynamic_feed_outlined, '动态广场',
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DynamicPage()))),
        _row(context, Icons.chat_bubble_outline, '消息中心 / 私信',
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MessagesPage()))),
        _row(context, Icons.card_giftcard, '福利中心',
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WelfarePage()))),
        _row(context, Icons.settings_outlined, '设置与资料',
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()))),
        _row(context, Icons.edit_note_outlined, '书评示例',
            () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const CommentsPage(bookId: 9031, bookTitle: '示例')))),
      ],
    );
  }

  Widget _row(BuildContext context, IconData icon, String title, VoidCallback onTap) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
