import '../../api/models.dart';
import '../illustration_identity.dart';

/// 为插画 URL 生成合法、唯一且跨平台安全的文件名（无冒号、斜杠或查询参数）
String getIllustrationFileName(String url) {
  final clean = url.replaceAll('&amp;', '&').trim();
  final key = illustrationCacheKey(clean);
  final uri = Uri.tryParse(key);
  var ext = 'jpg';
  if (uri != null && uri.path.contains('.')) {
    final dotExt = uri.path.split('.').last.toLowerCase();
    if (const {'jpg', 'jpeg', 'png', 'webp', 'gif', 'avif'}.contains(dotExt)) {
      ext = dotExt == 'jpeg' ? 'jpg' : dotExt;
    }
  }
  if (uri != null && uri.pathSegments.isNotEmpty) {
    final last = uri.pathSegments.last;
    final dotIdx = last.lastIndexOf('.');
    final nameWithoutExt = dotIdx > 0 ? last.substring(0, dotIdx) : last;
    if (RegExp(r'^[a-zA-Z0-9_-]{6,64}$').hasMatch(nameWithoutExt)) {
      return '$nameWithoutExt.$ext';
    }
  }
  final hash = (key.hashCode & 0x7FFFFFFF).toRadixString(16).padLeft(8, '0');
  final len = key.length.toRadixString(16);
  return 'img_${hash}_$len.$ext';
}

/// 制作任务所处的当前阶段
enum EpubTaskPhase {
  /// 未开始或空闲
  idle,

  /// 阶段 1: 刷新并拉取全量目录
  fetchingCatalog,

  /// 阶段 2: 逐章下载正文与相关插画
  downloadingContent,

  /// 阶段 3: 用户自选封面与文件标题
  editingMetadata,

  /// 阶段 4: Isolate 中执行 EPUB 3 标准容器打包
  packaging,

  /// 阶段 5: 制作全部完成
  completed,

  /// 用户或限流主动暂停
  paused,

  /// 遇到不可恢复错误或全部失败
  failed,

  /// 用户主动取消
  canceled,
}

/// 计算预设的电子书与导出文件名标题："书名  [卷名]"
String computeDefaultEpubTitle(String bookTitle, List<LKVolume> volumes) {
  final cleanBookTitle = bookTitle.trim();
  if (volumes.length == 1) {
    final volTitle = volumes.first.title.trim();
    return '$cleanBookTitle  [${volTitle.isNotEmpty ? volTitle : "正文"}]';
  } else if (volumes.length > 1) {
    final first = volumes.first.title.trim();
    final last = volumes.last.title.trim();
    if (first.isNotEmpty && last.isNotEmpty && first != last) {
      return '$cleanBookTitle  [$first - $last]';
    }
    return '$cleanBookTitle  [全本]';
  }
  return cleanBookTitle;
}

/// 导出选项
class EpubExportOptions {
  final bool includeIllustrations;
  final bool exportIncomplete;
  final bool exportAsTxt;

  const EpubExportOptions({
    this.includeIllustrations = true,
    this.exportIncomplete = false,
    this.exportAsTxt = false,
  });

  EpubExportOptions copyWith({
    bool? includeIllustrations,
    bool? exportIncomplete,
    bool? exportAsTxt,
  }) =>
      EpubExportOptions(
        includeIllustrations:
            includeIllustrations ?? this.includeIllustrations,
        exportIncomplete: exportIncomplete ?? this.exportIncomplete,
        exportAsTxt: exportAsTxt ?? this.exportAsTxt,
      );

  Map<String, dynamic> toJson() => {
        'include_illustrations': includeIllustrations,
        'export_incomplete': exportIncomplete,
        'export_as_txt': exportAsTxt,
      };

  factory EpubExportOptions.fromJson(Map<String, dynamic> json) =>
      EpubExportOptions(
        includeIllustrations: json['include_illustrations'] == true,
        exportIncomplete: json['export_incomplete'] == true,
        exportAsTxt: json['export_as_txt'] == true,
      );
}

/// 用于制作任务的规范化章节项
class EpubChapterItem {
  final int chapterId;
  final int chapterNo;
  final String title;
  final int volumeId;
  final String volumeTitle;
  final bool locked;
  final bool unlocked;
  final bool braveRequired;

  const EpubChapterItem({
    required this.chapterId,
    required this.chapterNo,
    required this.title,
    required this.volumeId,
    required this.volumeTitle,
    this.locked = false,
    this.unlocked = false,
    this.braveRequired = false,
  });

  Map<String, dynamic> toJson() => {
        'chapter_id': chapterId,
        'chapter_no': chapterNo,
        'title': title,
        'volume_id': volumeId,
        'volume_title': volumeTitle,
        'locked': locked,
        'unlocked': unlocked,
        'brave_required': braveRequired,
      };

