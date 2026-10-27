#include <flutter/runtime_effect.glsl>

// Reserved by ImageFilter.shader: texture size and actual GPU backdrop input.
// Input is the entire render pass, NOT the clipped widget's dimensions.
uniform vec2 u_size;
uniform vec2 u_center_px;
uniform vec2 u_half_lens_px;
uniform float u_pressed;
uniform float u_fraction;
uniform vec2 u_view_size_px;
uniform float u_refraction; // Dart float offset 10
uniform vec2 u_corner_radii_px; // Dart vec2 offset 11; capsule radii (rx, ry)
uniform float u_dispersion_px; // Dart float offset 13; maximum RGB offset in physical px
uniform sampler2D u_backdrop;
out vec4 frag_color;

vec4 sampleBackdrop(vec2 pixel) {
  vec2 uv = clamp(pixel / u_size, vec2(0.001), vec2(0.999));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(u_backdrop, uv);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec4 original = sampleBackdrop(p);
  // Root-pass contract: never refract an unknown offscreen input. The outer
  // native Gaussian stage still blurs this entire output (not only the lens).
  if (any(greaterThan(abs(u_size - u_view_size_px), vec2(2.0)))) {
    frag_color = original;
    return;
  }
  vec2 delta = p - u_center_px;
  vec2 halfSize = max(u_half_lens_px, vec2(1.0));
  // Rounded-rectangle SDF for this capsule lens. The component passes equal
  // X/Y radii; elliptical corner radii are intentionally not used.
  vec2 radius = clamp(u_corner_radii_px, vec2(0.0), halfSize);
  vec2 q = abs(delta) - (halfSize - radius);
  vec2 outside = max(q, vec2(0.0));
  float sd = length(outside) + min(max(q.x, q.y), 0.0) - min(radius.x, radius.y);
  vec2 grad = outside / max(length(outside), 0.0001);
  if (length(outside) < 0.0001) {
    grad = q.x > q.y ? vec2(sign(delta.x), 0.0) : vec2(0.0, sign(delta.y));
  } else {
    grad *= sign(delta);
  }
  // Refract only in a thin inward edge band; the central input is unchanged.
  float edgeBand = max(min(halfSize.x, halfSize.y) * 0.34, 1.0);
  float edge = sd <= 0.0 ? smoothstep(-edgeBand, 0.0, sd) : 0.0;
  float power = u_refraction * (1.0 + u_pressed * (0.035 / 0.135));
  vec2 source = p - grad * power * min(halfSize.x, halfSize.y) * edge;
  vec4 refracted = sampleBackdrop(source);
  // Keep channel separation subpixel and confined to the same refracting edge
  // band. A zero slider value, zero edge weight, or zero refraction is neutral.
  float separation = clamp(u_dispersion_px, 0.0, 0.72) * edge;
  vec2 chroma = grad * separation;
  refracted.r = sampleBackdrop(source + chroma).r;
  refracted.b = sampleBackdrop(source - chroma).b;
  frag_color = mix(original, refracted, u_fraction);
}
