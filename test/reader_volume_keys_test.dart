import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/services/reader_volume_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <Map<dynamic, dynamic>>[];
  final bindings = <ReaderVolumeKeys>[];
  ReaderVolumeKeys binding(void Function(bool) turn, bool Function() eligible) {
    final value = ReaderVolumeKeys(onTurn: turn, isEligible: eligible);
    bindings.add(value);
    return value;
  }

  Future<void> key(int owner, String direction) async {
    await messenger.handlePlatformMessage(
        ReaderVolumeKeys.channel.name,
        const StandardMethodCodec().encodeMethodCall(
            MethodCall('volumeKey', {'owner': owner, 'direction': direction})),
        (_) {});
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(ReaderVolumeKeys.channel, (call) async {
      expect(call.method, 'setVolumePaging');
      calls.add(call.arguments as Map);
      return null;
    });
  });
  tearDown(() {
    for (final value in bindings) {
      value.dispose();
    }
    bindings.clear();
    messenger.setMockMethodCallHandler(ReaderVolumeKeys.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('volume paging defaults off and persists independently of reading mode',
      () async {
    expect((await ReaderPrefs.loadAll()).volumeTurnPage, isFalse);
    await ReaderPrefs.setVolumeTurnPage(true);
    await ReaderPrefs.setPagedMode(true);
    expect((await ReaderPrefs.loadAll()).volumeTurnPage, isTrue);
    await ReaderPrefs.setPagedMode(false);
    expect((await ReaderPrefs.loadAll()).volumeTurnPage, isTrue);
  });

  test('only eligible owner receives next/previous; pauses and resumes capture',
      () async {
    var eligible = false;
    final turns = <bool>[];
    final value = binding(turns.add, () => eligible);
    value.sync();
    expect(calls, isEmpty);
    eligible = true;
    value.sync();
    final owner = calls.last['owner'] as int;
    value.sync();
    expect(calls, hasLength(1));
    await key(owner, 'next');
    await key(owner, 'previous');
    await key(owner + 100, 'next');
    await key(owner, 'invalid');
    expect(turns, [true, false]);
    eligible = false;
    await key(owner, 'next');
    value.sync();
    expect(calls.last['enabled'], isFalse);
    eligible = true;
    value.sync();
    value.sync(force: true); // Android clears capture in onPause.
    expect(calls, hasLength(4));
    await key(owner, 'next');
    value.dispose();
    await key(owner, 'next');
    expect(turns, [true, false, true]);
    expect(calls.last['enabled'], isFalse);
  });

  test('disposing an old chapter cannot disable the new reader owner',
      () async {
    final turns = <bool>[];
    final old = binding((_) => fail('old reader received key'), () => true);
    old.sync();
    final oldOwner = calls.last['owner'] as int;
    final current = binding(turns.add, () => true);
    current.sync();
    final newOwner = calls.last['owner'] as int;
    old.dispose();
    expect(calls, hasLength(2));
    expect(calls.last['enabled'], isTrue);
    await key(oldOwner, 'next');
    await key(newOwner, 'next');
    expect(turns, [true]);
  });

  test('iOS and desktop do not register Android volume capture', () {
    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(ReaderVolumeKeys.supported, isFalse);
      binding((_) => fail('unsupported platform'), () => true).sync();
    }
    expect(calls, isEmpty);
  });
}
