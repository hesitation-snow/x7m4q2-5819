import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../api/store.dart';
import '../services/app_motion.dart';
import 'liquid_glass_math.dart';

class _GlassGlint extends CustomPainter {
  const _GlassGlint(this.dark, this.strength);
  final double strength;
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.10, size.height * 0.32)
      ..quadraticBezierTo(size.width * 0.18, 1, size.width * 0.42, 1)
      ..lineTo(size.width * 0.68, 1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..shader = ui.Gradient.linear(Offset.zero, Offset(size.width * 0.7, 0), [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: (dark ? 0.38 : 0.72) * strength),
        Colors.white.withValues(alpha: 0),
      ], const [
        0,
        0.45,
        1
      ]);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_GlassGlint oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.strength != strength;
}

/// Clips the low-alpha prepainted selected glyph to the moving glass capsule.
/// ClipPath uses a retained clip layer only; the ghost is not wrapped in an
/// opacity/saveLayer that could rebase the root-pass shader coordinates.
class _GlassSamplingClipper extends CustomClipper<Path> {
  const _GlassSamplingClipper(this.rect, this.radius);

  final Rect rect;
  final double radius;

  @override
  Path getClip(Size size) =>
      Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));

  @override
  bool shouldReclip(covariant _GlassSamplingClipper oldClipper) =>
      oldClipper.rect != rect || oldClipper.radius != radius;
}

// Coordinates are populated at PAINT, not from a previous frame's layout.
// The engine's input is a full render-pass texture, NOT a 292x50 clip texture.
// This component targets the root Scaffold pass. Known ancestor saveLayers use
// ordinary blur; the shader also guards mismatched input/view texture sizes.
class _RootGlassBackdrop extends SingleChildRenderObjectWidget {
  const _RootGlassBackdrop(
      {super.key,
      required this.shader,
      required this.optics,
      required this.lens,
      required this.pressed,
      required this.deformation,
      required this.fraction,
      required this.view,
      required super.child});
  final GlassConfiguration optics;
  final ui.FragmentShader shader;
  final Rect lens;
  final bool pressed;
  final double deformation;
  final double fraction;
  final ui.FlutterView view;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRootGlass(this);
  @override
  void updateRenderObject(
      BuildContext context, covariant _RenderRootGlass renderObject) {
    renderObject.configuration = this;
  }
}

