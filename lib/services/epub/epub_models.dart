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

  /// 阶段 3: Isolate 中执行 EPUB 3 标准容器打包
  packaging,

  /// 阶段 4: 制作全部完成
  completed,

  /// 用户或限流主动暂停
  paused,

  /// 遇到不可恢复错误或全部失败
  failed,

  /// 用户主动取消
  canceled,
}

/// 导出选项
class EpubExportOptions {
  final bool includeIllustrations;
  final bool exportIncomplete;

  const EpubExportOptions({
    this.includeIllustrations = true,
    this.exportIncomplete = false,
  });

  EpubExportOptions copyWith({
    bool? includeIllustrations,
    bool? exportIncomplete,
  }) =>
      EpubExportOptions(
        includeIllustrations:
            includeIllustrations ?? this.includeIllustrations,
        exportIncomplete: exportIncomplete ?? this.exportIncomplete,
      );

  Map<String, dynamic> toJson() => {
        'include_illustrations': includeIllustrations,
        'export_incomplete': exportIncomplete,
      };

  factory EpubExportOptions.fromJson(Map<String, dynamic> json) =>
      EpubExportOptions(
        includeIllustrations: json['include_illustrations'] == true,
        exportIncomplete: json['export_incomplete'] == true,
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

  const EpubDownloadTask({
    required this.bookId,
    required this.bookTitle,
    required this.authorName,
    this.coverUrl = '',
    this.summary = '',
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
  });

  int get totalChapters => chapters.length;
  int get completedCount => completedChapterIds.length;
  int get failedCount => failedChapters.length;

  bool get isRunning =>
      phase == EpubTaskPhase.fetchingCatalog ||
      phase == EpubTaskPhase.downloadingContent ||
      phase == EpubTaskPhase.packaging;

  bool get isPaused => phase == EpubTaskPhase.paused;
  bool get isCompleted => phase == EpubTaskPhase.completed;
  bool get isTerminal =>
      phase == EpubTaskPhase.completed ||
      phase == EpubTaskPhase.failed ||
      phase == EpubTaskPhase.canceled;

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
  }) =>
      EpubDownloadTask(
        bookId: bookId ?? this.bookId,
        bookTitle: bookTitle ?? this.bookTitle,
        authorName: authorName ?? this.authorName,
        coverUrl: coverUrl ?? this.coverUrl,
        summary: summary ?? this.summary,
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
      );

  Map<String, dynamic> toJson() => {
        'book_id': bookId,
        'book_title': bookTitle,
        'author_name': authorName,
        'cover_url': coverUrl,
        'summary': summary,
        'owner_uid': ownerUid,
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
      };
}
