import 'dart:async';

import 'package:flutter/foundation.dart';
import 'reader_tts_core.dart';
import 'structured_content.dart';

enum ReaderSpeechLanguage { chinese, japanese, korean, other }
enum ReaderLanguageFilter { automatic, chineseOnly, japaneseOnly }

/// Optional per-block language metadata. Locale tags are normalized by the
/// classifier (for example `ja-JP`, `ko`, `zh-Hant`).
class ReaderLanguageBlock {
  const ReaderLanguageBlock({required this.blockIndex, this.locale});
  final int blockIndex;
  final String? locale;
}

class ClassifiedTtsSegment {
  const ClassifiedTtsSegment({required this.segment, required this.language, this.locale, this.explicitLocale = false});
  final TtsSegment segment;
  final ReaderSpeechLanguage language;
  final String? locale;
  final bool explicitLocale;
}

/// Classifies TTS segments. Explicit locale metadata wins; when absent, kana
/// and Hangul are strong script signals. Han-only text deliberately resolves
/// to [defaultLanguage] rather than being guessed as Japanese.
class ReaderLanguageSegments {
  const ReaderLanguageSegments({this.defaultLanguage = ReaderSpeechLanguage.chinese});
  final ReaderSpeechLanguage defaultLanguage;

  List<ClassifiedTtsSegment> classify(
    Iterable<TtsSegment> segments, {
    Iterable<ReaderLanguageBlock> metadata = const [],
    Map<int, StructuredBlock> structuredBlocks = const {},
    Map<int, String> localeByBlock = const {},
  }) {
    final localeMap = <int, String>{};
    for (final item in metadata) {
      final locale = item.locale;
      if (locale != null && locale.trim().isNotEmpty) {
        localeMap[item.blockIndex] = locale;
      }
    }
    for (final entry in localeByBlock.entries) {
      if (entry.value.trim().isNotEmpty) localeMap[entry.key] = entry.value;
    }
    final result = <ClassifiedTtsSegment>[];
    for (final segment in segments) {
      final locale = localeMap[segment.blockIndex];
      final explicit = _fromLocale(locale);
      final detected = explicit ?? _detectScript(segment.text) ?? defaultLanguage;
      result.add(ClassifiedTtsSegment(segment: segment, language: detected, locale: locale, explicitLocale: explicit != null));
    }
    return List.unmodifiable(result);
  }

  List<TtsSegment> filter(
    Iterable<TtsSegment> segments, {
    ReaderLanguageFilter filter = ReaderLanguageFilter.automatic,
    Iterable<ReaderLanguageBlock> metadata = const [],
    Map<int, StructuredBlock> structuredBlocks = const {},
    Map<int, String> localeByBlock = const {},
  }) {
    final classified = classify(segments, metadata: metadata, structuredBlocks: structuredBlocks, localeByBlock: localeByBlock);
    if (filter == ReaderLanguageFilter.automatic) return List.unmodifiable(classified.map((e) => e.segment));
    final wanted = filter == ReaderLanguageFilter.chineseOnly ? ReaderSpeechLanguage.chinese : ReaderSpeechLanguage.japanese;
    return List.unmodifiable(classified.where((e) => e.language == wanted).map((e) => e.segment));
  }

  static ReaderSpeechLanguage? _fromLocale(String? value) {
    if (value == null) return null;
    final locale = value.trim().toLowerCase().replaceAll('_', '-');
    if (locale == 'zh' || locale.startsWith('zh-')) return ReaderSpeechLanguage.chinese;
    if (locale == 'ja' || locale.startsWith('ja-')) return ReaderSpeechLanguage.japanese;
    if (locale == 'ko' || locale.startsWith('ko-')) return ReaderSpeechLanguage.korean;
    return ReaderSpeechLanguage.other;
  }

