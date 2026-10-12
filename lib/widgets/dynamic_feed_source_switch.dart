import 'package:flutter/material.dart';
import '../api/store.dart';
import 'common.dart';

class DynamicFeedSourceSwitch extends StatelessWidget {
  const DynamicFeedSourceSwitch({super.key, this.secondary});
  final Widget? secondary;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DynamicFeedMode>(
        valueListenable: LKStore.dynamicFeedMode,
        builder: (context, mode, _) => SwitchListTile(
          secondary: secondary,
          title: const Text('使用旧版动态数据源'),
          subtitle: const Text('如果动态加载有问题时可以启用'),
          value: mode == DynamicFeedMode.legacyMixed,
          onChanged: (enabled) async {
            try {
              await LKStore.setDynamicFeedMode(enabled
                  ? DynamicFeedMode.legacyMixed
                  : DynamicFeedMode.anonymousFollow);
            } catch (_) {
              if (context.mounted) showFloatingPrompt(context, '无法保存设置，请重试');
            }
          },
        ),
      );
}
