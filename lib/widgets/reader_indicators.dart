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
  const IndicatorPositionSettings(
      {super.key, required this.value, required this.onChanged});

  Widget _slider(
          String label, double current, double max, ValueChanged<double> change,
          {double min = 0}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label：${current.round()}'),
        Slider(
            key: ValueKey(label),
            value: current.clamp(min, max),
            min: min,
            max: max,
            divisions: (max - min).round(),
            label: current.round().toString(),
            onChanged: change),
      ]);

  @override
  Widget build(BuildContext context) => ExpansionTile(
          title: const Text('指示器位置'),
          subtitle: const Text('仅移动指示器，不改变正文排版；距离从安全区起算'),
          childrenPadding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _IndicatorPreview(position: value),
            const SizedBox(height: 8),
            _slider('顶部距离', value.top, 96,
                (v) => onChanged(value.copyWith(top: v))),
            _slider('底部距离', value.bottom, 96,
                (v) => onChanged(value.copyWith(bottom: v))),
            _slider('左右边距', value.side, 96,
                (v) => onChanged(value.copyWith(side: v))),
            const Text('顶部标题对齐：左 ← 居中 → 右'),
            Slider(
                key: const ValueKey('标题水平对齐'),
                value: value.titleAlignment,
                min: -1,
                max: 1,
                divisions: 2,
                onChanged: (v) => onChanged(value.copyWith(titleAlignment: v))),
            TextButton(
                onPressed: () => onChanged(const IndicatorPosition()),
                child: const Text('恢复默认位置')),
          ]);
}

class _IndicatorPreview extends StatelessWidget {
  final IndicatorPosition position;

  const _IndicatorPreview({required this.position});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    const deviceWidth = 140.0;
    const deviceHeight = 190.0;
    const miniSafeTop = 14.0;
    const miniSafeBottom = 12.0;

    final topOffset =
        miniSafeTop + (position.top.clamp(0.0, 96.0) / 96.0 * 24.0);
    final bottomOffset =
        miniSafeBottom + (position.bottom.clamp(0.0, 96.0) / 96.0 * 20.0);
    final sideOffset = 8.0 + (position.side.clamp(0.0, 96.0) / 96.0 * 18.0);

    final titleAlign = Alignment(
      position.titleAlignment.clamp(-1.0, 1.0),
      -1.0,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.smartphone_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                '屏幕指示器实时预览',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: deviceWidth,
              height: deviceHeight,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E2025) : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark ? Colors.grey.shade700 : Colors.grey.shade400,
                  width: 2.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    // 正文段落模拟线条
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 42),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            for (var w in [1.0, 0.9, 0.85, 0.95, 0.6])
                              FractionallySizedBox(
                                widthFactor: w,
                                child: Container(
                                  height: 3,
                                  decoration: BoxDecoration(
                                    color: (isDark
                                            ? Colors.white
                                            : Colors.black)
                                        .withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // 顶部刘海 / 挖孔条
                    Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        margin: const EdgeInsets.only(top: 4),
                        width: 26,
                        height: 4,
                        decoration: BoxDecoration(
                          color: isDark ? Colors.black : Colors.grey.shade800,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),

                    // 顶部章节标题指示器
                    Positioned(
                      top: topOffset,
                      left: sideOffset,
                      right: sideOffset,
                      child: Align(
                        alignment: titleAlign,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '第一章 标题',
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 底部时间与阅读进度指示器
                    Positioned(
                      bottom: bottomOffset,
                      left: sideOffset,
                      right: sideOffset,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 3, vertical: 1),
                            decoration: BoxDecoration(
                              color: scheme.onSurface.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '12:34',
                              style: TextStyle(
                                fontSize: 7,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 3, vertical: 1),
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '45.0%',
                              style: TextStyle(
                                fontSize: 7,
                                fontWeight: FontWeight.bold,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // 底部手势小横条
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 3),
                        width: 32,
                        height: 2.5,
                        decoration: BoxDecoration(
                          color: (isDark ? Colors.white : Colors.black)
                              .withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
