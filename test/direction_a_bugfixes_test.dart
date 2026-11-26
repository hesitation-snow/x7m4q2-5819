import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/reading_session.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/custom_tts_settings_page.dart';
import 'package:yomiru/pages/medal_shop_page.dart';
import 'package:yomiru/services/app_theme.dart';
import 'package:yomiru/services/custom_ssml_tts.dart';
import 'package:yomiru/services/epub/epub_builder.dart';
import 'package:yomiru/services/epub/epub_models.dart';
import 'package:yomiru/services/reader_audio_handler.dart';
import 'package:yomiru/services/system_tts.dart';

class _TestAudioPlayer implements ReaderAudioPlayer {
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _processing =
      StreamController<ja.ProcessingState>.broadcast(sync: true);
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _buffered = StreamController<Duration>.broadcast(sync: true);
  final _duration = StreamController<Duration?>.broadcast(sync: true);
  final _index = StreamController<int?>.broadcast(sync: true);

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<ja.ProcessingState> get processingStateStream => _processing.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<Duration> get bufferedPositionStream => _buffered.stream;
  @override
  Stream<Duration?> get durationStream => _duration.stream;
  @override
  bool get playing => false;
  @override
  ja.ProcessingState get processingState => ja.ProcessingState.idle;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  int? get currentIndex => null;
  @override
  Stream<int?> get currentIndexStream => _index.stream;

  @override
  Future<void> setSource(ja.AudioSource source) async {}
  @override
  Future<void> setFiles(List<File> files, {required int initialIndex}) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> seekToNext() async {}
  @override
  Future<void> seekToPrevious() async {}
  @override
  Future<void> seekToIndex(int index) async {}

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _processing.close();
    await _position.close();
    await _buffered.close();
    await _duration.close();
    await _index.close();
  }
}

class _DummyPreviewPlayer implements CustomTtsPreviewPlayer {
  @override
  Future<void> dispose() async {}

  @override
  Future<void> play(Uint8List mp3Bytes) async {}

  @override
  Future<void> stop() async {}
}

class _FakeVoiceCatalogTts extends CustomSsmlTts {
  @override
  Future<List<AzureSpeechVoice>> listAzureVoices({
    required String endpoint,
    String? locale,
    String? credentialOverride,
    Duration timeout = const Duration(seconds: 20),
  }) async =>
      const [
        AzureSpeechVoice(
          id: 'zh-CN-XiaoxiaoNeural',
          name: 'Xiaoxiao',
          locale: 'zh-CN',
        ),
        AzureSpeechVoice(
          id: 'ja-JP-NanamiNeural',
          name: 'Nanami',
          locale: 'ja-JP',
        ),
      ];
}

