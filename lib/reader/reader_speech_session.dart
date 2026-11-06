import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'reader_language_segments.dart';
import 'reader_tts_core.dart';

/// Provider-neutral voice configuration; keys are part of the cache identity.
class SpeechSynthesisConfig {
  const SpeechSynthesisConfig(
      {required this.source,
      required this.voice,
      required this.language,
      required this.rate,
      this.options = const {},
      this.fileExtension});
  final String source;

  /// Explicitly override decoder extension; defaults follow source conventions.
  final String? fileExtension;
  String get normalizedFileExtension {
    final value = (fileExtension ?? (source == 'system' ? 'wav' : 'mp3'))
        .toLowerCase()
        .replaceFirst(RegExp(r'^\.'), '');
    if (!RegExp(r'^[a-z0-9]{1,8}$').hasMatch(value)) {
      throw ArgumentError.value(fileExtension, 'fileExtension');
    }
    return value;
  }

  final String voice;
  final String language;
  final double rate;
  final Map<String, Object?> options;
}

abstract interface class SpeechAudioSynthesizer {
  Future<File> synthesize(
      String text, SpeechSynthesisConfig config, String cachePath);
}

/// Adapter seam for the platform SystemTts.synthesizeToFile implementation.
class SystemTtsFileSynthesizer implements SpeechAudioSynthesizer {
  SystemTtsFileSynthesizer(this.synthesizeToFile);
  final Future<File> Function(
          String text, SpeechSynthesisConfig config, String cachePath)
      synthesizeToFile;
  @override
  Future<File> synthesize(
          String text, SpeechSynthesisConfig config, String cachePath) =>
      synthesizeToFile(text, config, cachePath);
}

abstract interface class SpeechFilesHandler {
  Future<void> playFiles(List<File> files,
      {required String title,
      String? artist,
      required int startIndex,
      required FutureOr<void> Function(int) onSegmentChanged,
      required FutureOr<void> Function() onCompleted});
  Future<void> pause();
  Future<void> stop();
  Future<void> skipToNext();
  Future<void> skipToPrevious();
}

class SpeechAudioCache {
  SpeechAudioCache(
      {Future<Directory> Function()? temporaryDirectory,
      this.budgetBytes = 128 * 1024 * 1024})
      : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;
  final Future<Directory> Function() _temporaryDirectory;
  final int budgetBytes;
  Future<Directory>? _rootFuture;
  Future<Directory> _root() =>
      _rootFuture ??= _temporaryDirectory().then((d) async {
        final dir = Directory('${d.path}/reader_speech_cache_v2');
        await dir.create(recursive: true);
        return dir;
      });

  String cachePath(String account, String text, SpeechSynthesisConfig config) {
    final accountKey = _hash(account);
    final identity = jsonEncode([
      config.source,
      config.voice,
      config.language,
      config.rate,
      config.options,
      config.normalizedFileExtension,
      text
    ]);
    final name = _hash(identity);
    return 'reader-cache:$accountKey/$name.${config.normalizedFileExtension}';
  }

  Future<File?> get(
      String account, String text, SpeechSynthesisConfig config) async {
    final path = cachePath(account, text, config);
    final file = File(
        '${(await _root()).path}/${path.substring('reader-cache:'.length)}');
    if (!await file.exists()) return null;
    await file.setLastModified(DateTime.now());
    return file;
  }

