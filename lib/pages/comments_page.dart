import '../services/app_motion.dart';
import '../widgets/account_scope.dart';
import '../api/lk_client.dart';
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api/lk_api.dart';
import '../api/models.dart';
import '../services/avatar_cache.dart';
import '../services/emoji_catalog.dart';
import '../widgets/common.dart';
import '../widgets/emoji_text.dart';
import 'media_viewer_page.dart';
import 'user_profile_page.dart';

/// 书评 / 本卷评论
class CommentsPage extends StatefulWidget {
  final int bookId;
  final String bookTitle;

  /// 0 = 整书评论;>0 = 本卷评论
  final int volumeId;
  final int dynamicId;
  final LKDynamicItem? dynamicPreview;
  const CommentsPage(
      {super.key,
      this.bookId = 0,
      this.bookTitle = '',
      this.volumeId = 0,
      this.dynamicId = 0,
      this.dynamicPreview});

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  static const int _pageSize = 20;
  List<LKComment> _comments = [];
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;
  String? _loadMoreError;
  int _page = 0;
  String _cursor = '';
  bool _hasMore = true;
  int _loadSerial = 0;
  final _input = TextEditingController();

  /// 表情包(code → 图片地址),评论渲染与表情面板共用
  final Map<String, String> _emojiUrl = {};
  List<LKEmojiGroup> _emojiGroups = [];
  final _picker = ImagePicker();
  final List<LKDynamicMedia> _pendingMedia = [];
  LKDynamicItem? _dynamicDetail;
  bool _uploadingImage = false;
  bool _publishing = false;
  final _liking = <int>{};
  final Set<String> _selectedPollOptions = <String>{};
  bool _pollSubmitting = false;
  final Map<int, List<LKComment>> _repliesByComment = {};
  final Set<int> _expandedReplies = <int>{};
  final Set<int> _loadingReplies = <int>{};
  final Map<int, String> _replyErrors = <int, String>{};
  final Map<int, int> _replyPages = <int, int>{};
  final Map<int, String> _replyCursors = <int, String>{};
  final Map<int, bool> _replyHasMore = <int, bool>{};
  LKComment? _replyTarget;
  int _replyParentCommentId = 0;

  bool get _isVolume => widget.volumeId > 0;
  bool get _isDynamic => widget.dynamicId > 0;

