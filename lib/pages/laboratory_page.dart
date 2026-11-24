import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../api/store.dart';
import '../services/app_theme.dart';
import '../services/slider_haptics.dart';
import '../widgets/liquid_glass_bottom_bar.dart';
import '../widgets/m3_controls.dart';

class LaboratoryPage extends StatelessWidget {
  const LaboratoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('实验室')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          MediaQuery.of(context).padding.bottom + 24,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
            child: Text(
              '探索可选功能与界面实验，所有设置均可随时关闭。',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ),
          const AppSectionTitle('功能实验'),
          AppSettingsGroup(
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: LKStore.dailyTreasureEnabled,
                builder: (context, enabled, _) => SwitchListTile(
                  key: const ValueKey('laboratory-daily-treasure-switch'),
                  secondary: const AppSettingIcon(Icons.inventory_2_outlined),
                  title: const Text('每日开宝箱'),
                  value: enabled,
                  onChanged: LKStore.setDailyTreasureEnabled,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: LKStore.allMedalsEnabled,
                builder: (context, enabled, _) => SwitchListTile(
                  key: const ValueKey('laboratory-all-medals-switch'),
                  secondary:
                      const AppSettingIcon(Icons.workspace_premium_outlined),
                  title: const Text('加载勋章商城全部内容'),
                  value: enabled,
                  onChanged: LKStore.setAllMedalsEnabled,
                ),
              ),
            ],
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
  final Map<String, SliderHapticFeedback> _sliderHaptics = {};

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
      {double min = 0, bool enabled = true, String? hint}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isNewHaptics = !_sliderHaptics.containsKey(title);
    final haptics = _sliderHaptics.putIfAbsent(title, SliderHapticFeedback.new);
    if (isNewHaptics) {
      haptics.sync(value, min: min, max: max, continuousNotches: 25);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          '$title：${number(title, value)}',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(hint,
              style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 4),
        SliderTheme(
          data: AppTheme.sliderThemeOf(scheme, theme.textTheme),
          child: Slider(
              key: ValueKey(title),
              value: value,
              min: min,
              max: max,
              label: number(title, value),
              semanticFormatterCallback: (v) => '$title ${number(title, v)}',
              onChangeStart: enabled
                  ? (v) =>
                      haptics.sync(v, min: min, max: max, continuousNotches: 25)
                  : null,
              onChanged: enabled
                  ? (v) {
                      haptics.onChanged(
                        v,
                        min: min,
                        max: max,
                        continuousNotches: 25,
                      );
                      change(v);
                    }
                  : null,
              onChangeEnd: enabled
                  ? (_) => unawaited(LKStore.flushGlassConfiguration())
                  : null),
        ),
      ]),
    );
  }

  Widget section(BuildContext context, String title, IconData icon,
      List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionTitle(title),
        Material(
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .25),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final supported = ui.ImageFilter.isShaderFilterSupported;
    final theme = Theme.of(context);
    final rootScheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('悬浮底栏')),
      bottomNavigationBar: ValueListenableBuilder<GlassConfiguration>(
        valueListenable: LKStore.glassConfiguration,
        builder: (context, config, previewChild) {
          final minPreviewHeight = config.barHeight + config.floatingHeight + 36;
          final targetHeight = (MediaQuery.sizeOf(context).height * .25)
              .clamp(minPreviewHeight, 240.0);
          return SizedBox(height: targetHeight, child: previewChild);
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: rootScheme.surface,
            border: Border(
              top: BorderSide(
                color: rootScheme.outlineVariant.withValues(alpha: .25),
              ),
            ),
          ),
          child: Stack(children: [
            Positioned.fill(
                child: ListView.builder(
                    primary: false,
                    key: const ValueKey('glass-preview-background'),
                    padding: const EdgeInsets.fromLTRB(12, 34, 12, 80),
                    itemCount: 12,
                    itemBuilder: (context, i) {
                      final accents = [
                        (
                          rootScheme.primaryContainer,
                          rootScheme.onPrimaryContainer,
                          '第一卷 · 轻小说阅读样本',
                          '轻文学 · 连载中',
                        ),
                        (
                          rootScheme.secondaryContainer,
                          rootScheme.onSecondaryContainer,
                          '第二卷 · 书架排版效果',
                          '奇幻 · 已收藏',
                        ),
                        (
                          rootScheme.tertiaryContainer,
                          rootScheme.onTertiaryContainer,
                          '第三卷 · 动态视觉示例',
                          '日常 · 最近更新',
                        ),
                      ];
                      final sample = accents[i % accents.length];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: sample.$1.withValues(alpha: .42),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 34,
                                height: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: sample.$1,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.menu_book_rounded,
                                  size: 18,
                                  color: sample.$2,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      sample.$3,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      sample.$4,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: rootScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    })),
            Positioned(
              top: 8,
              left: 16,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: rootScheme.surfaceContainerHighest
                        .withValues(alpha: .92),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: rootScheme.outlineVariant.withValues(alpha: .3),
                    ),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    child: Text('实时预览', style: theme.textTheme.labelSmall),
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
          ]),
        ),
      ),
      body: ValueListenableBuilder<GlassConfiguration>(
          valueListenable: LKStore.glassConfiguration,
          builder: (context, _, __) {
            final c = LKStore.glassConfigurationFor(MediaQuery.sizeOf(context));
            GlassConfiguration current() =>
                LKStore.glassConfigurationFor(MediaQuery.sizeOf(context));
            final scheme = Theme.of(context).colorScheme;
            return ListView(
              key: const ValueKey('glass-controls'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
                  child: Text(
                    '调整悬浮底栏的玻璃效果会自动保存为自定义参数；重置会保存当前设备的默认参数。',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                  ),
                ),
                section(context, '显示行为', Icons.swipe_vertical_rounded, [
                  SwitchListTile(
                    key: const ValueKey('glass-keep-visible-on-scroll'),
                    secondary:
                        const AppSettingIcon(Icons.swipe_vertical_rounded),
                    title: const Text('滚动时保持底栏显示'),
                    subtitle: const Text('关闭后，首页、书架和动态滚动时底栏会随内容收起'),
                    value: c.keepVisibleOnScroll,
                    onChanged: (value) => LKStore.updateGlassConfiguration(
                        current().copyWith(keepVisibleOnScroll: value)),
                  ),
                ]),
                const SizedBox(height: 20),
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
                const SizedBox(height: 20),
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
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.restore_rounded),
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
