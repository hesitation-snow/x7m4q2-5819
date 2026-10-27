import '../services/app_motion.dart';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/store.dart';
import '../widgets/common.dart';
import 'account_access_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    final u = _user.text.trim();
    final p = _pwd.text;
    if (u.isEmpty || p.isEmpty) return;
    setState(() => _busy = true);
    try {
      await LKApi.login(u, p);
      await LKStore.save();
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showLkError(context, _loginError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    if (_busy) return;
    final session = LKClient.shared.session;
    final uid = session.uid;
    final key = session.securityKey;
    setState(() => _busy = true);
    try {
      final allDevices = await showLogoutScopeDialog(context);
      if (!mounted ||
          allDevices == null ||
          session.uid != uid ||
          session.securityKey != key) {
        return;
      }
      await LKApi.logout(allDevices: allDevices);
      if (!mounted || session.isLoggedIn) return;
      showLkError(context, allDevices ? '已退出所有设备' : '已退出本机');
    } catch (_) {
      if (mounted) showLkError(context, '退出失败，请重试或选择“仅退出本机”');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _loginError(Object error) {
    if (error is LKException) {
      return switch (error.code) {
        2 => '密码错误，请检查后重试',
        1001 => '账号不存在，请确认登录邮箱是否正确',
        _ => error.message.isEmpty ? '登录失败，请稍后重试' : error.message,
      };
    }
    return '登录失败，请检查网络后重试';
  }

  @override
  Widget build(BuildContext context) {
    final s = LKClient.shared.session;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('登录轻之国度')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(Icons.menu_book_outlined,
                          size: 32, color: scheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _user,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                          labelText: '邮箱',
                          prefixIcon: Icon(Icons.person_outline)),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _pwd,
                      obscureText: true,
                      decoration: const InputDecoration(
                          labelText: '密码',
                          prefixIcon: Icon(Icons.lock_outline)),
                      onSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _login,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: MotionProgressIndicator(strokeWidth: 2))
                          : Text(s.isLoggedIn ? '重新登录' : '登录'),
                    ),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        for (final register in [true, false])
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () async {
                                    final message =
                                        await Navigator.push<String>(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => AccountAccessPage(
                                              register: register)),
                                    );
                                    if (message != null && context.mounted) {
                                      showLkError(context, message);
                                    }
                                  },
                            child: Text(register ? '注册账号' : '重置密码'),
                          ),
                      ],
                    ),
                    if (s.isLoggedIn) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _busy ? null : _logout,
                        style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.error),
                        child: Text('退出登录(当前: ${s.nickname})'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
