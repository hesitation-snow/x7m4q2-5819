import 'dart:async';

import 'package:flutter/foundation.dart';

/// Minimal reader-block input for TTS adaptation. [text] uses Dart UTF-16
/// indexing, matching String.length/substring and the reader's text offsets.
class TtsReaderBlock {
  const TtsReaderBlock({
    required this.text,
    this.image,
    this.isDivider = false,
    this.blockIndex = 0,
  });

  final String text;
  final String? image;
  final bool isDivider;
  final int blockIndex;
}

/// A speakable range in a reader block. [startOffset]/[endOffset] are UTF-16
/// code-unit offsets, end-exclusive, into the original block text.
class TtsSegment {
  const TtsSegment({
    required this.blockIndex,
    required this.startOffset,
    required this.endOffset,
    required this.text,
  });

  final int blockIndex;
  final int startOffset;
  final int endOffset;
  final String text;

  @override
  String toString() =>
      'TtsSegment(blockIndex: $blockIndex, range: $startOffset..$endOffset, text: $text)';
}

/// Splits reader blocks at sentence punctuation while retaining source ranges.
/// Image/divider blocks and text containing only whitespace/symbols are skipped.
/// Whitespace surrounding a sentence is excluded from its range; punctuation
/// stays attached to the sentence before it.
List<TtsSegment> adaptReaderBlocksToTts(
  Iterable<TtsReaderBlock> blocks, {
  int maxSegmentCodeUnits = 240,
}) {
  if (maxSegmentCodeUnits < 1) {
    throw ArgumentError.value(maxSegmentCodeUnits, 'maxSegmentCodeUnits');
  }
  final result = <TtsSegment>[];
  for (final block in blocks) {
    if (block.image != null || block.isDivider || block.text.isEmpty) continue;
    final text = block.text;
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (_isSentenceEnd(text.codeUnitAt(i))) {
        var end = i + 1;
        while (end < text.length && _isSentenceEnd(text.codeUnitAt(end))) {
          end++;
        }
        _appendRange(result, block, start, end, maxSegmentCodeUnits);
        start = end;
        i = end - 1;
      }
    }
    _appendRange(result, block, start, text.length, maxSegmentCodeUnits);
  }
  return List.unmodifiable(result);
}

bool _isSentenceEnd(int unit) =>
    unit == 0x3002 || // 。
    unit == 0xff01 || // ！
    unit == 0xff1f || // ？
    unit == 0x0021 || // !
    unit == 0x003f || // ?
    unit == 0x002e || // .
    unit == 0x2026; // …

bool _isSpeakableUnit(int unit) {
  // Whitespace/control is excluded here; punctuation remains when attached to
  // speech, while punctuation-only runs are filtered by _containsSpeech.
  if (unit <= 0x20 || unit == 0x3000 || (unit >= 0x7f && unit <= 0x9f)) {
    return false;
  }
  return true;
}

bool _containsSpeech(String text, int from, int to) {
  for (var i = from; i < to; i++) {
    final unit = text.codeUnitAt(i);
    if ((unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5a) ||
        (unit >= 0x61 && unit <= 0x7a) ||
        unit >= 0x80) {
      // CJK and most non-ASCII scripts are speech. Unicode punctuation blocks
      // are omitted unless accompanied by a letter, digit or emoji elsewhere.
      if (!((unit >= 0x2000 && unit <= 0x206f) ||
          (unit >= 0x3000 && unit <= 0x303f) ||
          (unit >= 0xff00 && unit <= 0xff65))) {
        return true;
      }
    }
  }
  return false;
}