class _RenderRootGlass extends RenderProxyBox {
  _RenderRootGlass(this._configuration);
  _RootGlassBackdrop _configuration;
  set configuration(_RootGlassBackdrop value) {
    final prev = _configuration;
    if (prev.optics == value.optics &&
        identical(prev.shader, value.shader) &&
        prev.lens == value.lens &&
        prev.pressed == value.pressed &&
        prev.deformation == value.deformation &&
        prev.fraction == value.fraction &&
        identical(prev.view, value.view)) {
      return;
    }
    _configuration = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;
  @override
  void paint(PaintingContext context, Offset offset) {
    final c = _configuration;
    final sigma = c.optics.blur * c.fraction;
    final dpr = c.view.devicePixelRatio;
    final transform = getTransformTo(null);
    final center = MatrixUtils.transformPoint(transform, c.lens.center) * dpr;
    final bounds = MatrixUtils.transformRect(transform, c.lens);
    bool rootPass = true;
    RenderObject? ancestor = parent;
    while (ancestor != null) {
      if ((ancestor is RenderOpacity && ancestor.opacity < 1) ||
          (ancestor is RenderAnimatedOpacity && ancestor.opacity.value < 1) ||
          ancestor is RenderShaderMask ||
          ancestor is RenderBackdropFilter) {
        rootPass = false;
        break;
      }
      ancestor = ancestor.parent;
    }
    // Avoid assuming axis-aligned lens bounds under arbitrary ancestor rotation.
    if (transform.storage[1].abs() > 0.0001 ||
        transform.storage[4].abs() > 0.0001) {
      rootPass = false;
    }
    final useRefraction = rootPass && c.optics.refraction > 0 && c.fraction > 0;
    if (sigma <= 0 && !useRefraction) {
      super.paint(context, offset);
      return;
    }
    final ui.ImageFilter filter;
    if (useRefraction) {
      final shader = c.shader
        ..setFloat(2, center.dx)
        ..setFloat(3, center.dy)
        ..setFloat(4, bounds.width * dpr / 2)
        ..setFloat(5, bounds.height * dpr / 2)
        ..setFloat(6, c.pressed ? 1 : 0)
        ..setFloat(7, c.fraction)
        ..setFloat(8, c.view.physicalSize.width)
        ..setFloat(9, c.view.physicalSize.height)
        ..setFloat(10, c.optics.refraction)
        ..setFloat(11, math.min(bounds.width, bounds.height) * dpr / 2)
        ..setFloat(12, math.min(bounds.width, bounds.height) * dpr / 2)
        ..setFloat(
            13,
            chromaticDispersionMaxPx(
              refraction: c.optics.refraction,
              pressed: c.pressed,
              deformation: c.deformation,
            ));
      final shaderFilter = ui.ImageFilter.shader(shader);
      // Inner shader reads the original root-pass backdrop. Only its OUTPUT is
      // blurred: reversing these stages would invalidate root texture coordinates.
      filter = sigma > 0
          ? ui.ImageFilter.compose(
              outer: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              inner: shaderFilter)
          : shaderFilter;
    } else {
      filter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    }
    final backdropLayer =
        (layer ??= BackdropFilterLayer()) as BackdropFilterLayer;
    backdropLayer.filter = filter;
    context.pushLayer(backdropLayer, super.paint, offset);
  }
}

Future<ui.FragmentProgram>? _liquidGlassProgram;

Future<ui.FragmentProgram> _loadLiquidGlassProgram() =>
    _liquidGlassProgram ??=
        ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');

double liquidGlassBarHeight(BuildContext context, GlassConfiguration optics) {
  final textHeight =
      MediaQuery.textScalerOf(context).scale(10 * optics.barHeight / 50);
  return math.max(
    48.0,
    math.max(
      optics.barHeight,
      textHeight * 1.35 + 19 * optics.barHeight / 50 + 7,
    ),
  );
}

double liquidGlassBarWidth(BuildContext context, GlassConfiguration optics) {
  return math.min(
    optics.barWidth,
    math.max(0.0, MediaQuery.sizeOf(context).width - 32),
  );
}

class LiquidGlassDestination {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const LiquidGlassDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
}

/// Reusable Liquid Glass floating capsule matching [LiquidGlassBottomBar].
class LiquidGlassCapsule extends StatefulWidget {
  const LiquidGlassCapsule({
    super.key,
    required this.optics,
    required this.height,
    this.width,
    this.pressed = false,
    this.fraction = 1.0,
    this.surfaceKey,
    required this.child,
  });

  final GlassConfiguration optics;
  final double height;
  final double? width;
  final bool pressed;
  final double fraction;
  final Key? surfaceKey;
  final Widget child;

