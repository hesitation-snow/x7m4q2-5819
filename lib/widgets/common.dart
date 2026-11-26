import 'm3_menu_sheet.dart';
import 'm3_controls.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../services/app_motion.dart';

import '../api/models.dart';
import '../api/store.dart';
import '../api/lk_client.dart';
import '../services/book_access_probe.dart';

/// 动态中引用书籍的柔和底色，保持深浅主题下的辨识度。
Color activityBookReferenceColor(Brightness brightness) =>
    brightness == Brightness.dark
        ? const Color(0xFF2B3239)
        : const Color(0xFFF0F3F6);

/// 选择退出范围。返回 true 表示同时退出其他设备，false 表示仅退出本机，
/// null 表示取消。
Future<bool?> showLogoutScopeDialog(BuildContext context) {
  return showModalBottomSheet<bool>(
    sheetAnimationStyle: AppMotion.style(context),
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (sheetContext) => M3MenuSheet(
      title: '退出登录',
      icon: Icons.logout_rounded,
      description: '选择要退出的登录范围',
      children: [
        M3OptionTile(
          icon: Icons.smartphone_outlined,
          title: '仅退出本机',
          subtitle: '只清除此设备的登录状态',
          onTap: () => Navigator.pop(sheetContext, false),
        ),
        M3OptionTile(
          icon: Icons.devices_outlined,
          title: '退出所有设备',
          subtitle: '使其他设备上的登录状态也失效',
          danger: true,
          onTap: () => Navigator.pop(sheetContext, true),
        ),
      ],
    ),
  );
}

