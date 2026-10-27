import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/lk_api.dart';
import 'package:yomiru/api/lk_client.dart';
import 'package:yomiru/pages/reader_catalog_sheet.dart';
import 'package:yomiru/reader/indicator_position.dart';
import 'package:yomiru/widgets/m3_controls.dart';
import 'package:yomiru/widgets/m3_menu_sheet.dart';
import 'package:yomiru/widgets/reader_indicators.dart';
import 'package:yomiru/widgets/reader_settings_section.dart';

void main() {
  testWidgets('reader section reuses global group and matching entry icons',
      (tester) async {
    var entered = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReaderSettingsSection(title: '显示', children: [
          SwitchListTile(
            secondary: const AppSettingIcon(Icons.info_outline),
            title: const Text('正文指示器'),
            value: true,
            onChanged: (_) {},
          ),
          IndicatorPositionSettings(
            value: const IndicatorPosition(top: 89, bottom: 67, side: 43),
            onChanged: (_) {},
            onEnterEditMode: () => entered++,
          ),
        ]),
      ),
    ));
    expect(find.byType(AppSectionTitle), findsOneWidget);
    expect(find.byType(AppSettingsGroup), findsOneWidget);
    expect(find.byType(AppSettingIcon), findsNWidgets(2));
    expect(find.textContaining(RegExp(r'89|67|43|dp')), findsNothing);
    final switchIcon = tester.getSize(find.byType(AppSettingIcon).first);
    expect(tester.getSize(find.byType(AppSettingIcon).last), switchIcon);
    expect(switchIcon, const Size(36, 36));
    await tester.tap(find.text('调整指示器位置'));
    expect(entered, 1);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'indicator console wraps large text and retains real font tuning: $brightness',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var value = const IndicatorPosition();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: StatefulBuilder(builder: (_, setState) {
              return IndicatorEditOverlay(
                position: value,
                title: '真实阅读章节',
                progress: const Text('50%'),
                deviceStatus: const Text('12:34'),
                onChanged: (next) => setState(() => value = next),
                onSave: () {},
                onCancel: () {},
                onReset: () {},
              );
            }),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(M3ChoiceChip), findsWidgets);
      final title = find.byKey(const ValueKey('reader-indicator-title'));
      expect(tester.widget<Text>(title).style?.fontSize, 11);
      final fontIncrease = find.text('+1').last;
      await tester.ensureVisible(fontIncrease);
      await tester.tap(fontIncrease);
      await tester.pumpAndSettle();
      expect(value.topFontSize, 12);
      expect(tester.widget<Text>(title).style?.fontSize, 12);
      await tester.ensureVisible(find.text('保存'));
      expect(find.text('保存').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'catalog has shared fixed header and themed large-text surface: $brightness',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      LKApi.client =
          LKClient.forTesting(httpClient: MockClient((request) async {
        final volumes = request.url.path.endsWith('/get-book-volumes');
        return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'list': volumes
                    ? [
                        {
                          'volume_id': 1,
                          'title': '第一卷 旅途与晨光',
                          'chapter_count': 2
                        }
                      ]
                    : [
                        {'chapter_id': 10, 'title': '第一章 晨光', 'chapter_no': 1},
                        {'chapter_id': 11, 'title': '第二章 旅途', 'chapter_no': 2},
                      ],
                'total': volumes ? 1 : 2,
              },
            }),
            200,
            headers: {'content-type': 'application/json'});
      }));
      addTearDown(() => LKApi.client = LKClient.shared);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scheme =
          ColorScheme.fromSeed(seedColor: Colors.teal, brightness: brightness);
      var picked = 0;
      Widget app({Widget? header}) => MaterialApp(
            theme: ThemeData(colorScheme: scheme),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: ReaderCatalogSheet(
                  bookId: 1,
                  volumeId: 1,
                  currentChapterId: 10,
                  currentChapterNo: 1,
                  header: header,
                  onPick: (chapterId, _, __) => picked = chapterId,
                ),
              ),
            ),
          );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(M3SheetHeader), findsOneWidget);
      expect(
          tester.widget<M3SheetHeader>(find.byType(M3SheetHeader)).title, '目录');
      expect(
          find.ancestor(
              of: find.byType(M3SheetHeader),
              matching: find.byType(Scrollable)),
          findsNothing);
      final surface = tester.widget<Material>(find
          .descendant(
              of: find.byType(ReaderCatalogSheet),
              matching: find.byType(Material))
          .first);
      expect(surface.color, scheme.surfaceContainer);
      expect(surface.borderRadius,
          const BorderRadius.vertical(top: Radius.circular(28)));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('第二章 旅途'));
      expect(picked, 11);
      await tester.pumpWidget(app(header: const Text('组合目录标题')));
      await tester.pumpAndSettle();
      expect(find.text('组合目录标题'), findsOneWidget);
      expect(find.byType(M3SheetHeader), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
