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

  Future<void> flush({bool force = false}) async {
    final existing = _inFlight;
    if (existing != null) {
      await existing;
      if (!force) return;
      // 离开阅读器时把请求期间新增的真实时长也补齐。
      return flush(force: true);
    }
    final request = _flush(force: force);
    _inFlight = request;
    try {
      await request;
    } finally {
      if (identical(_inFlight, request)) _inFlight = null;
    }
  }

  Future<void> _flush({required bool force}) async {
    final identity = owner();
    final generation = session.generation;
    bool isCurrent() =>
        identity.$1 > 0 &&
        owner() == identity &&
        (session.accountId, session.accountRevision) == identity &&
        session.generation == generation;
    if (!isCurrent()) return;
    final snapshot = session.snapshot();
    if (snapshot == null) return;
    var pending = snapshot.readDurationSeconds - session.reportedSeconds;
    if (pending < (force ? 1 : 15)) return;
    // 固定本次截止值，补报也不会无限追赶计时器或超过服务器的单次上限。
    while (pending > 0 && isCurrent()) {
      final delta = pending.clamp(1, 300);
      await send(snapshot, delta);
      if (!isCurrent()) return;
      session.reportedSeconds += delta;
      pending -= delta;
    }
  }
}
