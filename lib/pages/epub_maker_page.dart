import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../api/models.dart';
import '../api/store.dart';
import '../services/app_motion.dart';
import '../services/epub/epub_download_service.dart';
import '../services/epub/epub_models.dart';
import '../widgets/common.dart';

class EpubMakerPage extends StatefulWidget {
  final LKBook book;
  final List<LKVolume> initialVolumes;

  const EpubMakerPage({
    super.key,
    required this.book,
    required this.initialVolumes,
  });

  @override
  State<EpubMakerPage> createState() => _EpubMakerPageState();
}

class _EpubMakerPageState extends State<EpubMakerPage> {
  final EpubDownloadService _service = EpubDownloadService.shared;
  final Set<int> _selectedVolumeIds = {};
  bool _includeIllustrations = true;
  bool _exportAsTxt = false;
  bool _warnedDataSaver = false;
  final GlobalKey _shareButtonKey = GlobalKey();

  TextEditingController? _titleController;
  String? _selectedCoverPath;
  int? _lastEditingBookId;

  @override
  void initState() {
    super.initState();
    _includeIllustrations = !LKStore.dataSaverMode.value;
    // 书籍导出不要默认全选所有章节，由用户手动勾选或点全选
  }

  @override
  void dispose() {
    _titleController?.dispose();
    super.dispose();
  }

  void _initEditingStateIfNeeded(EpubDownloadTask task) {
    if (_lastEditingBookId != task.bookId || _titleController == null) {
      _lastEditingBookId = task.bookId;
      _titleController?.dispose();
      final presetTitle = task.customTitle?.trim().isNotEmpty == true
          ? task.customTitle!
          : computeDefaultEpubTitle(task.bookTitle, task.selectedVolumes);
      _titleController = TextEditingController(text: presetTitle);
      _selectedCoverPath = task.customCoverPath;
    }
  }

  Future<void> _confirmAndPackage(EpubDownloadTask task) async {
    final title = _titleController?.text.trim();
    if (title == null || title.isEmpty) {
      showFloatingPrompt(context, '标题不能为空');
      return;
    }
    await _service.confirmMetadataAndPackage(
      customTitle: title,
      customCoverPath: _selectedCoverPath,
    );
  }

