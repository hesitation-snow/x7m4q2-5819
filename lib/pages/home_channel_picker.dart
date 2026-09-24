import 'package:flutter/material.dart';

import '../api/home_channels.dart';

class HomeChannelPickerResult {
  const HomeChannelPickerResult({required this.selectedCode, this.order});

  final String selectedCode;
  final List<String>? order;
}

/// 分类入口兼具浏览和排序：列表的前三项就是首页的三个标签。
class HomeChannelPicker extends StatefulWidget {
  const HomeChannelPicker({
    super.key,
    required this.order,
    required this.selectedCode,
  });

  final List<String> order;
  final String selectedCode;

  @override
  State<HomeChannelPicker> createState() => _HomeChannelPickerState();
}

class _HomeChannelPickerState extends State<HomeChannelPicker> {
  late List<String> _order;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _order = normalizeHomeChannelOrder(widget.order).toList();
  }

  IconData _iconFor(String code) => switch (code) {
        'hot' => Icons.local_fire_department_rounded,
        'recent' => Icons.schedule_rounded,
        'rank' => Icons.leaderboard_rounded,
        'lightnovel' => Icons.auto_stories_rounded,
        'original' => Icons.edit_note_rounded,
        'fanfic' => Icons.auto_awesome_rounded,
        _ => Icons.menu_book_rounded,
      };

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final code = _order.removeAt(oldIndex);
      _order.insert(newIndex, code);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: _editing
            ? SizedBox(
                height: maxHeight.clamp(0.0, 550.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(
                      title: '编辑分类',
                      action: TextButton(
                        onPressed: () => Navigator.of(context).pop(
                          HomeChannelPickerResult(
                            selectedCode: widget.selectedCode,
                            order: List<String>.of(_order),
                          ),
                        ),
                        child: const Text('完成'),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                      child: Text(
                        '拖动调整顺序，前 3 个显示在首页',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: _order.length,
                        onReorderItem: _reorder,
                        itemBuilder: (context, index) {
                          final code = _order[index];
                          final channel = homeChannelByCode(code);
                          final primary = index < homePrimaryChannelCount;
                          return Padding(
                            key: ValueKey(code),
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Material(
                              color: primary
                                  ? scheme.primaryContainer
                                      .withValues(alpha: 0.35)
                                  : scheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(14),
                              child: ReorderableDelayedDragStartListener(
                                index: index,
                                child: ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  leading: Icon(
                                    _iconFor(code),
                                    color: primary
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  title: Text(channel.label),
                                  subtitle: primary
                                      ? Text('首页标签 ${index + 1}')
                                      : null,
                                  trailing: ReorderableDragStartListener(
                                    index: index,
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Icon(Icons.drag_handle_rounded),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              )
            : ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(
                        title: '分类',
                        action: TextButton.icon(
                          onPressed: () => setState(() => _editing = true),
                          icon: const Icon(Icons.tune_rounded, size: 18),
                          label: const Text('编辑'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _order.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          mainAxisExtent: 68,
                        ),
                        itemBuilder: (context, index) {
                          final code = _order[index];
                          final channel = homeChannelByCode(code);
                          final selected = code == widget.selectedCode;
                          return Material(
                            color: selected
                                ? scheme.primaryContainer
                                    .withValues(alpha: 0.55)
                                : scheme.surfaceContainerLow,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                              side: BorderSide(
                                color: selected
                                    ? scheme.primary.withValues(alpha: 0.45)
                                    : scheme.outlineVariant
                                        .withValues(alpha: 0.22),
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => Navigator.of(context).pop(
                                HomeChannelPickerResult(selectedCode: code),
                              ),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                child: Row(
                                  children: [
                                    Icon(
                                      _iconFor(code),
                                      size: 20,
                                      color: selected
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            channel.label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.w500,
                                              color: selected
                                                  ? scheme.primary
                                                  : scheme.onSurface,
                                            ),
                                          ),
                                          if (index < homePrimaryChannelCount)
                                            Text(
                                              '首页 ${index + 1}',
                                              style: theme.textTheme.labelSmall
                                                  ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _header({required String title, required Widget action}) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        action,
      ],
    );
  }
}
