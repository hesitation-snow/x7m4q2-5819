import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../api/lk_api.dart';
import '../../api/lk_client.dart';
import '../../api/models.dart';
import '../illustration_cache.dart';
import '../illustration_identity.dart';
import 'epub_builder.dart';
import 'epub_models.dart';

/// 严格限制网络并发数的信号量调度器
@visibleForTesting
class ConcurrencyLimiter {
  final int maxConcurrent;
  int _running = 0;
  final Queue<Completer<void>> _queue = Queue();

  ConcurrencyLimiter(this.maxConcurrent) : assert(maxConcurrent > 0);

  int get currentRunning => _running;

  Future<T> run<T>(Future<T> Function() block) async {
    while (_running >= maxConcurrent) {
      final completer = Completer<void>();
      _queue.add(completer);
      await completer.future;
    }
    _running++;
    try {
      return await block();
    } finally {
      _running--;
      if (_queue.isNotEmpty) {
        _queue.removeFirst().complete();
      }
    }
  }
}

/// 独立的 EPUB 后台下载与制作调度服务
///
/// 特性：
/// 1. 脱离页面生命周期，切页与退出后仍在后台运行；
/// 2. 同时只允许制作一本书；
/// 3. 网络请求并发严格限制 <= 2；
/// 4. 章节正文与图片流式写入独立任务目录，绝不污染阅读器 50 章上限缓存；
/// 5. 绑定登录账号，换号与注销时自动停止并保护鉴权数据。
class EpubDownloadService {
  static final EpubDownloadService shared = EpubDownloadService._();

  EpubDownloadService._() {
    LKClient.sessionRev.addListener(_onSessionRevChanged);
  }

  /// 状态通知器，驱动所有观察者 UI 响应
  final ValueNotifier<EpubDownloadTask?> currentTask = ValueNotifier(null);

  /// 网络请求并发限制器：最多 2 个网络并发
  final ConcurrencyLimiter _networkSemaphore = ConcurrencyLimiter(2);

  int _boundUid = 0;
  bool _isPausedFlag = false;
  bool _isCanceledFlag = false;

  void _onSessionRevChanged() {
    final task = currentTask.value;
    if (task == null || task.isTerminal) return;

    final currentUid = LKClient.shared.session.uid;
    if (_boundUid > 0 && currentUid != _boundUid) {
      _handleAccountChanged('登录账号已切换，制作任务已停止');
    } else if (_boundUid > 0 && !LKClient.shared.session.isLoggedIn) {
      _handleAccountChanged('已退出登录，制作任务已停止');
    }
  }

  void _handleAccountChanged(String reason) {
    final task = currentTask.value;
    if (task == null || task.isTerminal) return;
    _isPausedFlag = false;
    _isCanceledFlag = true;
    currentTask.value = task.copyWith(
      phase: EpubTaskPhase.failed,
      statusMessage: reason,
    );
  }

  /// 检查当前是否有正在进行的任务
  bool get hasActiveTask {
    final t = currentTask.value;
    return t != null && t.isRunning;
  }

  /// 启动书籍制作任务
  Future<void> startTask({
    required LKBook book,
    required List<LKVolume> selectedVolumes,
    required EpubExportOptions options,
  }) async {
    if (hasActiveTask) {
      throw StateError('已有正在制作的任务，请等待完成或取消后再试');
    }

    _isPausedFlag = false;
    _isCanceledFlag = false;
    _boundUid = LKClient.shared.session.uid;

    final task = EpubDownloadTask(
      bookId: book.bookId,
      bookTitle: book.title,
      authorName: book.authorName,
      coverUrl: book.coverUrl,
      summary: book.summary,
      ownerUid: _boundUid,
      options: options,
      selectedVolumes: selectedVolumes,
      phase: EpubTaskPhase.fetchingCatalog,
      statusMessage: '正在刷新目录…',
    );

    currentTask.value = task;

    // 异步在后台启动流程，不阻塞调用方
    unawaited(_runPipeline(task));
  }

  /// 暂停当前任务
  Future<void> pauseTask() async {
    final task = currentTask.value;
    if (task == null || !task.isRunning) return;

    _isPausedFlag = true;
    currentTask.value = task.copyWith(
      phase: EpubTaskPhase.paused,
      statusMessage: '制作已暂停',
    );
    await _saveTaskCheckpoint(currentTask.value!);
  }

