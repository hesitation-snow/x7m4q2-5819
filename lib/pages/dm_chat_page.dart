import '../services/app_motion.dart';
import '../widgets/account_scope.dart';
import 'dart:async';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../widgets/common.dart';

/// 私信聊天
class DMChatPage extends StatelessWidget {
  const DMChatPage({super.key, required this.peerUid, required this.peerName});
  final int peerUid;
  final String peerName;
  @override
  Widget build(BuildContext context) => AccountScope(
        title: '私信',
        builder: (_) => _DMChatPageBody(peerUid: peerUid, peerName: peerName),
      );
}

class _DMChatPageBody extends StatefulWidget {
  final int peerUid;
  final String peerName;
  const _DMChatPageBody({required this.peerUid, required this.peerName});

  @override
  State<_DMChatPageBody> createState() => _DMChatPageState();
}

class _DMChatPageState extends State<_DMChatPageBody> {
  List<dynamic> _messages = [];
  final _input = TextEditingController();
  final _session = SessionStamp();
  bool _sending = false;
  int _loadSerial = 0;
  bool _loading = true;
  Object? _error;

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
    if (!_session.isCurrent || !mounted) return;
    final serial = ++_loadSerial;
    setState(() {
      _loading = _messages.isEmpty;
      _error = null;
    });
    try {
      final msgsFuture = LKApi.dmMessages(widget.peerUid);
      // Attach the error handler immediately, even if loading messages fails.
      unawaited(LKApi.dmMarkRead(widget.peerUid).catchError((_) {}));
      final msgs = await msgsFuture;
      if (!mounted || !_session.isCurrent || serial != _loadSerial) return;
      setState(() {
        _messages = msgs;
        _error = null;
      });
    } catch (e) {
      if (mounted && _session.isCurrent && serial == _loadSerial) {
        setState(() => _error = e);
        if (_messages.isNotEmpty) showLkError(context, e);
      }
    } finally {
      if (mounted && serial == _loadSerial) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final content = _input.text.trim();
    if (content.isEmpty || _sending || !_session.isCurrent) return;
    final draft = _input.text;
    setState(() => _sending = true);
    try {
      await LKApi.dmSend(widget.peerUid, content);
      if (!mounted || !_session.isCurrent) return;
      if (_input.text == draft) _input.clear();
      await _load();
    } catch (e) {
      if (mounted && _session.isCurrent) showLkError(context, e);
    } finally {
      if (mounted && _session.isCurrent) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUid = LKClient.shared.session.uid;
    return Scaffold(
      appBar:
          AppBar(title: Text(widget.peerName.isEmpty ? '私信' : widget.peerName)),
      body: Column(children: [
        Expanded(
          child: _loading && _messages.isEmpty
              ? const LkLoadingIndicator()
              : _error != null && _messages.isEmpty
                  ? Center(
                      child: TextButton(
                          onPressed: _load, child: const Text('加载失败，点击重试')))
                  : MotionRefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(12),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final m = _messages[i];
                          final mine = m.isMine(myUid);
                          return Align(
                            alignment: mine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              constraints: const BoxConstraints(maxWidth: 280),
                              decoration: BoxDecoration(
                                color: mine
                                    ? (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? const Color(0xFF35523F)
                                        : Colors.lightGreen.shade200)
                                    : (Theme.of(context).brightness ==
                                            Brightness.dark
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
              FilledButton(
                  onPressed: _sending ? null : _send,
                  child: Text(_sending ? '发送中…' : '发送')),
            ]),
          ),
        ),
      ]),
    );
  }
}
