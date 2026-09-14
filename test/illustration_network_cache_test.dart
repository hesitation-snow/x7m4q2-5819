import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/file.dart' as file;
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as cache;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/reader_cache.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/reader_page.dart';
import 'package:yomiru/services/illustration_cache.dart';
import 'package:yomiru/services/illustration_cache_manager.dart';
import 'package:yomiru/services/illustration_identity.dart';

late final Uint8List _png;

class _Files implements cache.FileSystem {
  final files = MemoryFileSystem();
  @override
  Future<file.File> createFile(String name) async => files.file('/$name');
}

class _Repository extends cache.NonStoringObjectProvider {
  final objects = <String, cache.CacheObject>{};
  int _id = 0;
  @override
  Future<cache.CacheObject?> get(String key) async => objects[key];
  @override
  Future<cache.CacheObject> insert(cache.CacheObject object,
      {bool setTouchedToNow = true}) async {
    final stored = object.copyWith(id: object.id ?? ++_id);
    objects[stored.key] = stored;
    return stored;
  }

  @override
  Future<int> update(cache.CacheObject object,
      {bool setTouchedToNow = true}) async {
    objects[object.key] = object;
    return 1;
  }

  @override
  Future<dynamic> updateOrInsert(cache.CacheObject object) => insert(object);
  @override
  Future<List<cache.CacheObject>> getAllObjects() async =>
      objects.values.toList();
  @override
  Future<int> delete(int id) async {
    objects.removeWhere((_, object) => object.id == id);
    return 1;
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    objects.removeWhere((_, object) => ids.contains(object.id));
    return ids.length;
  }
}

class _Response implements cache.FileServiceResponse {
  final List<int> bytes;
  _Response(this.bytes);
  @override
  Stream<List<int>> get content => Stream.value(bytes);
  @override
  int get contentLength => bytes.length;
  @override
  int get statusCode => 200;
  @override
  DateTime get validTill => DateTime.now().subtract(const Duration(seconds: 1));
  @override
  String get fileExtension => '.png';
  @override
  String? get eTag => null;
}

