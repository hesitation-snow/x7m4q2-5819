import 'dart:async';

import '../api/lk_api.dart';
import '../api/models.dart';
import '../api/reader_cache.dart';
import '../pages/catalog_paging.dart';
import '../reader/reader_language_segments.dart';
import '../reader/reader_tts_core.dart';
import '../reader/speech_segments.dart';
import '../reader/structured_content.dart';

enum SpeechNextChapterStatus { loaded, noNext, locked, cancelled }

class LoadedSpeechChapter {
  const LoadedSpeechChapter({
    required this.chapterId,
    required this.title,
    required this.volumeId,
    required this.nextChapterId,
    required this.nextChapterTitle,
    required this.nextVolumeId,
    required this.segments,
  });

  final int chapterId;
  final String title;
  final int volumeId;
  final int? nextChapterId;
  final String nextChapterTitle;
  final int? nextVolumeId;
  final List<TtsSegment> segments;
}

class SpeechNextChapterResult {
  const SpeechNextChapterResult.loaded(LoadedSpeechChapter this.chapter)
      : status = SpeechNextChapterStatus.loaded,
        message = '';

  const SpeechNextChapterResult.noNext()
      : status = SpeechNextChapterStatus.noNext,
        chapter = null,
        message = '';

  const SpeechNextChapterResult.locked(this.message)
      : status = SpeechNextChapterStatus.locked,
        chapter = null;

  const SpeechNextChapterResult.cancelled()
      : status = SpeechNextChapterStatus.cancelled,
        chapter = null,
        message = '';

  final SpeechNextChapterStatus status;
  final LoadedSpeechChapter? chapter;
  final String message;
}

/// 后台续读加载器：脱离具体页面 Widget 生命周期解析下一章、提取可朗读段落，
/// 并自动跳过无文本章节（如纯插画页）直到找到可朗读章节、需要解锁或抵达书末。
class SpeechChapterLoader {
  static const int _maxEmptyChapterSkips = 5;

