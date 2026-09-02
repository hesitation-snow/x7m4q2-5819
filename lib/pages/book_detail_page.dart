import 'dart:async';

import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/follow_relation.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/store.dart';
import '../services/avatar_cache.dart';
import '../widgets/common.dart';
import 'catalog_paging.dart';
import 'login_page.dart';
import 'reader_page.dart';
import 'search_page.dart';
import 'user_profile_page.dart';

int _bookDetailInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _bookDetailFlag(dynamic value) =>
    value == true || value == 1 || value == '1' || value == 'true';

LKBook _preservePublisher(LKBook book, LKBook? fallback) {
  if (fallback == null ||
      (fallback.publisherUid <= 0 &&
          fallback.publisherName.trim().isEmpty &&
          fallback.publisherAvatar.trim().isEmpty)) {
    return book;
  }
  final data = book.toJson();
  if (book.publisherUid <= 0 && fallback.publisherUid > 0) {
    data['publisher_uid'] = fallback.publisherUid;
  }
  if (book.publisherName.trim().isEmpty &&
      fallback.publisherName.trim().isNotEmpty) {
    data['publisher_name'] = fallback.publisherName;
  }
  if (book.publisherAvatar.trim().isEmpty &&
      fallback.publisherAvatar.trim().isNotEmpty) {
    data['publisher_avatar'] = fallback.publisherAvatar;
  }
  if (!book.publisherFollowed && fallback.publisherFollowed) {
    data['publisher_followed'] = true;
  }
  return LKBook.fromJson(data);
}

Widget _braveAccessBadge(BuildContext context) {
  final color = Theme.of(context).colorScheme.primary;
  return Container(
    margin: const EdgeInsets.only(right: 8),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Text('勇者可读',
        style: TextStyle(
            color: color, fontSize: 10.5, fontWeight: FontWeight.w600)),
  );
}

/// 书籍详情(LightNovelReader 风格):
/// - 大封面头部 + 状态
/// - 可点击标签(跳转标签搜索)
/// - 滚动感知的"继续阅读/开始阅读" FAB
/// - 卷目录(云进度标记"读到")
class BookDetailPage extends StatefulWidget {
  final int bookId;
  const BookDetailPage({super.key, required this.bookId});

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  LKBook? _book;
  List<LKVolume> _volumes = const [];
  bool _inShelf = false;
  int _readVolumeId = 0;
  int _readChapterId = 0;
  String _readChapterTitle = '';
  bool _hasHistory = false;
  final _publisherRelation = FollowRelationState();
  bool get _publisherFollowed => _publisherRelation.followed;
  bool _publisherFollowBusy = false;
  String? _error;
  int _bookRequestSerial = 0;
  bool _volumesLoading = true;
  String? _volumesError;
  int _volumesRequestSerial = 0;
  int _volumesPage = 0;
  bool _volumesHasMore = true;
  final _scroll = ScrollController();
  bool _fabVisible = true;
  double _lastOffset = 0;

  /// 目录中已就地展开的卷;展开后章节列表直接显示在卷卡片下方。
  final Set<int> _expandedVolumeIds = <int>{};
  final Map<int, List<LKChapter>> _volumeChapters = {};
  final Map<int, String> _volumeErrors = {};
  final Set<int> _loadingVolumeIds = <int>{};
  final Map<int, int> _volumeChapterRequests = {};
  bool _loadingAllVolumes = false;
  List<LKChapter> _catalogPreview = const [];
  int _catalogPreviewVolumeId = 0;
  bool _catalogPreviewLoading = false;
  String? _catalogPreviewError;
  int _catalogPreviewRequestSerial = 0;

  bool get _usesPagedCatalog => shouldUsePagedCatalogForVolumes(
        _volumes,
        bookChapterCount: _book?.chapterCount ?? 0,
      );

  bool get _canExpandAllVolumes =>
      !_volumesHasMore &&
      shouldOfferExpandAllVolumes(
        _volumes,
        bookChapterCount: _book?.chapterCount ?? 0,
      );

  bool _volumeUsesPagedCatalog(LKVolume volume) =>
      shouldUsePagedCatalog(_chapterTotalFor(volume));

  LKVolume? get _initialCatalogVolume {
    final preferredId = _hasHistory && _readVolumeId > 0
        ? _readVolumeId
        : (_book?.defaultVolumeId ?? 0);
    final candidates = _usesPagedCatalog
        ? _volumes.where(_volumeUsesPagedCatalog).toList(growable: false)
        : _volumes;
    return selectCatalogStartVolume(
      candidates,
      preferredVolumeId: preferredId,
    );
  }

