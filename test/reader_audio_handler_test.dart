import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:yomiru/services/reader_audio_handler.dart';
import 'package:yomiru/pages/custom_tts_settings_page.dart';

void main() {
  group('MemoryAudioSource', () {
    test('serves MP3 and WAV bytes with correct ranges and MIME', () async {
      for (final mime in ['audio/mpeg', 'audio/wav']) {
        final source = MemoryAudioSource(Uint8List.fromList([1, 2, 3, 4]),
            contentType: mime);
        final response = await source.request(1, 3);
        expect(response.sourceLength, 4);
        expect(response.contentLength, 2);
        expect(response.offset, 1);
        expect(await response.stream.expand((chunk) => chunk).toList(), [2, 3]);
        expect(response.contentType, mime);
      }
    });

    test('rejects out-of-range requests', () async {
      final source =
          MemoryAudioSource(Uint8List.fromList([1]), contentType: 'audio/mpeg');
      await expectLater(source.request(0, 2), throwsRangeError);
    });
  });

  group('ReaderAudioHandler', () {
    late FakeReaderAudioPlayer player;
    late ReaderAudioHandler handler;
    setUp(() {
      player = FakeReaderAudioPlayer();
      handler = ReaderAudioHandler(
          player: player,
          configureAudioSession: false,
          temporaryDirectory: () async => Directory.systemTemp);
    });
    tearDown(() async => handler.dispose());

    test('publishes item/queue and supports play pause seek stop', () async {
      final audio = Uint8List.fromList([0, 1, 2]);
      await handler.playBytes(audio, title: '书名', author: '作者', segment: '第1段');
      expect(handler.mediaItem.valueOrNull?.title, '书名 · 第1段');
      expect(handler.queue.valueOrNull, hasLength(1));
      expect(player.source, isA<ja.UriAudioSource>());
      expect((player.source as ja.UriAudioSource).uri.scheme, 'file');
      expect(File.fromUri((player.source as ja.UriAudioSource).uri).path,
          endsWith('.mp3'));
      expect(player.playCount, 1);
      expect(handler.playbackState.valueOrNull?.playing, isTrue);
      await handler.pause();
      expect(handler.speechStatus, '已暂停');
      await handler.seek(const Duration(seconds: 3));
      expect(player.position, const Duration(seconds: 3));
      await handler.stop();
      expect(handler.playbackState.valueOrNull?.processingState,
          AudioProcessingState.idle);
      expect(handler.speechStatus, '已停止');
    });

    test('updates semantic TTS item and reported position', () {
      handler.updateSpeechStatus(
          title: '书',
          author: '作者',
          segment: '第2段',
          status: '合成中',
          position: const Duration(seconds: 12));
      expect(handler.mediaItem.valueOrNull?.title, '书 · 第2段');
      expect(handler.speechStatus, '合成中');
      expect(handler.playbackState.valueOrNull?.updatePosition,
          const Duration(seconds: 12));
    });

    test('supports WAV and skips previous to beginning', () async {
      await handler.playBytes(Uint8List.fromList([4, 5]),
          title: 'WAV', contentType: 'audio/wav', autoplay: false);
      expect(File.fromUri((player.source as ja.UriAudioSource).uri).path,
          endsWith('.wav'));
      expect(player.playCount, 0);
      player.position = const Duration(seconds: 8);
      await handler.skipToPrevious();
      expect(player.position, Duration.zero);
    });

    test('dispose cancels subscriptions and closes published streams',
        () async {
      var updates = 0;
      final sub = handler.playbackState.listen((_) => updates++);
      await handler.playBytes(Uint8List.fromList([1]),
          title: 'X', autoplay: false);
      await handler.dispose();
      final afterDispose = updates;
      expect(player.positionController.hasListener, isFalse);
      expect(updates, afterDispose);
      expect(handler.playbackState.isClosed, isTrue);
      await sub.cancel();
    });

    test('routes all system media actions to the current owner', () async {
      final calls = <String>[];
      handler.bindTtsOwner(
          ownerKey: 'owner-1',
          callbacks: TtsMediaCallbacks(
            onPlay: () => calls.add('play'),
            onPause: () => calls.add('pause'),
            onStop: () => calls.add('stop'),
            onPrevious: () => calls.add('previous'),
            onNext: () => calls.add('next'),
          ));
      await handler.play();
      await handler.pause();
      await handler.stop();
      await handler.skipToPrevious();
      await handler.skipToNext();
      expect(calls, ['play', 'pause', 'stop', 'previous', 'next']);
      expect(player.playCount, 0);
    });

    test('owner takeover ignores old unbind and routes to new owner', () async {
      final calls = <String>[];
      TtsMediaCallbacks callbacks(String owner) => TtsMediaCallbacks(
            onPlay: () => calls.add('$owner-play'),
            onPause: () {},
            onStop: () {},
            onPrevious: () {},
            onNext: () {},
          );
      handler.bindTtsOwner(ownerKey: 'old', callbacks: callbacks('old'));
      handler.bindTtsOwner(ownerKey: 'new', callbacks: callbacks('new'));
      expect(handler.unbindTtsOwner('old'), isFalse);
      expect(handler.ttsOwnerKey, 'new');
      await handler.play();
      expect(calls, ['new-play']);
      expect(handler.unbindTtsOwner('new'), isTrue);
    });

    test('publishes TTS status, title, position and duration metadata',
        () async {
      await handler.publishTtsState(
          title: '朗读标题',
          author: '朗读作者',
          segment: '片段三',
          status: '合成中',
          position: const Duration(seconds: 14),
          duration: const Duration(seconds: 80));
      final item = handler.mediaItem.valueOrNull!;
      expect(item.title, '朗读标题 · 片段三');
      expect(item.artist, '朗读作者');
      expect(item.extras?['status'], '合成中');
      expect(item.extras?['durationMs'], 80000);
      expect(handler.playbackState.valueOrNull?.updatePosition,
          const Duration(seconds: 14));
    });

    test('external TTS status drives playback state and validates owner key',
        () async {
      handler.bindTtsOwner(
        ownerKey: 'page-a',
        callbacks: TtsMediaCallbacks(
          onPlay: () {},
          onPause: () {},
          onStop: () {},
          onPrevious: () {},
          onNext: () {},
        ),
      );
      await handler.publishTtsState(
        ownerKey: 'page-a',
        title: '外部朗读',
        status: '播放中',
        position: const Duration(seconds: 9),
      );
      final playingState = handler.playbackState.valueOrNull!;
      expect(playingState.playing, isTrue);
      expect(playingState.processingState, AudioProcessingState.ready);
      expect(playingState.updatePosition, const Duration(seconds: 9));
      expect(handler.mediaItem.valueOrNull?.title, '外部朗读');

      await handler.publishTtsState(
          ownerKey: 'stale-page', title: '旧页面', status: '已暂停');
      expect(handler.mediaItem.valueOrNull?.title, '外部朗读');
      expect(handler.playbackState.valueOrNull?.playing, isTrue);

      await handler.publishTtsState(ownerKey: 'page-a', status: '合成中');
      expect(handler.playbackState.valueOrNull?.playing, isFalse);
      expect(handler.playbackState.valueOrNull?.processingState,
          AudioProcessingState.loading);
      expect(handler.disposeTtsOwner('page-a'), isTrue);
      expect(handler.playbackState.isClosed, isFalse);
    });

    test(
        'playMp3 uses a private file without localhost cleartext and keeps shared handler owned',
        () async {
      final input = Uint8List.fromList([0x49, 0x44, 0x33]);
      await handler.playMp3(input, title: '试听曲目', author: '试听作者');
      expect(player.source, isA<ja.UriAudioSource>());
      expect((player.source as ja.UriAudioSource).uri.scheme, 'file');
      expect(File.fromUri((player.source as ja.UriAudioSource).uri).path,
          endsWith('.mp3'));
      expect(handler.mediaItem.valueOrNull?.title, '试听曲目');
      expect(handler.mediaItem.valueOrNull?.artist, '试听作者');
      expect(handler.queue.valueOrNull?.single.title, '试听曲目');
      expect(player.playCount, 1);
      expect(handler.playbackState.isClosed, isFalse);
    });

    test('late cleanup of an old preview never stops a newer source', () async {
      final first = ReaderAudioHandlerTtsAdapter(handler);
      final second = ReaderAudioHandlerTtsAdapter(handler);
      await first.playMp3(Uint8List.fromList([1, 2, 3]));
      final oldId = handler.mediaItem.value!.id;
      await second.playMp3(Uint8List.fromList([4, 5, 6]));
      expect(handler.mediaItem.value!.id, isNot(oldId));
      await first.stop();
      expect(player.playing, isTrue);
      await second.stop();
      expect(player.playing, isFalse);
    });

    test('preview adapter recognizes WAV bytes rather than forcing an MP3 file',
        () async {
      final adapter = ReaderAudioHandlerTtsAdapter(handler);
      final bytes = Uint8List(48);
      bytes.setRange(0, 4, 'RIFF'.codeUnits);
      bytes.setRange(8, 12, 'WAVE'.codeUnits);
      await adapter.playMp3(bytes);
      final source = player.source as ja.UriAudioSource;
      expect(source.uri.path, endsWith('.wav'));
      expect(await File.fromUri(source.uri).readAsBytes(), bytes);
      await adapter.stop();
    });

    test('rejects empty bytes and unsupported media types', () async {
      await expectLater(
          handler.playBytes(Uint8List(0), title: 'x'), throwsArgumentError);
      await expectLater(
          handler.playBytes(Uint8List.fromList([1]),
              title: 'x', contentType: 'audio/ogg'),
          throwsArgumentError);
    });
  });
}

