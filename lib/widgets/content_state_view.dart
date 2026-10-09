import 'package:flutter/material.dart';
import '../services/app_motion.dart';

/// 加载、失败与空内容共用提示样式；失败不混入实际正文。
class ContentStateView extends StatelessWidget {
  const ContentStateView(
      {super.key,
      required this.message,
      this.loading = false,
      this.icon = Icons.error_outline_rounded,
      this.onRetry,
      this.color,
      this.extraAction});
  final String message;
  final bool loading;
  final IconData icon;
  final VoidCallback? onRetry;
  final Color? color;
  final Widget? extraAction;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
        child: SingleChildScrollView(
            child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (loading)
              MotionProgressIndicator(color: foreground)
            else
              Icon(icon, size: 36, color: foreground.withValues(alpha: .7)),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: foreground, fontSize: 14, height: 1.5)),
            if (extraAction != null) ...[
              const SizedBox(height: 12),
              extraAction!
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重试'))
            ],
          ])),
    )));
  }
}
