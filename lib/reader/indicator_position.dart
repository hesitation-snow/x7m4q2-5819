/// Indicator offsets and font sizing are independent of body typography.
class IndicatorPosition {
  final double top;
  final double bottom;
  final double side;
  final double titleAlignment;
  final double topFontSize;
  final double bottomFontSize;

  const IndicatorPosition({
    this.top = 6,
    this.bottom = 8,
    this.side = 16,
    this.titleAlignment = 0,
    this.topFontSize = 11,
    this.bottomFontSize = 11,
  });

  static double bounded(double value, double max, [double min = 0]) =>
      value.isFinite ? value.clamp(min, max).toDouble() : min;

  IndicatorPosition copyWith({
    double? top,
    double? bottom,
    double? side,
    double? titleAlignment,
    double? topFontSize,
    double? bottomFontSize,
  }) =>
      IndicatorPosition(
        top: bounded(top ?? this.top, 96),
        bottom: bounded(bottom ?? this.bottom, 96),
        side: bounded(side ?? this.side, 96),
        titleAlignment: bounded(titleAlignment ?? this.titleAlignment, 1, -1),
        topFontSize: bounded(topFontSize ?? this.topFontSize, 20, 8),
        bottomFontSize: bounded(bottomFontSize ?? this.bottomFontSize, 20, 8),
      );
}
