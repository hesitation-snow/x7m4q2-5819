import 'dart:async';

import '../api/models.dart';

class CatalogVolumeBatch {
  final List<LKVolume> items;
  final bool hasMore;
  final int? total;
  final int page;

  const CatalogVolumeBatch({
    required this.items,
    required this.hasMore,
    this.total,
    required this.page,
  });
}

enum CatalogVerificationStatus {
  partial,
  containsBrave,
  noBrave,
  unknown,
  cancelled,
}

class CatalogRoundResult {
  final CatalogVerificationStatus status;
  final int requests;
  final bool madeProgress;

  const CatalogRoundResult({
    required this.status,
    required this.requests,
    required this.madeProgress,
  });
}

/// Checks directory metadata only. A public book entry is not negative evidence.
/// Each successful page is a checkpoint; failed or stale responses never advance it.
class BookCatalogVerifier {
  final Future<LKBook> Function(int id, Duration remaining) loadBook;
  final Future<CatalogVolumeBatch> Function(
      int id, int page, int pageSize, Duration remaining) loadVolumes;
  final Future<LKChapterPage> Function(
          int id, int volumeId, int page, int pageSize, Duration remaining)
      loadChapters;
  final DateTime Function() now;
  final int maxEntries;
  final _states = <int, _Checkpoint>{};

  BookCatalogVerifier({
    required this.loadBook,
    required this.loadVolumes,
    required this.loadChapters,
    DateTime Function()? now,
    this.maxEntries = 128,
  }) : now = now ?? DateTime.now {
    if (maxEntries < 1) throw ArgumentError.value(maxEntries, 'maxEntries');
  }

  /// Call once per external lookup, not once per scheduling round.
  void beginLookup(int id) {
    final state = _states[id];
    if (state != null &&
        !state.busy &&
        (state.status == CatalogVerificationStatus.noBrave ||
            state.status == CatalogVerificationStatus.unknown &&
                state.volumesDone &&
                state.volumeIndex == state.volumes.length)) {
      // A completed traversal containing missing metadata must be retryable,
      // even when the server did not update its book timestamp/counts.
      _states.remove(id);
    }
  }

  bool hasPending(int id) =>
      _states[id]?.status == CatalogVerificationStatus.partial;

