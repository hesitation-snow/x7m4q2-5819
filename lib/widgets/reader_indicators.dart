import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../reader/indicator_position.dart';
import 'm3_controls.dart';

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
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: position.topFontSize)))),
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
                                                    child:
                                                        DefaultTextStyle.merge(
                                                      style: TextStyle(
                                                          fontSize: position
                                                              .bottomFontSize),
                                                      child: deviceStatus!,
                                                    ))))
                                      else
                                        const Spacer(),
                                      const SizedBox(width: 8),
                                      Expanded(
                                          child: Align(
                                              alignment: Alignment.bottomRight,
                                              child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  child: DefaultTextStyle.merge(
                                                    style: TextStyle(
                                                        fontSize: position
                                                            .bottomFontSize),
                                                    child: progress,
                                                  )))),
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

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: const AppSettingIcon(Icons.open_with_rounded),
      title: const Text('调整指示器位置'),
      subtitle: const Text('在阅读画面中拖动调整位置与字号'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onEnterEditMode,
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
  // 当前微调选择的目标：0 = 顶部, 1 = 底部
  int _selectedTarget = 0;

  void _stepDistance(int delta) {
    final current = widget.position;
    if (_selectedTarget == 0) {
      final next = (current.top + delta).clamp(0.0, 96.0);
      widget.onChanged(current.copyWith(top: next));
    } else {
      final next = (current.bottom + delta).clamp(0.0, 96.0);
      widget.onChanged(current.copyWith(bottom: next));
    }
  }

  void _stepSide(int delta) {
    final current = widget.position;
    final next = (current.side + delta).clamp(0.0, 96.0);
    widget.onChanged(current.copyWith(side: next));
  }

  void _stepFontSize(int delta) {
    final current = widget.position;
    if (_selectedTarget == 0) {
      final next = (current.topFontSize + delta).clamp(8.0, 20.0);
      widget.onChanged(current.copyWith(topFontSize: next));
    } else if (_selectedTarget == 1) {
      final next = (current.bottomFontSize + delta).clamp(8.0, 20.0);
      widget.onChanged(current.copyWith(bottomFontSize: next));
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
                      fontSize: position.topFontSize,
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
                      DefaultTextStyle.merge(
                        style: TextStyle(fontSize: position.bottomFontSize),
                        child: widget.deviceStatus!,
                      )
                    else
                      Text('12:34',
                          style: TextStyle(
                              fontSize: position.bottomFontSize,
                              color: scheme.primary)),
                    DefaultTextStyle.merge(
                      style: TextStyle(fontSize: position.bottomFontSize),
                      child: widget.progress,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 5. 居中微调面板；大字体下内部滚动，不撑开正文布局。
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 560,
                  maxHeight: (media.size.height - safe.vertical) * .65,
                ),
                child: _buildControlCard(context, scheme, position),
              ),
            ),
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
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight:
                        isSelected ? FontWeight.bold : FontWeight.normal,
                    color:
                        isSelected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
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
    return Card(
      elevation: 4,
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  for (final (index, target)
                      in [(0, '顶部'), (1, '底部')].indexed) ...[
                    if (index > 0) const SizedBox(width: 8),
                    Expanded(
                      child: M3ChoiceChip(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        label: target.$2,
                        selected: _selectedTarget == target.$1,
                        onSelected: (_) =>
                            setState(() => _selectedTarget = target.$1),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                _selectedTarget == 0
                    ? '顶部距离：${pos.top.round()} dp'
                    : '底部距离：${pos.bottom.round()} dp',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 4,
                children: [
                  _stepButton('-5', () => _stepDistance(-5)),
                  _stepButton('-1', () => _stepDistance(-1)),
                  _stepButton('+1', () => _stepDistance(1)),
                  _stepButton('+5', () => _stepDistance(5)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _selectedTarget == 0
                    ? '顶部字号：${pos.topFontSize.round()} sp'
                    : '底部字号：${pos.bottomFontSize.round()} sp',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 4,
                children: [
                  _stepButton('-1', () => _stepFontSize(-1)),
                  _stepButton('+1', () => _stepFontSize(1)),
                ],
              ),
              if (_selectedTarget == 0) ...[
                const SizedBox(height: 8),
                Text('标题对齐',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (final (index, align) in [
                      ('居左', -1.0, pos.titleAlignment <= -0.5),
                      ('居中', 0.0, pos.titleAlignment.abs() < 0.5),
                      ('居右', 1.0, pos.titleAlignment >= 0.5),
                    ].indexed) ...[
                      if (index > 0) const SizedBox(width: 8),
                      Expanded(
                        child: M3ChoiceChip(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          label: align.$1,
                          selected: align.$3,
                          onSelected: (_) => _setAlignment(align.$2),
                        ),
                      ),
                    ],
                  ],
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  '左右边距：${pos.side.round()} dp',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  children: [
                    _stepButton('-5', () => _stepSide(-5)),
                    _stepButton('-1', () => _stepSide(-1)),
                    _stepButton('+1', () => _stepSide(1)),
                    _stepButton('+5', () => _stepSide(5)),
                  ],
                ),
              ],
              const Divider(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: widget.onReset,
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('默认'),
                  ),
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: widget.onSave,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepButton(String text, VoidCallback onPressed) {
    return FilledButton.tonal(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: const StadiumBorder(),
        textStyle: Theme.of(context).textTheme.labelMedium,
      ),
      child: Text(text),
    );
  }
}
