import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/lk_api.dart';
import '../api/models.dart';
import '../services/avatar_cache.dart';
import '../widgets/common.dart';
import 'book_detail_page.dart';
import 'dm_chat_page.dart';
import 'reader_page.dart';
import 'search_page.dart';
import 'user_profile_page.dart';

class _MessageCategory {
  final String type;
  final String label;
  final IconData icon;

  const _MessageCategory(this.type, this.label, this.icon);
}

const _messageCategories = <_MessageCategory>[
  _MessageCategory('reply', '回复', Icons.reply_outlined),
  _MessageCategory('mention', '提及', Icons.alternate_email),
  _MessageCategory('like', '点赞', Icons.favorite_border),
  _MessageCategory('fan', '关注', Icons.person_add_alt_1_outlined),
  _MessageCategory('system', '系统', Icons.notifications_none),
  _MessageCategory('dm', '私信', Icons.mail_outline),
];

class _NotificationFeedData {
  List<LKMessageItem> items = const [];
  int page = 0;
  bool hasMore = true;
  bool loading = false;
  bool refreshing = false;
  bool loadingMore = false;
  bool markedRead = false;
  bool markingRead = false;
  Object? error;
  Object? loadMoreError;
  int requestSerial = 0;
}

/// 消息中心。通知分类和私信会话分别加载，切换分类时保留已取得的数据。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final Map<String, _NotificationFeedData> _feeds;
  int _activeIndex = 0;
  LKMessageSummary _summary = const LKMessageSummary();
  bool _summaryLoading = false;
  bool _markingAll = false;
  int _summaryMutationSerial = 0;

  List<LKConversation> _conversations = const [];
  bool _dmLoading = false;
  Object? _dmError;
  int _dmRequestSerial = 0;

  @override
  void initState() {
    super.initState();
    _feeds = {
      for (final category in _messageCategories.take(5))
        category.type: _NotificationFeedData(),
    };
    _tabs = TabController(length: _messageCategories.length, vsync: this)
      ..addListener(_handleTabChanged);
    unawaited(_loadSummary());
    unawaited(_loadNotification(_messageCategories.first.type));
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_handleTabChanged)
      ..dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    final next = _tabs.index;
    if (next == _activeIndex) return;
    setState(() => _activeIndex = next);
    final type = _messageCategories[next].type;
    if (type == 'dm') {
      if (_conversations.isEmpty && !_dmLoading) unawaited(_loadDm());
    } else {
      final feed = _feeds[type]!;
      if (feed.items.isEmpty && !feed.loading) {
        unawaited(_loadNotification(type));
      } else if (_summary.countFor(type) > 0 && !feed.markedRead) {
        unawaited(_markCategoryRead(type));
      }
    }
  }

  Future<void> _loadSummary() async {
    if (_summaryLoading) return;
    final mutationAtStart = _summaryMutationSerial;
    setState(() => _summaryLoading = true);
    try {
      final summary = await LKApi.messageUnread();
      if (!mounted) return;
      if (mutationAtStart != _summaryMutationSerial) return;
      setState(() => _summary = summary);
      final type = _messageCategories[_activeIndex].type;
      final feed = _feeds[type];
      if (feed != null &&
          feed.page > 0 &&
          summary.countFor(type) > 0 &&
          !feed.markedRead) {
        unawaited(_markCategoryRead(type));
      }
    } catch (_) {
      // 各分类仍可独立使用，未读汇总失败不遮挡消息列表。
    } finally {
      if (mounted) setState(() => _summaryLoading = false);
    }
  }

  Future<void> _loadNotification(String type, {bool loadMore = false}) async {
    final feed = _feeds[type]!;
    if (loadMore) {
      if (feed.loading ||
          feed.refreshing ||
          feed.loadingMore ||
          !feed.hasMore) {
        return;
      }
    } else {
      if (feed.loading || feed.refreshing) return;
      // A user refresh takes precedence over an in-flight append request.
      if (feed.loadingMore) {
        feed.requestSerial++;
        feed.loadingMore = false;
      }
    }

    final page = loadMore ? feed.page + 1 : 1;
    final request = ++feed.requestSerial;
    setState(() {
      if (loadMore) {
        feed.loadingMore = true;
        feed.loadMoreError = null;
      } else {
        feed.loading = feed.items.isEmpty;
        feed.refreshing = feed.items.isNotEmpty;
        feed.error = null;
      }
    });

    try {
      final result = await LKApi.messages(type, page);
      if (!mounted || request != feed.requestSerial) return;
      setState(() {
        feed.items =
            loadMore ? _mergeMessages(feed.items, result.items) : result.items;
        feed.page = page;
        feed.hasMore = result.hasMore && result.items.isNotEmpty;
        feed.error = null;
        feed.loadMoreError = null;
      });
      if (page == 1 &&
          !feed.markedRead &&
          _messageCategories[_activeIndex].type == type &&
          (_summary.countFor(type) > 0 ||
              result.items.any((item) => item.unread))) {
        unawaited(_markCategoryRead(type));
      }
    } catch (error) {
      if (!mounted || request != feed.requestSerial) return;
      setState(() {
        if (loadMore) {
          feed.loadMoreError = error;
        } else {
          feed.error = error;
        }
      });
    } finally {
      if (mounted && request == feed.requestSerial) {
        setState(() {
          feed.loading = false;
          feed.refreshing = false;
          feed.loadingMore = false;
        });
      }
    }
  }

  List<LKMessageItem> _mergeMessages(
      List<LKMessageItem> current, List<LKMessageItem> incoming) {
    final result = <LKMessageItem>[];
    final seen = <String>{};
    for (final item in [...current, ...incoming]) {
      if (seen.add(_messageKey(item))) result.add(item);
    }
    return result;
  }

  String _messageKey(LKMessageItem item) => item.id > 0
      ? '${item.type}:${item.id}'
      : '${item.type}:${item.time}:${item.uid}:${item.content}';

  Future<void> _markCategoryRead(String type) async {
    final feed = _feeds[type]!;
    if (feed.markedRead || feed.markingRead) return;
    feed.markingRead = true;
    try {
      await LKApi.markMessagesRead('category', category: type);
      if (!mounted) return;
      setState(() {
        _summaryMutationSerial++;
        feed.markedRead = true;
        _summary = _summary.clearCategory(type);
      });
    } catch (_) {
      // 已读同步失败时保留未读数，下次进入仍会重试。
    } finally {
      feed.markingRead = false;
    }
  }

  Future<void> _markAllNotificationsRead() async {
    if (_markingAll) return;
    setState(() => _markingAll = true);
    try {
      await LKApi.markMessagesRead('all');
      if (!mounted) return;
      setState(() {
        _summaryMutationSerial++;
        _summary = _summary.clearNotifications();
        for (final feed in _feeds.values) {
          feed.markedRead = true;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('通知已全部标记为已读')),
      );
    } catch (error) {
      if (mounted) showLkError(context, error);
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  Future<void> _loadDm() async {
    if (_dmLoading) return;
    final request = ++_dmRequestSerial;
    setState(() {
      _dmLoading = true;
      _dmError = null;
    });
    try {
      final conversations = await LKApi.dmConversations();
      if (!mounted || request != _dmRequestSerial) return;
      setState(() => _conversations = conversations);
    } catch (error) {
      if (!mounted || request != _dmRequestSerial) return;
      setState(() => _dmError = error);
    } finally {
      if (mounted && request == _dmRequestSerial) {
        setState(() => _dmLoading = false);
      }
    }
  }

  Future<void> _refreshActive() async {
    final type = _messageCategories[_activeIndex].type;
    if (type == 'dm') {
      await Future.wait<void>([_loadDm(), _loadSummary()]);
    } else {
      await Future.wait<void>([
        _loadNotification(type),
        _loadSummary(),
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = _messageCategories[_activeIndex].type;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('消息中心'),
            if (_summary.unreadCount > 0) ...[
              const SizedBox(width: 8),
              Badge(label: Text('${_summary.unreadCount}')),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: '通知全部已读',
            onPressed: _markingAll ? null : _markAllNotificationsRead,
            icon: _markingAll
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.done_all_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [for (final category in _messageCategories) _tab(category)],
        ),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: KeyedSubtree(
          key: ValueKey(type),
          child: type == 'dm' ? _buildDmBody() : _buildNotificationBody(type),
        ),
      ),
    );
  }

  Widget _tab(_MessageCategory category) {
    final feed = _feeds[category.type];
    final count = category.type == 'dm'
        ? _summary.dmCount
        : (feed?.markedRead == true ? 0 : _summary.countFor(category.type));
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(category.icon, size: 18),
          const SizedBox(width: 5),
          Text(category.label),
          if (count > 0) ...[
            const SizedBox(width: 5),
            Badge(label: Text(count > 99 ? '99+' : '$count')),
          ],
        ],
      ),
    );
  }

  Widget _buildNotificationBody(String type) {
    final feed = _feeds[type]!;
    if (feed.loading && feed.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (feed.error != null && feed.items.isEmpty) {
      return _refreshableState(
        icon: Icons.cloud_off_outlined,
        title: '消息加载失败',
        detail: feed.error.toString(),
        onRefresh: _refreshActive,
      );
    }
    if (feed.items.isEmpty) {
      return _refreshableState(
        icon: Icons.mark_email_read_outlined,
        title:
            '暂时没有${_messageCategories.firstWhere((e) => e.type == type).label}消息',
        onRefresh: _refreshActive,
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 360 &&
            feed.hasMore &&
            !feed.loadingMore) {
          unawaited(_loadNotification(type, loadMore: true));
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: _refreshActive,
        child: ListView.builder(
          key: PageStorageKey<String>('messages-$type'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
              10, 8, 10, MediaQuery.paddingOf(context).bottom + 12),
          itemCount: feed.items.length + 1,
          itemBuilder: (context, index) {
            if (index == feed.items.length) {
              return _messageFooter(type, feed);
            }
            return _messageCard(feed.items[index], feed.markedRead);
          },
        ),
      ),
    );
  }

  Widget _messageFooter(String type, _NotificationFeedData feed) {
    if (feed.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (feed.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: () => _loadNotification(type, loadMore: true),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    if (feed.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: () => _loadNotification(type),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('刷新失败，点击重试'),
          ),
        ),
      );
    }
    return const SizedBox(height: 8);
  }

  Widget _messageCard(LKMessageItem item, bool categoryMarkedRead) {
    final scheme = Theme.of(context).colorScheme;
    final actor = item.nickname.isNotEmpty ? item.nickname : item.sourceName;
    final avatar = item.avatar.isNotEmpty ? item.avatar : item.sourceAvatar;
    final canOpen = _canOpen(item);
    return Card(
      key: ValueKey<String>(_messageKey(item)),
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: canOpen ? () => _openMessage(item) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 21,
                backgroundColor: scheme.surfaceContainerHighest,
                backgroundImage:
                    avatar.isEmpty ? null : YomiruAvatarCache.provider(avatar),
                child: avatar.isEmpty
                    ? Icon(_categoryFor(item.type).icon,
                        size: 21, color: scheme.onSurfaceVariant)
                    : null,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            actor.isEmpty ? item.title : actor,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (item.unread && !categoryMarkedRead)
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(top: 5, left: 8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.primary,
                            ),
                          ),
                      ],
                    ),
                    if (actor.isNotEmpty && item.title.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(item.title,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant)),
                    ],
                    if (item.content.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(item.content),
                    ],
                    if (item.quoteText.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          item.quoteText,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                    if (item.relatedTitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.relatedTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.primary),
                      ),
                    ],
                    if (item.time.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        _formatTime(item.time),
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              if (canOpen)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Icon(Icons.chevron_right_rounded,
                      size: 20, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _canOpen(LKMessageItem item) =>
      item.targetDynamicId > 0 ||
      item.targetBookId > 0 ||
      item.uid > 0 ||
      item.targetUrl.isNotEmpty ||
      item.contentTargetUrl.isNotEmpty;

  bool _targetsComments(LKMessageItem item) {
    final targetType = item.targetType.toLowerCase();
    return item.targetCommentId > 0 ||
        item.targetReplyId > 0 ||
        item.rootCommentId > 0 ||
        item.type == 'reply' ||
        item.type == 'mention' ||
        targetType.contains('comment') ||
        targetType.contains('reply');
  }

  Future<void> _openMessage(LKMessageItem item) async {
    if (item.targetDynamicId > 0) {
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => CommentsPage(dynamicId: item.targetDynamicId)),
      );
      return;
    }
    if (item.targetBookId > 0) {
      if (_targetsComments(item)) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CommentsPage(
              bookId: item.targetBookId,
              bookTitle: item.relatedTitle,
              volumeId: item.targetVolumeId,
            ),
          ),
        );
        return;
      }
      if (item.targetChapterId > 0) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReaderPage(
              bookId: item.targetBookId,
              bookTitle: item.relatedTitle,
              chapterId: item.targetChapterId,
              chapterTitle: item.title,
              volumeId: item.targetVolumeId,
            ),
          ),
        );
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => BookDetailPage(bookId: item.targetBookId)),
      );
      return;
    }
    if (item.uid > 0) {
      openUserProfile(context, item.uid);
      return;
    }
    final raw = item.contentTargetUrl.isNotEmpty
        ? item.contentTargetUrl
        : item.targetUrl;
    final uri = Uri.tryParse(
        raw.startsWith('/') ? 'https://www.lightnovel.fun$raw' : raw);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) showLkError(context, '无法打开消息链接');
    }
  }

  Widget _buildDmBody() {
    if (_dmLoading && _conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_dmError != null && _conversations.isEmpty) {
      return _refreshableState(
        icon: Icons.cloud_off_outlined,
        title: '私信加载失败',
        detail: _dmError.toString(),
        onRefresh: _refreshActive,
      );
    }
    if (_conversations.isEmpty) {
      return _refreshableState(
        icon: Icons.mark_email_read_outlined,
        title: '暂时没有私信',
        onRefresh: _refreshActive,
      );
    }
    return RefreshIndicator(
      onRefresh: _refreshActive,
      child: ListView.builder(
        key: const PageStorageKey<String>('messages-dm'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
            10, 8, 10, MediaQuery.paddingOf(context).bottom + 12),
        itemCount: _conversations.length,
        itemBuilder: (context, index) =>
            _conversationCard(_conversations[index]),
      ),
    );
  }

  Widget _conversationCard(LKConversation conversation) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: scheme.surfaceContainerHighest,
          backgroundImage: conversation.peerAvatar.isEmpty
              ? null
              : YomiruAvatarCache.provider(conversation.peerAvatar),
          child: conversation.peerAvatar.isEmpty
              ? Icon(Icons.person_outline, color: scheme.onSurfaceVariant)
              : null,
        ),
        title: Text(conversation.peerName.isEmpty
            ? '用户 ${conversation.peerUid}'
            : conversation.peerName),
        subtitle: Text(
          conversation.lastMessage.isEmpty
              ? '暂无消息内容'
              : conversation.lastMessage,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (conversation.updatedAt.isNotEmpty)
              Text(
                _formatTime(conversation.updatedAt),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            if (conversation.unread > 0) ...[
              const SizedBox(height: 5),
              Badge(
                  label: Text(conversation.unread > 99
                      ? '99+'
                      : '${conversation.unread}')),
            ],
          ],
        ),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DMChatPage(
                peerUid: conversation.peerUid,
                peerName: conversation.peerName,
              ),
            ),
          );
          if (!mounted) return;
          await Future.wait<void>([_loadDm(), _loadSummary()]);
        },
      ),
    );
  }

  Widget _refreshableState({
    required IconData icon,
    required String title,
    String? detail,
    required Future<void> Function() onRefresh,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: constraints.maxHeight,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 42, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 12),
                      Text(title, style: const TextStyle(fontSize: 16)),
                      if (detail != null && detail.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          detail,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: onRefresh,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('刷新'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  _MessageCategory _categoryFor(String type) => _messageCategories.firstWhere(
        (category) => category.type == type,
        orElse: () => _messageCategories[4],
      );

  String _formatTime(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final number = int.tryParse(value);
    final date = number == null
        ? DateTime.tryParse(value.replaceFirst(' ', 'T'))
        : DateTime.fromMillisecondsSinceEpoch(
            number > 20000000000 ? number : number * 1000);
    if (date == null) return value.replaceFirst('T', ' ').split('.').first;
    final local = date.toLocal();
    final now = DateTime.now();
    String two(int number) => number.toString().padLeft(2, '0');
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${two(local.hour)}:${two(local.minute)}';
    }
    if (local.year == now.year) {
      return '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
    }
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}