  static Future<SpeechNextChapterResult> loadNextChapter({
    required int bookId,
    required int currentChapterId,
    required int currentVolumeId,
    int? nextChapterId,
    String nextChapterTitle = '',
    int? nextVolumeId,
    required ReaderLanguageFilter languageFilter,
    required bool Function() isCurrent,
    int? cacheOwnerUid,
    bool useContentCache = true,
    Future<LKChapterDetail> Function(int bookId, int chapterId)?
        fetchChapterDetail,
    Future<List<LKVolume>> Function(int bookId)? fetchVolumes,
    Future<LKChapterPage> Function(int bookId, int volumeId, int page)?
        fetchChapterPage,
  }) async {
    if (!isCurrent()) return const SpeechNextChapterResult.cancelled();
    if (bookId <= 0 || currentChapterId <= 0) {
      return const SpeechNextChapterResult.noNext();
    }

    final loadDetail = fetchChapterDetail ?? LKApi.chapterDetail;
    final loadVolumes = fetchVolumes ?? LKApi.allVolumes;
    final loadPage = fetchChapterPage ?? LKApi.chapterPage;
    final cacheGeneration = ReaderContentCache.generation;

    Future<LKChapterDetail?> readCached(int chapterId) async {
      if (!useContentCache || cacheOwnerUid == null) return null;
      return ReaderContentCache.read(bookId, chapterId, ownerUid: cacheOwnerUid);
    }

    Future<LKChapterDetail> getDetail(int chapterId) async {
      final cached = await readCached(chapterId);
      if (cached != null) return cached;
      return loadDetail(bookId, chapterId);
    }

    Future<({int? id, String title, int? volumeId})> resolveFollowing(
      int chapterId,
      int volumeId,
      LKChapterDetail? knownDetail,
    ) async {
      if (knownDetail?.nextChapterId != null &&
          knownDetail!.nextChapterId! > 0) {
        return (
          id: knownDetail.nextChapterId,
          title: knownDetail.nextTitle ?? '',
          volumeId: knownDetail.nextVolumeId,
        );
      }
      final detail = knownDetail ?? await getDetail(chapterId);
      if (!isCurrent()) return (id: null, title: '', volumeId: null);
      if (detail.nextChapterId != null && detail.nextChapterId! > 0) {
        return (
          id: detail.nextChapterId,
          title: detail.nextTitle ?? '',
          volumeId: detail.nextVolumeId,
        );
      }
      final resolvedVolId = detail.volumeId > 0 ? detail.volumeId : volumeId;
      if (resolvedVolId <= 0) {
        return (id: null, title: '', volumeId: null);
      }
      final volumes = await loadVolumes(bookId);
      if (!isCurrent()) return (id: null, title: '', volumeId: null);
      final volumeIndex =
          volumes.indexWhere((volume) => volume.volumeId == resolvedVolId);
      if (volumeIndex < 0) return (id: null, title: '', volumeId: null);
      final volume = volumes[volumeIndex];

      int sourcePage = detail.chapterNo > 0
          ? catalogPageForChapter(
              chapterNo: detail.chapterNo,
              total: volume.chapterCount,
              pageSize: 50,
            )
          : 1;
      LKChapterPage page = await loadPage(bookId, volume.volumeId, sourcePage);
      if (!isCurrent()) return (id: null, title: '', volumeId: null);

      var chapterIndex =
          page.items.indexWhere((item) => item.chapterId == chapterId);
      if (chapterIndex < 0 && sourcePage != 1) {
        // 回退顺扫当前卷，应对服务端 chapterNo 缺失或不连续的情况。
        var scanPage = 1;
        while (true) {
          final candidate = scanPage == sourcePage
              ? page
              : await loadPage(bookId, volume.volumeId, scanPage);
          if (!isCurrent()) return (id: null, title: '', volumeId: null);
          final idx =
              candidate.items.indexWhere((item) => item.chapterId == chapterId);
          if (idx >= 0) {
            sourcePage = scanPage;
            page = candidate;
            chapterIndex = idx;
            break;
          }
          if (!candidate.hasMore || candidate.items.isEmpty) break;
          scanPage++;
        }
      }
      if (chapterIndex < 0) return (id: null, title: '', volumeId: null);

      if (chapterIndex < page.items.length - 1) {
        final next = page.items[chapterIndex + 1];
        return (
          id: next.chapterId,
          title: next.title,
          volumeId: volume.volumeId,
        );
      }
      final pageCount = catalogPageCount(
          page.total > 0 ? page.total : volume.chapterCount, 50);
      if (page.hasMore || sourcePage < pageCount) {
        final nextPage =
            await loadPage(bookId, volume.volumeId, sourcePage + 1);
        if (nextPage.items.isNotEmpty) {
          final next = nextPage.items.first;
          return (
            id: next.chapterId,
            title: next.title,
            volumeId: volume.volumeId,
          );
        }
      }
      for (var vIdx = volumeIndex + 1; vIdx < volumes.length; vIdx++) {
        final nextVol = volumes[vIdx];
        final firstPage = await loadPage(bookId, nextVol.volumeId, 1);
        if (!isCurrent()) return (id: null, title: '', volumeId: null);
        if (firstPage.items.isNotEmpty) {
          final next = firstPage.items.first;
          return (
            id: next.chapterId,
            title: next.title,
            volumeId: nextVol.volumeId,
          );
        }
      }
      return (id: null, title: '', volumeId: null);
    }

    int lastVisitedChapterId = currentChapterId;
    int? targetId = nextChapterId;
    String targetTitle = nextChapterTitle;
    int? targetVolumeId = nextVolumeId;

    if (targetId == null || targetId <= 0) {
      final resolved = await resolveFollowing(
        currentChapterId,
        currentVolumeId,
        null,
      );
      if (!isCurrent()) return const SpeechNextChapterResult.cancelled();
      targetId = resolved.id;
      targetTitle = resolved.title;
      targetVolumeId = resolved.volumeId;
    }

    for (var attempt = 0; attempt < _maxEmptyChapterSkips; attempt++) {
      if (!isCurrent()) return const SpeechNextChapterResult.cancelled();
      if (targetId == null ||
          targetId <= 0 ||
          targetId == lastVisitedChapterId) {
        return const SpeechNextChapterResult.noNext();
      }
      lastVisitedChapterId = targetId;

      final detail = await getDetail(targetId);
      if (!isCurrent()) return const SpeechNextChapterResult.cancelled();

      if (detail.locked && !detail.unlocked) {
        return const SpeechNextChapterResult.locked('下一章需要解锁，已停止连续朗读');
      }

      if (useContentCache &&
          cacheOwnerUid != null &&
          ReaderContentCache.generation == cacheGeneration) {
        unawaited(ReaderContentCache.write(
          bookId,
          detail,
          ownerUid: cacheOwnerUid,
          expectedGeneration: cacheGeneration,
        ).catchError((Object _) {}));
      }

      final resolvedVolId = detail.volumeId > 0
          ? detail.volumeId
          : (targetVolumeId ?? currentVolumeId);
      final resolvedTitle =
          detail.title.trim().isNotEmpty ? detail.title.trim() : targetTitle;
      final segments = _extractSegments(detail);
      final speakable = const ReaderLanguageSegments()
          .filter(segments, filter: languageFilter);

      if (speakable.isNotEmpty) {
        final following = await resolveFollowing(
          targetId,
          resolvedVolId,
          detail,
        );
        if (!isCurrent()) return const SpeechNextChapterResult.cancelled();

        if (useContentCache &&
            cacheOwnerUid != null &&
            following.id != null &&
            following.id! > 0 &&
            following.id != targetId &&
            ReaderContentCache.generation == cacheGeneration) {
          final prefetchId = following.id!;
          unawaited(() async {
            try {
              if (await ReaderContentCache.contains(bookId, prefetchId,
                  ownerUid: cacheOwnerUid)) {
                return;
              }
              final prefetched = await loadDetail(bookId, prefetchId);
              if (ReaderContentCache.generation != cacheGeneration) return;
              await ReaderContentCache.write(
                bookId,
                prefetched,
                ownerUid: cacheOwnerUid,
                expectedGeneration: cacheGeneration,
              );
            } catch (_) {}
          }());
        }

        return SpeechNextChapterResult.loaded(
          LoadedSpeechChapter(
            chapterId: targetId,
            title: resolvedTitle,
            volumeId: resolvedVolId,
            nextChapterId: following.id,
            nextChapterTitle: following.title,
            nextVolumeId: following.volumeId,
            segments: segments,
          ),
        );
      }

      // 若下一章只有插画等无文本内容，尝试顺延跳过。
      final skippedNext = await resolveFollowing(
        targetId,
        resolvedVolId,
        detail,
      );
      if (!isCurrent()) return const SpeechNextChapterResult.cancelled();
      targetId = skippedNext.id;
      targetTitle = skippedNext.title;
      targetVolumeId = skippedNext.volumeId;
    }

    return const SpeechNextChapterResult.noNext();
  }

  static List<TtsSegment> _extractSegments(LKChapterDetail detail) {
    List<StructuredBlock> blocks = const [];
    final html = detail.bodyHtml;
    if (html != null && html.isNotEmpty) {
      blocks = StructuredContentParser.parseHtml(html, firstLineIndent: false);
    }
    if (blocks.isEmpty && detail.bodyText.isNotEmpty) {
      blocks = StructuredContentParser.parseText(detail.bodyText,
          firstLineIndent: false);
    }
    return splitSpeechSegments(
      blocks.indexed
          .where((entry) =>
              !entry.$2.isDivider && entry.$2.text != '(本章暂无内容)')
          .map((entry) => SpeechTextBlock(
                blockIndex: entry.$1,
                text: entry.$2.text,
                image: entry.$2.imageUrl,
              )),
    )
        .map((segment) => TtsSegment(
              blockIndex: segment.blockIndex,
              startOffset: segment.startOffset,
              endOffset: segment.endOffset,
              text: segment.text,
            ))
        .toList(growable: false);
  }
}
