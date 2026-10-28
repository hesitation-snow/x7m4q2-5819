import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../api/store.dart';
import '../widgets/liquid_glass_bottom_bar.dart';

class LaboratoryPage extends StatelessWidget {
  const LaboratoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('实验室')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            '探索可选功能与界面实验，所有设置均可随时关闭。',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Text('功能实验', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ValueListenableBuilder<bool>(
              valueListenable: LKStore.dailyTreasureEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                key: const ValueKey('laboratory-daily-treasure-switch'),
                secondary:
                    Icon(Icons.inventory_2_outlined, color: scheme.primary),
                title: const Text('每日开宝箱'),
                value: enabled,
                onChanged: LKStore.setDailyTreasureEnabled,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ValueListenableBuilder<bool>(
              valueListenable: LKStore.allMedalsEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                key: const ValueKey('laboratory-all-medals-switch'),
                secondary: Icon(Icons.workspace_premium_outlined,
                    color: scheme.primary),
                title: const Text('加载勋章商城全部内容'),
                value: enabled,
                onChanged: LKStore.setAllMedalsEnabled,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class LiquidGlassLabPage extends StatefulWidget {
  const LiquidGlassLabPage({super.key});
  @override
  State<LiquidGlassLabPage> createState() => _LiquidGlassLabPageState();
}

class _LiquidGlassLabPageState extends State<LiquidGlassLabPage> {
  int selected = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) LKStore.ensureGlassDimensions(MediaQuery.sizeOf(context));
    });
  }

  @override
  void dispose() {
    unawaited(LKStore.flushGlassConfiguration());
    super.dispose();
  }

  String number(String title, double v) => title == '背景模糊'
      ? v.toStringAsFixed(1)
      : title == '折射强度'
          ? v.toStringAsFixed(3)
          : title == '底栏宽度' || title == '底栏高度' || title == '悬浮高度'
              ? '${v.round()} dp'
              : '${(v * 100).toStringAsFixed(0)}%';

