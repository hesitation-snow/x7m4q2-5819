import 'package:flutter/material.dart';

/// 十六进制颜色解析工具
/// 支持 #RRGGBB, RRGGBB, #RGB, RGB 以及可选的 8 位十六进制
Color? parseHexColor(String input) {
  var hex = input.trim();
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  }
  // 3 位简写: #RGB -> #RRGGBB
  if (hex.length == 3) {
    final r = hex[0];
    final g = hex[1];
    final b = hex[2];
    hex = '$r$r$g$g$b$b';
  } else if (hex.length == 4) {
    // 4 位简写: #ARGB -> #AARRGGBB
    final a = hex[0];
    final r = hex[1];
    final g = hex[2];
    final b = hex[3];
    hex = '$a$a$r$r$g$g$b$b';
  }

  if (hex.length == 6) {
    final val = int.tryParse(hex, radix: 16);
    if (val != null) {
      return Color(0xFF000000 | val);
    }
  } else if (hex.length == 8) {
    final val = int.tryParse(hex, radix: 16);
    if (val != null) {
      return Color(val);
    }
  }
  return null;
}

/// 格式化为大写十六进制字符串（如 #333333）
String formatHexColor(Color color, {bool leadingHash = true}) {
  final r = ((color.r * 255.0).round().clamp(0, 255))
      .toRadixString(16)
      .padLeft(2, '0')
      .toUpperCase();
  final g = ((color.g * 255.0).round().clamp(0, 255))
      .toRadixString(16)
      .padLeft(2, '0')
      .toUpperCase();
  final b = ((color.b * 255.0).round().clamp(0, 255))
      .toRadixString(16)
      .padLeft(2, '0')
      .toUpperCase();
  return '${leadingHash ? '#' : ''}$r$g$b';
}

/// 常用阅读文字颜色快捷预设
const List<Color> kQuickReadingTextColors = [
  Color(0xFF000000), // 纯黑
  Color(0xFF1F1F1F), // 墨黑
  Color(0xFF333333), // 经典炭黑 (日间白底标配)
  Color(0xFF4A4A4A), // 柔和深灰
  Color(0xFF3D362A), // 复古暗棕 (米黄纸张标配)
  Color(0xFF1E3A2F), // 护眼墨绿
  Color(0xFF1E2D4A), // 静谧暗蓝
  Color(0xFFFFFFFF), // 纯白
  Color(0xFFF7F1E3), // 羊皮纸白
  Color(0xFFE5E7EB), // 浅亮灰
  Color(0xFFC9CDD6), // 银灰 (深灰背景标配)
  Color(0xFF9AA0A6), // 柔灰 (纯黑背景标配)
  Color(0xFFA3B899), // 浅茶绿
  Color(0xFFB0C4DE), // 浅雾蓝
];

/// 颜色面板操作返回结果
class ReaderTextColorResult {
  final bool resetToDefault;
  final Color? color;

  const ReaderTextColorResult.color(Color this.color) : resetToDefault = false;
  const ReaderTextColorResult.reset()
      : resetToDefault = true,
        color = null;
}

/// 弹出阅读器文字颜色面板
Future<ReaderTextColorResult?> showReaderTextColorDialog({
  required BuildContext context,
  required Color initialColor,
  required Color defaultColor,
  required Color backgroundColor,
  bool isCustom = false,
}) {
  return showDialog<ReaderTextColorResult>(
    context: context,
    builder: (ctx) => ReaderTextColorDialog(
      initialColor: initialColor,
      defaultColor: defaultColor,
      backgroundColor: backgroundColor,
      isCustom: isCustom,
    ),
  );
}

/// 阅读器文字颜色设置面板
class ReaderTextColorDialog extends StatefulWidget {
  final Color initialColor;
  final Color defaultColor;
  final Color backgroundColor;
  final bool isCustom;

  const ReaderTextColorDialog({
    super.key,
    required this.initialColor,
    required this.defaultColor,
    required this.backgroundColor,
    this.isCustom = false,
  });

  @override
  State<ReaderTextColorDialog> createState() => _ReaderTextColorDialogState();
}

class _ReaderTextColorDialogState extends State<ReaderTextColorDialog> {
  late Color _currentColor;
  late HSVColor _hsv;
  late TextEditingController _hexController;
  bool _isTextValid = true;
  bool _isResetToDefault = false;