void _appendRange(List<TtsSegment> output, TtsReaderBlock block, int from,
    int to, int maxCodeUnits) {
  while (from < to && !_isSpeakableUnit(block.text.codeUnitAt(from))) {
    from++;
  }
  while (to > from && !_isSpeakableUnit(block.text.codeUnitAt(to - 1))) {
    to--;
  }
  if (from >= to || !_containsSpeech(block.text, from, to)) return;

  var cursor = from;
  while (cursor < to) {
    var end = (cursor + maxCodeUnits).clamp(cursor + 1, to);
    // Avoid separating a UTF-16 surrogate pair when a hard limit is reached.
    if (end < to &&
        end > cursor &&
        _isHighSurrogate(block.text.codeUnitAt(end - 1)) &&
        _isLowSurrogate(block.text.codeUnitAt(end))) {
      end--;
      // A limit of one code unit must still make progress for surrogate pairs.
      if (end == cursor) end = cursor + 2;
    }
    // Prefer a nearby whitespace boundary without discarding source characters.
    if (end < to) {
      final lowerBound = cursor + (maxCodeUnits ~/ 2);
      for (var candidate = end; candidate > lowerBound; candidate--) {
        if (_isWhitespace(block.text.codeUnitAt(candidate - 1))) {
          end = candidate;
          break;
        }
      }
    }
    while (end < to && _isWhitespace(block.text.codeUnitAt(end))) {
      end++;
    }
    var visibleEnd = end;
    while (visibleEnd > cursor &&
        _isWhitespace(block.text.codeUnitAt(visibleEnd - 1))) {
      visibleEnd--;
    }
    if (visibleEnd > cursor) {
      output.add(TtsSegment(
        blockIndex: block.blockIndex,
        startOffset: cursor,
        endOffset: visibleEnd,
        text: block.text.substring(cursor, visibleEnd),
      ));
    }
    cursor = end;
  }
}

bool _isWhitespace(int unit) => unit <= 0x20 || unit == 0x3000;
bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

enum TtsPlaybackStatus { idle, playing, paused, stopped, completed, error }

/// Playback updates emitted by an injected platform/system TTS implementation.
class TtsPlaybackEvent {
  const TtsPlaybackEvent({
    this.position,
    this.completed = false,
    this.interrupted = false,
    this.error,
  });

  /// Current segment index, or null if position is unchanged.
  final int? position;
  final bool completed;

  /// The system interrupted the current utterance; resume restarts the segment.
  final bool interrupted;
  final Object? error;
}

/// Platform boundary. A native Android implementation can be added separately.
abstract interface class SystemTtsService {
  Stream<TtsPlaybackEvent> get events;
  Future<void> speak(String text, {required double rate});
  Future<void> pause();
  Future<void> stop();
}

/// Pure-Dart playback controller; service is injectable for unit tests.
/// Generation checks discard stale asynchronous completions/events after a new
/// play/stop request.
class ReaderTtsController extends ChangeNotifier {
  ReaderTtsController(this._service) {
    _subscription = _service.events.listen(_onEvent, onError: _onStreamError);
  }

  final SystemTtsService _service;
  late final StreamSubscription<TtsPlaybackEvent> _subscription;
  List<TtsSegment> _segments = const [];
  int _generation = 0;
  bool _disposed = false;
  double _rate = 1.0;

  TtsPlaybackStatus _status = TtsPlaybackStatus.idle;
  int _position = 0;
  Object? _error;

  TtsPlaybackStatus get status => _status;
  int get position => _position;
  Object? get error => _error;
  double get rate => _rate;
  int get segmentCount => _segments.length;
  TtsSegment? get currentSegment =>
      _position >= 0 && _position < _segments.length
          ? _segments[_position]
          : null;

  set status(TtsPlaybackStatus value) {
    if (_status == value) return;
    _status = value;
    _notifyIfAlive();
  }

  set position(int value) {
    if (_position == value) return;
    _position = value;
    _notifyIfAlive();
  }

  set error(Object? value) {
    if (_error == value) return;
    _error = value;
    _notifyIfAlive();
  }

  set _rateValue(double value) {
    if (_rate == value) return;
    _rate = value;
    _notifyIfAlive();
  }

  void _notifyIfAlive() {
    if (!_disposed) notifyListeners();
  }

  Future<void> play(List<TtsSegment> segments, {int startAt = 0}) async {
    _ensureAlive();
    final generation = ++_generation;
    _segments = List.unmodifiable(segments);
    error = null;
    if (!_isCurrent(generation)) return;
    if (_segments.isEmpty) {
      position = 0;
      if (!_isCurrent(generation)) return;
      status = TtsPlaybackStatus.completed;
      if (!_isCurrent(generation)) return;
      try {
        await _service.stop();
      } catch (e) {
        if (_isCurrent(generation)) _setError(e);
      }
      return;
    }
    position = startAt.clamp(0, _segments.length - 1);
    if (!_isCurrent(generation)) return;
    await _speakCurrent(generation);
  }

