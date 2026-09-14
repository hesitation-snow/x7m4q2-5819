import '../services/app_motion.dart';
import '../widgets/account_scope.dart';
import '../widgets/scrollable_status.dart';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../services/avatar_cache.dart';
import '../widgets/common.dart';
import 'user_profile_page.dart';

/// 关注与粉丝列表，支持用户主页跳转和关注操作。
class FollowListPage extends StatelessWidget {
  const FollowListPage({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  Widget build(BuildContext context) => AccountScope(
        title: '关注与粉丝',
        builder: (_) => _FollowListPageBody(initialTab: initialTab),
      );
}

class _FollowListPageBody extends StatefulWidget {
  final int initialTab;

  const _FollowListPageBody({this.initialTab = 0});

  @override
  State<_FollowListPageBody> createState() => _FollowListPageState();
}

class _FollowListPageState extends State<_FollowListPageBody>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _following = <LKFollowUser>[];
  final _followers = <LKFollowUser>[];
  int _followingPage = 0;
  int _followersPage = 0;
  int _followingTotal = 0;
  int _followersTotal = 0;
  bool _followingHasMore = true;
  bool _followersHasMore = true;
  bool _followingLoading = false;
  bool _followersLoading = false;
  String? _followingError;
  String? _followersError;
  final Set<int> _followActionUids = <int>{};
  final _session = SessionStamp();
  final Map<int, bool> _followOverrides = {};
  final Map<int, LKFollowUser> _changedUsers = {};
  int _relationRevision = 0;

  @override
  void initState() {
    super.initState();
    LKClient.followChanged.addListener(_onFollowChanged);
    _tabs = MotionTabController(
        length: 2, initialIndex: widget.initialTab == 1 ? 1 : 0, vsync: this);
    _loadFollowing(reset: true);
    _loadFollowers(reset: true);
  }

  @override
  void dispose() {
    LKClient.followChanged.removeListener(_onFollowChanged);
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadFollowing({bool reset = false}) async {
    if (!LKClient.shared.session.isLoggedIn || _followingLoading) return;
    if (!reset && !_followingHasMore) return;
    final page = reset ? 1 : _followingPage + 1;
    final revision = _relationRevision;
    if (mounted && _session.isCurrent) {
      setState(() {
        _followingLoading = true;
        _followingError = null;
      });
    }
    try {
      final result = await LKApi.myFollowing(page);
      if (!mounted || !_session.isCurrent) return;
      YomiruAvatarCache.precache(
          context, result.items.map((item) => item.avatar));
      setState(() {
        if (reset) _following.clear();
        _appendUnique(
            _following,
            result.items
                .where((user) => _followOverrides[user.uid] != false)
                .toList());
        _appendUnique(
            _following,
            _changedUsers.values
                .where((user) => _followOverrides[user.uid] == true)
                .toList());
        _followingPage = result.page;
        if (revision == _relationRevision) _followingTotal = result.total;
        if (_followingTotal < _following.length) {
          _followingTotal = _following.length;
        }
        _followingHasMore = result.hasMore && result.items.isNotEmpty;
        _followingError = null;
      });
    } catch (e) {
      if (mounted && _session.isCurrent) {
        setState(() => _followingError = _friendlyError(e));
      }
    } finally {
      if (mounted && _session.isCurrent) {
        setState(() => _followingLoading = false);
      }
    }
  }

  Future<void> _loadFollowers({bool reset = false}) async {
    if (!LKClient.shared.session.isLoggedIn || _followersLoading) return;
    if (!reset && !_followersHasMore) return;
    final page = reset ? 1 : _followersPage + 1;
    if (mounted && _session.isCurrent) {
      setState(() {
        _followersLoading = true;
        _followersError = null;
      });
    }
    try {
      final result = await LKApi.myFollowers(page);
      if (!mounted || !_session.isCurrent) return;
      YomiruAvatarCache.precache(
          context, result.items.map((item) => item.avatar));
      setState(() {
        if (reset) _followers.clear();
        _appendUnique(
            _followers,
            result.items
                .map((user) => user.copyWith(
                    followed: _followOverrides[user.uid] ?? user.followed))
                .toList());
        _followersPage = result.page;
        _followersTotal = result.total;
        _followersHasMore = result.hasMore && result.items.isNotEmpty;
        _followersError = null;
      });
    } catch (e) {
      if (mounted && _session.isCurrent) {
        setState(() => _followersError = _friendlyError(e));
      }
    } finally {
      if (mounted && _session.isCurrent) {
        setState(() => _followersLoading = false);
      }
    }
  }

  void _appendUnique(List<LKFollowUser> target, List<LKFollowUser> items) {
    final existing = target.map((e) => e.uid).toSet();
    for (final item in items) {
      if (item.uid > 0 && existing.add(item.uid)) target.add(item);
    }
  }

  Future<void> _refresh() async {
    if (_followingLoading || _followersLoading) return;
    // An explicit refresh may reflect changes made from another device.
    _followOverrides.clear();
    _changedUsers.clear();
    _relationRevision++;
    await Future.wait([
      _loadFollowing(reset: true),
      _loadFollowers(reset: true),
    ]);
  }

  void _onFollowChanged() {
    final change = LKClient.followChanged.value;
    if (!mounted ||
        !_session.isCurrent ||
        change == null ||
        change.viewerUid != _session.uid ||
        _followActionUids.contains(change.targetUid)) {
      return;
    }
    final users = [..._following, ..._followers];
    final index = users.indexWhere((user) => user.uid == change.targetUid);
    if (index < 0) {
      _refresh();
      return;
    }
    final user = users[index];
    final wasFollowed = _followOverrides[user.uid] ??
        (_following.any((item) => item.uid == user.uid) || user.followed);
    if (wasFollowed == change.followed) return;
    setState(() {
      _relationRevision++;
      _followOverrides[user.uid] = change.followed;
      _changedUsers[user.uid] = user.copyWith(followed: change.followed);
      for (var i = 0; i < _followers.length; i++) {
        if (_followers[i].uid == user.uid) {
          _followers[i] = _followers[i].copyWith(followed: change.followed);
        }
      }
      _following.removeWhere((item) => item.uid == user.uid);
      if (change.followed) _following.insert(0, user.copyWith(followed: true));
      _followingTotal =
          (_followingTotal + (change.followed ? 1 : -1)).clamp(0, 1 << 31);
    });
  }

  Future<void> _toggleFollow(LKFollowUser user, bool following) async {
    if (!_session.isCurrent ||
        user.uid <= 0 ||
        _followActionUids.contains(user.uid)) {
      return;
    }
    setState(() => _followActionUids.add(user.uid));
    try {
      await LKApi.toggleFollow(user.uid, !following);
      if (!mounted || !_session.isCurrent) return;
      setState(() {
        _relationRevision++;
        _followOverrides[user.uid] = !following;
        _changedUsers[user.uid] = user.copyWith(followed: !following);
        final fanIndex = _followers.indexWhere((item) => item.uid == user.uid);
        if (fanIndex >= 0) {
          _followers[fanIndex] =
              _followers[fanIndex].copyWith(followed: !following);
        }
        if (following) {
          _following.removeWhere((item) => item.uid == user.uid);
          if (_followingTotal > 0) _followingTotal--;
        } else {
          if (!_following.any((item) => item.uid == user.uid)) {
            _following.insert(0, user.copyWith(followed: true));
          }
          _followingTotal++;
        }
      });
      showFloatingPrompt(context, following ? '已取消关注' : '已关注');
    } catch (e) {
      if (mounted && _session.isCurrent) {
        showFloatingPrompt(context, '操作失败：$e');
      }
    } finally {
      if (mounted && _session.isCurrent) {
        setState(() => _followActionUids.remove(user.uid));
      }
    }
  }

  String _friendlyError(Object error) {
    if (error is LKException && error.code == 8) return '登录状态已失效，请重新登录';
    return '加载失败，请点击重试';
  }

  @override
  Widget build(BuildContext context) {
    if (!LKClient.shared.session.isLoggedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('关注与粉丝')),
        body: const Center(child: Text('登录后才能查看关注与粉丝')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('关注与粉丝'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _followingLoading || _followersLoading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: '关注 ${_followingTotal > 0 ? _followingTotal : ''}'),
            Tab(text: '粉丝 ${_followersTotal > 0 ? _followersTotal : ''}'),
          ],
        ),
      ),
      body: MotionRefreshIndicator(
        onRefresh: _refresh,
        child: TabBarView(
          physics: AppMotion.isDisabled(context)
              ? const NeverScrollableScrollPhysics()
              : null,
          controller: _tabs,
          children: [
            _buildList(
              items: _following,
              followingTab: true,
              loading: _followingLoading,
              hasMore: _followingHasMore,
              error: _followingError,
              onRetry: () => _loadFollowing(reset: true),
              onLoadMore: () => _loadFollowing(),
            ),
            _buildList(
              items: _followers,
              followingTab: false,
              loading: _followersLoading,
              hasMore: _followersHasMore,
              error: _followersError,
              onRetry: () => _loadFollowers(reset: true),
              onLoadMore: () => _loadFollowers(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList({
    required List<LKFollowUser> items,
    required bool followingTab,
    required bool loading,
    required bool hasMore,
    required String? error,
    required VoidCallback onRetry,
    required VoidCallback onLoadMore,
  }) {
    if (loading && items.isEmpty) {
      return const ScrollableStatus(child: LkLoadingIndicator());
    }
    if (error != null && items.isEmpty) {
      return ScrollableStatus(
        child: FilledButton.tonal(
          onPressed: onRetry,
          child: Text(error),
        ),
      );
    }
    if (items.isEmpty) {
      return const ScrollableStatus(child: Text('这里暂时没有用户'));
    }
    final showLoadMore = hasMore || loading || error != null;
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.paddingOf(context).bottom + 16,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: items.length + (showLoadMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == items.length) {
          if (error != null) {
            return Center(
                child: TextButton(
              onPressed: onLoadMore,
              child: const Text('加载失败，点击重试'),
            ));
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _session.isCurrent && !loading) onLoadMore();
          });
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: LkLoadingIndicator()),
          );
        }
        return _userTile(items[index], followingTab: followingTab);
      },
    );
  }

