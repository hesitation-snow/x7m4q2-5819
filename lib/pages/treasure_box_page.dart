import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/treasure_box.dart';
import '../services/app_motion.dart';
import '../services/treasure_diagnostics.dart';
import '../widgets/account_scope.dart';
import '../widgets/common.dart';
import 'book_detail_page.dart';

class TreasureBoxPage extends StatelessWidget {
  const TreasureBoxPage({super.key});

  @override
  Widget build(BuildContext context) => AccountScope(
        title: '每日开宝箱',
        builder: (_) => const _TreasureBoxBody(),
      );
}

class _TreasureBoxBody extends StatefulWidget {
  const _TreasureBoxBody();

  @override
  State<_TreasureBoxBody> createState() => _TreasureBoxBodyState();
}

class _TreasureBoxBodyState extends State<_TreasureBoxBody> {
  TreasureBoxDetail? _detail;
  String? _diagnostic;
  String? _error;
  bool _loading = false;
  String? _claimingKey;
  int _serial = 0;
  final _claimedKeys = <String>{};
  late int _owner;
  late int _revision;

  bool get _validSession =>
      LKClient.shared.session.isLoggedIn &&
      LKClient.shared.session.uid == _owner &&
      LKClient.sessionRev.value == _revision;

  @override
  void initState() {
    super.initState();
    _owner = LKClient.shared.session.uid;
    _revision = LKClient.sessionRev.value;
    LKClient.sessionRev.addListener(_sessionChanged);
    _load();
  }

