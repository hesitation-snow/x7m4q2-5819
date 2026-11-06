import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/reader/reader_tts_core.dart';

void main() {
  group('adaptReaderBlocksToTts', () {
    test('splits by punctuation and preserves UTF-16 ranges and block indexes',
        () {
      const source = '😀你好！ 这是第二句。';
      final parts = adaptReaderBlocksToTts([
        const TtsReaderBlock(text: '!!!', blockIndex: 2),
        const TtsReaderBlock(text: source, blockIndex: 7),
      ]);
      expect(parts.map((p) => p.text), ['😀你好！', '这是第二句。']);
      expect(parts.map((p) => p.blockIndex), [7, 7]);
      for (final part in parts) {
        expect(source.substring(part.startOffset, part.endOffset), part.text);
      }
      expect(parts.first.endOffset, '😀你好！'.length);
    });

    test('ignores image, divider and punctuation-only blocks', () {
      expect(
        adaptReaderBlocksToTts([
          const TtsReaderBlock(text: '', image: 'img'),
          const TtsReaderBlock(text: '---', isDivider: true),
          const TtsReaderBlock(text: '！？……'),
          const TtsReaderBlock(text: '正文。', blockIndex: 4),
        ]).map((e) => e.text),
        ['正文。'],
      );
    });

    test('bounds long segments and preserves all text', () {
      const text = 'abcdefghij klmnopqrst';
      final parts = adaptReaderBlocksToTts(
        [const TtsReaderBlock(text: text)],
        maxSegmentCodeUnits: 8,
      );
      expect(parts.every((p) => p.text.length <= 8), isTrue);
      expect(parts.map((p) => p.text).join(), text);
      for (final part in parts) {
        expect(text.substring(part.startOffset, part.endOffset), part.text);
      }
    });
  });

  group('ReaderTtsController', () {
    test('plays, changes rate, pauses, advances and completes', () async {
      final service = _FakeTts();
      final controller = ReaderTtsController(service);
      const segments = [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 2, text: '甲。'),
        TtsSegment(blockIndex: 1, startOffset: 0, endOffset: 2, text: '乙。'),
      ];
      await controller.play(segments);
      expect(controller.status, TtsPlaybackStatus.playing);
      expect(service.spoken.single, '甲。');
      await controller.setRate(1.25);
      expect(controller.rate, 1.25);
      await controller.pause();
      expect(controller.status, TtsPlaybackStatus.paused);
      await controller.resume();
      service.emit(const TtsPlaybackEvent(completed: true));
      await Future<void>.delayed(Duration.zero);
      expect(controller.position, 1);
      expect(service.spoken.last, '乙。');
      service.emit(const TtsPlaybackEvent(completed: true));
      expect(controller.status, TtsPlaybackStatus.completed);
      controller.dispose();
    });

    test('reports service exceptions and ignores stale async completion',
        () async {
      final service = _FakeTts()..speakCompleter = Completer<void>();
      final controller = ReaderTtsController(service);
      const segments = [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 2, text: '甲。'),
      ];
      final pendingPlay = controller.play(segments);
      await controller.stop();
      service.speakCompleter!.completeError(StateError('late failure'));
      await pendingPlay;
      expect(controller.status, TtsPlaybackStatus.stopped);

      service.failNextSpeak = true;
      await controller.resume();
      expect(controller.status, TtsPlaybackStatus.error);
      expect(controller.error, isA<StateError>());
      controller.dispose();
    });

    test('notifies listeners for status, position and rate changes', () async {
      final service = _FakeTts();
      final controller = ReaderTtsController(service);
      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.play(const [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 2, text: '甲。'),
        TtsSegment(blockIndex: 1, startOffset: 0, endOffset: 2, text: '乙。'),
      ]);
      expect(notifications, greaterThanOrEqualTo(1));
      final afterPlay = notifications;
      service.emit(const TtsPlaybackEvent(position: 1));
      expect(notifications, afterPlay + 1);
      await controller.setRate(1.5);
      expect(controller.rate, 1.5);
      expect(notifications, greaterThan(afterPlay + 1));
      await controller.pause();
      expect(controller.status, TtsPlaybackStatus.paused);
      controller.dispose();
    });

    test('pause only pauses active speech; stop preserves position', () async {
      final service = _FakeTts();
      final controller = ReaderTtsController(service);
      await controller.play(const [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 2, text: '甲。'),
        TtsSegment(blockIndex: 1, startOffset: 0, endOffset: 2, text: '乙。'),
      ]);
      service.emit(const TtsPlaybackEvent(position: 1));
      await controller.stop();
      expect(controller.status, TtsPlaybackStatus.stopped);
      expect(controller.position, 1);
      await controller.pause();
      expect(controller.status, TtsPlaybackStatus.stopped);
      await controller.resume();
      expect(controller.status, TtsPlaybackStatus.playing);
      expect(service.spoken.last, '乙。');
      controller.dispose();
    });

    test('navigation preserves paused state and ignores late events', () async {
      final service = _FakeTts();
      final controller = ReaderTtsController(service);
      await controller.play(const [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 1, text: '甲'),
        TtsSegment(blockIndex: 1, startOffset: 0, endOffset: 1, text: '乙'),
      ]);
      await controller.next();
      expect(controller.position, 1);
      expect(service.spoken.last, '乙');
      await controller.next();
      expect(service.spoken.length, 2);
      await controller.pause();
      await controller.previous();
      service.emit(const TtsPlaybackEvent(completed: true));
      service.emit(const TtsPlaybackEvent(error: 'late'));
      expect(controller.position, 0);
      expect(controller.status, TtsPlaybackStatus.paused);
      await controller.resume();
      expect(service.spoken.last, '甲');
      controller.dispose();
    });

    test('empty list stops previous speech', () async {
      final service = _FakeTts();
      final controller = ReaderTtsController(service);
      await controller.play(const [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 1, text: '甲')
      ]);
      await controller.play(const []);
      expect(service.stops, 1);
      expect(controller.status, TtsPlaybackStatus.completed);
      controller.dispose();
    });

    test('listeners can stop on playing without old speak escaping', () async {
      final service = _FakeTts();
      final controller = ReaderTtsController(service);
      controller.addListener(() {
        if (controller.status == TtsPlaybackStatus.playing) {
          unawaited(controller.stop());
        }
      });
      await controller.play(const [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 1, text: '甲')
      ]);
      expect(service.spoken, isEmpty);
      expect(controller.status, TtsPlaybackStatus.stopped);
      controller.dispose();
    });

    test('listener play during stop is not stopped by old operation', () async {
      final service = _FakeTts();
      final controller = ReaderTtsController(service);
      const a = [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 1, text: '甲')
      ];
      const b = [
        TtsSegment(blockIndex: 1, startOffset: 0, endOffset: 1, text: '乙')
      ];
      await controller.play(a);
      controller.addListener(() {
        if (controller.status == TtsPlaybackStatus.stopped) {
          unawaited(controller.play(b));
        }
      });
      await controller.stop();
      expect(service.stops, 0);
      expect(service.spoken.last, '乙');
      expect(controller.status, TtsPlaybackStatus.playing);
      controller.dispose();
    });

    test('navigation from pause and stop listeners preserves interruption',
        () async {
      for (final stop in [false, true]) {
        final service = _FakeTts();
        final controller = ReaderTtsController(service);
        await controller.play(const [
          TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 1, text: '甲'),
          TtsSegment(blockIndex: 1, startOffset: 0, endOffset: 1, text: '乙'),
        ]);
        controller.addListener(() {
          if (controller.status ==
                  (stop
                      ? TtsPlaybackStatus.stopped
                      : TtsPlaybackStatus.paused) &&
              controller.position == 0) {
            unawaited(controller.next());
          }
        });
        if (stop) {
          await controller.stop();
          expect(service.stops, 1);
        } else {
          await controller.pause();
          expect(service.pauses, 1);
        }
        expect(controller.position, 1);
        controller.dispose();
      }
    });

    test('event stream position and errors update controller state', () async {
      final service = _FakeTts();
      final controller = ReaderTtsController(service);
      await controller.play(const [
        TtsSegment(blockIndex: 0, startOffset: 0, endOffset: 2, text: '甲。'),
        TtsSegment(blockIndex: 1, startOffset: 0, endOffset: 2, text: '乙。'),
      ]);
      service.emit(const TtsPlaybackEvent(position: 1));
      expect(controller.position, 1);
      service.emit(const TtsPlaybackEvent(error: 'platform error'));
      expect(controller.status, TtsPlaybackStatus.error);
      expect(controller.error, 'platform error');
      controller.dispose();
    });
  });
}

class _FakeTts implements SystemTtsService {
  final StreamController<TtsPlaybackEvent> _events =
      StreamController<TtsPlaybackEvent>.broadcast(sync: true);
  final List<String> spoken = [];
  Completer<void>? speakCompleter;
  bool failNextSpeak = false;
  int stops = 0;
  int pauses = 0;

  @override
  Stream<TtsPlaybackEvent> get events => _events.stream;

  @override
  Future<void> speak(String text, {required double rate}) {
    spoken.add(text);
    if (failNextSpeak) {
      failNextSpeak = false;
      return Future<void>.error(StateError('speak failure'));
    }
    return speakCompleter?.future ?? Future<void>.value();
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  void emit(TtsPlaybackEvent event) => _events.add(event);
}