  Widget _userTile(LKFollowUser user, {required bool followingTab}) {
    final subtitle = <String>[];
    if (user.levelName.isNotEmpty) subtitle.add(user.levelName);
    if (user.isBrave) subtitle.add('勇者');
    if (user.signature.isNotEmpty) subtitle.add(user.signature);
    final following = followingTab || user.followed;
    final busy = _followActionUids.contains(user.uid);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: theme.cardTheme.color ?? colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        tileColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        horizontalTitleGap: 12,
        leading: CircleAvatar(
          radius: 24,
          backgroundImage: YomiruAvatarCache.providerOrNull(user.avatar),
          child: YomiruAvatarCache.providerOrNull(user.avatar) == null
              ? const Icon(Icons.person_outline)
              : null,
        ),
        title: Text(
          user.nickname.isEmpty ? '未知用户' : user.nickname,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle.isEmpty ? '暂无签名' : subtitle.join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        trailing: user.uid <= 0
            ? null
            : FilledButton.tonal(
                onPressed: busy ? null : () => _toggleFollow(user, following),
                style: FilledButton.styleFrom(
                  backgroundColor: following
                      ? colors.surfaceContainerHighest
                      : colors.secondaryContainer,
                  foregroundColor: following
                      ? colors.onSurfaceVariant
                      : colors.onSecondaryContainer,
                  minimumSize: const Size(76, 36),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: const StadiumBorder(),
                ),
                child: Text(busy
                    ? '处理中'
                    : following
                        ? '已关注'
                        : '关注'),
              ),
        onTap: user.uid > 0 ? () => openUserProfile(context, user.uid) : null,
      ),
    );
  }
}