/// 取消关注用户的二次确认对话框。返回 true 表示确认取关，false 表示取消。
Future<bool> confirmUnfollowUser(BuildContext context,
    {String? nickname}) async {
  final name =
      (nickname != null && nickname.trim().isNotEmpty) ? nickname : '该用户';
  final result = await showDialog<bool>(
    animationStyle: AppMotion.style(context),
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('取消关注'),
      content: Text('确定不再关注 $name 吗？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 无封面书籍的默认封面(站点官方占位图)
const String kDefaultCover =
    'https://www.lightnovel.fun/sample-assets/legacy/default_article_cover_v.jpg';

/// 将布局尺寸换算成图片解码尺寸，避免小卡片把网络原图完整解码进内存。
int imageCacheDimension(BuildContext context, double logicalSize,
    {int max = 2048}) {
  if (!logicalSize.isFinite || logicalSize <= 0) return max;
  return (logicalSize * MediaQuery.devicePixelRatioOf(context))
      .ceil()
      .clamp(1, max)
      .toInt();
}

/// 页面级加载状态统一居中显示；[minHeight] 用于底部弹窗等固定高度区域。
class LkLoadingIndicator extends StatelessWidget {
  final double? minHeight;
  final double size;
  final double strokeWidth;
  final Color? color;

  const LkLoadingIndicator({
    super.key,
    this.minHeight,
    this.size = 28,
    this.strokeWidth = 3,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final indicator = Center(
      child: SizedBox(
        width: size,
        height: size,
        child: MotionProgressIndicator(
          strokeWidth: strokeWidth,
          color: color,
        ),
      ),
    );
    return minHeight == null
        ? indicator
        : SizedBox(height: minHeight, child: indicator);
  }
}

/// 轻量的渐隐分割线:中间略清晰,两端自然淡出,适合卡片内部的内容分区。
class LkFadedDivider extends StatelessWidget {
  final double height;
  final Color? color;

  const LkFadedDivider({super.key, this.height = 1, this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = color ?? scheme.onSurface;
    final peak = Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.12;
    return SizedBox(
      width: double.infinity,
      height: height,
      child: Center(
        child: SizedBox(
          width: double.infinity,
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  base.withValues(alpha: 0),
                  base.withValues(alpha: peak),
                  base.withValues(alpha: peak),
                  base.withValues(alpha: 0),
                ],
                stops: const [0, 0.18, 0.82, 1],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 带缓存、圆角、阴影与防社死高斯模糊保护的封面/头像
class CoverImage extends StatefulWidget {
  final String url;
  final double width;
  final double height;
  final double radius;
  final BoxFit fit;
  final bool isBrave;
  final bool showPeekButton;
  final bool compactPeek;
  final int bookId;
  final BookAccessStatus accessStatus;
  const CoverImage({
    super.key,
    required this.url,
    this.width = 48,
    this.height = 64,
    this.radius = 8,
    this.fit = BoxFit.cover,
    this.isBrave = false,
    this.showPeekButton = true,
    this.compactPeek = false,
    this.bookId = 0,
    this.accessStatus = BookAccessStatus.unknown,
  });

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  bool _revealed = false;
  bool _probeScheduled = false;
  Timer? _probeDeferTimer;
  bool _lastBrave = false;
  int _probeEpoch = 0;
  ModalRoute<dynamic>? _route;
  bool get _brave =>
      widget.isBrave ||
      (widget.bookId > 0 && LKStore.isBraveBook(widget.bookId));
  bool get _needsBraveProbe =>
      LKStore.hideBraveBooks.value ||
      LKStore.coverBlurMode.value == CoverBlurMode.brave;

  @override
  void initState() {
    super.initState();
    _lastBrave = _brave;
    LKStore.braveBookRevision.addListener(_onBraveChanged);
  }

  void _onBraveChanged() {
    if (!mounted || _lastBrave == _brave) return;
    _lastBrave = _brave;
    setState(() {
      _revealed = false;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.url != widget.url ||
        oldWidget.isBrave != widget.isBrave ||
        oldWidget.accessStatus != widget.accessStatus) {
      _revealed = false;
      ++_probeEpoch;
      _probeScheduled = false;
      _probeDeferTimer?.cancel();
      _probeDeferTimer = null;
      _lastBrave = _brave;
    }
  }

  void _scheduleAccessProbe() {
    if (_probeScheduled ||
        widget.bookId <= 0 ||
        _brave ||
        widget.accessStatus != BookAccessStatus.unknown ||
        !_needsBraveProbe ||
        LKStore.dataSaverMode.value) {
      return;
    }
    final probe = BookAccessProbe.shared;
    if (probe.queued >= probe.maxPending) {
      if (_probeDeferTimer != null) return;
      final epoch = _probeEpoch;
      _probeDeferTimer = Timer(const Duration(milliseconds: 400), () {
        _probeDeferTimer = null;
        if (!mounted || epoch != _probeEpoch) return;
        _scheduleAccessProbe();
      });
      return;
    }
    _probeScheduled = true;
    final epoch = _probeEpoch;
    final id = widget.bookId;
    final account = LKClient.sessionRev.value;
    bool current() =>
        mounted &&
        epoch == _probeEpoch &&
        id == widget.bookId &&
        account == LKClient.sessionRev.value &&
        _route?.isCurrent != false &&
        _needsBraveProbe &&
        !LKStore.dataSaverMode.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        try {
          if (current()) {
            await BookAccessProbe.shared.lookup(id, isCurrent: current);
          }
        } finally {
          if (mounted && epoch == _probeEpoch) _probeScheduled = false;
        }
      }());
    });
  }

  @override
  void dispose() {
    ++_probeEpoch;
    _probeDeferTimer?.cancel();
    _probeDeferTimer = null;
    LKStore.braveBookRevision.removeListener(_onBraveChanged);
    super.dispose();
  }

  Widget _buildPlaceholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final double effectiveWidth = widget.width.isFinite && widget.width > 0
            ? widget.width
            : (constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : 72.0);
        final double iconSize = (effectiveWidth * 0.42).clamp(24.0, 56.0);
        return Container(
          width: widget.width.isFinite ? widget.width : null,
          height: widget.height.isFinite ? widget.height : null,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.surfaceContainerHigh,
                scheme.surfaceContainerHighest,
              ],
            ),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: Center(
            child: Icon(
              Icons.menu_book_rounded,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
              size: iconSize,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final effectiveUrl = widget.url.trim();
    final placeholder = _buildPlaceholder(context);
    final boxWidth = widget.width.isFinite ? widget.width : null;
    final boxHeight = widget.height.isFinite ? widget.height : null;

    return ValueListenableBuilder<bool>(
      valueListenable: LKStore.dataSaverMode,
      builder: (context, dataSaver, _) {
        if (dataSaver) {
          return Container(
            width: boxWidth,
            height: boxHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.radius),
              child: placeholder,
            ),
          );
        }

        _scheduleAccessProbe();
        final targetUrl = effectiveUrl.isEmpty ? kDefaultCover : effectiveUrl;

        return ValueListenableBuilder<CoverBlurMode>(
          valueListenable: LKStore.coverBlurMode,
          builder: (context, blurMode, _) {
            final isBlurTarget = switch (blurMode) {
              CoverBlurMode.all => true,
              CoverBlurMode.brave => _brave,
              CoverBlurMode.none => false,
            };
            final shouldBlur = isBlurTarget && !_revealed;
            final canShowPeek = widget.showPeekButton &&
                (widget.width > 52 || !widget.width.isFinite);

            Widget image = CachedNetworkImage(
              fadeOutDuration: AppMotion.duration(context, 1000),
              fadeInDuration: AppMotion.duration(context, 500),
              imageUrl: targetUrl,
              width: boxWidth,
              height: boxHeight,
              memCacheWidth: imageCacheDimension(context, widget.width),
              fit: widget.fit,
              placeholder: (_, __) => placeholder,
              errorWidget: (_, __, ___) => effectiveUrl.isNotEmpty &&
                      targetUrl != kDefaultCover
                  ? CachedNetworkImage(
                      fadeOutDuration: AppMotion.duration(context, 1000),
                      fadeInDuration: AppMotion.duration(context, 500),
                      imageUrl: kDefaultCover,
                      width: boxWidth,
                      height: boxHeight,
                      memCacheWidth: imageCacheDimension(context, widget.width),
                      fit: widget.fit,
                      placeholder: (_, __) => placeholder,
                      errorWidget: (_, __, ___) => placeholder,
                    )
                  : placeholder,
            );

            if (shouldBlur) {
              image = RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: image,
                ),
              );
            }

            return Container(
              width: boxWidth,
              height: boxHeight,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.radius),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    image,
                    if (isBlurTarget && canShowPeek)
                      Positioned(
                        top: widget.compactPeek ? 3.5 : 5,
                        right: widget.compactPeek ? 3.5 : 5,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _revealed = !_revealed),
                          child: Container(
                            padding:
                                EdgeInsets.all(widget.compactPeek ? 3 : 4.5),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 3,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: Icon(
                              _revealed
                                  ? Icons.visibility_rounded
                                  : Icons.visibility_off_rounded,
                              color: Colors.white,
                              size: widget.compactPeek ? 10.5 : 13,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 书籍卡片:白底圆角 + 封面阴影 + 标签胶囊 + 状态徽章
class BookCard extends StatelessWidget {
  final LKBook book;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final int? rank;
  const BookCard(
      {super.key,
      required this.book,
      required this.onTap,
      this.onLongPress,
      this.rank});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor =
        Theme.of(context).cardTheme.color ?? scheme.surfaceContainerLow;
    final titleColor = scheme.onSurface;
    final status = bookStatusLabel(book);
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
        child: Material(
          color: cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: isDark ? 0.25 : 0.2),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (rank != null) _rankBadge(scheme, rank!),
                  if (rank != null) const SizedBox(width: 10),
                  CoverImage(
                      key: ValueKey(book.bookId),
                      url: book.coverUrl,
                      width: 76,
                      height: 107,
                      radius: 8,
                      isBrave: book.isBrave,
                      bookId: book.bookId,
                      accessStatus: book.accessStatus),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                              color: titleColor),
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              book.authorName.isEmpty ? '佚名' : book.authorName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant),
                            ),
                            _statusBadge(scheme, status),
                            if (book.isBrave) _braveBadge(scheme),
                            if (book.unreadChapterCount > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: scheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${book.unreadChapterCount} 章更新',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onPrimaryContainer,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          runSpacing: 4,
                          children: [
                            // 过长的 tag(如整段书名式 tag)不展示,避免 RIGHT OVERFLOW
                            ..._shortTags(book.tags)
                                .take(3)
                                .map((t) => _tagChip(scheme, t)),
                            if (book.wordCount > 0)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Text(
                                  _fmtWord(book.wordCount),
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant),
                                ),
                              ),
                          ],
                        ),
                        // 小说介绍(单列卡片的简介)
                        if (book.summary.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            book.summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.45,
                                color: scheme.onSurfaceVariant),
                          ),
                        ],
                        // 最后更新时间
                        if (book.updatedAt.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Row(children: [
                            Icon(Icons.schedule_rounded,
                                size: 12, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '更新于 ${book.updatedAt.length > 16 ? book.updatedAt.substring(0, 16) : book.updatedAt}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ]),
                        ],
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 20, color: scheme.outlineVariant),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rankBadge(ColorScheme scheme, int r) {
    final Color color;
    if (r == 1) {
      color = const Color(0xFFF57F17);
    } else if (r == 2) {
      color = const Color(0xFF78909C);
    } else if (r == 3) {
      color = const Color(0xFFBF6B4A);
    } else {
      color = scheme.onSurfaceVariant;
    }
    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: color.withValues(alpha: 0.4),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Text(
        '$r',
        style: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
      ),
    );
  }

  Widget _statusBadge(ColorScheme scheme, String status) {
    final done = status == '完结';
    final color = done ? scheme.tertiary : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Text(status,
          style: TextStyle(
              fontSize: 10, color: color, fontWeight: FontWeight.w500)),
    );
  }

  Widget _braveBadge(ColorScheme scheme) {
    final color = scheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.6),
      ),
      child: Text(
        '勇者',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _tagChip(ColorScheme scheme, String tag) {
    return Container(
      margin: const EdgeInsets.only(right: 5),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      constraints: const BoxConstraints(maxWidth: 110),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(tag,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: scheme.primary)),
    );
  }

  /// 过长的 tag 在主页不展示(12 字以内)
  static List<String> _shortTags(List<String> tags) =>
      tags.where((t) => t.length <= 12).toList();

  static String _fmtWord(int n) =>
      n >= 10000 ? '${(n / 10000).toStringAsFixed(1)}万字' : '$n字';
}

Widget _braveCornerBadge(ColorScheme scheme, {bool compact = false}) {
  return Container(
    padding: EdgeInsets.symmetric(
      horizontal: compact ? 3.5 : 5,
      vertical: compact ? 1.5 : 2,
    ),
    decoration: BoxDecoration(
      color: scheme.error.withValues(alpha: 0.90),
      borderRadius: BorderRadius.circular(compact ? 3 : 4),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.3),
          blurRadius: compact ? 2 : 4,
          offset: const Offset(0, 1),
        ),
      ],
    ),
    child: Text(
      '勇者',
      style: TextStyle(
        fontSize: compact ? 8.5 : 9.5,
        fontWeight: FontWeight.bold,
        color: scheme.onError,
      ),
    ),
  );
}

