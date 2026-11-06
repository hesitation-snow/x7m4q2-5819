import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../reader/reader_tts_core.dart';

/// An installed Android system TTS engine.
class SystemTtsEngine {
  const SystemTtsEngine({
    required this.id,
    required this.label,
    required this.isSystem,
  });

  final String id;
  final String label;
  final bool isSystem;

  factory SystemTtsEngine.fromMap(Map<dynamic, dynamic> map) => SystemTtsEngine(
        id: _stringValue(map['name'] ?? map['id']) ?? '',
        label: _stringValue(map['label'] ?? map['name']) ?? '',
        isSystem: map['isSystem'] == true,
      );
}

/// A voice exposed by the platform text-to-speech engine.
class SystemTtsVoice {
  const SystemTtsVoice({
    required this.id,
    required this.name,
    this.locale,
    this.engine,
    this.networkRequired,
  });

  final String id;
  final String name;
  final String? locale;
  final String? engine;
  final bool? networkRequired;

  factory SystemTtsVoice.fromMap(Map<dynamic, dynamic> map) {
    return SystemTtsVoice(
      id: _stringValue(map['voiceId'] ?? map['id']) ?? '',
      name: _stringValue(map['name'] ?? map['label']) ?? '',
      locale: _stringValue(map['locale']),
      engine: _stringValue(map['engine']),
      networkRequired: map['networkRequired'] is bool
          ? map['networkRequired'] as bool
          : null,
    );
  }
}

/// Position information emitted while an utterance is being spoken.
class SystemTtsProgress {
  const SystemTtsProgress({
    required this.utteranceId,
    required this.start,
    required this.end,
    this.text,
  });

  final String utteranceId;
  final int start;
  final int end;
  final String? text;

  factory SystemTtsProgress.fromMap(Map<dynamic, dynamic> map) {
    return SystemTtsProgress(
      utteranceId: _stringValue(map['utteranceId']) ?? '',
      start: _intValue(map['start'] ?? map['startIndex']) ?? 0,
      end: _intValue(map['end'] ?? map['endIndex']) ?? 0,
      text: _stringValue(map['text']),
    );
  }
}

/// Typed events emitted by the native TTS implementation.
sealed class SystemTtsEvent {
  const SystemTtsEvent(this.utteranceId);

  final String utteranceId;
}

class SystemTtsSpeechStart extends SystemTtsEvent {
  const SystemTtsSpeechStart(super.utteranceId);
}

class SystemTtsSpeechProgress extends SystemTtsEvent {
  SystemTtsSpeechProgress(this.progress) : super(progress.utteranceId);

  final SystemTtsProgress progress;
}

class SystemTtsSpeechDone extends SystemTtsEvent {
  const SystemTtsSpeechDone(super.utteranceId);
}

class SystemTtsSpeechStopped extends SystemTtsEvent {
  const SystemTtsSpeechStopped(super.utteranceId);
}

class SystemTtsSpeechError extends SystemTtsEvent {
  const SystemTtsSpeechError(super.utteranceId, this.message);

  final String message;
}

