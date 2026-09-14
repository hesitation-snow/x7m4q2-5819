import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:yomiru/api/models.dart';
import 'package:yomiru/pages/settings_page.dart';
import 'package:yomiru/services/app_update_service.dart';

void main() {
  PackageInfo package(String version) => PackageInfo(
        appName: 'Yomiru',
        packageName: 'moe.yutro.yomiru',
        version: version,
        buildNumber: '6',
      );

  test('release tag newer than installed version is detected', () {
    final info = AppUpdateInfo(
      package: package('1.0.5'),
      release: LKRelease(tag: 'v1.1.0'),
    );

    expect(info.hasNewVersion, isTrue);
    expect(info.latestVersion, '1.1.0');
    expect(info.currentLabel, '1.0.5+6');
  });

  test('same release version is not reported as an update', () {
    final info = AppUpdateInfo(
      package: package('1.1.0'),
      release: LKRelease(tag: 'v1.1.0'),
    );

    expect(info.hasNewVersion, isFalse);
  });

  test('download links stay on the configured HTTPS destinations', () {
    expect(
      YomiruUpdateService.repositoryUrl,
      'https://github.com/hesitation-snow/yomiru',
    );
    expect(
      YomiruUpdateService.baiduDownloadUrl,
      'https://pan.baidu.com/s/1UK9bD81BBMg4KbUWtobO3Q?pwd=ga6c',
    );
  });

  testWidgets('new-version dialog offers both download sources',
      (tester) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final info = AppUpdateInfo(
      package: package('1.0.5'),
      release: LKRelease(
        tag: 'v1.1.0',
        url: '${YomiruUpdateService.releasesUrl}/tag/v1.1.0',
        body: 'Release notes',
      ),
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await YomiruUpdateService.showResult(context, info);
          },
          child: const Text('check'),
        ),
      ),
    ));

    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('百度网盘'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    final buttonCenters = [
      tester.getCenter(find.widgetWithText(TextButton, '稍后')).dy,
      tester.getCenter(find.widgetWithText(TextButton, '百度网盘')).dy,
      tester.getCenter(find.widgetWithText(FilledButton, 'GitHub')).dy,
    ];
    expect(buttonCenters[1], closeTo(buttonCenters[0], 0.1));
    expect(buttonCenters[2], closeTo(buttonCenters[0], 0.1));
  });

  testWidgets('long release notes stay compact and remain scrollable',
      (tester) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notes = List.generate(80, (index) => '更新内容 ${index + 1}').join('\n');
    final info = AppUpdateInfo(
      package: package('1.0.5'),
      release: LKRelease(tag: 'v1.1.0', body: notes),
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            await YomiruUpdateService.showResult(context, info);
          },
          child: const Text('check'),
        ),
      ),
    ));

    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();

    final notesFinder = find.byKey(const Key('release_notes_scroll'));
    expect(notesFinder, findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('update_dialog_content'))).height,
      lessThanOrEqualTo(260),
    );
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: notesFinder, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    expect(find.textContaining('更新内容 80'), findsNothing);
    expect(find.textContaining('…'), findsOneWidget);
  });

  testWidgets('settings cards fit the dark theme and expose repository link',
      (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'Yomiru',
      packageName: 'moe.yutro.yomiru',
      version: '1.0.5',
      buildNumber: '6',
      buildSignature: '',
    );
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5C6BC0),
      brightness: Brightness.dark,
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF121316),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Color(0xFF1E2025),
        ),
      ),
      home: const SettingsPage(),
    ));
    await tester.pump();

    expect(find.byType(Card), findsAtLeastNWidgets(3));
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(find.text('关于'), 100);
    await tester.ensureVisible(find.widgetWithText(ListTile, '关于'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.text('github.com/hesitation-snow/yomiru'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
