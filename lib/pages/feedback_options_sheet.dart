import 'package:flutter/material.dart';

import '../services/app_motion.dart';
import '../services/app_update_service.dart';
import '../widgets/m3_controls.dart';
import '../widgets/m3_menu_sheet.dart';

const githubIssuesUrl = 'https://github.com/hesitation-snow/Yomiru/issues';
const telegramFeedbackUrl = 'https://t.me/FurippuFurappazu';

Future<void> showFeedbackOptions(BuildContext context) async {
  final destination = await showModalBottomSheet<String>(
    context: context,
    sheetAnimationStyle: AppMotion.style(context),
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (sheetContext) => M3MenuSheet(
      title: '反馈问题',
      icon: Icons.feedback_outlined,
      description: '连接问题请先用浏览器确认轻之国度官网是否能正常访问。',
      children: [
        M3OptionTile(
          icon: Icons.bug_report_outlined,
          title: '在 GitHub 提交 Issue',
          trailing: const Icon(Icons.open_in_new_rounded, size: 18),
          onTap: () => Navigator.pop(sheetContext, githubIssuesUrl),
        ),
        M3OptionTile(
          icon: Icons.send_outlined,
          title: '加入 Telegram 群组',
          trailing: const Icon(Icons.open_in_new_rounded, size: 18),
          onTap: () => Navigator.pop(sheetContext, telegramFeedbackUrl),
        ),
      ],
    ),
  );
  if (destination != null && context.mounted) {
    await YomiruUpdateService.openExternal(context, destination);
  }
}
