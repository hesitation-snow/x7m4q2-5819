import '../services/app_motion.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../services/emoji_catalog.dart';
import '../widgets/common.dart';
import '../widgets/m3_menu_sheet.dart';

class DynamicPublishPage extends StatefulWidget {
  const DynamicPublishPage({super.key});

  @override
  State<DynamicPublishPage> createState() => _DynamicPublishPageState();
}

class _DynamicPublishPageState extends State<DynamicPublishPage> {
  final _controller = TextEditingController();
  final _picker = ImagePicker();
  final _media = <LKDynamicMedia>[];
  List<LKEmojiGroup> _emojiGroups = const [];
  bool _uploading = false;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _loadEmojis();
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
      await LKApi.publishShortDynamic(content, media: _media);
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
