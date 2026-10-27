import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../api/store.dart';
import 'm3_menu_sheet.dart';

/// App-wide theme color presets
const List<(String, Color)> kAppThemeColorPresets = [
  ('默认紫', Color(0xFF5C6BC0)),
  ('湖水青', Color(0xFF009688)),
  ('经典蓝', Color(0xFF2196F3)),
  ('罗兰紫', Color(0xFF7E57C2)),
  ('胭脂粉', Color(0xFFE91E63)),
  ('落叶红', Color(0xFFE64A19)),
  ('琥珀棕', Color(0xFF8D6E63)),
  ('翡翠绿', Color(0xFF388E3C)),
  ('深海蓝', Color(0xFF00838F)),
];

/// Shows the app theme color bottom sheet
Future<void> showAppThemeColorSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => const AppThemeColorSheet(),
  );
}

class AppThemeColorSheet extends StatelessWidget {
  const AppThemeColorSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return const M3MenuSheet(
      title: '配色',
      icon: Icons.colorize_rounded,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: AppThemeColorSection(),
        ),
      ],
    );
  }
}

/// Standalone / inlined theme color section containing preset dots,
/// animated custom color wheel, and tonal palette bar.
class AppThemeColorSection extends StatefulWidget {
  const AppThemeColorSection({super.key});

  @override
  State<AppThemeColorSection> createState() => _AppThemeColorSectionState();
}

class _AppThemeColorSectionState extends State<AppThemeColorSection> {
  late Color _currentColor;
  bool _isCustomColor = false;
  bool _wheelExpanded = false;
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _wheelExpanded =
        false; // Always collapsed by default upon entering settings
    _syncFromStore();
    LKStore.themeSeedColor.addListener(_onStoreColorChanged);
  }

  @override
  void dispose() {
    LKStore.themeSeedColor.removeListener(_onStoreColorChanged);
    super.dispose();
  }

  void _onStoreColorChanged() {
    if (mounted) {
      setState(() {
        _syncFromStore();
      });
    }
  }

  void _syncFromStore() {
    final savedColorValue = LKStore.themeSeedColor.value;
    if (savedColorValue == null) {
      _currentColor = kAppThemeColorPresets[0].$2;
      _isCustomColor = false;
    } else {
      _currentColor = Color(savedColorValue);
      _isCustomColor =
          !kAppThemeColorPresets.any((p) => p.$2.toARGB32() == savedColorValue);
    }
    _hsv = HSVColor.fromColor(_currentColor);
  }

  void _selectPreset(Color color, bool isDefault) {
    setState(() {
      _currentColor = color;
      _isCustomColor = false;
      _wheelExpanded = false; // Collapse wheel on preset selection
      _hsv = HSVColor.fromColor(color);
    });
    LKStore.setThemeSeedColor(isDefault ? null : color.toARGB32());
  }

  void _toggleCustomPicker() {
    setState(() {
      _wheelExpanded = !_wheelExpanded;
      if (_wheelExpanded) {
        _isCustomColor = true;
        LKStore.setThemeSeedColor(_currentColor.toARGB32());
      }
    });
  }

  void _updateWheelColor(Offset localPos, double radius) {
    final dx = localPos.dx - radius;
    final dy = localPos.dy - radius;
    final dist = math.sqrt(dx * dx + dy * dy);
    final sat = (dist / radius).clamp(0.0, 1.0);
    var hue = math.atan2(dy, dx) * 180 / math.pi;
    if (hue < 0) hue += 360;

    final newHsv = HSVColor.fromAHSV(1.0, hue, sat, 0.95);
    setState(() {
      _hsv = newHsv;
      _currentColor = newHsv.toColor();
      _isCustomColor = true;
    });
    LKStore.setThemeSeedColor(_currentColor.toARGB32());
  }

  List<Color> _generateTonalPalette(Color seed) {
    final hsl = HSLColor.fromColor(seed);
    const lightnessSteps = [
      0.93,
      0.84,
      0.74,
      0.64,
      0.54,
      0.44,
      0.35,
      0.26,
      0.18,
      0.10
    ];
    return lightnessSteps.map((l) => hsl.withLightness(l).toColor()).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final savedColorValue = LKStore.themeSeedColor.value;
    final hexString =
        '#${_currentColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Preset colors row with Custom eyedropper button
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              // Default sparkle
              _buildColorCircle(
                color: kAppThemeColorPresets[0].$2,
                isSelected: !_isCustomColor && savedColorValue == null,
                isSparkle: true,
                onTap: () => _selectPreset(kAppThemeColorPresets[0].$2, true),
              ),
              const SizedBox(width: 8),
              // Presets
              for (var i = 1; i < kAppThemeColorPresets.length; i++) ...[
                _buildColorCircle(
                  color: kAppThemeColorPresets[i].$2,
                  isSelected: !_isCustomColor &&
                      savedColorValue == kAppThemeColorPresets[i].$2.toARGB32(),
                  onTap: () =>
                      _selectPreset(kAppThemeColorPresets[i].$2, false),
                ),
                const SizedBox(width: 8),
              ],
              // Eyedropper custom
              _buildCustomPickerCircle(
                isSelected: _isCustomColor || _wheelExpanded,
                scheme: scheme,
                onTap: _toggleCustomPicker,
              ),
            ],
          ),
        ),

        // 2. Color Wheel & Tonal bar smoothly expands when _wheelExpanded is true
        AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          child: _wheelExpanded
              ? Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Column(
                    key: const ValueKey('color-wheel-section'),
                    children: [
                      Center(
                        child: SizedBox(
                          width: 220,
                          height: 220,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final radius = constraints.maxWidth / 2;
                              return RawGestureDetector(
                                gestures: <Type, GestureRecognizerFactory>{
                                  _EagerPanGestureRecognizer:
                                      GestureRecognizerFactoryWithHandlers<
                                          _EagerPanGestureRecognizer>(
                                    () => _EagerPanGestureRecognizer(),
                                    (_EagerPanGestureRecognizer instance) {
                                      instance
                                        ..onDown = (d) {
                                          _updateWheelColor(
                                              d.localPosition, radius);
                                        }
                                        ..onStart = (d) {
                                          _updateWheelColor(
                                              d.localPosition, radius);
                                        }
                                        ..onUpdate = (d) {
                                          _updateWheelColor(
                                              d.localPosition, radius);
                                        };
                                    },
                                  ),
                                },
                                child: CustomPaint(
                                  size: Size(constraints.maxWidth,
                                      constraints.maxHeight),
                                  painter: _ColorWheelPainter(hsv: _hsv),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          hexString,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildTonalPaletteBar(_currentColor),
                      const SizedBox(height: 4),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildColorCircle({
    required Color color,
    required bool isSelected,
    bool isSparkle = false,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: isSelected
              ? Border.all(color: Colors.white, width: 2.5)
              : Border.all(color: Colors.black12, width: 1),
          boxShadow: [
            if (isSelected)
              BoxShadow(
                color: color.withValues(alpha: 0.5),
                blurRadius: 6,
                spreadRadius: 2,
              ),
          ],
        ),
        child: isSparkle
            ? const Icon(Icons.auto_awesome, color: Colors.white, size: 18)
            : isSelected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null,
      ),
    );
  }

  Widget _buildCustomPickerCircle({
    required bool isSelected,
    required ColorScheme scheme,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: isSelected
              ? Border.all(color: scheme.primary, width: 2.5)
              : Border.all(color: Colors.black12, width: 1),
        ),
        child: Icon(
          Icons.colorize_rounded,
          color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
          size: 18,
        ),
      ),
    );
  }

  Widget _buildTonalPaletteBar(Color seed) {
    final tones = _generateTonalPalette(seed);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 24,
        child: Row(
          children: [
            for (var i = 0; i < tones.length; i++)
              Expanded(
                child: ColoredBox(color: tones[i]),
              ),
          ],
        ),
      ),
    );
  }
}

