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
import 'package:yomiru/api/models.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/dynamic_page.dart';
import 'package:yomiru/pages/dynamic_publish_page.dart';
import 'package:yomiru/pages/epub_maker_page.dart';
import 'package:yomiru/pages/home_channel_picker.dart';
import 'package:yomiru/pages/home_page.dart';
import 'package:yomiru/pages/search_page.dart';
import 'package:yomiru/pages/welfare_page.dart';
import 'package:yomiru/widgets/m3_controls.dart';
import 'package:yomiru/widgets/m3_menu_sheet.dart';

http.Response _response(Map<String, dynamic> data) => http.Response.bytes(
      utf8.encode(jsonEncode({'code': 0, 'data': data})),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page,
  Brightness brightness, {
  double textScale = 2,
  Size size = const Size(320, 760),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.indigo,
        brightness: brightness,
      ),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: page,
  ));
  await tester.pumpAndSettle();
}

Finder _chip(String label) => find.widgetWithText(M3ChoiceChip, label);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKClient.shared.session
      ..clear()
      ..uid = 42
      ..securityKey = 'test-session';
    WelfarePage.clearClaimedTestingState();
    LKStore.homeChannelOrder.value = defaultHomeChannelOrder;
    LKStore.dataSaverMode.value = false;
    LKStore.dailyTreasureEnabled.value = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    LKApi.client = LKClient.forTesting(httpClient: MockClient((request) async {
      if (request.url.path.contains('comment-emoji-list')) {
        return _response({
          'list': [
            {'name': '测试表情组', 'items': []}
          ]
        });
      }
      return _response({'list': [], 'has_more': false});
    }));
  });

  tearDown(() {
    LKApi.client = LKClient.shared;
    LKClient.shared.session.clear();
    WelfarePage.clearClaimedTestingState();
    LKStore.dailyTreasureEnabled.value = false;
  });

  for (final brightness in Brightness.values) {
    testWidgets('search uses shared selectable chips at 2x text $brightness',
        (tester) async {
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        if (request.url.path.contains('apk-search-taxonomy')) {
          return _response({
            'channels': [
              {'code': 'lightnovel', 'label': '轻小说'}
            ],
            'tabs': [
              {
                'groups': [
                  {
                    'sections': [
                      {
                        'tag_items': [
                          {
                            'title': '冒险',
                            'jump_type': 'tag',
                            'jump_value': 'adventure'
                          }
                        ]
                      }
                    ]
                  }
                ]
              }
            ]
          });
        }
        return _response({'list': []});
      }));
      await _pumpPage(tester, const SearchPage(), brightness);
      expect(find.byType(M3ChoiceChip), findsNWidgets(6));
      await tester.tap(_chip('最新'));
      await tester.pumpAndSettle();
      expect(tester.widget<M3ChoiceChip>(_chip('最新')).selected, isTrue);
      expect(tester.widget<M3ChoiceChip>(_chip('相关')).selected, isFalse);
      await tester.ensureVisible(_chip('轻小说'));
      await tester.tap(_chip('轻小说'));
      await tester.pumpAndSettle();
      expect(tester.widget<M3ChoiceChip>(_chip('轻小说')).selected, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dynamic shared chips remain independent toggles $brightness',
        (tester) async {
      await _pumpPage(tester, const DynamicPage(), brightness);
      expect(find.byType(M3ChoiceChip), findsNWidgets(2));
      await tester.tap(_chip('关注'));
      await tester.pumpAndSettle();
      await tester.tap(_chip('仅作品'));
      await tester.pumpAndSettle();
      expect(tester.widget<M3ChoiceChip>(_chip('关注')).selected, isTrue);
      expect(tester.widget<M3ChoiceChip>(_chip('仅作品')).selected, isTrue);
      await tester.tap(_chip('关注'));
      await tester.pumpAndSettle();
      expect(tester.widget<M3ChoiceChip>(_chip('关注')).selected, isFalse);
      expect(tester.widget<M3ChoiceChip>(_chip('仅作品')).selected, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'rank selector fits shared chips and retains selection $brightness',
        (tester) async {
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        return _response({
          'list': [
            {'book_id': 7, 'title': '排行榜测试作品'}
          ]
        });
      }));
      await _pumpPage(
        tester,
        const Scaffold(
          body: FeedTab(channelCode: 'rank', path: 'rank', listMode: true),
        ),
        brightness,
      );
      expect(_chip('综合热度'), findsOneWidget);
      await tester.tap(_chip('新书'));
      await tester.pumpAndSettle();
      expect(tester.widget<M3ChoiceChip>(_chip('新书')).selected, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'emoji sheet shares chrome and close preserves draft $brightness',
        (tester) async {
      await _pumpPage(tester, const DynamicPublishPage(), brightness);
      await tester.enterText(find.byType(TextField), '保留的草稿');
      await tester.ensureVisible(find.text('表情'));
      await tester.tap(find.text('表情'));
      await tester.pumpAndSettle();
      expect(find.byType(M3MenuSheet), findsOneWidget);
      expect(find.text('选择表情'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(M3MenuSheet), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '保留的草稿');
    });

    testWidgets(
        'epub illustration setting uses shared leading icon $brightness',
        (tester) async {
      await _pumpPage(
        tester,
        EpubMakerPage(
          book: LKBook(bookId: 71, title: '导出测试作品'),
          initialVolumes: [LKVolume(volumeId: 1, title: '第一卷')],
        ),
        brightness,
        textScale: 1,
      );
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.secondary, isA<AppSettingIcon>());
      expect((toggle.secondary! as AppSettingIcon).icon, Icons.image_outlined);
      await tester.tap(find.text('TXT'));
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile), findsNothing);
      await tester.tap(find.text('EPUB'));
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('category close cancels while done returns order $brightness',
        (tester) async {
      HomeChannelPickerResult? result;
      var returned = false;
      await _pumpPage(
        tester,
        Scaffold(body: Builder(builder: (context) {
          return TextButton(
            onPressed: () async {
              result = await showModalBottomSheet<HomeChannelPickerResult>(
                context: context,
                showDragHandle: false,
                isScrollControlled: true,
                builder: (_) => HomeChannelPicker(
                  order: defaultHomeChannelOrder,
                  selectedCode: 'hot',
                ),
              );
              returned = true;
            },
            child: const Text('打开分类'),
          );
        })),
        brightness,
      );
      await tester.tap(find.text('打开分类'));
      await tester.pumpAndSettle();
      expect(find.byType(M3SheetHeader), findsOneWidget);
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(result, isNull);
      await tester.tap(find.text('打开分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(result!.order, defaultHomeChannelOrder);
      expect(result!.selectedCode, 'hot');
      expect(tester.takeException(), isNull);
    });

    testWidgets('welfare informational sheets never claim rewards $brightness',
        (tester) async {
      final paths = <String>[];
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        final path = request.url.path;
        paths.add(path);
        if (path.contains('welfare-treasure-box-detail')) {
          return _response({
            'card': {
              'week_plan': [
                {
                  'day': 1,
                  'is_today': true,
                  'total_reward': 50,
                  'total_boxes': 3
                },
                {'day': 2, 'total_reward': 60, 'total_boxes': 3},
              ]
            }
          });
        }
        if (path.contains('invite')) {
          return _response({'invite_code': 'TEST42'});
        }
        return _response({
          'tasks': [
            {
              'task_id': 300006,
              'task_key': 'daily_invite_friend_v1',
              'title': '邀请好友获得轻币',
              'status': 0,
            }
          ]
        });
      }));
      await _pumpPage(tester, const WelfarePage(), brightness,
          textScale: 1, size: const Size(430, 900));
      await tester.ensureVisible(find.text('周计划'));
      await tester.tap(find.text('周计划'));
      await tester.pumpAndSettle();
      expect(find.byType(M3SheetHeader), findsOneWidget);
      expect(find.text('宝箱 7 天奖励计划'), findsOneWidget);
      expect(find.text('+50 轻币'), findsOneWidget);
      final weekBuilder =
          tester.widget<BottomSheet>(find.byType(BottomSheet)).builder;
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('去邀请'));
      await tester.tap(find.text('去邀请'));
      await tester.pumpAndSettle();
      expect(find.byType(M3MenuSheet), findsOneWidget);
      expect(find.text('TEST42'), findsOneWidget);
      final inviteSheet = tester.widget<M3MenuSheet>(find.byType(M3MenuSheet));
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(paths.where((path) => path.contains('claim')), isEmpty);
      expect(tester.takeException(), isNull);
      // Exercise these panel bodies at the narrow/large-text boundary without
      // conflating their layout with the unrelated task-center dashboard.
      await _pumpPage(
          tester, Scaffold(body: Builder(builder: weekBuilder)), brightness);
      expect(find.text('+50 轻币'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _pumpPage(tester, Scaffold(body: inviteSheet), brightness);
      expect(find.text('TEST42'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
