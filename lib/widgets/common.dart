import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../services/app_motion.dart';

import '../api/models.dart';
import '../api/store.dart';

/// 选择退出范围。返回 true 表示同时退出其他设备，false 表示仅退出本机，
/// null 表示取消。
Future<bool?> showLogoutScopeDialog(BuildContext context) {
  return showModalBottomSheet<bool>(
    sheetAnimationStyle: AppMotion.style(context),
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;

      Widget option({
        required IconData icon,
        required String title,
        required String subtitle,
        required Color color,
        required VoidCallback onTap,
      }) {
        return Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 3),
                        Text(subtitle,
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                                height: 1.25)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        );
      }

      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: Material(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(28),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 28, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child:
                            Icon(Icons.logout_rounded, color: scheme.primary),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('退出登录',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w800)),
                            SizedBox(height: 3),
                            Text('选择要退出的登录范围', style: TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  option(
                    icon: Icons.smartphone_rounded,
                    title: '仅退出本机',
                    subtitle: '只清除此设备的登录状态',
                    color: scheme.primary,
                    onTap: () => Navigator.pop(sheetContext, false),
                  ),
                  const SizedBox(height: 10),
                  option(
                    icon: Icons.devices_rounded,
                    title: '退出所有设备',
                    subtitle: '使其他设备上的登录状态也失效',
                    color: scheme.error,
                    onTap: () => Navigator.pop(sheetContext, true),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: const StadiumBorder(),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
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
  });

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  bool _revealed = false;

  @override
  void didUpdateWidget(covariant CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.isBrave != widget.isBrave) {
      _revealed = false;
    }
  }

  Widget _buildPlaceholder(BuildContext context) {
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
              colors: [Colors.indigo.shade100, Colors.indigo.shade200],
            ),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          child: Center(
            child: Icon(
              Icons.menu_book_rounded,
              color: Colors.indigo.shade400,
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

        final targetUrl = effectiveUrl.isEmpty ? kDefaultCover : effectiveUrl;

        return ValueListenableBuilder<CoverBlurMode>(
          valueListenable: LKStore.coverBlurMode,
          builder: (context, blurMode, _) {
            final isBlurTarget = switch (blurMode) {
              CoverBlurMode.all => true,
              CoverBlurMode.brave => widget.isBrave,
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
              image = ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: image,
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
                            padding: EdgeInsets.all(widget.compactPeek ? 3 : 4.5),
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
  final int? rank;
  const BookCard(
      {super.key, required this.book, required this.onTap, this.rank});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = Theme.of(context).cardTheme.color ?? scheme.surfaceContainerLow;
    final titleColor =
        isDark ? const Color(0xFFECEDF1) : const Color(0xFF263238);
    final borderColor = isDark ? Colors.grey.shade800 : Colors.grey.shade300;
    final status = bookStatusLabel(book);
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
        child: Material(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
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
                      height: 101,
                      radius: 8,
                      isBrave: book.isBrave),
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
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                book.authorName.isEmpty
                                    ? '佚名'
                                    : book.authorName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? Colors.grey.shade400
                                        : Colors.grey.shade600),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _statusBadge(scheme, status, borderColor),
                            if (book.isBrave) ...[
                              const SizedBox(width: 6),
                              _braveBadge(scheme),
                            ],
                            if (book.unreadChapterCount > 0) ...[
                              const SizedBox(width: 6),
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
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
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
                                      color: isDark
                                          ? Colors.grey.shade500
                                          : Colors.grey.shade500),
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
                                color: isDark
                                    ? Colors.grey.shade400
                                    : Colors.grey.shade600),
                          ),
                        ],
                        // 最后更新时间
                        if (book.updatedAt.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Row(children: [
                            Icon(Icons.schedule_rounded,
                                size: 12,
                                color: isDark
                                    ? Colors.grey.shade500
                                    : Colors.grey.shade500),
                            const SizedBox(width: 4),
                            Text(
                              '更新于 ${book.updatedAt.length > 16 ? book.updatedAt.substring(0, 16) : book.updatedAt}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: isDark
                                      ? Colors.grey.shade500
                                      : Colors.grey.shade500),
                            ),
                          ]),
                        ],
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 20,
                      color:
                          isDark ? Colors.grey.shade700 : Colors.grey.shade300),
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
      color = Colors.grey.shade400;
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

  Widget _statusBadge(ColorScheme scheme, String status, Color borderColor) {
    final done = status == '完结';
    final color = done ? Colors.teal : scheme.primary;
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
    const color = Color(0xFFE53935);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.6),
      ),
      child: const Text(
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
      color: const Color(0xFFE53935).withValues(alpha: 0.88),
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
        color: Colors.white,
      ),
    ),
  );
}

