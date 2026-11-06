import 'package:audio_service/audio_service.dart';

import 'reader_audio_handler.dart';

Future<ReaderAudioHandler>? _initialization;

/// Audio is optional: failure must not prevent the rest of Yomiru from starting.
/// Concurrent requests share one service; a failure may be retried by the user.
Future<ReaderAudioHandler> ensureReaderAudioHandler() async {
  final active = activeReaderAudioHandler;
  if (active != null) return active;
  if (_initialization != null) return _initialization!;
  final initialization = AudioService.init<ReaderAudioHandler>(
    builder: ReaderAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'moe.yutro.yomiru.reader',
      androidNotificationChannelName: 'Yomiru 听书',
      androidNotificationChannelDescription: '阅读器语音播放控制',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
    ),
  );
  _initialization = initialization;
  try {
    final handler = await initialization;
    activeReaderAudioHandler = handler;
    return handler;
  } finally {
    if (identical(_initialization, initialization)) _initialization = null;
  }
}
