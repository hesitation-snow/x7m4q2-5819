import 'dart:async';

import '../services/app_motion.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/store.dart';
import '../services/emoji_catalog.dart';
import '../widgets/common.dart';
import '../widgets/m3_menu_sheet.dart';

class DynamicPublishPage extends StatefulWidget {
  final LKTopicTag? initialTopic;
  const DynamicPublishPage({super.key, this.initialTopic});

  @override
  State<DynamicPublishPage> createState() => _DynamicPublishPageState();
}

class _DynamicPublishPageState extends State<DynamicPublishPage> {
  final _controller = TextEditingController();
  final _picker = ImagePicker();
  final _media = <LKDynamicMedia>[];
  List<LKEmojiGroup> _emojiGroups = const [];
  List<LKTopicTag> _topics = LKApi.cachedTopicTags;
  List<LKTopicTag> _recentTopics = const [];
  LKTopicTag? _selectedTopic;
  bool _uploading = false;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTopic;
    if (initial != null && initial.isUsable) {
      _selectedTopic = initial;
    }
    _loadEmojis();
    _loadRecentTopics();
    _loadTopics();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadEmojis() async {
    try {
      final groups = await YomiruEmojiCatalog.load();
      if (mounted) setState(() => _emojiGroups = groups);
    } catch (_) {}
  }

  Future<void> _loadRecentTopics() async {
    try {
      final recent = await LKStore.readRecentTopicTags();
      if (mounted) setState(() => _recentTopics = recent);
    } catch (_) {}
  }

  Future<void> _loadTopics() async {
    try {
      final topics = await LKApi.dynamicTopicTags();
      if (mounted) setState(() => _topics = topics);
    } catch (_) {
      // 话题拉取失败不影响发动态，保持已有缓存或空列表。
    }
  }

  void _toggleTopic(LKTopicTag tag) {
    setState(() {
      if (_selectedTopic != null && _selectedTopic!.matches(tag)) {
        _selectedTopic = null;
      } else {
        _selectedTopic = tag;
      }
    });
  }

  List<LKTopicTag> _quickTopics() {
    final quick = <LKTopicTag>[];
    void addUnique(LKTopicTag candidate) {
      if (quick.length >= 8) return;
      if (quick.any((item) => item.matches(candidate))) return;
      final refreshed = _topics.where((item) => item.matches(candidate));
      quick.add(refreshed.isNotEmpty ? refreshed.first : candidate);
    }

    final selected = _selectedTopic;
    if (selected != null && selected.isUsable) {
      addUnique(selected);
    }
    for (final tag in _recentTopics) {
      addUnique(tag);
    }
    for (final tag in _topics) {
      addUnique(tag);
    }
    return quick;
  }

  Future<void> _showTopicPicker() async {
    final picked = await showModalBottomSheet<LKTopicTag>(
      sheetAnimationStyle: AppMotion.style(context),
      context: context,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _TopicPickerSheet(
        initialTopics: _topics.isNotEmpty ? _topics : LKApi.cachedTopicTags,
        selectedTopic: _selectedTopic,
      ),
    );
    if (picked != null && mounted) {
      _toggleTopic(picked);
    }
  }

  Widget _buildTopicBar(BuildContext context) {
    final quickTopics = _quickTopics();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ActionChip(
            key: const ValueKey('topic-picker-open'),
            avatar: const Icon(Icons.tag_rounded, size: 16),
            label: const Text('选择话题'),
            visualDensity: VisualDensity.compact,
            onPressed: _publishing ? null : _showTopicPicker,
          ),
          for (final tag in quickTopics) ...[
            const SizedBox(width: 8),
            FilterChip(
              label: Text('# ${tag.name}'),
              selected:
                  _selectedTopic != null && _selectedTopic!.matches(tag),
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: _publishing ? null : (_) => _toggleTopic(tag),
            ),
          ],
        ],
      ),
    );
  }

  void _insertEmoji(String code) {
    final value = _controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(start, value.text.length);
    final text = value.text.replaceRange(start, end, code);
    _controller.value = value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: start + code.length),
      composing: TextRange.empty,
    );
  }

  Future<void> _showEmojiPicker() async {
    if (_emojiGroups.isEmpty) {
      showLkError(context, '表情加载中,请稍后再试');
      return;
    }
    final code = await showModalBottomSheet<String>(
      sheetAnimationStyle: AppMotion.style(context),
      context: context,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 460),
        child: M3MenuSheet(
          title: '选择表情',
          icon: Icons.emoji_emotions_outlined,
          children: _emojiGroups
              .map(
                (group) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (group.name.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(group.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: group.items
                            .where((item) => item.isImage)
                            .map(
                              (item) => InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => Navigator.pop(context, item.code),
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: CachedNetworkImage(
                                    fadeOutDuration:
                                        AppMotion.duration(context, 1000),
                                    fadeInDuration:
                                        AppMotion.duration(context, 500),
                                    imageUrl: YomiruEmojiCatalog.normalizeUrl(
                                        item.url),
                                    width: 38,
                                    height: 38,
                                    memCacheWidth:
                                        imageCacheDimension(context, 38),
                                    fit: BoxFit.contain,
                                    errorWidget: (_, __, ___) =>
                                        Text(item.code),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (code != null) _insertEmoji(code);
  }

  Future<void> _pickImage() async {
    if (_uploading || _media.length >= 9) return;
    final file = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 88, maxWidth: 2048);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      final uploaded = await LKApi.uploadDynamicImage(file.path);
      if (mounted) setState(() => _media.add(uploaded));
    } catch (e) {
      if (mounted) showLkError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _publish() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _publishing || _uploading) return;
    if (!LKClient.shared.session.isLoggedIn) {
      showLkError(context, '请先登录');
      return;
    }
    setState(() => _publishing = true);
    try {
      final topic = _selectedTopic;
      await LKApi.publishShortDynamic(
        content,
        media: _media,
        topic: topic,
      );
      if (topic != null && topic.isUsable) {
        unawaited(LKStore.recordRecentTopicTag(topic));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showLkError(context, e);
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final idleBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .25)),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('发布动态'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _publishing || _uploading ? null : _publish,
              child: Text(_publishing ? '发布中' : '发布'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _buildTopicBar(context),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            minLines: 6,
            maxLines: 12,
            maxLength: 2000,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '分享此刻想说的话…',
              filled: true,
              fillColor: scheme.surfaceContainerLow,
              contentPadding: const EdgeInsets.all(16),
              border: idleBorder,
              enabledBorder: idleBorder,
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: scheme.primary, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._media.asMap().entries.map((entry) => Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          fadeOutDuration: AppMotion.duration(context, 1000),
                          fadeInDuration: AppMotion.duration(context, 500),
                          imageUrl: entry.value.url,
                          width: 84,
                          height: 84,
                          memCacheWidth: imageCacheDimension(context, 84),
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () =>
                                setState(() => _media.removeAt(entry.key)),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  )),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _showEmojiPicker,
                icon: const Icon(Icons.emoji_emotions_outlined),
                label: const Text('表情'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _uploading ? null : _pickImage,
                icon: _uploading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: MotionProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_outlined),
                label: const Text('添加图片'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopicPickerSheet extends StatefulWidget {
  const _TopicPickerSheet({
    required this.initialTopics,
    required this.selectedTopic,
  });

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
                const M3SheetHeader(
                  title: '选择话题',
                  icon: Icons.tag_rounded,
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
                                        Text(
                                          '${tag.usageCount}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            color: isSelected
                                                ? scheme.onSecondaryContainer
                                                : scheme.onSurfaceVariant,
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
