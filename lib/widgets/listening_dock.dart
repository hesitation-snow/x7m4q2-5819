import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/store.dart';
import '../pages/reader_page.dart';
import '../pages/tts_settings_page.dart';
import '../services/app_motion.dart';
import '../services/listening_now.dart';
import 'liquid_glass_bottom_bar.dart';
import 'm3_menu_sheet.dart';
import 'reader_listening_sheet.dart';

/// Home entry for an in-progress listening session. One tap opens the menu.
class ListeningDock extends StatefulWidget {
  const ListeningDock({
    super.key,
    this.liquidGlass = false,
    this.glassConfiguration,
  });

  final bool liquidGlass;
  final GlassConfiguration? glassConfiguration;

  @override
  State<ListeningDock> createState() => _ListeningDockState();
}

class _ListeningDockState extends State<ListeningDock> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  Widget _buildDockBadge(
    BuildContext context, {
    required ColorScheme scheme,
    required bool dark,
    required bool hasError,
    required Color badgeAccent,
    required double? progress,
    required String coverUrl,
    required int bookId,
  }) {
    final fallback = Stack(
      alignment: Alignment.center,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hasError
                ? scheme.errorContainer.withValues(alpha: dark ? 0.55 : 0.85)
                : scheme.primary.withValues(alpha: dark ? 0.24 : 0.14),
          ),
          child: const SizedBox.expand(),
        ),
        Icon(
          hasError ? Icons.error_outline_rounded : Icons.headphones_rounded,
          size: 18,
          color: badgeAccent,
        ),
      ],
    );

    final trimmedCover = coverUrl.trim();
    Widget inner = fallback;
    if (!hasError && trimmedCover.isNotEmpty) {
      final cacheWidth =
          (31 * MediaQuery.devicePixelRatioOf(context)).round().clamp(32, 256);
      inner = ValueListenableBuilder<bool>(
        valueListenable: LKStore.dataSaverMode,
        builder: (context, dataSaver, _) {
          if (dataSaver) return fallback;
          return ValueListenableBuilder<CoverBlurMode>(
            valueListenable: LKStore.coverBlurMode,
            builder: (context, blurMode, _) {
              return ValueListenableBuilder<int>(
                valueListenable: LKStore.braveBookRevision,
                builder: (context, _, __) {
                  final shouldBlur = switch (blurMode) {
                    CoverBlurMode.all => true,
                    CoverBlurMode.brave =>
                      bookId > 0 && LKStore.isBraveBook(bookId),
                    CoverBlurMode.none => false,
                  };
                  Widget artwork = CachedNetworkImage(
                    key: const ValueKey('listening-dock-cover'),
                    imageUrl: trimmedCover,
                    width: 31,
                    height: 31,
                    memCacheWidth: cacheWidth,
                    fit: BoxFit.cover,
                    fadeInDuration: AppMotion.duration(context, 200),
                    fadeOutDuration: AppMotion.duration(context, 200),
                    placeholder: (_, __) => fallback,
                    errorWidget: (_, __, ___) => fallback,
                  );
                  if (shouldBlur) {
                    artwork = ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                      child: artwork,
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.all(2.5),
                    child: ClipOval(child: artwork),
                  );
                },
              );
            },
          );
        },
      );
    }

    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(child: inner),
          Positioned.fill(
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 2,
              strokeCap: StrokeCap.round,
              color: badgeAccent,
              backgroundColor: badgeAccent.withValues(
                alpha: dark ? 0.18 : 0.12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ListeningNow.instance,
      builder: (context, _) {
        final now = ListeningNow.instance;
        final session = now.session;
        final errorBanner = now.hasErrorBanner;
        if ((!now.active || session == null) && !errorBanner) {
          return const SizedBox.shrink();
        }

        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final dark = theme.brightness == Brightness.dark;
        final reduceMotion = AppMotion.isDisabled(context);
        final scaler = MediaQuery.textScalerOf(context);
        final titleLine = scaler.scale(13.5) * 1.25;
        final subtitleLine = scaler.scale(11.5) * 1.25;
        final dockHeight = math.max(54.0, titleLine + subtitleLine + 20.0);

        final error = errorBanner ? now.lastError : session?.error;
        final hasError = error != null && error.isNotEmpty;
        final sentence = session?.currentSegment?.text ?? '';
        final subtitleText = hasError
            ? '朗读失败，点击查看'
            : sentence.isNotEmpty
                ? sentence
                : '正在准备语音…';
        final double? progress = session == null
            ? 0.0
            : session.isBuffering
                ? (reduceMotion ? 0.25 : null)
                : session.segmentCount > 0
                    ? ((session.position + 1) / session.segmentCount)
                        .clamp(0.0, 1.0)
                    : 0.0;
        final badgeAccent = hasError ? scheme.error : scheme.primary;
        final toggleLabel = errorBanner
            ? '关闭'
            : (session?.isPaused ?? true)
                ? '继续'
                : '暂停';

        final content = InkWell(
          key: const ValueKey('listening-dock'),
          borderRadius: BorderRadius.circular(dockHeight / 2),
          onTap: () => showListeningMenu(context),
          onHighlightChanged: _setPressed,
          child: SizedBox(
            height: dockHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 0, 8, 0),
              child: Row(
                children: [
                  _buildDockBadge(
                    context,
                    scheme: scheme,
                    dark: dark,
                    hasError: hasError,
                    badgeAccent: badgeAccent,
                    progress: progress,
                    coverUrl: now.coverUrl,
                    bookId: now.bookId,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          now.bookTitle.isEmpty ? '正在听书' : now.bookTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                            color: scheme.onSurface,
                          ),
                        ),
                        Text(
                          subtitleText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5,
                            height: 1.25,
                            color: hasError
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: toggleLabel,
                    excludeFromSemantics: true,
                    child: Semantics(
                      button: true,
                      label: toggleLabel,
                      child: Material(
                        color: scheme.primaryContainer
                            .withValues(alpha: dark ? 0.55 : 0.78),
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            if (errorBanner) {
                              now.clearError();
                            } else {
                              unawaited(now.toggle());
                            }
                          },
                          child: SizedBox(
                            width: 38,
                            height: 38,
                            child: Icon(
                              errorBanner
                                  ? Icons.close_rounded
                                  : (session?.isPaused ?? true)
                                      ? Icons.play_arrow_rounded
                                      : Icons.pause_rounded,
                              size: 21,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        final activePress = _pressed && !reduceMotion;

        if (widget.liquidGlass) {
          final optics = widget.glassConfiguration ??
              LKStore.glassConfigurationFor(MediaQuery.sizeOf(context));
          final dockWidth = liquidGlassBarWidth(context, optics);
          return AnimatedScale(
            scale: activePress ? 0.985 : 1.0,
            duration: AppMotion.duration(context, 120),
            curve: Curves.easeOutCubic,
            child: LiquidGlassCapsule(
              surfaceKey: const ValueKey('listening-dock-glass-surface'),
              optics: optics,
              width: dockWidth,
              height: dockHeight,
              pressed: activePress,
              child: content,
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: AnimatedScale(
            scale: activePress ? 0.985 : 1.0,
            duration: AppMotion.duration(context, 120),
            curve: Curves.easeOutCubic,
            child: SizedBox(
              height: dockHeight,
              child: Material(
                color: scheme.surfaceContainerHigh,
                elevation: 4,
                shadowColor:
                    scheme.shadow.withValues(alpha: dark ? 0.45 : 0.22),
                shape: StadiumBorder(
                  side: BorderSide(
                    color: scheme.outlineVariant
                        .withValues(alpha: dark ? 0.42 : 0.50),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showListeningMenu(BuildContext context) {
  return showModalBottomSheet<void>(
    sheetAnimationStyle: AppMotion.style(context),
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    showDragHandle: false,
    isScrollControlled: true,
    builder: (sheetContext) => const ListeningMenu(),
  );
}

class ListeningMenu extends StatelessWidget {
  const ListeningMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 640,
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
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
              M3SheetHeader(
                title: '正在听书',
                icon: Icons.headphones_rounded,
                action: IconButton(
                  tooltip: '听书设置',
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const TtsSettingsPage(),
                      ),
                    );
                  },
                ),
                onClose: () => Navigator.pop(context),
              ),
              Flexible(
                child: ListenableBuilder(
                  listenable: ListeningNow.instance,
                  builder: (context, _) {
                    final now = ListeningNow.instance;
                    final session = now.session;
                    final errorBanner = now.hasErrorBanner;
                    if ((!now.active || session == null) && !errorBanner) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHigh,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.headphones_outlined,
                                color: scheme.onSurfaceVariant,
                                size: 24,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '当前没有在听的内容',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    final sentence = errorBanner
                        ? '后台朗读已停止，可返回阅读页继续。'
                        : (session?.currentSegment?.text ?? '正在准备下一段');
                    final error = errorBanner ? now.lastError : session?.error;
                    final hasError = error != null && error.isNotEmpty;
                    final title = now.chapterTitle.isNotEmpty
                        ? '${now.bookTitle} · ${now.chapterTitle}'
                        : (now.bookTitle.isEmpty ? '正在听书' : now.bookTitle);
                    final statusText = hasError
                        ? '朗读失败：$error'
                        : session!.isBuffering
                            ? '正在准备语音…'
                            : session.isPaused
                                ? '已暂停 · 第 ${session.position + 1}/${session.segmentCount} 段'
                                : '正在播放 · 第 ${session.position + 1}/${session.segmentCount} 段';
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ListeningPlaybackCard(
                            title: title,
                            status: statusText,
                            position: session?.position ?? 0,
                            segmentCount: session?.segmentCount ?? 0,
                            text: sentence,
                            loading: session?.isBuffering ?? false,
                            hasError: hasError,
                          ),
                          if (!errorBanner && session != null) ...[
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton.filledTonal(
                                  tooltip: '上一段',
                                  onPressed: session.position > 0
                                      ? () => unawaited(now.previous())
                                      : null,
                                  icon: const Icon(Icons.skip_previous_rounded),
                                ),
                                const SizedBox(width: 8),
                                IconButton.filled(
                                  tooltip: session.isPaused ? '继续' : '暂停',
                                  iconSize: 32,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(64, 56),
                                  ),
                                  onPressed: () => unawaited(now.toggle()),
                                  icon: Icon(session.isPaused
                                      ? Icons.play_arrow_rounded
                                      : Icons.pause_rounded),
                                ),
                                const SizedBox(width: 8),
                                IconButton.filledTonal(
                                  tooltip: '下一段',
                                  onPressed:
                                      session.position + 1 < session.segmentCount
                                          ? () => unawaited(now.next())
                                          : null,
                                  icon: const Icon(Icons.skip_next_rounded),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 44),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  onPressed: now.bookId <= 0
                                      ? null
                                      : () {
                                          final targetBookId = now.bookId;
                                          final targetBookTitle = now.bookTitle;
                                          final targetCoverUrl = now.coverUrl;
                                          final targetChapterId = now.chapterId;
                                          final targetChapterTitle =
                                              now.chapterTitle;
                                          final targetVolumeId = now.volumeId;
                                          if (errorBanner) now.clearError();
                                          Navigator.pop(context);
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ReaderPage(
                                                bookId: targetBookId,
                                                bookTitle: targetBookTitle,
                                                bookCoverUrl: targetCoverUrl,
                                                chapterId: targetChapterId,
                                                chapterTitle:
                                                    targetChapterTitle,
                                                volumeId: targetVolumeId,
                                              ),
                                            ),
                                          );
                                        },
                                  icon: const Icon(Icons.menu_book_rounded),
                                  label: const Text('回到阅读'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(0, 44),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  onPressed: () {
                                    Navigator.pop(context);
                                    if (errorBanner) {
                                      now.clearError();
                                    } else {
                                      unawaited(now.stop());
                                    }
                                  },
                                  icon: Icon(errorBanner
                                      ? Icons.close_rounded
                                      : Icons.stop_rounded),
                                  label: Text(errorBanner ? '关闭' : '停止'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