  @override
  void initState() {
    super.initState();
    _currentColor = widget.initialColor;
    _hsv = HSVColor.fromColor(_currentColor);
    _hexController = TextEditingController(text: formatHexColor(_currentColor));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _onColorFromPalette(Color newColor) {
    setState(() {
      _currentColor = newColor;
      _hsv = HSVColor.fromColor(newColor);
      _isResetToDefault = false;
      _isTextValid = true;
      _hexController.text = formatHexColor(newColor);
      _hexController.selection = TextSelection.collapsed(
        offset: _hexController.text.length,
      );
    });
  }

  void _onHsvChanged(HSVColor newHsv) {
    setState(() {
      _hsv = newHsv;
      _currentColor = newHsv.toColor();
      _isResetToDefault = false;
      _isTextValid = true;
      _hexController.text = formatHexColor(_currentColor);
      _hexController.selection = TextSelection.collapsed(
        offset: _hexController.text.length,
      );
    });
  }

  void _onHexTextChanged(String text) {
    final parsed = parseHexColor(text);
    if (parsed != null) {
      setState(() {
        _currentColor = parsed;
        _hsv = HSVColor.fromColor(parsed);
        _isResetToDefault = false;
        _isTextValid = true;
      });
    } else {
      setState(() {
        _isTextValid = false;
      });
    }
  }

  void _resetToDefault() {
    setState(() {
      _currentColor = widget.defaultColor;
      _hsv = HSVColor.fromColor(widget.defaultColor);
      _isResetToDefault = true;
      _isTextValid = true;
      _hexController.text = formatHexColor(widget.defaultColor);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: isDark ? const Color(0xFF23252B) : Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. 标题与重置按钮
              Row(
                children: [
                  const Icon(Icons.palette_outlined, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    '文字颜色',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: _resetToDefault,
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: const Text('恢复默认', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // 2. 实时正文效果预览卡片
              _buildPreviewCard(),
              const SizedBox(height: 10),

              // 3. 2D 饱和度/亮度调色板
              _buildSaturationValueBoard(),
              const SizedBox(height: 8),

              // 4. 色相 Rainbow 滑杆
              _buildHueSlider(),
              const SizedBox(height: 10),

              // 5. 十六进制输入框
              _buildHexInputField(scheme),
              const SizedBox(height: 10),

              // 6. 快捷常用字色
              _buildQuickSwatches(),
              const SizedBox(height: 14),

              // 7. 底部确定与取消按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      if (_isResetToDefault) {
                        Navigator.of(context)
                            .pop(const ReaderTextColorResult.reset());
                      } else {
                        Navigator.of(context).pop(
                          ReaderTextColorResult.color(_currentColor),
                        );
                      }
                    },
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 正文阅读效果预览卡片
  Widget _buildPreviewCard() {
    final hexCode = formatHexColor(_currentColor);
    final isDefault =
        _isResetToDefault || _currentColor == widget.defaultColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.grey.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: _currentColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.8),
                    width: 1,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '效果预览 ($hexCode${isDefault ? ' · 默认' : ''})',
                style: TextStyle(
                  color: _currentColor.withValues(alpha: 0.75),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '落霞与孤鹜齐飞，秋水共长天一色。',
            style: TextStyle(
              color: _currentColor,
              fontSize: 15,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'The quick brown fox jumps over the lazy dog.',
            style: TextStyle(
              color: _currentColor.withValues(alpha: 0.85),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// 2D 饱和度与亮度调色板
  Widget _buildSaturationValueBoard() {
    return SizedBox(
      height: 95,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;

            return GestureDetector(
              onPanDown: (details) {
                _updateSatVal(details.localPosition, w, h);
              },
              onPanUpdate: (details) {
                _updateSatVal(details.localPosition, w, h);
              },
              child: CustomPaint(
                size: Size(w, h),
                painter: _SaturationValuePainter(
                  hue: _hsv.hue,
                  saturation: _hsv.saturation,
                  value: _hsv.value,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _updateSatVal(Offset localPosition, double width, double height) {
    final sat = (localPosition.dx / width).clamp(0.0, 1.0);
    final val = (1.0 - (localPosition.dy / height)).clamp(0.0, 1.0);
    _onHsvChanged(_hsv.withSaturation(sat).withValue(val));
  }

  /// 色相 Rainbow 渐变滑杆
  Widget _buildHueSlider() {
    return SizedBox(
      height: 22,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;

            return GestureDetector(
              onPanDown: (details) {
                _updateHue(details.localPosition, w);
              },
              onPanUpdate: (details) {
                _updateHue(details.localPosition, w);
              },
              child: CustomPaint(
                size: Size(w, h),
                painter: _HueSliderPainter(hue: _hsv.hue),
              ),
            );
          },
        ),
      ),
    );
  }

  void _updateHue(Offset localPosition, double width) {
    final ratio = (localPosition.dx / width).clamp(0.0, 1.0);
    final hue = ratio * 360.0;
    _onHsvChanged(_hsv.withHue(hue.clamp(0.0, 360.0)));
  }

  /// 十六进制输入框
  Widget _buildHexInputField(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _hexController,
                maxLength: 9,
                decoration: InputDecoration(
                  labelText: '十六进制色号',
                  hintText: '#RRGGBB 或 #RGB (如 #333)',
                  counterText: '',
                  prefixIcon: const Icon(Icons.tag_rounded, size: 20),
                  suffixIcon: Container(
                    margin: const EdgeInsets.all(8),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: _isTextValid ? _currentColor : Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _isTextValid
                            ? scheme.outlineVariant
                            : scheme.error,
                        width: 1.5,
                      ),
                    ),
                  ),
                  errorText: _isTextValid
                      ? null
                      : '格式无效，支持 #RRGGBB 或 #RGB (如 #333)',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: _onHexTextChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 快捷预设常用颜色列表
  Widget _buildQuickSwatches() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '推荐常用色',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: kQuickReadingTextColors.map((color) {
            final isSelected = !_isResetToDefault &&
                _currentColor.toARGB32() == color.toARGB32();
            return GestureDetector(
              onTap: () => _onColorFromPalette(color),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey.withValues(alpha: 0.35),
                    width: isSelected ? 2.5 : 1,
                  ),
                  boxShadow: [
                    if (isSelected)
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.35),
                        blurRadius: 4,
                      ),
                  ],
                ),
                child: isSelected
                    ? Icon(
                        Icons.check,
                        size: 16,
                        color: color.computeLuminance() > 0.5
                            ? Colors.black
                            : Colors.white,
                      )
                    : null,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// 饱和度与亮度色板绘制器
class _SaturationValuePainter extends CustomPainter {
  final double hue;
  final double saturation;
  final double value;

  _SaturationValuePainter({
    required this.hue,
    required this.saturation,
    required this.value,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final baseColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();

    // 水平渐变: 白色到纯色
    final horizontalGradient = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [Colors.white, baseColor],
    );
    final horizPaint = Paint()
      ..shader = horizontalGradient.createShader(rect);
    canvas.drawRect(rect, horizPaint);

    // 垂直渐变: 透明到黑色
    const verticalGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.transparent, Colors.black],
    );
    final vertPaint = Paint()
      ..shader = verticalGradient.createShader(rect);
    canvas.drawRect(rect, vertPaint);

    // 绘制指示器手柄
    final thumbX = saturation * size.width;
    final thumbY = (1.0 - value) * size.height;
    final thumbCenter = Offset(thumbX, thumbY);

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final innerPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawCircle(thumbCenter, 7.5, borderPaint);
    canvas.drawCircle(thumbCenter, 6.0, innerPaint);
  }

  @override
  bool shouldRepaint(_SaturationValuePainter oldDelegate) {
    return oldDelegate.hue != hue ||
        oldDelegate.saturation != saturation ||
        oldDelegate.value != value;
  }
}

/// 色相 Rainbow 滑杆绘制器
class _HueSliderPainter extends CustomPainter {
  final double hue;

  static const List<Color> _hueColors = [
    Color(0xFFFF0000), // Red 0°
    Color(0xFFFFFF00), // Yellow 60°
    Color(0xFF00FF00), // Green 120°
    Color(0xFF00FFFF), // Cyan 180°
    Color(0xFF0000FF), // Blue 240°
    Color(0xFFFF00FF), // Magenta 300°
    Color(0xFFFF0000), // Red 360°
  ];

  _HueSliderPainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const gradient = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: _hueColors,
    );

    final bgPaint = Paint()..shader = gradient.createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(size.height / 2)),
      bgPaint,
    );

    // 指示器手柄
    final thumbX = (hue / 360.0).clamp(0.0, 1.0) * size.width;
    final thumbCenter = Offset(thumbX, size.height / 2);

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawCircle(thumbCenter + const Offset(0, 1), 9, shadowPaint);

    final thumbBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(thumbCenter, 9, thumbBorder);

    final currentColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();
    final thumbInner = Paint()..color = currentColor;
    canvas.drawCircle(thumbCenter, 6, thumbInner);
  }

  @override
  bool shouldRepaint(_HueSliderPainter oldDelegate) {
    return oldDelegate.hue != hue;
  }
}
