import 'package:flutter/material.dart';
import '../reader/reader_typography.dart';
import 'reader_settings_section.dart';
import 'm3_controls.dart';

/// Material 3 阅读排版设置，预览与提交保持独立。
class ReaderTypographySheet extends StatefulWidget {
  final ReaderTypography initialTypography;
  final double fontSize;
  final ValueChanged<double>? onFontSizeChanged;
  final Color textColor;
  final Color backgroundColor;
  final Color linkColor;
  final bool isDark;
  final bool paged;
  final ValueChanged<ReaderTypography> onPreviewChange;
  final ValueChanged<ReaderTypography> onCommit;
  final VoidCallback? onPickTextColor;

  const ReaderTypographySheet({
    super.key,
    required this.initialTypography,
    required this.fontSize,
    this.onFontSizeChanged,
    required this.textColor,
    required this.backgroundColor,
    required this.linkColor,
    required this.isDark,
    this.paged = true,
    required this.onPreviewChange,
    required this.onCommit,
    this.onPickTextColor,
  });

  @override
  State<ReaderTypographySheet> createState() => ReaderTypographySheetState();
}

class ReaderTypographySheetState extends State<ReaderTypographySheet> {
  late ReaderTypography _current;
  late double _fontSize;

  @override
  void initState() {
    super.initState();
    _current = widget.initialTypography;
    _fontSize = widget.fontSize;
  }

