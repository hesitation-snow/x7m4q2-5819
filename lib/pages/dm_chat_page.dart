import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/store.dart';
import '../widgets/common.dart';

/// 私信聊天
class DMChatPage extends StatefulWidget {
  final int peerUid;
  final String peerName;
  const DMChatPage({super.key, required this.peerUid, required this.peerName});

  @override
  State<DMChatPage> createState() => _DMChatPageState();
}

class _DMChatPageState extends State<DMChatPage> {
  List<dynamic> _messages = [];
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final msgs = await LKApi.dmMessages(widget.peerUid);
      if (!mounted) return;
      setState(() => _messages = msgs);
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (content.isEmpty) return;
    try {
      await LKApi.dmSend(widget.peerUid, content);
      _input.clear();
      _load();
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = LKClient.shared.session.uid;
    return Scaffold(
      appBar: AppBar(title: Text(widget.peerName.isEmpty ? '私信' : widget.peerName)),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _messages.length,
            itemBuilder: (_, i) {
              final m = _messages[i];
              final mine = m.isMine(myUid);
              return Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  constraints: const BoxConstraints(maxWidth: 280),
                  decoration: BoxDecoration(
                    color: mine
                        ? (Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF35523F)
                            : Colors.lightGreen.shade200)
                        : (Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF2A2C33)
                            : Colors.white),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(m.content),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                      hintText: '发消息…',
                      isDense: true,
                      border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _send, child: const Text('发送')),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// 福利中心
class WelfarePage extends StatefulWidget {
  const WelfarePage({super.key});

  @override
  State<WelfarePage> createState() => _WelfarePageState();
}

class _WelfarePageState extends State<WelfarePage> {
  Map<String, dynamic>? _home;
  Map<String, dynamic>? _sign;
  Map<String, dynamic>? _tasks;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final home = await LKApi.welfareHome();
      if (!mounted) return;
      setState(() {
        _home = home;
        _error = null;
      });
      if (LKClient.shared.session.isLoggedIn) {
        final sign = await LKApi.signDetail();
        final tasks = await LKApi.taskList();
        if (!mounted) return;
        setState(() {
          _sign = sign;
          _tasks = tasks;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() fn, String ok) async {
    try {
      await fn();
      if (mounted) showLkError(context, ok);
      _load();
    } catch (e) {
      if (mounted) showLkError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = (_home?['wallet'] as Map<String, dynamic>?) ?? const {};
    final tasks = ((_tasks?['list'] as List?) ??
            (_tasks?['tasks'] as Map<String, dynamic>?)?['list'] as List?) ??
        const [];
    return Scaffold(
      appBar: AppBar(title: const Text('福利中心')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16).copyWith(
              bottom: 16 + MediaQuery.of(context).padding.bottom),
          children: [
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.grey)),
            Text('💰 金币: ${wallet['coin'] ?? wallet['coins'] ?? 0}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            if (_sign != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.event_available),
                  title: Text(
                      '签到: 已签 ${_sign!['signed_days'] ?? 0} 天${(_sign!['signed_today'] ?? 0) == 1 ? '(今日已签)' : ''}'),
                  trailing: FilledButton(
                    onPressed: () => _run(LKApi.claimSign, '签到成功 🎉'),
                    child: const Text('立即签到'),
                  ),
                ),
              ),
            if (tasks.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('🎯 任务(点击领取)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              ...tasks.take(8).map((t) => Card(
                    child: ListTile(
                      dense: true,
                      title: Text('${t['title'] ?? ''}'),
                      trailing: TextButton(
                        onPressed: () => _run(
                            () => LKApi.claimTask(
                                (t['task_id'] as num?)?.toInt() ?? 0),
                            '领取成功'),
                        child: const Text('领取'),
                      ),
                    ),
                  )),
            ],
            const SizedBox(height: 8),
            const Text('😴 睡眠陪伴', style: TextStyle(fontWeight: FontWeight.bold)),
            Row(children: [
              Expanded(
                  child: OutlinedButton(
                      onPressed: () => _run(LKApi.startSleep, '已开始'),
                      child: const Text('开始'))),
              const SizedBox(width: 8),
              Expanded(
                  child: OutlinedButton(
                      onPressed: () => _run(LKApi.finishSleep, '已结束'),
                      child: const Text('结束'))),
              const SizedBox(width: 8),
              Expanded(
                  child: OutlinedButton(
                      onPressed: () => _run(LKApi.claimSleep, '领取成功'),
                      child: const Text('领奖励'))),
            ]),
            const SizedBox(height: 8),
            const Text('🎁 宝藏箱', style: TextStyle(fontWeight: FontWeight.bold)),
            FilledButton(
              onPressed: () => _run(LKApi.claimTreasure, '开启成功 🎉'),
              child: const Text('开启宝箱'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final mode = LKStore.themeMode.value;
    final modeLabel = switch (mode) {
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
      ThemeMode.system => '跟随系统',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('设置与资料')),
      body: ListView(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
        children: [
        ListTile(
          leading: const Icon(Icons.dark_mode_outlined),
          title: const Text('深色模式'),
          subtitle: Text('当前: $modeLabel'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _darkMode(context),
        ),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('修改昵称 / 签名'),
          onTap: () => _editProfile(context),
        ),
        ListTile(
          leading: const Icon(Icons.password_outlined),
          title: const Text('修改密码'),
          onTap: () => _changePassword(context),
        ),
        ListTile(
          leading: const Icon(Icons.military_tech_outlined),
          title: const Text('我的勋章(可装备)'),
          onTap: () => _medals(context),
        ),
        ListTile(
          leading: const Icon(Icons.redeem_outlined),
          title: const Text('我的邀请码'),
          onTap: () async {
            try {
              final d = await LKApi.inviteCode();
              if (!context.mounted) return;
              showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('我的邀请码'),
                  content: Text('${d['code'] ?? d['invite_code'] ?? '暂无'}'),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
                ),
              );
            } catch (e) {
              if (context.mounted) showLkError(context, e);
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('关于'),
          onTap: () async {
            try {
              final d = await LKApi.about();
              if (!context.mounted) return;
              showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('关于'),
                  content: Text('轻之国度 https://www.lightnovel.fun\n版本: ${d['version'] ?? ''}'),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
                ),
              );
            } catch (e) {
              if (context.mounted) showLkError(context, e);
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.system_update_outlined),
          title: const Text('检查更新'),
          onTap: () async {
            try {
              final d = await LKApi.updateCheck();
              if (!context.mounted) return;
              showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('检查更新'),
                  content: Text('当前: ${d['current_version'] ?? ''}\n最新: ${d['latest_version'] ?? ''}'),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
                ),
              );
            } catch (e) {
              if (context.mounted) showLkError(context, e);
            }
          },
        ),
      ]),
    );
  }

  void _darkMode(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text('深色模式',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          for (final (label, value) in [
            ('跟随系统', ThemeMode.system),
            ('浅色', ThemeMode.light),
            ('深色', ThemeMode.dark),
          ])
            ListTile(
              title: Text(label),
              trailing: LKStore.themeMode.value == value
                  ? Icon(Icons.check_circle_rounded,
                      color: Theme.of(context).colorScheme.primary)
                  : const Icon(Icons.circle_outlined,
                      color: Colors.grey),
              onTap: () {
                LKStore.setThemeMode(value);
                Navigator.pop(sheetCtx);
              },
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _editProfile(BuildContext context) {
    final nick = TextEditingController(text: LKClient.shared.session.nickname);
    final sign = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('修改资料'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nick, decoration: const InputDecoration(labelText: '昵称')),
          TextField(controller: sign, decoration: const InputDecoration(labelText: '签名')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await LKApi.updateProfile(nick.text.trim(), sign.text.trim());
                LKClient.shared.session.nickname = nick.text.trim();
                if (context.mounted) showLkError(context, '已保存');
              } catch (e) {
                if (context.mounted) showLkError(context, e);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _changePassword(BuildContext context) {
    final oldP = TextEditingController();
    final newP = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: oldP, obscureText: true, decoration: const InputDecoration(labelText: '旧密码')),
          TextField(controller: newP, obscureText: true, decoration: const InputDecoration(labelText: '新密码')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await LKApi.changePassword(oldP.text, newP.text);
                if (context.mounted) showLkError(context, '密码已修改');
              } catch (e) {
                if (context.mounted) showLkError(context, e);
              }
            },
            child: const Text('修改'),
          ),
        ],
      ),
    );
  }

  void _medals(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => FutureBuilder(
        future: LKApi.client.post('/api/bff/my-medals-v1', LKApi.client.authed()),
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
          }
          if (snap.hasError) return Text('${snap.error}');
          final list = ((snap.data?['list'] as List?) ?? const []);
          if (list.isEmpty) return const Center(child: Text('暂无勋章'));
          return ListView(
            children: list.map((m) {
              final name = m['name'] ?? '';
              final equipped = (m['equipped'] as num?)?.toInt() == 1;
              final id = (m['medal_id'] as num?)?.toInt() ?? (m['id'] as num?)?.toInt() ?? 0;
              return ListTile(
                title: Text('$name${equipped ? '(已装备)' : ''}'),
                onTap: () async {
                  await LKApi.toggleMedal(id, !equipped);
                  if (context.mounted) showLkError(context, '已切换');
                },
              );
            }).toList(),
          );
        },
      ),
    );
  }
}
