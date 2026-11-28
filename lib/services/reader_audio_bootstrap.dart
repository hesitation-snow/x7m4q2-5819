import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'reader_audio_handler.dart';

Future<ReaderAudioHandler>? _initialization;

/// Audio is optional: failure must not prevent the rest of Yomiru from starting.
/// Concurrent requests share one service; a failure may be retried by the user.
Future<ReaderAudioHandler> ensureReaderAudioHandler() async {
  final active = activeReaderAudioHandler;
  if (active != null) return active;
  if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
    throw UnsupportedError('AudioService is unavailable in headless tests');
  }
  if (_initialization != null) return _initialization!;
  final initialization = AudioService.init<ReaderAudioHandler>(
    builder: ReaderAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'moe.yutro.yomiru.reader',
      androidNotificationChannelName: 'Yomiru 听书',
      androidNotificationChannelDescription: '阅读器语音播放控制',
      androidNotificationIcon: 'drawable/ic_stat_listening',
      androidNotificationClickStartsActivity: true,
      androidResumeOnClick: true,
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
    ),
  ).timeout(const Duration(seconds: 15));
  _initialization = initialization;
  try {
    final handler = await initialization;
    activeReaderAudioHandler = handler;
    return handler;
  } finally {
    if (identical(_initialization, initialization)) _initialization = null;
  }
}
