import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/store.dart';
import '../services/avatar_cache.dart';
import '../widgets/common.dart';
import 'book_detail_page.dart';
import 'media_viewer_page.dart';
import 'search_page.dart';

void openUserProfile(BuildContext context, int uid) {
  if (uid <= 0) return;
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => UserProfilePage(uid: uid)),
  );
}

class UserProfilePage extends StatefulWidget {
  final int uid;

  const UserProfilePage({super.key, required this.uid});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  LKPublicUserPage? _home;
  Map<int, List<LKMedal>> _globalMedals = const {};
  LKPublicBookshelfPage? _bookshelf;
  final _dynamics = <LKDynamicItem>[];
  String _dynamicCursor = '';
  bool _dynamicLoading = false;
  bool _publicationLoading = false;
  bool _bookshelfLoading = false;
  bool _dynamicHasMore = true;
  bool _followed = false;
  bool _followBusy = false;
  int _followersCount = 0;
  String? _error;
  String? _dynamicError;
  String? _bookshelfError;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(_onTabChanged);
    _loadGlobalMedals();
    _loadInitial();
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging || _tabs.index != 0 || _dynamics.isNotEmpty) {
      return;
    }
    _loadDynamics();
  }

  Future<void> _loadGlobalMedals() async {
    final cached = await LKStore.cachedGlobalMedals();
    if (!mounted || cached.isEmpty) return;
    setState(() => _globalMedals = cached);
  }

  Future<void> _loadInitial({bool forceRefresh = false}) async {
    if (mounted) {
      setState(() {
        _error = null;
      });
    }
    try {
      final home = await LKApi.publicUserHome(widget.uid, 1,
          pageSize: 20, forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _home = home;
        _followed = home.profile.followed;
        _followersCount = home.profile.followersCount;
        _error = null;
        if (!home.profile.publicBookshelf) _bookshelf = null;
      });
      if (mounted) {
        YomiruAvatarCache.precache(context, [home.profile.avatar]);
      }
      if (home.profile.medals.isNotEmpty) {
        unawaited(LKStore.cacheGlobalMedals({
          home.profile.uid > 0 ? home.profile.uid : widget.uid:
              home.profile.medals,
        }));
      }
      final pending = <Future<void>>[_loadDynamics()];
      if (home.profile.publicBookshelf) {
        pending.add(_loadInitialBookshelf());
      }
      await Future.wait(pending);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '用户主页加载失败，请点击重试';
        });
      }
    }
  }

  Future<void> _loadInitialBookshelf() async {
    try {
      final bookshelf =
          await LKApi.publicUserBookshelf(widget.uid, 1, pageSize: 20);
      if (!mounted) return;
      setState(() {
        _bookshelf = bookshelf;
        _bookshelfError = null;
      });
    } catch (_) {
      if (mounted) setState(() => _bookshelfError = '书架无法加载，请点击重试');
    }
  }

  Future<void> _loadDynamics({bool append = false}) async {
    if (_dynamicLoading || append && !_dynamicHasMore) return;
    if (mounted) {
      setState(() {
        _dynamicLoading = true;
        if (!append) _dynamicError = null;
      });
    }
    try {
      final result = await LKApi.publicUserDynamics(
        widget.uid,
        cursor: append ? _dynamicCursor : '',
        pageSize: 20,
      );
      if (!mounted) return;
      YomiruAvatarCache.precache(
          context, result.items.map((item) => item.avatar));
      setState(() {
        if (!append) _dynamics.clear();
        _dynamics.addAll(result.items);
        _dynamicCursor = result.cursor;
        _dynamicHasMore = result.hasMore;
        _dynamicError = null;
      });
    } catch (_) {
      if (mounted) setState(() => _dynamicError = '动态无法加载，请点击重试');
    } finally {
      if (mounted) setState(() => _dynamicLoading = false);
    }
  }

  Future<void> _loadMorePublications() async {
    final home = _home;
    if (home == null || _publicationLoading || !home.hasMore) return;
    setState(() => _publicationLoading = true);
    try {
      final next = await LKApi.publicUserHome(widget.uid, home.page + 1,
          pageSize: home.pageSize);
      if (!mounted) return;
      setState(() {
        _home = LKPublicUserPage(
          profile: home.profile,
          publications: [...home.publications, ...next.publications],
          page: next.page,
          pageSize: next.pageSize,
          total: next.total,
          hasMore: next.hasMore,
        );
      });
    } finally {
      if (mounted) setState(() => _publicationLoading = false);
    }
  }

  Future<void> _loadMoreBookshelf() async {
    final bookshelf = _bookshelf;
    if (bookshelf == null || _bookshelfLoading || !bookshelf.hasMore) return;
    setState(() => _bookshelfLoading = true);
    try {
      final next = await LKApi.publicUserBookshelf(
          widget.uid, bookshelf.page + 1,
          pageSize: bookshelf.pageSize);
      if (!mounted) return;
      setState(() {
        _bookshelf = LKPublicBookshelfPage(
          visible: bookshelf.visible,
          books: [...bookshelf.books, ...next.books],
          page: next.page,
          pageSize: next.pageSize,
          total: next.total,
          hasMore: next.hasMore,
        );
        _bookshelfError = null;
      });
    } catch (_) {
      if (mounted) setState(() => _bookshelfError = '书架无法加载，请点击重试');
    } finally {
      if (mounted) setState(() => _bookshelfLoading = false);
    }
  }

  Future<void> _refresh() async {
    _dynamicCursor = '';
    _dynamicHasMore = true;
    _bookshelfError = null;
    await _loadInitial(forceRefresh: true);
  }

  bool _canShowFollow(LKPublicUserProfile profile) {
    final session = LKClient.shared.session;
    final targetUid = profile.uid > 0 ? profile.uid : widget.uid;
    return session.isLoggedIn &&
        targetUid > 0 &&
        targetUid != session.uid &&
        !profile.isSelf &&
        (profile.canFollow || _followed);
  }

  Future<void> _toggleFollow() async {
    if (_followBusy) return;
    final profile = _home?.profile;
    if (profile == null || !_canShowFollow(profile)) return;
    final targetUid = profile.uid > 0 ? profile.uid : widget.uid;
    final follow = !_followed;
    setState(() => _followBusy = true);
    try {
      await LKApi.toggleFollow(targetUid, follow);
      if (!mounted) return;
      setState(() {
        _followed = follow;
        _followersCount =
            (_followersCount + (follow ? 1 : -1)).clamp(0, 1 << 31);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(follow ? '已关注' : '已取消关注')),
      );
    } catch (e) {
      if (mounted) showLkError(context, '操作失败：$e');
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_home == null && _error == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('用户主页')),
        body: _buildProfileLoadingSkeleton(),
      );
    }
    if (_home == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('用户主页')),
        body: Center(
          child: FilledButton.tonal(
            onPressed: _loadInitial,
            child: Text(_error ?? '用户主页加载失败，请重试'),
          ),
        ),
      );
    }
    final profile = _home!.profile;
    return Scaffold(
      appBar: AppBar(
        title: Text(profile.nickname.isEmpty ? '用户主页' : profile.nickname),
        actions: [
          if (_canShowFollow(profile))
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: _followBusy ? null : _toggleFollow,
                child: _followBusy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_followed ? '取消关注' : '关注'),
              ),
            ),
        ],
      ),
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(child: _buildProfileHeader(profile)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _ProfileTabsHeader(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              tabBar: TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: '动态'),
                  Tab(text: '公开发布'),
                  Tab(text: '公开书架'),
                ],
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabs,
          children: [
            _buildDynamicTab(),
            _buildPublicationTab(),
            _buildBookshelfTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileLoadingSkeleton() {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.surfaceContainerHighest;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(radius: 32, backgroundColor: muted),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                              height: 20,
                              width: 150,
                              decoration: BoxDecoration(
                                  color: muted,
                                  borderRadius: BorderRadius.circular(6))),
                          const SizedBox(height: 8),
                          Container(
                              height: 14,
                              width: 100,
                              decoration: BoxDecoration(
                                  color: muted,
                                  borderRadius: BorderRadius.circular(5))),
                          const SizedBox(height: 10),
                          Container(
                              height: 24,
                              width: 210,
                              decoration: BoxDecoration(
                                  color: muted,
                                  borderRadius: BorderRadius.circular(12))),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: List.generate(
                    3,
                    (_) => Expanded(
                      child: Container(
                          height: 34,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                              color: muted,
                              borderRadius: BorderRadius.circular(6))),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: SizedBox(
            height: 48,
            child:
                Center(child: LinearProgressIndicator(color: scheme.primary)),
          ),
        ),
        const SizedBox(height: 10),
        const Card(
          child: SizedBox(
            height: 180,
            child: Center(child: LkLoadingIndicator()),
          ),
        ),
      ],
    );
  }

  Widget _buildProfileHeader(LKPublicUserProfile profile) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = profile.avatar;
    final medals = (profile.medals.isNotEmpty
            ? profile.medals
            : (_globalMedals[profile.uid > 0 ? profile.uid : widget.uid] ??
                const <LKMedal>[]))
        .take(5)
        .toList();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: scheme.surfaceContainerHighest,
                  backgroundImage: avatar.isNotEmpty
                      ? YomiruAvatarCache.provider(avatar)
                      : null,
                  child: avatar.isEmpty
                      ? Icon(Icons.person,
                          size: 32, color: scheme.onSurfaceVariant)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.nickname.isEmpty ? '未知用户' : profile.nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 20,
                            fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text('UID: ${profile.uid > 0 ? profile.uid : widget.uid}',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _heroChip(profile.levelName.isEmpty
                              ? '用户'
                              : profile.levelName),
                          if (profile.isBrave) _heroChip('勇者'),
                          ...medals.map((medal) => Tooltip(
                                message: medal.name,
                                child: GestureDetector(
                                  onTap: () => _showMedalName(medal.name),
                                  child: CircleAvatar(
                                    radius: 16,
                                    backgroundColor:
                                        scheme.surfaceContainerHighest,
                                    backgroundImage: medal.image.isNotEmpty
                                        ? YomiruMedalCache.provider(medal.image)
                                        : null,
                                    child: medal.image.isEmpty
                                        ? Icon(Icons.military_tech,
                                            size: 18,
                                            color: scheme.onSurfaceVariant)
                                        : null,
                                  ),
                                ),
                              )),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (profile.signature.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(profile.signature,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                _stat('粉丝', _followersCount),
                _stat('关注', profile.followingCount),
                _stat('发布', profile.postCount),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showMedalName(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(name.isEmpty ? '未知勋章' : name)),
    );
  }

  Widget _heroChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontSize: 12)),
      );

  Widget _stat(String label, int value) => Expanded(
        child: Column(
          children: [
            Text('$value',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _buildDynamicTab() {
    if (_dynamicLoading && _dynamics.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: _dynamics.isEmpty
          ? _emptyList(_dynamicError ?? '暂无公开动态',
              onRetry: _dynamicError == null ? null : _loadDynamics)
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _dynamics.length + (_dynamicHasMore ? 1 : 0),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, index) {
                if (index == _dynamics.length) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _loadDynamics(append: true);
                  });
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: LkLoadingIndicator()),
                  );
                }
                return _dynamicTile(_dynamics[index]);
              },
            ),
    );
  }

  Widget _dynamicTile(LKDynamicItem item) {
    final hasBook = item.bookId > 0 && item.bookTitle.isNotEmpty;
    final medals = item.authorMedals.isNotEmpty
        ? item.authorMedals
        : (_globalMedals[item.authorUid] ?? const <LKMedal>[]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: item.dynamicId > 0
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CommentsPage(
                        dynamicId: item.dynamicId,
                        dynamicPreview: item,
                      ),
                    ),
                  )
              : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: item.authorUid > 0
                          ? () => openUserProfile(context, item.authorUid)
                          : null,
                      child: CircleAvatar(
                        radius: 18,
                        backgroundImage: item.avatar.isNotEmpty
                            ? YomiruAvatarCache.provider(item.avatar)
                            : null,
                        child: item.avatar.isEmpty
                            ? const Icon(Icons.person_outline, size: 20)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Wrap(
                        spacing: 5,
                        runSpacing: 3,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          GestureDetector(
                            onTap: item.authorUid > 0
                                ? () => openUserProfile(context, item.authorUid)
                                : null,
                            child: Text(
                              item.nickname.isEmpty
                                  ? '用户 ${item.authorUid}'
                                  : item.nickname,
                              style: TextStyle(
                                  color: Colors.indigo.shade400, fontSize: 13),
                            ),
                          ),
                          ...medals.take(5).map(
                                (medal) => Tooltip(
                                  message: medal.name,
                                  child: GestureDetector(
                                    onTap: () => _showMedalName(medal.name),
                                    child: CircleAvatar(
                                      radius: 10,
                                      backgroundColor: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      backgroundImage: medal.image.isNotEmpty
                                          ? YomiruMedalCache.provider(
                                              medal.image)
                                          : null,
                                      child: medal.image.isEmpty
                                          ? const Icon(Icons.military_tech,
                                              size: 12)
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                          if (item.eventType.isNotEmpty)
                            _eventChip(_eventLabel(item.eventType)),
                        ],
                      ),
                    ),
                  ],
                ),
                if (item.summary.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(item.summary),
                ],
                if (hasBook)
                  InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => BookDetailPage(bookId: item.bookId)),
                    ),
                    child: Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          CoverImage(
                              url: item.bookCover, width: 40, height: 54),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text(item.bookTitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                  ),
                _mediaGallery(item.media),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text('赞 ${item.likeCount} · 评论 ${item.commentCount}',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500)),
                    const Spacer(),
                    Text(_shortTime(item.time),
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade400)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _eventChip(String text) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
        borderRadius: BorderRadius.circular(4),
      ),
      child:
          Text(text, style: const TextStyle(fontSize: 10, color: Colors.white)),
    );
  }

  double _previewRatio(LKDynamicMedia media) {
    if (media.width <= 0 || media.height <= 0) return 1.45;
    return (media.width / media.height).clamp(0.65, 1.8).toDouble();
  }

  Widget _mediaGallery(List<LKDynamicMedia> media) {
    final visible = media.where((item) => item.url.isNotEmpty).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          Widget image(LKDynamicMedia item, {double? width, double? height}) {
            return GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => MediaViewerPage(url: item.url)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: CachedNetworkImage(
                  imageUrl: item.url,
                  width: width,
                  height: height,
                  memCacheWidth: width == null
                      ? null
                      : imageCacheDimension(context, width),
                  fit: BoxFit.cover,
                  placeholder: (_, __) => ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Center(child: LkLoadingIndicator(size: 20)),
                  ),
                  errorWidget: (_, __, ___) => ColoredBox(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child:
                        const Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
            );
          }

          if (visible.length == 1) {
            final item = visible.first;
            final height = (constraints.maxWidth / _previewRatio(item))
                .clamp(140.0, 280.0)
                .toDouble();
            return image(item, width: constraints.maxWidth, height: height);
          }
          final size = (constraints.maxWidth - 12) / 3;
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            children: visible
                .map((item) => image(item, width: size, height: size))
                .toList(),
          );
        },
      ),
    );
  }

  String _eventLabel(String value) {
    return dynamicEventLabel(value);
  }

  Widget _buildPublicationTab() {
    final publications = _home!.publications;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: publications.isEmpty
          ? _emptyList('暂无公开发布')
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: publications.length + (_home!.hasMore ? 1 : 0),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, index) {
                if (index == publications.length) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _loadMorePublications();
                  });
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: LkLoadingIndicator()),
                  );
                }
                return _bookTile(publications[index]);
              },
            ),
    );
  }

  Widget _buildBookshelfTab() {
    final shelf = _bookshelf;
    if (_bookshelfError != null && shelf == null) {
      return RefreshIndicator(
        onRefresh: _loadInitial,
        child: _emptyList(_bookshelfError!, onRetry: _loadInitial),
      );
    }
    if (shelf == null || !shelf.visible) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: _emptyList('该用户未公开书架'),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: shelf.books.isEmpty
          ? _emptyList('公开书架暂无作品')
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: shelf.books.length + (shelf.hasMore ? 1 : 0),
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, index) {
                if (index == shelf.books.length) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _loadMoreBookshelf();
                  });
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: LkLoadingIndicator()),
                  );
                }
                return _bookTile(shelf.books[index]);
              },
            ),
    );
  }

  Widget _bookTile(LKPublicBook book) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CoverImage(url: book.coverUrl, width: 48, height: 64),
      title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [book.typeText, _shortTime(book.updatedAt)]
            .where((e) => e.isNotEmpty)
            .join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: book.bookId > 0
          ? () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => BookDetailPage(bookId: book.bookId)),
              )
          : null,
    );
  }

  Widget _emptyList(String text, {VoidCallback? onRetry}) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 150),
        Center(child: Text(text, style: const TextStyle(color: Colors.grey))),
        if (onRetry != null)
          Center(
            child: TextButton(onPressed: onRetry, child: const Text('重试')),
          ),
      ],
    );
  }

  String _shortTime(String value) {
    if (value.length > 16) return value.substring(0, 16).replaceAll('T', ' ');
    return value;
  }
}

class _ProfileTabsHeader extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  final Color backgroundColor;

  const _ProfileTabsHeader({
    required this.tabBar,
    required this.backgroundColor,
  });

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return ColoredBox(color: backgroundColor, child: tabBar);
  }

  @override
  bool shouldRebuild(covariant _ProfileTabsHeader oldDelegate) =>
      oldDelegate.tabBar.controller != tabBar.controller ||
      oldDelegate.backgroundColor != backgroundColor;
}