  Widget control(
          String title, double value, double max, ValueChanged<double> change,
          {double min = 0, bool enabled = true, String? hint}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$title：${number(title, value)}',
              style: Theme.of(context).textTheme.titleSmall),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
          Slider(
              key: ValueKey(title),
              value: value,
              min: min,
              max: max,
              label: number(title, value),
              semanticFormatterCallback: (v) => '$title ${number(title, v)}',
              onChanged: enabled ? change : null,
              onChangeEnd: enabled
                  ? (_) => unawaited(LKStore.flushGlassConfiguration())
                  : null),
        ]),
      );

  Widget section(BuildContext context, String title, IconData icon,
      List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(children: [
              Icon(icon, color: scheme.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium)),
            ]),
          ),
          ...children,
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supported = ui.ImageFilter.isShaderFilterSupported;
    return Scaffold(
      appBar: AppBar(title: const Text('悬浮底栏')),
      bottomNavigationBar: SizedBox(
          height: (MediaQuery.sizeOf(context).height * .25).clamp(110.0, 220.0),
          child: Stack(children: [
            Positioned.fill(
                child: ListView.builder(
                    primary: false,
                    key: const ValueKey('glass-preview-background'),
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: 12,
                    itemBuilder: (context, i) => ColoredBox(
                        color: [Colors.teal, Colors.amber, Colors.indigo][i % 3]
                            .withValues(alpha: .14),
                        child: ListTile(
                            leading: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                    color: [
                                      Colors.teal,
                                      Colors.amber,
                                      Colors.indigo
                                    ][i % 3]
                                        .withValues(alpha: .55),
                                    borderRadius: BorderRadius.circular(12))),
                            title: Text('演示内容 ${i + 1}'),
                            subtitle: const Text('滚动文字与色块，观察玻璃背景变化'))))),
            Positioned(
              top: 8,
              left: 16,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    child: Text('实时预览',
                        style: Theme.of(context).textTheme.labelMedium),
                  ),
                ),
              ),
            ),
            Positioned(
                left: 8,
                right: 8,
                bottom: 0,
                child: LiquidGlassBottomBar(
                    selectedIndex: selected,
                    onDestinationSelected: (i) => setState(() => selected = i),
                    destinations: const [
                      LiquidGlassDestination(
                          icon: Icons.home_outlined,
                          selectedIcon: Icons.home,
                          label: '首页'),
                      LiquidGlassDestination(
                          icon: Icons.bookmark_outline,
                          selectedIcon: Icons.bookmark,
                          label: '书架'),
                      LiquidGlassDestination(
                          icon: Icons.dynamic_feed_outlined,
                          selectedIcon: Icons.dynamic_feed,
                          label: '动态'),
                      LiquidGlassDestination(
                          icon: Icons.person_outline,
                          selectedIcon: Icons.person,
                          label: '我的'),
                    ])),
          ])),
      body: ValueListenableBuilder<GlassConfiguration>(
          valueListenable: LKStore.glassConfiguration,
          builder: (context, _, __) {
            final c = LKStore.glassConfigurationFor(MediaQuery.sizeOf(context));
            GlassConfiguration current() =>
                LKStore.glassConfigurationFor(MediaQuery.sizeOf(context));
            final scheme = Theme.of(context).colorScheme;
            return ListView(
              key: const ValueKey('glass-controls'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                  child: Text(
                    '调整悬浮底栏的玻璃效果会自动保存为自定义参数；重置会保存当前设备的默认参数。',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                section(context, '显示行为', Icons.swipe_vertical_rounded, [
                  SwitchListTile(
                    key: const ValueKey('glass-keep-visible-on-scroll'),
                    title: const Text('滚动时保持底栏显示'),
                    subtitle: const Text('关闭后，首页、书架和动态滚动时底栏会随内容收起'),
                    value: c.keepVisibleOnScroll,
                    onChanged: (value) => LKStore.updateGlassConfiguration(
                        current().copyWith(keepVisibleOnScroll: value)),
                  ),
                ]),
                const SizedBox(height: 12),
                section(context, '玻璃效果', Icons.blur_on_rounded, [
                  control(
                      '背景模糊',
                      c.blur,
                      40,
                      (v) => LKStore.updateGlassConfiguration(
                          current().copyWith(blur: v))),
                  control(
                      '底色遮罩',
                      c.tint,
                      1,
                      (v) => LKStore.updateGlassConfiguration(
                          current().copyWith(tint: v))),
                  control(
                      '折射强度',
                      c.refraction,
                      .25,
                      (v) => LKStore.updateGlassConfiguration(
                          current().copyWith(refraction: v)),
                      enabled: supported,
                      hint: supported ? null : '当前渲染引擎不支持折射，将使用普通模糊效果。'),
                  control(
                      '高光强度',
                      c.highlight,
                      1,
                      (v) => LKStore.updateGlassConfiguration(
                          current().copyWith(highlight: v))),
                ]),
                const SizedBox(height: 12),
                section(context, '尺寸与位置', Icons.tune_rounded, [
                  control(
                      '底栏宽度',
                      c.barWidth,
                      360,
                      (v) => LKStore.updateGlassConfiguration(
                          current().copyWith(barWidth: v)),
                      min: c.barWidth < 220 ? c.barWidth : 220),
                  control(
                      '底栏高度',
                      c.barHeight,
                      72,
                      (v) => LKStore.updateGlassConfiguration(
                          current().copyWith(barHeight: v)),
                      min: 40),
                  control(
                      '悬浮高度',
                      c.floatingHeight,
                      48,
                      (v) => LKStore.updateGlassConfiguration(
                          current().copyWith(floatingHeight: v))),
                ]),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.restore),
                  label: const Text('重置悬浮底栏默认参数'),
                  onPressed: () {
                    LKStore.updateGlassConfiguration(
                        GlassConfiguration.defaultsFor(
                            MediaQuery.sizeOf(context)));
                    unawaited(LKStore.flushGlassConfiguration());
                  },
                ),
                const SizedBox(height: 24),
              ],
            );
          }),
    );
  }
}
