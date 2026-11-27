import 'package:flutter/material.dart';

import '../services/app_theme.dart';
import '../services/slider_haptics.dart';
import 'm3_controls.dart';

/// Listening controls stay reachable while voice settings scroll.
class ReaderListeningSheet extends StatelessWidget {
  const ReaderListeningSheet(
      {super.key,
      required this.content,
      required this.controls,
      required this.onClose});
  final Widget content;
  final Widget controls;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .92),
        child: Material(
          color: scheme.surface,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 8),
            ExcludeSemantics(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(children: [
                const AppSettingIcon(Icons.headphones_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('听书', style: theme.textTheme.titleMedium),
                      Text('退出阅读后仍会继续播放',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '收起面板',
                  onPressed: onClose,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                key: const ValueKey('listening-settings-scroll'),
                padding: EdgeInsets.fromLTRB(
                    16, 4, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
                child: content,
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: .35)),
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: controls,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class ListeningSourcePicker extends StatelessWidget {
  const ListeningSourcePicker(
      {super.key,
      required this.value,
      required this.onChanged,
      this.enabled = true});
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  static const _sources = [
    ('online', '在线自然音', '免密钥，中日韩自动切换音色', Icons.cloud_outlined),
    ('system', '系统引擎', '使用手机已安装的本地语音', Icons.phone_android_rounded),
    ('custom', '自定义', 'Azure 或自定义 SSML 接口', Icons.tune_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeSource = _sources.firstWhere(
      (item) => item.$1 == value,
      orElse: () => _sources.first,
    );
    return LayoutBuilder(builder: (context, constraints) {
      final compactList = constraints.maxWidth < 300 ||
          MediaQuery.textScalerOf(context).scale(14) > 18;
      if (compactList) {
        return AppSettingsGroup(
          children: [
            for (final source in _sources)
              Semantics(
                selected: value == source.$1,
                button: true,
                child: ListTile(
                  key: ValueKey('listening-source-${source.$1}'),
                  enabled: enabled,
                  leading: AppSettingIcon(source.$4),
                  title: Text(source.$2),
                  subtitle: Text(source.$3),
                  trailing: Icon(
                    value == source.$1
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color:
                        value == source.$1 ? scheme.primary : scheme.outline,
                    size: 20,
                  ),
                  onTap: !enabled ? null : () => onChanged(source.$1),
                ),
              ),
          ],
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .25),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  for (final source in _sources)
                    Expanded(
                      child: Semantics(
                        selected: value == source.$1,
                        button: true,
                        child: Material(
                          color: value == source.$1
                              ? scheme.secondaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: ValueKey('listening-source-${source.$1}'),
                            onTap: !enabled ? null : () => onChanged(source.$1),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 10,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    source.$4,
                                    size: 20,
                                    color: value == source.$1
                                        ? scheme.onSecondaryContainer
                                        : scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    source.$2,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium?.copyWith(
                                      fontWeight: value == source.$1
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: value == source.$1
                                          ? scheme.onSecondaryContainer
                                          : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: Text(
              activeSource.$3,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    });
  }
}

class ListeningPlaybackCard extends StatelessWidget {
  const ListeningPlaybackCard(
      {super.key,
      required this.title,
      required this.status,
      required this.position,
      required this.segmentCount,
      this.text,
      this.loading = false,
      this.hasError = false});
  final String title;
  final String status;
  final int position;
  final int segmentCount;
  final String? text;
  final bool loading;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('listening-now-playing'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: hasError ? colors.errorContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: hasError
              ? colors.error.withValues(alpha: .35)
              : colors.outlineVariant.withValues(alpha: .35),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: theme.textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(
              hasError ? Icons.error_outline_rounded : Icons.graphic_eq_rounded,
              size: 18,
              color: hasError ? colors.onErrorContainer : colors.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(status,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: hasError ? colors.onErrorContainer : colors.onSurface,
                    fontWeight: FontWeight.w600,
                  )),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Text(text ?? '从当前阅读位置开始朗读',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: colors.onSurface, height: 1.45)),
        if (!loading && status.startsWith('已暂停')) ...[
          const SizedBox(height: 8),
          Text('暂停后从当前语段开头恢复',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant)),
        ],
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            minHeight: 4,
            value: loading
                ? null
                : segmentCount == 0
                    ? 0
                    : ((position + 1) / segmentCount).clamp(0, 1),
            semanticsLabel: loading ? '正在准备语音' : '语段进度',
            backgroundColor: colors.surfaceContainerHighest,
          ),
        ),
      ]),
    );
  }
}

class ListeningSection extends StatelessWidget {
  const ListeningSection({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSectionTitle(title),
            child,
          ],
        ),
      );
}

/// Rate control used by both settings and the reader listening sheet.
class ListeningRateControl extends StatefulWidget {
  const ListeningRateControl({
    super.key,
    required this.rate,
    required this.onChanged,
    this.onChangeEnd,
  });

  static const _minRate = 0.5;
  static const _maxRate = 3.0;
  static const _step = 0.1;
  static const _divisions = 25;
  static const _presets = <double>[0.8, 1.0, 1.2, 1.5, 2.0];

  final double rate;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<ListeningRateControl> createState() => _ListeningRateControlState();
}

class _ListeningRateControlState extends State<ListeningRateControl> {
  final SliderHapticFeedback _haptics = SliderHapticFeedback();

  @override
  void initState() {
    super.initState();
    _syncHaptics(widget.rate);
  }

  @override
  void didUpdateWidget(ListeningRateControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.rate != oldWidget.rate) {
      _syncHaptics(widget.rate);
    }
  }

  void _syncHaptics(double value) {
    _haptics.sync(
      value.clamp(ListeningRateControl._minRate, ListeningRateControl._maxRate)
          .toDouble(),
      min: ListeningRateControl._minRate,
      max: ListeningRateControl._maxRate,
      divisions: ListeningRateControl._divisions,
    );
  }

  void _stepBy(double delta, double current) {
    final next = (((current + delta) * 10).round() / 10)
        .clamp(ListeningRateControl._minRate, ListeningRateControl._maxRate)
        .toDouble();
    if ((next - current).abs() < 0.001) return;
    SliderHapticFeedback.tick();
    _syncHaptics(next);
    widget.onChanged(next);
    widget.onChangeEnd?.call(next);
  }

  Widget _stepButton({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        fixedSize: const Size(44, 44),
        padding: EdgeInsets.zero,
        backgroundColor: enabled
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerHigh.withValues(alpha: 0.45),
        foregroundColor: enabled
            ? scheme.onSurfaceVariant
            : scheme.onSurfaceVariant.withValues(alpha: 0.35),
      ),
      icon: Icon(icon, size: 18),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = widget.rate
        .clamp(ListeningRateControl._minRate, ListeningRateControl._maxRate)
        .toDouble();
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .25)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const AppSettingIcon(Icons.speed_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '朗读语速',
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${shown.toStringAsFixed(2)}×',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(
              children: [
                _stepButton(
                  context: context,
                  icon: Icons.remove_rounded,
                  tooltip: '减速',
                  onPressed: shown > ListeningRateControl._minRate + 0.001
                      ? () => _stepBy(-ListeningRateControl._step, shown)
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SliderTheme(
                    data: AppTheme.sliderThemeOf(
                      scheme,
                      theme.textTheme,
                      trackHeight: 14,
                      thumbHeight: 34,
                    ),
                    child: Slider(
                      min: ListeningRateControl._minRate,
                      max: ListeningRateControl._maxRate,
                      divisions: ListeningRateControl._divisions,
                      value: shown,
                      label: '${shown.toStringAsFixed(2)}×',
                      onChangeStart: (value) => _haptics.sync(
                        value,
                        min: ListeningRateControl._minRate,
                        max: ListeningRateControl._maxRate,
                        divisions: ListeningRateControl._divisions,
                      ),
                      onChanged: (value) {
                        _haptics.onChanged(
                          value,
                          min: ListeningRateControl._minRate,
                          max: ListeningRateControl._maxRate,
                          divisions: ListeningRateControl._divisions,
                        );
                        widget.onChanged(value);
                      },
                      onChangeEnd: widget.onChangeEnd,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _stepButton(
                  context: context,
                  icon: Icons.add_rounded,
                  tooltip: '加速',
                  onPressed: shown < ListeningRateControl._maxRate - 0.001
                      ? () => _stepBy(ListeningRateControl._step, shown)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final preset in ListeningRateControl._presets)
                  M3ChoiceChip(
                    label: '${preset.toStringAsFixed(1)}×',
                    selected: (shown - preset).abs() < 0.03,
                    onSelected: (_) {
                      if ((shown - preset).abs() >= 0.001) {
                        SliderHapticFeedback.tick();
                      }
                      _syncHaptics(preset);
                      widget.onChanged(preset);
                      widget.onChangeEnd?.call(preset);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
