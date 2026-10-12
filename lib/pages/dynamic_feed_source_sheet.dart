import 'package:flutter/material.dart';
import '../api/store.dart';
import '../widgets/common.dart';

class DynamicFeedSourceSheet extends StatelessWidget {
  const DynamicFeedSourceSheet({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
            child: ValueListenableBuilder<DynamicFeedMode>(
          valueListenable: LKStore.dynamicFeedMode,
          builder: (context, selected, _) =>
              Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
                padding: EdgeInsets.all(16),
                child: Text('动态数据源',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 18))),
            const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('仅影响默认「动态」列表。列表异常时可切换；个人「关注」、发布和评论不受影响。')),
            for (final option in DynamicFeedMode.values)
              ListTile(
                title: Text(option.label),
                subtitle: Text(option.description),
                trailing:
                    option == selected ? const Icon(Icons.check_rounded) : null,
                onTap: () async {
                  try {
                    await LKStore.setDynamicFeedMode(option);
                    if (context.mounted) Navigator.pop(context);
                } catch (_) {
                  if (context.mounted) {
                    showFloatingPrompt(context, '无法保存设置，请重试');
                  }
                  }
                },
              ),
            const SizedBox(height: 12),
          ]),
        )),
      );
}
