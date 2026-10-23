import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../reader/indicator_position.dart';

/// Paint-only overlay: never changes body constraints or pagination.
class ReaderIndicators extends StatelessWidget {
  final IndicatorPosition position;
  final String title;
  final Widget progress;
  final Widget? deviceStatus;
  const ReaderIndicators(
      {super.key,
      required this.position,
      required this.title,
      required this.progress,
      this.deviceStatus});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final safe = EdgeInsets.fromLTRB(
        math.max(media.padding.left, media.viewPadding.left),
        math.max(media.padding.top, media.viewPadding.top),
        math.max(media.padding.right, media.viewPadding.right),
        math.max(media.padding.bottom, media.viewPadding.bottom));
    return IgnorePointer(
        child: Padding(
            padding: safe,
            child: LayoutBuilder(builder: (context, constraints) {
              final top = IndicatorPosition.bounded(
                  position.top, constraints.maxHeight / 4);
              final bottom = IndicatorPosition.bounded(
                  position.bottom, constraints.maxHeight / 4);
              final side = IndicatorPosition.bounded(
                  position.side, constraints.maxWidth / 4);
              return Padding(
                  padding: EdgeInsets.fromLTRB(side, top, side, bottom),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                            child: Align(
                                alignment: Alignment(
                                    IndicatorPosition.bounded(
                                        position.titleAlignment, 1, -1),
                                    -1),
                                child: Text(title,
                                    key: const ValueKey(
                                        'reader-indicator-title'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis))),
                        Flexible(
                            child: Align(
                                alignment: Alignment.bottomCenter,
                                child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      if (deviceStatus != null)
                                        Expanded(
                                            child: Align(
                                                alignment: Alignment.bottomLeft,
                                                child: FittedBox(
                                                    fit: BoxFit.scaleDown,
                                                    child: deviceStatus!)))
                                      else
                                        const Spacer(),
                                      const SizedBox(width: 8),
                                      Expanded(
                                          child: Align(
                                              alignment: Alignment.bottomRight,
                                              child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  child: progress))),
                                    ]))),
                      ]));
            })));
  }
}

class IndicatorPositionSettings extends StatelessWidget {
  final IndicatorPosition value;
  final ValueChanged<IndicatorPosition> onChanged;
  final VoidCallback? onEnterEditMode;

  const IndicatorPositionSettings({
    super.key,
    required this.value,
    required this.onChanged,
    this.onEnterEditMode,
  });

  Widget _slider(
          String label, double current, double max, ValueChanged<double> change,
          {double min = 0}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label：${current.round()} dp'),
        Slider(
            key: ValueKey(label),
            value: current.clamp(min, max),
            min: min,
            max: max,
            divisions: (max - min).round(),
            label: '${current.round()} dp',
            semanticFormatterCallback: (v) => '$label ${v.round()} dp',
            onChanged: change),
      ]);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      title: const Text('指示器位置'),
      subtitle: Text(
          '顶部：${value.top.round()} dp · 底部：${value.bottom.round()} dp · 边距：${value.side.round()} dp'),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        if (onEnterEditMode != null) ...[
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: onEnterEditMode,
              icon: const Icon(Icons.open_with_rounded, size: 20),
              label: const Text('全屏可视化拖动调整'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '直接在真机阅读画面上拖动微调，精准避开刘海与挖孔屏',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
        ],
        _slider(
            '顶部距离', value.top, 96, (v) => onChanged(value.copyWith(top: v))),
        _slider('底部距离', value.bottom, 96,
            (v) => onChanged(value.copyWith(bottom: v))),
        _slider(
            '左右边距', value.side, 96, (v) => onChanged(value.copyWith(side: v))),
        const Text('顶部标题对齐：左 ← 居中 → 右'),
        Slider(
            key: const ValueKey('标题水平对齐'),
            value: value.titleAlignment,
            min: -1,
            max: 1,
            divisions: 2,
            onChanged: (v) => onChanged(value.copyWith(titleAlignment: v))),
        TextButton.icon(
            icon: const Icon(Icons.restart_alt),
            onPressed: () => onChanged(const IndicatorPosition()),
            label: const Text('恢复默认位置')),
      ],
    );
  }
}

