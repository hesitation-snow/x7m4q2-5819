import 'dart:async';

import 'package:flutter/services.dart';

/// Fires a subtle [HapticFeedback.selectionClick] only when a slider crosses
/// into a new discrete notch, avoiding continuous buzzing on sub-step moves.
class SliderHapticFeedback {
  int? _lastNotch;

  int _computeNotch(
    double value, {
    required double min,
    required double max,
    int? divisions,
    int continuousNotches = 25,
  }) {
    final span = max - min;
    if (span <= 0) return 0;
    final steps =
        (divisions != null && divisions > 0) ? divisions : continuousNotches;
    return (((value - min) / span).clamp(0.0, 1.0) * steps).round();
  }

  /// Syncs the baseline notch to the current slider value without vibrating.
  void sync(
    double value, {
    required double min,
    required double max,
    int? divisions,
    int continuousNotches = 25,
  }) {
    _lastNotch = _computeNotch(
      value,
      min: min,
      max: max,
      divisions: divisions,
      continuousNotches: continuousNotches,
    );
  }

  /// Fires a subtle selection click if [value] enters a different notch.
  void onChanged(
    double value, {
    required double min,
    required double max,
    int? divisions,
    int continuousNotches = 25,
  }) {
    final notch = _computeNotch(
      value,
      min: min,
      max: max,
      divisions: divisions,
      continuousNotches: continuousNotches,
    );
    if (_lastNotch == notch) return;
    _lastNotch = notch;
    unawaited(HapticFeedback.selectionClick());
  }

  void reset() => _lastNotch = null;

  /// Explicit light tactile click for discrete stepper buttons / preset chips.
  static void tick() {
    unawaited(HapticFeedback.selectionClick());
  }
}