  @override
  void initState() {
    super.initState();
    LKClient.sessionRev.addListener(_onPublisherSessionChanged);
    _load();
    _scroll.addListener(() {
      final o = _scroll.offset;
      final down = o > _lastOffset + 2;
      _lastOffset = o;
      final v = o < 80 || !down;
      if (v != _fabVisible && mounted) setState(() => _fabVisible = v);
    });
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onPublisherSessionChanged);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final request = ++_bookRequestSerial;
    if (mounted) {
      setState(() {
        _error = null;
        _volumesLoading = true;
      });
    }
    await Future.wait<void>([
      _loadPrimary(request: request, forceRefresh: forceRefresh),
      _loadVolumes(forceRefresh: forceRefresh),
    ]);
    if (!mounted || request != _bookRequestSerial) return;
    await _loadCatalogPreview(forceRefresh: forceRefresh);
    if (forceRefresh && mounted) {
      final expanded = _volumes
          .where((volume) => _expandedVolumeIds.contains(volume.volumeId))
          .toList();
      for (var start = 0; start < expanded.length; start += 3) {
        if (!mounted || request != _bookRequestSerial) return;
        await Future.wait(expanded
            .skip(start)
            .take(3)
            .map((volume) => _loadVolumeChapters(volume, forceRefresh: true)));
      }
    }
  }

  Future<void> _loadPrimary(
      {required int request, bool forceRefresh = false}) async {
    try {
      final bootstrap = await LKApi.readerBootstrap(widget.bookId);
      final detailBook = bootstrap.book;
      final book = detailBook.bookId > 0
          ? detailBook
          : LKBook.fromJson({...detailBook.toJson(), 'book_id': widget.bookId});
      var localShelf = false;
      if (!LKClient.shared.session.isLoggedIn) {
        localShelf = await LKStore.isLocalShelf(widget.bookId);
      }
      if (!mounted || request != _bookRequestSerial) return;
      setState(() {
        _book = book;
        _inShelf = bootstrap.inShelf || localShelf;
        _hasHistory = bootstrap.hasHistory && bootstrap.readChapterId > 0;
        _readVolumeId = bootstrap.readVolumeId;
        _readChapterId = bootstrap.readChapterId;
        _readChapterTitle = bootstrap.readChapterTitle;
        _bindPublisher(book);
        _error = null;
      });
      unawaited(
          _refreshPublisherFollowStatus(book, forceRefresh: forceRefresh));
      // 聚合接口先让页面和阅读按钮可用，完整简介随后静默刷新。
      if (forceRefresh) {
        await _loadBook(request: request, background: true, forceRefresh: true);
      } else {
        unawaited(_loadBook(request: request, background: true));
      }
    } catch (_) {
      if (!mounted || request != _bookRequestSerial) return;
      await Future.wait<void>([
        _loadBook(request: request, forceRefresh: forceRefresh),
        _loadLibraryState(),
      ]);
    }
  }

  Future<void> _loadBook(
      {required int request,
      bool background = false,
      bool forceRefresh = false}) async {
    try {
      final detailBook =
          await LKApi.bookDetail(widget.bookId, forceRefresh: forceRefresh);
      if (!mounted || request != _bookRequestSerial) return;
      // 详情接口个别缓存/兼容响应可能缺少 book_id,但当前页面路由 ID 是可靠的。
      final detail = detailBook.bookId > 0
          ? detailBook
          : LKBook.fromJson({...detailBook.toJson(), 'book_id': widget.bookId});
      // 发布者资料以 reader-bootstrap 的 publisher 对象为准；详情接口
      // 若只返回展示名称，不应覆盖已经取得的 UID 和头像。
      final book = _preservePublisher(detail, _book);
      if (!mounted) return;
      setState(() {
        _book = book;
        _bindPublisher(book);
        _error = null;
      });
      unawaited(_refreshPublisherFollowStatus(book));
      if (!forceRefresh) unawaited(_loadCatalogPreview());
    } catch (e) {
      if (!background &&
          mounted &&
          request == _bookRequestSerial &&
          _book == null) {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<void> _loadVolumes(
      {bool append = false, bool forceRefresh = false}) async {
    if (append && (_volumesLoading || !_volumesHasMore)) return;
    final request = append ? _volumesRequestSerial : ++_volumesRequestSerial;
    final page = append ? _volumesPage + 1 : 1;
    const pageSize = 50;
    if (mounted) {
      setState(() {
        _volumesLoading = true;
        _volumesError = null;
      });
    }
    try {
      final pageItems = await LKApi.volumes(widget.bookId, page,
          pageSize: pageSize, forceRefresh: forceRefresh);
      if (!mounted || request != _volumesRequestSerial) return;
      final volumes = append
          ? (() {
              final seen = _volumes.map((volume) => volume.volumeId).toSet();
              return [
                ..._volumes,
                ...pageItems.where((volume) => seen.add(volume.volumeId)),
              ];
            })()
          : pageItems;
      final expectedTotal = _book?.volumeCount ?? 0;
      setState(() {
        _volumes = volumes;
        _volumesPage = page;
        _volumesHasMore = pageItems.length >= pageSize &&
            (expectedTotal <= 0 || volumes.length < expectedTotal);
        if (!append) {
          final validIds = volumes.map((volume) => volume.volumeId).toSet();
          _expandedVolumeIds.removeWhere((id) => !validIds.contains(id));
          _volumeChapters.removeWhere((id, _) => !validIds.contains(id));
          _volumeErrors.removeWhere((id, _) => !validIds.contains(id));
        }
        _volumesError = null;
      });
      if (!forceRefresh) unawaited(_loadCatalogPreview());
    } catch (_) {
      if (mounted && request == _volumesRequestSerial) {
        setState(() => _volumesError = '目录加载失败，请检查网络后重试');
      }
    } finally {
      if (mounted && request == _volumesRequestSerial) {
        setState(() => _volumesLoading = false);
      }
    }
  }

  int _chapterTotalFor(LKVolume volume) {
    return effectiveVolumeChapterCount(
      volume,
      loadedVolumeCount: _volumes.length,
      bookChapterCount: _book?.chapterCount ?? 0,
    );
  }

  Future<void> _loadCatalogPreview({bool forceRefresh = false}) async {
    if (!_usesPagedCatalog) return;
    final book = _book;
    final volume = _initialCatalogVolume;
    if (book == null || volume == null) return;
    if (!forceRefresh &&
        _catalogPreviewLoading &&
        _catalogPreviewVolumeId == volume.volumeId) {
      return;
    }
    if (!forceRefresh &&
        _catalogPreviewVolumeId == volume.volumeId &&
        _catalogPreview.isNotEmpty) {
      return;
    }
    final request = ++_catalogPreviewRequestSerial;
    if (mounted) {
      setState(() {
        _catalogPreviewVolumeId = volume.volumeId;
        _catalogPreviewLoading = true;
        _catalogPreviewError = null;
      });
    }
    try {
      final page = await LKApi.chapterPage(book.bookId, volume.volumeId, 1,
          forceRefresh: forceRefresh);
      if (!mounted || request != _catalogPreviewRequestSerial) return;
      setState(() {
        _catalogPreview = page.items.take(8).toList(growable: false);
        _catalogPreviewError = null;
      });
    } catch (_) {
      if (mounted && request == _catalogPreviewRequestSerial) {
        setState(() => _catalogPreviewError = '目录预览加载失败，点击重试');
      }
    } finally {
      if (mounted && request == _catalogPreviewRequestSerial) {
        setState(() => _catalogPreviewLoading = false);
      }
    }
  }

  void _openCatalog([LKVolume? requestedVolume]) {
    final book = _book;
    final volume = requestedVolume ?? _initialCatalogVolume;
    if (book == null || volume == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChaptersPage(
          bookId: book.bookId,
          volumeId: volume.volumeId,
          volumeTitle: volume.title,
          bookTitle: book.title,
          totalChapterCount: _chapterTotalFor(volume),
          currentChapterId: _readChapterId,
          volumes: _volumes,
        ),
      ),
    );
  }

  Future<void> _loadLibraryState() async {
    if (LKClient.shared.session.isLoggedIn) {
      try {
        final st = await LKApi.client.post(
            '/api/new-content-read/get-book-library-state',
            LKApi.client.authed({'book_id': widget.bookId}));
        if (!mounted) return;
        final historyRaw = st['history'];
        final history = historyRaw is Map
            ? Map<String, dynamic>.from(historyRaw)
            : const <String, dynamic>{};
        final hasHistory = _bookDetailFlag(st['has_history']);
        setState(() {
          _inShelf = _bookDetailFlag(st['in_shelf']);
          _hasHistory = hasHistory;
          _readChapterId = _bookDetailInt(st['last_read_chapter_id'] ??
              history['chapter_id'] ??
              (hasHistory ? st['latest_chapter_id'] : null));
          _readVolumeId =
              _bookDetailInt(st['last_read_volume_id'] ?? history['volume_id']);
          if (_readVolumeId <= 0) {
            _readVolumeId = _book?.defaultVolumeId ?? 0;
          }
          _readChapterTitle =
              (st['last_read_chapter_title'] ?? history['chapter_title'] ?? '')
                  .toString();
        });
      } catch (_) {}
      return;
    }
    if (await LKStore.isLocalShelf(widget.bookId) && mounted) {
      setState(() => _inShelf = true);
    }
  }

  Future<void> _toggleShelf() async {
    final add = !_inShelf;
    try {
      if (LKClient.shared.session.isLoggedIn) {
        await LKApi.toggleShelf(widget.bookId, add);
        final book = _book;
        if (book != null) {
          await LKStore.setLocalShelf(book, add);
        }
      } else {
        final book = _book;
        if (book == null) {
          if (mounted) showLkError(context, '书籍信息仍在加载,请稍后再试');
          return;
        }
        await LKStore.setLocalShelf(book, add);
      }
      if (mounted) setState(() => _inShelf = add);
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  void _openReading() {
    final b = _book;
    if (b == null) return;
    final chapterId = _readChapterId > 0 ? _readChapterId : b.defaultChapterId;
    final volumeId = _readVolumeId > 0 ? _readVolumeId : b.defaultVolumeId;
    if (chapterId > 0) {
      Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ReaderPage(
                  bookId: b.bookId,
                  bookTitle: b.title,
                  chapterId: chapterId,
                  chapterTitle: _readChapterTitle,
                  volumeId: volumeId,
                )),
      );
      return;
    }
    if (_volumes.isNotEmpty) _openCatalog();
  }

  String get _fabLabel {
    if (_hasHistory && _readChapterId > 0) {
      return _readChapterTitle.isEmpty ? '继续阅读' : '继续阅读 · $_readChapterTitle';
    }
    return '开始阅读';
  }

  Future<void> _togglePublisherFollow() async {
    final book = _book;
    if (_publisherFollowBusy || book == null || book.publisherUid <= 0) return;
    final session = LKClient.shared.session;
    if (!session.isLoggedIn) {
      if (!mounted) return;
      await Navigator.push(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
      if (!mounted || !LKClient.shared.session.isLoggedIn) return;
      setState(() => _bindPublisher(book));
      await _refreshPublisherFollowStatus(book, forceRefresh: true);
      return;
    }
    if (session.uid == book.publisherUid) return;

    final request = _publisherRelation.beginMutation();
    final follow = !_publisherFollowed;
    setState(() => _publisherFollowBusy = true);
    try {
      await LKApi.toggleFollow(book.publisherUid, follow);
      if (!mounted || !_publisherRelation.isCurrent(request)) return;
      setState(() => _publisherRelation.complete(request, follow));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(follow ? '已关注' : '已取消关注')),
      );
    } catch (e) {
      if (mounted && _publisherRelation.isCurrent(request)) {
        showLkError(context, '操作失败：$e');
      }
    } finally {
      if (mounted && _publisherRelation.isCurrent(request)) {
        setState(() {
          _publisherRelation.fail(request);
          _publisherFollowBusy = false;
        });
      }
    }
  }

  void _bindPublisher(LKBook book) {
    final session = LKClient.shared.session;
    final changed = _publisherRelation.bind(
      viewerUid: session.isLoggedIn ? session.uid : 0,
      targetUid: book.publisherUid,
      initialValue: session.isLoggedIn && book.publisherFollowed,
    );
    if (changed) _publisherFollowBusy = false;
  }

  void _onPublisherSessionChanged() {
    final book = _book;
    if (!mounted || book == null) return;
    setState(() => _bindPublisher(book));
    unawaited(_refreshPublisherFollowStatus(book, forceRefresh: true));
  }

  Future<void> _openPublisherProfile(LKBook book) async {
    await openUserProfile(context, book.publisherUid);
    if (!mounted || _book?.publisherUid != book.publisherUid) return;
    await _refreshPublisherFollowStatus(book, forceRefresh: true);
  }

  Future<void> _refreshPublisherFollowStatus(LKBook book,
      {bool forceRefresh = false}) async {
    final session = LKClient.shared.session;
    if (_publisherFollowBusy ||
        !session.isLoggedIn ||
        book.publisherUid <= 0 ||
        session.uid == book.publisherUid) {
      return;
    }
    final viewerUid = session.uid;
    final request = _publisherRelation.beginRefresh(force: forceRefresh);
    if (request == null) return;
    try {
      // poster_user.followed 只属于书籍响应；用户主页的 relation.followed
      // 是针对当前登录账号重新计算的关系状态。
      final page = await LKApi.publicUserHome(book.publisherUid, 1,
          pageSize: 1, forceRefresh: true);
      if (!mounted ||
          !_publisherRelation.isCurrent(request) ||
          viewerUid != LKClient.shared.session.uid ||
          _book?.publisherUid != book.publisherUid ||
          _publisherFollowBusy) {
        return;
      }
      setState(
          () => _publisherRelation.complete(request, page.profile.followed));
    } catch (_) {
      _publisherRelation.fail(request);
      // 关系查询失败时保留 publisher 接口中的初始状态，不阻塞详情页。
    }
  }

  void _showFullBookTitle(String title) {
    final value = title.trim();
    if (value.isEmpty || !mounted) return;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(value,
              style: TextStyle(
                  color: isDark ? scheme.onSurface : scheme.onInverseSurface)),
          backgroundColor:
              isDark ? scheme.surfaceContainerHighest : scheme.inverseSurface,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  }

  Widget _publisherRow(LKBook book) {
    final scheme = Theme.of(context).colorScheme;
    final name =
        book.publisherName.trim().isEmpty ? '未知用户' : book.publisherName.trim();
    final canOpenProfile = book.publisherUid > 0;
    final canFollow = canOpenProfile &&
        (!LKClient.shared.session.isLoggedIn ||
            LKClient.shared.session.uid != book.publisherUid);
    return InkWell(
      onTap: canOpenProfile ? () => _openPublisherProfile(book) : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: scheme.primary.withValues(alpha: 0.12),
              backgroundImage: book.publisherAvatar.trim().isNotEmpty
                  ? YomiruAvatarCache.provider(book.publisherAvatar)
                  : null,
              child: book.publisherAvatar.trim().isEmpty
                  ? Icon(Icons.person_outline_rounded,
                      size: 17, color: scheme.primary)
                  : null,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            if (canFollow)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 64,
                  height: 32,
                  child: OutlinedButton(
                    onPressed:
                        _publisherFollowBusy ? null : _togglePublisherFollow,
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      shape: const StadiumBorder(),
                    ),
                    child: Text(_publisherFollowed ? '已关注' : '关注'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = _book;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: _error != null && b == null
          ? Center(
              child: Text(_error!, style: const TextStyle(color: Colors.grey)))
          : b == null
              ? const LkLoadingIndicator()
              : RefreshIndicator(
                  onRefresh: () => _load(forceRefresh: true),
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    controller: _scroll,
                    slivers: [
                      SliverAppBar(
                        pinned: true,
                        elevation: 0,
                        scrolledUnderElevation: 0.5,
                        backgroundColor:
                            isDark ? const Color(0xFF1B1C21) : Colors.white,
                        foregroundColor:
                            isDark ? Colors.white : const Color(0xFF263238),
                        expandedHeight: 8,
                        title: GestureDetector(
                          onTap: () => _showFullBookTitle(b.title),
                          child: Text(b.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: double.infinity,
                                child: Card(
                                  margin: EdgeInsets.zero,
                                  clipBehavior: Clip.antiAlias,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        14, 14, 14, 12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            CoverImage(
                                                url: b.coverUrl,
                                                width: 112,
                                                height: 152,
                                                radius: 10),
                                            const SizedBox(width: 16),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  InkWell(
                                                    onTap: () =>
                                                        _showFullBookTitle(
                                                            b.title),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            6),
                                                    child: Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          vertical: 2),
                                                      child: Text(b.title,
                                                          maxLines: 3,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              const TextStyle(
                                                                  fontSize: 18,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                  height: 1.3)),
                                                    ),
                                                  ),
                                                  if (b.authorName
                                                      .trim()
                                                      .isNotEmpty) ...[
                                                    const SizedBox(height: 8),
                                                    Text('作者: ${b.authorName}',
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                            fontSize: 13,
                                                            color: Colors.grey
                                                                .shade600)),
                                                  ],
                                                  const SizedBox(height: 8),
                                                  Row(children: [
                                                    _miniBadge(
                                                        scheme,
                                                        b.isCompleted
                                                            ? '完结'
                                                            : '连载'),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                        '${b.volumeCount}卷 · ${b.chapterCount}章',
                                                        style: TextStyle(
                                                            fontSize: 12,
                                                            color: Colors.grey
                                                                .shade500)),
                                                  ]),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    b.wordCount >= 10000
                                                        ? '${(b.wordCount / 10000).toStringAsFixed(1)} 万字'
                                                        : '${b.wordCount} 字',
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color: Colors
                                                            .grey.shade500),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (b.publisherUid > 0 ||
                                            b.publisherName.trim().isNotEmpty ||
                                            b.publisherAvatar
                                                .trim()
                                                .isNotEmpty) ...[
                                          const SizedBox(height: 12),
                                          const LkFadedDivider(),
                                          const SizedBox(height: 10),
                                          _publisherRow(b),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              if (b.tags.isNotEmpty) ...[
                                const SizedBox(height: 14),
                                SizedBox(
                                  height: 32,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: b.tags.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(width: 8),
                                    itemBuilder: (_, i) => GestureDetector(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) => SearchPage(
                                                initialTag: b.tags[i])),
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 5),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: scheme.primary
                                              .withValues(alpha: 0.08),
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        ),
                                        child: Text(b.tags[i],
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: scheme.primary)),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 14),
                              Row(children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _toggleShelf,
                                    icon: Icon(
                                        _inShelf
                                            ? Icons.bookmark_added_rounded
                                            : Icons.bookmark_add_outlined,
                                        size: 18),
                                    label: Text(_inShelf ? '已加书架' : '加入书架'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => CommentsPage(
                                              bookId: b.bookId,
                                              bookTitle: b.title)),
                                    ),
                                    icon: const Icon(Icons.chat_bubble_outline,
                                        size: 18),
                                    label: const Text('书评'),
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 18),
                              const Text('简介',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 6),
                              Text(b.summary,
                                  style: TextStyle(
                                      height: 1.6,
                                      fontSize: 13.5,
                                      color: Colors.grey.shade700)),
                              const SizedBox(height: 18),
                              Row(children: [
                                const Text('目录',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold)),
                                const Spacer(),
                                if (_usesPagedCatalog || _canExpandAllVolumes)
                                  TextButton.icon(
                                    onPressed: _usesPagedCatalog
                                        ? (_volumes.isEmpty
                                            ? null
                                            : () => _openCatalog())
                                        : (_loadingAllVolumes
                                            ? null
                                            : _toggleAllVolumes),
                                    icon: Icon(_usesPagedCatalog
                                        ? Icons.format_list_bulleted_rounded
                                        : _allVolumesExpanded
                                            ? Icons.unfold_less_rounded
                                            : Icons.unfold_more_rounded),
                                    label: Text(_usesPagedCatalog
                                        ? '展开目录'
                                        : _loadingAllVolumes
                                            ? '加载中'
                                            : _allVolumesExpanded
                                                ? '收起全部'
                                                : '展开全部'),
                                  ),
                                Text('${b.volumeCount} 卷',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade500)),
                              ]),
                              const SizedBox(height: 8),
                              if (_volumesLoading && _volumes.isEmpty)
                                const LkLoadingIndicator(
                                  minHeight: 72,
                                  size: 22,
                                  strokeWidth: 2,
                                ),
                              if (!_volumesLoading &&
                                  _volumesError != null &&
                                  _volumes.isEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Center(
                                    child: TextButton.icon(
                                      onPressed: _loadVolumes,
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: Text(_volumesError!),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (_volumes.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          sliver: SliverList.builder(
                            itemCount:
                                _volumes.length + (_volumesHasMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index < _volumes.length) {
                                return _volumeCard(_volumes[index]);
                              }
                              if (_volumesError != null) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Center(
                                    child: TextButton.icon(
                                      onPressed: () =>
                                          _loadVolumes(append: true),
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: const Text('更多目录加载失败，点击重试'),
                                    ),
                                  ),
                                );
                              }
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  unawaited(_loadVolumes(append: true));
                                }
                              });
                              return const LkLoadingIndicator(
                                minHeight: 64,
                                size: 20,
                                strokeWidth: 2,
                              );
                            },
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 90 + MediaQuery.of(context).padding.bottom,
                        ),
                      ),
                    ],
                  ),
                ),
      floatingActionButton: AnimatedSlide(
        duration: const Duration(milliseconds: 200),
        offset: _fabVisible ? Offset.zero : const Offset(0, 2),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _fabVisible ? 1 : 0,
          child: FloatingActionButton.extended(
            onPressed: _fabVisible ? _openReading : null,
            icon: const Icon(Icons.menu_book_rounded),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child:
                  Text(_fabLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ),
    );
  }

  Widget _miniBadge(ColorScheme scheme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
            color: scheme.primary.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10,
              color: scheme.primary,
              fontWeight: FontWeight.w500)),
    );
  }

  Widget _pagedVolumeCard(LKVolume volume) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showPreview = _initialCatalogVolume?.volumeId == volume.volumeId;
    final total = _chapterTotalFor(volume);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isDark ? const Color(0xFF1E2025) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => _openCatalog(volume),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Expanded(
                    child: Text(volume.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  if (total > 0) ...[
                    const SizedBox(width: 8),
                    Text('$total 章',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500)),
                  ],
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right_rounded,
                      color: Colors.grey.shade400),
                ]),
              ),
            ),
            if (showPreview &&
                _catalogPreviewLoading &&
                _catalogPreview.isEmpty)
              const LkLoadingIndicator(
                minHeight: 64,
                size: 20,
                strokeWidth: 2,
              ),
            if (showPreview &&
                !_catalogPreviewLoading &&
                _catalogPreviewError != null &&
                _catalogPreview.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Center(
                  child: TextButton.icon(
                    onPressed: _loadCatalogPreview,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(_catalogPreviewError!),
                  ),
                ),
              ),
            if (showPreview && _catalogPreview.isNotEmpty) ...[
              const LkFadedDivider(),
              ..._chapterRows(volume, _catalogPreview),
              const LkFadedDivider(),
              TextButton.icon(
                onPressed: () => _openCatalog(volume),
                icon: const Icon(Icons.format_list_bulleted_rounded, size: 18),
                label: Text(total > _catalogPreview.length
                    ? '查看全部 $total 章'
                    : '查看完整目录'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _volumeCard(LKVolume v) {
    if (_volumeUsesPagedCatalog(v)) return _pagedVolumeCard(v);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final expanded = _expandedVolumeIds.contains(v.volumeId);
    final chs = _volumeChapters[v.volumeId];
    final total = _chapterTotalFor(v);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isDark ? const Color(0xFF1E2025) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => _toggleVolume(v),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Expanded(
                    child: Text(v.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  if (total > 0) ...[
                    const SizedBox(width: 8),
                    Text('$total 章',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500)),
                  ],
                  const SizedBox(width: 4),
                  // 加载状态显示在展开后的章节区域，卷标题行始终保持
                  // 箭头，避免“X章”旁边出现突兀的转圈动画。
                  Icon(
                      expanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.chevron_right_rounded,
                      color: Colors.grey.shade400),
                ]),
              ),
            ),
            if (expanded) ..._chapterRows(v, chs),
          ],
        ),
      ),
    );
  }

  /// 点击卷:就地展开/收起章节列表(首次展开时加载)
  Future<void> _toggleVolume(LKVolume v) async {
    if (_chapterTotalFor(v) == 1) {
      await _openSingleChapterVolume(v);
      return;
    }
    if (_volumeUsesPagedCatalog(v)) {
      _openCatalog(v);
      return;
    }
    final id = v.volumeId;
    if (_expandedVolumeIds.contains(id)) {
      setState(() => _expandedVolumeIds.remove(id));
      return;
    }
    setState(() {
      _expandedVolumeIds.add(id);
      _volumeErrors.remove(id);
    });
    await _loadVolumeChapters(v);
  }

  Future<void> _openSingleChapterVolume(LKVolume volume) async {
    final book = _book;
    if (book == null || _loadingVolumeIds.contains(volume.volumeId)) return;
    final cached = _volumeChapters[volume.volumeId];
    var chapterId = cached?.isNotEmpty == true
        ? cached!.first.chapterId
        : volume.firstChapterId > 0
            ? volume.firstChapterId
            : volume.lastChapterId;
    var chapterTitle =
        cached?.isNotEmpty == true ? cached!.first.title : volume.title;

    if (chapterId <= 0) {
      setState(() => _loadingVolumeIds.add(volume.volumeId));
      try {
        final page = await LKApi.chapterPage(
          book.bookId,
          volume.volumeId,
          1,
          pageSize: 1,
        );
        if (!mounted) return;
        if (page.items.isEmpty) {
          showLkError(context, '该卷暂时没有可阅读章节');
          return;
        }
        final chapter = page.items.first;
        chapterId = chapter.chapterId;
        chapterTitle = chapter.title;
        _volumeChapters[volume.volumeId] = [chapter];
      } catch (error) {
        if (mounted) showLkError(context, error);
        return;
      } finally {
        if (mounted) {
          setState(() => _loadingVolumeIds.remove(volume.volumeId));
        }
      }
    }
    if (!mounted || chapterId <= 0) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          bookId: book.bookId,
          bookTitle: book.title,
          chapterId: chapterId,
          chapterTitle: chapterTitle,
          volumeId: volume.volumeId,
        ),
      ),
    );
  }

  bool get _allVolumesExpanded =>
      _volumes.isNotEmpty &&
      _volumes.every((volume) => _expandedVolumeIds.contains(volume.volumeId));

  Future<void> _toggleAllVolumes() async {
    if (!_canExpandAllVolumes) return;
    if (_usesPagedCatalog) {
      _openCatalog();
      return;
    }
    if (_volumes.isEmpty) return;
    if (_allVolumesExpanded) {
      setState(_expandedVolumeIds.clear);
      return;
    }
    setState(() {
      _expandedVolumeIds.addAll(_volumes.map<int>((volume) => volume.volumeId));
      _volumeErrors.clear();
      _loadingAllVolumes = true;
    });
    final pending = _volumes
        .where((volume) => !_volumeChapters.containsKey(volume.volumeId))
        .toList();
    try {
      // 保持并行加载，但限制并发数，避免卷数较多时瞬间压满网络连接。
      var next = 0;
      final workerCount = pending.length < 4 ? pending.length : 4;
      Future<void> worker() async {
        while (next < pending.length) {
          final volume = pending[next++];
          await _loadVolumeChapters(volume);
        }
      }

      await Future.wait(List.generate(workerCount, (_) => worker()));
    } finally {
      if (mounted) setState(() => _loadingAllVolumes = false);
    }
  }

  Future<void> _loadVolumeChapters(LKVolume v,
      {bool forceRefresh = false}) async {
    final id = v.volumeId;
    final book = _book;
    if (book == null) return;
    if (!forceRefresh &&
        (_loadingVolumeIds.contains(id) || _volumeChapters.containsKey(id))) {
      return;
    }
    final request = (_volumeChapterRequests[id] ?? 0) + 1;
    _volumeChapterRequests[id] = request;
    if (mounted) {
      setState(() {
        _loadingVolumeIds.add(id);
        _volumeErrors.remove(id);
      });
    }
    try {
      final chs =
          await LKApi.allChapters(book.bookId, id, forceRefresh: forceRefresh);
      if (!mounted || _volumeChapterRequests[id] != request) return;
      setState(() {
        _volumeChapters[id] = chs;
        _volumeErrors.remove(id);
      });
    } catch (_) {
      if (!mounted || _volumeChapterRequests[id] != request) return;
      setState(() => _volumeErrors[id] = '连接失败，请检查网络后重试');
    } finally {
      if (mounted && _volumeChapterRequests[id] == request) {
        setState(() => _loadingVolumeIds.remove(id));
      }
    }
  }

  List<Widget> _chapterRows(LKVolume v, List<LKChapter>? chs) {
    final book = _book;
    if (book == null) return const [];
    if (chs == null) {
      if (_volumeErrors[v.volumeId] != null) {
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
            child: Center(
              child: TextButton.icon(
                onPressed: () => _loadVolumeChapters(v),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('章节加载失败，点击重试'),
              ),
            ),
          ),
        ];
      }
      return const [
        Padding(
          padding: EdgeInsets.fromLTRB(14, 2, 14, 14),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ];
    }
    return chs
        .map((c) => InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ReaderPage(
                          bookId: book.bookId,
                          bookTitle: book.title,
                          chapterId: c.chapterId,
                          chapterTitle: c.title,
                          volumeId: v.volumeId,
                        )),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  if (c.braveOnly) _braveAccessBadge(context),
                  Expanded(
                    child: Text(c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    c.wordCount >= 10000
                        ? '${(c.wordCount / 10000).toStringAsFixed(1)}万字'
                        : '${c.wordCount}字',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                  if (c.locked && !c.unlocked)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.lock_outline,
                          size: 14, color: Colors.grey),
                    ),
                ]),
              ),
            ))
        .toList();
  }
}