  factory EpubChapterItem.fromJson(Map<String, dynamic> json) =>
      EpubChapterItem(
        chapterId: json['chapter_id'] as int? ?? 0,
        chapterNo: json['chapter_no'] as int? ?? 0,
        title: (json['title'] ?? '').toString(),
        volumeId: json['volume_id'] as int? ?? 0,
        volumeTitle: (json['volume_title'] ?? '').toString(),
        locked: json['locked'] == true,
        unlocked: json['unlocked'] == true,
        braveRequired: json['brave_required'] == true,
      );
}

/// 制作任务当前快照
class EpubDownloadTask {
  final int bookId;
  final String bookTitle;
  final String authorName;
  final String coverUrl;
  final String summary;
  final int publisherUid;
  final int ownerUid;
  final EpubExportOptions options;
  final List<LKVolume> selectedVolumes;
  final List<EpubChapterItem> chapters;
  final Set<int> completedChapterIds;
  final Map<int, String> failedChapters;
  final EpubTaskPhase phase;
  final String statusMessage;
  final String currentChapterTitle;
  final String? outputPath;
  final int outputSizeBytes;
  final double packagingProgress; // 0.0 ~ 1.0
  final String? customTitle;
  final String? customCoverPath;
  final List<String> availableIllustrationPaths;
  final int illustrationDownloadedCount;
  final int currentIllustrationIndex;
  final int currentIllustrationTotal;
  final String speedText;

  /// 导出账号 UID（与 ownerUid 语义相同）
  int get exporterUid => ownerUid;

  const EpubDownloadTask({
    required this.bookId,
    required this.bookTitle,
    required this.authorName,
    this.coverUrl = '',
    this.summary = '',
    this.publisherUid = 0,
    required this.ownerUid,
    this.options = const EpubExportOptions(),
    this.selectedVolumes = const [],
    this.chapters = const [],
    this.completedChapterIds = const {},
    this.failedChapters = const {},
    this.phase = EpubTaskPhase.idle,
    this.statusMessage = '',
    this.currentChapterTitle = '',
    this.outputPath,
    this.outputSizeBytes = 0,
    this.packagingProgress = 0.0,
    this.customTitle,
    this.customCoverPath,
    this.availableIllustrationPaths = const [],
    this.illustrationDownloadedCount = 0,
    this.currentIllustrationIndex = 0,
    this.currentIllustrationTotal = 0,
    this.speedText = '',
  });

  int get totalChapters => chapters.length;
  int get completedCount => completedChapterIds.length;
  int get failedCount => failedChapters.length;

  bool get isRunning =>
      phase == EpubTaskPhase.fetchingCatalog ||
      phase == EpubTaskPhase.downloadingContent ||
      phase == EpubTaskPhase.editingMetadata ||
      phase == EpubTaskPhase.packaging;

  bool get isPaused => phase == EpubTaskPhase.paused;
  bool get isCompleted => phase == EpubTaskPhase.completed;
  bool get isTerminal =>
      phase == EpubTaskPhase.completed ||
      phase == EpubTaskPhase.failed ||
      phase == EpubTaskPhase.canceled;

  String get effectiveTitle {
    final custom = customTitle?.trim();
    if (custom != null && custom.isNotEmpty) {
      return custom;
    }
    return bookTitle;
  }

  double get downloadProgress {
    if (chapters.isEmpty) return 0.0;
    return (completedCount / chapters.length).clamp(0.0, 1.0);
  }