  static ReaderSpeechLanguage? _detectScript(String text) {
    var kana = false, hangul = false;
    for (final rune in text.runes) {
      // Hiragana/Katakana only: the broad CJK punctuation range overlaps
      // punctuation and is not a reliable Japanese-language indicator.
      if ((rune >= 0x3041 && rune <= 0x3096) ||
          (rune >= 0x30a1 && rune <= 0x30fa) ||
          (rune >= 0x31f0 && rune <= 0x31ff) ||
          (rune >= 0xff66 && rune <= 0xff9d)) {
        kana = true;
      }
      if ((rune >= 0xac00 && rune <= 0xd7af) ||
          (rune >= 0x1100 && rune <= 0x11ff) ||
          (rune >= 0x3130 && rune <= 0x318f)) {
        hangul = true;
      }
    }
    if (kana) return ReaderSpeechLanguage.japanese;
    if (hangul) return ReaderSpeechLanguage.korean;
    return null;
  }
}

enum PlaybackSleepTimer { none, minutes15, minutes30, minutes60, chapterEnd }

/// Optional speech synthesis cache. Implementations must prepare audio without
/// invoking the audible playback path.
abstract interface class SpeechAudioCache {
  Future<void> prefetch(String accountId, TtsSegment segment);
  Future<void> clear(String accountId);
}

typedef SpeechSegmentPreloader = Future<void> Function(String accountId, TtsSegment segment);

/// High-level playback conveniences around the existing controller. No voice
/// configuration is performed here; voice ownership remains with the caller.
class PlaybackCoordinator extends ChangeNotifier {
  PlaybackCoordinator({required this.controller, required this.accountId, this.cache, this.preloader, this.prefetchCount = 2}) {
    if (prefetchCount < 0) throw ArgumentError.value(prefetchCount, 'prefetchCount');
    _subscription = _controllerListener;
    controller.addListener(_subscription);
  }

  final ReaderTtsController controller;
  final String accountId;
  final SpeechAudioCache? cache;
  final SpeechSegmentPreloader? preloader;
  final int prefetchCount;
  late final VoidCallback _subscription;
  List<TtsSegment> _segments = const [];
  int _generation = 0;
  int _gapMs = 0;
  Timer? _gapTimer;
  Timer? _sleepTimer;
  bool _disposed = false;

  int get gapMilliseconds => _gapMs;
  PlaybackSleepTimer get sleepTimer => _sleepMode;
  PlaybackSleepTimer _sleepMode = PlaybackSleepTimer.none;

  void _controllerListener() {
    if (_disposed) return;
    if (controller.status == TtsPlaybackStatus.completed && _gapMs > 0 && controller.position + 1 < _segments.length) {
      _scheduleGapAdvance(_generation);
    } else if (controller.status != TtsPlaybackStatus.completed) {
      _gapTimer?.cancel();
    }
    _prefetchUpcoming(_generation);
    notifyListeners();
  }

  Future<void> play(List<TtsSegment> segments, {int startAt = 0, required String accountId}) async {
    _ensureAlive();
    final generation = ++_generation;
    _gapTimer?.cancel();
    _segments = List.unmodifiable(segments);
    if (accountId != this.accountId) return;
    await controller.play(_segments, startAt: startAt);
    if (_valid(generation)) _prefetchUpcoming(generation);
  }

  /// Immediate segment selection, intended for tapping a paragraph/segment.
  Future<void> jumpTo(int index, {required String accountId}) async {
    _ensureAlive();
    if (accountId != this.accountId || index < 0 || index >= _segments.length) return;
    final generation = ++_generation;
    _gapTimer?.cancel();
    await controller.play(_segments, startAt: index);
    if (_valid(generation)) _prefetchUpcoming(generation);
  }

  Future<void> previous() async {
    _ensureAlive();
    ++_generation;
    _gapTimer?.cancel();
    await controller.previous();
  }

  Future<void> next() async {
    _ensureAlive();
    ++_generation;
    _gapTimer?.cancel();
    await controller.next();
    _prefetchUpcoming(_generation);
  }

