import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/widgets/liquid_glass_math.dart';

void main() {
  group('roundedRectSdf', () {
    test('capsule center is inside and edge is zero', () {
      expect(
          roundedRectSdf(
              x: 0,
              y: 0,
              halfWidth: 50,
              halfHeight: 20,
              radiusX: 20,
              radiusY: 20),
          closeTo(-20, 1e-9));
      expect(
          roundedRectSdf(
              x: 50,
              y: 0,
              halfWidth: 50,
              halfHeight: 20,
              radiusX: 20,
              radiusY: 20),
          closeTo(0, 1e-9));
    });
    test('corner distance uses rounded-rectangle geometry', () {
      expect(
          roundedRectSdf(
              x: 49,
              y: 19,
              halfWidth: 50,
              halfHeight: 20,
              radiusX: 10,
              radiusY: 10),
          greaterThan(0));
      expect(
          roundedRectSdf(
              x: 0,
              y: 0,
              halfWidth: 50,
              halfHeight: 20,
              radiusX: 10,
              radiusY: 10),
          lessThan(0));
    });
  });

  test('highlight rises with press and deformation, bounded by preference', () {
    final rest =
        highlightStrength(configured: .8, pressed: false, deformation: 0);
    final moving =
        highlightStrength(configured: .8, pressed: false, deformation: 8);
    final pressed =
        highlightStrength(configured: .8, pressed: true, deformation: 0);
    expect(rest, lessThan(moving));
    expect(moving, lessThan(pressed));
    expect(pressed, lessThanOrEqualTo(.8));
    expect(
        highlightStrength(configured: 2, pressed: true, deformation: 100), 1);
  });

  test('edge weight fades inward and is zero in the core', () {
    expect(refractionEdgeWeight(0, 10), closeTo(1, 1e-9));
    expect(refractionEdgeWeight(1, 10), 0);
    expect(refractionEdgeWeight(-1, 0), 0);
    expect(refractionEdgeWeight(-5, 10), closeTo(.5, 1e-9));
    expect(refractionEdgeWeight(-10, 10), closeTo(0, 1e-9));
    expect(refractionEdgeWeight(-20, 10), closeTo(0, 1e-9));
  });

  test('chromatic dispersion is edge-limited, subpixel, and motion-driven', () {
    double offset(
            {required double edge,
            required bool pressed,
            double deformation = 0}) =>
        chromaticDispersionOffsetPx(
          edgeWeight: edge,
          refraction: .135,
          pressed: pressed,
          deformation: deformation,
        );

    final rest = offset(edge: 1, pressed: false);
    final pressed = offset(edge: 1, pressed: true);
    final deformed = offset(edge: 1, pressed: false, deformation: 20);
    expect(offset(edge: 0, pressed: true, deformation: 20), 0);
    expect(
        chromaticDispersionOffsetPx(
          edgeWeight: 1,
          refraction: 0,
          pressed: true,
          deformation: 20,
        ),
        0);
    expect(rest, greaterThan(0));
    expect(pressed, greaterThan(rest));
    expect(deformed, greaterThan(rest));
    expect(pressed, lessThan(1));
    expect(deformed, lessThan(1));
    expect(offset(edge: .5, pressed: false), closeTo(rest / 2, 1e-9));
  });
}
