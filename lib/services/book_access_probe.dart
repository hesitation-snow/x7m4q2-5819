import 'dart:async';

import '../api/lk_api.dart';
import '../api/store.dart';
import 'background_work_queue.dart';
import 'book_catalog_verifier.dart';

/// Positive-only display enrichment, never a grant to read protected content.
/// Catalog verification yields between bounded rounds and resumes checkpoints.
class BookAccessProbe {
  BookAccessProbe(
      {required this.query,
      DateTime Function()? now,
      bool Function(int)? isKnownBrave,
      bool Function()? isEnabled,
      Future<void> Function(int)? onConfirmed,
      void Function(int)? onLookupStarted,
      bool Function(int)? needsContinuation,
      this.maxPending = 32,
      this.deadline = const Duration(seconds: 8),
      this.cooldown = const Duration(minutes: 5),
      this.errorCooldown = const Duration(seconds: 15),
      this.maxRounds = 8,
      this.roundDelay = Duration.zero,
      this.partialCooldown = const Duration(seconds: 15)})
      : _now = now ?? DateTime.now,
        _isKnownBrave = isKnownBrave ?? ((_) => false),
        _isEnabled = isEnabled ?? (() => true),
        _onConfirmed = onConfirmed,
        _onLookupStarted = onLookupStarted,
        _needsContinuation = needsContinuation ?? ((_) => false) {
    if (maxPending < 1 ||
        maxRounds < 1 ||
        deadline <= Duration.zero ||
        roundDelay.isNegative) {
      throw ArgumentError('Invalid catalog verification budget');
    }
  }

  static final _catalog = BookCatalogVerifier(
    loadBook: (id, remaining) => LKApi.bookDetail(id,
        forceRefresh: true,
        forAccessVerification: true,
        requestTimeout: remaining),
    loadVolumes: (id, page, size, remaining) async {
      final batch = await LKApi.volumeCatalogPage(id, page,
          pageSize: size, requestTimeout: remaining);
      return CatalogVolumeBatch(
          items: batch.items,
          hasMore: batch.hasMore,
          total: batch.total,
          page: batch.page);
    },
    loadChapters: (id, volume, page, size, remaining) => LKApi.chapterPage(
        id, volume, page,
        pageSize: size,
        forceRefresh: true,
        requireList: true,
        requestTimeout: remaining),
  );

  static final shared = BookAccessProbe(
      query: _queryApi,
      isKnownBrave: LKStore.isBraveBook,
      isEnabled: () => !LKStore.dataSaverMode.value,
      onConfirmed: LKStore.markBookBrave,
      onLookupStarted: _catalog.beginLookup,
      needsContinuation: _catalog.hasPending,
      roundDelay: const Duration(milliseconds: 150));

  static Future<bool?> _queryApi(int id, bool Function() current) async {
    if (LKStore.isBraveBook(id)) return true;
    final result = await _catalog.verifyRound(id,
        isCurrent: () => current() && !LKStore.dataSaverMode.value,
        maxRequests: 4,
        budget: const Duration(seconds: 8));
    return result.status == CatalogVerificationStatus.containsBrave
        ? true
        : null;
  }

  final Future<bool?> Function(int, bool Function()) query;
  final DateTime Function() _now;
  final bool Function(int) _isKnownBrave;
  final bool Function() _isEnabled;
  final Future<void> Function(int)? _onConfirmed;
  final void Function(int)? _onLookupStarted;
  final bool Function(int) _needsContinuation;
  final int maxPending;
  final int maxRounds;
  final Duration deadline;
  final Duration cooldown;
  final Duration errorCooldown;
  final Duration partialCooldown;
  final Duration roundDelay;
  final _queue = BackgroundWorkQueue(concurrency: 2);
  final _positive = <int>{};
  final _retryAfter = <int, DateTime>{};
  final _pending = <int, Future<bool?>>{};
  int get queued => _pending.length;
  final _listeners = <int, Set<bool Function()>>{};

  Future<void> get whenIdle async {
    final observed = <Future<bool?>>{};
    while (true) {
      final work = _pending.values
          .where((future) => !observed.contains(future))
          .toList();
      if (work.isNotEmpty) {
        observed.addAll(work);
        await Future.wait(work);
      }
      await _queue.whenIdle;
      // Wait for work, not a subscriber's finally callback in another zone.
      // Completed futures may still be in the map until that caller resumes.
      if (!_pending.values.any((future) => !observed.contains(future))) {
        return;
      }
    }
  }

  void _coolDown(int id, Duration duration) {
    if (_retryAfter.length >= 256) _retryAfter.remove(_retryAfter.keys.first);
    _retryAfter[id] = _now().add(duration);
  }

  Future<bool?> _runLookup(int id, bool Function() wanted) async {
    _onLookupStarted?.call(id);
    for (var round = 0; round < maxRounds && wanted(); round++) {
      var failed = false;
      final result = await _queue.run<bool?>(() async {
        var expired = false;
        try {
          return await query(id, () => !expired && wanted()).timeout(deadline);
        } catch (_) {
          failed = true;
          return null; // Failure is unknown, never a negative book mark.
        } finally {
          expired = true;
        }
      }, isCurrent: wanted);
      if (_isKnownBrave(id)) return true;
      if (!wanted()) return null;
      if (result == true) {
        if (_positive.length >= 256) _positive.remove(_positive.first);
        _positive.add(id);
        _retryAfter.remove(id);
        if (wanted()) await _onConfirmed?.call(id);
        return true;
      }
      if (!wanted()) return null;
      if (failed || !_needsContinuation(id)) {
        _coolDown(id, failed ? errorCooldown : cooldown);
        return null;
      }
      if (round + 1 >= maxRounds) {
        _coolDown(id, partialCooldown);
        return null; // Keep the cursor for a later visit/refresh, not "public".
      }
      // Release the queue slot before yielding: other books get their turn.
      await Future<void>.delayed(roundDelay);
    }
    return null;
  }

  Future<bool?> lookup(int id, {required bool Function() isCurrent}) async {
    if (id <= 0 || !isCurrent()) return null;
    if (_isKnownBrave(id) || _positive.contains(id)) return true;
    if (!_isEnabled()) return null;
    final next = _retryAfter[id];
    if (next != null && _now().isBefore(next)) return null;
    if (!_pending.containsKey(id) && _pending.length >= maxPending) return null;
    final listeners = _listeners.putIfAbsent(id, () => {});
    listeners.add(isCurrent);
    bool wanted() => _isEnabled() && listeners.any((listener) => listener());
    final request = _pending.putIfAbsent(id, () => _runLookup(id, wanted));
    try {
      final result = await request;
      return _isKnownBrave(id) ? true : result;
    } catch (_) {
      return _isKnownBrave(id) ? true : null;
    } finally {
      listeners.remove(isCurrent);
      if (identical(_pending[id], request)) {
        _pending.remove(id);
        _listeners.remove(id);
      }
    }
  }
}