/// 过长的 tag(如整段书名式 tag)过滤掉,避免溢出
List<String> shortTags(List<String> tags) =>
    tags.where((t) => t.length <= 12).toList();

/// 书籍网格排版代理：
/// 1. 支持指定固定列数（2/3/4/5）或自动自适应（<= 0 时按 maxCrossAxisExtent: 220 自动计算）；
/// 2. 锁定封面为 105:148 比例，卡片总高度 = 封面高度 + 文字区高度；
/// 3. 文字区按列宽和系统字体缩放预留两行标题及一行次要信息。
class BookGridDelegate extends SliverGridDelegate {
  final int columnCount;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final double maxCrossAxisExtent;
  final bool isShelf;
  final TextScaler textScaler;

  /// 轻小说文库本标准封面宽高比（A6 规格：105mm × 148mm，约 1 : 1.4095）。
  /// 平台小说封面均依此日本文库本标准规格制作（如 697x981、826x1163、1065x1500、1367x1923），
  /// 锁定 105:148 可让封面 100% 完整展示，彻底解决 3:4 比例下顶部书名/LOGO 与底部出版标识被裁切的问题。
  static const double coverAspectRatio = 105.0 / 148.0; // 约 0.7095 (1 : 1.4095)

  const BookGridDelegate({
    this.columnCount = 0,
    this.crossAxisSpacing = 10,
    this.mainAxisSpacing = 12,
    this.maxCrossAxisExtent = 220,
    this.isShelf = false,
    this.textScaler = TextScaler.noScaling,
  });