  /// 继续当前任务
  Future<void> resumeTask() async {
    final task = currentTask.value;
    if (task == null || task.phase != EpubTaskPhase.paused) return;

    _isPausedFlag = false;
    _isCanceledFlag = false;
    _boundUid = LKClient.shared.session.uid;

    if (task.completedCount < task.totalChapters) {
      currentTask.value = task.copyWith(
        phase: EpubTaskPhase.downloadingContent,
        statusMessage: '继续下载正文…',
      );
      unawaited(_runDownloadPhase(currentTask.value!));
    } else {
      currentTask.value = task.copyWith(
        phase: EpubTaskPhase.packaging,
        statusMessage: '继续制作文件…',
      );
      unawaited(_runPackagingPhase(currentTask.value!));
    }
  }

  /// 取消当前任务并删除临时文件
  Future<void> cancelTask() async {
    final task = currentTask.value;
    if (task == null) return;

    _isCanceledFlag = true;
    _isPausedFlag = false;

    currentTask.value = task.copyWith(
      phase: EpubTaskPhase.canceled,
      statusMessage: '任务已取消',
    );

    await _deleteTaskDirectory(task.bookId);
  }

  /// 重试失败章节
  Future<void> retryFailedChapters() async {
    final task = currentTask.value;
    if (task == null || task.failedChapters.isEmpty) return;

    final clearedFailed = <int, String>{};
    currentTask.value = task.copyWith(
      failedChapters: clearedFailed,
      phase: EpubTaskPhase.downloadingContent,
      statusMessage: '正在重试失败章节…',
    );

    _isPausedFlag = false;
    _isCanceledFlag = false;
    unawaited(_runDownloadPhase(currentTask.value!));
  }

  /// 显式选择导出已完成内容（部分章节缺失的不完整版）
  Future<void> exportCompletedContent() async {
    final task = currentTask.value;
    if (task == null || task.completedCount == 0) return;

    final updated = task.copyWith(
      options: task.options.copyWith(exportIncomplete: true),
      phase: EpubTaskPhase.packaging,
      statusMessage: '正在导出已完成内容…',
    );
    currentTask.value = updated;
    unawaited(_runPackagingPhase(updated));
  }

  /// 完整调度管线：阶段 1 -> 阶段 2 -> 阶段 3 -> 阶段 4
  Future<void> _runPipeline(EpubDownloadTask initialTask) async {
    try {
      // 1. 获取任务目录并准备结构
      final taskDir = await _getTaskDirectory(initialTask.bookId);
      await taskDir.create(recursive: true);
      await Directory('${taskDir.path}/chapters').create(recursive: true);
      await Directory('${taskDir.path}/images').create(recursive: true);

      // 阶段 1: 刷新并拉取全量目录
      final catalogChapters = await _fetchCompleteCatalog(initialTask);
      if (_isCanceledFlag) return;
      if (catalogChapters.isEmpty) {
        currentTask.value = currentTask.value?.copyWith(
          phase: EpubTaskPhase.failed,
          statusMessage: '所选卷下未包含有效章节',
        );
        return;
      }

      final taskWithCatalog = initialTask.copyWith(
        chapters: catalogChapters,
        phase: EpubTaskPhase.downloadingContent,
        statusMessage: '开始下载正文与插画…',
      );
      currentTask.value = taskWithCatalog;
      await _saveTaskCheckpoint(taskWithCatalog);

      // 下载封面（若存在）
      await _downloadCover(taskWithCatalog, taskDir);

      // 阶段 2: 下载正文与插画
      await _runDownloadPhase(taskWithCatalog);
    } catch (e) {
      if (_isCanceledFlag) return;
      currentTask.value = currentTask.value?.copyWith(
        phase: EpubTaskPhase.failed,
        statusMessage: '制作失败: $e',
      );
    }
  }

