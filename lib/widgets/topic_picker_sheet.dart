import 'dart:async';

import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/models.dart';
import '../services/app_motion.dart';
import 'm3_menu_sheet.dart';

/// Shows the searchable official topic picker bottom sheet.
/// Returns the tapped [LKTopicTag], or `null` when dismissed without picking.
Future<LKTopicTag?> showTopicPickerSheet(
  BuildContext context, {
  List<LKTopicTag> initialTopics = const [],
  LKTopicTag? selectedTopic,
  String title = '选择话题',
}) {
  return showModalBottomSheet<LKTopicTag>(
    sheetAnimationStyle: AppMotion.style(context),
    context: context,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _TopicPickerSheet(
      title: title,
      initialTopics: initialTopics,
      selectedTopic: selectedTopic,
    ),
  );
}

class _TopicPickerSheet extends StatefulWidget {
  const _TopicPickerSheet({
    required this.title,
    required this.initialTopics,
    required this.selectedTopic,
  });

  final String title;
  final List<LKTopicTag> initialTopics;
  final LKTopicTag? selectedTopic;

  @override
  State<_TopicPickerSheet> createState() => _TopicPickerSheetState();
}

class _TopicPickerSheetState extends State<_TopicPickerSheet> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  late List<LKTopicTag> _topics = widget.initialTopics;
  bool _loading = false;
  bool _failed = false;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    if (_topics.isEmpty) {
      _fetchTopics('');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchTopics(String query) async {
    final seq = ++_searchSeq;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final result = await LKApi.dynamicTopicTags(q: query);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _topics = result;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || seq != _searchSeq) return;
      final trimmed = query.trim().toLowerCase();
      final fallback = widget.initialTopics.isNotEmpty
          ? widget.initialTopics
          : LKApi.cachedTopicTags;
      final localMatches = trimmed.isEmpty
          ? fallback
          : fallback
              .where((tag) => tag.name.toLowerCase().contains(trimmed))
              .toList(growable: false);
      setState(() {
        _topics = localMatches;
        _loading = false;
        _failed = localMatches.isEmpty;
      });
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      _searchSeq++;
      final cached = widget.initialTopics.isNotEmpty
          ? widget.initialTopics
          : LKApi.cachedTopicTags;
      setState(() {
        _topics = cached;
        _loading = false;
        _failed = false;
      });
      if (cached.isEmpty) {
        _fetchTopics('');
      }
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchTopics(query);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = widget.selectedTopic;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
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
                M3SheetHeader(
                  title: widget.title,
                  icon: Icons.tag_rounded,
                  action: selected == null
                      ? null
                      : TextButton(
                          key: const ValueKey('topic-picker-clear'),
                          onPressed: () => Navigator.pop(context, selected),
                          child: const Text('清除'),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: TextField(
                    key: const ValueKey('topic-search-input'),
                    controller: _searchController,
                    onChanged: _onQueryChanged,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: '搜索官方话题',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _searchController,
                        builder: (context, value, _) => value.text.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(
                                tooltip: '清空',
                                onPressed: () {
                                  _searchController.clear();
                                  _onQueryChanged('');
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                      ),
                      filled: true,
                      fillColor: scheme.surfaceContainerHigh,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                if (_loading && _topics.isNotEmpty)
                  const LinearProgressIndicator(minHeight: 2),
                Flexible(
                  child: _loading && _topics.isEmpty
                      ? const SizedBox(
                          height: 180,
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      : _topics.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _failed ? '暂时无法加载话题' : '没有找到匹配的话题',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  if (_failed) ...[
                                    const SizedBox(height: 10),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _fetchTopics(_searchController.text),
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: const Text('重试'),
                                    ),
                                  ],
                                ],
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                              itemCount: _topics.length,
                              itemBuilder: (context, index) {
                                final tag = _topics[index];
                                final isSelected =
                                    selected != null && selected.matches(tag);
                                return ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  selected: isSelected,
                                  selectedTileColor: scheme.secondaryContainer
                                      .withValues(alpha: 0.65),
                                  title: Text(
                                    '# ${tag.name}',
                                    style: TextStyle(
                                      fontWeight: isSelected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: isSelected
                                          ? scheme.onSecondaryContainer
                                          : scheme.onSurface,
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (tag.usageCount > 0)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 3),
                                          decoration: ShapeDecoration(
                                            color: isSelected
                                                ? scheme.secondaryContainer
                                                : scheme.surfaceContainerHigh,
                                            shape: const StadiumBorder(),
                                          ),
                                          child: Text(
                                            '${tag.usageCount} 讨论',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                              color: isSelected
                                                  ? scheme.onSecondaryContainer
                                                  : scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      if (isSelected) ...[
                                        if (tag.usageCount > 0)
                                          const SizedBox(width: 8),
                                        Icon(
                                          Icons.check_rounded,
                                          size: 20,
                                          color: scheme.primary,
                                        ),
                                      ],
                                    ],
                                  ),
                                  onTap: () => Navigator.pop(context, tag),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
