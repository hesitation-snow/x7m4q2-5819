import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/widgets/reader_device_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.yutro.yomiru/reader_battery');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
      'battery has no visible percentage and clock updates independently',
      (tester) async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      calls++;
      return 63;
    });
    await tester.pumpWidget(
        const MaterialApp(home: ReaderDeviceStatus(color: Colors.grey)));
    await tester.pump();
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsOneWidget);
    expect(find.bySemanticsLabel('电量 63%'), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    expect(calls, greaterThan(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final before = calls;
    await tester.pump(const Duration(minutes: 2));
    expect(calls, before);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, greaterThan(before));
    await tester.pumpWidget(const SizedBox());
    final disposed = calls;
    await tester.pump(const Duration(minutes: 2));
    expect(calls, disposed);
  });

  testWidgets('unavailable battery still shows clock without inventing charge',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    await tester.pumpWidget(
        const MaterialApp(home: ReaderDeviceStatus(color: Colors.white)));
    await tester.pump();
    expect(find.bySemanticsLabel('电量未知'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d{2}:\d{2}$')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clamps battery level between 0 and 100 and renders properly',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => 150);
    await tester.pumpWidget(
        const MaterialApp(home: ReaderDeviceStatus(color: Colors.white)));
    await tester.pump();
    expect(find.bySemanticsLabel('电量 100%'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