/// 全屏指示器编辑交互浮层：直接在真实阅读画面上拖拽与微调
class IndicatorEditOverlay extends StatefulWidget {
  final IndicatorPosition position;
  final String title;
  final Widget progress;
  final Widget? deviceStatus;
  final ValueChanged<IndicatorPosition> onChanged;
  final VoidCallback onSave;
  final VoidCallback onCancel;
  final VoidCallback onReset;

  const IndicatorEditOverlay({
    super.key,
    required this.position,
    required this.title,
    required this.progress,
    this.deviceStatus,
    required this.onChanged,
    required this.onSave,
    required this.onCancel,
    required this.onReset,
  });

  @override
  State<IndicatorEditOverlay> createState() => _IndicatorEditOverlayState();
}

class _IndicatorEditOverlayState extends State<IndicatorEditOverlay> {
  // 当前微调选择的目标：0 = 顶部标题, 1 = 底部信息, 2 = 左右边距
  int _selectedTarget = 0;
  bool _controlBarAtTop = false;

  void _step(int delta) {
    final current = widget.position;
    if (_selectedTarget == 0) {
      final next = (current.top + delta).clamp(0.0, 96.0);
      widget.onChanged(current.copyWith(top: next));
    } else if (_selectedTarget == 1) {
      final next = (current.bottom + delta).clamp(0.0, 96.0);
      widget.onChanged(current.copyWith(bottom: next));
    } else {
      final next = (current.side + delta).clamp(0.0, 96.0);
      widget.onChanged(current.copyWith(side: next));
    }
  }

