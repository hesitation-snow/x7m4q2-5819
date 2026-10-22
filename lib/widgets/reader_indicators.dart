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
