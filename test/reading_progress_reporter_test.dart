import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/reading_session.dart';
import 'package:yomiru/services/reading_progress_reporter.dart';

void main() {
  late DateTime now;
  late LKReadingSession session;
  late ReadingProgressReporter reporter;
  late List<int> deltas;
  late (int, int) owner;

  void begin({int chapter = 1}) => session.begin(
      bookId: 1,
      volumeId: 1,
      chapterId: chapter,
      accountId: owner.$1,
      accountRevision: owner.$2);

  setUp(() {
    now = DateTime(2026, 9, 5);
    owner = (12, 1);
    session = LKReadingSession(now: () => now);
    deltas = [];
    reporter = ReadingProgressReporter(
        session: session,
        owner: () => owner,
        send: (_, delta) async {
          deltas.add(delta);
        });
    begin();
  });

  test('reader and repeated welfare refreshes only send new active seconds',
      () async {
    now = now.add(const Duration(seconds: 16));
    session.pause();
    await reporter.flush();
    await reporter.flush(force: true);
    await reporter.flush(force: true);
    expect(deltas, [16]);
    now = now.add(const Duration(minutes: 5));
    begin(); // 同章重新进入时恢复计时，但不忘记此前已上报的值。
    now = now.add(const Duration(seconds: 20));
    session.pause();
    await reporter.flush();
    expect(deltas, [16, 20]);
  });

  test('flush splits genuine backlog into deltas no larger than 300', () async {
    now = now.add(const Duration(seconds: 701));
    session.pause();
    await reporter.flush(force: true);
    expect(deltas, [300, 300, 101]);
    expect(session.reportedSeconds, 701);
  });

  test('logout reset removes the previous reading snapshot', () async {
    now = now.add(const Duration(seconds: 60));
    session.reset();
    expect(session.snapshot(), isNull);
    await reporter.flush(force: true);
    expect(deltas, isEmpty);
  });

  test(
      'simultaneous callers share report and include seconds accrued in flight',
      () async {
    final gate = Completer<void>();
    reporter = ReadingProgressReporter(
        session: session,
        owner: () => owner,
        send: (_, delta) async {
          deltas.add(delta);
          if (deltas.length == 1) await gate.future;
        });
    now = now.add(const Duration(seconds: 60));
    final first = reporter.flush();
    now = now.add(const Duration(seconds: 3));
    session.pause();
    final second = reporter.flush(force: true);
    expect(deltas, [60]);
    gate.complete();
    await Future.wait([first, second]);
    expect(deltas, [60, 3]);
  });

  test('a failed request is not acknowledged or retried in a tight loop',
      () async {
    var fail = true;
    reporter = ReadingProgressReporter(
        session: session,
        owner: () => owner,
        send: (_, delta) async {
          deltas.add(delta);
          if (fail) throw StateError('offline');
        });
    now = now.add(const Duration(seconds: 16));
    session.pause();
    await expectLater(reporter.flush(), throwsStateError);
    expect(session.reportedSeconds, 0);
    fail = false;
    await reporter.flush();
    expect(session.reportedSeconds, 16);
    expect(deltas, [16, 16]);
  });

  test('switching accounts or logging in again cannot report an old session',
      () async {
    now = now.add(const Duration(seconds: 60));
    session.pause();
    owner = (13, 2);
    await reporter.flush(force: true);
    owner = (12, 3);
    await reporter.flush(force: true);
    expect(deltas, isEmpty);
  });

  test('late acknowledgement cannot change new chapter reporting offset',
      () async {
    final gate = Completer<void>();
    reporter = ReadingProgressReporter(
        session: session,
        owner: () => owner,
        send: (_, delta) async {
          deltas.add(delta);
          await gate.future;
        });
    now = now.add(const Duration(seconds: 60));
    final work = reporter.flush();
    begin(chapter: 2);
    gate.complete();
    await work;
    expect(session.reportedSeconds, 0);
    now = now.add(const Duration(seconds: 20));
    session.pause();
    await reporter.flush();
    expect(deltas, [60, 20]);
  });
}