  void _setAlignment(double align) {
    widget.onChanged(widget.position.copyWith(titleAlignment: align));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final safe = EdgeInsets.fromLTRB(
      math.max(media.padding.left, media.viewPadding.left),
      math.max(media.padding.top, media.viewPadding.top),
      math.max(media.padding.right, media.viewPadding.right),
      math.max(media.padding.bottom, media.viewPadding.bottom),
    );

    final position = widget.position;

    return Material(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 半透明防护蒙层（阻止底层翻页或菜单手势）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(
              color: (isDark ? Colors.black : Colors.black)
                  .withValues(alpha: 0.15),
            ),
          ),

          // 2. 状态栏与底部安全区参考虚线
          Positioned(
            top: safe.top,
            left: 0,
            right: 0,
            child: _safeBoundaryLine('系统安全区顶部 (系统栏/刘海)', scheme),
          ),
          Positioned(
            bottom: safe.bottom,
            left: 0,
            right: 0,
            child: _safeBoundaryLine('系统安全区底部 (手势横条)', scheme),
          ),

          // 3. 顶部指示器（标题），支持直接上下/左右拖拽
          Positioned(
            top: safe.top + position.top,
            left: safe.left + position.side,
            right: safe.right + position.side,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _selectedTarget = 0),
              onPanUpdate: (details) {
                setState(() => _selectedTarget = 0);
                final dy = details.delta.dy;
                final dx = details.delta.dx;
                final newTop = (position.top + dy).clamp(0.0, 96.0);
                var newAlign =
                    (position.titleAlignment + dx / 120.0).clamp(-1.0, 1.0);
                if (newAlign.abs() < 0.12) {
                  newAlign = 0.0;
                } else if (newAlign < -0.85) {
                  newAlign = -1.0;
                } else if (newAlign > 0.85) {
                  newAlign = 1.0;
                }
                widget.onChanged(
                    position.copyWith(top: newTop, titleAlignment: newAlign));
              },
              child: Align(
                alignment: Alignment(
                  IndicatorPosition.bounded(position.titleAlignment, 1, -1),
                  0,
                ),
                child: _editableBox(
                  isSelected: _selectedTarget == 0,
                  label: '标题 · 可直接拖拽',
                  scheme: scheme,
                  child: Text(
                    widget.title,
                    key: const ValueKey('reader-indicator-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 4. 底部指示器（时间与进度），支持直接上下拖拽
          Positioned(
            bottom: safe.bottom + position.bottom,
            left: safe.left + position.side,
            right: safe.right + position.side,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _selectedTarget = 1),
              onPanUpdate: (details) {
                setState(() => _selectedTarget = 1);
                final dy = details.delta.dy;
                // 向上拖拽手指，提高底部距离
                final newBottom = (position.bottom - dy).clamp(0.0, 96.0);
                widget.onChanged(position.copyWith(bottom: newBottom));
              },
              child: _editableBox(
                isSelected: _selectedTarget == 1,
                label: '底部信息 · 可直接拖拽',
                scheme: scheme,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (widget.deviceStatus != null)
                      widget.deviceStatus!
                    else
                      Text('12:34',
                          style:
                              TextStyle(fontSize: 11, color: scheme.primary)),
                    widget.progress,
                  ],
                ),
              ),
            ),
          ),

          // 5. 悬浮微调与控制面板（支持切换停靠顶部或底部，避免遮挡）
          Positioned(
            top: _controlBarAtTop ? safe.top + 50 : null,
            bottom: _controlBarAtTop ? null : safe.bottom + 40,
            left: 16,
            right: 16,
            child: _buildControlCard(context, scheme, position),
          ),
        ],
      ),
    );
  }

  Widget _safeBoundaryLine(String label, ColorScheme scheme) {
    return IgnorePointer(
      child: Container(
        height: 1,
        color: scheme.error.withValues(alpha: 0.4),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(fontSize: 9, color: scheme.onErrorContainer),
            ),
          ),
        ),
      ),
    );
  }

  Widget _editableBox({
    required bool isSelected,
    required String label,
    required ColorScheme scheme,
    required Widget child,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isSelected
            ? scheme.primaryContainer.withValues(alpha: 0.45)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected ? scheme.primary : scheme.outlineVariant,
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.open_with_rounded,
                  size: 11,
                  color: isSelected ? scheme.primary : scheme.outline),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
  }

  Widget _buildControlCard(
      BuildContext context, ColorScheme scheme, IndicatorPosition pos) {
    final targetName = switch (_selectedTarget) {
      0 => '顶部',
      1 => '底部',
      _ => '边距',
    };
    final targetValue = switch (_selectedTarget) {
      0 => '${pos.top.round()} dp',
      1 => '${pos.bottom.round()} dp',
      _ => '${pos.side.round()} dp',
    };

    return Card(
      elevation: 6,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一行：目标项选择 Segment + 调转面板位置按钮
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<int>(
                    segments: [
                      ButtonSegment(
                        value: 0,
                        label: Text('顶部 (${pos.top.round()})',
                            style: const TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: 1,
                        label: Text('底部 (${pos.bottom.round()})',
                            style: const TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: 2,
                        label: Text('边距 (${pos.side.round()})',
                            style: const TextStyle(fontSize: 11)),
                      ),
                    ],
                    selected: {_selectedTarget},
                    onSelectionChanged: (set) =>
                        setState(() => _selectedTarget = set.first),
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: _controlBarAtTop ? '移到底部' : '移到顶部',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _controlBarAtTop = !_controlBarAtTop),
                  icon: Icon(
                      _controlBarAtTop
                          ? Icons.vertical_align_bottom_rounded
                          : Icons.vertical_align_top_rounded,
                      size: 18),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 第二行：精确 1dp / 5dp 微调按钮群
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('$targetName：',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold)),
                Text(targetValue,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: scheme.primary)),
                const SizedBox(width: 8),
                _stepButton('-5', () => _step(-5)),
                const SizedBox(width: 4),
                _stepButton('-1', () => _step(-1)),
                const SizedBox(width: 4),
                _stepButton('+1', () => _step(1)),
                const SizedBox(width: 4),
                _stepButton('+5', () => _step(5)),
              ],
            ),

            if (_selectedTarget == 0) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('标题对齐：', style: TextStyle(fontSize: 12)),
                  _alignChip('居左', -1.0, pos.titleAlignment <= -0.5),
                  const SizedBox(width: 6),
                  _alignChip('居中', 0.0, pos.titleAlignment.abs() < 0.5),
                  const SizedBox(width: 6),
                  _alignChip('居右', 1.0, pos.titleAlignment >= 0.5),
                ],
              ),
            ],

            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // 第三行：操作按钮（重置、取消、保存）
            Row(
              children: [
                TextButton.icon(
                  onPressed: widget.onReset,
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('默认', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: widget.onCancel,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    minimumSize: const Size(60, 34),
                  ),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: widget.onSave,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    minimumSize: const Size(68, 34),
                  ),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepButton(String text, VoidCallback onPressed) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        minimumSize: const Size(36, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _alignChip(String label, double align, bool isSelected) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: isSelected,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => _setAlignment(align),
      padding: EdgeInsets.zero,
    );
  }
}
