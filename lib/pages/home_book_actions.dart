import 'dart:async';

import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/store.dart';
import '../services/app_motion.dart';
import '../widgets/common.dart';
import '../widgets/m3_controls.dart';
import '../widgets/m3_menu_sheet.dart';
import 'comments_page.dart';

/// The menu is used only by the home feed, not by shelf cards.
Future<void> showHomeBookActions(BuildContext context, LKBook book) async {
  final openComments = await showModalBottomSheet<bool>(
    context: context,
    sheetAnimationStyle: AppMotion.style(context),
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (_) => _HomeBookActions(book: book),
  );
  if (openComments == true && context.mounted) {
    await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              CommentsPage(bookId: book.bookId, bookTitle: book.title),
        ));
  }
}

// A book can be visible in multiple feeds. Keep its mutation single-flight,
// even if a sheet is dismissed and reopened while the request is in flight.
final Map<int, Completer<void>> _addingBooks = <int, Completer<void>>{};
Future<void> _saveLocal(LKBook book) => LKStore.setLocalShelf(book, true);

class _HomeBookActions extends StatefulWidget {
  const _HomeBookActions({required this.book});
  final LKBook book;

  @override
  State<_HomeBookActions> createState() => _HomeBookActionsState();
}

class _HomeBookActionsState extends State<_HomeBookActions> {
  bool _loading = true;
  bool _inShelf = false;
  Object? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    LKClient.sessionRev.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    final revision = LKClient.sessionRev.value;
    if (mounted) {
      setState(() {
        _loading = true;
        _inShelf = false;
        _error = null;
      });
    }
    try {
      final pending = _addingBooks[widget.book.bookId];
      if (pending != null) await pending.future;
      if (!mounted ||
          request != _request ||
          revision != LKClient.sessionRev.value) {
        return;
      }
      final bool inShelf;
      if (LKClient.shared.session.isLoggedIn) {
        final state = await LKApi.client.post(
          '/api/new-content-read/get-book-library-state',
          LKApi.client.authed({'book_id': widget.book.bookId}),
        );
        final value = state['in_shelf'];
        inShelf =
            value == true || value == 1 || value == '1' || value == 'true';
      } else {
        inShelf = await LKStore.isLocalShelf(widget.book.bookId);
      }
      if (!mounted ||
          request != _request ||
          revision != LKClient.sessionRev.value) {
        return;
      }
      setState(() {
        _inShelf = inShelf;
        _loading = false;
      });
    } catch (e) {
      if (!mounted ||
          request != _request ||
          revision != LKClient.sessionRev.value) {
        return;
      }
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    final id = widget.book.bookId;
    if (_loading || _inShelf || id <= 0 || _addingBooks.containsKey(id)) return;
    final pending = Completer<void>();
    _addingBooks[id] = pending;
    final revision = LKClient.sessionRev.value;
    final loggedIn = LKClient.shared.session.isLoggedIn;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (loggedIn) await LKApi.toggleShelf(id, true);
      await _saveLocal(widget.book);
      if (!mounted || revision != LKClient.sessionRev.value) return;
      setState(() {
        _inShelf = true;
        _loading = false;
      });
      showFloatingPrompt(context, '已加入书架');
    } catch (e) {
      if (!mounted || revision != LKClient.sessionRev.value) return;
      // A cloud mutation may have succeeded before a local write failed; reload
      // the authoritative state on retry instead of issuing a second add.
      setState(() {
        _error = e;
        _loading = false;
      });
    } finally {
      _addingBooks.remove(id);
      pending.complete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _loading
        ? '加载中'
        : _error != null
            ? '加载失败，点击重试'
            : _inShelf
                ? '已加入书架'
                : '加入书架';
    return M3MenuSheet(
      title: widget.book.title,
      icon: Icons.menu_book_rounded,
      children: [
        M3OptionTile(
          title: label,
          icon: _inShelf
              ? Icons.bookmark_added_rounded
              : Icons.bookmark_add_outlined,
          onTap: _loading || _inShelf
              ? null
              : _error != null
                  ? _load
                  : _add,
          trailing: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : null,
        ),
        M3OptionTile(
          title: '查看书评',
          icon: Icons.chat_bubble_outline_rounded,
          onTap: () => Navigator.pop(context, true),
        ),
      ],
    );
  }
}
