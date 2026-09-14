import '../services/app_motion.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/models.dart';
import '../widgets/common.dart';
import 'catalog_paging.dart';

/// 阅读器目录弹层:卷就地展开章节,点章节跳转;打开时自动定位当前卷/章
class ReaderCatalogSheet extends StatefulWidget {
  final int bookId;
  final int volumeId;
  final int currentChapterId;
  final int currentChapterNo;
  final void Function(int chapterId, String title, int volumeId) onPick;
  const ReaderCatalogSheet(
      {super.key,
      required this.bookId,
      required this.volumeId,
      required this.currentChapterId,
      required this.currentChapterNo,
      required this.onPick});

  @override
  State<ReaderCatalogSheet> createState() => _ReaderCatalogSheetState();
}

class _ReaderCatalogSheetState extends State<ReaderCatalogSheet> {
  static const int _pageSize = 50;
  static const int _volumePageSize = 50;

  List<LKVolume> _volumes = const [];
  String? _error;
  int _volumesPage = 0;
  bool _volumesHasMore = true;
  bool _volumePageLoading = false;
  int? _expanded;
  final Map<int, List<LKChapter>> _chapters = {};
  final Set<int> _loadingVolumes = <int>{};
  final Set<int> _openingSingleVolumes = <int>{};
  final Map<int, String> _chapterErrors = <int, String>{};
  final Map<int, int> _failedChapterPages = <int, int>{};
  final Map<int, Set<int>> _loadedChapterPages = <int, Set<int>>{};
  final Map<int, int> _chapterTotals = <int, int>{};
  final Map<int, bool> _maxPageHasMore = <int, bool>{};
  final ScrollController _sc = ScrollController();
  final Map<int, GlobalKey> _volKeys = {};
  final GlobalKey _curChapterKey = GlobalKey();
  bool _located = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.volumeId; // 打开即展开当前卷
    unawaited(_loadVolumes());
    // 当前卷与卷列表互不依赖，先加载当前章节所在分页即可立即使用目录。
    if (widget.volumeId > 0) unawaited(_loadChapters(widget.volumeId));
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  Future<void> _loadVolumes({bool append = false}) async {
    if (_volumePageLoading || (append && !_volumesHasMore)) return;
    final page = append ? _volumesPage + 1 : 1;
    setState(() {
      _volumePageLoading = true;
      _error = null;
    });
    try {
      final pageItems = await LKApi.volumes(
        widget.bookId,
        page,
        pageSize: _volumePageSize,
      );
      if (!mounted) return;
      final seen =
          append ? _volumes.map((volume) => volume.volumeId).toSet() : <int>{};
      final merged = [
        if (append) ..._volumes,
        ...pageItems.where((volume) => seen.add(volume.volumeId)),
      ];
      setState(() {
        _volumes = merged;
        _volumesPage = page;
        _volumesHasMore = pageItems.length >= _volumePageSize;
        _error = null;
      });
      if (widget.volumeId > 0 &&
          _displayVolumes.any((volume) => volume.volumeId == widget.volumeId)) {
        _revealCurrent();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = append ? '更多目录加载失败，点击重试' : '目录加载失败，请检查网络后重试');
      }
    } finally {
      if (mounted) setState(() => _volumePageLoading = false);
    }
  }

  /// 保留服务端返回的卷顺序，当前卷只通过“当前”标记突出显示。
  /// 当前卷不再被强行挪到列表顶部，避免目录顺序与网站不一致。
  List<LKVolume> get _displayVolumes => _volumes;

  LKVolume? _volumeFor(int volumeId) {
    for (final volume in _volumes) {
      if (volume.volumeId == volumeId) return volume;
    }
    return null;
  }

  int _initialPageFor(int volumeId) {
    if (volumeId != widget.volumeId || widget.currentChapterNo <= 0) return 1;
    return catalogPageForChapter(
      chapterNo: widget.currentChapterNo,
      total: _volumeFor(volumeId)?.chapterCount ?? 0,
      pageSize: _pageSize,
    );
  }

  int _totalFor(int volumeId) =>
      _chapterTotals[volumeId] ?? _volumeFor(volumeId)?.chapterCount ?? 0;

  int _pageCountFor(int volumeId) =>
      catalogPageCount(_totalFor(volumeId), _pageSize);

  bool _hasPreviousPage(int volumeId) {
    final pages = _loadedChapterPages[volumeId];
    return pages != null &&
        pages.isNotEmpty &&
        pages.reduce((a, b) => a < b ? a : b) > 1;
  }

  bool _hasNextPage(int volumeId) {
    final pages = _loadedChapterPages[volumeId];
    if (pages == null || pages.isEmpty) return false;
    final maxPage = pages.reduce((a, b) => a > b ? a : b);
    final pageCount = _pageCountFor(volumeId);
    return pageCount > 0
        ? maxPage < pageCount
        : (_maxPageHasMore[volumeId] ?? false);
  }

  Future<void> _loadChapters(int vid, {int? page}) async {
    final targetPage = page ?? _initialPageFor(vid);
    if ((_loadedChapterPages[vid]?.contains(targetPage) ?? false) ||
        _loadingVolumes.contains(vid)) {
      return;
    }
    setState(() {
      _loadingVolumes.add(vid);
      _chapterErrors.remove(vid);
      _failedChapterPages.remove(vid);
    });
    try {
      var loadedPage = targetPage;
      var result = await LKApi.chapterPage(widget.bookId, vid, loadedPage,
          pageSize: _pageSize);
      final currentChapterMissing = vid == widget.volumeId &&
          widget.currentChapterId > 0 &&
          !result.items
              .any((chapter) => chapter.chapterId == widget.currentChapterId);
      // 少数响应的 chapter_no 是全书序号。若它把单章卷定位到了不存在
      // 的后续分页，退回第一页即可找到当前章。
      if (loadedPage > 1 &&
          currentChapterMissing &&
          (result.items.isEmpty || result.total <= _pageSize)) {
        loadedPage = 1;
        result = await LKApi.chapterPage(widget.bookId, vid, loadedPage,
            pageSize: _pageSize);
      }
      if (!mounted) return;
      final loadedPages = _loadedChapterPages[vid] ?? const <int>{};
      final existing = _chapters[vid] ?? const <LKChapter>[];
      final minLoadedPage = loadedPages.isEmpty
          ? loadedPage
          : loadedPages.reduce((a, b) => a < b ? a : b);
      final candidates = loadedPage < minLoadedPage
          ? [...result.items, ...existing]
          : [...existing, ...result.items];
      final seen = <int>{};
      final merged = candidates
          .where((chapter) => seen.add(chapter.chapterId))
          .toList(growable: false);
      final maxLoadedPage = loadedPages.isEmpty
          ? loadedPage
          : loadedPages.reduce((a, b) => a > b ? a : b);
      setState(() {
        _chapters[vid] = merged;
        _loadedChapterPages[vid] = {...loadedPages, loadedPage};
        _chapterTotals[vid] = result.total > 0
            ? result.total
            : (_volumeFor(vid)?.chapterCount ?? merged.length);
        if (loadedPage >= maxLoadedPage) {
          _maxPageHasMore[vid] = result.hasMore;
        }
      });
      if (vid == widget.volumeId) _revealCurrent();
    } catch (_) {
      if (mounted) {
        setState(() {
          _chapterErrors[vid] = '章节加载失败，请检查网络后重试';
          _failedChapterPages[vid] = targetPage;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingVolumes.remove(vid));
    }
  }

  Future<void> _loadPreviousPage(int volumeId) async {
    final pages = _loadedChapterPages[volumeId];
    if (pages == null || pages.isEmpty) return;
    final page = pages.reduce((a, b) => a < b ? a : b) - 1;
    if (page > 0) await _loadChapters(volumeId, page: page);
  }

  Future<void> _loadNextPage(int volumeId) async {
    final pages = _loadedChapterPages[volumeId];
    if (pages == null || pages.isEmpty) return;
    final page = pages.reduce((a, b) => a > b ? a : b) + 1;
    await _loadChapters(volumeId, page: page);
  }

  int _chapterCountFor(LKVolume volume) {
    final loadedTotal = _chapterTotals[volume.volumeId] ?? 0;
    if (loadedTotal > 0) return loadedTotal;
    if (volume.chapterCount > 0) return volume.chapterCount;
    if (volume.firstChapterId > 0 &&
        volume.firstChapterId == volume.lastChapterId) {
      return 1;
    }
    return 0;
  }

  Future<void> _toggle(LKVolume volume) async {
    final vid = volume.volumeId;
    if (_chapterCountFor(volume) == 1) {
      await _openSingleChapterVolume(volume);
      return;
    }
    if (_expanded == vid) {
      setState(() => _expanded = null);
      return;
    }
    setState(() => _expanded = vid);
    unawaited(_loadChapters(vid));
  }

  Future<void> _openSingleChapterVolume(LKVolume volume) async {
    final vid = volume.volumeId;
    if (vid <= 0 || !_openingSingleVolumes.add(vid)) return;
    if (mounted) setState(() {});
    try {
      final cached = _chapters[vid];
      var chapterId = cached?.isNotEmpty == true
          ? cached!.first.chapterId
          : volume.firstChapterId > 0
              ? volume.firstChapterId
              : volume.lastChapterId;
      var chapterTitle =
          cached?.isNotEmpty == true ? cached!.first.title : volume.title;
      if (chapterId <= 0) {
        final page = await LKApi.chapterPage(
          widget.bookId,
          vid,
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
      }
      if (mounted) widget.onPick(chapterId, chapterTitle, vid);
    } catch (_) {
      if (mounted) showLkError(context, '章节加载失败，请检查网络后重试');
    } finally {
      _openingSingleVolumes.remove(vid);
      if (mounted) setState(() {});
    }
  }

  /// 滚动定位到当前卷与当前章节
  void _revealCurrent() {
    if (_located) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final volumes = _displayVolumes;
      if (volumes.isEmpty) return;
      final vi = volumes.indexWhere((v) => v.volumeId == widget.volumeId);
      if (vi < 0) return;
      // 1) 当前卷:已构建则 ensureVisible,否则按估计偏移跳
      final vctx = _volKeys[widget.volumeId]?.currentContext;
      if (vctx != null) {
        Scrollable.ensureVisible(vctx,
            duration: AppMotion.duration(context, 250), alignment: 0.15);
      } else if (_sc.hasClients) {
        final est = (vi * 56.0).clamp(0.0, _sc.position.maxScrollExtent);
        _sc.jumpTo(est);
      }
      // 2) 当前章节(在展开的当前卷内):已构建则精确定位,否则按行高估计
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final cctx = _curChapterKey.currentContext;
        if (cctx != null) {
          _located = true;
          Scrollable.ensureVisible(cctx,
              duration: AppMotion.duration(context, 250), alignment: 0.45);
          return;
        }
        final chs = _chapters[widget.volumeId];
        if (_sc.hasClients && chs != null) {
          final ci =
              chs.indexWhere((c) => c.chapterId == widget.currentChapterId);
          if (ci > 0) {
            final est = (vi * 56.0 + ci * 42.0)
                .clamp(0.0, _sc.position.maxScrollExtent);
            _sc.jumpTo(est);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              final ctx2 = _curChapterKey.currentContext;
              if (ctx2 != null) {
                _located = true;
                Scrollable.ensureVisible(ctx2,
                    duration: AppMotion.duration(context, 200),
                    alignment: 0.45);
              }
            });
          }
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final displayVolumes = _displayVolumes;
    final hasVolumeFooter =
        _volumePageLoading || _volumesHasMore || _error != null;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const Text('目录',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ]),
      ),
      Expanded(
        child: displayVolumes.isEmpty && _volumePageLoading
            ? const LkLoadingIndicator(minHeight: 120, size: 24)
            : displayVolumes.isEmpty && _error != null
                ? Center(
                    child: TextButton.icon(
                      onPressed: _volumePageLoading
                          ? null
                          : () => _loadVolumes(append: _volumesPage > 0),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(_error!),
                    ),
                  )
                : displayVolumes.isEmpty
                    ? const Center(child: Text('暂无目录'))
                    : ListView.builder(
                        controller: _sc,
                        padding: EdgeInsets.fromLTRB(12, 0, 12,
                            12 + MediaQuery.of(context).padding.bottom),
                        itemCount:
                            displayVolumes.length + (hasVolumeFooter ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i >= displayVolumes.length) {
                            if (_error != null) {
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: TextButton.icon(
                                    onPressed: _volumePageLoading
                                        ? null
                                        : () => _loadVolumes(
                                            append: _volumesPage > 0),
                                    icon: const Icon(Icons.refresh_rounded,
                                        size: 18),
                                    label: Text(_error!),
                                  ),
                                ),
                              );
                            }
                            if (!_volumePageLoading && _volumesHasMore) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  unawaited(_loadVolumes(append: true));
                                }
                              });
                            }
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 10),
                              child: MotionLinearProgressIndicator(
                                minHeight: 2,
                              ),
                            );
                          }
                          final v = displayVolumes[i];
                          final vid = v.volumeId;
                          final expanded = _expanded == vid;
                          final chs = _chapters[vid];
                          final chapterError = _chapterErrors[vid];
                          final isCur = vid == widget.volumeId;
                          final chapterCount = _chapterCountFor(v);
                          final openingSingle =
                              _openingSingleVolumes.contains(vid);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              key: _volKeys.putIfAbsent(vid, GlobalKey.new),
                              color: isDark
                                  ? const Color(0xFF2A2C33)
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(12),
                              clipBehavior: Clip.antiAlias,
                              child: Column(children: [
                                InkWell(
                                  onTap:
                                      openingSingle ? null : () => _toggle(v),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 10),
                                    child: Row(children: [
                                      Icon(
                                          chapterCount == 1
                                              ? Icons.play_arrow_rounded
                                              : expanded
                                                  ? Icons
                                                      .keyboard_arrow_down_rounded
                                                  : Icons.chevron_right_rounded,
                                          size: 20,
                                          color: Colors.grey.shade500),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(v.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w600,
                                                color: isCur
                                                    ? scheme.primary
                                                    : null)),
                                      ),
                                      if (chapterCount > 0)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(left: 6),
                                          child: Text('$chapterCount 章',
                                              style: TextStyle(
                                                  fontSize: 10.5,
                                                  color: Colors.grey.shade500)),
                                        ),
                                      if (isCur)
                                        Container(
                                          margin:
                                              const EdgeInsets.only(left: 6),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: scheme.primary
                                                .withValues(alpha: 0.12),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Text('当前',
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: scheme.primary)),
                                        ),
                                    ]),
                                  ),
                                ),
                                if (expanded &&
                                    chs == null &&
                                    chapterError == null &&
                                    _loadingVolumes.contains(vid))
                                  const Padding(
                                    padding: EdgeInsets.only(bottom: 12),
                                    child: MotionLinearProgressIndicator(
                                      minHeight: 2,
                                    ),
                                  ),
                                if (expanded &&
                                    chs == null &&
                                    chapterError != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: TextButton.icon(
                                      onPressed: () => _loadChapters(vid,
                                          page: _failedChapterPages[vid]),
                                      icon: const Icon(Icons.refresh_rounded,
                                          size: 18),
                                      label: Text(chapterError),
                                    ),
                                  ),
                                if (expanded && chs != null) ...[
                                  if (_hasPreviousPage(vid))
                                    TextButton.icon(
                                      onPressed: _loadingVolumes.contains(vid)
                                          ? null
                                          : () => _loadPreviousPage(vid),
                                      icon: const Icon(
                                          Icons.expand_less_rounded,
                                          size: 18),
                                      label: const Text('加载更早章节'),
                                    ),
                                  ...chs.map((c) => InkWell(
                                        onTap: () => widget.onPick(
                                            c.chapterId, c.title, vid),
                                        child: Container(
                                          key: c.chapterId ==
                                                  widget.currentChapterId
                                              ? _curChapterKey
                                              : null,
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 10),
                                          color: c.chapterId ==
                                                  widget.currentChapterId
                                              ? scheme.primary
                                                  .withValues(alpha: 0.12)
                                              : Colors.transparent,
                                          child: Text(c.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  color: c.chapterId ==
                                                          widget
                                                              .currentChapterId
                                                      ? scheme.primary
                                                      : null)),
                                        ),
                                      )),
                                  if (chapterError != null)
                                    TextButton.icon(
                                      onPressed: _loadingVolumes.contains(vid)
                                          ? null
                                          : () => _loadChapters(vid,
                                              page: _failedChapterPages[vid]),
                                      icon: const Icon(Icons.refresh_rounded,
                                          size: 18),
                                      label: const Text('加载失败，点击重试'),
                                    ),
                                  if (_loadingVolumes.contains(vid))
                                    const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 10),
                                      child:
                                          MotionLinearProgressIndicator(minHeight: 2),
                                    ),
                                  if (!_loadingVolumes.contains(vid) &&
                                      _hasNextPage(vid))
                                    TextButton.icon(
                                      onPressed: () => _loadNextPage(vid),
                                      icon: const Icon(
                                          Icons.expand_more_rounded,
                                          size: 18),
                                      label: const Text('加载后续章节'),
                                    ),
                                  if (_totalFor(vid) > 0)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 10),
                                      child: Text(
                                          '已加载 ${chs.length} / ${_totalFor(vid)}',
                                          style: TextStyle(
                                              fontSize: 10.5,
                                              color: Colors.grey.shade500)),
                                    ),
                                ],
                              ]),
                            ),
                          );
                        },
                      ),
      ),
    ]);
  }
}