  /// 根据单元格宽度计算文字信息区的高度（与 BookGridCard 严格保持一致）
  static double calculateTextHeight(double cellWidth,
      {bool isShelf = false, TextScaler textScaler = TextScaler.noScaling}) {
    final dense = cellWidth < 105;
    final compact = cellWidth < 150;
    final titleSize = dense ? 11.0 : (compact ? 12.0 : (isShelf ? 13.0 : 13.5));
    final topGap =
        isShelf ? (dense ? 3.0 : 4.0) : (dense ? 4.0 : (compact ? 5.0 : 7.0));
    final titleHeight =
        (textScaler.scale(titleSize) * (isShelf ? 1.22 : 1.25)).ceilToDouble() *
            2;
    final secondaryHeight = isShelf || dense
        ? 0.0
        : (compact ? 2.0 : 3.0) +
            (textScaler.scale(compact ? 10.0 : 10.5) * 1.25).ceilToDouble();
    final requiredHeight = topGap + titleHeight + secondaryHeight;
    return math.max(
        requiredHeight, _minimumTextHeight(cellWidth, isShelf: isShelf));
  }

  static double _minimumTextHeight(double cellWidth, {bool isShelf = false}) {
    if (isShelf) {
      // 书架模式：仅展示书名（最多 2 行），无次要标签行，行高与留白更紧凑精干，极大减小行间空隙
      if (cellWidth < 105) {
        return 31.0;
      } else if (cellWidth < 150) {
        return 35.0;
      } else {
        return 38.0;
      }
    }
    if (cellWidth < 105) {
      // 密集模式（如手机 4~5 列）：2 行书名（11pt，行高 1.25，高约 27.5）+ 顶部间距 4 + 底部微量余量 = 36.0
      return 36.0;
    } else if (cellWidth < 150) {
      // 紧凑模式（如手机 3 列）：2 行书名（12pt，高约 30）+ 间距 5 + 单行字数（高约 11）+ 间距 2 = 48.0
      return 48.0;
    } else {
      // 标准模式（如常规 2 列）：2 行书名（13.5pt，高约 34）+ 间距 7 + 标签/字数行（高约 14）+ 间距 3 = 58.0
      return 58.0;
    }
  }