  void _sessionChanged() {
    if (mounted && !_validSession) {
      _serial++;
      _owner = LKClient.shared.session.uid;
      _revision = LKClient.sessionRev.value;
      setState(() {
        _detail = null;
        _diagnostic = null;
        _claimedKeys.clear();
        _loading = false;
        _error = null;
      });
      if (_validSession) _load();
    }
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_sessionChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!_validSession) return;
    final serial = ++_serial;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await LKApi.welfareTreasureBoxDetail();
      if (!mounted || !_validSession || serial != _serial) return;
      setState(() {
        _detail = TreasureBoxDetail.fromMap(raw);
        _diagnostic = treasureDiagnostics(raw);
      });
    } catch (e) {
      if (mounted && _validSession && serial == _serial) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && serial == _serial) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _claim(TreasureBoxItem box, {bool force = false}) async {
    if (!_validSession ||
        _loading ||
        _claimingKey != null ||
        _claimedKeys.contains(box.key) ||
        (!force && !box.canClaim(DateTime.now()))) {
      return;
    }
    setState(() => _claimingKey = box.key);
    try {
      final res = await TreasureBoxApi.claim(box);
      if (!mounted || !_validSession) return;
      setState(() => _claimedKeys.add(box.key));
      final reward = res['data'] is Map
          ? (res['data']['reward_coin'] ?? res['data']['reward_amount'] ?? res['data']['coin'])
          : (res['reward_coin'] ?? res['reward_amount'] ?? res['coin']);
      final rewardCoin = int.tryParse('$reward') ?? box.reward;
      showFloatingPrompt(
        context,
        rewardCoin > 0 ? '宝箱开启成功，获得 $rewardCoin 轻币！' : '宝箱开启成功！',
      );
      await _load();
    } catch (e) {
      if (!mounted || !_validSession) return;
      showLkError(context, e);
      await _load();
    } finally {
      if (mounted) setState(() => _claimingKey = null);
    }
  }

  Future<void> _openBook(TreasureBoxItem box) async {
    if (box.bookId <= 0) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BookDetailPage(bookId: box.bookId),
    ));
    if (mounted && _validSession) {
      try {
        await TreasureBoxApi.reportProgress(box);
      } catch (e) {
        if (mounted && _validSession) {
          showLkError(context, e);
        }
      }
      await _load();
    }
  }

  Future<void> _handleAdPrerequisite(TreasureBoxItem box) async {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: AppMotion.style(context),
      builder: (ctx) => CommunityAdDialog(box: box),
    );
    if (confirmed == true && mounted && _validSession) {
      setState(() => _claimingKey = box.key);
      try {
        await TreasureBoxApi.reportProgress(box);
        if (!mounted || !_validSession) return;
        await _load();
        if (!mounted || !_validSession) return;
        final current = _detail?.boxes.firstWhere(
          (b) => b.boxIndex == box.boxIndex,
          orElse: () => box,
        );
        setState(() => _claimingKey = null);
        if (current != null && current.canClaim(DateTime.now())) {
          await _claim(current);
        } else {
          showFloatingPrompt(context, '广告观看完成，前置条件已达成');
        }
      } catch (e) {
        if (!mounted || !_validSession) return;
        showLkError(context, e);
      } finally {
        if (mounted) setState(() => _claimingKey = null);
      }
    }
  }

  Future<void> _showDiagnostics() async {
    final text = _diagnostic;
    if (text == null || !_validSession) return;
    await showDialog<void>(
      context: context,
      animationStyle: AppMotion.style(context),
      builder: (dialogContext) => AlertDialog(
        title: const Text('宝箱诊断'),
        content: SizedBox(
          width: 480,
          height: MediaQuery.sizeOf(context).height * 0.45,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              if (!_validSession) return;
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) showFloatingPrompt(context, '已复制脱敏诊断');
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final y = time.year.toString().padLeft(4, '0');
    final m = time.month.toString().padLeft(2, '0');
    final d = time.day.toString().padLeft(2, '0');
    final h = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;

    return Scaffold(
      appBar: AppBar(
        title: const Text('每日开宝箱'),
        actions: [
          if (_diagnostic != null && _validSession)
            IconButton(
              tooltip: '宝箱诊断',
              onPressed: _showDiagnostics,
              icon: const Icon(Icons.info_outline_rounded),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_validSession
          ? const Center(child: Text('请重新登录后查看宝箱'))
          : MotionRefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  16,
                  12,
                  16,
                  24 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  if (_loading && detail == null)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (_error != null && detail == null)
                    Card(
                      child: ListTile(
                        leading: Icon(
                          Icons.error_outline,
                          color: theme.colorScheme.error,
                        ),
                        title: const Text('宝箱详情加载失败'),
                        subtitle: Text(_error!),
                        trailing: FilledButton.tonal(
                          onPressed: _loading ? null : _load,
                          child: const Text('重试'),
                        ),
                      ),
                    ),
                  if (detail != null) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '今日宝箱进度',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              detail.todayTotal != null && detail.todayTotal! > 0
                                  ? '今日已开启 ${detail.opened} / ${detail.todayTotal} 个宝箱'
                                  : '今日已开启 ${detail.opened} 个宝箱',
                              style: theme.textTheme.bodyMedium,
                            ),
                            if (detail.claimable != null && detail.claimable! > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '今日可领取 ${detail.claimable} 个宝箱',
                                  style: TextStyle(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            if (detail.nextUnlock != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '下个宝箱开启时间：${_formatTime(detail.nextUnlock!)}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              '开启条件与奖励以服务器返回为准',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (detail.boxes.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('暂无宝箱数据，请稍后下拉刷新')),
                      ),
                    for (final box in detail.boxes) _buildBoxCard(box),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildBoxCard(TreasureBoxItem box) {
    final theme = Theme.of(context);
    final isLocallyClaimed = _claimedKeys.contains(box.key);
    final state = isLocallyClaimed ? TreasureBoxState.claimed : box.state(DateTime.now());
    final isClaiming = _claimingKey == box.key;
    final isReady = state == TreasureBoxState.ready;
    final isClaimed = state == TreasureBoxState.claimed;

    final title = box.reward > 0 ? '${box.reward} 轻币' : box.title;
    final unlockText = box.unlockAt.isNotEmpty
        ? box.unlockAt
        : (box.unlockAtTime != null ? _formatTime(box.unlockAtTime!) : '');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isClaimed
                      ? Icons.inventory_2_outlined
                      : Icons.card_giftcard_rounded,
                  color: isClaimed
                      ? theme.colorScheme.outline
                      : theme.colorScheme.primary,
                  size: 26,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isClaimed ? theme.colorScheme.outline : null,
                        ),
                      ),
                      if (unlockText.isNotEmpty && !isClaimed)
                        Text(
                          '开启时间：$unlockText',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildActionButton(box, state, isClaiming, isReady),
              ],
            ),
            if (box.description.isNotEmpty && !isClaimed) ...[
              const SizedBox(height: 10),
              Text(
                box.description,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (box.requirementCompleted != null && !isClaimed) ...[
              const SizedBox(height: 6),
              Text(
                box.requirementCompleted!
                    ? '前置条件已达成'
                    : '前置条件未满足',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: box.requirementCompleted!
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
              ),
            ],
            if (box.bookId > 0 && !isClaimed) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _loading || isClaiming ? null : () => _openBook(box),
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: Text(
                    box.bookTitle.isNotEmpty
                        ? '查看指定作品：${box.bookTitle}'
                        : '查看指定作品',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(
    TreasureBoxItem box,
    TreasureBoxState state,
    bool isClaiming,
    bool isReady,
  ) {
    if (isClaiming) {
      return const FilledButton(
        onPressed: null,
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (state == TreasureBoxState.claimed) {
      return const OutlinedButton(
        onPressed: null,
        child: Text('已领取'),
      );
    }
    if (state == TreasureBoxState.waiting) {
      final label = box.buttonText.isNotEmpty &&
              box.buttonText != '去完成任务' &&
              box.buttonText != '已完成'
          ? box.buttonText
          : '未到时间';
      return OutlinedButton(
        onPressed: null,
        child: Text(label),
      );
    }
    if (state == TreasureBoxState.prerequisite) {
      if (box.isAdTask) {
        return FilledButton.tonal(
          onPressed: _loading ? null : () => _handleAdPrerequisite(box),
          child: const Text('看广告开启'),
        );
      }
      if (box.isReadTask) {
        return FilledButton.tonal(
          onPressed: _loading ? null : () => _openBook(box),
          child: const Text('去阅读'),
        );
      }
      return OutlinedButton(
        onPressed: null,
        child: Text(box.buttonText.isNotEmpty ? box.buttonText : '未满足条件'),
      );
    }
    if (isReady) {
      return FilledButton(
        onPressed: _loading ? null : () => _claim(box),
        child: const Text('开宝箱'),
      );
    }
    return OutlinedButton(
      onPressed: _loading ? null : _load,
      child: const Text('刷新状态'),
    );
  }
}

class CommunityAdDialog extends StatefulWidget {
  const CommunityAdDialog({
    super.key,
    required this.box,
    this.countdownDuration = 3,
  });

  final TreasureBoxItem box;
  final int countdownDuration;

  @override
  State<CommunityAdDialog> createState() => _CommunityAdDialogState();
}

class _CommunityAdDialogState extends State<CommunityAdDialog> {
  static const String groupNumber = '132141941';
  static const String adHeadline = '轻国交流群+132141941';

  late int _secondsLeft;
  Timer? _timer;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _secondsLeft = widget.countdownDuration;
    if (_secondsLeft > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          if (_secondsLeft > 1) {
            _secondsLeft--;
          } else {
            _secondsLeft = 0;
            timer.cancel();
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copyGroupNumber() async {
    setState(() => _copied = true);
    await Clipboard.setData(const ClipboardData(text: groupNumber));
    if (!mounted) return;
    showFloatingPrompt(context, '群号 132141941 已复制到剪贴板');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCountingDown = _secondsLeft > 0;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.campaign_rounded,
              color: theme.colorScheme.onPrimaryContainer,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '社区交流广告',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '看广告支持轻之国度',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.25),
                  width: 1.5,
                ),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '官方推荐',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    adHeadline,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '欢迎加入轻之国度交流群！与书友一起畅聊轻小说、交流汉化与书评、获取最新资讯与福利。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                    onPressed: _copyGroupNumber,
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 18,
                    ),
                    label: Text(_copied ? '群号已复制' : '复制群号: $groupNumber'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (isCountingDown)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: widget.countdownDuration > 0
                          ? 1 - (_secondsLeft / widget.countdownDuration)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在观看广告... (${_secondsLeft}s)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: theme.colorScheme.primary,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '广告已完成观看，可开启宝箱',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('放弃'),
        ),
        FilledButton(
          onPressed: isCountingDown
              ? null
              : () => Navigator.of(context).pop(true),
          child: const Text('完成观看并开启宝箱'),
        ),
      ],
    );
  }
}
