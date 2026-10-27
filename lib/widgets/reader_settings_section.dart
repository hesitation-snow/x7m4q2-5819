import 'package:flutter/material.dart';
import 'm3_controls.dart';

Color readerSettingsCardColor(ColorScheme scheme) => scheme.surfaceContainerLow;

class ReaderSettingsSection extends StatelessWidget {
  const ReaderSettingsSection(
      {super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppSectionTitle(title),
        AppSettingsGroup(dividers: false, children: children),
      ]),
    );
  }
}

class ReaderThemePicker extends StatelessWidget {
  const ReaderThemePicker(
      {super.key,
      required this.presets,
      required this.selected,
      required this.onSelected});

  final List<(Color, Color, String)> presets;

  /// null 表示跟随系统。
  final int? selected;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: (constraints.maxWidth - 8).clamp(0.0, 2000.0),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i <= presets.length; i++)
                  Builder(builder: (context) {
                    final system = i == presets.length;
                    final value = system ? null : i;
                    final label = system ? '跟随系统' : presets[i].$3;
                    final active = selected == value;
                    return Semantics(
                      button: true,
                      selected: active,
                      label: label,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => onSelected(value),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 6),
                          child: Column(children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: system ? scheme.surface : presets[i].$1,
                                border: Border.all(
                                    color: active
                                        ? scheme.primary
                                        : scheme.outline.withValues(alpha: 0.3),
                                    width: active ? 2.5 : 1),
                              ),
                              child: system
                                  ? Icon(Icons.brightness_auto_outlined,
                                      color: scheme.onSurfaceVariant, size: 22)
                                  : Icon(
                                      active
                                          ? Icons.check_rounded
                                          : Icons.text_fields,
                                      color: presets[i].$2,
                                      size: 22),
                            ),
                            const SizedBox(height: 6),
                            Text(label,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: active
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : FontWeight.normal)),
                          ]),
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
        );
      },
    );
  }
}