/// 卷内章节列表
class ChaptersPage extends StatefulWidget {
  final int bookId;
  final int volumeId;
  final String volumeTitle;
  final String bookTitle;
  final int totalChapterCount;
  final int currentChapterId;
  final List<LKVolume> volumes;
  const ChaptersPage({
    super.key,
    required this.bookId,
    required this.volumeId,
    required this.volumeTitle,
    required this.bookTitle,
    this.totalChapterCount = 0,
    this.currentChapterId = 0,
    this.volumes = const [],
  });

  @override
  State<ChaptersPage> createState() => _ChaptersPageState();
}

class _ChaptersPageState extends State<ChaptersPage> {
  static const int _pageSize = 50;

  final ScrollController _scroll = ScrollController();
  List<LKChapter> _chapters = const [];
  String? _error;
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _descending = false;
  int _total = 0;
  late int _volumeId;
  late String _volumeTitle;
  int _loadedLogicalPages = 0;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    _volumeId = widget.volumeId;
    _volumeTitle = widget.volumeTitle;
    _total = widget.totalChapterCount;
    _scroll.addListener(_handleScroll);
    _loadPage(reset: true);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  List<LKVolume> get _availableVolumes => widget.volumes.isNotEmpty
      ? widget.volumes
      : [
          LKVolume(
            volumeId: widget.volumeId,
            title: widget.volumeTitle,
            chapterCount: widget.totalChapterCount,
          ),
        ];

