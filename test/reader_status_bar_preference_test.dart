import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/widgets/reader_device_status.dart';

import 'reader_controls_test.dart' show withReader;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final saved in <bool?>[null, false, true]) {
    test('status bar preference loads saved value $saved', () async {
      SharedPreferences.setMockInitialValues({
        if (saved != null) 'r_hide_bar': saved,
        'r_paged': true,
        'r_tap_turn': true,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(await ReaderPrefs.hideStatusBar(), saved ?? true);
      final settings = await ReaderPrefs.loadAll();
      expect(settings.hideStatusBar, saved ?? true);
      expect(settings.pagedMode, isTrue);
      expect(settings.tapTurnPage, isTrue);
      expect(prefs.containsKey('r_hide_bar'), saved != null);
    });
  }

  test('status bar setting persists toggles without changing other settings',
      () async {
    SharedPreferences.setMockInitialValues({'r_paged': true});
    final prefs = await SharedPreferences.getInstance();
    for (final value in [false, true, false]) {
      await ReaderPrefs.setHideStatusBar(value);
      await prefs.reload();
      expect(prefs.getBool('r_hide_bar'), value);
      expect(await ReaderPrefs.hideStatusBar(), value);
      expect((await ReaderPrefs.loadAll()).hideStatusBar, value);
      expect((await ReaderPrefs.loadAll()).pagedMode, isTrue);
    }
  });

  for (final paged in [false, true]) {
    testWidgets('real reader status bar and indicator, paged=$paged',
        (tester) async {
      final modes = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
          expect(call.arguments, ['SystemUiOverlay.bottom']);
          modes.add('hidden');
        } else if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          modes.add(call.arguments as String);
        }
        return null;
      });
      try {
        await withReader(tester, paged: paged, platform: TargetPlatform.android,
            run: (_, __) async {
          // The toolbar starts open and the system status bar stays visible.
          expect(modes.last, 'SystemUiMode.edgeToEdge');
          expect(find.byType(ReaderDeviceStatus), findsNothing);
          await tester.tapAt(const Offset(200, 350));
          await tester.pump();
          expect(modes.last, 'hidden');
          expect(find.byType(ReaderDeviceStatus), findsOneWidget);
          await tester.tapAt(const Offset(200, 350));
          await tester.pump();
          expect(modes.last, 'SystemUiMode.edgeToEdge');
          expect(find.byType(ReaderDeviceStatus), findsNothing);
          await tester.tap(find.byTooltip('阅读设置'));
          await tester.pumpAndSettle();
          final tile = find.widgetWithText(SwitchListTile, '隐藏系统状态栏');
          await tester.ensureVisible(tile);
          expect(tester.widget<SwitchListTile>(tile).value, isTrue);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(await ReaderPrefs.hideStatusBar(), isFalse);
          expect((await ReaderPrefs.loadAll()).hideStatusBar, isFalse);
          Navigator.of(tester.element(find.text('外观'))).pop();
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(200, 350));
          await tester.pump();
          expect(modes.last, 'SystemUiMode.edgeToEdge');
          expect(find.byType(ReaderDeviceStatus), findsNothing);
        });
        expect(modes.last, 'SystemUiMode.edgeToEdge');
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      }
    });
  }
}