/// 过长的 tag(如整段书名式 tag)过滤掉,避免溢出
List<String> shortTags(List<String> tags) =>
    tags.where((t) => t.length <= 12).toList();

/// 书籍网格排版代理：
/// 1. 支持指定固定列数（2/3/4/5）或自动自适应（<= 0 时按 maxCrossAxisExtent: 220 自动计算）；
/// 2. 精确锁定封面为 3:4 比例，卡片总高度 = 封面高度 + 自适应文字区高度；
/// 3. 文字区高度随卡片宽度阶梯自适应，彻底避免封面变形与溢出。
class BookGridDelegate extends SliverGridDelegate {
  final int columnCount;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final double maxCrossAxisExtent;

  const BookGridDelegate({
    this.columnCount = 0,
    this.crossAxisSpacing = 10,
    this.mainAxisSpacing = 12,
    this.maxCrossAxisExtent = 220,
  });

  /// 根据单元格宽度计算文字信息区的高度（与 BookGridCard 严格保持一致）
  static double calculateTextHeight(double cellWidth) {
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
    double mainAxisSpacing = 12,
    double maxCrossAxisExtent = 220,
  }) {
    final int count = columnCount > 0
        ? columnCount
        : math.max(2, (usableWidth / maxCrossAxisExtent).ceil());
    final double totalCrossSpacing = crossAxisSpacing * (count - 1);
    final double cellWidth =
        math.max(0.0, (usableWidth - totalCrossSpacing) / count);
    final double coverHeight = cellWidth * (4.0 / 3.0);
    final double textHeight = calculateTextHeight(cellWidth);
    final double cellHeight = coverHeight + textHeight;
    final double rowStride = cellHeight + mainAxisSpacing;
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
        oldDelegate.maxCrossAxisExtent != maxCrossAxisExtent;
  }
}

/// 书籍网格使用自适应/用户指定列数。
/// 封面比例严格保持 3:4，文字与角标自适应不同列宽。
SliverGridDelegate bookGridDelegate({int? columnCount}) => BookGridDelegate(
      columnCount: columnCount ?? LKStore.gridColumnCount.value,
      crossAxisSpacing: 10,
      mainAxisSpacing: 12,
    );

