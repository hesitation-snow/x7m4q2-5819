import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';

import '../reader/reader_speech_session.dart' show SpeechFilesHandler;

/// Shared application media session, initialized once from main.dart.
ReaderAudioHandler? activeReaderAudioHandler;

/// Callbacks owned by the active TTS controller for Android media controls.
class TtsMediaCallbacks {
  const TtsMediaCallbacks({
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    required this.onPrevious,
    required this.onNext,
    this.onError,
  });

  final FutureOr<void> Function() onPlay;
  final FutureOr<void> Function() onPause;
  final FutureOr<void> Function() onStop;
  final FutureOr<void> Function() onPrevious;
  final FutureOr<void> Function() onNext;
  final void Function(Object error)? onError;
}

/// Audio service bridge for Yomiru's reader/TTS pipeline.
///
/// Create once with `AudioService.init<ReaderAudioHandler>(
/// builder: () => ReaderAudioHandler(), config: const AudioServiceConfig(...))`.
/// Call [playBytes] for each synthesized in-memory MP3/WAV segment and use
/// [updateSpeechStatus] to keep OS media surfaces in sync with TTS progress.
class ReaderAudioHandler extends BaseAudioHandler
    implements SpeechFilesHandler {
  ReaderAudioHandler({
    ReaderAudioPlayer? player,
    Future<Directory> Function()? temporaryDirectory,
    @visibleForTesting bool configureAudioSession = true,
  })  : _player = player ?? JustAudioReaderPlayer(ja.AudioPlayer()),
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
        _configureSession = configureAudioSession {
    _subscriptions.addAll([
      _player.playingStream.listen((_) => _publishState()),
      _player.processingStateStream.listen(_onProcessingState),
      _player.positionStream.listen((_) => _publishState()),
      _player.bufferedPositionStream.listen((_) => _publishState()),
      _player.durationStream.listen((duration) {
        _playerDuration = duration;
        if (!_disposed && !_externalTtsActive) {
          final current = mediaItem.valueOrNull;
          if (current != null) {
            mediaItem.add(current.copyWith(duration: duration));
          }
        }
        _publishState();
      }),
      _player.currentIndexStream.listen(_onCurrentIndex),
    ]);
  }

  final ReaderAudioPlayer _player;
  final Future<Directory> Function() _temporaryDirectory;
  final bool _configureSession;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<File> _files = const [];
  List<MediaItem> _items = const [];
  bool _disposed = false;
  int _sourceGeneration = 0;
  int _controlRevision = 0;
  bool _loadingSource = false;
  File? _previewFile;
  bool _completionSent = false;
  int? _lastIndex;
  String _title = 'Yomiru';
  String? _author;
  String? _segment;
  String _status = '停止';
  Duration _reportedPosition = Duration.zero;
  Duration? _reportedDuration;
  Duration? _playerDuration;
  Object? _ttsOwnerKey;
  FutureOr<void> Function(int index)? _onSegmentChanged;
  FutureOr<void> Function()? _onQueueCompleted;
  TtsMediaCallbacks? _ttsOwnerCallbacks;
  Object? _speechSessionOwnerKey;
  TtsMediaCallbacks? _speechSessionCallbacks;
  double _playbackRate = 1;

  /// Assign the external TTS media controls to one owner. A later bind takes
  /// ownership; callbacks from the previous owner are never retained.
  void bindTtsOwner(
      {required Object ownerKey, required TtsMediaCallbacks callbacks}) {
    _ensureAlive();
    _ttsOwnerKey = ownerKey;
    _ttsOwnerCallbacks = callbacks;
    _speechSessionOwnerKey = null;
    _speechSessionCallbacks = null;
    unawaited(_activateSession());
    _publishState();
  }

  /// A reader/page owner should call this from its own dispose path. It only
  /// detaches that owner and never disposes the application-wide handler.
  bool disposeTtsOwner(Object ownerKey) => unbindTtsOwner(ownerKey);

  bool _acceptsOwnerUpdate(Object? ownerKey) =>
      ownerKey == null ? _ttsOwnerKey == null : ownerKey == _ttsOwnerKey;

  bool get _externalTtsActive => _ttsOwnerKey != null;

  bool get _externalTtsPlaying {
    final normalized = _status.toLowerCase();
    return normalized.contains('播放中') ||
        normalized == 'playing' ||
        normalized.contains('正在播放');
  }

  AudioProcessingState get _externalTtsProcessingState {
    final normalized = _status.toLowerCase();
    if (normalized.contains('停止') ||
        normalized == 'stopped' ||
        normalized == 'idle') {
      return AudioProcessingState.idle;
    }
    if (normalized == 'completed' || normalized.contains('完成')) {
      return AudioProcessingState.completed;
    }
    if (normalized == 'error' || normalized.contains('失败')) {
      return AudioProcessingState.error;
    }
    if (normalized.contains('合成') ||
        normalized.contains('加载') ||
        normalized.contains('准备') ||
        normalized.contains('buffer') ||
        normalized == 'loading') {
      return AudioProcessingState.loading;
    }
    return AudioProcessingState.ready;
  }

  /// Release ownership only when [ownerKey] still owns the media controls.
  bool unbindTtsOwner(Object ownerKey) {
    if (_ttsOwnerKey != ownerKey) return false;
    _ttsOwnerKey = null;
    _ttsOwnerCallbacks = null;
    mediaItem.add(null);
    queue.add(const []);
    queueTitle.add('');
    _publishState(
        processingState: AudioProcessingState.idle, position: Duration.zero);
    unawaited(_deactivateSession());
    return true;
  }

  /// Synonyms matching bind/unbind terminology used by reader controllers.
  void bindOwner(
          {required Object ownerKey, required TtsMediaCallbacks callbacks}) =>
      bindTtsOwner(ownerKey: ownerKey, callbacks: callbacks);
  bool unbindOwner(Object ownerKey) => unbindTtsOwner(ownerKey);

  void bindSpeechSessionControls({
    required Object ownerKey,
    required TtsMediaCallbacks callbacks,
  }) {
    _ensureAlive();
    _speechSessionOwnerKey = ownerKey;
    _speechSessionCallbacks = callbacks;
  }

  bool unbindSpeechSessionControls(Object ownerKey) {
    if (_speechSessionOwnerKey != ownerKey) return false;
    _speechSessionOwnerKey = null;
    _speechSessionCallbacks = null;
    return true;
  }

  Object? get ttsOwnerKey => _ttsOwnerKey;
  Object? get speechSessionOwnerKey => _speechSessionOwnerKey;

  /// Player speed for already synthesized audio. Does not change cache identity.
  Future<void> setPlaybackRate(double rate) async {
    _ensureAlive();
    _playbackRate = rate.clamp(0.5, 3.0);
    await _player.setSpeed(_playbackRate);
    _publishState();
  }

  @override
  Future<void> playFiles(
    List<File> files, {
    required String title,
    String? artist,
    required int startIndex,
    required FutureOr<void> Function(int index) onSegmentChanged,
    required FutureOr<void> Function() onCompleted,
  }) async {
    _ensureAlive();
    final generation = ++_sourceGeneration;
    final controlRevision = ++_controlRevision;
    _loadingSource = true;
    if (files.isEmpty) throw ArgumentError.value(files, 'files');
    if (startIndex < 0 || startIndex >= files.length) {
      throw RangeError.index(startIndex, files);
    }
    for (final file in files) {
      if (!await file.exists()) {
        throw ArgumentError.value(file.path, 'files', 'Audio file is missing');
      }
    }
    if (_disposed || generation != _sourceGeneration) return;
    _ttsOwnerKey = null;
    _ttsOwnerCallbacks = null;
    _reportedPosition = Duration.zero;
    _files = List<File>.unmodifiable(files);
    _items = List<MediaItem>.generate(
      files.length,
      (index) => MediaItem(
        id: files[index].absolute.path,
        title:
            files.length == 1 ? title : '$title (${index + 1}/${files.length})',
        artist: artist,
        album: title,
        playable: true,
        extras: <String, Object?>{'segmentIndex': index},
      ),
      growable: false,
    );
    _title = title;
    _author = artist;
    _segment = '$startIndex';
    _onSegmentChanged = onSegmentChanged;
    _onQueueCompleted = onCompleted;
    _completionSent = false;
    _lastIndex = startIndex;
    queue.add(_items);
    queueTitle.add(title);
    mediaItem.add(_items[startIndex]);
    try {
      await _activateSession();
      if (_disposed || generation != _sourceGeneration) return;
      await _player.setFiles(_files, initialIndex: startIndex);
      if (_disposed || generation != _sourceGeneration) return;
      await _player.setSpeed(_playbackRate);
      _loadingSource = false;
      _completionSent = false;
      final current = mediaItem.valueOrNull;
      if (current != null) {
        mediaItem.add(current.copyWith(duration: _playerDuration));
      }
      await onSegmentChanged(startIndex);
      if (_disposed ||
          generation != _sourceGeneration ||
          controlRevision != _controlRevision) {
        return;
      }
      await play();
    } catch (error) {
      if (!_disposed && generation == _sourceGeneration) {
        _loadingSource = false;
        rethrow;
      }
    }
  }

  /// Play an in-memory MP3 preview while retaining this shared handler's
  /// lifecycle ownership. The preview adapter must never dispose this handler.
  Future<void> playMp3(Uint8List bytes,
          {String title = '试听', String? author}) =>
      playBytes(bytes, title: title, author: author, contentType: 'audio/mpeg');

  Future<void> publishTtsState({
    Object? ownerKey,
    String? title,
    String? author,
    String? segment,
    required String status,
    Duration? position,
    Duration? duration,
  }) async {
    if (!_acceptsOwnerUpdate(ownerKey)) return;
    updateSpeechStatus(
        ownerKey: ownerKey,
        title: title,
        author: author,
        segment: segment,
        status: status,
        position: position,
        duration: duration);
  }

  Future<void> _invokeOwner(FutureOr<void> Function()? callback) async {
    if (callback != null) await callback();
  }

  Future<void> _invokeOwnerStopOrLocalStop() async {
    final callback =
        _ttsOwnerCallbacks?.onStop ?? _speechSessionCallbacks?.onStop;
    if (callback != null) await callback();
    await _stopLocalPlayer();
  }

  Future<void> _stopLocalPlayer() async {
    await _player.stop();
    _status = '已停止';
    _reportedPosition = Duration.zero;
    _publishState(
        processingState: AudioProcessingState.idle, position: Duration.zero);
    await _deactivateSession();
  }

  void _publishTtsItem() {
    final old = mediaItem.valueOrNull;
    final extras = <String, Object?>{'segment': _segment, 'status': _status};
    if (_reportedDuration != null) {
      extras['durationMs'] = _reportedDuration!.inMilliseconds;
    }
    mediaItem.add(MediaItem(
      id: old?.id ?? 'yomiru:tts',
      title: _segment == null || _segment!.isEmpty
          ? _title
          : '$_title · $_segment',
      artist: _author,
      album: _title,
      playable: old?.playable ?? true,
      extras: extras,
    ));
  }

  Future<void> _activateSession() async {
    if (!_configureSession) return;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    await session.setActive(true);
  }

  Future<void> _deactivateSession() async {
    if (!_configureSession) return;
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {
      // Best-effort during teardown.
    }
  }

  /// Load and start playback from in-memory encoded MP3 or WAV bytes.
  /// `contentType` defaults to MP3; specify `audio/wav` for WAV data.
  Future<void> playBytes(
    Uint8List bytes, {
    required String title,
    String? author,
    String? segment,
    String contentType = 'audio/mpeg',
    String? id,
    bool autoplay = true,
  }) async {
    _ensureAlive();
    final generation = ++_sourceGeneration;
    final controlRevision = ++_controlRevision;
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'Must not be empty');
    }
    final mime = _normalizeMime(contentType);
    if (mime != 'audio/mpeg' && mime != 'audio/wav' && mime != 'audio/x-wav') {
      throw ArgumentError.value(
          contentType, 'contentType', 'Use audio/mpeg or audio/wav');
    }
    _ttsOwnerKey = null;
    _ttsOwnerCallbacks = null;
    _speechSessionOwnerKey = null;
    _speechSessionCallbacks = null;
    _files = const [];
    _items = const [];
    _onSegmentChanged = null;
    _onQueueCompleted = null;
    _completionSent = false;
    _title = title;
    _author = author;
    _segment = segment;
    _reportedPosition = Duration.zero;
    _status = autoplay ? '准备播放' : '已就绪';
    final item = MediaItem(
      id: id ?? 'memory:${DateTime.now().microsecondsSinceEpoch}',
      title: segment == null || segment.isEmpty ? title : '$title · $segment',
      artist: author,
      album: title,
      playable: true,
      artUri: null,
      extras: <String, Object?>{'segment': segment, 'contentType': mime},
    );
    mediaItem.add(item);
    queue.add(<MediaItem>[item]);
    queueTitle.add(title);
    _loadingSource = true;
    final directory = await _temporaryDirectory();
    if (_disposed || generation != _sourceGeneration) return;
    await directory.create(recursive: true);
    final extension = mime == 'audio/mpeg' ? 'mp3' : 'wav';
    final file = File(
        '${directory.path}/yomiru-preview-${DateTime.now().microsecondsSinceEpoch}-$generation.$extension');
    await file.writeAsBytes(bytes, flush: true);
    if (_disposed || generation != _sourceGeneration) {
      await file.delete();
      return;
    }
    final previous = _previewFile;
    _previewFile = file;
    try {
      await _activateSession();
      if (_disposed || generation != _sourceGeneration) return;
      await _player.setSource(ja.AudioSource.file(file.path));
      if (_disposed || generation != _sourceGeneration) return;
      _loadingSource = false;
      _status = '已就绪';
      _publishState(processingState: AudioProcessingState.ready);
      if (autoplay && controlRevision == _controlRevision) await play();
    } finally {
      if (previous != null && await previous.exists()) await previous.delete();
      if (_disposed || generation != _sourceGeneration) {
        if (await file.exists()) await file.delete();
      }
    }
  }

  /// Publish the reader/TTS's semantic progress independently of player events.
  /// Useful for announcing the current text segment and synthesis lifecycle.
  void updateSpeechStatus({
    Object? ownerKey,
    String? title,
    String? author,
    String? segment,
    required String status,
    Duration? position,
    Duration? duration,
  }) {
    if (_disposed || !_acceptsOwnerUpdate(ownerKey)) return;
    final changedItem = (title != null && title != _title) ||
        (author != null && author != _author) ||
        (segment != null && segment != _segment);
    if (title != null) _title = title;
    if (author != null) _author = author;
    if (segment != null) _segment = segment;
    _status = status;
    if (position != null) _reportedPosition = position;
    if (duration != null) _reportedDuration = duration;
    if (changedItem || duration != null || mediaItem.valueOrNull == null) {
      _publishTtsItem();
    } else {
      final current = mediaItem.valueOrNull!;
      mediaItem.add(current.copyWith(extras: <String, Object?>{
        ...?current.extras,
        'segment': _segment,
        'status': _status,
        if (_reportedDuration != null)
          'durationMs': _reportedDuration!.inMilliseconds,
      }));
    }
    _publishState();
  }

  String get speechStatus => _status;

  @override
  Future<void> play() async {
    _ensureAlive();
    final ownerCallback = _ttsOwnerCallbacks?.onPlay;
    if (ownerCallback != null) {
      await _invokeOwner(ownerCallback);
      _status = '播放中';
      _publishState(processingState: AudioProcessingState.ready);
      return;
    }
    final generation = _sourceGeneration;
    final revision = _controlRevision;
    // A paused synthesis/gap must resume through the session first. It may
    // replace the audio source; never then play the old completed source.
    await _speechSessionCallbacks?.onPlay();
    if (_disposed ||
        generation != _sourceGeneration ||
        revision != _controlRevision) {
      return;
    }
    await _activateSession();
    if (_disposed ||
        generation != _sourceGeneration ||
        revision != _controlRevision) {
      return;
    }
    unawaited(_player.play().catchError((Object error) {
      if (!_disposed &&
          generation == _sourceGeneration &&
          revision == _controlRevision) {
        _status = '播放失败';
        _speechSessionCallbacks?.onError?.call(error);
        _publishState(processingState: AudioProcessingState.error);
      }
    }));
    _status = '播放中';
    _publishState();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    ++_controlRevision;
    final ownerCallback = _ttsOwnerCallbacks?.onPause;
    if (ownerCallback != null) {
      await _invokeOwner(ownerCallback);
      _status = '已暂停';
      _publishState(processingState: AudioProcessingState.ready);
      return;
    }
    await _player.pause();
    await _speechSessionCallbacks?.onPause();
    _status = '已暂停';
    _publishState();
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    ++_sourceGeneration;
    ++_controlRevision;
    _loadingSource = false;
    _completionSent = true;
    _onQueueCompleted = null;
    await _invokeOwnerStopOrLocalStop();
    final preview = _previewFile;
    _previewFile = null;
    if (preview != null && await preview.exists()) await preview.delete();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) return;
    await _player.seek(position);
    _reportedPosition = position;
    _publishState();
  }

  @override
  Future<void> skipToNext() async {
    if (_disposed) return;
    final callback = _ttsOwnerCallbacks?.onNext ??
        _speechSessionCallbacks?.onNext ??
        onNextSegment;
    if (callback != null) {
      await callback();
    } else {
      await _player.seekToNext();
    }
  }

  /// Optional owner callback invoked by headset/notification next controls.
  FutureOr<void> Function()? onNextSegment;

  /// Optional owner callback invoked by headset/notification previous controls.
  FutureOr<void> Function()? onPreviousSegment;

  @override
  Future<void> skipToPrevious() async {
    if (_disposed) return;
    final callback = _ttsOwnerCallbacks?.onPrevious ??
        _speechSessionCallbacks?.onPrevious ??
        onPreviousSegment;
    if (callback != null) {
      await callback();
    } else if (_files.length <= 1) {
      await seek(Duration.zero);
    } else {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> onTaskRemoved() async {
    // Let the Android media foreground service outlive the reader Activity; the
    // user can still stop playback from the system media surface.
  }

  /// Cancel all event subscriptions, release player/session and close streams.
  /// Safe to call repeatedly; no callback can publish after cancellation.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(activeReaderAudioHandler, this)) {
      activeReaderAudioHandler = null;
    }
    _ttsOwnerKey = null;
    _ttsOwnerCallbacks = null;
    _speechSessionOwnerKey = null;
    _speechSessionCallbacks = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    final preview = _previewFile;
    _previewFile = null;
    if (preview != null && await preview.exists()) await preview.delete();
    await _deactivateSession();
    await playbackState.close();
    await queue.close();
    await queueTitle.close();
    await mediaItem.close();
  }

  void _onCurrentIndex(int? index) {
    if (_disposed || index == null || index < 0 || index >= _items.length) {
      return;
    }
    if (_lastIndex == index) return;
    _lastIndex = index;
    mediaItem.add(_items[index]);
    _segment = '${index + 1}/${_items.length}';
    _publishState(index: index);
    final callback = _onSegmentChanged;
    if (callback != null) unawaited(Future<void>.sync(() => callback(index)));
  }

  void _onProcessingState(ja.ProcessingState state) {
    _publishState();
    if (!_loadingSource &&
        state == ja.ProcessingState.completed &&
        !_completionSent) {
      _completionSent = true;
      final callback = _onQueueCompleted;
      if (callback != null) {
        unawaited(Future<void>.sync(callback).catchError((Object error) {
          _speechSessionCallbacks?.onError?.call(error);
        }));
      }
      // The callback can immediately load the next segment. Deactivating audio
      // focus here races with that new activation and interrupts playback.
    }
  }

  void _publishState(
      {AudioProcessingState? processingState, Duration? position, int? index}) {
    if (_disposed) return;
    final externalTts = _externalTtsActive;
    final currentPosition =
        position ?? (externalTts ? _reportedPosition : _player.position);
    final effectivePosition = currentPosition > _reportedPosition
        ? currentPosition
        : _reportedPosition;
    final processing = processingState ??
        (externalTts
            ? _externalTtsProcessingState
            : switch (_player.processingState) {
                ja.ProcessingState.idle => AudioProcessingState.idle,
                ja.ProcessingState.loading => AudioProcessingState.loading,
                ja.ProcessingState.buffering => AudioProcessingState.buffering,
                ja.ProcessingState.ready => AudioProcessingState.ready,
                ja.ProcessingState.completed => AudioProcessingState.completed,
              });
    final playing = externalTts
        ? _externalTtsPlaying
        : _player.playing &&
            processing != AudioProcessingState.completed &&
            processing != AudioProcessingState.idle &&
            processing != AudioProcessingState.error;
    playbackState.add(PlaybackState(
      processingState: processing,
      playing: playing,
      controls: <MediaControl>[
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToPrevious,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      systemActions: const {MediaAction.seek},
      updatePosition: effectivePosition,
      bufferedPosition: _player.bufferedPosition,
      speed: _playbackRate,
      queueIndex: index ?? _player.currentIndex,
      captioningEnabled: false,
      repeatMode: AudioServiceRepeatMode.none,
    ));
  }

  void _ensureAlive() {
    if (_disposed) throw StateError('ReaderAudioHandler has been disposed');
  }

  static String _normalizeMime(String value) =>
      value.toLowerCase().split(';').first.trim();
}

