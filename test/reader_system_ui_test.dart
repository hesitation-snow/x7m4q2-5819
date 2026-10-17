import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/services/reader_system_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final modes = <String>[];
  final overlays = <List<dynamic>>[];
  setUp(() {
    modes.clear();
    overlays.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        modes.add(call.arguments as String);
      } else if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
        modes.add('statusBarOnly');
        overlays.add(call.arguments as List<dynamic>);
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('outgoing chapter cannot reset incoming immersive reader', () {
    final old = ReaderSystemUi()..apply(true);
    final next = ReaderSystemUi()..apply(true);
    old.dispose();
    expect(modes, everyElement('statusBarOnly'));
    expect(overlays, everyElement(['SystemUiOverlay.bottom']));
    next.dispose();
    expect(modes.last, 'SystemUiMode.edgeToEdge');
  });

  test('replacement protects bars while preferences are still loading', () {
    final old = ReaderSystemUi()..apply(true);
    final next = ReaderSystemUi();
    old.apply(false);
    old.dispose();
    expect(modes, ['statusBarOnly']);
    next.apply(true);
    next.apply(false);
    expect(modes.last, 'SystemUiMode.edgeToEdge');
    next.dispose();
  });

  test('popping nested reader restores previous preference', () {
    final old = ReaderSystemUi()..apply(true);
    final next = ReaderSystemUi()..apply(false);
    next.dispose();
    expect(modes.last, 'statusBarOnly');
    old.dispose();
    expect(modes.last, 'SystemUiMode.edgeToEdge');
  });
}
