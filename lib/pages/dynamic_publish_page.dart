import 'dart:async';
import 'dart:math' as math;

import '../services/app_motion.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/store.dart';
import '../services/avatar_cache.dart';
import '../services/emoji_catalog.dart';
import '../widgets/common.dart';
import '../widgets/emoji_panel.dart';
import '../widgets/topic_picker_sheet.dart';

class DynamicPublishPage extends StatefulWidget {
  final LKTopicTag? initialTopic;
  const DynamicPublishPage({super.key, this.initialTopic});

  @override
  State<DynamicPublishPage> createState() => _DynamicPublishPageState();
}

class _DynamicPublishPageState extends State<DynamicPublishPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _picker = ImagePicker();
  final _media = <LKDynamicMedia>[];
  List<LKEmojiGroup> _emojiGroups = const [];
  List<LKTopicTag> _topics = LKApi.cachedTopicTags;
  List<LKTopicTag> _recentTopics = const [];
  LKTopicTag? _selectedTopic;
  bool _showEmoji = false;
  bool _keyboardTransitioning = false;
  double _transitionHeight = 0;
  Timer? _transitionTimer;
  bool _uploading = false;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTopic;
    if (initial != null && initial.isUsable) {
      _selectedTopic = initial;
    }
    unawaited(LkEmojiKeyboardHeight.warmUp());
    _loadEmojis();
    _loadRecentTopics();
    _loadTopics();
  }

  @override
  void dispose() {
    _transitionTimer?.cancel();
    _focusNode.dispose();
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

  void _hideEmojiPanel() {
    _transitionTimer?.cancel();
    if (_showEmoji || _keyboardTransitioning) {
      setState(() {
        _showEmoji = false;
        _keyboardTransitioning = false;
      });
    }
  }

  Future<void> _showTopicPicker() async {
    _hideEmojiPanel();
    final picked = await showTopicPickerSheet(
      context,
      initialTopics: _topics.isNotEmpty ? _topics : LKApi.cachedTopicTags,
      selectedTopic: _selectedTopic,
    );
    if (picked != null && mounted) {
      _toggleTopic(picked);
    }
  }

  Widget _buildTopicBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final quickTopics = _quickTopics();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          ActionChip(
            key: const ValueKey('topic-picker-open'),
            avatar: Icon(Icons.tag_rounded, size: 16, color: scheme.primary),
            label: const Text('选择话题'),
            backgroundColor: scheme.primaryContainer.withValues(alpha: 0.45),
            side: BorderSide.none,
            shape: const StadiumBorder(),
            labelStyle: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface,
            ),
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
              shape: const StadiumBorder(),
              backgroundColor: scheme.surfaceContainerHigh,
              selectedColor: scheme.primaryContainer,
              side: BorderSide(
                color: (_selectedTopic != null && _selectedTopic!.matches(tag))
                    ? Colors.transparent
                    : scheme.outlineVariant.withValues(alpha: 0.35),
              ),
              labelStyle: TextStyle(
                fontSize: 13,
                fontWeight:
                    (_selectedTopic != null && _selectedTopic!.matches(tag))
                        ? FontWeight.w600
                        : FontWeight.w400,
                color: (_selectedTopic != null && _selectedTopic!.matches(tag))
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
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

  void _returnToKeyboard() {
    _transitionTimer?.cancel();
    final currentH = LkEmojiKeyboardHeight.panelHeight(
      context,
      reservedHeight: 220,
    );
    setState(() {
      _showEmoji = false;
      _keyboardTransitioning = true;
      _transitionHeight = currentH;
    });
    _focusNode.requestFocus();
    _transitionTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && _keyboardTransitioning) {
        setState(() => _keyboardTransitioning = false);
      }
    });
  }

  void _toggleEmoji() {
    if (_emojiGroups.isEmpty) {
      showLkError(context, '表情加载中,请稍后再试');
      return;
    }
    if (_showEmoji) {
      _returnToKeyboard();
    } else {
      _transitionTimer?.cancel();
      _keyboardTransitioning = false;
      _focusNode.unfocus();
      setState(() {
        _showEmoji = true;
      });
    }
  }

  Future<void> _pickImage() async {
    if (_uploading || _media.length >= 9) return;
    _hideEmojiPanel();
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

  Widget _buildAuthorHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = LKClient.shared.session;
    final avatar = YomiruAvatarCache.providerOrNull(session.avatar);
    final displayName =
        session.nickname.trim().isNotEmpty ? session.nickname.trim() : '动态发布';
    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: scheme.surfaceContainerHighest,
          backgroundImage: avatar,
          child: avatar == null
              ? Icon(Icons.person_rounded,
                  size: 20, color: scheme.onSurfaceVariant)
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: ShapeDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: const StadiumBorder(),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.public_rounded,
                        size: 12, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      '公开',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMediaGrid(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_media.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          ..._media.asMap().entries.map((entry) => Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.25),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: CachedNetworkImage(
                        fadeOutDuration: AppMotion.duration(context, 1000),
                        fadeInDuration: AppMotion.duration(context, 500),
                        imageUrl: entry.value.url,
                        width: 96,
                        height: 96,
                        memCacheWidth: imageCacheDimension(context, 96),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 5,
                    top: 5,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.62),
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () =>
                            setState(() => _media.removeAt(entry.key)),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 15,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )),
          if (_media.length < 9)
            Material(
              color: scheme.surfaceContainerHigh.withValues(alpha: 0.65),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.35),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _uploading ? null : _pickImage,
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: _uploading
                      ? const Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: MotionProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 26,
                          color: scheme.onSurfaceVariant,
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomComposerDock(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    final inset = media.viewInsets.bottom;
    LkEmojiKeyboardHeight.recordInset(inset);
    if (_keyboardTransitioning && inset >= _transitionHeight - 1.0) {
      _keyboardTransitioning = false;
      _transitionTimer?.cancel();
    }
    final panelH = LkEmojiKeyboardHeight.panelHeight(
      context,
      reservedHeight: 220,
    );
    final double bottomSpacing;
    if (_showEmoji) {
      bottomSpacing = panelH;
    } else if (_keyboardTransitioning) {
      bottomSpacing = math.max(_transitionHeight, inset);
    } else {
      bottomSpacing = inset;
    }
    final hasBottomCover = _showEmoji || bottomSpacing > 0;

    return Material(
      color: scheme.surfaceContainerLow,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.22),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SafeArea(
              top: false,
              bottom: !hasBottomCover,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 10),
                  _buildTopicBar(context),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 16, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    foregroundColor: _showEmoji
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    shape: const StadiumBorder(),
                                  ),
                                  onPressed: _publishing ? null : _toggleEmoji,
                                  icon: Icon(
                                    _showEmoji
                                        ? Icons.keyboard_alt_outlined
                                        : Icons.sentiment_satisfied_alt_rounded,
                                    size: 20,
                                  ),
                                  label: Text(_showEmoji ? '键盘' : '表情'),
                                ),
                                const SizedBox(width: 4),
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    foregroundColor: scheme.onSurfaceVariant,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    shape: const StadiumBorder(),
                                  ),
                                  onPressed: _uploading ||
                                          _publishing ||
                                          _media.length >= 9
                                      ? null
                                      : _pickImage,
                                  icon: _uploading
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: MotionProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Icon(
                                          Icons.photo_library_outlined,
                                          size: 20,
                                        ),
                                  label: Text(
                                    _media.isEmpty
                                        ? '图片'
                                        : '图片 ${_media.length}/9',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _controller,
                          builder: (context, value, _) {
                            final length = value.text.characters.length;
                            final nearLimit = length >= 1800;
                            final countColor = nearLimit
                                ? scheme.error
                                : scheme.onSurfaceVariant
                                    .withValues(alpha: 0.78);
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    value: (length / 2000).clamp(0.0, 1.0),
                                    strokeWidth: 2,
                                    strokeCap: StrokeCap.round,
                                    color: nearLimit
                                        ? scheme.error
                                        : scheme.primary
                                            .withValues(alpha: 0.85),
                                    backgroundColor: scheme.outlineVariant
                                        .withValues(alpha: 0.25),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '$length/2000',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: countColor,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_showEmoji)
              SizedBox(
                height: panelH,
                child: Material(
                  color: scheme.surfaceContainer,
                  child: SafeArea(
                    top: false,
                    child: LkEmojiPanel(
                      groups: _emojiGroups,
                      onPick: _insertEmoji,
                    ),
                  ),
                ),
              )
            else if (bottomSpacing > 0)
              SizedBox(height: bottomSpacing),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PopScope(
      canPop: !_showEmoji,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showEmoji) {
          setState(() => _showEmoji = false);
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          centerTitle: true,
          leading: IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.close_rounded),
          ),
          title: Text(
            '发布动态',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, _) {
                  final hasText = value.text.trim().isNotEmpty;
                  return FilledButton(
                    style: FilledButton.styleFrom(
                      shape: const StadiumBorder(),
                      minimumSize: const Size(68, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      backgroundColor: hasText
                          ? scheme.primary
                          : scheme.surfaceContainerHighest,
                      foregroundColor:
                          hasText ? scheme.onPrimary : scheme.onSurfaceVariant,
                    ),
                    onPressed: _publishing || _uploading ? null : _publish,
                    child: Text(_publishing ? '发布中' : '发布'),
                  );
                },
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildAuthorHeader(context),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      minLines: 7,
                      maxLines: null,
                      maxLength: 2000,
                      autofocus: true,
                      onTap: () {
                        if (_showEmoji) {
                          _returnToKeyboard();
                        }
                      },
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontSize: 16.5,
                        height: 1.65,
                        color: scheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        hintText: '分享此刻想说的话…',
                        hintStyle: theme.textTheme.bodyLarge?.copyWith(
                          fontSize: 16.5,
                          color:
                              scheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        counterText: '',
                      ),
                    ),
                    _buildMediaGrid(context),
                  ],
                ),
              ),
            ),
            _buildBottomComposerDock(context),
          ],
        ),
      ),
    );
  }
}
