import '../services/app_motion.dart';
import '../services/app_theme.dart';
import '../widgets/account_scope.dart';
import 'dart:async';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../widgets/common.dart';
import '../widgets/content_state_view.dart';

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
  final _focus = FocusNode();
  bool _hasFocus = false;
  double _lastViewInset = 0;
  final _session = SessionStamp();
  bool _sending = false;
  int _loadSerial = 0;
  bool _loading = true;
  bool _loadingMore = false;
  int _page = 1;
  bool _hasMore = true;
  Object? _error;
  Object? _loadMoreError;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    _load();
  }

  void _onFocusChanged() {
    if (mounted && _hasFocus != _focus.hasFocus) {
      setState(() => _hasFocus = _focus.hasFocus);
    }
  }

  void _dismissInput() {
    if (_focus.hasFocus) {
      _focus.unfocus();
    }
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_session.isCurrent || !mounted) return;
    final serial = ++_loadSerial;
    setState(() {
      _loading = _messages.isEmpty;
      _loadingMore = false;
      _error = null;
      _loadMoreError = null;
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
    final serial = _loadSerial;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    final nextPage = _page + 1;
    try {
      final olderMsgs =
          await LKApi.dmMessages(widget.peerUid, page: nextPage, pageSize: 30);
      if (!mounted || !_session.isCurrent || serial != _loadSerial) return;
      setState(() {
        _page = nextPage;
        _hasMore = olderMsgs.length >= 30;
        _loadMoreError = null;
        final existingIds = _messages.map((m) => m.id).toSet();
        final newOlder =
            olderMsgs.where((m) => !existingIds.contains(m.id)).toList();
        _messages = [...newOlder, ..._messages];
      });
    } catch (e) {
      if (mounted && _session.isCurrent && serial == _loadSerial) {
        setState(() => _loadMoreError = e);
      }
    } finally {
      if (mounted && _session.isCurrent && serial == _loadSerial) {
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
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (_lastViewInset > 0 && inset == 0 && _focus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _focus.hasFocus &&
            MediaQuery.viewInsetsOf(context).bottom == 0) {
          _focus.unfocus();
        }
      });
    }
    _lastViewInset = inset;
    final inputActive = _hasFocus || inset > 0;
    return PopScope(
      canPop: !inputActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _dismissInput();
        }
      },
      child: Scaffold(
        backgroundColor: scheme.surfaceContainerLowest,
        appBar:
            AppBar(title: Text(widget.peerName.isEmpty ? '私信' : widget.peerName)),
        body: Column(children: [
          Expanded(
            child: Stack(
              children: [
                _loading && _messages.isEmpty
                    ? const LkLoadingIndicator()
                    : _error != null && _messages.isEmpty
                        ? ContentStateView(
                            message: _error.toString(),
                            onRetry: _load,
                          )
                        : NotificationListener<ScrollNotification>(
                            onNotification: (n) {
                              if (n.metrics.extentBefore < 80 &&
                                  _hasMore &&
                                  !_loadingMore &&
                                  !_loading &&
                                  _loadMoreError == null) {
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
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 8),
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
                                                    style: TextStyle(
                                                        fontSize: 12)),
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
                                      margin: const EdgeInsets.symmetric(
                                          vertical: 4),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                      constraints: BoxConstraints(
                                        maxWidth:
                                            MediaQuery.sizeOf(context).width *
                                                .82,
                                      ),
                                      decoration: BoxDecoration(
                                        color: mine
                                            ? scheme.primaryContainer
                                            : scheme.surfaceContainerHigh,
                                        borderRadius: BorderRadius.only(
                                          topLeft: const Radius.circular(20),
                                          topRight: const Radius.circular(20),
                                          bottomLeft:
                                              Radius.circular(mine ? 20 : 4),
                                          bottomRight:
                                              Radius.circular(mine ? 4 : 20),
                                        ),
                                      ),
                                      child: SelectableText(
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
                if (inputActive)
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('dm-input-dismiss-barrier'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _dismissInput,
                      onVerticalDragStart: (_) => _dismissInput(),
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              border: Border(
                top: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: .25),
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  8,
                  12,
                  bottomBarSafePadding(context, base: 8),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: scheme.surfaceContainerHigh,
                      hintText: '发消息…',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                          color: scheme.primary,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const StadiumBorder(),
                    minimumSize: const Size(64, 42),
                  ),
                  onPressed: _sending ? null : _send,
                  child: Text(_sending ? '发送中…' : '发送'),
                ),
              ]),
            ),
          ),
          ),
        ]),
      ),
    );
  }
}