/// Friendly, platform-independent error surfaced by [SystemTts].
class SystemTtsException implements Exception {
  const SystemTtsException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// Flutter facade for the native system TTS channels.
class SystemTts {
  SystemTts({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : methodChannel = methodChannel ?? const MethodChannel(channelName),
        eventChannel = eventChannel ?? const EventChannel(eventChannelName);

  static const String channelName = 'moe.yutro.yomiru/tts';
  static const String eventChannelName = channelName;

  final MethodChannel methodChannel;
  final EventChannel eventChannel;
  final StreamController<SystemTtsEvent> _events =
      StreamController<SystemTtsEvent>.broadcast();
  bool _disposed = false;
  bool _listening = false;
  static final Map<String, SystemTts> _handlerOwners = {};

  Stream<SystemTtsEvent> get events => _events.stream;

  /// Request the Android notification permission needed to expose background
  /// media controls on Android 13+. Other platforms keep their native behavior.
  Future<bool> requestNotificationPermission() async {
    _ensureAlive();
    try {
      final result = await methodChannel
          .invokeMethod<dynamic>('requestNotificationPermission');
      return result == true;
    } on MissingPluginException {
      return true;
    } on PlatformException catch (error) {
      throw _friendlyNativeError(error.code);
    }
  }

  Future<List<SystemTtsEngine>> getEngines() async {
    _ensureAlive();
    try {
      final result = await methodChannel.invokeMethod<dynamic>('getEngines');
      if (result is! List) {
        throw const SystemTtsException('系统语音引擎列表格式无效');
      }
      return result
          .whereType<Map>()
          .map(SystemTtsEngine.fromMap)
          .where((engine) => engine.id.isNotEmpty)
          .toList(growable: false);
    } on PlatformException catch (error) {
      throw _friendlyNativeError(error.code);
    } on MissingPluginException {
      throw const SystemTtsException('当前平台暂不支持选择系统语音引擎');
    }
  }

  Future<void> setEngine(String engineId) async {
    _ensureAlive();
    if (engineId.trim().isEmpty) {
      throw const SystemTtsException('系统语音引擎 ID 为空');
    }
    try {
      final result = await methodChannel.invokeMethod<dynamic>(
          'setEngine', <String, Object?>{'id': engineId});
      if (result != true) {
        throw const SystemTtsException('切换系统语音引擎失败');
      }
    } on PlatformException catch (error) {
      throw _friendlyNativeError(error.code);
    } on MissingPluginException {
      throw const SystemTtsException('当前平台暂不支持选择系统语音引擎');
    }
  }

  Future<List<SystemTtsVoice>> getVoices() async {
    _ensureAlive();
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final result = await methodChannel.invokeMethod<dynamic>('getVoices');
        if (result == null) return const [];
        if (result is! List) {
          throw const SystemTtsException('语音列表格式无效');
        }
        return result
            .whereType<Map>()
            .map((voice) => SystemTtsVoice.fromMap(voice))
            .where((voice) => voice.id.isNotEmpty)
            .toList(growable: false);
      } on PlatformException catch (error) {
        if (error.code == 'TTS_NOT_READY' && attempt < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        throw _friendlyNativeError(error.code);
      } on MissingPluginException {
        throw const SystemTtsException('当前平台暂不支持系统语音朗读');
      }
    }
    return const [];
  }

  Future<void> speak({
    required String text,
    required String utteranceId,
    String? locale,
    String? voiceId,
    double rate = 1.0,
    bool Function()? isCurrent,
  }) async {
    _ensureAlive();
    bool current() => !_disposed && (isCurrent?.call() ?? true);
    try {
      if (locale != null) {
        final result = await methodChannel.invokeMethod<dynamic>(
            'setLanguage', <String, Object?>{'locale': locale});
        if (!current()) return;
        if (result is! Map || result['available'] != true) {
          throw const SystemTtsException('所选语言不可用', code: 'INVALID_LOCALE');
        }
      }
      if (voiceId != null) {
        final result = await methodChannel.invokeMethod<dynamic>(
            'setVoice', <String, Object?>{'id': voiceId});
        if (!current()) return;
        if (result != true) {
          throw const SystemTtsException('所选语音不可用', code: 'VOICE_NOT_FOUND');
        }
      }
      final rateResult = await methodChannel.invokeMethod<dynamic>(
          'setSpeechRate', <String, Object?>{'rate': rate});
      if (!current()) return;
      if (rateResult != true) {
        throw const SystemTtsException('语速设置无效', code: 'INVALID_RATE');
      }
      final result =
          await methodChannel.invokeMethod<dynamic>('speak', <String, Object?>{
        'text': text,
        'utteranceId': utteranceId,
      });
      if (!current()) return;
      if (result is! Map ||
          result['accepted'] != true ||
          result['utteranceId'] != utteranceId) {
        throw const SystemTtsException('语音播放失败', code: 'SPEAK_FAILED');
      }
    } on PlatformException catch (error) {
      throw _friendlyNativeError(error.code);
    } on MissingPluginException {
      throw const SystemTtsException('当前平台暂不支持系统语音朗读');
    }
  }

  static Future<void> _fileSynthesisTail = Future<void>.value();

  /// Android TextToSpeech has shared engine configuration. Serialize audible
  /// and prefetched file synthesis so one voice/rate cannot overwrite another.
  Future<String> synthesizeToFile(
    String text,
    String outputFile,
    String? locale,
    String? voiceId,
    double rate,
  ) {
    final result = _fileSynthesisTail.then(
        (_) => _synthesizeToFileOnce(text, outputFile, locale, voiceId, rate));
    _fileSynthesisTail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<String> _synthesizeToFileOnce(
    String text,
    String outputFile,
    String? locale,
    String? voiceId,
    double rate,
  ) async {
    _ensureAlive();
    final cacheDirectory = await getTemporaryDirectory();
    final cachePath = _normalizedPath(cacheDirectory.path);
    final outputPath = _normalizedPath(outputFile);
    if (outputPath == cachePath ||
        !outputPath.startsWith('$cachePath${Platform.pathSeparator}') ||
        File(outputPath).uri.pathSegments.isEmpty) {
      throw const SystemTtsException(
        '输出文件必须位于应用缓存目录中',
        code: 'INVALID_OUTPUT_PATH',
      );
    }
    try {
      final utteranceId =
          'system-tts-file-${DateTime.now().microsecondsSinceEpoch}';
      final result = await methodChannel.invokeMethod<dynamic>(
        'synthesizeToFile',
        <String, Object?>{
          'text': text,
          'filePath': outputPath,
          'locale': locale,
          'voiceId': voiceId,
          'rate': rate,
          'utteranceId': utteranceId,
        },
      ).timeout(const Duration(seconds: 45), onTimeout: () async {
        try {
          await methodChannel.invokeMethod<void>('stop');
        } catch (_) {}
        throw const SystemTtsException('系统语音合成超时，请检查语音引擎及语音包。',
            code: 'SYNTHESIS_TIMEOUT');
      });
      if (result is! Map ||
          result['completed'] != true ||
          _normalizedPath(_stringValue(result['path']) ?? '') != outputPath) {
        throw const SystemTtsException('语音文件合成失败', code: 'SYNTHESIS_FAILED');
      }
      return outputPath;
    } on PlatformException catch (error) {
      throw _friendlyNativeError(error.code);
    } on MissingPluginException {
      throw const SystemTtsException('当前平台暂不支持系统语音文件合成');
    }
  }

  static String _normalizedPath(String path) {
    final absolute = File(path).absolute.path;
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  Future<void> pause() async {
    _ensureAlive();
    try {
      await methodChannel.invokeMethod<dynamic>('pause');
    } on PlatformException catch (error) {
      throw _friendlyNativeError(error.code);
    } on MissingPluginException {
      throw const SystemTtsException('当前平台暂不支持系统语音暂停');
    }
  }

  Future<void> configure({String? locale, String? voiceId}) async {
    _ensureAlive();
    try {
      if (locale != null) {
        final result = await methodChannel.invokeMethod<dynamic>(
            'setLanguage', <String, Object?>{'locale': locale});
        if (result is! Map || result['available'] != true) {
          throw const SystemTtsException('所选语言不可用', code: 'INVALID_LOCALE');
        }
      }
      if (voiceId != null) {
        final result = await methodChannel.invokeMethod<dynamic>(
            'setVoice', <String, Object?>{'id': voiceId});
        if (result != true) {
          throw const SystemTtsException('所选语音不可用', code: 'VOICE_NOT_FOUND');
        }
      }
    } on PlatformException catch (error) {
      throw _friendlyNativeError(error.code);
    } on MissingPluginException {
      throw const SystemTtsException('当前平台暂不支持系统语音朗读');
    }
  }

  Future<void> stop() async {
    _ensureAlive();
    try {
      await methodChannel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      throw _friendlyError(error);
    } on MissingPluginException {
      throw const SystemTtsException('当前平台暂不支持停止系统语音');
    }
  }

  /// Register the native same-channel callback; repeated calls are idempotent.
  void listen() {
    _ensureAlive();
    if (_listening && identical(_handlerOwners[methodChannel.name], this)) {
      return;
    }
    _listening = true;
    _handlerOwners[methodChannel.name] = this;
    methodChannel.setMethodCallHandler((MethodCall call) async {
      _handleNativeMethod(call);
    });
  }

  void _handleNativeMethod(MethodCall call) {
    final raw = call.arguments;
    if (raw is! Map) {
      _events.add(const SystemTtsSpeechError('', '语音事件格式无效'));
      return;
    }
    final map = Map<dynamic, dynamic>.from(raw);
    final type = call.method;
    final id = _stringValue(map['utteranceId']) ?? '';
    switch (type) {
      case 'onStart':
      case 'speechStart':
        _events.add(SystemTtsSpeechStart(id));
      case 'onProgress':
      case 'progress':
        _events.add(SystemTtsSpeechProgress(SystemTtsProgress.fromMap(map)));
      case 'onComplete':
      case 'done':
        _events.add(SystemTtsSpeechDone(id));
      case 'onStopped':
        _events.add(SystemTtsSpeechStopped(id));
      case 'onError':
      case 'error':
        _events.add(SystemTtsSpeechError(
          id,
          _friendlyNativeError(_stringValue(map['code'])).message,
        ));
      default:
        _events.add(SystemTtsSpeechError(id, '未知语音事件：$type'));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(_handlerOwners[methodChannel.name], this)) {
      _handlerOwners.remove(methodChannel.name);
      methodChannel.setMethodCallHandler(null);
    }
    await _events.close();
  }

  void _ensureAlive() {
    if (_disposed) throw const SystemTtsException('语音服务已关闭');
  }

  static SystemTtsException _friendlyNativeError(String? code) {
    final message = switch (code) {
      'TTS_NOT_READY' => '系统语音引擎仍在初始化，请稍后重试',
      'VOICE_NOT_FOUND' => '所选语音不可用',
      'ENGINE_NOT_FOUND' => '所选系统语音引擎未安装',
      'INVALID_ENGINE' => '系统语音引擎参数无效',
      'TTS_ENGINE_CHANGED' => '语音引擎已切换，请重试当前语段',
      'INVALID_LOCALE' => '语言区域设置无效',
      'INVALID_RATE' => '语速设置无效',
      'INVALID_TEXT' => '朗读文本为空或无效',
      'SPEAK_FAILED' => '语音播放失败',
      'TTS_ERROR' => '语音播放失败',
      'INIT_FAILED' => '系统语音引擎初始化失败',
      'engine_unavailable' => '系统语音引擎不可用',
      'voice_not_found' => '所选语音不可用',
      'invalid_argument' || 'INVALID_ARGUMENT' => '语音参数无效',
      'speak_failed' => '语音播放失败',
      'stop_failed' => '停止语音失败',
      _ => '系统语音合成发生错误',
    };
    return SystemTtsException(message, code: code);
  }

  static SystemTtsException _friendlyError(PlatformException error) {
    final details = _stringValue(error.message);
    final message = switch (error.code) {
      'engine_unavailable' => '系统语音引擎不可用',
      'voice_not_found' => '所选语音不可用',
      'invalid_argument' => '语音参数无效',
      'speak_failed' => '语音播放失败',
      'stop_failed' => '停止语音失败',
      _ => details == null || details.isEmpty ? '系统语音服务发生错误' : details,
    };
    return SystemTtsException(message, code: error.code);
  }
}

/// Adapts native Android utterance callbacks to the reader playback controller.
class NativeSystemTtsService implements SystemTtsService {
  NativeSystemTtsService(this.systemTts) {
    final name = systemTts.methodChannel.name;
    final previousOwner = SystemTts._handlerOwners[name];
    final previousService = _owners[name];
    systemTts.listen();
    _owners[name] = this;
    _subscription = systemTts.events.listen(_onEvent, onError: (Object error) {
      if (!_disposed) _events.add(TtsPlaybackEvent(error: error));
    });
    if (previousOwner != null && !identical(previousOwner, systemTts)) {
      // Ownership changes even when the new page has not started playback.
      // Stop the old page in the shared queue, ahead of new-owner speech.
      unawaited(_enqueue(() async {
        if (_ownsChannel) {
          try {
            await systemTts.stop();
          } catch (error) {
            _takeoverFailure = error;
            rethrow;
          }
        }
      }).catchError((Object error) {
        if (!_disposed && _ownsChannel) {
          _events.add(TtsPlaybackEvent(error: error));
        }
      }));
      previousService?._revokeOwnership();
    }
  }

  final SystemTts systemTts;
  // Delivery is synchronous: once an utterance has passed the active-ID check,
  // its event must reach the controller before another play can replace it.
  // Terminal state is cleared before add(), making listener re-entry safe.
  final StreamController<TtsPlaybackEvent> _events =
      StreamController<TtsPlaybackEvent>.broadcast(sync: true);
  late final StreamSubscription<SystemTtsEvent> _subscription;
  int _serial = 0;
  bool _disposed = false;
  static int _nextUtterance = 0;
  static final Map<String, Future<void>> _queues = {};
  static final Map<String, NativeSystemTtsService> _owners = {};
  Object? _takeoverFailure;
  String? _activeUtterance;
  String? _acceptedUtterance;
  SystemTtsEvent? _pendingTerminal;

  void _revokeOwnership() {
    final wasActive = _activeUtterance != null;
    ++_serial;
    _activeUtterance = null;
    _acceptedUtterance = null;
    _pendingTerminal = null;
    if (wasActive && !_disposed) {
      _events.add(const TtsPlaybackEvent(interrupted: true));
    }
  }

  bool get _ownsChannel => identical(
      SystemTts._handlerOwners[systemTts.methodChannel.name], systemTts);

  Future<void> _enqueue(Future<void> Function() operation) {
    final name = systemTts.methodChannel.name;
    final result =
        (_queues[name] ?? Future<void>.value()).then((_) => operation());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _queues[name] = tail;
    tail.then((_) {
      if (identical(_queues[name], tail)) _queues.remove(name);
    });
    return result;
  }

  String? locale = 'zh-CN';
  String? voiceId;

  @override
  Stream<TtsPlaybackEvent> get events => _events.stream;

  Future<List<SystemTtsVoice>> getVoices() => systemTts.getVoices();

  void selectVoice(SystemTtsVoice? voice) {
    locale = voice?.locale ?? 'zh-CN';
    voiceId = voice?.id;
  }

  @override
  Future<void> speak(String text, {required double rate}) {
    if (_disposed) throw StateError('TTS service is disposed');
    if (!_ownsChannel) {
      if (SystemTts._handlerOwners[systemTts.methodChannel.name] != null) {
        throw StateError('TTS channel belongs to another reader');
      }
      systemTts.listen();
      _owners[systemTts.methodChannel.name] = this;
      _takeoverFailure = null;
    }
    final token = ++_serial;
    final id = 'reader-tts-${++_nextUtterance}';
    final selectedLocale = locale;
    final selectedVoice = voiceId;
    _activeUtterance = id;
    _acceptedUtterance = null;
    _pendingTerminal = null;
    bool current() => !_disposed && _ownsChannel && token == _serial;
    return _enqueue(() async {
      if (!current()) return;
      try {
        final takeoverFailure = _takeoverFailure;
        if (takeoverFailure != null) throw takeoverFailure;
        // Stop the previous utterance before changing engine configuration: a
        // rejected voice/rate must not leave obsolete audio playing silently.
        await systemTts.stop();
        if (!current()) return;
        await systemTts.speak(
          text: text,
          utteranceId: id,
          locale: selectedLocale,
          voiceId: selectedVoice,
          rate: rate,
          isCurrent: current,
        );
        if (current() && _activeUtterance == id) {
          _acceptedUtterance = id;
          final pending = _pendingTerminal;
          _pendingTerminal = null;
          if (pending != null) _onEvent(pending);
        }
      } catch (_) {
        if (current() && _activeUtterance == id) {
          _activeUtterance = null;
          _pendingTerminal = null;
        }
        rethrow;
      }
    });
  }

  @override
  Future<void> pause() => _interrupt(pause: true);

  @override
  Future<void> stop() => _interrupt(pause: false);

  Future<void> _interrupt({required bool pause}) {
    if (_disposed) throw StateError('TTS service is disposed');
    ++_serial;
    _activeUtterance = null;
    return _enqueue(() async {
      if (!_disposed && _ownsChannel) {
        if (pause) {
          await systemTts.pause();
        } else {
          await systemTts.stop();
        }
      }
    });
  }

  void _onEvent(SystemTtsEvent event) {
    final active = _activeUtterance;
    if (_disposed ||
        !_ownsChannel ||
        active == null ||
        active != event.utteranceId) {
      return;
    }
    if ((event is SystemTtsSpeechDone ||
            event is SystemTtsSpeechError ||
            event is SystemTtsSpeechStopped) &&
        _acceptedUtterance != active) {
      _pendingTerminal ??= event;
      return;
    }
    if (event is SystemTtsSpeechError) {
      if (active == event.utteranceId) {
        _activeUtterance = null;
        _events.add(TtsPlaybackEvent(error: SystemTtsException(event.message)));
      }
      return;
    }
    if (active != event.utteranceId) return;
    if (event is SystemTtsSpeechDone) {
      _activeUtterance = null;
      _events.add(const TtsPlaybackEvent(completed: true));
    } else if (event is SystemTtsSpeechStopped) {
      _activeUtterance = null;
      _events.add(const TtsPlaybackEvent(interrupted: true));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_serial;
    _activeUtterance = null;
    final name = systemTts.methodChannel.name;
    if (identical(_owners[name], this)) _owners.remove(name);
    await _subscription.cancel();
    try {
      await _enqueue(() async {
        if (_ownsChannel) await systemTts.stop();
      });
    } catch (_) {
      // Disposal is best-effort; the activity also shuts down the engine.
    }
    await _events.close();
    await systemTts.dispose();
  }
}

String? _stringValue(Object? value) => value is String ? value : null;

int? _intValue(Object? value) => value is int ? value : null;
