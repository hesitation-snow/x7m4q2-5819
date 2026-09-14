import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/services/app_motion.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LKStore.animationsEnabled.value = true;
  });
  tearDown(() => LKStore.animationsEnabled.value = true);

  test('motion preference persists and is on by default', () async {
    expect(AppMotion.disabled, isFalse);
    await LKStore.setAnimationsEnabled(false);
    expect(AppMotion.disabled, isTrue);
    expect(
        (await SharedPreferences.getInstance()).getBool('animations_enabled'),
        isFalse);
    await LKStore.setAnimationsEnabled(true);
    expect(
        (await SharedPreferences.getInstance()).getBool('animations_enabled'),
        isTrue);
  });

  testWidgets(
      'disabled scroll and page navigation jump without an intermediate frame',
      (tester) async {
    final scroll = ScrollController();
    final pages = PageController();
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      context = c;
      return Column(children: [
        Expanded(
            child: ListView(
                controller: scroll,
                itemExtent: 60,
                children: List.generate(40, (i) => Text('row$i')))),
        Expanded(
            child: PageView(
                controller: pages,
                children: const [Text('one'), Text('two'), Text('three')])),
      ]);
    })));
    LKStore.animationsEnabled.value = false;
    await AppMotion.scrollTo(context, scroll, 300);
    await AppMotion.pageTo(context, pages, 2);
    expect(scroll.offset, 300);
    expect(pages.page, 2);
    await tester.pump();
    expect(scroll.offset, 300);
    LKStore.animationsEnabled.value = true;
    final animation = AppMotion.scrollTo(context, scroll, 600);
    expect(scroll.offset, 300);
    await tester.pumpAndSettle();
    await animation;
    expect(scroll.offset, 600);
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    pages.dispose();
  });

  testWidgets('loading keeps animating while transitions stay disabled',
      (tester) async {
    LKStore.animationsEnabled.value = false;
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(builder: (c) {
              context = c;
              return const Column(children: [
                MotionProgressIndicator(),
                MotionLinearProgressIndicator(),
              ]);
            }))));
    expect(AppMotion.duration(context, 300), Duration.zero);
    expect(AppMotion.style(context), AnimationStyle.noAnimation);
    expect(
        tester
            .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator))
            .value,
        isNull);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('page routes and tabs complete immediately when motion is off',
      (tester) async {
    LKStore.animationsEnabled.value = false;
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(pageTransitionsTheme: AppMotion.noPageTransitions),
        home: Builder(builder: (c) {
          context = c;
          return const Text('home');
        })));
    final route =
        MaterialPageRoute<void>(builder: (_) => const Text('destination'));
    Navigator.of(context).push(route);
    await tester.pump();
    expect(route.transitionDuration, Duration.zero);
    expect(route.animation!.isCompleted, isTrue);
    expect(find.text('destination'), findsOneWidget);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    final tabs = MotionTabController(length: 3, vsync: tester);
    tabs.animateTo(2);
    expect(tabs.indexIsChanging, isFalse);
    expect(tabs.animation!.value, 2);
    tabs.dispose();
  });

  testWidgets('refresh keeps its normal spinner when transitions are disabled',
      (tester) async {
    LKStore.animationsEnabled.value = false;
    final completed = Completer<void>();
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MotionRefreshIndicator(
      onRefresh: () {
        requests++;
        return completed.future;
      },
      child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [SizedBox(height: 900, child: Text('content'))]),
    ))));
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(requests, 1);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(
        tester
            .widget<RefreshProgressIndicator>(
                find.byType(RefreshProgressIndicator))
            .value,
        isNull);
    completed.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });
}
