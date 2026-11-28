import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/brave_quiz_page.dart';
import 'package:yomiru/pages/epub_maker_page.dart';
import 'package:yomiru/pages/follow_list_page.dart';
import 'package:yomiru/pages/login_page.dart';
import 'package:yomiru/pages/medal_center_page.dart';
import 'package:yomiru/services/app_motion.dart';
import 'package:yomiru/services/epub/epub_download_service.dart';
import 'package:yomiru/services/epub/epub_models.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);
  final String rootPath;

  @override
  Future<String?> getTemporaryPath() async => '$rootPath/tmp';

  @override
  Future<String?> getApplicationSupportPath() async => '$rootPath/support';

  @override
  Future<String?> getApplicationDocumentsPath() async => '$rootPath/docs';
}

http.Response _okJson(Map<String, dynamic> data) => http.Response(
      jsonEncode({'code': 0, 'data': data}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void _setSession({
  required int uid,
  required String securityKey,
  String nickname = 'tester',
}) {
  LKClient.shared.session
    ..uid = uid
    ..securityKey = securityKey
    ..nickname = nickname;
  LKApi.client.session
    ..uid = uid
    ..securityKey = securityKey
    ..nickname = nickname;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final originalPathProvider = PathProviderPlatform.instance;
  late Directory testSandboxDir;
  String? storedSecureKey;
  var failNextSecureWrite = false;

  setUpAll(() {
    testSandboxDir = Directory.systemTemp.createTempSync('pre_release_test_');
    PathProviderPlatform.instance = _FakePathProvider(testSandboxDir.path);
  });

  tearDownAll(() {
    PathProviderPlatform.instance = originalPathProvider;
    if (testSandboxDir.existsSync()) {
      testSandboxDir.deleteSync(recursive: true);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKClient.followChanged.value = null;
    EpubDownloadService.shared.currentTask.value = null;
    storedSecureKey = null;
    failNextSecureWrite = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (call) async {
      switch (call.method) {
        case 'read':
          return storedSecureKey;
        case 'write':
          if (failNextSecureWrite) {
            throw PlatformException(code: 'IO_ERR', message: 'disk full');
          }
          storedSecureKey = (call.arguments as Map)['value'] as String?;
          return null;
        case 'delete':
          storedSecureKey = null;
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    LKClient.followChanged.value = null;
    EpubDownloadService.shared.currentTask.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, null);
  });

  test(
      'LKApi.toggleFollow sends target uid (not viewer uid), invalidates target cache, and notifies targetUid',
      () async {
    final followBodies = <Map<String, dynamic>>[];
    var homeFetches = 0;

    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (request.url.path.endsWith('/api/bff/public-user-home-v1')) {
          homeFetches++;
          return _okJson({
            'profile': {'uid': 999, 'nickname': 'TargetUser'},
            'publications': [],
          });
        }
        if (request.url.path.endsWith('/api/bff/toggle-user-follow-v1')) {
          followBodies.add(body);
          return _okJson({});
        }
        return _okJson({});
      }),
    );
    _setSession(uid: 7, securityKey: 'sec-7');

    await LKApi.publicUserHome(999, 1);
    expect(homeFetches, 1);

    await LKApi.toggleFollow(999, true);
    expect(followBodies.single['uid'], 999);
    expect(followBodies.single['act'], 'follow');
    expect(LKClient.followChanged.value,
        (viewerUid: 7, targetUid: 999, followed: true));

    // Target public home cache must have been invalidated.
    await LKApi.publicUserHome(999, 1);
    expect(homeFetches, 2);
  });

  testWidgets(
      'BraveQuizPage keeps passing result visible and bumps profileRefreshRev without bumping sessionRev',
      (tester) async {
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/api/question/is-answered')) {
          return _okJson({'answered': false, 'available': true});
        }
        if (request.url.path.endsWith('/api/question/get-questions')) {
          return _okJson({
            'passing_score': 60,
            'questions': [
              {
                'question_id': 1,
                'title': '测试题目',
                'options': [
                  {'key': 'A', 'text': '选项 A'},
                  {'key': 'B', 'text': '选项 B'},
                ],
              },
            ],
          });
        }
        if (request.url.path.endsWith('/api/question/get-score')) {
          return _okJson({'score': 85, 'passed': true, 'correct_count': 1});
        }
        return _okJson({});
      }),
    );
    _setSession(uid: 7, securityKey: 'sec-7');

    final sessionRevBefore = LKClient.sessionRev.value;
    final profileRevBefore = LKClient.profileRefreshRev.value;

    await tester.pumpWidget(const MaterialApp(home: BraveQuizPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选项 A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认交卷'));
    await tester.pumpAndSettle();

    expect(find.text('恭喜通过勇者考试'), findsOneWidget);
    expect(find.text('85 / 100'), findsOneWidget);
    expect(LKClient.sessionRev.value, sessionRevBefore);
    expect(LKClient.profileRefreshRev.value, profileRevBefore + 1);
  });

  testWidgets(
      'LoginPage saves store & clears caches before firing sessionRev and rolls back session on store save error',
      (tester) async {
    // 1. Successful login: sessionRev listener sees persisted uid and cleared response cache.
    SharedPreferences.setMockInitialValues({
      'lk_response_cache_v1_stale_feed': jsonEncode({
        'saved_at': 1,
        'data': {'stale': true},
      }),
    });
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/api/bff/auth-password-login-v1')) {
          LKClient.shared.session
            ..uid = 88
            ..securityKey = 'new-key'
            ..nickname = 'NewUser';
          return _okJson({
            'auth': {'security_key': 'new-key', 'uid': 88},
            'user': {'nickname': 'NewUser', 'avatar': ''},
          });
        }
        return _okJson({});
      }),
    );
    LKClient.shared.session
      ..uid = 5
      ..securityKey = 'old-key'
      ..nickname = 'OldUser';
    LKApi.client.session
      ..uid = 5
      ..securityKey = 'old-key'
      ..nickname = 'OldUser';

    int? observedUidAtSessionRev;
    String? observedStaleCacheAtSessionRev;
    final epochBefore = LKStore.contentCacheEpoch;
    var checkPrefsDone = false;
    void onSessionRev() {
      observedUidAtSessionRev = LKApi.client.session.uid;
      unawaited(SharedPreferences.getInstance().then((p) {
        observedStaleCacheAtSessionRev =
            p.getString('lk_response_cache_v1_stale_feed');
        checkPrefsDone = true;
      }));
    }

    LKClient.sessionRev.addListener(onSessionRev);
    addTearDown(() => LKClient.sessionRev.removeListener(onSessionRev));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const LoginPage()),
              ),
              child: const Text('去登录页'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('去登录页'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'user@example.com');
    await tester.enterText(find.byType(TextField).last, 'secret');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    for (var i = 0; i < 30 && !checkPrefsDone; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(checkPrefsDone, isTrue);
    expect(observedUidAtSessionRev, 88);
    expect(LKStore.contentCacheEpoch, greaterThan(epochBefore));
    expect(observedStaleCacheAtSessionRev, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('lk_response_cache_v1_stale_feed'), isFalse);

    // 2. Store save failure rolls back in-memory session fields.
    LKClient.sessionRev.removeListener(onSessionRev);
    failNextSecureWrite = true;
    LKApi.client.session
      ..uid = 5
      ..securityKey = 'old-key'
      ..nickname = 'OldUser'
      ..avatar = 'old.png';
    final revBeforeFail = LKClient.sessionRev.value;

    await tester.tap(find.text('去登录页'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'user@example.com');
    await tester.enterText(find.byType(TextField).last, 'secret');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    for (var i = 0;
        i < 30 &&
            find
                .text('登录成功但本地保存失败，请检查设备存储后重试')
                .evaluate()
                .isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pump();

    expect(LKApi.client.session.uid, 5);
    expect(LKApi.client.session.securityKey, 'old-key');
    expect(LKApi.client.session.nickname, 'OldUser');
    expect(LKClient.sessionRev.value, revBeforeFail);
    expect(find.text('登录成功但本地保存失败，请检查设备存储后重试'), findsOneWidget);
  });

  testWidgets(
      'MedalCenterPage does not overwrite fast empty network result with stale disk cache or stick _refreshing',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'my_medals_cache_7': jsonEncode([
        {'medal_id': 1, 'name': '旧磁盘勋章', 'image': '', 'equipped': true},
      ]),
    });
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/api/bff/my-medals-v1')) {
          return _okJson({'list': []});
        }
        return _okJson({});
      }),
    );
    _setSession(uid: 7, securityKey: 'sec-7');

    await tester.pumpWidget(const MaterialApp(home: MedalCenterPage()));
    await tester.pumpAndSettle();

    expect(find.text('旧磁盘勋章'), findsNothing);
    expect(find.byType(MotionLinearProgressIndicator), findsNothing);
  });

  testWidgets(
      'EpubMakerPage failed view retry catches activeRun StateError instead of crashing',
      (tester) async {
    final activeHold = Completer<http.Response>();
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((_) => activeHold.future),
    );
    _setSession(uid: 7, securityKey: 'sec-7');
    addTearDown(() {
      if (!activeHold.isCompleted) {
        activeHold.complete(http.Response('{"code":500}', 500));
      }
    });

    final book = LKBook(bookId: 99, title: '测试轻小说', authorName: '作者');
    // Keep _activeRun busy so retry startTask throws StateError.
    final activeFuture = EpubDownloadService.shared
        .startTask(
          book: book,
          selectedVolumes: [LKVolume(volumeId: 1, title: '第一卷')],
          options: const EpubExportOptions(),
        )
        .catchError((_) {});
    await tester.pump();
    EpubDownloadService.shared.currentTask.value = EpubDownloadTask(
      ownerUid: 7,
      bookId: 99,
      bookTitle: '测试轻小说',
      authorName: '作者',
      coverUrl: '',
      selectedVolumes: [LKVolume(volumeId: 1, title: '第一卷')],
      options: const EpubExportOptions(),
      phase: EpubTaskPhase.failed,
      statusMessage: '账号状态变化，任务已取消',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EpubMakerPage(
          book: book,
          initialVolumes: [LKVolume(volumeId: 1, title: '第一卷')],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    activeHold.complete(http.Response('{"code":500}', 500));
    await activeFuture;
  });

  testWidgets(
      'FollowListPage clears stale false overrides after successful explicit refresh',
      (tester) async {
    var followingCalls = 0;
    LKApi.client = LKClient.forTesting(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path.contains('user-following-v1')) {
          followingCalls++;
          return _okJson({
            'list': [
              {'uid': 201, 'nickname': '老友甲', 'followed': true},
            ],
            'total': 1,
            'page': 1,
            'has_more': false,
          });
        }
        if (path.contains('user-followers-v1')) {
          return _okJson({'list': [], 'total': 0, 'page': 1, 'has_more': false});
        }
        if (path.contains('toggle-user-follow-v1')) {
          return _okJson({});
        }
        return _okJson({});
      }),
    );
    _setSession(uid: 7, securityKey: 'sec-7');

    await tester.pumpWidget(const MaterialApp(home: FollowListPage()));
    await tester.pumpAndSettle();

    expect(find.text('老友甲'), findsOneWidget);
    // Unfollow locally -> confirm dialog -> _followOverrides[201] = false.
    await tester.tap(find.text('已关注'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('老友甲'), findsNothing);

    // Explicit refresh returns 201 again (e.g. re-followed elsewhere) -> must appear again.
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(followingCalls, 2);
    expect(find.text('老友甲'), findsOneWidget);
  });

  test('iOS AppDelegate, Podfile, and Android Gradle release hygiene checks', () {
    final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(appDelegate, contains('FlutterImplicitEngineDelegate'));
    expect(appDelegate, contains('didInitializeImplicitFlutterEngine'));
    expect(appDelegate, contains('.cachesDirectory'));
    expect(appDelegate, contains('temporaryDirectory'));
    final cancelStart = appDelegate.indexOf('func cancel()');
    expect(cancelStart, greaterThan(0));
    final cancelSnippet = appDelegate.substring(cancelStart, cancelStart + 220);
    expect(cancelSnippet, isNot(contains('[weak self]')));
    expect(appDelegate, contains('configureAudioSessionForLiveSpeech()'));
    expect(appDelegate, contains('runOnMain'));

    final podfile = File('ios/Podfile').readAsStringSync();
    expect(podfile, contains("platform :ios, '15.0'"));
    expect(podfile, contains("IPHONEOS_DEPLOYMENT_TARGET"));

    final gradle = File('android/gradle.properties').readAsStringSync();
    expect(gradle, isNot(contains('kotlin.incremental=false')));
    expect(gradle, isNot(contains('org.gradle.workers.max=2')));
  });
}
