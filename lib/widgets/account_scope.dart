import 'package:flutter/material.dart';
import '../api/lk_client.dart';

/// Recreates private page state whenever the active session changes.
class AccountScope extends StatelessWidget {
  const AccountScope({super.key, required this.title, required this.builder});
  final String title;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: LKClient.sessionRev,
        builder: (context, revision, _) {
          final session = LKClient.shared.session;
          if (!session.isLoggedIn) {
            return Scaffold(
              appBar: AppBar(title: Text(title)),
              body: Center(child: Text('登录后才能查看$title')),
            );
          }
          return KeyedSubtree(
            key: ValueKey((session.uid, revision)),
            child: Builder(builder: builder),
          );
        },
      );
}

/// Capture values, not the mutable session object, before awaiting a request.
class SessionStamp {
  SessionStamp()
      : uid = LKClient.shared.session.uid,
        _key = LKClient.shared.session.securityKey,
        _revision = LKClient.sessionRev.value;
  final int uid;
  final String _key;
  final int _revision;
  bool get isCurrent =>
      uid == LKClient.shared.session.uid &&
      _key == LKClient.shared.session.securityKey &&
      _revision == LKClient.sessionRev.value;
}