class FakeReaderAudioPlayer implements ReaderAudioPlayer {
  final playingController = StreamController<bool>.broadcast(sync: true);
  final processingController =
      StreamController<ja.ProcessingState>.broadcast(sync: true);
  final positionController = StreamController<Duration>.broadcast(sync: true);
  final bufferedController = StreamController<Duration>.broadcast(sync: true);
  final durationController = StreamController<Duration?>.broadcast(sync: true);
  final currentIndexController = StreamController<int?>.broadcast(sync: true);
  bool _playing = false;
  int? _currentIndex;
  List<File> files = const [];
  ja.ProcessingState _processing = ja.ProcessingState.idle;
  @override
  Duration position = Duration.zero;
  Duration buffered = Duration.zero;
  ja.AudioSource? source;
  int playCount = 0;

  @override
  Stream<bool> get playingStream => playingController.stream;
  @override
  Stream<ja.ProcessingState> get processingStateStream =>
      processingController.stream;
  @override
  Stream<Duration> get positionStream => positionController.stream;
  @override
  Stream<Duration> get bufferedPositionStream => bufferedController.stream;
  @override
  Stream<Duration?> get durationStream => durationController.stream;
  @override
  bool get playing => _playing;
  @override
  ja.ProcessingState get processingState => _processing;
  @override
  Duration get bufferedPosition => buffered;
  @override
  int? get currentIndex => _currentIndex;
  @override
  Stream<int?> get currentIndexStream => currentIndexController.stream;
  @override
  Future<void> setSource(ja.AudioSource value) async {
    files = const [];
    _currentIndex = null;
    currentIndexController.add(null);
    source = value;
    _processing = ja.ProcessingState.ready;
    processingController.add(_processing);
  }

