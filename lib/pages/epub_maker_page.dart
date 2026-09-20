import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _warnedDataSaver = false;
  final GlobalKey _shareButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _includeIllustrations = !LKStore.dataSaverMode.value;
    for (final v in widget.initialVolumes) {
      if (v.volumeId > 0) {
        _selectedVolumeIds.add(v.volumeId);
      }
    }
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
          includeIllustrations: _includeIllustrations,
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
        content: const Text('确定要取消本次 EPUB 制作吗？已下载的临时章节与图片将被清理。'),
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

  Future<void> _saveAsDocument(String filePath, String fileName) async {
    if (Platform.isAndroid) {
      try {
        const platform = MethodChannel('moe.yutro.yomiru/epub_export');
        final saved = await platform.invokeMethod<bool>('saveDocument', {
          'filePath': filePath,
          'fileName': fileName,
        });
        if (saved == true && mounted) {
          showFloatingPrompt(context, '文件已另存为');
          return;
        }
      } catch (_) {
        // Fallback to share sheet
      }
    }
    await _shareEpubFile(filePath, fileName);
  }

  Future<void> _shareEpubFile(String filePath, String fileName) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        if (mounted) showLkError(context, 'EPUB 文件不存在，请重新制作');
        return;
      }
      final origin = _calculateShareOrigin();
      await Share.shareXFiles(
        [
          XFile(
            filePath,
            mimeType: 'application/epub+zip',
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
        title: const Text('制作 EPUB'),
      ),
      body: ValueListenableBuilder<EpubDownloadTask?>(
        valueListenable: _service.currentTask,
        builder: (context, task, _) {
          // 如果当前有本小说的任务或正在进行
          if (task != null && task.bookId == widget.book.bookId && !task.isTerminal) {
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
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.image_outlined, color: scheme.primary, size: 20),
                  ),
                  title: const Text('包含封面与插画'),
                  subtitle: const Text('下载书中高清彩色插画并在 EPUB 中排版'),
                  value: _includeIllustrations,
                  onChanged: _toggleIncludeIllustrations,
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
                      _includeIllustrations ? '包含封面与插画' : '仅纯文本正文',
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
      EpubTaskPhase.packaging => 2,
      EpubTaskPhase.completed => 3,
      _ => 1,
    };

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // 4 阶段进度条
        Row(
          children: [
            _buildStepIndicator(0, '获取目录', currentStep),
            _buildStepLine(0 < currentStep),
            _buildStepIndicator(1, '正文插画', currentStep),
            _buildStepLine(1 < currentStep),
            _buildStepIndicator(2, '制作文件', currentStep),
            _buildStepLine(2 < currentStep),
            _buildStepIndicator(3, '完成', currentStep),
          ],
        ),
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

  // ==================== 完成视图 ====================

  Widget _buildCompletedView(BuildContext context, EpubDownloadTask task) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fileName = task.outputPath?.split(Platform.pathSeparator).last ?? 'book.epub';

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
            task.options.exportIncomplete ? 'EPUB 制作完成（不完整版）' : 'EPUB 制作完成',
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

          // 保存与分享按钮
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              key: _shareButtonKey,
              onPressed: () {
                if (task.outputPath != null) {
                  _saveAsDocument(task.outputPath!, fileName);
                }
              },
              icon: Icon(Platform.isAndroid ? Icons.save_alt_rounded : Icons.share_rounded),
              label: Text(Platform.isAndroid ? '另存为 / 导出' : '分享 / 存储到文件'),
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