  @override
  void initState() {
    super.initState();
    LKClient.sessionRev.addListener(_onSessionChanged);
    _load();
    _loadEmojis();
    if (_isDynamic) _loadDynamicDetail();
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onSessionChanged);
    _input.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    _loadSerial++;
    _input.clear();
    setState(() {
      _publishing = false;
      _liking.clear();
      _uploadingImage = false;
      _pendingMedia.clear();
      _replyErrors.clear();
      _replyPages.clear();
      _replyCursors.clear();
      _replyHasMore.clear();
      _replyTarget = null;
      _replyParentCommentId = 0;
      _comments = [];
      _repliesByComment.clear();
      _loadingReplies.clear();
      _expandedReplies.clear();
    });
    unawaited(_load());
  }

  Future<void> _loadEmojis() async {
    try {
      final groups = await YomiruEmojiCatalog.load();
      if (!mounted) return;
      setState(() {
        _emojiGroups = groups;
        _emojiUrl
          ..clear()
          ..addAll(YomiruEmojiCatalog.urls);
      });
    } catch (_) {}
  }

  Future<LKCommentPage> _requestCommentPage({
    required int page,
    required String cursor,
    int commentId = 0,
  }) {
    if (_isDynamic) {
      return LKApi.dynamicCommentPage(
        widget.dynamicId,
        commentId: commentId,
        cursor: cursor,
        page: page,
        pageSize: _pageSize,
      );
    }
    if (_isVolume) {
      return LKApi.volumeCommentPage(
        widget.bookId,
        widget.volumeId,
        page,
        pageSize: _pageSize,
        commentId: commentId,
      );
    }
    return LKApi.bookCommentPage(
      widget.bookId,
      page,
      pageSize: _pageSize,
      commentId: commentId,
    );
  }

  static List<LKComment> _mergeComments(
      Iterable<LKComment> first, Iterable<LKComment> second) {
    final seen = <int>{};
    return [...first, ...second]
        .where(
            (comment) => comment.commentId <= 0 || seen.add(comment.commentId))
        .toList(growable: false);
  }

  void _seedReplyPreviews(Iterable<LKComment> comments) {
    for (final comment in comments) {
      if (comment.commentId <= 0 ||
          comment.replies.isEmpty ||
          _repliesByComment.containsKey(comment.commentId)) {
        continue;
      }
      _repliesByComment[comment.commentId] = comment.replies;
      _replyPages[comment.commentId] = 0;
      _replyCursors[comment.commentId] = '';
      _replyHasMore[comment.commentId] =
          comment.replyCount > comment.replies.length;
      _expandedReplies.add(comment.commentId);
    }
  }

  Future<void> _load({bool reset = true}) async {
    if (!reset && (_loading || _loadingMore || !_hasMore)) return;
    final requestSerial = reset ? ++_loadSerial : _loadSerial;
    final targetPage = reset ? 1 : _page + 1;
    final targetCursor = reset ? '' : _cursor;
    setState(() {
      if (reset) {
        _loadingReplies.clear();
        _loadingMore = false;
        _loading = _comments.isEmpty;
        _error = null;
        _loadMoreError = null;
      } else {
        _loadingMore = true;
        _loadMoreError = null;
      }
    });
    try {
      final result =
          await _requestCommentPage(page: targetPage, cursor: targetCursor);
      if (!mounted || requestSerial != _loadSerial) return;
      setState(() {
        if (reset) {
          _comments = result.items;
          _repliesByComment.clear();
          _expandedReplies.clear();
          _replyErrors.clear();
          _replyPages.clear();
          _replyCursors.clear();
          _replyHasMore.clear();
          _seedReplyPreviews(result.items);
        } else {
          final before = _comments.length;
          _comments = _mergeComments(_comments, result.items);
          _seedReplyPreviews(result.items);
          if (_comments.length == before && result.items.isNotEmpty) {
            _hasMore = false;
          }
        }
        _page = result.page;
        _cursor = result.nextCursor;
        if (reset || _hasMore) {
          _hasMore = result.hasMore && result.items.isNotEmpty;
        }
        _error = null;
      });
    } catch (e) {
      if (mounted && requestSerial == _loadSerial) {
        setState(() {
          if (reset && _comments.isEmpty) {
            _error = e.toString();
          } else {
            _loadMoreError = e.toString();
          }
        });
      }
    } finally {
      if (mounted && requestSerial == _loadSerial) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _loadDynamicDetail() async {
    final session = SessionStamp();
    try {
      final detail = await LKApi.dynamicDetail(widget.dynamicId);
      if (!mounted || !session.isCurrent) return;
      setState(() {
        _dynamicDetail = detail;
        _selectedPollOptions
          ..clear()
          ..addAll(detail.poll?.options
                  .where((option) => option.selected)
                  .map((option) => option.id) ??
              const []);
      });
      await LKApi.markDynamicRead(dynamicId: widget.dynamicId);
    } catch (_) {
      // 详情失败时仍保留信息流传入的预览内容。
    }
  }

  Future<void> _publish() async {
    final content = _input.text.trim();
    if (content.isEmpty || _publishing || _uploadingImage) return;
    final session = SessionStamp();
    final draft = _input.text;
    final media = List<LKDynamicMedia>.of(_pendingMedia);
    setState(() => _publishing = true);
    final replyTarget = _replyTarget;
    final replyIds = replyTarget == null
        ? (rootCommentId: 0, replyCommentId: 0)
        : resolveBookCommentReplyIds(
            replyTarget,
            parentCommentId: _replyParentCommentId,
          );
    final replyRootId = replyTarget == null
        ? 0
        : _isDynamic
            ? (_replyParentCommentId > 0
                ? _replyParentCommentId
                : replyTarget.rootCommentId > 0
                    ? replyTarget.rootCommentId
                    : replyTarget.commentId)
            : replyIds.rootCommentId;
    try {
      if (_isDynamic) {
        await LKApi.publishDynamicComment(widget.dynamicId, content,
            replyCommentId: replyTarget?.commentId ?? 0, media: media);
      } else if (_isVolume) {
        await LKApi.publishBookComment(widget.bookId, content,
            volumeId: widget.volumeId,
            rootCommentId: replyIds.rootCommentId,
            replyCommentId: replyIds.replyCommentId,
            media: media);
      } else {
        await LKApi.publishBookComment(widget.bookId, content,
            rootCommentId: replyIds.rootCommentId,
            replyCommentId: replyIds.replyCommentId,
            media: media);
      }
      if (!mounted || !session.isCurrent) return;
      if (_input.text == draft) _input.clear();
      _pendingMedia.removeWhere(media.contains);
      if (mounted && identical(_replyTarget, replyTarget)) {
        setState(() {
          _replyTarget = null;
          _replyParentCommentId = 0;
        });
      }
      if (replyRootId > 0 && mounted) {
        LKComment? root;
        for (final comment in _comments) {
          if (comment.commentId == replyRootId) {
            root = comment;
            break;
          }
        }
        if (root != null) {
          setState(() => _expandedReplies.add(replyRootId));
          await _loadReplies(root, reset: true);
        } else {
          await _load();
        }
      } else {
        await _load();
      }
    } catch (e) {
      if (mounted) showLkError(context, e);
    } finally {
      if (mounted && session.isCurrent) setState(() => _publishing = false);
    }
  }

  Future<void> _pickImage() async {
    if (_uploadingImage || _publishing || _pendingMedia.length >= 9) return;
    final session = SessionStamp();
    setState(() => _uploadingImage = true);
    try {
      final file = await _picker.pickImage(
          source: ImageSource.gallery, imageQuality: 88, maxWidth: 2048);
      if (file == null || !mounted || !session.isCurrent) return;
      final media = await LKApi.uploadCommentImage(file.path);
      if (mounted && session.isCurrent) {
        setState(() => _pendingMedia.add(media));
      }
    } catch (e) {
      if (mounted && session.isCurrent) showLkError(context, e);
    } finally {
      if (mounted && session.isCurrent) setState(() => _uploadingImage = false);
    }
  }

  Future<void> _toggleReplies(LKComment comment) async {
    if (comment.commentId <= 0 || _loadingReplies.contains(comment.commentId)) {
      return;
    }
    if (_expandedReplies.contains(comment.commentId)) {
      setState(() => _expandedReplies.remove(comment.commentId));
      return;
    }
    setState(() => _expandedReplies.add(comment.commentId));
    if (_repliesByComment.containsKey(comment.commentId) &&
        (_replyPages[comment.commentId] ?? 0) > 0) {
      return;
    }
    await _loadReplies(comment, reset: true);
  }

  Future<void> _loadReplies(LKComment comment, {bool reset = false}) async {
    final session = SessionStamp();
    final revision = _loadSerial;
    bool current() => mounted && session.isCurrent && revision == _loadSerial;
    final commentId = comment.commentId;
    if (commentId <= 0 || _loadingReplies.contains(commentId)) return;
    if (!reset && !(_replyHasMore[commentId] ?? false)) return;
    final page = reset ? 1 : (_replyPages[commentId] ?? 0) + 1;
    final cursor = reset ? '' : (_replyCursors[commentId] ?? '');
    setState(() {
      _loadingReplies.add(commentId);
      _replyErrors.remove(commentId);
    });
    try {
      final result = await _requestCommentPage(
          page: page, cursor: cursor, commentId: commentId);
      if (!current()) return;
      setState(() {
        final existing = _repliesByComment[commentId] ?? const <LKComment>[];
        final merged = reset
            ? _mergeComments(result.items, existing)
            : _mergeComments(existing, result.items);
        _repliesByComment[commentId] = merged;
        _replyPages[commentId] = result.page;
        _replyCursors[commentId] = result.nextCursor;
        _replyHasMore[commentId] = result.hasMore;
      });
    } catch (e) {
      if (!current()) return;
      setState(() => _replyErrors[commentId] = e.toString());
    } finally {
      if (current()) setState(() => _loadingReplies.remove(commentId));
    }
  }

  /// 渲染评论内容:把表情代码({:xx:} / [s:数字] 等)替换为表情图片
  Widget _renderContent(String content) =>
      LkEmojiText(text: content, emojiUrls: _emojiUrl);

  String _formatCommentTime(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final number = int.tryParse(value);
    final date = number == null
        ? DateTime.tryParse(value.replaceFirst(' ', 'T'))
        : DateTime.fromMillisecondsSinceEpoch(
            number > 20000000000 ? number : number * 1000);
    if (date == null) return value.replaceFirst('T', ' ').split('.').first;
    String two(int n) => n.toString().padLeft(2, '0');
    final local = date.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// 点赞/取消点赞(乐观更新,失败回滚)
  Future<void> _toggleLike(dynamic c) async {
    if (_liking.contains(c.commentId)) return;
    final session = SessionStamp();
    final wasLiked = c.liked as bool;
    final rootIndex = _comments.indexOf(c);
    var replyIndex = -1;
    var replyParentId = 0;
    if (rootIndex < 0) {
      for (final entry in _repliesByComment.entries) {
        final index = entry.value.indexOf(c);
        if (index >= 0) {
          replyParentId = entry.key;
          replyIndex = index;
          break;
        }
      }
    }
    if (rootIndex < 0 && replyIndex < 0) return;
    _liking.add(c.commentId as int);
    final updated = LKComment(
      commentId: c.commentId,
      rootCommentId: c.rootCommentId,
      replyToCommentId: c.replyToCommentId,
      userUid: c.userUid,
      nickname: c.nickname,
      replyToNickname: c.replyToNickname,
      avatar: c.avatar,
      content: c.content,
      time: c.time,
      likeCount: (c.likeCount as int) + (wasLiked ? -1 : 1),
      liked: !wasLiked,
      media: c.media,
      replyCount: c.replyCount,
      replies: c.replies,
    );
    setState(() {
      if (rootIndex >= 0) {
        _comments[rootIndex] = updated;
      } else {
        final replies = List<LKComment>.from(_repliesByComment[replyParentId]!);
        replies[replyIndex] = updated;
        _repliesByComment[replyParentId] = replies;
      }
    });
    try {
      if (_isDynamic) {
        await LKApi.toggleDynamicCommentLike(
            widget.dynamicId, c.commentId, !wasLiked);
      } else {
        await LKApi.likeBookComment(widget.bookId, c.commentId, !wasLiked,
            volumeId: widget.volumeId,
            rootCommentId:
                c.rootCommentId > 0 ? c.rootCommentId : replyParentId);
      }
    } catch (e) {
      // Only roll back the exact optimistic item, not a refreshed/new-account list.
      if (!mounted || !session.isCurrent) return;
      setState(() {
        final currentRoot = _comments.indexOf(updated);
        if (currentRoot >= 0) {
          _comments[currentRoot] = c;
        } else {
          final replies =
              List<LKComment>.of(_repliesByComment[replyParentId] ?? []);
          final currentReply = replies.indexOf(updated);
          if (currentReply >= 0) {
            replies[currentReply] = c;
            _repliesByComment[replyParentId] = replies;
          }
        }
      });
      showLkError(context, e);
    } finally {
      if (session.isCurrent) _liking.remove(c.commentId);
    }
  }

  Widget _likeButton(dynamic c) {
    final liked = c.liked as bool;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('${c.likeCount}',
          style: TextStyle(
              fontSize: 11,
              color: liked ? Colors.redAccent : Colors.grey.shade500)),
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(
          liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          size: 18,
          color: liked ? Colors.redAccent : Colors.grey.shade500,
        ),
        onPressed: () => _toggleLike(c),
      ),
    ]);
  }

  /// 长按复制评论
  Future<void> _copyComment(dynamic c) async {
    // 去掉表情代码,复制纯文本
    final text = (c.content as String)
        .replaceAll(RegExp(r'\{:[^:]+:\}|\[[a-zA-Z]+:\d+\]'), '');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showLkError(context, '已复制评论');
  }

  Widget _mediaGallery(List<LKDynamicMedia> media) {
    if (media.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: media
            .map((item) => GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => MediaViewerPage(url: item.url)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedNetworkImage(
                      fadeOutDuration: AppMotion.duration(context, 1000),
                      fadeInDuration: AppMotion.duration(context, 500),
                      imageUrl: item.url,
                      width: 92,
                      height: 92,
                      memCacheWidth: imageCacheDimension(context, 92),
                      fit: BoxFit.cover,
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _dynamicHeader() {
    final item = _dynamicDetail ?? widget.dynamicPreview;
    if (item == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: LkLoadingIndicator(minHeight: 180),
      );
    }
    final poll = item.poll;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: InkWell(
        onLongPress: () => _copyDynamicUrl(item),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                CircleAvatar(
                  radius: 18,
                  backgroundImage:
                      YomiruAvatarCache.providerOrNull(item.avatar),
                  child: YomiruAvatarCache.providerOrNull(item.avatar) == null
                      ? const Icon(Icons.person)
                      : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(item.nickname.isEmpty ? '未知用户' : item.nickname,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(item.time,
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ]),
              const SizedBox(height: 12),
              if (item.title.isNotEmpty && item.summary.trim().isNotEmpty) ...[
                Text(item.title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
              ],
              if (item.displayContent.trim().isNotEmpty)
                _renderContent(item.displayContent),
              _mediaGallery(item.media),
              if (poll != null) _pollCard(poll),
              const SizedBox(height: 8),
              Text('评论 ${item.commentCount} · 赞 ${item.likeCount}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyDynamicUrl(LKDynamicItem item) async {
    if (item.dynamicId <= 0) return;
    await Clipboard.setData(
        ClipboardData(text: dynamicWebsiteUrl(item.dynamicId)));
    if (mounted) showLkError(context, '已复制动态链接');
  }

  Widget _pollCard(LKDynamicPoll poll) {
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(poll.title.isEmpty ? '投票' : poll.title,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (poll.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(poll.description,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
            ...poll.options.map((option) {
              final selected = _selectedPollOptions.contains(option.id);
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: selected,
                title: Text(option.text),
                subtitle: poll.voted || poll.ended
                    ? Text(
                        '${option.voteCount} 票${option.percent > 0 ? ' · ${option.percent.toStringAsFixed(1)}%' : ''}')
                    : null,
                onChanged: poll.voted || poll.ended
                    ? null
                    : (value) {
                        setState(() {
                          if (value == true) {
                            if (!poll.multiple) _selectedPollOptions.clear();
                            _selectedPollOptions.add(option.id);
                          } else {
                            _selectedPollOptions.remove(option.id);
                          }
                        });
                      },
              );
            }),
            if (!poll.voted && !poll.ended)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _pollSubmitting || _selectedPollOptions.isEmpty
                      ? null
                      : () async {
                          setState(() => _pollSubmitting = true);
                          try {
                            await LKApi.submitDynamicPollVote(widget.dynamicId,
                                _selectedPollOptions.toList());
                            await _loadDynamicDetail();
                          } catch (e) {
                            if (mounted) showLkError(context, e);
                          } finally {
                            if (mounted) {
                              setState(() => _pollSubmitting = false);
                            }
                          }
                        },
                  child: Text(_pollSubmitting ? '提交中' : '投票'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _replyControls(LKComment comment,
      {bool isReply = false, int parentCommentId = 0}) {
    final expanded = !isReply && _expandedReplies.contains(comment.commentId);
    final loading = !isReply && _loadingReplies.contains(comment.commentId);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: () => setState(() {
              _replyTarget = comment;
              _replyParentCommentId = isReply ? parentCommentId : 0;
            }),
            icon: const Icon(Icons.reply_rounded, size: 17),
            label: Text(
                _replyTarget?.commentId == comment.commentId ? '正在回复' : '回复'),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
          ),
          if (!isReply &&
              (comment.replyCount > 0 ||
                  (_repliesByComment[comment.commentId]?.isNotEmpty ?? false)))
            TextButton.icon(
              onPressed: loading ? null : () => _toggleReplies(comment),
              icon: Icon(expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded),
              label: Text(loading
                  ? '加载回复…'
                  : expanded
                      ? '收起回复'
                      : '查看 ${comment.replyCount} 条回复'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _replyList(LKComment parent) {
    if (!_expandedReplies.contains(parent.commentId)) {
      return const SizedBox.shrink();
    }
    final replies = _repliesByComment[parent.commentId] ?? const <LKComment>[];
    final loading = _loadingReplies.contains(parent.commentId);
    final error = _replyErrors[parent.commentId];
    if (replies.isEmpty) {
      if (loading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: LkLoadingIndicator()),
        );
      }
      if (error != null) {
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _loadReplies(parent, reset: true),
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: const Text('回复加载失败，点击重试'),
          ),
        );
      }
    }
    if (replies.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text('暂时没有可显示的回复',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          ...replies.map((reply) => _commentItem(reply,
              isReply: true, parentCommentId: parent.commentId)),
          if (error != null)
            TextButton.icon(
              onPressed: () => _loadReplies(parent),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('继续加载失败，点击重试'),
            )
          else if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(child: LkLoadingIndicator()),
            )
          else if (_replyHasMore[parent.commentId] ?? false)
            TextButton.icon(
              onPressed: () => _loadReplies(parent),
              icon: const Icon(Icons.expand_more_rounded, size: 18),
              label: const Text('加载更多回复'),
            ),
        ],
      ),
    );
  }

  bool _onCommentScroll(ScrollNotification notification) {
    if (notification.metrics.axis == Axis.vertical &&
        notification.metrics.extentAfter < 480 &&
        !_loading &&
        !_loadingMore &&
        _loadMoreError == null &&
        _hasMore) {
      unawaited(_load(reset: false));
    }
    return false;
  }

  Widget _commentPageFooter() {
    if (_loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: TextButton.icon(
            onPressed: () => _load(reset: false),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('加载更多失败，点击重试'),
          ),
        ),
      );
    }
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loadingMore && _loadMoreError == null && _hasMore) {
          unawaited(_load(reset: false));
        }
      });
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Center(child: LkLoadingIndicator()),
    );
  }

  /// 评论采用左侧头像 + 右侧正文布局，日期统一放在昵称下方。
  Widget _commentItem(dynamic c,
      {bool isReply = false, int parentCommentId = 0}) {
    final avatar = CircleAvatar(
      radius: 24,
      backgroundImage: YomiruAvatarCache.providerOrNull(c.avatar),
      child: YomiruAvatarCache.providerOrNull(c.avatar) == null
          ? const Icon(Icons.person)
          : null,
    );
    final author = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(c.nickname,
            style: TextStyle(fontSize: 13, color: Colors.indigo.shade400)),
        if (c.replyToNickname.isNotEmpty)
          Text('回复 @${c.replyToNickname}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        if (c.time.isNotEmpty)
          Text(
            _formatCommentTime(c.time),
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500),
          ),
      ],
    );
    return InkWell(
      onTap: c.userUid > 0 ? () => openUserProfile(context, c.userUid) : null,
      onLongPress: () => _copyComment(c),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Align(alignment: Alignment.topCenter, child: avatar),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: author),
                      _likeButton(c),
                    ],
                  ),
                  const SizedBox(height: 5),
                  _renderContent(c.content),
                  _mediaGallery(c.media),
                  _replyControls(c,
                      isReply: isReply, parentCommentId: parentCommentId),
                  if (!isReply) _replyList(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 键盘 inset 只由输入行处理:动画期间评论列表不重建,交互更流畅
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
          title: Text(_isDynamic
              ? '动态详情'
              : _isVolume
                  ? '本卷评论 · ${widget.bookTitle}'
                  : '书评 · ${widget.bookTitle}')),
      body: Column(children: [
        Expanded(
          child: _loading
              ? const LkLoadingIndicator()
              : MotionRefreshIndicator(
                  onRefresh: () => _load(),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onCommentScroll,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                          bottom: MediaQuery.paddingOf(context).bottom),
                      itemCount: (_isDynamic ? 1 : 0) +
                          (_comments.isEmpty ? 1 : _comments.length) +
                          (_hasMore || _loadingMore || _loadMoreError != null
                              ? 1
                              : 0),
                      itemBuilder: (_, i) {
                        if (_isDynamic && i == 0) return _dynamicHeader();
                        final contentIndex = i - (_isDynamic ? 1 : 0);
                        if (_comments.isEmpty && contentIndex == 0) {
                          return SizedBox(
                            height: 240,
                            child: Center(
                              child: Text(
                                _error ??
                                    (_isDynamic
                                        ? '还没有评论'
                                        : _isVolume
                                            ? '本卷还没有评论'
                                            : '还没有书评，来抢沙发'),
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ),
                          );
                        }
                        if (contentIndex >= _comments.length) {
                          return _commentPageFooter();
                        }
                        final c = _comments[contentIndex];
                        return _commentItem(c);
                      },
                    ),
                  ),
                ),
        ),
        _CommentsInputBar(
          publishing: _publishing || _uploadingImage,
          controller: _input,
          emojiGroups: _emojiGroups,
          isVolume: _isVolume,
          hintText: _isDynamic ? '写下你的动态评论…' : null,
          replyLabel: _replyTarget == null
              ? null
              : '回复 @${_replyTarget!.nickname.isEmpty ? '用户' : _replyTarget!.nickname}',
          onCancelReply: _replyTarget == null
              ? null
              : () => setState(() {
                    _replyTarget = null;
                    _replyParentCommentId = 0;
                  }),
          onPickImage: _pickImage,
          pendingImageUrl:
              _pendingMedia.isEmpty ? null : _pendingMedia.last.url,
          onRemoveImage: _pendingMedia.isEmpty
              ? null
              : () => setState(() => _pendingMedia.removeLast()),
          onPublish: _publish,
        ),
      ]),
    );
  }
}