  Future<void> _selectVolume(int volumeId) async {
    if (volumeId == _volumeId) return;
    LKVolume? selected;
    for (final volume in _availableVolumes) {
      if (volume.volumeId == volumeId) {
        selected = volume;
        break;
      }
    }
    if (selected == null) return;
    setState(() {
      _volumeId = selected!.volumeId;
      _volumeTitle = selected.title;
      _total = selected.chapterCount;
      _descending = false;
      _error = null;
    });
    await _loadPage(reset: true);
    if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
  }

  void _handleScroll() {
    if (!_scroll.hasClients) return;
    if (shouldLoadNextCatalogPage(
      extentAfter: _scroll.position.extentAfter,
      hasMore: _hasMore,
      loading: _initialLoading || _loadingMore,
      hasError: _error != null,
    )) {
      unawaited(_loadPage());
    }
  }

  void _scheduleFillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (shouldLoadNextCatalogPage(
        extentAfter: _scroll.position.extentAfter,
        hasMore: _hasMore,
        loading: _initialLoading || _loadingMore,
        hasError: _error != null,
      )) {
        unawaited(_loadPage());
      }
    });
  }

  Future<void> _refresh() => _loadPage(reset: true, forceRefresh: true);

  Future<void> _loadPage(
      {bool reset = false, bool forceRefresh = false}) async {
    if (!reset && (_initialLoading || _loadingMore || !_hasMore)) {
      return;
    }
    final request = reset ? ++_requestSerial : _requestSerial;
    final logicalPage = reset ? 1 : _loadedLogicalPages + 1;
    setState(() {
      if (reset) {
        _chapters = const [];
        _loadedLogicalPages = 0;
        _hasMore = true;
        _initialLoading = true;
        _loadingMore = false;
      } else {
        _loadingMore = true;
      }
      _error = null;
    });
    try {
      final sourcePage = catalogSourcePage(
        logicalPage: logicalPage,
        total: _total,
        pageSize: _pageSize,
        descending: _descending,
      );
      final page = await LKApi.chapterPage(widget.bookId, _volumeId, sourcePage,
          pageSize: _pageSize, forceRefresh: forceRefresh);
      if (!mounted || request != _requestSerial) return;
      final pageItems = _descending
          ? page.items.reversed.toList(growable: false)
          : page.items;
      final merged = reset ? <LKChapter>[] : List<LKChapter>.of(_chapters);
      final seen = merged
          .map((chapter) =>
              '${chapter.chapterId}:${chapter.chapterNo}:${chapter.title}')
          .toSet();
      for (final chapter in pageItems) {
        final key =
            '${chapter.chapterId}:${chapter.chapterNo}:${chapter.title}';
        if (seen.add(key)) merged.add(chapter);
      }
      final total = page.total > 0 ? page.total : _total;
      setState(() {
        _chapters = merged;
        _total = total;
        _loadedLogicalPages = logicalPage;
        _hasMore = page.items.isNotEmpty &&
            (_descending ? sourcePage > 1 : page.hasMore);
        _error = null;
      });
    } catch (e) {
      if (mounted && request == _requestSerial) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && request == _requestSerial) {
        setState(() {
          _initialLoading = false;
          _loadingMore = false;
        });
        _scheduleFillViewport();
      }
    }
  }

  Future<void> _setDescending(bool value) async {
    if (_descending == value || _initialLoading || _loadingMore) return;
    if (value && _total <= 0) return;
    setState(() => _descending = value);
    await _loadPage(reset: true);
    if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
  }

  String get _progressLabel => _total > 0
      ? '已加载 ${_chapters.length} / $_total'
      : '已加载 ${_chapters.length} 章';

  Widget _centeredList(Widget child) => ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.7,
            child: Center(child: child),
          ),
        ],
      );

  Widget _footer() {
    if (_loadingMore) {
      return const SizedBox(
        height: 72,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_error != null) {
      return SizedBox(
        height: 72,
        child: Center(
          child: TextButton.icon(
            onPressed: _loadPage,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    return SizedBox(
      height: 64,
      child: Center(
        child: Text(
          _hasMore ? '继续下滑加载' : '已加载全部章节',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.bookTitle.isEmpty ? '章节列表' : widget.bookTitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              _chapters.isEmpty
                  ? _volumeTitle
                  : '$_volumeTitle · $_progressLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.normal,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.58)),
            ),
          ],
        ),
        actions: [
          if (_availableVolumes.length > 1)
            PopupMenuButton<int>(
              tooltip: '切换分卷',
              icon: const Icon(Icons.library_books_outlined),
              onSelected: _selectVolume,
              itemBuilder: (_) => _availableVolumes
                  .map((volume) => CheckedPopupMenuItem<int>(
                        value: volume.volumeId,
                        checked: volume.volumeId == _volumeId,
                        child: SizedBox(
                          width: 240,
                          child: Row(children: [
                            Expanded(
                              child: Text(volume.title,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                            ),
                            if (volume.chapterCount > 0) ...[
                              const SizedBox(width: 8),
                              Text('${volume.chapterCount} 章',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade500)),
                            ],
                          ]),
                        ),
                      ))
                  .toList(growable: false),
            ),
          IconButton(
            tooltip: _descending ? '当前倒序，点击切换为正序' : '当前正序，点击切换为倒序',
            onPressed: _total > 0 && !_initialLoading && !_loadingMore
                ? () => _setDescending(!_descending)
                : null,
            icon: Icon(_descending
                ? Icons.arrow_downward_rounded
                : Icons.arrow_upward_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _initialLoading && _chapters.isEmpty
            ? _centeredList(const LkLoadingIndicator())
            : _error != null && _chapters.isEmpty
                ? _centeredList(
                    TextButton.icon(
                      onPressed: () => _loadPage(reset: true),
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(_error!),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).padding.bottom),
                    itemCount: _chapters.length + 1,
                    itemBuilder: (_, i) {
                      if (i == _chapters.length) return _footer();
                      final c = _chapters[i];
                      return Column(
                        key: ValueKey('chapter-${c.chapterId}'),
                        children: [
                          ListTile(
                            selected: c.chapterId == widget.currentChapterId,
                            selectedTileColor: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.08),
                            // 网站标题本身已含"第X章",不再重复拼接
                            title: Row(children: [
                              if (c.braveOnly) _braveAccessBadge(context),
                              Expanded(
                                child: Text(c.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ]),
                            subtitle: Text(c.wordCount >= 10000
                                ? '${(c.wordCount / 10000).toStringAsFixed(1)}万字'
                                : '${c.wordCount}字'),
                            trailing: c.locked && !c.unlocked
                                ? const Icon(Icons.lock_outline, size: 18)
                                : null,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => ReaderPage(
                                        bookId: widget.bookId,
                                        bookTitle: widget.bookTitle,
                                        chapterId: c.chapterId,
                                        chapterTitle: c.title,
                                        volumeId: _volumeId,
                                      )),
                            ),
                          ),
                          const LkFadedDivider(),
                        ],
                      );
                    },
                  ),
      ),
    );
  }
}
