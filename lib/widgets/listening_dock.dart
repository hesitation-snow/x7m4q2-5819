import 'dart:async';

import 'package:flutter/material.dart';

import '../pages/reader_page.dart';
import '../pages/tts_settings_page.dart';
import '../services/app_motion.dart';
import '../services/listening_now.dart';
import 'm3_controls.dart';
import 'm3_menu_sheet.dart';
import 'reader_listening_sheet.dart';

/// Home entry for an in-progress listening session. One tap opens the menu.
class ListeningDock extends StatelessWidget {
  const ListeningDock({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ListeningNow.instance,
      builder: (context, _) {
        final now = ListeningNow.instance;
        final session = now.session;
        if (!now.active || session == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final sentence = session.currentSegment?.text ?? '正在准备下一段';
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Material(
            color: theme.colorScheme.surfaceContainerLow,
            elevation: 2,
            shadowColor: theme.colorScheme.shadow.withValues(alpha: .18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: .4)),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('listening-dock'),
              onTap: () => showListeningMenu(context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Row(
                  children: [
                    const AppSettingIcon(Icons.headphones_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            now.bookTitle.isEmpty ? '正在听书' : now.bookTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            sentence,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: session.isPaused ? '继续' : '暂停',
                      onPressed: () => unawaited(now.toggle()),
                      icon: Icon(session.isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded),
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
}

Future<void> showListeningMenu(BuildContext context) {
  return showModalBottomSheet<void>(
    sheetAnimationStyle: AppMotion.style(context),
    context: context,
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
                    if (!now.active || session == null) {
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
                    final sentence = session.currentSegment?.text ?? '正在准备下一段';
                    final error = session.error;
                    final hasError = error != null && error.isNotEmpty;
                    final title = now.chapterTitle.isNotEmpty
                        ? '${now.bookTitle} · ${now.chapterTitle}'
                        : (now.bookTitle.isEmpty ? '正在听书' : now.bookTitle);
                    final statusText = hasError
                        ? '朗读失败：$error'
                        : session.isLoading
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
                            position: session.position,
                            segmentCount: session.segmentCount,
                            text: sentence,
                            loading: session.isLoading,
                            hasError: hasError,
                          ),
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
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                tooltip: '停止',
                                onPressed: () {
                                  Navigator.pop(context);
                                  unawaited(now.stop());
                                },
                                icon: const Icon(Icons.stop_rounded),
                              ),
                            ],
                          ),
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
                                          Navigator.pop(context);
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) => ReaderPage(
                                                bookId: now.bookId,
                                                bookTitle: now.bookTitle,
                                                chapterId: now.chapterId,
                                                chapterTitle: now.chapterTitle,
                                                volumeId: now.volumeId,
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
                                    unawaited(now.stop());
                                  },
                                  icon: const Icon(Icons.stop_rounded),
                                  label: const Text('停止'),
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
