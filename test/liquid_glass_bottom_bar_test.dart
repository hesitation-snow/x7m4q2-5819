import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/widgets/liquid_glass_bottom_bar.dart';

const destinations = [
  LiquidGlassDestination(
      icon: Icons.home_outlined, selectedIcon: Icons.home, label: '首页'),
  LiquidGlassDestination(
      icon: Icons.bookmark_outline, selectedIcon: Icons.bookmark, label: '书架'),
  LiquidGlassDestination(
      icon: Icons.dynamic_feed_outlined,
      selectedIcon: Icons.dynamic_feed,
      label: '动态'),
  LiquidGlassDestination(
      icon: Icons.person_outline, selectedIcon: Icons.person, label: '我的'),
];

class Harness extends StatefulWidget {
  const Harness(
      {super.key, this.width = 800, this.disabled = false, this.insets = 0});
  final double width;
  final bool disabled;
  final double insets;
  @override
  State<Harness> createState() => HarnessState();
}

class HarnessState extends State<Harness> {
  int selected = 0;
  int pageTaps = 0;
  double fraction = 1;
  bool acceptSelection = true;
  final requests = <int>[];
  void external(int index) => setState(() => selected = index);
  void hide() => setState(() => fraction = 0);
  @override
  Widget build(BuildContext context) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
              size: Size(widget.width, 600),
              disableAnimations: widget.disabled,
              viewInsets: EdgeInsets.only(bottom: widget.insets)),
          child: Center(
              child: SizedBox(
            width: widget.width,
            height: 600,
            child: Scaffold(
              extendBody: true,
              body: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => pageTaps++,
                  child: const SizedBox.expand()),
              bottomNavigationBar: LiquidGlassBottomBar(
                selectedIndex: selected,
                barFrac: fraction,
                onDestinationSelected: (i) {
                  requests.add(i);
                  if (acceptSelection) external(i);
                },
                destinations: destinations,
              ),
            ),
          )),
        ),
      );
}

Finder get surface => find.byKey(const ValueKey('liquid-glass-surface'));
Positioned lens(WidgetTester tester) =>
    tester.widget<Positioned>(find.byKey(const ValueKey('liquid-glass-lens')));