  void setParagraphInterval(Duration interval) {
    _ensureAlive();
    if (interval.isNegative) throw ArgumentError.value(interval, 'interval');
    _gapMs = interval.inMilliseconds;
    if (_gapMs == 0) _gapTimer?.cancel();
  }

  void setSleepTimer(PlaybackSleepTimer mode) {
    _ensureAlive();
    _sleepTimer?.cancel();
    _sleepMode = mode;
    if (mode == PlaybackSleepTimer.none || mode == PlaybackSleepTimer.chapterEnd) return;
    final minutes = switch (mode) { PlaybackSleepTimer.minutes15 => 15, PlaybackSleepTimer.minutes30 => 30, PlaybackSleepTimer.minutes60 => 60, _ => 0 };
    _sleepTimer = Timer(Duration(minutes: minutes), () { if (!_disposed) unawaited(controller.pause()); });
  }

  void onChapterEnd() {
    if (!_disposed && _sleepMode == PlaybackSleepTimer.chapterEnd) unawaited(controller.pause());
  }

  Future<void> _prefetchUpcoming(int generation) async {
    if (!_valid(generation) || _segments.isEmpty) return;
    final start = (controller.position + 1).clamp(0, _segments.length);
    final end = (start + prefetchCount).clamp(start, _segments.length);
    for (var i = start; i < end; i++) {
      if (!_valid(generation)) return;
      try {
        final loader = preloader;
        if (loader != null) {
          await loader(accountId, _segments[i]);
        } else if (cache != null) {
          await cache!.prefetch(accountId, _segments[i]);
        }
      } catch (_) {
        // Prefetch is opportunistic and must never interrupt audible playback.
      }
    }
  }

  void _scheduleGapAdvance(int generation) {
    if (_gapTimer?.isActive == true) return;
    _gapTimer = Timer(Duration(milliseconds: _gapMs), () {
      if (_valid(generation) && controller.status == TtsPlaybackStatus.completed && controller.position + 1 < _segments.length) {
        unawaited(controller.next());
      }
    });
  }

  bool _valid(int generation) => !_disposed && generation == _generation;
  void _ensureAlive() { if (_disposed) throw StateError('PlaybackCoordinator is disposed'); }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _gapTimer?.cancel();
    _sleepTimer?.cancel();
    controller.removeListener(_subscription);
    unawaited(cache?.clear(accountId));
    super.dispose();
  }
}

// Extension-friendly helpers for mapping current reader blocks without changing
// StructuredBlock or the core controller API.
List<TtsReaderBlock> ttsReaderBlocksFromStructured(Iterable<StructuredBlock> blocks) => [
  for (var index = 0; index < blocks.length; index++)
    TtsReaderBlock(text: blocks.elementAt(index).text, isDivider: blocks.elementAt(index).isDivider, image: blocks.elementAt(index).imageUrl, blockIndex: index),
];

/// Derive block-level locale hints from HTML metadata supplied by the caller.
List<ReaderLanguageBlock> readerLanguageMetadata(Map<int, String> localeByBlock) => [
  for (final entry in localeByBlock.entries) ReaderLanguageBlock(blockIndex: entry.key, locale: entry.value),
];

/// Convenience bridge for callers who already have a `locale` attribute per
/// structured block in a side table; no mutation of StructuredBlock required.
Map<int, String> structuredLocaleMap(Iterable<StructuredBlock> blocks, {String? defaultLocale}) => {
  for (var i = 0; i < blocks.length; i++) if (defaultLocale != null) i: defaultLocale,
};

/// Ignore unused metadata? Kept as a typed adapter for optional structured input.
TtsSegment segmentForStructuredBlock(StructuredBlock block, int blockIndex, int start, int end) => TtsSegment(blockIndex: blockIndex, startOffset: start, endOffset: end, text: block.text.substring(start, end));