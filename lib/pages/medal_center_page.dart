import 'dart:async';

import '../services/app_motion.dart';
import '../widgets/account_scope.dart';
import '../widgets/scrollable_status.dart';
import 'package:flutter/material.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/models.dart';
import '../api/store.dart';
import '../services/avatar_cache.dart';
import '../widgets/common.dart';
import '../widgets/content_state_view.dart';
import 'medal_shop_page.dart';

class MedalCenterPage extends StatelessWidget {
  const MedalCenterPage({super.key});

  @override
  Widget build(BuildContext context) => AccountScope(
        title: '勋章中心',
        builder: (_) => const _MedalCenterPageBody(),
      );
}

class _MedalCenterPageBody extends StatefulWidget {
  const _MedalCenterPageBody();

  @override
  State<_MedalCenterPageBody> createState() => _MedalCenterPageState();
}

class _MedalCenterPageState extends State<_MedalCenterPageBody> {
  static final Map<int, _MedalCenterMemoryEntry> _memoryCache = {};

  final _session = SessionStamp();
  int _loadSerial = 0;
  List<LKMedal> _medals = const [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  final Set<int> _busy = <int>{};

  @override
  void initState() {
    super.initState();
    final cached = _readMemorySnapshot();
    if (cached != null) {
      _medals = cached;
      _loading = false;
    }
    _load();
  }

  List<LKMedal>? _readMemorySnapshot() {
    final session = LKClient.shared.session;
    final entry = _memoryCache[_session.uid];
    if (entry == null || !entry.matchesCurrent(session)) return null;
    return entry.medals;
  }

  void _writeMemorySnapshot(List<LKMedal> medals) {
    final session = LKClient.shared.session;
    if (!session.isLoggedIn || _session.uid <= 0) return;
    _memoryCache[_session.uid] = _MedalCenterMemoryEntry(
      client: LKApi.client,
      sessionRev: LKClient.sessionRev.value,
      securityKey: session.securityKey,
      cacheEpoch: LKStore.contentCacheEpoch,
      medals: List<LKMedal>.unmodifiable(medals),
    );
  }

  String _imageUrl(String value) {
    final image = value.trim();
    if (image.startsWith('http')) return image;
    if (image.startsWith('/')) return 'https://api.lightnovel.fun$image';
    return image;
  }

  Future<void> _load() async {
    final session = LKClient.shared.session;
    final serial = ++_loadSerial;
    final uid = _session.uid;
    bool current() => mounted && _session.isCurrent && serial == _loadSerial;
    if (!session.isLoggedIn) {
      if (mounted && _session.isCurrent) {
        setState(() {
          _medals = const [];
          _loading = false;
          _refreshing = false;
          _error = '登录后才能查看勋章中心';
        });
      }
      return;
    }
    if (mounted && _session.isCurrent) {
      setState(() {
        _error = null;
        if (_medals.isEmpty) {
          _loading = true;
        } else {
          _refreshing = true;
        }
      });
    }
    final networkFuture = LKApi.myMedals();
    if (_medals.isEmpty) {
      unawaited(LKStore.cachedMedals(uid).then((cached) {
        if (!mounted || !current() || cached == null || _medals.isNotEmpty) {
          return;
        }
        setState(() {
          _medals = cached;
          _loading = false;
          _refreshing = true;
          _error = null;
        });
        if (cached.isNotEmpty) {
          YomiruMedalCache.precache(
              context, cached.map((medal) => _imageUrl(medal.image)));
        }
      }));
    }
    try {
      final medals = await networkFuture;
      if (!mounted || !current()) return;
      _writeMemorySnapshot(medals);
      setState(() {
        _medals = medals;
        _loading = false;
        _refreshing = false;
        _error = null;
      });
      unawaited(LKStore.cacheMedals(uid, medals, isCurrent: current));
      YomiruMedalCache.precache(
          context, medals.map((medal) => _imageUrl(medal.image)));
    } catch (e) {
      if (mounted && current()) {
        final hasExisting = _medals.isNotEmpty;
        setState(() {
          _loading = false;
          _refreshing = false;
          _error = hasExisting ? null : e.toString();
        });
        if (hasExisting) {
          showLkError(context, e);
        }
      }
    }
  }

  Future<void> _toggle(LKMedal medal) async {
    if (!_session.isCurrent ||
        medal.medalId <= 0 ||
        _busy.contains(medal.medalId)) {
      return;
    }
    setState(() => _busy.add(medal.medalId));
    try {
      await LKApi.toggleMedal(medal.medalId, !medal.equipped);
      if (mounted && _session.isCurrent) {
        showLkSnackBar(context, medal.equipped ? '已取下' : '已佩戴',
            tone: LkNoticeTone.success);
        await _load();
      }
    } catch (e) {
      if (mounted && _session.isCurrent) showLkError(context, e);
    } finally {
      if (mounted && _session.isCurrent) {
        setState(() => _busy.remove(medal.medalId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('勋章中心'),
        actions: [
          IconButton(
            tooltip: '勋章商城',
            icon: const Icon(Icons.storefront_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MedalShopPage()),
            ),
          ),
        ],
      ),
      body: _loading && _medals.isEmpty
          ? const ScrollableStatus(child: LkLoadingIndicator())
          : _error != null && _medals.isEmpty
              ? ScrollableStatus(
                  child: ContentStateView(message: _error!, onRetry: _load),
                )
              : Stack(
                  children: [
                    MotionRefreshIndicator(
                      onRefresh: _load,
                      child: _medals.isEmpty
                          ? const ScrollableStatus(child: Text('暂无已拥有勋章'))
                          : GridView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: EdgeInsets.fromLTRB(12, 12, 12,
                                  24 + MediaQuery.paddingOf(context).bottom),
                              gridDelegate:
                                  SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 220,
                                mainAxisExtent: 200 +
                                    (MediaQuery.textScalerOf(context).scale(14) -
                                                14)
                                            .clamp(0, 40) *
                                        3,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                              itemCount: _medals.length,
                              itemBuilder: (_, index) =>
                                  _medalCard(_medals[index]),
                            ),
                    ),
                    if (_refreshing)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: MotionLinearProgressIndicator(minHeight: 2),
                      ),
                  ],
                ),
    );
  }

  Widget _medalCard(LKMedal medal) {
    final image = _imageUrl(medal.image);
    final busy = _busy.contains(medal.medalId);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
        child: Column(
          children: [
            Expanded(
              child: image.isEmpty || LKStore.dataSaverMode.value
                  ? Icon(Icons.military_tech_outlined,
                      size: 58,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)
                  : Image(
                      image: YomiruMedalCache.provider(image),
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Icon(
                          Icons.military_tech_outlined,
                          size: 58,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
            ),
            Text(
              medal.name.isEmpty ? '未命名勋章' : medal.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: OutlinedButton(
                onPressed:
                    medal.medalId <= 0 || busy ? null : () => _toggle(medal),
                child: Text(busy
                    ? '处理中'
                    : medal.equipped
                        ? '取下'
                        : '佩戴'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MedalCenterMemoryEntry {
  const _MedalCenterMemoryEntry({
    required this.client,
    required this.sessionRev,
    required this.securityKey,
    required this.cacheEpoch,
    required this.medals,
  });

  final Object client;
  final int sessionRev;
  final String securityKey;
  final int cacheEpoch;
  final List<LKMedal> medals;

  bool matchesCurrent(LKSession session) =>
      session.isLoggedIn &&
      identical(client, LKApi.client) &&
      sessionRev == LKClient.sessionRev.value &&
      securityKey == session.securityKey &&
      cacheEpoch == LKStore.contentCacheEpoch;
}