/// Eager pan gesture recognizer that declares immediate victory in the gesture arena,
/// preventing parent ListViews/ScrollViews from stealing vertical touch drags on the color wheel.
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _ColorWheelPainter extends CustomPainter {
  final HSVColor hsv;

  _ColorWheelPainter({required this.hsv});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 1. Hue sweep
    const sweepGradient = SweepGradient(
      colors: [
        Color(0xFFFF0000), // 0
        Color(0xFFFFFF00), // 60
        Color(0xFF00FF00), // 120
        Color(0xFF00FFFF), // 180
        Color(0xFF0000FF), // 240
        Color(0xFFFF00FF), // 300
        Color(0xFFFF0000), // 360
      ],
    );
    final sweepPaint = Paint()..shader = sweepGradient.createShader(rect);
    canvas.drawCircle(center, radius, sweepPaint);

    // 2. Saturation radial gradient (white in center to transparent at edge)
    final radialGradient = RadialGradient(
      colors: [
        Colors.white,
        Colors.white.withValues(alpha: 0.0),
      ],
    );
    final satPaint = Paint()..shader = radialGradient.createShader(rect);
    canvas.drawCircle(center, radius, satPaint);

    // 3. Draw thumb handle
    final rad = hsv.hue * math.pi / 180;
    final dist = hsv.saturation * radius;
    final thumbCenter = Offset(
      center.dx + dist * math.cos(rad),
      center.dy + dist * math.sin(rad),
    );

    final outerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    final innerPaint = Paint()
      ..color = Colors.black45
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawCircle(thumbCenter, 9.0, outerPaint);
    canvas.drawCircle(thumbCenter, 7.0, innerPaint);
  }

  @override
  bool shouldRepaint(_ColorWheelPainter oldDelegate) {
    return oldDelegate.hsv != hsv;
  }
}
