import 'dart:async';
import 'package:flutter/material.dart';
import '../api/account_access.dart';
import '../api/lk_client.dart';
import '../services/app_motion.dart';
import '../services/app_update_service.dart';

class AccountAccessPage extends StatefulWidget {
  const AccountAccessPage({super.key, required this.register, this.api});
  final bool register;
  final AccountAccessApi? api;
  @override
  State<AccountAccessPage> createState() => _AccountAccessPageState();
}

class _AccountAccessPageState extends State<AccountAccessPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _nickname = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  late final _api = widget.api ?? AccountAccessApi();
  Timer? _timer;
  int _cooldown = 0;
  bool _busy = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _message;

  String? _emailError(String? value) =>
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '')
          ? null
          : '请输入正确的邮箱';

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_email, _code, _nickname, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(bool send) async {
    if (_busy || (send && _cooldown > 0)) return;
    if (send
        ? _emailError(_email.text) != null
        : !_form.currentState!.validate()) {
      if (send) setState(() => _message = '请输入正确的邮箱');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (send) {
        await _api.sendCode(_email.text, register: widget.register);
        if (!mounted) return;
        setState(() {
          _cooldown = 60;
          _message = '验证码已发送，请检查邮箱及垃圾邮件';
        });
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }
          setState(() => _cooldown--);
          if (_cooldown == 0) timer.cancel();
        });
      } else {
        await _api.submit(
            register: widget.register,
            email: _email.text,
            code: _code.text,
            nickname: _nickname.text,
            password: _password.text);
        if (!mounted) return;
        Navigator.pop(
            context, widget.register ? '注册成功，请使用新账号登录' : '密码已重置，请使用新密码登录');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = error is LKException
            ? (error.message.isEmpty
                ? '操作失败（${error.code}），请稍后重试'
                : error.message)
            : '请求失败，请检查网络后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.register ? '注册账号' : '重置密码')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Center(
                        child: Container(
                          width: 64,
                          height: 64,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(
                            widget.register
                                ? Icons.person_add_outlined
                                : Icons.lock_reset_outlined,
                            size: 32,
                            color: scheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.register ? '注册账号' : '重置密码',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.register
                            ? '使用邮箱注册轻之国度账号'
                            : '通过绑定邮箱重置密码',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _email,
                        enabled: !_busy && _cooldown == 0,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: '邮箱',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        validator: _emailError,
                      ),
                      const SizedBox(height: 16),
                      LayoutBuilder(builder: (context, constraints) {
                        final codeField = TextFormField(
                          controller: _code,
                          enabled: !_busy,
                          keyboardType: TextInputType.number,
                          autofillHints: const [AutofillHints.oneTimeCode],
                          decoration: const InputDecoration(
                            labelText: '邮箱验证码',
                            prefixIcon: Icon(Icons.pin_outlined),
                          ),
                          validator: (v) =>
                              v == null || v.trim().isEmpty ? '请输入验证码' : null,
                        );
                        final sendButton = OutlinedButton(
                          onPressed:
                              _busy || _cooldown > 0 ? null : () => _run(true),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 56),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          child: Text(
                              _cooldown > 0 ? '重新发送（$_cooldown 秒）' : '发送验证码'),
                        );
                        if (constraints.maxWidth <
                            280 * MediaQuery.textScalerOf(context).scale(1)) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              codeField,
                              const SizedBox(height: 12),
                              sendButton
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: codeField),
                            const SizedBox(width: 12),
                            sendButton
                          ],
                        );
                      }),
                      const SizedBox(height: 16),
                      if (widget.register) ...[
                        TextFormField(
                          controller: _nickname,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: '昵称',
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                          validator: (v) =>
                              v == null || v.trim().isEmpty ? '请输入昵称' : null,
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _obscurePassword,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: InputDecoration(
                          labelText: widget.register ? '密码' : '新密码',
                          prefixIcon: const Icon(Icons.lock_outline),
                          helperText: '8–16 位，大小写字母、数字、特殊符号至少三类',
                          helperMaxLines: 2,
                          suffixIcon: IconButton(
                            tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                            icon: Icon(_obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (v) {
                          final p = v ?? '';
                          final groups = [
                            RegExp('[a-z]'),
                            RegExp('[A-Z]'),
                            RegExp('[0-9]'),
                            RegExp(
                                r'''[~!@#$%\^&*()_+`\-={}\[\];':",./<>?\\|]''')
                          ];
                          final allowed = RegExp(
                              r'''^[0-9a-zA-Z~!@#$%\^&*()_+`\-={}\[\];':",./<>?\\|]{8,16}$''');
                          return allowed.hasMatch(p) &&
                                  groups.where((r) => r.hasMatch(p)).length >= 3
                              ? null
                              : '密码格式不符合要求';
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _confirm,
                        enabled: !_busy,
                        obscureText: _obscureConfirm,
                        decoration: InputDecoration(
                          labelText: '确认密码',
                          prefixIcon: const Icon(Icons.lock_reset_outlined),
                          suffixIcon: IconButton(
                            tooltip: _obscureConfirm ? '显示确认密码' : '隐藏确认密码',
                            icon: Icon(_obscureConfirm
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                            onPressed: () => setState(
                                () => _obscureConfirm = !_obscureConfirm),
                          ),
                        ),
                        validator: (v) =>
                            v != _password.text || (v ?? '').isEmpty
                                ? '两次输入的密码不一致'
                                : null,
                      ),
                      const SizedBox(height: 20),
                      if (_message != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: scheme.errorContainer.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 20, color: scheme.onErrorContainer),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _message!,
                                  semanticsLabel: _message,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: scheme.onErrorContainer),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      FilledButton(
                        onPressed: _busy ? null : () => _run(false),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: MotionProgressIndicator(strokeWidth: 2))
                            : Text(widget.register ? '注册账号' : '重置密码'),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.help_outline_rounded,
                                    size: 18, color: scheme.onSurfaceVariant),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '遇到网页验证或需要直接访问官网？',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '官网：首页“登入/注册” → “邮箱注册”或“忘记密码”。完成后返回登录。',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.85),
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => YomiruUpdateService.openExternal(
                                        context, 'https://www.lightnovel.fun/'),
                                icon: const Icon(Icons.open_in_browser_rounded,
                                    size: 16),
                                label: const Text('打开官方网站'),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