  int get _selectedChapterCount {
    var count = 0;
    for (final v in widget.initialVolumes) {
      if (_selectedVolumeIds.contains(v.volumeId)) {
        count += v.chapterCount > 0 ? v.chapterCount : 0;
      }
    }
    return count;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _toggleIncludeIllustrations(bool value) async {
    if (value && LKStore.dataSaverMode.value && !_warnedDataSaver) {
      final confirmed = await showDialog<bool>(
        context: context,
        animationStyle: AppMotion.style(context),
        builder: (ctx) => AlertDialog(
          title: const Text('流量提醒'),
          content: const Text('当前已开启流量节省模式。下载包含插画的 EPUB 将消耗额外的网络流量，是否确认开启？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认开启'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      _warnedDataSaver = true;
    }
    setState(() => _includeIllustrations = value);
  }

  Future<void> _startMaking() async {
    if (_selectedVolumeIds.isEmpty) {
      showFloatingPrompt(context, '请至少选择一卷');
      return;
    }
    final selectedVolumes = widget.initialVolumes
        .where((v) => _selectedVolumeIds.contains(v.volumeId))
        .toList();

    try {
      await _service.startTask(
        book: widget.book,
        selectedVolumes: selectedVolumes,
        options: EpubExportOptions(
          includeIllustrations: !_exportAsTxt && _includeIllustrations,
          exportAsTxt: _exportAsTxt,
        ),
      );
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: AppMotion.style(context),
      builder: (ctx) => AlertDialog(
        title: const Text('取消制作'),
        content: const Text('确定要取消本次书籍制作吗？已下载的临时章节与图片将被清理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续制作'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('取消制作'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _service.cancelTask();
    }
  }

  Rect _calculateShareOrigin() {
    final renderBox = _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      final origin = renderBox.localToGlobal(Offset.zero) & renderBox.size;
      if (!origin.isEmpty) return origin;
    }
    final size = MediaQuery.sizeOf(context);
    return Rect.fromLTWH(size.width / 4, size.height / 2, size.width / 2, 1);
  }

  Future<void> _pickCustomLocalCover() async {
    try {
      final picker = ImagePicker();
      final photo = await picker.pickImage(source: ImageSource.gallery);
      if (photo != null && mounted) {
        setState(() {
          _selectedCoverPath = photo.path;
        });
      }
    } catch (e) {
      if (mounted) {
        showFloatingPrompt(context, '选择图片失败: $e');
      }
    }
  }

  Future<void> _saveAsDocument(
    String filePath,
    String fileName, {
    String? mimeType,
  }) async {
    final effectiveMime = mimeType ??
        (fileName.endsWith('.txt') ? 'text/plain' : 'application/epub+zip');
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        const platform = MethodChannel('moe.yutro.yomiru/epub_export');
        final saved = await platform.invokeMethod<bool>('saveDocument', {
          'filePath': filePath,
          'fileName': fileName,
          'mimeType': effectiveMime,
        });
        if (saved == true && mounted) {
          showFloatingPrompt(context, '文件已另存为');
          return;
        } else if (saved == false) {
          return;
        }
      } catch (e) {
        if (mounted) {
          showFloatingPrompt(context, '另存为失败: $e');
        }
        return;
      }
    }
  }

  Future<void> _shareBookFile(
    String filePath,
    String fileName, {
    required String mimeType,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        if (mounted) {
          showLkError(
            context,
            fileName.endsWith('.txt') ? 'TXT 文件不存在，请重新制作' : 'EPUB 文件不存在，请重新制作',
          );
        }
        return;
      }
      final origin = _calculateShareOrigin();
      await Share.shareXFiles(
        [
          XFile(
            filePath,
            mimeType: mimeType,
            name: fileName,
          ),
        ],
        subject: fileName,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (mounted) showLkError(context, '导出失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍导出'),
      ),
      body: ValueListenableBuilder<EpubDownloadTask?>(
        valueListenable: _service.currentTask,
        builder: (context, task, _) {
          // 如果当前有本小说的任务或正在进行
          if (task != null && task.bookId == widget.book.bookId && !task.isTerminal) {
            if (task.phase == EpubTaskPhase.editingMetadata) {
              return _buildMetadataEditingView(context, task);
            }
            return _buildProgressView(context, task);
          }
          if (task != null && task.bookId == widget.book.bookId && task.phase == EpubTaskPhase.completed) {
            return _buildCompletedView(context, task);
          }
          return _buildConfigView(context);
        },
      ),
    );
  }

  // ==================== 配置视图 ====================

  Widget _buildConfigView(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final b = widget.book;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              // 书籍头部卡片
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      CoverImage(
                        url: b.coverUrl,
                        width: 60,
                        height: 82,
                        radius: 6,
                        isBrave: b.isBrave,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              b.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              b.authorName.isNotEmpty ? '作者：${b.authorName}' : '轻之国度',
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '共 ${widget.initialVolumes.length} 卷',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 插画选项卡片
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                child: SwitchListTile(
                  secondary: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _exportAsTxt
                          ? scheme.onSurface.withValues(alpha: 0.08)
                          : scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.image_outlined,
                      color: _exportAsTxt
                          ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                          : scheme.primary,
                      size: 20,
                    ),
                  ),
                  title: Text(
                    '包含封面与插画',
                    style: TextStyle(
                      color: _exportAsTxt
                          ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                          : null,
                    ),
                  ),
                  subtitle: Text(
                    _exportAsTxt
                        ? 'TXT 纯文本格式不支持图片与插画'
                        : '下载书中插画并在 EPUB 中排版',
                  ),
                  value: _exportAsTxt ? false : _includeIllustrations,
                  onChanged: _exportAsTxt ? null : _toggleIncludeIllustrations,
                ),
              ),
              const SizedBox(height: 12),

              // 仅文本（保存为 TXT）选项卡片
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                child: SwitchListTile(
                  secondary: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.description_outlined,
                        color: scheme.primary, size: 20),
                  ),
                  title: const Text('仅文本（保存为 TXT）'),
                  subtitle: const Text('导出为纯文本文件，不包含插画与复杂排版'),
                  value: _exportAsTxt,
                  onChanged: (v) {
                    setState(() {
                      _exportAsTxt = v;
                    });
                  },
                ),
              ),
              const SizedBox(height: 12),

              // 导出账号标识提示卡片
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '导出文件包含可还原的发布者与当前导出账号 UID 标识',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // 卷选择标题与快捷按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '选择导出卷',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _selectedVolumeIds.addAll(
                              widget.initialVolumes.map((v) => v.volumeId),
                            );
                          });
                        },
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() => _selectedVolumeIds.clear());
                        },
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // 卷列表
              ...widget.initialVolumes.map((v) {
                final isSelected = _selectedVolumeIds.contains(v.volumeId);
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: isSelected
                          ? scheme.primary.withValues(alpha: 0.5)
                          : scheme.outlineVariant.withValues(alpha: 0.25),
                    ),
                  ),
                  child: CheckboxListTile(
                    title: Text(
                      v.title.isEmpty ? '默认卷' : v.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    subtitle: v.chapterCount > 0 ? Text('${v.chapterCount} 章') : null,
                    value: isSelected,
                    onChanged: (val) {
                      setState(() {
                        if (val == true) {
                          _selectedVolumeIds.add(v.volumeId);
                        } else {
                          _selectedVolumeIds.remove(v.volumeId);
                        }
                      });
                    },
                  ),
                );
              }),
            ],
          ),
        ),

        // 底部开始制作栏
        Container(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            MediaQuery.of(context).padding.bottom + 12,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                offset: const Offset(0, -2),
                blurRadius: 8,
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已选择 ${_selectedVolumeIds.length} 卷 · $_selectedChapterCount 章',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _exportAsTxt
                          ? '导出为 TXT 纯文本'
                          : (_includeIllustrations ? '包含封面与插画' : '仅纯文本正文'),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _selectedVolumeIds.isEmpty ? null : _startMaking,
                icon: const Icon(Icons.download_rounded),
                label: const Text('开始制作'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ==================== 进度与调度视图 ====================

  Widget _buildProgressView(BuildContext context, EpubDownloadTask task) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final currentStep = switch (task.phase) {
      EpubTaskPhase.fetchingCatalog => 0,
      EpubTaskPhase.downloadingContent => 1,
      EpubTaskPhase.editingMetadata => 2,
      EpubTaskPhase.packaging => 3,
      EpubTaskPhase.completed => 4,
      _ => 1,
    };

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // 5 阶段进度条
        _buildStepper(currentStep, isTxt: task.options.exportAsTxt),
        const SizedBox(height: 36),

        // 状态卡片
        Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                if (task.isPaused)
                  Icon(Icons.pause_circle_outline_rounded, size: 48, color: scheme.primary)
                else if (task.phase == EpubTaskPhase.packaging)
                  const SizedBox.square(
                    dimension: 48,
                    child: MotionProgressIndicator(strokeWidth: 3),
                  )
                else
                  Icon(Icons.cloud_download_outlined, size: 48, color: scheme.primary),
                const SizedBox(height: 16),
                Text(
                  task.statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),

                // 进度条
                if (task.phase == EpubTaskPhase.downloadingContent) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: task.downloadProgress,
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '已完成 ${task.completedCount} / ${task.totalChapters} 章',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${(task.downloadProgress * 100).toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: scheme.primary,
                        ),
                      ),
                    ],
                  ),
                  if (task.options.includeIllustrations || task.speedText.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (task.options.includeIllustrations)
                            Expanded(
                              child: Row(
                                children: [
                                  Icon(Icons.photo_library_outlined,
                                      size: 15, color: scheme.primary),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      task.currentIllustrationTotal > 0
                                          ? '插画: 第 ${task.currentIllustrationIndex} / ${task.currentIllustrationTotal} 张 · 累计 ${task.illustrationDownloadedCount} 张'
                                          : '插画: 已下载 ${task.illustrationDownloadedCount} 张',
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            const Spacer(),
                          if (task.speedText.isNotEmpty)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.speed_rounded,
                                    size: 15, color: scheme.primary),
                                const SizedBox(width: 4),
                                Text(
                                  task.speedText,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.primary,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),

        // 如果存在失败章节，显示失败列表
        if (task.failedCount > 0) ...[
          Card(
            color: scheme.errorContainer.withValues(alpha: 0.2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: scheme.error.withValues(alpha: 0.4),
              ),
            ),
            child: ExpansionTile(
              initiallyExpanded: true,
              leading: Icon(Icons.warning_amber_rounded, color: scheme.error),
              title: Text(
                '有 ${task.failedCount} 个章节下载未成功',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.error,
                ),
              ),
              subtitle: const Text('可一键重试或直接导出已完成部分'),
              children: [
                for (final entry in task.failedChapters.entries) ...[
                  ListTile(
                    dense: true,
                    title: Text(
                      _findChapterTitle(task, entry.key),
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      entry.value,
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _service.retryFailedChapters(),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('重试失败章节'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: () => _service.exportCompletedContent(),
                          child: const Text('导出已完成内容'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],

        // 控制按钮（暂停 / 继续 / 取消）
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _confirmCancel,
                icon: const Icon(Icons.close_rounded),
                label: const Text('取消制作'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.icon(
                onPressed: task.isPaused
                    ? () => _service.resumeTask()
                    : () => _service.pauseTask(),
                icon: Icon(task.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                label: Text(task.isPaused ? '继续' : '暂停'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _findChapterTitle(EpubDownloadTask task, int chapterId) {
    for (final c in task.chapters) {
      if (c.chapterId == chapterId) return c.title;
    }
    return '章节 $chapterId';
  }

  Widget _buildStepIndicator(int stepIndex, String title, int currentStep) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDone = stepIndex < currentStep;
    final isCurrent = stepIndex == currentStep;

    final color = isDone || isCurrent ? scheme.primary : scheme.outlineVariant;

    return Column(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: isDone ? scheme.primary : (isCurrent ? scheme.primary.withValues(alpha: 0.15) : Colors.transparent),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          alignment: Alignment.center,
          child: isDone
              ? Icon(Icons.check_rounded, size: 16, color: scheme.onPrimary)
              : Text(
                  '${stepIndex + 1}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildStepLine(bool active) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 20),
        color: active ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }

  Widget _buildStepper(int currentStep, {bool isTxt = false}) {
    return Row(
      children: [
        _buildStepIndicator(0, '获取目录', currentStep),
        _buildStepLine(0 < currentStep),
        _buildStepIndicator(1, isTxt ? '下载正文' : '正文插画', currentStep),
        _buildStepLine(1 < currentStep),
        _buildStepIndicator(2, isTxt ? '确认标题' : '封面标题', currentStep),
        _buildStepLine(2 < currentStep),
        _buildStepIndicator(3, isTxt ? '生成文本' : '制作文件', currentStep),
        _buildStepLine(3 < currentStep),
        _buildStepIndicator(4, '完成', currentStep),
      ],
    );
  }

  // ==================== 封面与标题编辑视图 ====================

  Widget _buildMetadataEditingView(BuildContext context, EpubDownloadTask task) {
    _initEditingStateIfNeeded(task);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final isDefaultSelected = _selectedCoverPath == null ||
        _selectedCoverPath!.isEmpty ||
        _selectedCoverPath!.endsWith('cover.jpg');

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // 5 阶段进度条（第 2 步：封面标题/确认标题）
              _buildStepper(2, isTxt: task.options.exportAsTxt),
              const SizedBox(height: 24),

              // 标题编辑卡片
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.edit_note_rounded,
                              size: 20, color: scheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            '文件与书籍标题',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _titleController,
                        decoration: InputDecoration(
                          labelText: task.options.exportAsTxt ? 'TXT 标题' : 'EPUB 标题',
                          hintText: '输入自定义标题',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.refresh_rounded, size: 20),
                            tooltip: '恢复预设标题',
                            onPressed: () {
                              final preset = computeDefaultEpubTitle(
                                task.bookTitle,
                                task.selectedVolumes,
                              );
                              _titleController?.text = preset;
                              setState(() {});
                            },
                          ),
                          helperText: task.options.exportAsTxt
                              ? '预设格式：书名  [卷名]，作为导出文本标题及文件名'
                              : '预设格式：书名  [卷名]，作为电子书内标题及导出文件名',
                          helperMaxLines: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 导出账号标识提示卡片
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        task.options.exportAsTxt
                            ? '导出的文件包含可还原的账号 UID 标识'
                            : '导出的 EPUB 元数据中包含可还原的发布者与当前导出账号 UID 标识',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // 封面自选卡片（TXT 纯文本模式无封面，直接隐藏）
              if (!task.options.exportAsTxt) ...[
                const SizedBox(height: 20),
                Card(
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.photo_library_outlined,
                                size: 20, color: scheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              '电子书封面',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '预设使用书籍默认封面，或点击下方已下载插画切换',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),

                        // 当前选中的封面大图预览
                        Center(
                          child: _buildCoverPreview(task),
                        ),
                        const SizedBox(height: 20),

                        // 封面选择横向列表（默认封面 + 本机图片 + 可选插画）
                        Row(
                          children: [
                            Text(
                              '选择封面：',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            if (task.availableIllustrationPaths.isNotEmpty)
                              Text(
                                '（含 ${task.availableIllustrationPaths.length} 张插画）',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 122,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: 2 + task.availableIllustrationPaths.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return _buildCoverChoiceTile(
                                  label: '默认封面',
                                  isSelected: isDefaultSelected,
                                  onTap: () {
                                    setState(() {
                                      _selectedCoverPath = null;
                                    });
                                  },
                                  image: _buildDefaultCoverThumbnail(task),
                                );
                              }
                              if (index == 1) {
                                final isCustomLocalSelected = !isDefaultSelected &&
                                    _selectedCoverPath != null &&
                                    !task.availableIllustrationPaths.contains(_selectedCoverPath);
                                final hasLocalFile = isCustomLocalSelected &&
                                    File(_selectedCoverPath!).existsSync();
                                return _buildCoverChoiceTile(
                                  label: hasLocalFile ? '本机图片' : '自选本机',
                                  isSelected: isCustomLocalSelected,
                                  onTap: _pickCustomLocalCover,
                                  image: hasLocalFile
                                      ? Image.file(
                                          File(_selectedCoverPath!),
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              _buildPlaceholderCover(),
                                        )
                                      : Container(
                                          color: scheme.surfaceContainerHighest,
                                          alignment: Alignment.center,
                                          child: Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                Icons.add_photo_alternate_rounded,
                                                size: 26,
                                                color: scheme.primary,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                '相册选取',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: scheme.primary,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                );
                              }
                              final illIndex = index - 2;
                              final illPath =
                                  task.availableIllustrationPaths[illIndex];
                              final isSelected = !isDefaultSelected &&
                                  _selectedCoverPath == illPath;
                              return _buildCoverChoiceTile(
                                label: '插画 ${illIndex + 1}',
                                isSelected: isSelected,
                                onTap: () {
                                  setState(() {
                                    _selectedCoverPath = illPath;
                                  });
                                },
                                image: Image.file(
                                  File(illPath),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      _buildPlaceholderCover(),
                                ),
                              );
                            },
                          ),
                        ),
                        if (task.availableIllustrationPaths.isEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            task.options.includeIllustrations
                                ? '本次所选卷中未包含插画，可使用书籍默认封面或选择本机图片'
                                : '制作时未开启插画下载，可使用书籍默认封面或选择本机图片',
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        // 底部固定操作栏
        Container(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            MediaQuery.of(context).padding.bottom + 12,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                offset: const Offset(0, -2),
                blurRadius: 8,
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _confirmCancel,
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('取消制作'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () => _confirmAndPackage(task),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(task.options.exportAsTxt ? '确认并生成 TXT' : '确认并生成 EPUB'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoverPreview(EpubDownloadTask task) {
    final path = _selectedCoverPath;
    Widget imageWidget;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      imageWidget = Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
      );
    } else if (task.customCoverPath != null &&
        File(task.customCoverPath!).existsSync()) {
      imageWidget = Image.file(
        File(task.customCoverPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
      );
    } else if (task.coverUrl.isNotEmpty) {
      imageWidget = CoverImage(
        url: task.coverUrl,
        width: 120,
        height: 168,
        fit: BoxFit.cover,
        radius: 0,
        showPeekButton: false,
      );
    } else {
      imageWidget = _buildPlaceholderCover();
    }

    return Container(
      width: 120,
      height: 168,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: Theme.of(context)
              .colorScheme
              .outlineVariant
              .withValues(alpha: 0.4),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          imageWidget,
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              color: Colors.black.withValues(alpha: 0.65),
              child: const Text(
                '当前封面',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultCoverThumbnail(EpubDownloadTask task) {
    if (task.customCoverPath != null &&
        File(task.customCoverPath!).existsSync()) {
      return Image.file(
        File(task.customCoverPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
      );
    }
    if (task.coverUrl.isNotEmpty) {
      return CoverImage(
        url: task.coverUrl,
        width: 64,
        height: 90,
        fit: BoxFit.cover,
        radius: 0,
        showPeekButton: false,
      );
    }
    return _buildPlaceholderCover();
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.book_rounded,
        size: 32,
        color: Theme.of(context)
            .colorScheme
            .onSurfaceVariant
            .withValues(alpha: 0.5),
      ),
    );
  }

  Widget _buildCoverChoiceTile({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required Widget image,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 64,
                height: 90,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected
                        ? scheme.primary
                        : scheme.outlineVariant.withValues(alpha: 0.3),
                    width: isSelected ? 2.5 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: image,
              ),
              if (isSelected)
                Positioned(
                  top: 3,
                  right: 3,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child:
                        Icon(Icons.check, size: 10, color: scheme.onPrimary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 64,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 完成视图 ====================

  Widget _buildCompletedView(BuildContext context, EpubDownloadTask task) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isTxt = task.options.exportAsTxt;
    final defaultFileName = isTxt ? 'book.txt' : 'book.epub';
    final fileName = task.outputPath != null
        ? task.outputPath!.split(RegExp(r'[\\/]')).last
        : defaultFileName;

    final completedTitle = isTxt
        ? (task.options.exportIncomplete ? 'TXT 制作完成（不完整版）' : 'TXT 制作完成')
        : (task.options.exportIncomplete ? 'EPUB 制作完成（不完整版）' : 'EPUB 制作完成');

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.check_circle_rounded, size: 48, color: scheme.primary),
          ),
          const SizedBox(height: 20),
          Text(
            completedTitle,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            fileName,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '文件大小：${_formatSize(task.outputSizeBytes)}',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
          ),
          const SizedBox(height: 36),

          // 另存为文件按钮
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: () {
                if (task.outputPath != null) {
                  _saveAsDocument(
                    task.outputPath!,
                    fileName,
                    mimeType: isTxt ? 'text/plain' : 'application/epub+zip',
                  );
                }
              },
              icon: const Icon(Icons.save_alt_rounded),
              label: const Text('另存为文件'),
            ),
          ),
          const SizedBox(height: 12),

          // 独立分享按钮
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.tonalIcon(
              key: _shareButtonKey,
              onPressed: () {
                if (task.outputPath != null) {
                  _shareBookFile(
                    task.outputPath!,
                    fileName,
                    mimeType: isTxt ? 'text/plain' : 'application/epub+zip',
                  );
                }
              },
              icon: const Icon(Icons.share_rounded),
              label: const Text('分享'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: () async {
                await EpubDownloadService.clearAllTempFiles();
                _service.currentTask.value = null;
                if (context.mounted) {
                  showFloatingPrompt(context, '临时文件已清理');
                  Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('清理临时文件并退出'),
            ),
          ),
        ],
      ),
    );
  }
}
