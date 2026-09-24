import 'package:flutter/material.dart';

import '../services/app_motion.dart';
import '../services/app_update_service.dart';

const githubIssuesUrl = 'https://github.com/hesitation-snow/Yomiru/issues';
const telegramFeedbackUrl = 'https://t.me/FurippuFurappazu';

Future<void> showFeedbackOptions(BuildContext context) async {
  final destination = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: AppMotion.style(context),
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('反馈问题', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  '连接问题请先用浏览器确认轻之国度官网是否能正常访问。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.bug_report_outlined),
                        title: const Text('在 GitHub 提交 Issue'),
                        subtitle: const Text('前往公开仓库的问题页面'),
                        trailing:
                            const Icon(Icons.open_in_new_rounded, size: 18),
                        onTap: () =>
                            Navigator.pop(sheetContext, githubIssuesUrl),
                      ),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: const Icon(Icons.send_outlined),
                        title: const Text('加入 Telegram 群组'),
                        subtitle: const Text('在群组中反馈问题'),
                        trailing:
                            const Icon(Icons.open_in_new_rounded, size: 18),
                        onTap: () =>
                            Navigator.pop(sheetContext, telegramFeedbackUrl),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  if (destination != null && context.mounted) {
    await YomiruUpdateService.openExternal(context, destination);
  }
}