  Future<File> put(String account, String text, SpeechSynthesisConfig config,
      Future<File> Function(String path) build) async {
    final path = cachePath(account, text, config);
    final root = await _root();
    final relative = path.substring('reader-cache:'.length);
    final target = File('${root.path}/$relative');
    await target.parent.create(recursive: true);
    if (await target.exists()) {
      await target.setLastModified(DateTime.now());
      return target;
    }
    final baseName = relative.split('/').last.split('.').first;
    final temp = File(
        '${target.parent.path}/$baseName.${DateTime.now().microsecondsSinceEpoch}.tmp.${config.normalizedFileExtension}');
    try {
      final generated = await build(temp.path);
      if (generated.path != temp.path) {
        await generated.copy(temp.path);
      }
      if (!await temp.exists()) {
        throw StateError('Synthesizer did not create cache file');
      }
      await temp.rename(target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    await _evict(root);
    return target;
  }

  Future<void> clear(String account) async {
    final root = await _root();
    final dir = Directory('${root.path}/${_hash(account)}');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> _evict(Directory root) async {
    final files = <File>[];
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is File && !e.path.endsWith('.tmp')) files.add(e);
    }
    final records = <(File, int, DateTime)>[];
    var total = 0;
    for (final file in files) {
      final s = await file.stat();
      total += s.size;
      records.add((file, s.size, s.modified));
    }
    records.sort((a, b) => a.$3.compareTo(b.$3));
    for (final item in records) {
      if (total <= budgetBytes) break;
      if (await item.$1.exists()) await item.$1.delete();
      total -= item.$2;
    }
  }

  static String _hash(String value) {
    // Stable FNV-1a 64-bit identity hash; no external package or network.
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

class ReaderSpeechSession extends ChangeNotifier {
  ReaderSpeechSession(
      {required this.handler,
      required this.synthesizer,
      SpeechAudioCache? cache,
      this.prefetchCount = 2})
      : cache = cache ?? SpeechAudioCache() {
    if (prefetchCount < 0) throw ArgumentError.value(prefetchCount);
  }
  final SpeechFilesHandler handler;
  final SpeechAudioSynthesizer synthesizer;
  final SpeechAudioCache cache;
  final int prefetchCount;
  final Map<String, Future<File>> _pendingFiles = {};
  List<TtsSegment> _segments = const [];
  String _account = '';
  SpeechSynthesisConfig? _config;
  String _title = '朗读';
  String? _artist;
  int _generation = 0;
  int _position = 0;
  int _utterance = 0;
  int? _pendingAdvance;
  int _internalControls = 0;
  Duration _gap = Duration.zero;
  Timer? _gapTimer;
  Timer? _sleepTimer;
  PlaybackSleepTimer _sleepMode = PlaybackSleepTimer.none;
  bool _paused = false;
  bool _stopped = true;
  bool _completed = false;
  bool _loading = false;
  bool _disposed = false;
  String? _error;

  int get position => _position;
  int get segmentCount => _segments.length;
  TtsSegment? get currentSegment =>
      _position >= 0 && _position < _segments.length
          ? _segments[_position]
          : null;
  bool get isPaused => _paused;
  bool get isStopped => _stopped;
  bool get isLoading => _loading;
  bool get isPlaying => !_paused && !_stopped && !_loading;
  bool get isCompleted => _completed;
  String? get error => _error;
  PlaybackSleepTimer get sleepTimer => _sleepMode;
  Duration get segmentInterval => _gap;

  bool _valid(int generation) =>
      !_disposed && !_stopped && generation == _generation;
  void _ensureAlive() {
    if (_disposed) throw StateError('ReaderSpeechSession disposed');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // Do not bounce our own pause/stop acknowledgements back through the handler.
  Future<void> _control(Future<void> Function() operation) async {
    _internalControls++;
    try {
      await operation();
    } finally {
      _internalControls--;
    }
  }

  Future<void> start(
    Iterable<TtsSegment> segments, {
    required String accountId,
    required SpeechSynthesisConfig config,
    int startAt = 0,
    ReaderLanguageFilter languageFilter = ReaderLanguageFilter.automatic,
    Iterable<ReaderLanguageBlock> languageMetadata = const [],
    Map<int, String> localeByBlock = const {},
    required String title,
    String? artist,
  }) async {
    _ensureAlive();
    final filtered = const ReaderLanguageSegments().filter(segments,
        filter: languageFilter,
        metadata: languageMetadata,
        localeByBlock: localeByBlock);
    if (filtered.isNotEmpty && (startAt < 0 || startAt >= filtered.length)) {
      throw RangeError.index(startAt, filtered);
    }
    final generation = ++_generation;
    ++_utterance;
    _gapTimer?.cancel();
    _pendingAdvance = null;
    _segments = filtered;
    _config = config;
    _account = accountId;
    _title = title;
    _artist = artist;
    _position = startAt;
    _paused = false;
    _completed = false;
    _error = null;
    _stopped = filtered.isEmpty;
    _loading = !_stopped;
    _notify();
    try {
      await _control(handler.stop);
      if (!_valid(generation)) return;
      await _loadAndPlay(startAt, generation);
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<File> _fileFor(
      TtsSegment segment, String account, SpeechSynthesisConfig config) async {
    final key = cache.cachePath(account, segment.text, config);
    final pending = _pendingFiles[key];
    if (pending != null) return pending;
    final future = () async {
      final existing = await cache.get(account, segment.text, config);
      return existing ??
          await cache.put(account, segment.text, config,
              (path) => synthesizer.synthesize(segment.text, config, path));
    }();
    _pendingFiles[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingFiles[key], future)) _pendingFiles.remove(key);
    }
  }

  Future<void> _loadAndPlay(int index, int generation) async {
    final config = _config!;
    final account = _account;
    final segment = _segments[index];
    final file = await _fileFor(segment, account, config);
    if (!_valid(generation) || _paused) return;
    final utterance = ++_utterance;
    await handler.playFiles([file],
        title: _title,
        artist: _artist,
        startIndex: 0,
        onSegmentChanged: (_) {
          if (_valid(generation) && !_paused) {
            _position = index;
            _loading = false;
            _notify();
          }
        },
        onCompleted: () => _onCompleted(index, generation, utterance));
    if (!_valid(generation) || _paused) return;
    _loading = false;
    _notify();
    unawaited(_prefetch(generation, index + 1, account, config));
  }

  Future<void> _prefetch(int generation, int from, String account,
      SpeechSynthesisConfig config) async {
    final segments = _segments;
    final end = (from + prefetchCount).clamp(0, segments.length);
    final futures = <Future<void>>[];
    for (var index = from; index < end && _valid(generation); index++) {
      futures.add(() async {
        try {
          await _fileFor(segments[index], account, config);
        } catch (_) {}
      }());
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
  }

  Future<void> _onCompleted(int index, int generation, int utterance) async {
    if (!_valid(generation) || utterance != _utterance || index != _position) {
      return;
    }
    ++_utterance; // reject duplicate completion before notifying listeners
    _loading = false;
    if (index + 1 >= _segments.length) {
      _stopped = true;
      _paused = false;
      _completed = true;
      _sleepTimer?.cancel();
      _sleepMode = PlaybackSleepTimer.none;
      _notify();
      return;
    }
    _pendingAdvance = index + 1;
    if (_paused) {
      return;
    }
    if (_gap == Duration.zero) {
      await seek(index + 1);
    } else {
      _gapTimer?.cancel();
      _gapTimer = Timer(_gap, () {
        if (_valid(generation) && !_paused && _pendingAdvance != null) {
          unawaited(seek(_pendingAdvance!));
        }
      });
      _notify();
    }
  }

  Future<void> seek(int index) async {
    _ensureAlive();
    if (index < 0 || index >= _segments.length) {
      throw RangeError.index(index, _segments);
    }
    if (_config == null) return;
    final generation = ++_generation;
    ++_utterance;
    _gapTimer?.cancel();
    _pendingAdvance = null;
    _position = index;
    _error = null;
    _completed = false;
    _stopped = false;
    _loading = !_paused;
    _notify();
    try {
      await _control(
          handler.pause); // silence old audio before awaiting synthesis
      if (!_valid(generation) || _paused) return;
      await _loadAndPlay(index, generation);
    } catch (error) {
      _fail(error, generation);
    }
  }

  Future<void> updateConfig(SpeechSynthesisConfig config) async {
    _ensureAlive();
    _config = config;
    _error = null;
    if (_stopped || _segments.isEmpty) {
      return;
    }
    await seek(
        _position); // cache identity includes voice, locale, rate, options
  }

  Future<void> next() async {
    _ensureAlive();
    if (_position + 1 < _segments.length) {
      await seek(_position + 1);
    }
  }

  Future<void> previous() async {
    _ensureAlive();
    if (_position > 0) {
      await seek(_position - 1);
    }
  }

  Future<void> onHandlerNext() => next();
  Future<void> onHandlerPrevious() => previous();
  Future<void> onHandlerPlay() async {
    if (_internalControls == 0 && !_disposed && _paused) await resume();
  }

  void onHandlerPaused() {
    if (_internalControls != 0 || _disposed || _stopped) return;
    ++_generation;
    ++_utterance;
    _paused = true;
    _loading = false;
    _gapTimer?.cancel();
    _notify();
  }

  void onHandlerStopped() {
    if (_internalControls != 0 || _disposed) return;
    _markStopped();
    _notify();
  }

  Future<void> pause() async {
    _ensureAlive();
    if (_paused || _stopped) return;
    onHandlerPaused();
    await _control(handler.pause);
  }

  Future<void> resume() async {
    _ensureAlive();
    if (!_paused || _stopped || _config == null) return;
    _paused = false;
    final target = _pendingAdvance ?? _position;
    await seek(target);
  }

  void _markStopped() {
    ++_generation;
    ++_utterance;
    _gapTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepMode = PlaybackSleepTimer.none;
    _stopped = true;
    _paused = false;
    _loading = false;
    _completed = false;
    _pendingAdvance = null;
  }

  Future<void> stop() async {
    _ensureAlive();
    _markStopped();
    await _control(handler.stop);
    _notify();
  }

  void reportPlaybackError(Object error) => _fail(error, _generation);

  void _fail(Object error, int generation) {
    if (!_valid(generation)) return;
    _error = error.toString();
    _stopped = true;
    _paused = false;
    _loading = false;
    _gapTimer?.cancel();
    _sleepTimer?.cancel();
    _notify();
  }

  void setSegmentInterval(Duration interval) {
    _ensureAlive();
    if (interval.isNegative) throw ArgumentError.value(interval);
    _gap = interval;
  }

  void setSleepTimer(PlaybackSleepTimer mode) {
    _ensureAlive();
    _sleepTimer?.cancel();
    _sleepMode = mode;
    final minutes = switch (mode) {
      PlaybackSleepTimer.minutes15 => 15,
      PlaybackSleepTimer.minutes30 => 30,
      PlaybackSleepTimer.minutes60 => 60,
      _ => 0,
    };
    if (minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: minutes), () {
        _sleepMode = PlaybackSleepTimer.none;
        if (!_disposed) unawaited(pause());
      });
    }
    _notify();
  }

  Future<void> clearAccount(String accountId) => cache.clear(accountId);
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    ++_utterance;
    _gapTimer?.cancel();
    _sleepTimer?.cancel();
    super.dispose();
  }
}