/// 底部评论输入区。独立于评论列表，避免键盘 inset 动画触发整页重建。
class _CommentsInputBar extends StatefulWidget {
  final TextEditingController controller;
  final List<LKEmojiGroup> emojiGroups;
  final bool isVolume;
  final String? hintText;
  final String? replyLabel;
  final VoidCallback? onCancelReply;
  final VoidCallback? onPickImage;
  final String? pendingImageUrl;
  final VoidCallback? onRemoveImage;
  final VoidCallback onPublish;
  final bool publishing;

  const _CommentsInputBar({
    required this.controller,
    required this.emojiGroups,
    required this.isVolume,
    this.hintText,
    this.replyLabel,
    this.onCancelReply,
    this.onPickImage,
    this.pendingImageUrl,
    this.onRemoveImage,
    required this.onPublish,
    this.publishing = false,
  });

  @override
  State<_CommentsInputBar> createState() => _CommentsInputBarState();
}

class _CommentsInputBarState extends State<_CommentsInputBar> {
  final _focus = FocusNode();
  bool _showEmoji = false;
  bool _keyboardReturning = false;
  double _keyboardTransitionHeight = 0;
  Timer? _keyboardTransitionTimer;

  @override
  void dispose() {
    _keyboardTransitionTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  double _emojiPanelHeight() {
    final media = MediaQuery.of(context);
    final inputHeight = media.textScaler.scale(64).clamp(96.0, 180.0) +
        (widget.pendingImageUrl == null ? 0 : 70) +
        (widget.replyLabel == null ? 0 : 36);
    final available = (media.size.height -
            media.viewPadding.vertical -
            kToolbarHeight -
            inputHeight -
            64)
        .clamp(0.0, 360.0);
    return (media.size.height * 0.42).clamp(0.0, available).toDouble();
  }

  void _returnToKeyboard() {
    _keyboardTransitionTimer?.cancel();
    final reserveHeight = _emojiPanelHeight();
    setState(() {
      _showEmoji = false;
      _keyboardReturning = true;
      _keyboardTransitionHeight = reserveHeight;
    });
    _focus.requestFocus();
    // 输入法出现期间继续占住表情面板高度，避免输入栏先落底再弹起。
    _keyboardTransitionTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() => _keyboardReturning = false);
    });
  }

  void _toggleEmoji() {
    if (widget.emojiGroups.isEmpty) {
      showLkError(context, '表情加载中,请稍后再试');
      return;
    }
    if (_showEmoji) {
      _returnToKeyboard();
    } else {
      _keyboardTransitionTimer?.cancel();
      _focus.unfocus();
      setState(() {
        _showEmoji = true;
        _keyboardReturning = false;
      });
    }
  }

  void _pickEmoji(String code) {
    final sel = widget.controller.selection;
    final text = widget.controller.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    widget.controller.text = text.replaceRange(start, end, code);
    widget.controller.selection =
        TextSelection.collapsed(offset: start + code.length);
  }

  @override
  Widget build(BuildContext context) {
    // 系统已经在动画中逐帧更新 viewInsets，不再叠加 AnimatedPadding。
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final panelH = _showEmoji ? _emojiPanelHeight() : 0.0;
    final double bottomPad;
    if (_showEmoji) {
      bottomPad = panelH;
    } else if (_keyboardReturning) {
      final reserve = _keyboardTransitionHeight.clamp(0.0, _emojiPanelHeight());
      bottomPad = inset > reserve ? inset : reserve;
    } else {
      bottomPad = inset;
    }

    return Stack(children: [
      if (_showEmoji)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: panelH,
          child: Material(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF1E2025)
                : Colors.white,
            child: SafeArea(
              top: false,
              child: _EmojiPanel(
                groups: widget.emojiGroups,
                onPick: _pickEmoji,
              ),
            ),
          ),
        ),
      Padding(
        padding: EdgeInsets.only(bottom: bottomPad),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              if (widget.replyLabel != null && widget.replyLabel!.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6, left: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.replyLabel!,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '取消回复',
                          icon: const Icon(Icons.close, size: 17),
                          onPressed: widget.onCancelReply,
                        ),
                      ],
                    ),
                  ),
                ),
              if (widget.pendingImageUrl != null &&
                  widget.pendingImageUrl!.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            fadeOutDuration: AppMotion.duration(context, 1000),
                            fadeInDuration: AppMotion.duration(context, 500),
                            imageUrl: widget.pendingImageUrl!,
                            width: 56,
                            height: 56,
                            memCacheWidth: imageCacheDimension(context, 56),
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          right: -8,
                          top: -8,
                          child: IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.cancel, size: 18),
                            onPressed: widget.onRemoveImage,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Row(children: [
                IconButton(
                  tooltip: _showEmoji ? '键盘' : '表情',
                  icon: Icon(_showEmoji
                      ? Icons.keyboard_alt_outlined
                      : Icons.emoji_emotions_outlined),
                  onPressed: _toggleEmoji,
                ),
                if (widget.onPickImage != null)
                  IconButton(
                    tooltip: '添加图片',
                    icon: const Icon(Icons.image_outlined),
                    onPressed: widget.onPickImage,
                  ),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focus,
                    onTap: () {
                      if (_showEmoji) {
                        _returnToKeyboard();
                      }
                    },
                    decoration: InputDecoration(
                        hintText: widget.hintText ??
                            (widget.isVolume ? '写下本卷评论…' : '写下你的书评…'),
                        isDense: true,
                        border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: widget.publishing ? null : widget.onPublish,
                    child: Text(widget.publishing ? '处理中…' : '发布')),
              ]),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// 评论表情选择面板(分组页签 + 网格)
