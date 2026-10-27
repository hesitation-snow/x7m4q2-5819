import 'dart:math' as math;

/// CPU reference for the component's capsule SDF and edge weight.
/// The shader uniforms currently pass equal X/Y corner radii (capsule shape);
/// callers should likewise provide equal radii. Coordinates and half sizes are
/// physical pixels, matching FlutterFragCoord.
double roundedRectSdf({
  required double x,
  required double y,
  required double halfWidth,
  required double halfHeight,
  required double radiusX,
  required double radiusY,
}) {
  final rx = radiusX.clamp(0.0, halfWidth);
  final ry = radiusY.clamp(0.0, halfHeight);
  final qx = x.abs() - (halfWidth - rx);
  final qy = y.abs() - (halfHeight - ry);
  final ox = math.max(qx, 0.0);
  final oy = math.max(qy, 0.0);
  return math.sqrt(ox * ox + oy * oy) +
      math.min(math.max(qx, qy), 0.0) -
      math.min(rx, ry);
}

double highlightStrength(
    {required double configured,
    required bool pressed,
    required double deformation}) {
  final motion = (deformation / 32).clamp(0.0, 0.45);
  return (configured.clamp(0.0, 1.0) * (pressed ? 1.0 : 0.55 + motion))
      .clamp(0.0, 1.0);
}

double refractionEdgeWeight(double signedDistance, double edgeBand) {
  if (signedDistance > 0) return 0;
  if (edgeBand <= 0) return signedDistance == 0 ? 1 : 0;
  final t = ((signedDistance + edgeBand) / edgeBand).clamp(0.0, 1.0);
  final smooth = t * t * (3 - 2 * t);
  return smooth;
}

/// Maximum RGB channel offset in physical pixels before edge attenuation.
/// Refraction-disabled configurations also disable chromatic separation.
double chromaticDispersionMaxPx({
  required double refraction,
  required bool pressed,
  required double deformation,
}) {
  if (refraction <= 0) return 0;
  final motion = (deformation.abs() / 32).clamp(0.0, 1.0);
  return (0.32 + (pressed ? 0.08 : 0.0) + motion * 0.24).clamp(0.0, 0.72);
}

/// Shader-equivalent RGB channel separation at a pixel, in physical pixels.
double chromaticDispersionOffsetPx({
  required double edgeWeight,
  required double refraction,
  required bool pressed,
  required double deformation,
}) =>
    chromaticDispersionMaxPx(
      refraction: refraction,
      pressed: pressed,
      deformation: deformation,
    ) *
    edgeWeight.clamp(0.0, 1.0);
