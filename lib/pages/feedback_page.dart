import 'package:flutter/material.dart';

import '../services/anonymous_telemetry.dart';
import '../widgets/common.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  static const _maxLength = 1600;
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _sending = true);
    try {
      await AnonymousTelemetry.submitFeedback(_controller.text);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showLkError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('反馈问题')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text(
              '如果遇到连接失败或内容无法加载，请先用浏览器访问轻之国度官网：浏览器也无法访问时，可能是当前网络或官网服务器异常；官网可以正常访问但 Yomiru 仍然异常时，再提交反馈。\n\n请描述遇到的问题或希望改进的地方，请勿填写密码、Token 或其他敏感信息。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_sending,
              minLines: 7,
              maxLines: 12,
              maxLength: _maxLength,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: '例如：在哪个页面遇到了什么问题？',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _sending ? null : _submit,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(_sending ? '发送中…' : '发送反馈'),
            ),
          ],
        ),
      ),
    );
  }
}