  @override
  State<LiquidGlassCapsule> createState() => _LiquidGlassCapsuleState();
}

class _LiquidGlassCapsuleState extends State<LiquidGlassCapsule> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (ui.ImageFilter.isShaderFilterSupported) {
      _loadShader();
    }
  }

  Future<void> _loadShader() async {
    try {
      final program = await _loadLiquidGlassProgram();
      if (mounted) {
        setState(() => _shader = program.fragmentShader());
      }
    } catch (error) {
      _liquidGlassProgram = null;
      debugPrint('Liquid glass capsule: ordinary blur fallback ($error)');
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fraction = widget.fraction.clamp(0.0, 1.0).toDouble();
    final radius = widget.height / 2;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final optics = widget.optics;
    final shader = _shader;
    final refracting = shader != null && ui.ImageFilter.isShaderFilterSupported;
    final glintStrength = highlightStrength(
      configured: optics.highlight,
      pressed: widget.pressed,
      deformation: widget.pressed ? 6 : 0,
    );
    final tint = DecoratedBox(
      decoration: BoxDecoration(
        color: (dark ? const Color(0xff202026) : const Color(0xfff5f5f7))
            .withValues(alpha: optics.tint * fraction),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(
              color: Colors.black
                  .withValues(alpha: (dark ? 0.30 : 0.09) * fraction),
              blurRadius: widget.pressed ? 12 : 18,
              spreadRadius: -2,
              offset: Offset(0, widget.pressed ? 3 : 6),
            ),
            BoxShadow(
              color: Colors.black
                  .withValues(alpha: (dark ? 0.18 : 0.05) * fraction),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.hasBoundedWidth
                  ? constraints.maxWidth
                  : (widget.width ?? 0.0);
              return Stack(
                key: widget.surfaceKey,
                children: [
                  Positioned.fill(
                    child: refracting
                        ? _RootGlassBackdrop(
                            key: const ValueKey('listening-dock-glass-refraction'),
                            shader: shader,
                            optics: optics,
                            lens: Rect.fromLTWH(0, 0, width, widget.height),
                            pressed: widget.pressed,
                            deformation: widget.pressed ? 6 : 0,
                            fraction: fraction,
                            view: View.of(context),
                            child: tint,
                          )
                        : BackdropFilter(
                            key: const ValueKey('listening-dock-glass-blur'),
                            filter: ui.ImageFilter.blur(
                              sigmaX: optics.blur * fraction,
                              sigmaY: optics.blur * fraction,
                            ),
                            child: tint,
                          ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(radius),
                          border: Border.all(
                            color: Colors.white.withValues(
                              alpha: (dark ? 0.16 : 0.65) *
                                  optics.highlight *
                                  fraction,
                            ),
                            width: 0.9,
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(
                                alpha: (dark ? 0.10 : 0.28) *
                                    glintStrength *
                                    fraction,
                              ),
                              Colors.white.withValues(alpha: 0),
                              Colors.white.withValues(
                                alpha: (dark ? 0.04 : 0.08) *
                                    optics.highlight *
                                    fraction,
                              ),
                            ],
                            stops: const [0.0, 0.45, 1.0],
                          ),
                        ),
                        child: CustomPaint(
                          painter: _GlassGlint(dark, glintStrength * fraction),
                        ),
                      ),
                    ),
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: widget.child,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A clipped GPU backdrop lens on Impeller. Other renderers use ordinary blur,
/// not refraction. No screenshots, image readback, or per-frame asset loading.
class LiquidGlassBottomBar extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<LiquidGlassDestination> destinations;
  final double barFrac;

  const LiquidGlassBottomBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.barFrac = 1,
  });

  @override
  State<LiquidGlassBottomBar> createState() => _LiquidGlassBottomBarState();
}

class _LiquidGlassBottomBarState extends State<LiquidGlassBottomBar>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _springX;
  late final AnimationController _springY;
  VelocityTracker? _velocityTracker;
  ui.FragmentShader? _shader;
  late double _position;
  double _from = 0;
  double _to = 0;
  double _stretch = 0;
  double _stretchY = 0;
  bool _pressed = false;
  bool _dragging = false;
  bool _reduceMotion = false;
  int? _focusHighlight;
  int? _pendingSelection;

  double get _selected => widget.destinations.isEmpty
      ? 0.5
      : (widget.selectedIndex.clamp(0, widget.destinations.length - 1) + 0.5) /
          widget.destinations.length;

  @override
  void initState() {
    super.initState();
    _position = _selected;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(_tick);
    _springX = AnimationController.unbounded(vsync: this, value: 0)
      ..addListener(() => _stretch = _springX.value);
    _springY = AnimationController.unbounded(vsync: this, value: 0)
      ..addListener(() => _stretchY = _springY.value);
    LKStore.animationsEnabled.addListener(_motionChanged);
    if (ui.ImageFilter.isShaderFilterSupported) _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await _loadLiquidGlassProgram();
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (error) {
      // Loading/driver failure is explicitly the blur fallback, not fake optics.
      _liquidGlassProgram = null;
      debugPrint('Liquid glass: ordinary blur fallback ($error)');
    }
  }

  void _tick() {
    _position = ui.lerpDouble(
        _from, _to, Curves.easeOutCubic.transform(_controller.value))!;
  }

  void _motionChanged() {
    if (mounted) {
      if (_reduceMotion || !LKStore.animationsEnabled.value) {
        _springX.stop();
        _springY.stop();
        _stretch = 0;
        _stretchY = 0;
      }
      setState(() {
        _reduceMotion = AppMotion.isDisabled(context);
        if (_reduceMotion) {
          _controller.stop();
          _position = _selected;
          _stretch = 0;
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Use the latest real viewport, without notifying listeners during build.
    MediaQuery.sizeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) LKStore.ensureGlassDimensions(MediaQuery.sizeOf(context));
    });
    _reduceMotion = AppMotion.isDisabled(context);
    if (_reduceMotion) {
      _controller.stop();
      _springX.stop();
      _springY.stop();
      _position = _selected;
      _stretch = 0;
      _stretchY = 0;
    }
  }

  @override
  void didUpdateWidget(LiquidGlassBottomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final acceptedInternalSelection = _pendingSelection == widget.selectedIndex;
    if (acceptedInternalSelection ||
        (widget.selectedIndex != oldWidget.selectedIndex &&
            _pendingSelection != null)) {
      _pendingSelection = null;
    }
    if (widget.selectedIndex != oldWidget.selectedIndex ||
        widget.destinations.length != oldWidget.destinations.length ||
        widget.barFrac <= 0.01) {
      _dragging = false;
      _pressed = false;
      if (!acceptedInternalSelection) {
        _springX.stop();
        _springY.stop();
        _stretch = 0;
        _stretchY = 0;
      }
      _moveTo(_selected, preserveSpring: acceptedInternalSelection);
    }
  }

  void _moveTo(double target, {bool preserveSpring = false}) {
    _controller.stop();
    if (!preserveSpring) {
      _springX.stop();
      _springY.stop();
    }
    if (_reduceMotion || widget.barFrac <= 0.01) {
      _position = target;
    } else {
      _from = _position;
      _to = target;
      _controller.forward(from: 0);
    }
  }

  void _select(int index, {bool springBack = false}) {
    setState(() {
      _pressed = false;
      _dragging = false;
      if (!springBack) {
        _stretch = 0;
        _stretchY = 0;
      }
      // The parent owns selection. Reconcile even when it rejects the request.
      _moveTo(_selected);
    });
    _pendingSelection = index;
    widget.onDestinationSelected(index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pendingSelection == index) _pendingSelection = null;
    });
  }

  void _springBack() {
    if (_reduceMotion) {
      setState(() {
        _stretch = 0;
        _stretchY = 0;
      });
      return;
    }
    final velocity =
        _velocityTracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
    const spring = SpringDescription(mass: 1, stiffness: 360, damping: 26);
    _stretch = math.max(_stretch, (velocity.dx.abs() / 110).clamp(0.0, 14.0));
    _stretchY = math.max(_stretchY, (velocity.dy.abs() / 220).clamp(0.0, 8.0));
    _springX.value = _stretch;
    _springY.value = _stretchY;
    _springX.animateWith(SpringSimulation(spring, _springX.value, 0,
        velocity.dx.sign * velocity.dx.abs().clamp(0.0, 1800) / 90));
    _springY.animateWith(SpringSimulation(spring, _springY.value, 0,
        velocity.dy.sign * velocity.dy.abs().clamp(0.0, 1800) / 140));
  }

  void _cancel() {
    _springX.stop();
    _springY.stop();
    setState(() {
      _pressed = false;
      _dragging = false;
      _stretch = 0;
      _stretchY = 0;
      _moveTo(_selected);
    });
  }

  @override
  void dispose() {
    LKStore.animationsEnabled.removeListener(_motionChanged);
    _controller.dispose();
    _springX.dispose();
    _springY.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<GlassConfiguration>(
        valueListenable: LKStore.glassConfiguration,
        builder: (context, _, __) => _buildGlass(
            context, LKStore.glassConfigurationFor(MediaQuery.sizeOf(context))),
      );
  Widget _buildGlass(BuildContext context, GlassConfiguration optics) {
    final media = MediaQuery.of(context);
    final fraction = optics.keepVisibleOnScroll
        ? 1.0
        : widget.barFrac.clamp(0.0, 1.0).toDouble();
    if (fraction <= 0.01 ||
        widget.destinations.isEmpty ||
        media.viewInsets.bottom > 0) {
      return const SizedBox.shrink();
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final barHeight = liquidGlassBarHeight(context, optics);
    final barScale = optics.barHeight / 50;
    // heightFactor is essential in Scaffold.bottomNavigationBar: do not consume
    // the whole viewport, nor intercept taps in the page above the 50px bar.
    return Align(
      heightFactor: 1,
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(
            bottom: math.max(media.padding.bottom, optics.floatingHeight)),
        child: Transform.translate(
          offset: Offset(
              0, (1 - fraction) * (barHeight + optics.floatingHeight + 10)),
          child: SizedBox(
            width: liquidGlassBarWidth(context, optics),
            height: barHeight,
            child: LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              if (width <= 0) return const SizedBox.shrink();
              final count = widget.destinations.length;
              final itemWidth = width / count;
              final base = math.min(
                  62.0 * barScale, math.max(0.0, itemWidth - 6 * barScale));
              final raised = _pressed && !_reduceMotion;
              final shader = _shader;
              final refracting =
                  shader != null && ui.ImageFilter.isShaderFilterSupported;
              final sigma = optics.blur;
              final tint = DecoratedBox(
                  decoration: BoxDecoration(
                color:
                    (dark ? const Color(0xff202026) : const Color(0xfff5f5f7))
                        .withValues(alpha: optics.tint * fraction),
                borderRadius: BorderRadius.circular(barHeight / 2),
              ));
              return Listener(
                onPointerDown: (event) {
                  _velocityTracker = VelocityTracker.withKind(event.kind)
                    ..addPosition(event.timeStamp, event.position);
                  setState(() => _pressed = true);
                },
                onPointerMove: (event) => _velocityTracker?.addPosition(
                    event.timeStamp, event.position),
                onPointerUp: (_) => setState(() => _pressed = false),
                onPointerCancel: (_) => _cancel(),
                child: GestureDetector(
                  excludeFromSemantics: true,
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _select((d.localPosition.dx / itemWidth)
                      .floor()
                      .clamp(0, count - 1)),
                  onTapCancel: () {
                    if (!_dragging) setState(() => _pressed = false);
                  },
                  onHorizontalDragStart: (d) {
                    _controller.stop();
                    setState(() {
                      _dragging = true;
                      _pressed = true;
                      _position = (d.localPosition.dx / width).clamp(0, 1);
                    });
                  },
                  onHorizontalDragUpdate: (d) {
                    if (!_dragging) return;
                    setState(() {
                      _position = (d.localPosition.dx / width).clamp(0, 1);
                      _stretch = _reduceMotion
                          ? 0
                          : ((d.primaryDelta ?? 0).abs() * 0.65).clamp(0, 14);
                    });
                  },
                  onHorizontalDragEnd: (_) {
                    if (_dragging) {
                      _select((_position * count).floor().clamp(0, count - 1),
                          springBack: true);
                      _springBack();
                    }
                  },
                  onHorizontalDragCancel: _cancel,
                  child: AnimatedBuilder(
                    animation:
                        Listenable.merge([_controller, _springX, _springY]),
                    builder: (context, _) {
                      final lensWidth = math.min(
                          width, base + (raised ? 7 * barScale : 0) + _stretch);
                      final lensHeight =
                          (raised ? 48.0 * barScale : 40.0 * barScale) +
                              _stretchY;
                      final left = (_position * width - lensWidth / 2)
                          .clamp(0.0, math.max(0.0, width - lensWidth))
                          .toDouble();
                      return Stack(
                        key: const ValueKey('liquid-glass-surface'),
                        children: [
                          if (refracting)
                            Positioned.fill(
                              child: ClipPath(
                                key: const ValueKey(
                                    'liquid-glass-sampling-ghost'),
                                clipper: _GlassSamplingClipper(
                                  Rect.fromLTWH(
                                    left,
                                    (barHeight - lensHeight) / 2,
                                    lensWidth,
                                    lensHeight,
                                  ),
                                  lensHeight / 2,
                                ),
                                // This deliberately paints the selected glyph at
                                // low alpha BEFORE BackdropFilter so its pixels are
                                // part of the root-pass input. The normal foreground
                                // row remains the only visible/interactive item.
                                child: IgnorePointer(
                                  child: ExcludeSemantics(
                                    child: _samplingGhost(
                                      context,
                                      count: count,
                                      selectedIndex: widget.selectedIndex,
                                      width: width,
                                      height: barHeight,
                                      visualScale: barScale,
                                      fraction: fraction,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(barHeight / 2),
                              child: refracting
                                  ? _RootGlassBackdrop(
                                      key: const ValueKey(
                                          'liquid-glass-refraction'),
                                      shader: shader,
                                      optics: optics,
                                      lens: Rect.fromLTWH(
                                          left,
                                          (barHeight - lensHeight) / 2,
                                          lensWidth,
                                          lensHeight),
                                      pressed: raised,
                                      fraction: fraction,
                                      deformation: _stretch + _stretchY,
                                      view: View.of(context),
                                      child: tint,
                                    )
                                  : BackdropFilter(
                                      key: const ValueKey(
                                          'liquid-glass-blur-fallback'),
                                      filter: ui.ImageFilter.blur(
                                          sigmaX: sigma * fraction,
                                          sigmaY: sigma * fraction),
                                      child: tint,
                                    ),
                            ),
                          ),
                          Positioned(
                            key: const ValueKey('liquid-glass-lens'),
                            left: left,
                            top: (barHeight - lensHeight) / 2,
                            width: lensWidth,
                            height: lensHeight,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(lensHeight / 2),
                                  color: Colors.white.withValues(
                                      alpha: (dark ? 0.09 : 0.23) *
                                          optics.highlight),
                                  boxShadow: [
                                    BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.09),
                                        blurRadius: raised ? 9 : 4,
                                        offset: const Offset(0, 2))
                                  ],
                                ),
                                child: CustomPaint(
                                  painter: _GlassGlint(
                                    dark,
                                    highlightStrength(
                                      configured: optics.highlight,
                                      pressed: raised,
                                      deformation: _stretch + _stretchY,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Row(children: [
                            for (var i = 0; i < count; i++)
                              Expanded(
                                  child: _item(context, i, barHeight, barScale,
                                      fraction)),
                          ]),
                        ],
                      );
                    },
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _samplingGhost(
    BuildContext context, {
    required int count,
    required int selectedIndex,
    required double width,
    required double height,
    required double visualScale,
    required double fraction,
  }) {
    if (count == 0) return const SizedBox.expand();
    final index = selectedIndex.clamp(0, count - 1);
    final destination = widget.destinations[index];
    final scheme = Theme.of(context).colorScheme;
    // Color alpha avoids an Opacity saveLayer before the root backdrop filter.
    final ghostColor = scheme.onPrimaryContainer.withValues(
      alpha: 0.10 * fraction,
    );
    final scale = visualScale;
    return Row(
      children: [
        for (var i = 0; i < count; i++)
          Expanded(
            child: i == index
                ? SizedBox(
                    width: width / count,
                    height: height,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(destination.selectedIcon,
                              size: 19 * scale, color: ghostColor),
                          SizedBox(height: 1.5 * scale),
                          Text(
                            destination.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: MediaQuery.textScalerOf(context),
                            style: TextStyle(
                              fontSize: 10 * scale,
                              fontWeight: FontWeight.w700,
                              color: ghostColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.expand(),
          ),
      ],
    );
  }

  Widget _item(BuildContext context, int index, double height, double scale,
      double fraction) {
    final dest = widget.destinations[index];
    final selected = index == widget.selectedIndex;
    final scheme = Theme.of(context).colorScheme;
    final proximity =
        (1 - ((_position * widget.destinations.length) - index - 0.5).abs())
            .clamp(0.0, 1.0);
    final baseColor =
        Color.lerp(scheme.onSurface, scheme.onPrimaryContainer, proximity)!;
    final color = baseColor.withValues(alpha: baseColor.a * fraction);
    return Semantics(
      button: true,
      selected: selected,
      label: dest.label,
      onTap: () => _select(index),
      child: FocusableActionDetector(
        onShowFocusHighlight: (show) => setState(() {
          if (show) {
            _focusHighlight = index;
          } else if (_focusHighlight == index) {
            _focusHighlight = null;
          }
        }),
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent()
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            _select(index);
            return null;
          })
        },
        child: ExcludeSemantics(
          child: Container(
            height: height,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: _focusHighlight == index
                  ? Border.all(
                      color: scheme.primary
                          .withValues(alpha: scheme.primary.a * fraction),
                      width: 2)
                  : null,
            ),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(selected ? dest.selectedIcon : dest.icon,
                    size: 19 * scale, color: color),
                SizedBox(height: 1.5 * scale),
                Text(dest.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textScaler: MediaQuery.textScalerOf(context),
                    style: TextStyle(
                        fontSize: 10 * scale,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w600,
                        color: color)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