class _Network extends cache.FileService {
  final calls = <String>[];
  Completer<void>? gate;
  bool fail = false;
  int active = 0;
  int maximum = 0;
  @override
  Future<cache.FileServiceResponse> get(String url,
      {Map<String, String>? headers}) async {
    calls.add(url);
    active++;
    if (active > maximum) maximum = active;
    try {
      if (gate != null) await gate!.future;
      if (fail) throw StateError('offline');
      return _Response(_png);
    } finally {
      active--;
    }
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Network network;
  late IllustrationCacheManager manager;
  var fixtureId = 0;
  const url = 'https://example.invalid/illustration.png';
  const signedBase = 'https://api.lightnovel.fun/upload-files/images/260731/'
      '6bda583f9cf992ba5ab8b0e6f2773cf0.jpg';

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    _png = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });

  setUp(() {
    network = _Network();
    manager = IllustrationCacheManager(cache.Config(
      'illustration-test-${fixtureId++}',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 2000,
      repo: _Repository(),
      fileSystem: _Files(),
      fileService: network,
    ));
  });
  tearDown(() async {
    if (network.gate?.isCompleted == false) network.gate!.complete();
    await manager.dispose();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  test(
      'expired disk files are reused by display, prefetch and save without network',
      () async {
    await manager.putFile(url, Uint8List.fromList(_png),
        maxAge: const Duration(seconds: -1));
    for (var i = 0; i < 3; i++) {
      final display = await manager.getFileStream(url).toList();
      expect((display.single as cache.FileInfo).source, cache.FileSource.Cache);
      expect(await manager.obtain(url), isNotNull);
      expect(await (await manager.getSingleFile(url)).readAsBytes(), _png);
      expect(await manager.downloadFile(url), isNotNull);
    }
    expect(network.calls, isEmpty);
  });

  test(
      'new image downloads once despite an immediately expired server response',
      () async {
    await manager.getFileStream(url).toList();
    await manager.getFileStream(url).toList();
    await manager.getSingleFile(url);
    expect(network.calls, [url]);
  });

  test('a new manager reuses the same persisted files without revalidation',
      () async {
    final repository = _Repository();
    final files = _Files();
    IllustrationCacheManager open() =>
        IllustrationCacheManager(cache.Config('restart-fixture',
            repo: repository, fileSystem: files, fileService: network));
    var reopened = open();
    try {
      await reopened.getSingleFile(url);
      await reopened.dispose();
      reopened = open();
      expect(await (await reopened.getSingleFile(url)).readAsBytes(), _png);
      expect(network.calls, [url]);
    } finally {
      await reopened.dispose();
    }
  });

  test('a file removed by the operating system is downloaded again on demand',
      () async {
    final local = await manager.getSingleFile(url);
    await local.delete();
    expect(await manager.cachedFile(url), isNull);
    expect(manager.isKnownCached(url), isFalse);
    final replacement = await manager.getSingleFile(url);
    expect(await replacement.readAsBytes(), _png);
    expect(network.calls, [url, url]);
  });

  test('simultaneous display, prefetch and saving share one download',
      () async {
    network.gate = Completer<void>();
    final results = <Future<Object?>>[
      manager.getFileStream(url).toList(),
      manager.obtain(url),
      manager.getSingleFile(url),
      manager.downloadFile(url),
    ];
    await _until(() => network.calls.isNotEmpty);
    expect(network.calls, [url]);
    network.gate!.complete();
    await Future.wait(results);
    expect(network.calls, [url]);
  });

  test('A to B to A with fresh signatures only downloads each resource once',
      () async {
    const first = '$signedBase?m=first&t=1700000000';
    const returning = '$signedBase?m=returning&t=1700000002';
    await manager.getFileStream(first).toList();
    await manager.getSingleFile(url);
    await manager.getFileStream(returning).toList();
    await manager.obtain(returning);
    expect(await (await manager.getSingleFile(returning)).readAsBytes(), _png);
    expect(network.calls, [first, url]); // 请求仍携带完整签名。
    expect(manager.isKnownCached(returning), isTrue);
  });

  test('two signatures in flight share the same download slot', () async {
    network.gate = Completer<void>();
    const first = '$signedBase?m=first&t=1700000000';
    final work = [
      manager.getSingleFile(first),
      manager.getSingleFile('$signedBase?m=second&t=1700000002')
    ];
    await _until(() => network.calls.isNotEmpty);
    network.gate!.complete();
    await Future.wait(work);
    expect(network.calls, [first]);
  });

  test('old signed URL disk entries survive upgrade and honor clearing',
      () async {
    const old = '$signedBase?m=old&t=1700000000';
    const fresh = '$signedBase?m=fresh&t=1700000002';
    await manager.putFile(old, _png, maxAge: const Duration(seconds: -1));
    expect(await (await manager.getSingleFile(fresh)).readAsBytes(), _png);
    expect(network.calls, isEmpty);
    await manager.emptyCache();
    await manager.getSingleFile(fresh);
    expect(network.calls, [fresh]);
  });

  test('all image entry points share the three-download limit', () async {
    network.gate = Completer<void>();
    final results = List.generate(12, (i) {
      final imageUrl = '$url?image=$i';
      return switch (i % 3) {
        0 => manager.getFileStream(imageUrl).toList(),
        1 => manager.obtain(imageUrl),
        _ => manager.getSingleFile(imageUrl),
      };
    });
    await _until(() => network.calls.length == 3);
    expect(network.maximum, 3);
    network.gate!.complete();
    await Future.wait(results);
    expect(network.calls.length, 12);
    expect(network.maximum, lessThanOrEqualTo(3));
  });

  test('cached image does not wait for occupied download slots', () async {
    const cachedUrl = 'https://example.invalid/cached.png';
    await manager.putFile(cachedUrl, Uint8List.fromList(_png),
        maxAge: const Duration(seconds: -1));
    network.gate = Completer<void>();
    final busy = List.generate(3, (i) => manager.obtain('$url?busy=$i'));
    await _until(() => network.calls.length == 3);
    final local = await manager
        .getSingleFile(cachedUrl)
        .timeout(const Duration(seconds: 1));
    expect(await local.exists(), isTrue);
    expect(network.calls, hasLength(3));
    network.gate!.complete();
    await Future.wait(busy);
  });

  test(
      'obsolete prefetch is skipped while another viewer can keep a shared request',
      () async {
    network.gate = Completer<void>();
    final busy = List.generate(3, (i) => manager.obtain('$url?busy=$i'));
    await _until(() => network.calls.length == 3);
    var current = true;
    final skipped = manager.obtain('$url?skip=1', isCurrent: () => current);
    final sharedPrefetch = manager.obtain(url, isCurrent: () => current);
    final display = manager.getFileStream(url).toList();
    await Future<void>.delayed(Duration.zero);
    current = false;
    network.gate!.complete();
    await Future.wait(busy);
    expect(await skipped, isNull);
    await sharedPrefetch;
    expect(await display, hasLength(1));
    expect(network.calls.where((value) => value == url), hasLength(1));
    expect(network.calls.any((value) => value.contains('skip=1')), isFalse);
  });

  test('failed download is released and a later explicit retry works',
      () async {
    network.fail = true;
    await expectLater(manager.getFileStream(url).toList(), throwsStateError);
    network.fail = false;
    await manager.getFileStream(url).toList();
    await manager.getFileStream(url).toList();
    expect(network.calls, [url, url]);
  });

  test(
      'same URL refresh is explicit and query parameters remain part of identity',
      () async {
    await manager.getSingleFile(url);
    await manager.downloadFile(url, force: true);
    await manager.getSingleFile('$url?v=2');
    expect(network.calls, [url, url, '$url?v=2']);
  });

  test(
      'clearing invalidates queued work and waits for active downloads before deletion',
      () async {
    network.gate = Completer<void>();
    final work = List.generate(8, (i) => manager.obtain('$url?clear=$i'));
    await _until(() => network.calls.length == 3);
    final before = manager.generation;
    final clearing = manager.emptyCache();
    expect(manager.generation, before + 1);
    network.gate!.complete();
    await clearing;
    expect(await Future.wait(work), everyElement(isNull));
    expect(network.calls, hasLength(3));
    for (var i = 0; i < 8; i++) {
      expect(await manager.cachedFile('$url?clear=$i'), isNull);
    }
    await manager.getSingleFile('$url?clear=0');
    expect(network.calls, hasLength(4));
  });

  testWidgets(
      'rebuilding a real image widget after memory eviction reuses expired disk cache',
      (tester) async {
    await tester.runAsync(() => manager.putFile(url, Uint8List.fromList(_png),
        maxAge: const Duration(seconds: -1)));
    Object? imageError;
    Widget picture() => MaterialApp(
            home: Scaffold(
                body: CachedNetworkImage(
          cacheManager: manager,
          imageUrl: url,
          memCacheWidth: 100,
          errorWidget: (_, __, error) {
            imageError = error;
            return const Text('image failed');
          },
        )));
    await tester.pumpWidget(picture());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(imageError, isNull);
    expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pumpWidget(picture());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(find.text('image failed'), findsNothing);
    expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        isTrue);
    expect(network.calls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'scroll reader next chapter then previous with rotated image signatures',
      (tester) async {
    final root = await tester.runAsync(
        () => io.Directory.systemTemp.createTemp('yomiru-reader-switch-'));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const wakeChannel =
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    messenger.setMockMethodCallHandler(pathChannel, (_) async => root!.path);
    messenger.setMockMessageHandler(wakeChannel,
        (_) async => const StandardMessageCodec().encodeMessage([null]));
    SharedPreferences.setMockInitialValues({'r_paged': false});
    LKClient.shared.session.clear();
    LKStore.dataSaverMode.value = false;
    YomiruIllustrationCache.useManagerForTesting(manager);
    final revisions = <int, int>{};
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final data = <String, dynamic>{};
      if (request.url.path.endsWith('/get-chapter-detail')) {
        final id = (body['chapter_id'] as num).toInt();
        final revision = (revisions[id] ?? 0) + 1;
        revisions[id] = revision;
        final imageBase = id == 317815
            ? signedBase
            : signedBase.replaceFirst('6bda583f', '7bda583f');
        data.addAll({
          'chapter_id': id,
          'volume_id': 1,
          'chapter_no': 1,
          'title': 'fixture-$id',
          'body_snapshot': {
            'body_html': '<p>fixture-$id</p>'
                '<img src="$imageBase?m=revision$revision&t=${1700000000 + revision}" width="600" height="400">'
                '<p>tail</p>'
          },
          'navigation': {
            'prev_chapter': {
              'chapter_id': 317815,
              'volume_id': 1,
              'title': 'fixture-317815'
            },
            'next_chapter': {
              'chapter_id': 317816,
              'volume_id': 1,
              'title': 'fixture-317816'
            },
          },
        });
      }
      return http.Response(jsonEncode({'code': 0, 'data': data}), 200,
          headers: {'content-type': 'application/json'});
    }));
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      await tester.pump();
    }

    try {
      await tester.runAsync(ReaderContentCache.clear);
      await tester.pumpWidget(const MaterialApp(
          home: ReaderPage(
        bookId: 1338,
        bookTitle: 'fixture',
        chapterId: 317815,
        chapterTitle: 'fixture-317815',
        volumeId: 1,
      )));
      await settle();
      expect(network.calls, hasLength(1));
      expect(network.calls.first, contains('m=revision1&t='));
      await tester.tap(find.text('下一章').hitTestable().first);
      await settle();
      expect(
          tester.widget<ReaderPage>(find.byType(ReaderPage)).chapterId, 317816);
      expect(network.calls, hasLength(2));
      await tester.tap(find.text('上一章').hitTestable().first);
      await settle();
      expect(
          tester.widget<ReaderPage>(find.byType(ReaderPage)).chapterId, 317815);
      expect(revisions[317815], greaterThan(1));
      final displayed = tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage).first);
      expect(displayed.imageUrl, contains('revision${revisions[317815]}'));
      expect(displayed.cacheKey, illustrationCacheKey(displayed.imageUrl));
      expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null),
          isTrue);
      expect(network.calls, hasLength(2)); // 返回旧章没有第三次图片下载。
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
      // flutter_cache_manager 的一次性清理定时器也必须在测试结束前走完。
      await tester.pump(const Duration(seconds: 11));
      await tester.runAsync(ReaderContentCache.clear);
      YomiruIllustrationCache.useManagerForTesting(null);
      LKApi.client = LKClient.shared;
      messenger.setMockMethodCallHandler(pathChannel, null);
      messenger.setMockMessageHandler(wakeChannel, null);
      await tester.runAsync(() => root!.delete(recursive: true));
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
