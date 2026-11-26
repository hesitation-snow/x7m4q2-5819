import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../reader/reader_speech_session.dart';
import '../reader/reader_tts_resume.dart';
import '../reader/reading_position.dart';
import 'edge_speech.dart';
import 'reader_audio_handler.dart';
import 'reader_tts_preferences.dart';

class ListeningSessionTransfer {
  const ListeningSessionTransfer({
    required this.session,
    required this.config,
    required this.accountId,
    required this.releaseResources,
    this.coverUrl = '',
  });

  final ReaderSpeechSession session;
  final SpeechSynthesisConfig? config;
  final String accountId;
  final Future<void> Function()? releaseResources;
  final String coverUrl;
}

/// Playback that outlives the reader page. Leaving a chapter keeps the
/// current session running and exposes it to the home dock.
class ListeningNow extends ChangeNotifier {
  ListeningNow._() {
    ReaderTtsPreferences.revision.addListener(_onPreferencesChanged);
  }
  static final ListeningNow instance = ListeningNow._();

  ReaderSpeechSession? _session;
  Future<void> Function()? _releaseResources;
  Future<void>? _stopFuture;
  String? _lastSavedResumeKey;

  SpeechSynthesisConfig? config;
  String? lastError;
  String accountId = '';
  String bookTitle = '';
  String chapterTitle = '';
  String coverUrl = '';
  int bookId = 0;
  int chapterId = 0;
  int volumeId = 0;

  ReaderSpeechSession? get session => _session;
  bool get active => _session != null && !_session!.isStopped;
  bool get isPlayingOrLoading => active && !(_session?.isPaused ?? true);

  void adopt({
    required ReaderSpeechSession session,
    required String bookTitle,
    required String chapterTitle,
    required int bookId,
    required int chapterId,
    required int volumeId,
    String coverUrl = '',
    SpeechSynthesisConfig? config,
    String accountId = '',
    Future<void> Function()? releaseResources,
  }) {
    final trimmedCover = coverUrl.trim();
    if (identical(_session, session)) {
      lastError = null;
      this.bookTitle = bookTitle;
      this.chapterTitle = chapterTitle;
      if (trimmedCover.isNotEmpty) this.coverUrl = trimmedCover;
      this.config = config;
      this.accountId = accountId;
      notifyListeners();
      return;
    }
    final previous = _session;
    final previousRelease = _releaseResources;
    _session = session;
    _releaseResources = releaseResources;
    this.config = config;
    lastError = null;
    this.accountId = accountId;
    this.bookTitle = bookTitle;
    this.chapterTitle = chapterTitle;
    this.coverUrl = trimmedCover;
    this.bookId = bookId;
    this.chapterId = chapterId;
    this.volumeId = volumeId;
    session.addListener(_onSession);
    _lastSavedResumeKey = null;
    _saveResumeProgress(session);
    notifyListeners();
    if (previous != null) {
      previous.removeListener(_onSession);
      Future<void>(() async {
        // Do not call previous.stop() once a new session has taken over the shared handler.
        previous.dispose();
        try {
          await previousRelease?.call();
        } catch (_) {}
      });
    }
  }

  bool matchesChapter({
    required int bookId,
    required int chapterId,
    String? accountId,
  }) {
    if (!active || _stopFuture != null) return false;
    if (this.bookId != bookId || this.chapterId != chapterId) return false;
    if (accountId != null &&
        this.accountId.isNotEmpty &&
        this.accountId != accountId) {
      return false;
    }
    return true;
  }

  ListeningSessionTransfer? take({
    required int bookId,
    required int chapterId,
    String? accountId,
  }) {
    if (!matchesChapter(
      bookId: bookId,
      chapterId: chapterId,
      accountId: accountId,
    )) {
      return null;
    }
    final session = _session;
    if (session == null) return null;
    session.removeListener(_onSession);
    final transfer = ListeningSessionTransfer(
      session: session,
      config: config,
      accountId: this.accountId,
      releaseResources: _releaseResources,
      coverUrl: coverUrl,
    );
    _session = null;
    _releaseResources = null;
    _lastSavedResumeKey = null;
    config = null;
    lastError = null;
    coverUrl = '';
    this.accountId = '';
    notifyListeners();
    return transfer;
  }