  @override
  Future<void> setFiles(List<File> value, {required int initialIndex}) async {
    files = List<File>.of(value);
    _currentIndex = initialIndex;
    _processing = ja.ProcessingState.ready;
    currentIndexController.add(initialIndex);
    processingController.add(_processing);
  }

  @override
  Future<void> play() async {
    _playing = true;
    playCount++;
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    playingController.add(false);
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _processing = ja.ProcessingState.idle;
    position = Duration.zero;
    playingController.add(false);
    processingController.add(_processing);
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
    positionController.add(value);
  }

  double speed = 1;

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  @override
  Future<void> seekToNext() async {
    final next = (_currentIndex ?? -1) + 1;
    if (next >= 0 && next < files.length) {
      _currentIndex = next;
      currentIndexController.add(next);
    }
  }

  @override
  Future<void> seekToPrevious() async {
    final previous = (_currentIndex ?? 0) - 1;
    if (previous >= 0 && previous < files.length) {
      _currentIndex = previous;
      currentIndexController.add(previous);
    }
  }

  @override
  Future<void> seekToIndex(int index) async {
    if (index >= 0 && index < files.length) {
      _currentIndex = index;
      currentIndexController.add(index);
    }
  }

  @override
  Future<void> dispose() async {
    await playingController.close();
    await processingController.close();
    await positionController.close();
    await bufferedController.close();
    await durationController.close();
    await currentIndexController.close();
  }
}