String _extractZipEntryText(Uint8List bytes, String targetName) {
  var offset = 0;
  final data = ByteData.sublistView(bytes);
  while (offset < bytes.length - 30) {
    final sig = data.getUint32(offset, Endian.little);
    if (sig == 0x04034b50) {
      final method = data.getUint16(offset + 8, Endian.little);
      final compSize = data.getUint32(offset + 18, Endian.little);
      final nameLen = data.getUint16(offset + 26, Endian.little);
      final extraLen = data.getUint16(offset + 28, Endian.little);
      final name =
          utf8.decode(bytes.sublist(offset + 30, offset + 30 + nameLen));
      final payloadOffset = offset + 30 + nameLen + extraLen;
      if (name == targetName) {
        final payload = bytes.sublist(payloadOffset, payloadOffset + compSize);
        if (method == 0) return utf8.decode(payload);
        if (method == 8) {
          return utf8.decode(ZLibDecoder(raw: true).convert(payload));
        }
      }
      offset = payloadOffset + compSize;
    } else {
      offset++;
    }
  }
  throw StateError('Entry $targetName not found in zip');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LKClient previousClient;

  setUp(() {
    previousClient = LKApi.client;
    LKClient.shared.session.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  tearDown(() {
    LKApi.client = previousClient;
    LKClient.shared.session.clear();
  });

  test('LKStore.load zeroes uid/nickname/avatar when security_key is empty',
      () async {
    SharedPreferences.setMockInitialValues({
      'uid': 42,
      'nickname': 'stale-user',
      'avatar': 'https://example.com/avatar.png',
    });
    await LKStore.load();
    final session = LKClient.shared.session;
    expect(session.securityKey, isEmpty);
    expect(session.uid, 0);
    expect(session.nickname, isEmpty);
    expect(session.avatar, isEmpty);
    expect(session.isLoggedIn, isFalse);
  });

  test('LKReadingSession.update applies volumeId and progress from volumeId 0',
      () {
    final session = LKReadingSession();
    session.begin(bookId: 10, volumeId: 0, chapterId: 20);
    session.update(volumeId: 7, progress: 0.75);
    final snapshot = session.snapshot();
    expect(snapshot, isNotNull);
    expect(snapshot!.volumeId, 7);
    expect(snapshot.progressPercent, 75);
  });

  test(
      'EpubBuilder handles disabled illustrations, PNG cover MIME, and incomplete exports',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('dir_a_epub_test_');
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    final taskDir = Directory('${tempDir.path}/task');
    final chaptersDir = Directory('${taskDir.path}/chapters');
    await chaptersDir.create(recursive: true);

    // PNG signature cover even though stored at cover.jpg
    await File('${taskDir.path}/cover.jpg').writeAsBytes(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 1,
    ]);
    await File('${taskDir.path}/image_map.json')
        .writeAsString(jsonEncode({'https://img.test/a.jpg': 'a.jpg'}));

    await File('${chaptersDir.path}/101.json').writeAsString(jsonEncode({
      'body_text': '正文第一段',
      'body_html': '<p>正文第一段</p><img src="https://img.test/a.jpg"/>',
    }));
    await File('${chaptersDir.path}/102.json').writeAsString(jsonEncode({
      'body_text': '未完成章节残留',
      'body_html': '<p>未完成章节残留</p>',
    }));

    final outputPath = '${tempDir.path}/out.epub';
    await EpubBuilder.packageInIsolate(
      EpubBuildContext(
        taskDir: taskDir.path,
        outputPath: outputPath,
        bookId: 100,
        bookTitle: '测试书籍',
        authorName: '作者',
        summary: '',
        includeIllustrations: false,
        exportIncomplete: true,
        chapters: const [
          EpubChapterItem(
            chapterId: 101,
            chapterNo: 1,
            title: '已完成章节',
            volumeId: 1,
            volumeTitle: '第一卷',
          ),
          EpubChapterItem(
            chapterId: 102,
            chapterNo: 2,
            title: '未完成章节',
            volumeId: 1,
            volumeTitle: '第一卷',
          ),
        ],
        completedChapterIds: const [101],
      ),
    );

    final bytes = await File(outputPath).readAsBytes();
    final opf = _extractZipEntryText(bytes, 'EPUB/content.opf');
    final coverXhtml = _extractZipEntryText(bytes, 'EPUB/text/cover.xhtml');
    final ch1Xhtml = _extractZipEntryText(bytes, 'EPUB/text/ch_0001.xhtml');

    expect(opf, contains('href="images/cover.png"'));
    expect(opf, contains('media-type="image/png"'));
    expect(coverXhtml, contains('src="../images/cover.png"'));
    expect(ch1Xhtml, isNot(contains('<img')));
    expect(opf, contains('href="text/ch_0001.xhtml"'));
    expect(opf, isNot(contains('ch_0002.xhtml')));
  });

  test(
      'NativeSystemTtsService(deferOwnership: true) keeps background owner alive until speak()',
      () async {
    const channel = MethodChannel('test.direction_a.tts');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'setLanguage') return {'available': true};
      if (call.method == 'setSpeechRate') return true;
      if (call.method == 'speak') {
        final args = call.arguments as Map;
        return {'accepted': true, 'utteranceId': args['utteranceId']};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final bgTts = SystemTts(methodChannel: channel);
    final bgService = NativeSystemTtsService(bgTts);
    final deferredTts = SystemTts(methodChannel: channel);
    final deferredService =
        NativeSystemTtsService(deferredTts, deferOwnership: true);

    await Future<void>.delayed(Duration.zero);
    expect(methods, isEmpty);

    await deferredService.speak('测试朗读', rate: 1.0);
    expect(methods, containsAllInOrder(['stop', 'setSpeechRate', 'speak']));

    await bgService.dispose();
    await deferredService.dispose();
  });

  test('ReaderAudioHandler.playBytes stops active speech session callbacks',
      () async {
    final handler = ReaderAudioHandler(
      player: _TestAudioPlayer(),
      configureAudioSession: false,
      temporaryDirectory: () async => Directory.systemTemp,
    );
    addTearDown(handler.dispose);

    var stopped = 0;
    handler.bindSpeechSessionControls(
      ownerKey: 'speech-1',
      callbacks: TtsMediaCallbacks(
        onPlay: () {},
        onPause: () {},
        onStop: () async => stopped++,
        onPrevious: () {},
        onNext: () {},
      ),
    );

    await handler.playBytes(
      Uint8List.fromList([1, 2, 3]),
      title: '试听',
      autoplay: false,
    );
    expect(stopped, 1);
  });

  testWidgets(
      'CustomTtsSettingsPage preserves Azure voice list when picking a voice',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MaterialApp(
        home: CustomTtsSettingsPage(
          tts: _FakeVoiceCatalogTts(),
          preferences: prefs,
          createPlayer: _DummyPreviewPlayer.new,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('custom-tts-load-voices')),
    );
    await tester.tap(find.byKey(const ValueKey('custom-tts-load-voices')));
    await tester.pumpAndSettle();

    expect(find.text('已获取 2 个音色。'), findsOneWidget);

    await tester.ensureVisible(find.text('选择 Azure 音色'));
    await tester.tap(find.text('选择 Azure 音色'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Nanami · ja-JP'));
    await tester.pumpAndSettle();

    expect(find.text('选择 Azure 音色'), findsOneWidget);
    expect(find.text('Nanami · ja-JP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'MedalShopPage does not mark catalog medals as owned and shows busy state with goods_id',
      (tester) async {
    final exchangeGate = Completer<http.Response>();
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((request) async {
        final uri = request.url.toString();
        if (uri.contains('exchange')) {
          return exchangeGate.future;
        }
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'owned_medals': [
                {'medal_id': 999, 'name': '已拥有的徽章'}
              ],
              'task_medals': [],
              'exchange_medals': [
                {
                  'goods_id': 200,
                  'medal_id': 10,
                  'name': '商城可兑换勋章',
                  'price': 50,
                  'owned': false,
                }
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    LKApi.client.session
      ..securityKey = 'sec'
      ..uid = 1;
    LKClient.shared.session
      ..securityKey = 'sec'
      ..uid = 1;

    await tester.pumpWidget(const MaterialApp(home: MedalShopPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('兑换勋章'));
    await tester.pumpAndSettle();

    expect(find.text('兑换'), findsOneWidget);
    expect(find.text('已获得'), findsNothing);

    await tester.tap(find.text('兑换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认兑换'));
    await tester.pump();

    expect(find.text('处理中'), findsOneWidget);
    exchangeGate.complete(
      http.Response(
        jsonEncode({'code': 0, 'data': {}}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('bottomBarSafePadding trims iOS inset and preserves Android clearance',
      (tester) async {
    Future<double> measure(TargetPlatform platform, double bottomInset) async {
      late double value;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(padding: EdgeInsets.only(bottom: bottomInset)),
            child: Theme(
              data: ThemeData(platform: platform),
              child: Builder(
                builder: (context) {
                  value = bottomBarSafePadding(context, base: 8);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      return value;
    }

    expect(await measure(TargetPlatform.iOS, 34), 20.0);
    expect(await measure(TargetPlatform.iOS, 21), 19.0);
    expect(await measure(TargetPlatform.iOS, 0), 8.0);
    expect(await measure(TargetPlatform.android, 24), 32.0);
    expect(await measure(TargetPlatform.android, 48), 56.0);
  });
}
