import 'package:flutter/foundation.dart';

import '../reader/reader_speech_session.dart';

/// Playback that outlives the reader page. Leaving a chapter keeps the
/// current session running and exposes it to the home dock.
class ListeningNow extends ChangeNotifier {
  ListeningNow._();
  static final ListeningNow instance = ListeningNow._();

  ReaderSpeechSession? _session;
  Future<void> Function()? _releaseResources;
  Future<void>? _stopFuture;

  String bookTitle = '';
  String chapterTitle = '';
  int bookId = 0;
  int chapterId = 0;
  int volumeId = 0;

  ReaderSpeechSession? get session => _session;
  bool get active => _session != null && !_session!.isStopped;

  void adopt({
    required ReaderSpeechSession session,
    required String bookTitle,
    required String chapterTitle,
    required int bookId,
    required int chapterId,
    required int volumeId,
    Future<void> Function()? releaseResources,
  }) {
    if (identical(_session, session)) {
      this.bookTitle = bookTitle;
      this.chapterTitle = chapterTitle;
      notifyListeners();
      return;
    }
    final previous = _session;
    final previousRelease = _releaseResources;
    _session = session;
    _releaseResources = releaseResources;
    this.bookTitle = bookTitle;
    this.chapterTitle = chapterTitle;
    this.bookId = bookId;
    this.chapterId = chapterId;
    this.volumeId = volumeId;
    session.addListener(_onSession);
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

  void _onSession() {
    final session = _session;
    if (session == null || _stopFuture != null) return;
    if (session.isStopped) {
      final release = _releaseResources;
      _session = null;
      _releaseResources = null;
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
