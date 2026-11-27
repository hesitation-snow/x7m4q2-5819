import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/comments_page.dart';
import 'package:yomiru/pages/custom_tts_settings_page.dart';
import 'package:yomiru/pages/dm_chat_page.dart';
import 'package:yomiru/pages/dynamic_publish_page.dart';
import 'package:yomiru/pages/login_page.dart';
import 'package:yomiru/pages/media_viewer_page.dart';
import 'package:yomiru/pages/search_page.dart';
import 'package:yomiru/pages/user_profile_page.dart';
import 'package:yomiru/reader/reader_speech_session.dart';
import 'package:yomiru/reader/reader_tts_core.dart';
import 'package:yomiru/services/custom_ssml_tts.dart';
import 'package:yomiru/services/listening_now.dart';
import 'package:yomiru/widgets/listening_dock.dart';
import 'package:yomiru/widgets/reader_listening_sheet.dart';

class _NoopPlayer implements CustomTtsPreviewPlayer {
  @override
  Future<void> play(Uint8List mp3Bytes) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _NoopCustomTts extends CustomSsmlTts {
  @override
  Future<void> saveCredential(String credential) async {}
  @override
  Future<void> clearCredential() async {}
}

class _NoopSynth implements SpeechAudioSynthesizer {
  @override
  Future<File> synthesize(
      String text, SpeechSynthesisConfig config, String cachePath) async {
    final f = File(cachePath);
    await f.parent.create(recursive: true);
    await f.writeAsString(text);
    return f;
  }
}

class _NoopHandler implements SpeechFilesHandler {
  @override
  Future<void> playFiles(
    List<File> files, {
    required String title,
    String? artist,
    Uri? artUri,
    required int startIndex,
    required FutureOr<void> Function(int) onSegmentChanged,
    required FutureOr<void> Function() onCompleted,
  }) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> skipToNext() async {}
  @override
  Future<void> skipToPrevious() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  http.Response okJson(Map<String, dynamic> data) => http.Response.bytes(
        utf8.encode(jsonEncode({'code': 0, 'data': data})),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.dataSaverMode.value = true;
    LKClient.shared.session
      ..securityKey = 'test-key'
      ..uid = 100;
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = false;
  });