  /// 辅助计算：给定总可用宽度，计算列数、单元格宽、高以及总行步长（供滚动锚定精准计算）
  static ({int count, double cellWidth, double cellHeight, double rowStride})
      computeMetrics({
    required double usableWidth,
    int columnCount = 0,
    double crossAxisSpacing = 10,
    double? mainAxisSpacing,
    double maxCrossAxisExtent = 220,
    bool isShelf = false,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    final int count = columnCount > 0
        ? columnCount
        : math.max(2, (usableWidth / maxCrossAxisExtent).ceil());
    final double totalCrossSpacing = crossAxisSpacing * (count - 1);
    final double cellWidth =
        math.max(0.0, (usableWidth - totalCrossSpacing) / count);
    final double coverHeight = cellWidth / coverAspectRatio;
    final double textHeight = calculateTextHeight(cellWidth,
        isShelf: isShelf, textScaler: textScaler);
    final double cellHeight = coverHeight + textHeight;
    final double effectiveMainAxisSpacing =
        mainAxisSpacing ?? (isShelf ? 8.0 : 12.0);
    final double rowStride = cellHeight + effectiveMainAxisSpacing;
    return (
      count: count,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      rowStride: rowStride,
    );
  }

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final double usableCrossAxisExtent =
        math.max(0.0, constraints.crossAxisExtent);
    final metrics = computeMetrics(
      usableWidth: usableCrossAxisExtent,
      columnCount: columnCount,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
      maxCrossAxisExtent: maxCrossAxisExtent,
      isShelf: isShelf,
      textScaler: textScaler,
    );

    return SliverGridRegularTileLayout(
      crossAxisCount: metrics.count,
      mainAxisStride: metrics.rowStride,
      crossAxisStride: metrics.cellWidth + crossAxisSpacing,
      childMainAxisExtent: metrics.cellHeight,
      childCrossAxisExtent: metrics.cellWidth,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(BookGridDelegate oldDelegate) {
    return oldDelegate.columnCount != columnCount ||
        oldDelegate.crossAxisSpacing != crossAxisSpacing ||
        oldDelegate.mainAxisSpacing != mainAxisSpacing ||
        oldDelegate.maxCrossAxisExtent != maxCrossAxisExtent ||
        oldDelegate.isShelf != isShelf ||
        oldDelegate.textScaler != textScaler;
  }
}

/// 书籍网格使用自适应/用户指定列数。
/// 封面比例保持 105:148，文字区跟随系统字体缩放。
SliverGridDelegate bookGridDelegate(
  BuildContext context, {
  int? columnCount,
  double crossAxisSpacing = 10,
  double? mainAxisSpacing,
  bool isShelf = false,
}) =>
    BookGridDelegate(
      columnCount: columnCount ?? LKStore.gridColumnCount.value,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing ?? (isShelf ? 8.0 : 12.0),
      isShelf: isShelf,
      textScaler: MediaQuery.textScalerOf(context),
    );

/// 弹出网格列数选择面板
Future<void> showGridColumnsSheet(BuildContext context) async {
  final current = LKStore.gridColumnCount.value;
  final options = [
    (0, '自动', '根据屏幕宽度自适应列数（手机通常 2 列）', Icons.auto_awesome_outlined),
    (2, '2 列', '经典双列大图海报，展示最全信息', Icons.grid_view_rounded),
    (3, '3 列', '紧凑排版，兼顾封面与浏览效率', Icons.view_column_outlined),
    (4, '4 列', '高密度速览，一屏纵览更多作品', Icons.view_comfy_alt_outlined),
    (5, '5 列', '极密浏览，适合大屏或快速检索', Icons.apps_rounded),
  ];

  await showModalBottomSheet<void>(
    sheetAnimationStyle: AppMotion.style(context),
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (sheetContext) => M3MenuSheet(
      title: '网格列数',
      icon: Icons.grid_view_outlined,
      description: '选择每行展示的书籍数量',
      children: [
        for (final (count, title, subtitle, icon) in options)
          M3OptionTile(
            title: title,
            subtitle: subtitle,
            icon: icon,
            selected: current == count,
            onTap: () {
              Navigator.pop(sheetContext);
              LKStore.setGridColumnCount(count);
            },
          ),
      ],
    ),
  );
}

/// 书籍网格卡片（自适应多列密度排版）
class BookGridCard extends StatelessWidget {
  final LKBook book;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final int? rank;
  final bool isShelf;
  const BookGridCard({
    super.key,
    required this.book,
    required this.onTap,
    this.onLongPress,
    this.rank,
    this.isShelf = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = bookStatusLabel(book);

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        // 三档密度响应：
        // isDense (< 105): 4~5 列极密模式
        // isCompact (105~149): 3 列紧凑模式
        // isStandard (>= 150): 2 列标准海报模式
        final isDense = cardWidth < 105;
        final isCompact = cardWidth >= 105 && cardWidth < 150;
        final visibleTags = isCompact
            ? const <String>[]
            : shortTags(book.tags)
                .where((tag) => tag.trim().isNotEmpty)
                .toList();
        final hasTags = visibleTags.isNotEmpty;
        final wordCountLabel = Text(
          book.wordCount >= 10000
              ? '${(book.wordCount / 10000).toStringAsFixed(1)}万字'
              : '${book.wordCount}字',
          style: TextStyle(
            fontSize: isCompact ? 10.0 : 10.5,
            height: 1.25,
            color: scheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );

        final coverHeight = cardWidth / BookGridDelegate.coverAspectRatio;

        return RepaintBoundary(
          child: InkWell(
            borderRadius: BorderRadius.circular(isDense ? 8 : 12),
            onTap: onTap,
            onLongPress: onLongPress,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面严格锁定文库本 105:148 比例（约 1:1.41），100% 完整展现原图无裁切
                AspectRatio(
                  aspectRatio: BookGridDelegate.coverAspectRatio,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CoverImage(
                          key: ValueKey(book.bookId),
                          url: book.coverUrl,
                          width: cardWidth,
                          height: coverHeight,
                          radius: isDense ? 8 : 12,
                          isBrave: book.isBrave,
                          bookId: book.bookId,
                          accessStatus: book.accessStatus,
                          compactPeek: isDense,
                        ),
                      ),
                      // 1. 排名角标（左上角）
                      if (rank != null)
                        Positioned(
                          top: isDense ? 4 : 6,
                          left: isDense ? 4 : 6,
                          child: Container(
                            width: isDense ? 20 : (isCompact ? 22 : 26),
                            height: isDense ? 20 : (isCompact ? 22 : 26),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: rank! <= 3
                                  ? (rank == 1
                                      ? const Color(0xFFF57F17)
                                      : rank == 2
                                          ? const Color(0xFF78909C)
                                          : const Color(0xFFBF6B4A))
                                  : Colors.black54,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                            child: Text(
                              '$rank',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: isDense ? 10 : (isCompact ? 11 : 13),
                              ),
                            ),
                          ),
                        ),
                      // 2. 勇者角标（左上角，若有排名则排在排名右侧）
                      if (book.isBrave)
                        Positioned(
                          top: isDense ? 4 : 6,
                          left: rank != null
                              ? (isDense ? 26 : (isCompact ? 30 : 36))
                              : (isDense ? 4 : 6),
                          child: _braveCornerBadge(scheme, compact: isDense),
                        ),
                      // 3. 更新章数角标：
                      // 小封面（isDense/isCompact）或右上角有高斯模糊睁眼按钮时，置于左下角，彻底避免与左上角和右上角撞车挤压；
                      // 仅在宽敞的标准封面且无模糊按钮遮挡时置于右上角。
                      if (book.unreadChapterCount > 0)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ListenableBuilder(
                              listenable: Listenable.merge([
                                LKStore.coverBlurMode,
                                LKStore.braveBookRevision,
                              ]),
                              builder: (context, _) {
                                final isBraveNow = book.isBrave ||
                                    LKStore.isBraveBook(book.bookId);
                                final isBlurActive =
                                    LKStore.coverBlurMode.value ==
                                            CoverBlurMode.all ||
                                        (LKStore.coverBlurMode.value ==
                                                CoverBlurMode.brave &&
                                            isBraveNow);
                                final placeBottomLeft =
                                    isDense || isCompact || isBlurActive;
                                return Align(
                                  alignment: placeBottomLeft
                                      ? Alignment.bottomLeft
                                      : Alignment.topRight,
                                  child: Padding(
                                    padding: EdgeInsets.all(isDense ? 4 : 6),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: isDense ? 4 : 6,
                                        vertical: placeBottomLeft
                                            ? (isDense ? 1.5 : 2.5)
                                            : 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: scheme.primaryContainer
                                            .withValues(alpha: 0.94),
                                        borderRadius: BorderRadius.circular(
                                            isDense ? 5 : 7),
                                        boxShadow: placeBottomLeft
                                            ? [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.25),
                                                  blurRadius: 2,
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: Text(
                                        isDense
                                            ? '+${book.unreadChapterCount}'
                                            : '${book.unreadChapterCount} 章更新',
                                        style: TextStyle(
                                          fontSize: isDense ? 8.5 : 10,
                                          fontWeight: FontWeight.w600,
                                          color: scheme.onPrimaryContainer,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      // 4. 连载/完结状态角标（右下角）
                      Positioned(
                        bottom: isDense ? 4 : 6,
                        right: isDense ? 4 : 6,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: isDense ? 4 : 6,
                            vertical: isDense ? 1.5 : 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius:
                                BorderRadius.circular(isDense ? 4 : 6),
                          ),
                          child: Text(
                            isDense
                                ? (status.contains('完结') ? '完结' : '连载')
                                : status,
                            style: TextStyle(
                              fontSize: isDense ? 8.5 : 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: isShelf
                      ? (isDense ? 3 : 4)
                      : (isDense ? 4 : (isCompact ? 5 : 7)),
                ),
                // 书名：保持可读，不随列数无限缩小，固定最多两行
                Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isDense
                        ? 11.0
                        : (isCompact ? 12.0 : (isShelf ? 13.0 : 13.5)),
                    fontWeight: FontWeight.w600,
                    height: isShelf ? 1.22 : 1.25,
                    color: scheme.onSurface,
                  ),
                ),
                // 次要信息行：密集模式及书架模式隐藏，紧凑模式显示精简字数，标准模式显示完整标签与字数
                if (!isDense && !isShelf) ...[
                  SizedBox(height: isCompact ? 2 : 3),
                  Row(
                    children: [
                      if (hasTags)
                        Expanded(
                          child: Text(
                            visibleTags.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              height: 1.25,
                              color: scheme.primary,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      if (book.wordCount > 0)
                        Padding(
                          padding: EdgeInsets.only(left: hasTags ? 6 : 0),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: cardWidth * (hasTags ? 0.45 : 1),
                            ),
                            child: wordCountLabel,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

enum LkNoticeTone { info, success, error }

LkNoticeTone inferLkNoticeTone(Object source, {bool defaultError = false}) {
  if (source is Exception || source is Error) return LkNoticeTone.error;
  final text = source.toString().trim();
  const errorHints = [
    '失败',
    '错误',
    '异常',
    '不存在',
    '无法',
    '不能',
    '不足',
    '无效',
    '超时',
    '重试',
    '暂不可用',
    '尚未',
    '请先',
    '请完成',
    '至少',
    '不能为空',
    '未开启',
    '已失效',
  ];
  for (final hint in errorHints) {
    if (text.contains(hint)) return LkNoticeTone.error;
  }
  const successHints = [
    '成功',
    '已复制',
    '已保存',
    '已加入',
    '已关注',
    '已清除',
    '已清理',
    '已删除',
    '已另存为',
    '已退出',
    '已领取',
    '已签到',
    '已取消关注',
    '已佩戴',
    '已取下',
  ];
  for (final hint in successHints) {
    if (text.contains(hint)) return LkNoticeTone.success;
  }
  return defaultError ? LkNoticeTone.error : LkNoticeTone.info;
}

/// 全应用统一格式的悬浮消息条，自动适配浅色、深色与纯黑主题。
SnackBar buildLkSnackBar(
  BuildContext context,
  String message, {
  LkNoticeTone tone = LkNoticeTone.info,
  Duration duration = const Duration(seconds: 3),
  EdgeInsetsGeometry? margin,
  SnackBarAction? action,
}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final dark = theme.brightness == Brightness.dark;
  final accent = tone == LkNoticeTone.error ? scheme.error : scheme.primary;
  final icon = switch (tone) {
    LkNoticeTone.error => Icons.error_outline_rounded,
    LkNoticeTone.success => Icons.check_rounded,
    LkNoticeTone.info => Icons.info_outline_rounded,
  };
  final border = tone == LkNoticeTone.error
      ? scheme.error.withValues(alpha: dark ? 0.45 : 0.35)
      : scheme.outlineVariant.withValues(alpha: dark ? 0.42 : 0.55);

  return SnackBar(
    content: Row(
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: dark ? 0.20 : 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 15, color: accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message.trim(),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              height: 1.35,
              color: scheme.onSurface,
            ),
          ),
        ),
      ],
    ),
    backgroundColor:
        dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLowest,
    elevation: 6,
    duration: duration,
    behavior: SnackBarBehavior.floating,
    dismissDirection: DismissDirection.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    margin: margin ?? const EdgeInsets.fromLTRB(16, 0, 16, 18),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: border),
    ),
    action: action,
  );
}

ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showLkSnackBar(
  BuildContext context,
  String message, {
  LkNoticeTone? tone,
  Duration duration = const Duration(seconds: 3),
  EdgeInsetsGeometry? margin,
  SnackBarAction? action,
}) {
  final value = message.trim();
  if (value.isEmpty || !context.mounted) return null;
  final resolvedTone = tone ?? inferLkNoticeTone(value);
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  return messenger.showSnackBar(
    buildLkSnackBar(
      context,
      value,
      tone: resolvedTone,
      duration: duration,
      margin: margin,
      action: action,
    ),
    snackBarAnimationStyle: AppMotion.style(context),
  );
}

/// 统一的错误/状态提示条
void showLkError(BuildContext context, Object e) {
  if (!context.mounted) return;
  showLkSnackBar(
    context,
    e.toString(),
    tone: inferLkNoticeTone(e, defaultError: true),
    duration: const Duration(seconds: 2),
  );
}

/// 统一悬浮气泡提示
void showFloatingPrompt(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 3),
  LkNoticeTone? tone,
}) {
  showLkSnackBar(
    context,
    message,
    tone: tone ?? inferLkNoticeTone(message),
    duration: duration,
  );
}
