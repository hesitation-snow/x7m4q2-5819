import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform bridge to keep the Android task alive in the background instead of
/// closing the Activity when the user navigates back from the home screen.
abstract final class AppBackground {
  static const MethodChannel _channel =
      MethodChannel('moe.yutro.yomiru/app_lifecycle');

  @visibleForTesting
  static Future<bool> Function()? overrideMoveToBackground;

  static Future<bool> moveToBackground() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final override = overrideMoveToBackground;
    if (override != null) {
      return await override();
    }
    try {
      final moved = await _channel.invokeMethod<bool>('moveToBackground');
      return moved == true;
    } catch (_) {
      return false;
    }
  }
}
