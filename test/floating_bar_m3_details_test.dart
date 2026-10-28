import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yomiru/api/store.dart';
import 'package:yomiru/pages/laboratory_page.dart';
import 'package:yomiru/widgets/liquid_glass_bottom_bar.dart';

void main() {
  testWidgets('details group controls while retaining live preview and updates',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    LKStore.loadGlassConfiguration(await SharedPreferences.getInstance());
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: const LiquidGlassLabPage(),
    ));
    await tester.pump();
    expect(find.text('显示行为'), findsOneWidget);
    expect(find.text('玻璃效果'), findsOneWidget);
    expect(find.text('尺寸与位置'), findsOneWidget);
    expect(find.text('实时预览'), findsOneWidget);
    expect(find.byType(LiquidGlassBottomBar), findsOneWidget);

    final blur = tester.widget<Slider>(find.byKey(const ValueKey('背景模糊')));
    final tint = tester.widget<Slider>(find.byKey(const ValueKey('底色遮罩')));
    blur.onChanged!(8);
    tint.onChanged!(.3);
    await tester.pump();
    expect(LKStore.glassConfiguration.value.blur, 8);
    expect(LKStore.glassConfiguration.value.tint, .3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
