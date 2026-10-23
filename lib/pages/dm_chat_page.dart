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
  bool _loadingMore = false;
  int _page = 1;
  bool _hasMore = true;
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
      final msgsFuture =
          LKApi.dmMessages(widget.peerUid, page: 1, pageSize: 30);
      // Attach the error handler immediately, even if loading messages fails.
      unawaited(LKApi.dmMarkRead(widget.peerUid).catchError((_) {}));
      final msgs = await msgsFuture;
      if (!mounted || !_session.isCurrent || serial != _loadSerial) return;
      setState(() {
        _messages = msgs;
        _page = 1;
        _hasMore = msgs.length >= 30;
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

  Future<void> _loadMore() async {
    if (_loading ||
        _loadingMore ||
        !_hasMore ||
        !_session.isCurrent ||
        !mounted) {
      return;
    }
    setState(() => _loadingMore = true);
    final nextPage = _page + 1;
    try {
      final olderMsgs =
          await LKApi.dmMessages(widget.peerUid, page: nextPage, pageSize: 30);
      if (!mounted || !_session.isCurrent) return;
      setState(() {
        _page = nextPage;
        _hasMore = olderMsgs.length >= 30;
        final existingIds = _messages.map((m) => m.id).toSet();
        final newOlder =
            olderMsgs.where((m) => !existingIds.contains(m.id)).toList();
        _messages = [...newOlder, ..._messages];
      });
    } catch (_) {
      // 容错处理
    } finally {
      if (mounted && _session.isCurrent) {
        setState(() => _loadingMore = false);
      }
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
    final scheme = Theme.of(context).colorScheme;
    final myUid = LKClient.shared.session.uid;
    final showTopLoader = _hasMore || _loadingMore;
    final totalCount = _messages.length + (showTopLoader ? 1 : 0);
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
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
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.extentBefore < 80 &&
                            _hasMore &&
                            !_loadingMore &&
                            !_loading) {
                          unawaited(_loadMore());
                        }
                        return false;
                      },
                      child: MotionRefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(12),
                          itemCount: totalCount,
                          itemBuilder: (_, i) {
                            if (showTopLoader && i == 0) {
                              return Center(
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: _loadingMore
                                      ? const SizedBox.square(
                                          dimension: 20,
                                          child: MotionProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : TextButton.icon(
                                          onPressed: _loadMore,
                                          icon: const Icon(
                                              Icons.history_rounded,
                                              size: 16),
                                          label: const Text('加载更早记录',
                                              style: TextStyle(fontSize: 12)),
                                        ),
                                ),
                              );
                            }
                            final actualIndex = showTopLoader ? i - 1 : i;
                            final m = _messages[actualIndex];
                            final mine = m.isMine(myUid);
                            return Align(
                              alignment: mine
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.sizeOf(context).width * .82,
                                ),
                                decoration: BoxDecoration(
                                  color: mine
                                      ? scheme.primaryContainer
                                      : scheme.surfaceContainerHigh,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(20),
                                    topRight: const Radius.circular(20),
                                    bottomLeft: Radius.circular(mine ? 20 : 4),
                                    bottomRight: Radius.circular(mine ? 4 : 20),
                                  ),
                                ),
                                child: Text(
                                  m.content,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyLarge
                                      ?.copyWith(
                                        color: mine
                                            ? scheme.onPrimaryContainer
                                            : scheme.onSurface,
                                      ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
        ),
        Material(
          color: scheme.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        hintText: '发消息…',
                        isDense: true,
                        border: const OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                    onPressed: _sending ? null : _send,
                    child: Text(_sending ? '发送中…' : '发送')),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
