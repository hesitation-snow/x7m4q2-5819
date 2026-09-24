import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/home_channels.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/home_channel_picker.dart';
import 'package:yomiru/pages/home_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.homeChannelOrder.value = defaultHomeChannelOrder;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });
  tearDown(() => LKApi.client = LKClient.shared);

  test('saved order keeps three home tabs and repairs missing channels',
      () async {
    expect(defaultHomeChannelOrder.take(3), ['hot', 'recent', 'rank']);
    final reordered = normalizeHomeChannelOrder([
      'original',
      'rank',
      'epub',
      'rank',
      'unknown',
    ]);
    expect(reordered.take(3), ['original', 'rank', 'epub']);
    expect(reordered.length, homeChannels.length);
    expect(reordered.toSet().length, homeChannels.length);

    await LKStore.setHomeChannelOrder(reordered);
    expect(
      (await SharedPreferences.getInstance())
          .getStringList('home_channel_order')!
          .take(3),
      ['original', 'rank', 'epub'],
    );
    LKStore.homeChannelOrder.value = defaultHomeChannelOrder;
    await LKStore.load();
    expect(
        LKStore.homeChannelOrder.value.take(3), ['original', 'rank', 'epub']);
  });

  Future<void> showPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              await showModalBottomSheet<HomeChannelPickerResult>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => HomeChannelPicker(
                  order: defaultHomeChannelOrder,
                  selectedCode: 'hot',
                ),
              );
            },
            child: const Text('打开分类'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开分类'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('picker offers all channels including the three home tabs',
      (tester) async {
    await showPicker(tester);
    for (final channel in homeChannels) {
      expect(find.text(channel.label), findsOneWidget);
    }
    expect(find.text('首页 1'), findsOneWidget);
    expect(find.text('首页 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing reorders the three home tabs without dropping channels',
      (tester) async {
    HomeChannelPickerResult? result;
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showModalBottomSheet<HomeChannelPickerResult>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => HomeChannelPicker(
                  order: defaultHomeChannelOrder,
                  selectedCode: 'hot',
                ),
              );
            },
            child: const Text('打开分类'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byIcon(Icons.drag_handle_rounded).at(3),
      const Offset(0, -330),
    );
    await tester.pumpAndSettle();
    expect(find.text('首页标签 1'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(result?.order?.take(3), ['lightnovel', 'hot', 'recent']);
    expect(result?.order?.length, homeChannels.length);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home uses the saved first three tabs and their feed endpoints',
      (tester) async {
    LKStore.homeChannelOrder.value = normalizeHomeChannelOrder([
      'original',
      'epub',
      'lightnovel',
    ]);
    final requests = <String>[];
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      requests.add(request.url.path);
      return http.Response(
          jsonEncode({
            'code': 0,
            'data': {'list': []}
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();

    expect(find.text('原创'), findsOneWidget);
    expect(find.text('EPUB'), findsOneWidget);
    expect(find.text('轻小说'), findsOneWidget);
    expect(find.text('热度'), findsNothing);
    expect(requests.any((path) => path.endsWith('/home-original-feed-v1')),
        isTrue);

    await tester.tap(find.text('EPUB'));
    await tester.pumpAndSettle();
    expect(requests.any((path) => path.endsWith('/home-epub-feed-v1')), isTrue);

    final pager = find.byKey(const ValueKey('home_channel_pager'));
    expect(tester.widget<PageView>(pager).controller!.page, closeTo(1, 0.01));
    await tester.drag(pager, const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(pager).controller!.page, closeTo(2, 0.01));
    expect(requests.any((path) => path.endsWith('/home-lightnovel-feed-v1')),
        isTrue);
    await tester.drag(pager, const Offset(320, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(pager).controller!.page, closeTo(1, 0.01));

    await tester.tap(find.byTooltip('选择分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byIcon(Icons.drag_handle_rounded).at(3),
      const Offset(0, -330),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(LKStore.homeChannelOrder.value.take(3), ['hot', 'original', 'epub']);
    expect(find.text('热度'), findsOneWidget);
    expect(find.text('轻小说'), findsNothing);
    expect(tester.widget<PageView>(pager).controller!.page, closeTo(2, 0.01));
    expect(
      (await SharedPreferences.getInstance())
          .getStringList('home_channel_order')!
          .take(3),
      ['hot', 'original', 'epub'],
    );

    await tester.tap(find.byTooltip('选择分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同人'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('分类：同人'), findsOneWidget);
    await tester.drag(find.byType(FeedTab).last, const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip('分类：同人'), findsOneWidget);

    await tester.tap(find.text('原创'));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(pager).controller!.page, closeTo(1, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('swiping recommended books does not change the home channel',
      (tester) async {
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      final books = List.generate(
        request.url.path.endsWith('/home-promo-v1') ? 8 : 1,
        (index) => {'book_id': index + 1, 'title': '测试书籍 $index'},
      );
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {'list': books},
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }));
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();

    final pager = find.byKey(const ValueKey('home_channel_pager'));
    final carousel = find.byWidgetPredicate(
      (widget) => widget is ListView && widget.scrollDirection == Axis.horizontal,
    );
    expect(carousel, findsOneWidget);
    final carouselScroll = find.descendant(
      of: carousel,
      matching: find.byType(Scrollable),
    );
    final carouselPosition = tester.state<ScrollableState>(carouselScroll).position;
    await tester.drag(carousel, const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(carouselPosition.pixels, greaterThan(0));
    expect(tester.widget<PageView>(pager).controller!.page, closeTo(0, 0.01));
    expect(tester.takeException(), isNull);
  });
}