class _EmojiPanel extends StatefulWidget {
  final List<LKEmojiGroup> groups;
  final void Function(String code) onPick;
  const _EmojiPanel({required this.groups, required this.onPick});

  @override
  State<_EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<_EmojiPanel> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final g = widget.groups[_tab];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(children: [
      SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: widget.groups.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final sel = i == _tab;
            return GestureDetector(
              onTap: () => setState(() => _tab = i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: sel
                      ? Theme.of(context).colorScheme.primary
                      : (isDark
                          ? const Color(0xFF2A2C33)
                          : Colors.grey.shade100),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  widget.groups[i].name,
                  style: TextStyle(
                    fontSize: 13,
                    color: sel ? Colors.white : Colors.grey.shade700,
                  ),
                ),
              ),
            );
          },
        ),
      ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 8,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: g.items.length,
          itemBuilder: (_, i) {
            final it = g.items[i];
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => widget.onPick(it.code),
              child: it.isImage
                  ? CachedNetworkImage(
                      fadeOutDuration: AppMotion.duration(context, 1000),
                      fadeInDuration: AppMotion.duration(context, 500),
                      imageUrl: it.url.replaceFirst(
                          'api.lightnovel.fun/static/',
                          'static.lightnovel.fun/'),
                      width: 32,
                      height: 32,
                      memCacheWidth: imageCacheDimension(context, 32),
                      fit: BoxFit.contain,
                      errorWidget: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          size: 20,
                          color: Colors.grey),
                    )
                  : Center(
                      child:
                          Text(it.code, style: const TextStyle(fontSize: 22))),
            );
          },
        ),
      ),
    ]);
  }
}
