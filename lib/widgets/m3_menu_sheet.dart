import 'package:flutter/material.dart';

/// Shared chrome for both simple menus and panels with their own scroll view.
/// Keeping this separate avoids nesting TabBarView/ListView in another scroller.
class M3SheetHeader extends StatelessWidget {
  const M3SheetHeader({
    super.key,
    required this.title,
    this.icon,
    this.action,
    this.onClose,
    this.closeTooltip = '关闭',
  });

  final String title;
  final IconData? icon;
  final Widget? action;
  final VoidCallback? onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        ExcludeSemantics(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
          child: Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onSurface, fontWeight: FontWeight.w600)),
              ),
            ),
            if (action != null) ...[
              action!,
              const SizedBox(width: 4),
            ],
            IconButton(
              tooltip: closeTooltip,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onClose ?? () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ]),
        ),
      ],
    );
  }
}

/// Compact, scrollable Material 3 menu. Dismissal never invokes an option.
class M3MenuSheet extends StatelessWidget {
  const M3MenuSheet({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.description,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 640,
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              M3SheetHeader(title: title, icon: icon),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (description != null) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                          child: Text(description!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant, height: 1.4)),
                        ),
                      ],
                      ...children,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
