import 'package:flutter_test/flutter_test.dart';
import 'package:yomiru/api/lk_client.dart';

void main() {
  test('parses the current error-code list response', () {
    final result = LKClient.parseErrorCodeCatalog({
      'version': 1,
      'list': [
        {'code': 2, 'message': '密码错误，请重新输入'},
        {'code': '1001', 'message': '用户不存在'},
        {'code': 3, 'message': ''},
      ],
    });

    expect(result[2], '密码错误，请重新输入');
    expect(result[1001], '用户不存在');
    expect(result.containsKey(3), isFalse);
  });

  test('keeps compatibility with a code-to-message map', () {
    final result = LKClient.parseErrorCodeCatalog({
      '8': '访问被拒绝，请重新登录',
      '21': {'message': '数据读取失败，请稍后重试'},
      'ignored': 'not a code',
    });

    expect(result[8], '访问被拒绝，请重新登录');
    expect(result[21], '数据读取失败，请稍后重试');
  });
}