  void updateCoverUrl(String url, {int? bookId}) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || !active) return;
    if (bookId != null && this.bookId != bookId) return;
    if (coverUrl == trimmed) return;
    coverUrl = trimmed;
    notifyListeners();
  }

  void _saveResumeProgress(ReaderSpeechSession session) {
    if (accountId.isEmpty || bookId <= 0 || chapterId <= 0) return;
    final segment = session.currentSegment;
    if (segment == null) return;
    final key = '$bookId:$chapterId:${segment.blockIndex}:${segment.startOffset}';
    if (key == _lastSavedResumeKey) return;
    _lastSavedResumeKey = key;
    unawaited(
      ReaderTtsResumeStore.save(
        accountId: accountId,
        bookId: bookId,
        chapterId: chapterId,
        position: ReadingPosition.text(
          blockIndex: segment.blockIndex,
          offset: segment.startOffset,
        ),
      ).catchError((Object _) {}),
    );
  }

  void _onPreferencesChanged() {
    if (!active || _session == null || _stopFuture != null) return;
    unawaited(_applyUpdatedPreferences());
  }

  Future<void> _applyUpdatedPreferences() async {
    final session = _session;
    if (session == null || session.isStopped || _stopFuture != null) return;
    final currentConfig = config;
    final acc = accountId.isNotEmpty
        ? accountId
        : ReaderTtsPreferences.currentAccountKey();
    final prefs = await ReaderTtsPreferences.loadOrNull(acc);
    if (prefs == null ||
        !identical(_session, session) ||
        session.isStopped ||
        _stopFuture != null) {
      return;
    }
    session.setSegmentInterval(prefs.segmentInterval);
    if (session.sleepTimer != prefs.sleepTimer) {
      session.setSleepTimer(prefs.sleepTimer);
    }
    if (currentConfig != null) {
      if (currentConfig.source == 'edge') {
        try {
          await activeReaderAudioHandler?.setPlaybackRate(prefs.rate);
        } catch (_) {}
        if (!identical(_session, session) || session.isStopped) return;
        final nextConfig =
            edgeSpeechConfig(voiceByLanguage: prefs.edgeVoiceByLanguage);
        if (jsonEncode(nextConfig.options) !=
            jsonEncode(currentConfig.options)) {
          config = nextConfig;
          await session.updateConfig(nextConfig);
        }
      } else if (currentConfig.source == 'system') {
        try {
          await activeReaderAudioHandler?.setPlaybackRate(1.0);
        } catch (_) {}
        if (!identical(_session, session) || session.isStopped) return;
        final nextVoice = prefs.systemVoiceId ?? currentConfig.voice;
        final nextOptions = <String, Object?>{
          ...currentConfig.options,
          'voiceByLanguage':
              Map<String, String>.unmodifiable(prefs.systemVoiceByLanguage),
        };
        if (prefs.rate != currentConfig.rate ||
            nextVoice != currentConfig.voice ||
            jsonEncode(nextOptions) != jsonEncode(currentConfig.options)) {
          final nextConfig = SpeechSynthesisConfig(
            source: currentConfig.source,
            voice: nextVoice,
            language: currentConfig.language,
            rate: prefs.rate,
            fileExtension: currentConfig.fileExtension,
            options: nextOptions,
          );
          config = nextConfig;
          await session.updateConfig(nextConfig);
        }
      } else if (currentConfig.source == 'custom' &&
          prefs.rate != currentConfig.rate) {
        try {
          await activeReaderAudioHandler?.setPlaybackRate(1.0);
        } catch (_) {}
        if (!identical(_session, session) || session.isStopped) return;
        final nextConfig = SpeechSynthesisConfig(
          source: currentConfig.source,
          voice: currentConfig.voice,
          language: currentConfig.language,
          rate: prefs.rate,
          fileExtension: currentConfig.fileExtension,
          options: currentConfig.options,
        );
        config = nextConfig;
        await session.updateConfig(nextConfig);
      }
    }
    if (identical(_session, session)) {
      notifyListeners();
    }
  }

  void _onSession() {
    final session = _session;
    if (session == null || _stopFuture != null) return;
    _saveResumeProgress(session);
    if (session.isStopped) {
      final sessionError = session.error;
      lastError =
          sessionError != null && sessionError.isNotEmpty ? sessionError : null;
      final release = _releaseResources;
      _session = null;
      _releaseResources = null;
      _lastSavedResumeKey = null;
      config = null;
      coverUrl = '';
      accountId = '';
      session.removeListener(_onSession);
      notifyListeners();
      Future<void>(() async {
        session.dispose();
        try {
          await release?.call();
        } catch (_) {}
      });
      return;
    }
    notifyListeners();
  }

  Future<void> toggle() async {
    final session = _session;
    if (session == null || session.isStopped) return;
    if (session.isPaused) {
      await session.resume();
    } else {
      await session.pause();
    }
  }

  Future<void> next() => _session?.next() ?? Future<void>.value();
  Future<void> previous() => _session?.previous() ?? Future<void>.value();

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    final future = _stopInternal();
    _stopFuture = future;
    future.whenComplete(() {
      if (identical(_stopFuture, future)) _stopFuture = null;
    });
    return future;
  }

  Future<void> _stopInternal() async {
    final session = _session;
    final release = _releaseResources;
    _session = null;
    _releaseResources = null;
    _lastSavedResumeKey = null;
    config = null;
    lastError = null;
    coverUrl = '';
    accountId = '';
    session?.removeListener(_onSession);
    try {
      if (session != null && !session.isStopped) {
        await session.stop();
      }
    } catch (_) {}
    session?.dispose();
    try {
      await release?.call();
    } catch (_) {}
    notifyListeners();
  }
}
