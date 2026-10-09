import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/reading_session.dart';

/// 阅读器与任务中心共用已确认的增量，页面重建不会重复计时。
class ReadingProgressReporter {
  ReadingProgressReporter({
    required this.session,
    required this.owner,
    required this.send,
  });

  static final shared = ReadingProgressReporter(
    session: LKReadingSession.shared,
    owner: () => (
      LKClient.shared.session.isLoggedIn ? LKClient.shared.session.uid : 0,
      LKClient.sessionRev.value,
    ),
    send: (snapshot, delta) => LKApi.reportReadingProgress(
      bookId: snapshot.bookId,
      volumeId: snapshot.volumeId,
      chapterId: snapshot.chapterId,
      progressPercent: snapshot.progressPercent,
      readDurationSeconds: snapshot.readDurationSeconds,
      activeSecondsDelta: delta,
    ),
  );

  final LKReadingSession session;
  final (int, int) Function() owner;
  final Future<void> Function(LKReadingSnapshot, int) send;
  Future<void>? _inFlight;
  _ReadingReportCursor? _cursor;

  Future<void> flush({bool force = false}) async {
    final identity = owner();
    final generation = session.generation;
    final snapshot = session.snapshot();
    if (identity.$1 <= 0 ||
        (session.accountId, session.accountRevision) != identity ||
        snapshot == null) {
      return;
    }
    final cursor =
        _cursor?.generation == generation && _cursor?.identity == identity
            ? _cursor!
            : (_cursor = _ReadingReportCursor(
                identity, generation, session.reportedSeconds));
    // 在等待网络前固定章节与时长，退出后进入其他章节也不会串报。
    while (_inFlight != null) {
      final existing = _inFlight!;
      await existing;
      if (!force) return;
    }
    final request = _flush(snapshot, cursor, force: force);
    _inFlight = request;
    try {
      await request;
    } finally {
      if (identical(_inFlight, request)) _inFlight = null;
    }
  }

  Future<void> _flush(LKReadingSnapshot snapshot, _ReadingReportCursor cursor,
      {required bool force}) async {
    bool isCurrent() =>
        owner() == cursor.identity &&
        (session.accountId, session.accountRevision) == cursor.identity;
    if (!isCurrent()) return;
    var pending = snapshot.readDurationSeconds - cursor.reportedSeconds;
    if (pending < (force ? 1 : 15)) return;
    // 固定本次截止值，补报也不会无限追赶计时器或超过服务器的单次上限。
    while (pending > 0 && isCurrent()) {
      final delta = pending.clamp(1, 300);
      await send(snapshot, delta);
      if (!isCurrent()) return;
      cursor.reportedSeconds += delta;
      if (session.generation == cursor.generation) {
        session.reportedSeconds = cursor.reportedSeconds;
      }
      pending -= delta;
    }
  }
}

class _ReadingReportCursor {
  _ReadingReportCursor(this.identity, this.generation, this.reportedSeconds);

  final (int, int) identity;
  final int generation;
  int reportedSeconds;
}