  testWidgets('SearchPage skips autofocus with initialTag, has clear button, and Back dismisses keyboard first',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((req) async {
      if (req.url.path.contains('taxonomy')) {
        return okJson({'channels': [], 'tabs': []});
      }
      return okJson({'list': []});
    }));

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const SearchPage(initialTag: 'fantasy'),
              ),
            ),
            child: const Text('打开搜索'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开搜索'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofocus, isFalse);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(find.byTooltip('清空搜索'), findsNothing);

    await tester.enterText(find.byType(TextField), '魔法');
    await tester.pump();
    expect(find.byTooltip('清空搜索'), findsOneWidget);

    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pump();
    expect(field.controller!.text, isEmpty);

    // Back dismisses focus first, second Back pops page.
    expect(field.focusNode!.hasFocus, isTrue);
    final nav = Navigator.of(tester.element(find.byType(SearchPage)));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsOneWidget);
    expect(field.focusNode!.hasFocus, isFalse);

    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(SearchPage), findsNothing);
  });

  testWidgets('DynamicPublishPage disables empty publish and confirms before discarding draft',
      (tester) async {
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((_) async => okJson({'list': []})),
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const DynamicPublishPage(),
              ),
            ),
            child: const Text('去发动态'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('去发动态'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '发布'));
    await tester.pump();
    expect(find.text('请输入动态内容'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('dynamic-content-input')),
      '一段待发布的草稿',
    );
    await tester.pump();

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('放弃此次编辑？'), findsOneWidget);

    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(DynamicPublishPage), findsOneWidget);
    expect(find.text('一段待发布的草稿'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(find.byType(DynamicPublishPage), findsNothing);
  });

  testWidgets('CommentsPage reply auto-focuses input and comment body tap does not push profile',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((req) async {
      if (req.url.path.contains('get-book-comments')) {
        return okJson({
          'list': [
            {
              'comment_id': 10,
              'user_uid': 77,
              'nickname': '评论者A',
              'content': '评论正文内容',
              'avatar': '',
            }
          ],
          'has_more': false,
        });
      }
      if (req.url.path.contains('public-user-home-v1')) {
        return okJson({
          'profile': {'uid': 77, 'nickname': '评论者A'},
        });
      }
      return okJson({'list': []});
    }));

    await tester.pumpWidget(const MaterialApp(home: CommentsPage(bookId: 1)));
    await tester.pumpAndSettle();

    // Tapping comment body must NOT navigate to UserProfilePage.
    await tester.tap(find.text('评论正文内容'));
    await tester.pumpAndSettle();
    expect(find.byType(UserProfilePage), findsNothing);

    // Tapping Reply focuses input automatically.
    await tester.tap(find.text('回复').first);
    await tester.pump();
    expect(find.text('回复 @评论者A'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );

    // Clear input focus by tapping author name works when not blocked? Wait: dismiss first, then tap author.
    await tester.tap(find.byTooltip('取消回复'));
    await tester.tapAt(const Offset(100, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.text('评论者A'));
    await tester.pumpAndSettle();
    expect(find.byType(UserProfilePage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('DMChatPage uses reversed ListView and exposes peer profile icon',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((req) async {
      if (req.url.path.contains('dm-messages-v1')) {
        return okJson({
          'list': [
            {'id': 1, 'sender_uid': 200, 'content': '第一条旧消息'},
            {'id': 2, 'sender_uid': 100, 'content': '最新一条消息'},
          ],
        });
      }
      return okJson({});
    }));

    await tester.pumpWidget(
      const MaterialApp(home: DMChatPage(peerUid: 200, peerName: '对方')),
    );
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.reverse, isTrue);
    expect(find.byTooltip('查看主页'), findsOneWidget);
    expect(find.text('最新一条消息'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('LoginPage uses AutofillGroup, keyboard actions, and prompts on empty submit',
      (tester) async {
    LKClient.shared.session.clear();
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pumpAndSettle();

    expect(find.byType(AutofillGroup), findsOneWidget);
    final fields =
        tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[0].textInputAction, TextInputAction.next);
    expect(fields[1].textInputAction, TextInputAction.done);
    expect(fields[1].autofillHints, contains(AutofillHints.password));

    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pump();
    expect(find.text('请输入登录邮箱'), findsOneWidget);
  });

  testWidgets('MediaViewerPage tap toggles chrome and hides 1/1 for single image',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaViewerPage(url: 'https://example.invalid/art.png'),
      ),
    );
    await tester.pump();

    expect(find.text('1 / 1'), findsNothing);
    expect(find.byTooltip('保存到相册'), findsOneWidget);

    await tester.tapAt(const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 250));

    final opacities =
        tester.widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacities.every((o) => o.opacity == 0), isTrue);

    await tester.tapAt(const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 250));
    final restored =
        tester.widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(restored.every((o) => o.opacity == 1), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('CustomTtsSettingsPage warns before discarding dirty changes and offers AppBar save',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => CustomTtsSettingsPage(
                  tts: _NoopCustomTts(),
                  preferences: prefs,
                  createPlayer: _NoopPlayer.new,
                ),
              ),
            ),
            child: const Text('打开自定义语音'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开自定义语音'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('保存设置'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('custom-tts-name')),
      '我的语音',
    );
    await tester.pump();

    final nav =
        Navigator.of(tester.element(find.byType(CustomTtsSettingsPage)));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);

    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(find.byType(CustomTtsSettingsPage), findsNothing);
  });

  testWidgets('ListeningMenu has a single Stop button and rate step buttons meet 44dp touch target',
      (tester) async {
    late Directory temp;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('yomiru_ux_menu_');
      final session = ReaderSpeechSession(
        handler: _NoopHandler(),
        synthesizer: _NoopSynth(),
        cache: SpeechAudioCache(temporaryDirectory: () async => temp),
      );
      await session.start(
        const [
          TtsSegment(
              blockIndex: 0, startOffset: 0, endOffset: 4, text: '测试段落'),
        ],
        accountId: 'guest',
        config: const SpeechSynthesisConfig(
          source: 'edge',
          voice: 'zh-CN-XiaoxiaoNeural',
          language: 'zh-CN',
          rate: 1,
        ),
        title: '书名',
        artist: '第一章',
      );
      ListeningNow.instance.adopt(
        session: session,
        bookTitle: '书名',
        chapterTitle: '第一章',
        bookId: 1,
        chapterId: 2,
        volumeId: 3,
      );
    });

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: ListeningMenu()),
                ListeningRateControl(rate: 1.0, onChanged: (_) {}),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('停止'), findsOneWidget);
      expect(find.byTooltip('停止'), findsNothing);
      final minusSize = tester.getSize(find.byTooltip('减速'));
      final plusSize = tester.getSize(find.byTooltip('加速'));
      expect(minusSize.width, greaterThanOrEqualTo(44));
      expect(minusSize.height, greaterThanOrEqualTo(44));
      expect(plusSize.width, greaterThanOrEqualTo(44));
      expect(plusSize.height, greaterThanOrEqualTo(44));
    } finally {
      await tester.runAsync(() async {
        await ListeningNow.instance.stop();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
    }
  });
}
