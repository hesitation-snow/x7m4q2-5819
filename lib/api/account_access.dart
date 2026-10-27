import 'lk_client.dart';

/// Public website contract; deliberately never changes the active app session.
class AccountAccessApi {
  AccountAccessApi({LKClient? client}) : _client = client ?? LKClient.shared;
  final LKClient _client;

  Future<void> sendCode(String email, {required bool register}) async {
    if (register) {
      final status = await _client
          .post('/api/bff/auth-email-status-v1', {'email': email.trim()});
      if ([true, 1, '1', 'true', 'yes'].contains(status['registered'])) {
        throw LKException(-1, '该邮箱已注册，请直接登录');
      }
    }
    await _client.post(
        register
            ? '/api/bff/auth-email-register-captcha-send-v1'
            : '/api/bff/auth-reset-password-captcha-send-v1',
        {'email': email.trim()});
  }

  Future<void> submit(
      {required bool register,
      required String email,
      required String code,
      required String nickname,
      required String password}) async {
    await _client.post(
      register
          ? '/api/bff/auth-email-register-v1'
          : '/api/bff/auth-reset-password-v1',
      register
          ? {
              'email': email.trim(),
              'captcha': code.trim(),
              'code': code.trim(),
              'nickname': nickname.trim(),
              'password': password
            }
          : {
              'email': email.trim(),
              'captcha': code.trim(),
              'new_password': password
            },
    );
  }
}