  Future<CatalogRoundResult> verifyRound(
    int id, {
    required bool Function() isCurrent,
    int maxRequests = 4,
    Duration budget = const Duration(seconds: 8),
  }) async {
    var requests = 0;
    var progress = false;
    CatalogRoundResult result(CatalogVerificationStatus status) =>
        CatalogRoundResult(
            status: status, requests: requests, madeProgress: progress);
    if (!isCurrent()) return result(CatalogVerificationStatus.cancelled);
    if (id <= 0 || maxRequests < 1 || budget <= Duration.zero) {
      return result(CatalogVerificationStatus.unknown);
    }
    var state = _states[id];
    if (state?.busy ?? false) {
      return result(CatalogVerificationStatus.cancelled);
    }
    if (state == null) {
      while (_states.length >= maxEntries) {
        final idle = _states.keys.where((key) => !_states[key]!.busy);
        if (idle.isEmpty) return result(CatalogVerificationStatus.unknown);
        _states.remove(idle.first);
      }
      state = _Checkpoint();
    }
    // Pin the same object until finally: idle LRU eviction cannot fork a cursor.
    final cursor = state;
    _states.remove(id);
    _states[id] = cursor;
    cursor.busy = true;
    final deadline = now().add(budget);
    Duration remaining() => deadline.difference(now());
    CatalogRoundResult finish(CatalogVerificationStatus status) {
      cursor.status = status;
      return result(status);
    }

    Future<T> request<T>(Future<T> Function(Duration) load) async {
      if (!isCurrent()) throw const _Cancelled();
      final left = remaining();
      if (left <= Duration.zero) throw TimeoutException('Round budget');
      requests++;
      final value = await load(left).timeout(left);
      if (!isCurrent()) throw const _Cancelled();
      if (remaining() <= Duration.zero) throw TimeoutException('Round budget');
      return value;
    }

    try {
      // This must remain the first request even for an existing checkpoint.
      final book = await request((left) => loadBook(id, left));
      if (book.bookId != id || book.volumeCount < 0 || book.chapterCount < 0) {
        return finish(CatalogVerificationStatus.unknown);
      }
      final fingerprint =
          '${book.updatedAt}|${book.volumeCount}|${book.chapterCount}';
      if (cursor.fingerprint != fingerprint) cursor.reset(fingerprint);
      if (book.isBrave) return finish(CatalogVerificationStatus.containsBrave);
      if (cursor.status == CatalogVerificationStatus.containsBrave ||
          cursor.status == CatalogVerificationStatus.noBrave) {
        return result(cursor.status);
      }
      while (true) {
        if (!isCurrent()) return finish(CatalogVerificationStatus.cancelled);
        if (cursor.volumeIndex == cursor.volumes.length && cursor.volumesDone) {
          final complete = cursor.volumes.isNotEmpty &&
              cursor.chapterIds.isNotEmpty &&
              !cursor.hasUnknown &&
              (book.volumeCount == 0 ||
                  cursor.volumes.length == book.volumeCount) &&
              (book.chapterCount == 0 ||
                  cursor.chapterIds.length == book.chapterCount);
          return finish(complete
              ? CatalogVerificationStatus.noBrave
              : CatalogVerificationStatus.unknown);
        }
        if (requests >= maxRequests || remaining() <= Duration.zero) {
          return finish(progress
              ? CatalogVerificationStatus.partial
              : CatalogVerificationStatus.unknown);
        }
        if (cursor.volumeIndex < cursor.volumes.length) {
          final volume = cursor.volumes[cursor.volumeIndex];
          final page = await request((left) =>
              loadChapters(id, volume.volumeId, cursor.chapterPage, 50, left));
          final ids = page.items.map((item) => item.chapterId).toSet();
          if (page.page != cursor.chapterPage ||
              page.pageSize < 1 ||
              page.pageSize > 50 ||
              page.items.length > page.pageSize ||
              ids.any((id) => id <= 0) ||
              ids.length != page.items.length ||
              ids.any(cursor.chapterIds.contains)) {
            return finish(CatalogVerificationStatus.unknown);
          }
          if (page.items.any((item) =>
              item.braveOnly || item.accessStatus == BookAccessStatus.brave)) {
            progress = true;
            return finish(CatalogVerificationStatus.containsBrave);
          }
          final count = cursor.volumeChapters + ids.length;
          final total = page.hasKnownTotal ? page.total : cursor.chapterTotal;
          if ((page.hasKnownTotal &&
                  cursor.chapterTotal != null &&
                  cursor.chapterTotal != page.total) ||
              (page.hasMore && ids.isEmpty) ||
              (total != null &&
                  (total < count ||
                      (page.hasMore && count >= total) ||
                      (!page.hasMore && count != total))) ||
              (volume.chapterCount > 0 &&
                  (count > volume.chapterCount ||
                      (!page.hasMore && count != volume.chapterCount))) ||
              (book.chapterCount > 0 &&
                  cursor.chapterIds.length + ids.length > book.chapterCount)) {
            return finish(CatalogVerificationStatus.unknown);
          }
          cursor.chapterIds.addAll(ids);
          cursor.hasUnknown |= (page.items.isEmpty &&
                  cursor.volumeChapters == 0) ||
              page.items
                  .any((item) => item.accessStatus != BookAccessStatus.public);
          cursor.volumeChapters = count;
          cursor.chapterTotal = total;
          cursor.chapterPage++;
          if (!page.hasMore) {
            cursor.volumeIndex++;
            cursor.chapterPage = 1;
            cursor.volumeChapters = 0;
            cursor.chapterTotal = null;
          }
          progress = true;
        } else {
          final batch = await request(
              (left) => loadVolumes(id, cursor.volumePage, 50, left));
          final ids = batch.items.map((volume) => volume.volumeId).toSet();
          final count = cursor.volumes.length + ids.length;
          final total = batch.total ?? cursor.volumeTotal;
          if (batch.page != cursor.volumePage ||
              batch.items.length > 50 ||
              ids.any((id) => id <= 0) ||
              ids.length != batch.items.length ||
              ids.any(cursor.volumeIds.contains) ||
              batch.items.any((volume) => volume.chapterCount < 0) ||
              (batch.hasMore && ids.isEmpty) ||
              (batch.total != null &&
                  cursor.volumeTotal != null &&
                  batch.total != cursor.volumeTotal) ||
              (total != null &&
                  (total < count ||
                      (batch.hasMore && count >= total) ||
                      (!batch.hasMore && count != total))) ||
              (book.volumeCount > 0 &&
                  (count > book.volumeCount ||
                      (!batch.hasMore && count != book.volumeCount)))) {
            return finish(CatalogVerificationStatus.unknown);
          }
          cursor.volumes.addAll(batch.items);
          cursor.volumeIds.addAll(ids);
          cursor.volumeTotal = total;
          cursor.volumePage++;
          cursor.volumesDone = !batch.hasMore;
          progress = true;
        }
      }
    } on _Cancelled {
      return finish(CatalogVerificationStatus.cancelled);
    } catch (_) {
      // Retain only earlier successful pages. Unknown does not auto-reschedule.
      return finish(CatalogVerificationStatus.unknown);
    } finally {
      cursor.busy = false;
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Checkpoint {
  bool busy = false;
  String? fingerprint;
  CatalogVerificationStatus status = CatalogVerificationStatus.unknown;
  final volumes = <LKVolume>[];
  final volumeIds = <int>{};
  final chapterIds = <int>{};
  int volumePage = 1;
  int volumeIndex = 0;
  int chapterPage = 1;
  int volumeChapters = 0;
  int? volumeTotal;
  int? chapterTotal;
  bool volumesDone = false;
  bool hasUnknown = false;

  void reset(String value) {
    fingerprint = value;
    status = CatalogVerificationStatus.unknown;
    volumes.clear();
    volumeIds.clear();
    chapterIds.clear();
    volumePage = chapterPage = 1;
    volumeIndex = volumeChapters = 0;
    volumeTotal = chapterTotal = null;
    volumesDone = hasUnknown = false;
  }
}