/// 弹出网格列数选择面板
Future<void> showGridColumnsSheet(BuildContext context) async {
  final current = LKStore.gridColumnCount.value;
  final options = [
    (0, '自动', '根据屏幕宽度自适应列数（手机通常 2 列）'),
    (2, '2 列', '经典双列大图海报，展示最全信息'),
    (3, '3 列', '紧凑排版，兼顾封面与浏览效率'),
    (4, '4 列', '高密度速览，一屏纵览更多作品'),
    (5, '5 列', '极密浏览，适合大屏或快速检索'),
  ];

  await showModalBottomSheet<void>(
    sheetAnimationStyle: AppMotion.style(context),
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (sheetContext) {
      final scheme = Theme.of(sheetContext).colorScheme;
      return Container(
        decoration: BoxDecoration(
          color: Theme.of(sheetContext).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(sheetContext).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Icon(Icons.grid_view_rounded,
                      size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    '网格列数（每行几本）',
                    style:
                        Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ...options.map((opt) {
              final (count, title, subtitle) = opt;
              final selected = current == count;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: selected
                      ? scheme.primaryContainer.withValues(alpha: 0.35)
                      : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(14),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      Navigator.pop(sheetContext);
                      LKStore.setGridColumnCount(count);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      title,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: selected
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        color: selected
                                            ? scheme.primary
                                            : scheme.onSurface,
                                      ),
                                    ),
                                    if (count == 0) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: scheme.primary
                                              .withValues(alpha: 0.12),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          '默认',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: scheme.primary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selected)
                            Icon(Icons.check_circle_rounded,
                                color: scheme.primary, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      );
    },
  );
}

/// 书籍网格卡片（自适应多列密度排版）
class BookGridCard extends StatelessWidget {
  final LKBook book;
  final VoidCallback onTap;
  final int? rank;
  const BookGridCard(
      {super.key, required this.book, required this.onTap, this.rank});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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

        final isBlurActive = LKStore.coverBlurMode.value == CoverBlurMode.all ||
            (LKStore.coverBlurMode.value == CoverBlurMode.brave && book.isBrave);

        return RepaintBoundary(
          child: InkWell(
            borderRadius: BorderRadius.circular(isDense ? 8 : 12),
            onTap: onTap,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面严格锁定 3:4 比例，杜绝文字挤压变形
                AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CoverImage(
                          key: ValueKey(book.bookId),
                          url: book.coverUrl,
                          width: double.infinity,
                          height: double.infinity,
                          radius: isDense ? 8 : 12,
                          isBrave: book.isBrave,
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
                                  blurRadius: isDense ? 2 : 4,
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
                      // 2. 勇者标记（左上角，位于排名右侧或贴左）
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
                        (isDense || isCompact || isBlurActive)
                            ? Positioned(
                                bottom: isDense ? 4 : 6,
                                left: isDense ? 4 : 6,
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: isDense ? 4 : 6,
                                    vertical: isDense ? 1.5 : 2.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.primaryContainer
                                        .withValues(alpha: 0.94),
                                    borderRadius: BorderRadius.circular(
                                        isDense ? 5 : 7),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.25),
                                        blurRadius: 2,
                                      ),
                                    ],
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
                              )
                            : Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: scheme.primaryContainer
                                        .withValues(alpha: 0.94),
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: Text(
                                    '${book.unreadChapterCount} 章更新',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: scheme.onPrimaryContainer,
                                    ),
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
                SizedBox(height: isDense ? 4 : (isCompact ? 5 : 7)),
                // 书名：保持可读，不随列数无限缩小，固定最多两行
                Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isDense ? 11.0 : (isCompact ? 12.0 : 13.5),
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                    color: isDark
                        ? const Color(0xFFECEDF1)
                        : const Color(0xFF263238),
                  ),
                ),
                // 次要信息行：密集模式隐藏，紧凑模式显示精简字数，标准模式显示完整标签与字数
                if (!isDense) ...[
                  SizedBox(height: isCompact ? 2 : 3),
                  Row(
                    children: [
                      if (!isCompact && book.tags.isNotEmpty)
                        Expanded(
                          child: Text(
                            shortTags(book.tags).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      if (book.wordCount > 0)
                        Text(
                          book.wordCount >= 10000
                              ? '${(book.wordCount / 10000).toStringAsFixed(1)}万字'
                              : '${book.wordCount}字',
                          style: TextStyle(
                            fontSize: isCompact ? 10.0 : 10.5,
                            color: Colors.grey.shade500,
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

/// 统一的错误提示条
void showLkError(BuildContext context, Object e) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      snackBarAnimationStyle: AppMotion.style(context),
      SnackBar(
        content: Text(e.toString()),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
}

/// 悬浮气泡提示（与书籍详情页点击书名弹出的悬浮框样式一致）
void showFloatingPrompt(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 3),
}) {
  final value = message.trim();
  if (value.isEmpty || !context.mounted) return;
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          value,
          style: TextStyle(
            color: isDark ? scheme.onSurface : scheme.onInverseSurface,
          ),
        ),
        backgroundColor:
            isDark ? scheme.surfaceContainerHighest : scheme.inverseSurface,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
}
