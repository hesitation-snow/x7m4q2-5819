import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/services/background_work_queue.dart';
import 'package:yomiru/services/book_access_probe.dart';

void main() {
  test('shared queue bounds concurrent work and skips canceled queued jobs',
      () async {
    final queue = BackgroundWorkQueue(concurrency: 2);
    final gate = Completer<void>();
    var active = 0;
    var maximum = 0;
    var calls = 0;
    var current = true;
    final jobs = List.generate(
        20,
        (_) => queue.run<int>(() async {
              calls++;
              active++;
              if (active > maximum) maximum = active;
              await gate.future;
              active--;
              return 1;
            }, isCurrent: () => current));
    expect(calls, 2);
    current = false;
    gate.complete();
    final results = await Future.wait(jobs);
    expect(maximum, 2);
    expect(calls, 2);
    expect(results.whereType<int>(), hasLength(2));
    expect(results.where((value) => value == null), hasLength(18));
  });

  test('a failed background job releases its queue slot', () async {
    final queue = BackgroundWorkQueue(concurrency: 1);
    await expectLater(queue.run<int>(() async => throw StateError('offline')),
        throwsStateError);
    expect(await queue.run<int>(() async => 2), 2);
  });

  test('book probe shares requests and briefly caches non-brave samples',
      () async {
    var now = DateTime(2026, 9, 5);
    var calls = 0;
    final gate = Completer<void>();
    final probe = BookAccessProbe(
        now: () => now,
        query: (_, current) async {
          calls++;
          await gate.future;
          return current() ? false : null;
        });
    final first = probe.lookup(1, isCurrent: () => true);
    final second = probe.lookup(1, isCurrent: () => true);
    gate.complete();
    expect(await Future.wait([first, second]), [false, false]);
    expect(calls, 1);
    expect(await probe.lookup(1, isCurrent: () => true), isFalse);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 6));
    await probe.lookup(1, isCurrent: () => true);
    expect(calls, 2);
  });

  test('leaving one profile does not cancel another interested viewer',
      () async {
    var firstActive = true;
    final gate = Completer<void>();
    var calls = 0;
    final probe = BookAccessProbe(query: (_, current) async {
      calls++;
      await gate.future;
      return current() ? true : null;
    });
    final first = probe.lookup(1, isCurrent: () => firstActive);
    final second = probe.lookup(1, isCurrent: () => true);
    firstActive = false;
    gate.complete();
    expect(await Future.wait([first, second]), [true, true]);
    expect(calls, 1);
  });

  test('canceled and failed probes do not create a negative cache entry',
      () async {
    var fail = true;
    var calls = 0;
    final probe = BookAccessProbe(query: (_, current) async {
      calls++;
      if (fail) throw StateError('offline');
      return true;
    });
    expect(await probe.lookup(1, isCurrent: () => false), isNull);
    expect(calls, 0);
    expect(await probe.lookup(1, isCurrent: () => true), isNull);
    fail = false;
    expect(await probe.lookup(1, isCurrent: () => true), isTrue);
    expect(calls, 2);
  });
}