/// A just_audio stream source serving immutable in-memory encoded audio bytes.
// just_audio marks StreamAudioSource as experimental; it is required for byte-backed audio.
// ignore: experimental_member_use
class MemoryAudioSource extends ja.StreamAudioSource {
  MemoryAudioSource(
    Uint8List bytes, {
    required this.contentType,
    String? sourceId,
  })  : _bytes = Uint8List.fromList(bytes),
        super(tag: sourceId);

  final Uint8List _bytes;
  final String contentType;

  // ignore: experimental_member_use
  @override
  // ignore: experimental_member_use
  Future<ja.StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = end ?? _bytes.length;
    if (from < 0 || to < from || to > _bytes.length) {
      throw RangeError(
          'Invalid byte range [$from, $to) for ${_bytes.length} bytes');
    }
    // ignore: experimental_member_use
    return ja.StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream<List<int>>.value(_bytes.sublist(from, to)),
      contentType: contentType,
    );
  }
}

/// Injectable minimal player seam for native-channel-free unit tests.
abstract interface class ReaderAudioPlayer {
  Stream<bool> get playingStream;
  Stream<ja.ProcessingState> get processingStateStream;
  Stream<Duration> get positionStream;
  Stream<Duration> get bufferedPositionStream;
  Stream<Duration?> get durationStream;
  bool get playing;
  ja.ProcessingState get processingState;
  Duration get position;
  Duration get bufferedPosition;
  int? get currentIndex;
  Stream<int?> get currentIndexStream;
  Future<void> setSource(ja.AudioSource source);
  Future<void> setFiles(List<File> files, {required int initialIndex});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> seekToNext();
  Future<void> seekToPrevious();
  Future<void> seekToIndex(int index);
  Future<void> dispose();
}