  @override
  void didUpdateWidget(ReaderTypographySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fontSize != oldWidget.fontSize) {
      _fontSize = widget.fontSize;
    }
  }

  /// 供外部在关闭面板前确认最后一次提交
  void commitCurrent() {
    widget.onCommit(_current);
  }

  void _updatePreview(ReaderTypography updated) {
    setState(() => _current = updated);
    widget.onPreviewChange(updated);
  }

  void _commitChange(ReaderTypography updated) {
    setState(() => _current = updated);
    widget.onCommit(updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListTileTheme(
      data: const ListTileThemeData(
        tileColor: Colors.transparent,
        shape: RoundedRectangleBorder(),
        contentPadding: EdgeInsets.zero,
      ),
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          // 1. 顶部排版实时预览卡片
          _buildPreviewCard(scheme),
          const SizedBox(height: 16),

          // 2. 快捷预设胶囊
          _buildPresetBar(scheme),
          const SizedBox(height: 16),

          // 3. 常用排版滑杆分组
          ReaderSettingsSection(
            title: '文字与版式',
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('字重', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text('仅调整阅读正文；部分字体的档位差异可能不明显',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        for (var i = 0;
                            i < ReaderFontWeight.values.length;
                            i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          Expanded(
                            child: M3ChoiceChip(
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              label: ReaderFontWeight.values[i].label,
                              selected:
                                  _current.weight == ReaderFontWeight.values[i],
                              onSelected: (_) => _commitChange(
                                  _current.copyWith(
                                      weight: ReaderFontWeight.values[i])),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const Divider(height: 16, thickness: 0.5),
                    // 字号大小
                    _buildSliderRow(
                      label: '字号大小',
                      value: _fontSize,
                      min: 12.0,
                      max: 28.0,
                      divisions: 16,
                      valueText: '${_fontSize.toStringAsFixed(0)} pt',
                      defaultValue: 17.0,
                      onChanged: (v) {
                        setState(() => _fontSize = v);
                        widget.onFontSizeChanged?.call(v);
                      },
                      onChangeEnd: (v) {
                        widget.onFontSizeChanged?.call(v);
                      },
                    ),
                    const Divider(height: 16, thickness: 0.5),

                    // 行间距
                    _buildSliderRow(
                      label: '行间距',
                      value: _current.lineHeight,
                      min: 1.20,
                      max: 2.40,
                      divisions: 24,
                      valueText: _current.lineHeight.toStringAsFixed(2),
                      defaultValue: 1.70,
                      onChanged: (v) =>
                          _updatePreview(_current.copyWith(lineHeight: v)),
                      onChangeEnd: (v) =>
                          _commitChange(_current.copyWith(lineHeight: v)),
                    ),
                    const Divider(height: 16, thickness: 0.5),

                    // 段落间距
                    _buildSliderRow(
                      label: '段落间距',
                      value: _current.paragraphSpacing,
                      min: 0.0,
                      max: 32.0,
                      divisions: 16,
                      valueText: '${_current.paragraphSpacing.round()} px',
                      defaultValue: 12.0,
                      onChanged: (v) => _updatePreview(
                          _current.copyWith(paragraphSpacing: v)),
                      onChangeEnd: (v) =>
                          _commitChange(_current.copyWith(paragraphSpacing: v)),
                    ),
                    const Divider(height: 16, thickness: 0.5),

                    // 字符间距
                    _buildSliderRow(
                      label: '字符间距',
                      value: _current.letterSpacing,
                      min: -0.5,
                      max: 2.5,
                      divisions: 30,
                      valueText:
                          '${_current.letterSpacing >= 0 ? '+' : ''}${_current.letterSpacing.toStringAsFixed(1)} pt',
                      defaultValue: 0.3,
                      onChanged: (v) =>
                          _updatePreview(_current.copyWith(letterSpacing: v)),
                      onChangeEnd: (v) =>
                          _commitChange(_current.copyWith(letterSpacing: v)),
                    ),
                    const Divider(height: 16, thickness: 0.5),

                    // 页边留白（左右联动）
                    _buildSliderRow(
                      label: '页边留白',
                      value: _current.marginHorizontal,
                      min: 8.0,
                      max: 48.0,
                      divisions: 20,
                      valueText: '${_current.marginHorizontal.round()} dp',
                      defaultValue: 20.0,
                      enabled: !_current.customMargins,
                      onChanged: (v) => _updatePreview(
                          _current.copyWith(marginHorizontal: v)),
                      onChangeEnd: (v) =>
                          _commitChange(_current.copyWith(marginHorizontal: v)),
                    ),
                    if (_current.customMargins)
                      Text('已启用独立四周边距，请在下方分别调整；此滑杆暂不生效。',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    const Divider(height: 16, thickness: 0.5),

                    // 两端对齐开关
                    _buildSwitchTile(
                      icon: Icons.format_align_justify_rounded,
                      title: '两端对齐',
                      subtitle: '段内文字平整铺满，段末行保持自然',
                      value: _current.justify,
                      onChanged: (v) {
                        final updated = _current.copyWith(justify: v);
                        _commitChange(updated);
                      },
                      scheme: scheme,
                    ),
                    const Divider(height: 16, thickness: 0.5),

                    // 分栏模式：选项独占一行，窄屏与大字体不挤压标题。
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '分栏模式',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              widget.paged
                                  ? '自动：宽屏双栏，手机单栏'
                                  : '仅对翻页模式生效，请先开启翻页模式',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            for (var i = 0; i < 3; i++) ...[
                              if (i > 0) const SizedBox(width: 8),
                              Expanded(
                                child: M3ChoiceChip(
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  label: [
                                    (ReaderColumnMode.auto, '自动'),
                                    (ReaderColumnMode.single, '单栏'),
                                    (ReaderColumnMode.doubleColumn, '双栏'),
                                  ][i]
                                      .$2,
                                  selected: _current.columnMode ==
                                      [
                                        (ReaderColumnMode.auto, '自动'),
                                        (ReaderColumnMode.single, '单栏'),
                                        (ReaderColumnMode.doubleColumn, '双栏'),
                                      ][i]
                                          .$1,
                                  onSelected: !widget.paged
                                      ? null
                                      : (_) => _commitChange(_current.copyWith(
                                              columnMode: [
                                            (ReaderColumnMode.auto, '自动'),
                                            (ReaderColumnMode.single, '单栏'),
                                            (
                                              ReaderColumnMode.doubleColumn,
                                              '双栏'
                                            ),
                                          ][i]
                                                  .$1)),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              )
            ],
          ),

          // 段落与边距选项直接展示，不再折叠。
          ReaderSettingsSection(
            title: '段落与边距',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Divider(height: 1, thickness: 0.5),
                    const SizedBox(height: 12),

                    // 词间距
                    _buildSliderRow(
                      label: '词间距',
                      value: _current.wordSpacing,
                      min: 0.0,
                      max: 8.0,
                      divisions: 16,
                      valueText:
                          '${_current.wordSpacing.toStringAsFixed(1)} dp',
                      defaultValue: 0.0,
                      onChanged: (v) =>
                          _updatePreview(_current.copyWith(wordSpacing: v)),
                      onChangeEnd: (v) =>
                          _commitChange(_current.copyWith(wordSpacing: v)),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 4),
                      child: Text(
                        '仅对空格分隔的外文/数字单词生效，纯中文无空格不影响',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const Divider(height: 16, thickness: 0.5),

                    // 首行缩进
                    _buildSwitchTile(
                      icon: Icons.format_indent_increase_rounded,
                      title: '首行缩进',
                      subtitle: '普通正文段落首行缩进两字符宽',
                      value: _current.firstLineIndentChars > 0,
                      onChanged: (v) {
                        final updated = _current.copyWith(
                          firstLineIndentChars: v ? 2.0 : 0.0,
                        );
                        _commitChange(updated);
                      },
                      scheme: scheme,
                    ),
                    const Divider(height: 16, thickness: 0.5),

                    // 独立调整四周边距开关
                    _buildSwitchTile(
                      icon: Icons.space_bar_rounded,
                      title: '独立四周边距',
                      subtitle: _current.customMargins
                          ? '当前使用下方独立边距'
                          : '开启后可独立微调上、下、左、右边距',
                      value: _current.customMargins,
                      onChanged: (v) {
                        final updated = _current.copyWith(customMargins: v);
                        _commitChange(updated);
                      },
                      scheme: scheme,
                    ),

                    if (_current.customMargins) ...[
                      const SizedBox(height: 8),
                      _buildSliderRow(
                        label: '上边距',
                        value: _current.marginTop,
                        min: 44.0,
                        max: 120.0,
                        divisions: 38,
                        valueText: '${_current.marginTop.round()} dp',
                        defaultValue: 56.0,
                        onChanged: (v) =>
                            _updatePreview(_current.copyWith(marginTop: v)),
                        onChangeEnd: (v) =>
                            _commitChange(_current.copyWith(marginTop: v)),
                      ),
                      const SizedBox(height: 8),
                      _buildSliderRow(
                        label: '下边距',
                        value: _current.marginBottom,
                        min: 50.0,
                        max: 140.0,
                        divisions: 45,
                        valueText: '${_current.marginBottom.round()} dp',
                        defaultValue: 70.0,
                        onChanged: (v) =>
                            _updatePreview(_current.copyWith(marginBottom: v)),
                        onChangeEnd: (v) =>
                            _commitChange(_current.copyWith(marginBottom: v)),
                      ),
                      const SizedBox(height: 8),
                      _buildSliderRow(
                        label: '左边距',
                        value: _current.marginLeft,
                        min: 8.0,
                        max: 60.0,
                        divisions: 26,
                        valueText: '${_current.marginLeft.round()} dp',
                        defaultValue: 20.0,
                        onChanged: (v) =>
                            _updatePreview(_current.copyWith(marginLeft: v)),
                        onChangeEnd: (v) =>
                            _commitChange(_current.copyWith(marginLeft: v)),
                      ),
                      const SizedBox(height: 8),
                      _buildSliderRow(
                        label: '右边距',
                        value: _current.marginRight,
                        min: 8.0,
                        max: 60.0,
                        divisions: 26,
                        valueText: '${_current.marginRight.round()} dp',
                        defaultValue: 20.0,
                        onChanged: (v) =>
                            _updatePreview(_current.copyWith(marginRight: v)),
                        onChangeEnd: (v) =>
                            _commitChange(_current.copyWith(marginRight: v)),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // 恢复默认排版按钮
                    Center(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final std = ReaderTypography.standard();
                          _commitChange(std);
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('恢复默认排版'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 统一的开关行（去除深色独立卡片底色，与排版卡片无缝融合）
  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required ColorScheme scheme,
  }) {
    return SwitchListTile(
      tileColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      contentPadding: EdgeInsets.zero,
      isThreeLine: false,
      secondary: AppSettingIcon(icon),
      title: Text(title),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            )
          : null,
      value: value,
      onChanged: onChanged,
    );
  }

  /// 顶部实时排版预览卡片
  Widget _buildPreviewCard(ColorScheme scheme) {
    final textStyle = TextStyle(
      fontSize: _fontSize.clamp(13.0, 18.0),
      height: _current.lineHeight,
      fontWeight: _current.weight.fontWeight,
      color: widget.textColor,
      letterSpacing: _current.letterSpacing,
      wordSpacing: _current.wordSpacing > 0 ? _current.wordSpacing : null,
    );
    final previewIndent = _current.firstLineIndentChars * textStyle.fontSize!;

    return Container(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            offset: const Offset(0, 2),
            blurRadius: 6,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final leftItems = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_outlined,
                      size: 16, color: widget.textColor.withValues(alpha: 0.7)),
                  const SizedBox(width: 6),
                  Text('排版预览',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: widget.textColor.withValues(alpha: 0.7))),
                  if (widget.onPickTextColor != null) ...[
                    const SizedBox(width: 14),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: widget.onPickTextColor,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: widget.textColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '文字颜色',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                      color: widget.textColor
                                          .withValues(alpha: 0.7)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              );

              final rightText = Text(
                '${_current.currentPreset.label} · 行高 ${_current.lineHeight.toStringAsFixed(2)}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: widget.textColor.withValues(alpha: 0.7)),
              );

              if (constraints.maxWidth < 360) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    leftItems,
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerRight, child: rightText),
                  ],
                );
              }

              return Row(
                children: [
                  leftItems,
                  const Spacer(),
                  rightText,
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            '第一章 晨光初启',
            style: textStyle.copyWith(
              fontSize: textStyle.fontSize! * 1.15,
              fontWeight: FontWeight.bold,
              height: 1.35,
            ),
          ),
          SizedBox(height: _current.paragraphSpacing * 0.6),
          Text.rich(
            TextSpan(
              children: [
                if (previewIndent > 0)
                  WidgetSpan(
                    child: SizedBox(width: previewIndent, height: 1.0),
                  ),
                const TextSpan(
                  text: '微风轻柔地拂过静谧的平原，晨曦将远方的山岚染成一片浅金。旅人背好行囊，向着地平线迈出坚定的步伐。',
                ),
              ],
              style: textStyle,
            ),
            textAlign: _current.justify ? TextAlign.justify : TextAlign.start,
          ),
          SizedBox(height: _current.paragraphSpacing * 0.6),
          Text.rich(
            TextSpan(
              children: [
                if (previewIndent > 0)
                  WidgetSpan(
                    child: SizedBox(width: previewIndent, height: 1.0),
                  ),
                const TextSpan(
                  text: '文字如涟漪般在纸页间舒展（Light Novel），留驻下时光最深邃的印记。',
                ),
              ],
              style: textStyle,
            ),
            textAlign: _current.justify ? TextAlign.justify : TextAlign.start,
          ),
        ],
      ),
    );
  }

  /// 预设选择胶囊栏
  Widget _buildPresetBar(ColorScheme scheme) {
    final active = _current.currentPreset;
    final presets = [
      (ReaderTypographyPreset.compact, '紧凑'),
      (ReaderTypographyPreset.standard, '标准'),
      (ReaderTypographyPreset.loose, '宽松'),
      (ReaderTypographyPreset.custom, '自定义'),
    ];

    return Row(
      children: [
        for (var i = 0; i < presets.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: M3ChoiceChip(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              label: presets[i].$2,
              selected: active == presets[i].$1,
              onSelected: (_) {
                if (presets[i].$1 == ReaderTypographyPreset.custom) return;
                final target = switch (presets[i].$1) {
                  ReaderTypographyPreset.compact => ReaderTypography.compact(),
                  ReaderTypographyPreset.loose => ReaderTypography.loose(),
                  _ => ReaderTypography.standard(),
                };
                _commitChange(target.copyWith(weight: _current.weight));
              },
            ),
          ),
        ],
      ],
    );
  }

  /// 标签与读数可换行，滑杆独占一行以兼顾窄屏和大字体。
  Widget _buildSliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String valueText,
    required double defaultValue,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clampedValue = value.clamp(min, max);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 4,
          children: [
            Text(label,
                style: theme.textTheme.titleSmall?.copyWith(
                    color:
                        enabled ? scheme.onSurface : scheme.onSurfaceVariant)),
            Text(valueText,
                style: theme.textTheme.labelLarge?.copyWith(
                    color: enabled && (clampedValue - defaultValue).abs() < 0.02
                        ? scheme.primary
                        : scheme.onSurfaceVariant)),
          ],
        ),
        Semantics(
          label: label,
          child: Slider(
            value: clampedValue,
            min: min,
            max: max,
            divisions: divisions,
            label: valueText,
            semanticFormatterCallback: (_) => valueText,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
        ),
      ],
    );
  }
}
