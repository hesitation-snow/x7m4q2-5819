import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Sends feedback only after the reader explicitly taps Send.
class FeedbackService {
  FeedbackService._();

  static const _endpoint = 'https://telemetry.yutro.uk/v1/install';

  static Future<void> submit(String content) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const FeedbackException('当前平台暂不支持反馈');
    }

    final message = content
        .replaceAll(
            RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'), '')
        .trim();
    if (message.isEmpty) {
      throw const FeedbackException('请先填写反馈内容');
    }
    if (message.length > 1600) {
      throw const FeedbackException('反馈内容不能超过 1600 字');
    }

    try {
      final response = await http
          .post(
            Uri.parse(_endpoint),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'type': 'feedback', 'message': message}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 429) {
        throw const FeedbackException('提交的次数太多了，请稍后再试吧。');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const FeedbackException('反馈发送失败，请稍后重试');
      }
    } on FeedbackException {
      rethrow;
    } catch (_) {
      throw const FeedbackException('反馈发送失败，请检查网络后重试');
    }
  }
}

class FeedbackException implements Exception {
  final String message;

  const FeedbackException(this.message);

  @override
  String toString() => message;
}