class JustAudioReaderPlayer implements ReaderAudioPlayer {
  JustAudioReaderPlayer(this.player);
  final ja.AudioPlayer player;

  @override
  Stream<bool> get playingStream => player.playingStream;
  @override
  Stream<ja.ProcessingState> get processingStateStream =>
      player.processingStateStream;
  @override
  Stream<Duration> get positionStream => player.positionStream;
  @override
  Stream<Duration> get bufferedPositionStream => player.bufferedPositionStream;
  @override
  Stream<Duration?> get durationStream => player.durationStream;
  @override
  bool get playing => player.playing;
  @override
  ja.ProcessingState get processingState => player.processingState;
  @override
  Duration get position => player.position;
  @override
  Duration get bufferedPosition => player.bufferedPosition;
  @override
  int? get currentIndex => player.currentIndex;
  @override
  Stream<int?> get currentIndexStream => player.currentIndexStream;
  @override
  Future<void> setSource(ja.AudioSource source) =>
      player.setAudioSource(source);
  @override
  Future<void> setFiles(List<File> files, {required int initialIndex}) =>
      player.setAudioSources(
        files.map((file) => ja.AudioSource.file(file.path)).toList(),
        initialIndex: initialIndex,
      );
  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> stop() => player.stop();
  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> setSpeed(double speed) => player.setSpeed(speed);
  @override
  Future<void> seekToNext() => player.seekToNext();
  @override
  Future<void> seekToPrevious() => player.seekToPrevious();
  @override
  Future<void> seekToIndex(int index) =>
      player.seek(Duration.zero, index: index);
  @override
  Future<void> dispose() => player.dispose();
}
