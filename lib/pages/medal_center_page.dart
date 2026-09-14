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
  final _session = SessionStamp();
  int _loadSerial = 0;
  List<LKMedal> _medals = const [];
  bool _loading = true;
  String? _error;
  final Set<int> _busy = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
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
    bool current() => mounted && _session.isCurrent && serial == _loadSerial;
    if (!session.isLoggedIn) {
      if (mounted && _session.isCurrent) {
        setState(() {
          _loading = false;
          _error = '登录后才能查看勋章中心';
        });
      }
      return;
    }
    final cached = await LKStore.cachedMedals(_session.uid);
    if (mounted && current() && cached != null && cached.isNotEmpty) {
      setState(() {
        _medals = cached;
        _loading = true;
        _error = null;
      });
      YomiruMedalCache.precache(
          context, cached.map((medal) => _imageUrl(medal.image)));
    }
    try {
      if (!mounted || !current()) return;
      final medals = await LKApi.myMedals();
      if (!mounted || !current()) return;
      await LKStore.cacheMedals(_session.uid, medals, isCurrent: current);
      if (!mounted || !current()) return;
      setState(() {
        _medals = medals;
        _loading = false;
        _error = null;
      });
      YomiruMedalCache.precache(
          context, medals.map((medal) => _imageUrl(medal.image)));
    } catch (e) {
      if (mounted && current()) {
        setState(() {
          _loading = false;
          _error = _medals.isEmpty ? e.toString() : null;
        });
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
        showLkError(context, medal.equipped ? '已取下' : '已佩戴');
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
          ? const LkLoadingIndicator()
          : _error != null && _medals.isEmpty
              ? Center(
                  child: FilledButton.tonal(
                    onPressed: _load,
                    child: Text(_error!),
                  ),
                )
              : MotionRefreshIndicator(
                  onRefresh: _load,
                  child: _medals.isEmpty
                      ? const ScrollableStatus(child: Text('暂无已拥有勋章'))
                      : GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
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
                          itemBuilder: (_, index) => _medalCard(_medals[index]),
                        ),
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
