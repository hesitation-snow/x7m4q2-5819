import 'package:flutter/material.dart';

/// Settings and action rows share the same small, tonal leading icon.
class AppSettingIcon extends StatelessWidget {
  const AppSettingIcon(this.icon, {super.key, this.danger = false});

  final IconData icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger ? scheme.error : scheme.primary;
    return ExcludeSemantics(
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }
}

class AppSectionTitle extends StatelessWidget {
  const AppSectionTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Semantics(
          header: true,
          child: Text(title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  )),
        ),
      );
}

/// Same surface, spacing and icon/text alignment in settings and menu sheets.
class AppSettingsGroup extends StatelessWidget {
  const AppSettingsGroup({
    super.key,
    required this.children,
    this.dividers = true,
  });
  final List<Widget> children;
  final bool dividers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTileTheme.merge(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minLeadingWidth: 36,
        horizontalTitleGap: 12,
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        tileColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        titleTextStyle: Theme.of(context)
            .textTheme
            .bodyLarge
            ?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w500),
        subtitleTextStyle: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (dividers && i > 0)
                Divider(
                  height: 1,
                  indent: 64,
                  endIndent: 16,
                  color: scheme.outlineVariant.withValues(alpha: .25),
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// A selection or action in a bottom sheet; null selected means navigation.
class M3OptionTile extends StatelessWidget {
  const M3OptionTile({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.selected,
    this.danger = false,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final bool? selected;
  final bool danger;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = selected == true;
    final foreground = danger
        ? scheme.error
        : active
            ? scheme.onSecondaryContainer
            : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        child: Material(
          color:
              active ? scheme.secondaryContainer : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            minLeadingWidth: 36,
            horizontalTitleGap: 12,
            leading: AppSettingIcon(icon, danger: danger),
            title: Text(title,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: foreground, fontWeight: FontWeight.w500)),
            subtitle: subtitle == null
                ? null
                : Text(subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.4,
                        color: active
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant)),
            trailing: trailing ??
                (active
                    ? Icon(Icons.check_rounded, color: foreground, size: 20)
                    : selected == null
                        ? Icon(Icons.chevron_right_rounded,
                            color: scheme.onSurfaceVariant, size: 20)
                        : null),
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}

/// A real Material choice control (focus/keyboard/semantics included), rather
/// than an individually painted container on each page.
class M3ChoiceChip extends StatelessWidget {
  const M3ChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.icon,
    this.shape,
  });
  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final IconData? icon;
  final OutlinedBorder? shape;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ChoiceChip(
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label),
      ),
      avatar: icon == null
          ? null
          : Icon(icon,
              size: 16,
              color: selected
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant),
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      side: BorderSide.none,
      shape: shape ?? const StadiumBorder(),
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.secondaryContainer,
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
  }
}