  /// 阶段 1: 全量分页获取目录、去重并按官方顺序排序
  Future<List<EpubChapterItem>> _fetchCompleteCatalog(EpubDownloadTask task) async {
    final allCollectedChapters = <EpubChapterItem>[];
    final seenChapterIds = <int>{};

    for (final volume in task.selectedVolumes) {
      if (_isCanceledFlag) return const [];
      var page = 1;
      var hasMore = true;

      while (hasMore) {
        if (_isCanceledFlag) return const [];
        final chapterPage = await _networkSemaphore.run(() => LKApi.chapterPage(
              task.bookId,
              volume.volumeId,
              page,
              pageSize: 50,
              forceRefresh: true,
            ));

        for (final ch in chapterPage.items) {
          if (ch.chapterId > 0 && seenChapterIds.add(ch.chapterId)) {
            allCollectedChapters.add(EpubChapterItem(
              chapterId: ch.chapterId,
              chapterNo: ch.chapterNo,
              title: ch.title,
              volumeId: volume.volumeId,
              volumeTitle: volume.title,
              locked: ch.locked,
              unlocked: ch.unlocked,
              braveRequired: ch.braveOnly,
            ));
          }
        }

        hasMore = chapterPage.hasMore && chapterPage.items.isNotEmpty;
        page++;
      }
    }

    return allCollectedChapters;
  }

