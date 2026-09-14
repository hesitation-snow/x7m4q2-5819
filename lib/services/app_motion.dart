import 'package:flutter/material.dart';

import '../api/store.dart';

/// 只控制应用界面动效；不改计时、网络超时，也不冻结整个应用的 Ticker。
class AppMotion {
  static bool get disabled => !LKStore.animationsEnabled.value;
  static bool isDisabled(BuildContext context) {
    // Always subscribe, even when our preference already disables motion.
    final systemDisabled =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return disabled || systemDisabled;
  }

  static Duration duration(BuildContext context, int milliseconds) =>
      isDisabled(context)
          ? Duration.zero
          : Duration(milliseconds: milliseconds);
  static AnimationStyle? style(BuildContext context) =>
      isDisabled(context) ? AnimationStyle.noAnimation : null;

  static const noPageTransitions = PageTransitionsTheme(builders: {
    TargetPlatform.android: _InstantPageTransitions(),
    TargetPlatform.iOS: _InstantPageTransitions(),
    TargetPlatform.macOS: _InstantPageTransitions(),
    TargetPlatform.windows: _InstantPageTransitions(),
    TargetPlatform.linux: _InstantPageTransitions(),
    TargetPlatform.fuchsia: _InstantPageTransitions(),
  });

  static Future<void> scrollTo(
      BuildContext context, ScrollController controller, double offset,
      {int milliseconds = 250, Curve curve = Curves.easeOut}) async {
    if (!controller.hasClients) return;
    if (isDisabled(context)) {
      controller.jumpTo(offset);
    } else {
      await controller.animateTo(offset,
          duration: Duration(milliseconds: milliseconds), curve: curve);
    }
  }

  static Future<void> pageTo(
      BuildContext context, PageController controller, int page,
      {int milliseconds = 260, Curve curve = Curves.easeOutCubic}) async {
    if (!controller.hasClients) return;
    if (isDisabled(context)) {
      controller.jumpToPage(page);
    } else {
      await controller.animateToPage(page,
          duration: Duration(milliseconds: milliseconds), curve: curve);
    }
  }
}

/// Tabs already on the navigation stack also obey changes to the global switch.
class MotionTabController extends TabController {
  MotionTabController(
      {required super.length, required super.vsync, super.initialIndex});

  @override
  void animateTo(int value, {Duration? duration, Curve curve = Curves.ease}) {
    super.animateTo(value,
        duration: AppMotion.disabled ? Duration.zero : duration, curve: curve);
  }
}

class _InstantPageTransitions extends PageTransitionsBuilder {
  const _InstantPageTransitions();
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Duration get reverseTransitionDuration => Duration.zero;
  @override
  Widget buildTransitions<T>(
          PageRoute<T> route,
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child) =>
      child;
}

/// 加载反馈不受“关闭动画”影响，避免被误认为界面卡住。
class MotionRefreshIndicator extends StatelessWidget {
  const MotionRefreshIndicator(
      {super.key,
      required this.child,
      required this.onRefresh,
      this.notificationPredicate = defaultScrollNotificationPredicate});
  final Widget child;
  final RefreshCallback onRefresh;
  final ScrollNotificationPredicate notificationPredicate;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
      onRefresh: onRefresh,
      notificationPredicate: notificationPredicate,
      child: child);
}

/// 加载圈保留正常旋转；有实际进度时按真实数值展示。
class MotionProgressIndicator extends StatelessWidget {
  const MotionProgressIndicator(
      {super.key,
      this.value,
      this.strokeWidth = 4,
      this.color,
      this.backgroundColor,
      this.valueColor,
      this.semanticsLabel,
      this.semanticsValue});
  final double? value;
  final double strokeWidth;
  final Color? color;
  final Color? backgroundColor;
  final Animation<Color?>? valueColor;
  final String? semanticsLabel;
  final String? semanticsValue;
  @override
  Widget build(BuildContext context) => CircularProgressIndicator(
        value: value,
        strokeWidth: strokeWidth,
        color: color,
        backgroundColor: backgroundColor,
        valueColor: valueColor,
        semanticsLabel: semanticsLabel,
        semanticsValue: semanticsValue,
      );
}

class MotionLinearProgressIndicator extends StatelessWidget {
  const MotionLinearProgressIndicator({super.key, this.minHeight});
  final double? minHeight;

  @override
  Widget build(BuildContext context) =>
      LinearProgressIndicator(minHeight: minHeight);
}
