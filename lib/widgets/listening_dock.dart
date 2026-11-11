import 'dart:async';

import 'package:flutter/material.dart';

import '../pages/reader_page.dart';
import '../services/listening_now.dart';
import 'm3_controls.dart';

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
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => const ListeningMenu(),
  );
}

class ListeningMenu extends StatelessWidget {
  const ListeningMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: ListeningNow.instance,
      builder: (context, _) {
        final now = ListeningNow.instance;
        final session = now.session;
        if (!now.active || session == null) {
          return const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('当前没有在听的内容'),
            ),
          );
        }
        final sentence = session.currentSegment?.text ?? '正在准备下一段';
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(now.bookTitle,
                    style: theme.textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (now.chapterTitle.isNotEmpty)
                  Text(now.chapterTitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                const SizedBox(height: 16),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant
                          .withValues(alpha: .35),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(sentence, style: theme.textTheme.bodyLarge),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  session.isLoading
                      ? '正在准备语音'
                      : session.isPaused
                          ? '已暂停'
                          : '正在播放 · 第 ${session.position + 1}/${session.segmentCount} 段',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton.filledTonal(
                      tooltip: '上一段',
                      onPressed: session.position > 0
                          ? () => unawaited(now.previous())
                          : null,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    IconButton.filled(
                      tooltip: session.isPaused ? '继续' : '暂停',
                      iconSize: 36,
                      onPressed: () => unawaited(now.toggle()),
                      icon: Icon(session.isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded),
                    ),
                    IconButton.filledTonal(
                      tooltip: '下一段',
                      onPressed: session.position + 1 < session.segmentCount
                          ? () => unawaited(now.next())
                          : null,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
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
                      child: FilledButton.tonalIcon(
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
          ),
        );
      },
    );
  }
}