  Future<void> resume() async {
    _ensureAlive();
    if (_segments.isEmpty) return;
    final generation = ++_generation;
    error = null;
    if (!_isCurrent(generation)) return;
    await _speakCurrent(generation);
  }

  Future<void> pause() async {
    _ensureAlive();
    if (status != TtsPlaybackStatus.playing) return;
    final generation = ++_generation;
    status = TtsPlaybackStatus.paused;
    if (!_isCurrent(generation)) return;
    try {
      await _service.pause();
      if (_isCurrent(generation)) status = TtsPlaybackStatus.paused;
    } catch (e) {
      if (_isCurrent(generation)) _setError(e);
    }
  }

  Future<void> stop() async {
    _ensureAlive();
    final generation = ++_generation;
    // Invalidate active speech immediately. Native stop is terminal for this
    // utterance; resume() will explicitly speak the current segment anew.
    status = TtsPlaybackStatus.stopped;
    if (!_isCurrent(generation)) return;
    try {
      await _service.stop();
      if (_isCurrent(generation)) status = TtsPlaybackStatus.stopped;
    } catch (e) {
      if (_isCurrent(generation)) _setError(e);
    }
  }

  Future<void> setRate(double value) async {
    _ensureAlive();
    if (!value.isFinite || value <= 0) {
      throw ArgumentError.value(
          value, 'value', 'Rate must be finite and positive');
    }
    final before = _generation;
    _rateValue = value;
    if (!_isCurrent(before)) return;
    if (status == TtsPlaybackStatus.playing && _segments.isNotEmpty) {
      await _speakCurrent(++_generation);
    }
  }

  /// Move one segment; an out-of-range request leaves playback unchanged.
  /// While playing, the selected segment is spoken immediately. Otherwise only
  /// the position changes, so resume() starts at the selected segment.
  Future<void> previous() => _moveBy(-1);
  Future<void> next() => _moveBy(1);

  Future<void> _moveBy(int delta) async {
    _ensureAlive();
    final target = position + delta;
    if (target < 0 || target >= _segments.length) return;
    final playing = status == TtsPlaybackStatus.playing;
    // Moving while paused/stopped must not cancel an in-flight pause/stop.
    final generation = playing ? ++_generation : _generation;
    position = target;
    if (playing && _isCurrent(generation)) await _speakCurrent(generation);
  }

  Future<void> _speakCurrent(int generation) async {
    if (!_isCurrent(generation)) return;
    status = TtsPlaybackStatus.playing;
    if (!_isCurrent(generation)) return;
    try {
      await _service.speak(_segments[position].text, rate: _rate);
      // A completion event normally advances position; speak() completion is
      // deliberately not treated as utterance completion (some bridges return
      // when queued, not when audio finishes).
      if (!_isCurrent(generation)) return;
    } catch (e) {
      if (_isCurrent(generation)) _setError(e);
    }
  }

  void _onEvent(TtsPlaybackEvent event) {
    if (_disposed || status != TtsPlaybackStatus.playing) return;
    final generation = _generation;
    if (event.error != null) {
      _setError(event.error!);
      return;
    }
    if (event.interrupted) {
      status = TtsPlaybackStatus.paused;
      return;
    }
    if (event.position != null && _segments.isNotEmpty) {
      position = event.position!.clamp(0, _segments.length - 1);
      if (!_isCurrent(generation)) return;
    }
    if (event.completed) {
      if (position + 1 < _segments.length) {
        position++;
        if (!_isCurrent(generation)) return;
        unawaited(_speakCurrent(generation));
      } else {
        status = TtsPlaybackStatus.completed;
      }
    }
  }

  void _onStreamError(Object e, StackTrace _) {
    if (!_disposed) _setError(e);
  }

  void _setError(Object e) {
    final generation = _generation;
    error = e;
    if (_isCurrent(generation)) status = TtsPlaybackStatus.error;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _ensureAlive() {
    if (_disposed) throw StateError('ReaderTtsController is disposed');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