  /// 下载封面
  Future<void> _downloadCover(EpubDownloadTask task, Directory taskDir) async {
    if (task.coverUrl.trim().isEmpty) return;
    try {
      final coverFile = File('${taskDir.path}/cover.jpg');
      if (await coverFile.exists()) return;

      final res = await _networkSemaphore.run(() => http.get(Uri.parse(task.coverUrl)));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        await coverFile.writeAsBytes(res.bodyBytes);
      }
    } catch (_) {
      // 封面下载失败不阻断全书制作
    }
  }

  /// 阶段 2: 逐章流式下载正文与插画
  Future<void> _runDownloadPhase(EpubDownloadTask task) async {
    final taskDir = await _getTaskDirectory(task.bookId);
    final completed = Set<int>.from(task.completedChapterIds);
    final failed = Map<int, String>.from(task.failedChapters);

    for (final ch in task.chapters) {
      if (_isCanceledFlag) return;
      if (_isPausedFlag) {
        await _saveTaskCheckpoint(currentTask.value!);
        return;
      }

      // 如果本章已完成，跳过
      if (completed.contains(ch.chapterId)) continue;

      // 如果已在失败列表中且未处于重试流程，跳过
      if (failed.containsKey(ch.chapterId)) continue;

      currentTask.value = currentTask.value?.copyWith(
        currentChapterTitle: ch.title,
        statusMessage: '正在下载: ${ch.title}',
      );

      try {
        final chFile = File('${taskDir.path}/chapters/${ch.chapterId}.json');
        LKChapterDetail detail;
        if (await chFile.exists()) {
          try {
            final json =
                jsonDecode(await chFile.readAsString()) as Map<String, dynamic>;
            detail = LKChapterDetail(
              chapterId: (json['chapter_id'] as num?)?.toInt() ?? ch.chapterId,
              chapterNo: (json['chapter_no'] as num?)?.toInt() ?? ch.chapterNo,
              title: (json['title'] ?? ch.title).toString(),
              bodyText: (json['body_text'] ?? '').toString(),
              bodyHtml: json['body_html'] as String?,
            );
          } catch (_) {
            detail = await _fetchChapterWithRetry(task.bookId, ch.chapterId);
          }
        } else {
          detail = await _fetchChapterWithRetry(task.bookId, ch.chapterId);
        }

        // 若需要下载插画，但已存章节没有 bodyHtml，则重新向服务端请求带 HTML 的最新数据
        if (task.options.includeIllustrations &&
            (detail.bodyHtml == null || detail.bodyHtml!.isEmpty)) {
          try {
            final refreshed =
                await _fetchChapterWithRetry(task.bookId, ch.chapterId);
            if (refreshed.bodyHtml != null &&
                refreshed.bodyHtml!.isNotEmpty) {
              detail = refreshed;
            }
          } catch (_) {}
        }

        if (_isCanceledFlag) return;

        // 写入独立章节文件
        await chFile.writeAsString(jsonEncode({
          'chapter_id': detail.chapterId,
          'chapter_no': detail.chapterNo,
          'title': detail.title,
          'body_text': detail.bodyText,
          'body_html': detail.bodyHtml,
        }));

        // 处理插画（若开启）
        if (task.options.includeIllustrations) {
          await _processChapterIllustrations(detail, taskDir);
        }

        completed.add(ch.chapterId);
        failed.remove(ch.chapterId);

        currentTask.value = currentTask.value?.copyWith(
          completedChapterIds: completed,
          failedChapters: failed,
        );
      } catch (e) {
        if (_isCanceledFlag) return;
        final errorMsg = _friendlyErrorMessage(e);
        failed[ch.chapterId] = errorMsg;

        currentTask.value = currentTask.value?.copyWith(
          failedChapters: failed,
        );

        // 如果是 429 频率限制，主动暂停
        if (_isRateLimitError(e)) {
          _isPausedFlag = true;
          currentTask.value = currentTask.value?.copyWith(
            phase: EpubTaskPhase.paused,
            statusMessage: '服务端访问过于频繁（429），已自动暂停，请稍后继续',
          );
          await _saveTaskCheckpoint(currentTask.value!);
          return;
        }
      }
    }

    await _saveTaskCheckpoint(currentTask.value!);

    // 检查是否所有章节都处理完毕
    if (completed.length == task.totalChapters) {
      // 全量完成，进入制作阶段
      final updated = currentTask.value!.copyWith(
        phase: EpubTaskPhase.packaging,
        statusMessage: '正在生成 EPUB 文件…',
      );
      currentTask.value = updated;
      await _runPackagingPhase(updated);
    } else {
      // 存在部分失败章节
      final updated = currentTask.value!.copyWith(
        phase: EpubTaskPhase.paused,
        statusMessage: '正文下载暂未全部完成（${failed.length} 章失败）',
      );
      currentTask.value = updated;
    }
  }

  /// 带退避重试的章节获取
  Future<LKChapterDetail> _fetchChapterWithRetry(int bookId, int chapterId) async {
    int attempts = 0;
    const maxAttempts = 3;

    while (true) {
      attempts++;
      try {
        return await _networkSemaphore.run(() => LKApi.chapterDetail(bookId, chapterId));
      } catch (e) {
        final accessRestricted = e is LKException && e.accessRestricted;
        if (accessRestricted || attempts >= maxAttempts || _isRateLimitError(e)) {
          rethrow;
        }
        // 指数退避：1s, 2s, 4s
        await Future.delayed(Duration(seconds: 1 << (attempts - 1)));
      }
    }
  }

  /// 处理本章插画（复用缓存，或按需下载并落盘）
  Future<void> _processChapterIllustrations(
    LKChapterDetail detail,
    Directory taskDir,
  ) async {
    final html = detail.bodyHtml ?? '';
    final text = detail.bodyText;
    final urls = <String>{};
    if (html.isNotEmpty) {
      urls.addAll(YomiruIllustrationCache.extractImageUrls(html));
    }
    if (text.contains('<img')) {
      urls.addAll(YomiruIllustrationCache.extractImageUrls(text));
    }
    if (urls.isEmpty) return;

    final imagesDir = Directory('${taskDir.path}/images');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final mapFile = File('${taskDir.path}/image_map.json');
    final map = <String, String>{};
    if (await mapFile.exists()) {
      try {
        map.addAll(
            Map<String, String>.from(jsonDecode(await mapFile.readAsString())));
      } catch (_) {}
    }

    for (final rawUrl in urls) {
      if (_isCanceledFlag || _isPausedFlag) return;
      final cleanUrl = rawUrl.replaceAll('&amp;', '&').trim();
      if (cleanUrl.isEmpty) continue;
      final fileName = getIllustrationFileName(cleanUrl);
      final destFile = File('${imagesDir.path}/$fileName');

      if (!await destFile.exists()) {
        try {
          // 1. 优先尝试从本地已有插画缓存管理器复制文件
          final cached =
              await YomiruIllustrationCache.manager.cachedFile(cleanUrl);
          if (cached != null && await File(cached.file.path).exists()) {
            await File(cached.file.path).copy(destFile.path);
          }
        } catch (_) {}

        if (!await destFile.exists()) {
          try {
            // 2. 尝试从缓存管理器预取并落盘
            final downloaded = await _networkSemaphore.run(
                () => YomiruIllustrationCache.prefetch(cleanUrl));
            if (downloaded != null && await File(downloaded.path).exists()) {
              await File(downloaded.path).copy(destFile.path);
            }
          } catch (_) {}
        }

        if (!await destFile.exists()) {
          try {
            // 3. 降级保障：直接通过 HTTP 请求下载原图落盘
            final uri = Uri.parse(cleanUrl);
            final res = await _networkSemaphore.run(() => http.get(uri));
            if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
              await destFile.writeAsBytes(res.bodyBytes);
            }
          } catch (_) {
            // 单张插画失败不中断正文任务
          }
        }
      }

      if (await destFile.exists()) {
        map[rawUrl] = fileName;
        map[cleanUrl] = fileName;
        map[illustrationCacheKey(cleanUrl)] = fileName;
        map[fileName] = fileName;
      }
    }

    await mapFile.writeAsString(jsonEncode(map));
  }

  /// 阶段 3: Isolate 中执行 EPUB 3 标准容器打包
  Future<void> _runPackagingPhase(EpubDownloadTask task) async {
    try {
      final taskDir = await _getTaskDirectory(task.bookId);
      final exportsDir = await _getExportsDirectory();
      await exportsDir.create(recursive: true);

      // 文件名清洗，避免特殊符号
      final safeTitle = task.bookTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final incompleteSuffix = task.options.exportIncomplete ? '_不完整版' : '';
      final fileName = '$safeTitle$incompleteSuffix.epub';
      final outputPath = '${exportsDir.path}/$fileName';

      currentTask.value = currentTask.value?.copyWith(
        phase: EpubTaskPhase.packaging,
        statusMessage: '正在打包 EPUB 3 容器…',
      );

      final buildContext = EpubBuildContext(
        taskDir: taskDir.path,
        outputPath: outputPath,
        bookId: task.bookId,
        bookTitle: task.bookTitle,
        authorName: task.authorName,
        summary: task.summary,
        includeIllustrations: task.options.includeIllustrations,
        exportIncomplete: task.options.exportIncomplete,
        chapters: task.chapters,
        completedChapterIds: task.completedChapterIds.toList(),
      );

      final sizeBytes = await EpubBuilder.packageInIsolate(buildContext);

      // 阶段 4: 完成
      currentTask.value = currentTask.value?.copyWith(
        phase: EpubTaskPhase.completed,
        statusMessage: '制作完成',
        outputPath: outputPath,
        outputSizeBytes: sizeBytes,
      );

      await _saveTaskCheckpoint(currentTask.value!);
    } catch (e) {
      if (_isCanceledFlag) return;
      currentTask.value = currentTask.value?.copyWith(
        phase: EpubTaskPhase.failed,
        statusMessage: '打包失败: $e',
      );
    }
  }

  bool _isRateLimitError(dynamic e) {
    if (e is LKException && e.code == 429) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('429') || msg.contains('频繁') || msg.contains('限流');
  }

  String _friendlyErrorMessage(dynamic e) {
    if (e is LKException) {
      if (e.accessRestricted || e.code == 403) return '无权限或需要勇者等级';
      return e.message;
    }
    return e.toString();
  }

  Future<Directory> _getTaskDirectory(int bookId) async {
    final temp = await getTemporaryDirectory();
    return Directory('${temp.path}/epub_maker/tasks/$bookId');
  }

  Future<Directory> _getExportsDirectory() async {
    final temp = await getTemporaryDirectory();
    return Directory('${temp.path}/epub_maker/exports');
  }

  Future<void> _deleteTaskDirectory(int bookId) async {
    try {
      final taskDir = await _getTaskDirectory(bookId);
      if (await taskDir.exists()) {
        await taskDir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _saveTaskCheckpoint(EpubDownloadTask task) async {
    try {
      final taskDir = await _getTaskDirectory(task.bookId);
      if (!await taskDir.exists()) return;
      final file = File('${taskDir.path}/meta.json');
      await file.writeAsString(jsonEncode(task.toJson()));
    } catch (_) {}
  }

  /// 清除所有 EPUB 制作产生的临时任务和导出文件
  static Future<void> clearAllTempFiles() async {
    try {
      final temp = await getTemporaryDirectory();
      final makerDir = Directory('${temp.path}/epub_maker');
      if (await makerDir.exists()) {
        await makerDir.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// 计算 EPUB 制作所占用的临时缓存体积
  static Future<int> calculateTempSizeBytes() async {
    try {
      final temp = await getTemporaryDirectory();
      final makerDir = Directory('${temp.path}/epub_maker');
      if (!await makerDir.exists()) return 0;
      var total = 0;
      await for (final entity in makerDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