void main() {
  setUp(() {
    LKStore.animationsEnabled.value = true;
    LKStore.glassConfiguration.value = GlassConfiguration(
      blur: 22,
      tint: .64,
      barWidth: 292,
      barHeight: 50,
      floatingHeight: 18,
    );
  });
  tearDown(() {
    LKStore.animationsEnabled.value = true;
    LKStore.glassConfiguration.value = GlassConfiguration.defaults;
  });

  testWidgets('Scaffold bar stays 292x50 and does not intercept page taps',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key));
    await tester.pumpAndSettle();
    expect(tester.getSize(surface), const Size(292, 50));
    final rect = tester.getRect(surface);
    await tester.tapAt(Offset(rect.center.dx, rect.top - 60));
    expect(key.currentState!.pageTaps, 1);
    final filter = tester.widget<BackdropFilter>(find.byType(BackdropFilter));
    expect(filter.filter, isA<ui.ImageFilter>());
    if (!ui.ImageFilter.isShaderFilterSupported) {
      expect(find.byKey(const ValueKey('liquid-glass-blur-fallback')),
          findsOneWidget);
    }
    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    expect(key.currentState!.selected, 1);
    expect(lens(tester).left! + lens(tester).width! / 2, closeTo(109.5, 0.01));
  });

  testWidgets('unified frost and high contrast foreground in both themes',
      (tester) async {
    for (final brightness in Brightness.values) {
      final theme = ThemeData(brightness: brightness);
      await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
          bottomNavigationBar: LiquidGlassBottomBar(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            destinations: destinations,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final label = tester.widget<Text>(find.text('书架'));
      expect(label.style!.color, theme.colorScheme.onSurface);
      expect(label.style!.fontWeight, FontWeight.w600);
      final decorations = tester.widgetList<DecoratedBox>(
          find.descendant(of: surface, matching: find.byType(DecoratedBox)));
      expect(decorations.any((box) {
        final decoration = box.decoration;
        return decoration is BoxDecoration &&
            decoration.color != null &&
            (decoration.color!.a - 0.64).abs() < 0.01;
      }), isTrue);
      if (!ui.ImageFilter.isShaderFilterSupported) {
        final filter =
            tester.widget<BackdropFilter>(find.byType(BackdropFilter));
        expect(filter.filter.toString(), contains('22.0'));
      }
    }
  });

  testWidgets('actual narrow width drives tap, drag and animated destination',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key, width: 220));
    await tester.pumpAndSettle();
    expect(tester.getSize(surface).width, 188);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(key.currentState!.selected, 3);
    expect(lens(tester).left! + lens(tester).width! / 2, closeTo(164.5, 0.01));
    final rect = tester.getRect(surface);
    await tester.dragFrom(
        Offset(rect.right - 20, rect.center.dy), const Offset(-95, 0));
    await tester.pumpAndSettle();
    expect(key.currentState!.selected, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'persistent animation listener handles rapid taps and external changes',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    final intermediate = lens(tester).left!;
    expect(intermediate, greaterThan(5.5));
    expect(intermediate, lessThan(224.5));
    await tester.tap(find.text('书架'));
    await tester.pump(const Duration(milliseconds: 20));
    key.currentState!.external(2);
    await tester.pumpAndSettle();
    expect(lens(tester).left! + lens(tester).width! / 2, closeTo(182.5, 0.01));
    expect(key.currentState!.requests, [3, 1]);
  });

  testWidgets(
      'press raises lens; cancelled drag restores selection without callback',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key));
    await tester.pumpAndSettle();
    final rect = tester.getRect(surface);
    final gesture =
        await tester.startGesture(Offset(rect.left + 35, rect.center.dy));
    await tester.pumpAndSettle();
    expect(lens(tester).height, 48);
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(lens(tester).width, greaterThan(69));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(key.currentState!.requests, isEmpty);
    expect(lens(tester).height, 40);
    expect(lens(tester).left! + lens(tester).width! / 2, closeTo(36.5, 0.01));
  });

  testWidgets('drag release springs deformation to bounded dimensions',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key));
    await tester.pumpAndSettle();
    final r = tester.getRect(surface);
    final gesture = await tester.startGesture(Offset(r.left + 30, r.center.dy));
    await gesture.moveBy(const Offset(70, 3));
    await tester.pump();
    await gesture.moveBy(const Offset(24, 2));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(key.currentState!.selected, 1);
    expect(lens(tester).width!, greaterThan(62));
    expect(lens(tester).width!, lessThanOrEqualTo(100));
    expect(lens(tester).height!, inInclusiveRange(40, 56));
    await tester.pumpAndSettle();
    expect(lens(tester).height, 40);
  });

  testWidgets('reduced motion drag release skips spring deformation',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key, disabled: true));
    final r = tester.getRect(surface);
    final gesture = await tester.startGesture(Offset(r.left + 30, r.center.dy));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(lens(tester).height, 40);
    expect(lens(tester).width, 62);
  });

  testWidgets(
      'external selection interrupts drag and rejected requests reconcile',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key));
    await tester.pumpAndSettle();
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('首页')));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    key.currentState!.external(2);
    await tester.pump();
    await gesture.moveBy(const Offset(80, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.requests, isEmpty);
    expect(lens(tester).left! + lens(tester).width! / 2, closeTo(182.5, 0.01));
    key.currentState!.acceptSelection = false;
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(lens(tester).left! + lens(tester).width! / 2, closeTo(182.5, 0.01));
  });

  testWidgets(
      'system reduce motion and live app switch immediately settle lens',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key, disabled: true));
    await tester.tap(find.text('我的'));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(lens(tester).left! + lens(tester).width! / 2, closeTo(255.5, 0.01));
    await tester.pumpWidget(Harness(key: key));
    key.currentState!.external(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    LKStore.animationsEnabled.value = false;
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(lens(tester).left! + lens(tester).width! / 2, closeTo(36.5, 0.01));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'four unique accessible buttons support semantics and keyboard activation',
      (tester) async {
    final handle = tester.ensureSemantics();
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key));
    await tester.pumpAndSettle();
    final node = tester.getSemantics(find.bySemanticsLabel('书架'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(
        tester
            .getSemantics(find.bySemanticsLabel('首页'))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        ui.Tristate.isTrue);
    tester.binding.performSemanticsAction(ui.SemanticsActionEvent(
        type: SemanticsAction.tap,
        nodeId: node.id,
        viewId: tester.view.viewId));
    await tester.pumpAndSettle();
    expect(key.currentState!.selected, 1);
    // Request the detector's own focus node via its descendant context.
    Focus.of(tester.element(find.text('我的'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(key.currentState!.selected, 3);
    handle.dispose();
  });

  testWidgets('sampling ghost is gated, ordered before filter, and inert',
      (tester) async {
    final handle = tester.ensureSemantics();
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key));
    await tester.pumpAndSettle();

    final ghost = find.byKey(const ValueKey('liquid-glass-sampling-ghost'));
    final shaderPath = find
        .byKey(const ValueKey('liquid-glass-refraction'))
        .evaluate()
        .isNotEmpty;
    expect(ghost, shaderPath ? findsOneWidget : findsNothing);
    if (shaderPath) {
      expect(find.descendant(of: ghost, matching: find.byType(IgnorePointer)),
          findsOneWidget);
      expect(
          find.descendant(of: ghost, matching: find.byType(ExcludeSemantics)),
          findsOneWidget);
      final stack = tester.widget<Stack>(surface);
      final children = stack.children;
      final ghostIndex = children.indexWhere((child) =>
          child is Positioned &&
          child.child.key == const ValueKey('liquid-glass-sampling-ghost'));
      final filterIndex = children.indexWhere(
          (child) => child is Positioned && child.child is ClipRRect);
      expect(ghostIndex, greaterThanOrEqualTo(0));
      expect(filterIndex, greaterThan(ghostIndex));
      expect(find.text('首页'), findsNWidgets(2)); // ghost + real foreground
    } else {
      expect(find.text('首页'), findsOneWidget); // fallback has no ghost paint
    }

    // The extra paint contributes neither another semantics node nor a hit target.
    expect(find.bySemanticsLabel('首页'), findsOneWidget);
    final shelfLabel = find.text('书架');
    await tester.tap(shelfLabel);
    await tester.pumpAndSettle();
    expect(key.currentState!.selected, 1);
    handle.dispose();
  });

  testWidgets('keep-visible preference overrides scroll collapse fraction',
      (tester) async {
    final key = GlobalKey<HarnessState>();
    LKStore.glassConfiguration.value =
        GlassConfiguration.defaults.copyWith(keepVisibleOnScroll: true);
    await tester.pumpWidget(Harness(key: key));
    await tester.pumpAndSettle();

    key.currentState!.hide();
    await tester.pumpAndSettle();
    expect(surface, findsOneWidget);
    expect(tester.getSize(surface), const Size(252, 60));

    LKStore.glassConfiguration.value = GlassConfiguration.defaults;
    await tester.pumpAndSettle();
    expect(surface, findsNothing);
  });

  testWidgets('keyboard and fully hidden bar leave no hit targets or semantics',
      (tester) async {
    await tester.pumpWidget(const Harness(insets: 250));
    expect(surface, findsNothing);
    final key = GlobalKey<HarnessState>();
    await tester.pumpWidget(Harness(key: key));
    key.currentState!.hide();
    await tester.pumpAndSettle();
    expect(surface, findsNothing);
  });
  testWidgets('large text retains scaling and 48px destination targets',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(
          size: Size(400, 700), textScaler: TextScaler.linear(2.5)),
      child: Scaffold(
          bottomNavigationBar: LiquidGlassBottomBar(
        selectedIndex: 0,
        onDestinationSelected: (_) {},
        destinations: destinations,
      )),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(find.text('首页')).textScaler!.scale(10), 25);
    final target = find
        .ancestor(of: find.text('首页'), matching: find.byType(Semantics))
        .first;
    expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
  });
}