  EpubDownloadTask copyWith({
    int? bookId,
    String? bookTitle,
    String? authorName,
    String? coverUrl,
    String? summary,
    int? publisherUid,
    int? ownerUid,
    EpubExportOptions? options,
    List<LKVolume>? selectedVolumes,
    List<EpubChapterItem>? chapters,
    Set<int>? completedChapterIds,
    Map<int, String>? failedChapters,
    EpubTaskPhase? phase,
    String? statusMessage,
    String? currentChapterTitle,
    String? outputPath,
    int? outputSizeBytes,
    double? packagingProgress,
    String? customTitle,
    String? customCoverPath,
    List<String>? availableIllustrationPaths,
    int? illustrationDownloadedCount,
    int? currentIllustrationIndex,
    int? currentIllustrationTotal,
    String? speedText,
  }) =>
      EpubDownloadTask(
        bookId: bookId ?? this.bookId,
        bookTitle: bookTitle ?? this.bookTitle,
        authorName: authorName ?? this.authorName,
        coverUrl: coverUrl ?? this.coverUrl,
        summary: summary ?? this.summary,
        publisherUid: publisherUid ?? this.publisherUid,
        ownerUid: ownerUid ?? this.ownerUid,
        options: options ?? this.options,
        selectedVolumes: selectedVolumes ?? this.selectedVolumes,
        chapters: chapters ?? this.chapters,
        completedChapterIds:
            completedChapterIds ?? this.completedChapterIds,
        failedChapters: failedChapters ?? this.failedChapters,
        phase: phase ?? this.phase,
        statusMessage: statusMessage ?? this.statusMessage,
        currentChapterTitle:
            currentChapterTitle ?? this.currentChapterTitle,
        outputPath: outputPath ?? this.outputPath,
        outputSizeBytes: outputSizeBytes ?? this.outputSizeBytes,
        packagingProgress: packagingProgress ?? this.packagingProgress,
        customTitle: customTitle ?? this.customTitle,
        customCoverPath: customCoverPath ?? this.customCoverPath,
        availableIllustrationPaths:
            availableIllustrationPaths ?? this.availableIllustrationPaths,
        illustrationDownloadedCount:
            illustrationDownloadedCount ?? this.illustrationDownloadedCount,
        currentIllustrationIndex:
            currentIllustrationIndex ?? this.currentIllustrationIndex,
        currentIllustrationTotal:
            currentIllustrationTotal ?? this.currentIllustrationTotal,
        speedText: speedText ?? this.speedText,
      );

  Map<String, dynamic> toJson() => {
        'book_id': bookId,
        'book_title': bookTitle,
        'author_name': authorName,
        'cover_url': coverUrl,
        'summary': summary,
        'publisher_uid': publisherUid,
        'owner_uid': ownerUid,
        'exporter_uid': ownerUid,
        'options': options.toJson(),
        'selected_volume_ids': selectedVolumes.map((v) => v.volumeId).toList(),
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'completed_chapter_ids': completedChapterIds.toList(),
        'failed_chapters':
            failedChapters.map((k, v) => MapEntry(k.toString(), v)),
        'phase': phase.name,
        'status_message': statusMessage,
        'output_path': outputPath,
        'output_size_bytes': outputSizeBytes,
        'custom_title': customTitle,
        'custom_cover_path': customCoverPath,
        'available_illustration_paths': availableIllustrationPaths,
        'illustration_downloaded_count': illustrationDownloadedCount,
        'current_illustration_index': currentIllustrationIndex,
        'current_illustration_total': currentIllustrationTotal,
        'speed_text': speedText,
      };

  factory EpubDownloadTask.fromJson(Map<String, dynamic> json) {
    return EpubDownloadTask(
      bookId: json['book_id'] as int? ?? 0,
      bookTitle: (json['book_title'] ?? '').toString(),
      authorName: (json['author_name'] ?? '').toString(),
      coverUrl: (json['cover_url'] ?? '').toString(),
      summary: (json['summary'] ?? '').toString(),
      publisherUid: (json['publisher_uid'] as num?)?.toInt() ?? 0,
      ownerUid: (json['owner_uid'] as num?)?.toInt() ??
          (json['exporter_uid'] as num?)?.toInt() ??
          0,
      options: json['options'] != null
          ? EpubExportOptions.fromJson(json['options'] as Map<String, dynamic>)
          : const EpubExportOptions(),
      selectedVolumes: const [],
      chapters: (json['chapters'] as List?)
              ?.map((e) => EpubChapterItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      completedChapterIds: (json['completed_chapter_ids'] as List?)
              ?.map((e) => (e as num).toInt())
              .toSet() ??
          const {},
      failedChapters: (json['failed_chapters'] as Map?)?.map((k, v) =>
              MapEntry(int.tryParse(k.toString()) ?? 0, v.toString())) ??
          const {},
      phase: EpubTaskPhase.values.firstWhere(
        (p) => p.name == json['phase'],
        orElse: () => EpubTaskPhase.idle,
      ),
      statusMessage: (json['status_message'] ?? '').toString(),
      currentChapterTitle: (json['current_chapter_title'] ?? '').toString(),
      outputPath: json['output_path'] as String?,
      outputSizeBytes: json['output_size_bytes'] as int? ?? 0,
      customTitle: json['custom_title'] as String?,
      customCoverPath: json['custom_cover_path'] as String?,
      availableIllustrationPaths:
          (json['available_illustration_paths'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              const [],
      illustrationDownloadedCount:
          json['illustration_downloaded_count'] as int? ?? 0,
      currentIllustrationIndex:
          json['current_illustration_index'] as int? ?? 0,
      currentIllustrationTotal:
          json['current_illustration_total'] as int? ?? 0,
      speedText: (json['speed_text'] ?? '').toString(),
    );
  }
}
