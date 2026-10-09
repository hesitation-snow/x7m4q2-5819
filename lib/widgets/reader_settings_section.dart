import 'package:flutter/material.dart';

Color readerSettingsCardColor(ColorScheme scheme) =>
    Color.alphaBlend(scheme.onSurface.withValues(alpha: 0.035), scheme.surface);

class ReaderSettingsSection extends StatelessWidget {
  const ReaderSettingsSection(
      {super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(title,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary)),
        ),
        Material(
          color: readerSettingsCardColor(scheme),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.2))),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTileTheme(
              data: const ListTileThemeData(
                  tileColor: Colors.transparent,
                  contentPadding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder()),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children),
            ),
          ),
        ),
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Column(children: [
                    Container(
                      width: 54,
                      height: 54,
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
                              color: scheme.onSurfaceVariant, size: 24)
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(label,
                        style: TextStyle(
                            fontSize: 11,
                            color: active
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                            fontWeight:
                                active ? FontWeight.w600 : FontWeight.normal)),
                  ]),
                ),
              ),
            );
          }),
      ]),
    );
  }
}
