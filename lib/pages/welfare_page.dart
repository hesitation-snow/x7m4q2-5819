import '../services/app_motion.dart';
import '../widgets/account_scope.dart';
import '../widgets/scrollable_status.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/lk_api.dart';
import '../api/lk_client.dart';
import '../api/reading_session.dart';
import '../services/reading_progress_reporter.dart';
import '../services/daily_task_claims.dart';
import '../services/deadline_countdown.dart';
import '../widgets/common.dart';
import 'book_detail_page.dart';
import 'dynamic_page.dart';
import 'reader_page.dart';
import 'search_page.dart';

// 本地协议测试开关：默认关闭，需显式 --dart-define 才会编译入口。
const _enableWelfareProtocolProbe =
    bool.fromEnvironment('YOMIRU_WELFARE_PROTOCOL_PROBE');

enum _TaskItemStatus {
  claimable,
  actionable,
  claimed,
}

/// 任务中心：签到、阅读、睡觉、日常任务和轻币记录。
/// 所有请求都走 Yomiru 当前配置的正式站点，不读取其他客户端的服务器地址。
class WelfarePage extends StatefulWidget {
  const WelfarePage({super.key, this.readingReporter});
  final ReadingProgressReporter? readingReporter;

  @override
  State<WelfarePage> createState() => _WelfarePageState();

  @visibleForTesting
  static bool isTaskClaimed(Map<String, dynamic> task) =>
      _WelfarePageState()._taskClaimed(task);

  @visibleForTesting
  static bool isTaskClaimable(Map<String, dynamic> task) =>
      _WelfarePageState()._taskClaimable(task);

  @visibleForTesting
  static String taskButtonText(Map<String, dynamic> task) =>
      _WelfarePageState()._taskButtonText(task);

  @visibleForTesting
  static int taskOrderWeight(Map<String, dynamic> task) =>
      _WelfarePageState()._taskOrderWeight(task);

  @visibleForTesting
  static List<Map<String, dynamic>> orderTasks(
          List<Map<String, dynamic>> tasks) =>
      _WelfarePageState()._orderTasks(tasks);

  @visibleForTesting
  static List<Map<String, dynamic>> filterVisibleTasks(
          Iterable<Map<String, dynamic>> tasks) =>
      _WelfarePageState()._visibleTasks(tasks);

  @visibleForTesting
  static bool isAllowedRewardTask(Map<String, dynamic> task) =>
      _WelfarePageState()._isAllowedRewardTask(task);

  @visibleForTesting
  static void markTaskClaimedTodayForTesting(Map<String, dynamic> task) {
    _WelfarePageState._testingClaimedKeys.addAll(
      _WelfarePageState()._taskClaimSignatures(task),
    );
  }

  @visibleForTesting
  static void clearClaimedTestingState() {
    _WelfarePageState._testingClaimedKeys.clear();
  }
}

class _WelfarePageState extends State<WelfarePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _cacheKeyPrefix = 'welfare_home_cache_v1_';
  static final Set<String> _testingClaimedKeys = {};
  final _dailyClaims = DailyTaskClaims(uid: () => LKClient.shared.session.uid);
  int _loadSerial = 0;

  Map<String, dynamic>? _home;
  Map<String, dynamic> _signDetail = const {};
  Map<String, dynamic> _earnCoin = const {};
  Map<String, dynamic> _sleep = const {};
  List<Map<String, dynamic>> _tasks = const [];
  bool _loading = true;
  String? _error;
  String _action = '';
  final _sleepClock = DeadlineCountdown();
  int get _sleepRemainingSeconds => _sleepClock.value;
  bool _sleepCountdownExpired = false;
  late final AnimationController _animController;

  String get _cacheKey {
    final uid = LKClient.shared.session.uid;
    return '$_cacheKeyPrefix${uid > 0 ? uid : 'guest'}';
  }

  List<String> _taskClaimSignatures(Map<String, dynamic> task) {
    final sigs = <String>[];
    final id = _taskId(task);
    if (id > 0) sigs.add('id:$id');
    final key = _taskKey(task).toLowerCase().trim();
    if (key.isNotEmpty) sigs.add('key:$key');
    if (_isBrowseWorkTask(task)) sigs.add('cat:browse');
    if (_isCollectWorkTask(task)) sigs.add('cat:collect');
    final normTitle = _taskTitle(task).replaceAll(RegExp(r'\s+'), '');
    if (normTitle.isNotEmpty) sigs.add('title:$normTitle');
    return sigs;
  }

  bool _isTaskClaimedToday(Map<String, dynamic> task) {
    final sigs = _taskClaimSignatures(task);
    for (final sig in sigs) {
      if (_dailyClaims.contains(sig) || _testingClaimedKeys.contains(sig)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _initDailyClaimedKeys() async {
    try {
      await _dailyClaims.load();
    } catch (_) {}
  }

  Future<void> _recordTaskClaimedToday(
      Map<String, dynamic> task, String key) async {
    final sigs = _taskClaimSignatures(task);
    if (sigs.isEmpty) return;
    try {
      await _dailyClaims.record(sigs, expectedKey: key);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    WidgetsBinding.instance.addObserver(this);
    LKClient.sessionRev.addListener(_onSessionChanged);
    _sleepClock.onElapsed = () {
      if (!mounted) return;
      _sleepCountdownExpired = true;
      unawaited(_load());
    };
    _restoreCache();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.isDisabled(context)) {
      _animController.stop();
    } else if (!_animController.isAnimating) {
      _animController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    LKClient.sessionRev.removeListener(_onSessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _sleepClock.dispose();
    _animController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sleepClock.refresh();
  }

  void _onSessionChanged() {
    _loadSerial++;
    _sleepClock.stop();
    _sleepClock.value = 0;
    setState(() {
      _home = null;
      _signDetail = _earnCoin = _sleep = const {};
      _tasks = const [];
      _action = '';
      _error = null;
      _loading = LKClient.shared.session.isLoggedIn;
    });
    if (_loading) {
      unawaited(_restoreCache());
      unawaited(_load());
    }
  }

  Future<void> _restoreCache() async {
    final key = _cacheKey;
    final revision = LKClient.sessionRev.value;
    try {
      await _initDailyClaimedKeys();
      final prefs = await SharedPreferences.getInstance();
      final cachedStr = prefs.getString(key);
      if (cachedStr != null && cachedStr.isNotEmpty) {
        final decoded = jsonDecode(cachedStr);
        if (decoded is Map &&
            mounted &&
            _home == null &&
            key == _cacheKey &&
            revision == LKClient.sessionRev.value) {
          final map = Map<String, dynamic>.from(decoded);
          final root = _root(map);
          final tasks = _orderTasks(_visibleTasks(_extractTasks(root)));
          final homeEarnCoin = _section(
              root, const ['earn_coin', 'earnCoin', 'welfare_earn_coin']);
          setState(() {
            _home = map;
            _tasks = tasks;
            _earnCoin = homeEarnCoin;
            _loading = false;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCache(
      Map<String, dynamic> data, String key, int revision) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (key != _cacheKey || revision != LKClient.sessionRev.value) return;
      await prefs.setString(key, jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _checkAndSyncReadingProgress() async {
    try {
      await (widget.readingReporter ?? ReadingProgressReporter.shared)
          .flush(force: true);
    } catch (_) {
      // 静默同步，不影响任务中心主请求
    }
  }

  Future<void> _load({bool forceTaskList = false}) async {
    if (!LKClient.shared.session.isLoggedIn) return;
    final serial = ++_loadSerial;
    final key = _cacheKey;
    final revision = LKClient.sessionRev.value;
    bool isCurrent() =>
        mounted &&
        serial == _loadSerial &&
        key == _cacheKey &&
        revision == LKClient.sessionRev.value;
    if (mounted) {
      setState(() {
        if (_home == null) _loading = true;
        _error = null;
      });
    }
    // 页面先显示缓存；阅读奖励详情等待增量确认后再查询。
    final readingSync = _checkAndSyncReadingProgress();

    try {
      await _initDailyClaimedKeys();
      final home = await LKApi.welfareHome();
      final root = _root(home);
      if (!isCurrent()) return;
      unawaited(_saveCache(home, key, revision));
      setState(() {
        _home = home;
        _loading = false;
      });

      final detailsFuture = Future.wait<Map<String, dynamic>>([
        _safeDetail(LKApi.welfareSignDetail()),
        _safeDetail(() async {
          await readingSync;
          if (!isCurrent()) return <String, dynamic>{};
          return LKApi.welfareEarnCoinDetail();
        }()),
        _safeDetail(LKApi.welfareSleepDetail()),
      ]);
      var tasks = _extractTasks(root);
      if (forceTaskList || _visibleTasks(tasks).length < 2) {
        try {
          final refreshedTasks =
              _extractTasks(_root(await LKApi.welfareTaskList()));
          if (refreshedTasks.isNotEmpty) {
            tasks = [...tasks, ...refreshedTasks];
          }
        } catch (_) {
          // 主页数据已经足够展示时，任务列表接口失败不影响其他模块。
        }
      }
      tasks = _orderTasks(_visibleTasks(tasks));
      final details = await detailsFuture;
      final signDetail = details[0];
      final homeEarnCoin =
          _section(root, const ['earn_coin', 'earnCoin', 'welfare_earn_coin']);
      final earnCoin = details[1].isNotEmpty ? details[1] : homeEarnCoin;
      final sleep = details[2];
      if (!isCurrent()) return;
      final seconds = _sleepRemainingSecondsFrom(sleep);
      _sleepCountdownExpired = false;
      setState(() {
        _signDetail = signDetail;
        _earnCoin = earnCoin;
        _sleep = sleep;
        _tasks = tasks;
        _loading = false;
      });
      _sleepClock.start(_sleepClaimed || _sleepClaimable ? 0 : seconds);
    } catch (e) {
      if (isCurrent()) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<Map<String, dynamic>> _safeDetail(
      Future<Map<String, dynamic>> request) async {
    try {
      return await request;
    } catch (_) {
      return const {};
    }
  }

  Future<void> _claimSign() async {
    await _runAction('sign', () => LKApi.claimWelfareSign());
  }

  Future<void> _claimEarnCoin() async {
    await _runAction(
        'earn-coin', () => LKApi.claimWelfareEarnCoin(taskKey: _earnTaskKey));
  }

  Future<void> _startSleep() async {
    await _runAction('sleep-start', LKApi.startWelfareSleep);
  }

  Future<void> _claimSleep() async {
    await _runAction('sleep-claim', LKApi.claimWelfareSleep);
  }

  bool _isSameTask(Map<String, dynamic> a, Map<String, dynamic> b) {
    final idA = _taskId(a);
    final idB = _taskId(b);
    if (idA > 0 && idB > 0 && idA == idB) return true;
    final keyA = _taskKey(a).toLowerCase().trim();
    final keyB = _taskKey(b).toLowerCase().trim();
    if (keyA.isNotEmpty && keyB.isNotEmpty && keyA == keyB) return true;
    if (_isBrowseWorkTask(a) && _isBrowseWorkTask(b)) return true;
    if (_isCollectWorkTask(a) && _isCollectWorkTask(b)) return true;
    final titleA = _taskTitle(a).replaceAll(RegExp(r'\s+'), '');
    final titleB = _taskTitle(b).replaceAll(RegExp(r'\s+'), '');
    if (titleA.isNotEmpty && titleB.isNotEmpty && titleA == titleB) return true;
    return false;
  }

  Future<void> _claimTask(Map<String, dynamic> task) async {
    final taskId = _taskId(task);
    final taskKey = _taskKey(task);
    await _runAction(
      'task:$taskId:$taskKey',
      () => LKApi.claimWelfareTask(taskId: taskId, taskKey: taskKey),
      taskContext: task,
    );
  }

  Future<void> _runAction(
    String action,
    Future<Map<String, dynamic>> Function() request, {
    Map<String, dynamic>? taskContext,
  }) async {
    if (_action.isNotEmpty) return;
    final claimKey = _dailyClaims.storageKey;
    final revision = LKClient.sessionRev.value;
    setState(() => _action = action);
    try {
      await request();
      if (!mounted || revision != LKClient.sessionRev.value) return;
      if (claimKey != _dailyClaims.storageKey) {
        await _load(forceTaskList: true);
        return;
      }
      showLkError(context, '操作成功');
      if (action.startsWith('task:')) {
        if (taskContext != null) {
          await _recordTaskClaimedToday(taskContext, claimKey);
        }
        if (!mounted ||
            revision != LKClient.sessionRev.value ||
            claimKey != _dailyClaims.storageKey) {
          return;
        }
        final parts = action.split(':');
        final taskId = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
        final taskKey = parts.length > 2 ? parts.sublist(2).join(':') : '';
        setState(() {
          final updated = _tasks.map((t) {
            if ((taskContext != null && _isSameTask(t, taskContext)) ||
                (taskId > 0 && _taskId(t) == taskId) ||
                (taskKey.isNotEmpty && _taskKey(t) == taskKey)) {
              return {
                ...t,
                'claimed': true,
                'is_claimed': true,
                'status': 2,
                'button_text': '已领取',
                'button_action': 'claimed',
              };
            }
            return t;
          }).toList();
          _tasks = _orderTasks(updated);
        });
      }
      await _load(forceTaskList: action.startsWith('task:'));
    } catch (e) {
      if (!mounted || revision != LKClient.sessionRev.value) return;
      if (claimKey != _dailyClaims.storageKey) {
        await _load(forceTaskList: true);
        return;
      }
      final errStr = e.toString().toLowerCase();
      if (action.startsWith('task:') &&
          (errStr.contains('已领取') ||
              errStr.contains('重复') ||
              errStr.contains('今日已') ||
              errStr.contains('已完成') ||
              errStr.contains('already') ||
              errStr.contains('claimed'))) {
        if (taskContext != null) {
          await _recordTaskClaimedToday(taskContext, claimKey);
        }
        if (mounted) {
          setState(() {
            final updated = _tasks.map((t) {
              if (taskContext != null && _isSameTask(t, taskContext)) {
                return {
                  ...t,
                  'claimed': true,
                  'is_claimed': true,
                  'status': 2,
                  'button_text': '已领取',
                  'button_action': 'claimed',
                };
              }
              return t;
            }).toList();
            _tasks = _orderTasks(updated);
          });
          showLkError(context, '今日已领取');
        }
        return;
      }
      showLkError(context, e);
    } finally {
      if (mounted) setState(() => _action = '');
    }
  }

  Map<String, dynamic> _root(Map<String, dynamic> data) {
    return _map(data['home']) ?? _map(data['welfare']) ?? data;
  }

  Map<String, dynamic>? _map(dynamic value) {
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  dynamic _taskField(Map<String, dynamic> task, List<String> keys,
      [int depth = 0]) {
    for (final key in keys) {
      if (task.containsKey(key) && task[key] != null) return task[key];
    }
    if (depth >= 4) return null;
    for (final key in const [
      'task',
      'task_info',
      'taskInfo',
      'task_data',
      'taskData',
      'reward_task',
      'rewardTask',
      'data',
      'detail',
      'payload',
    ]) {
      final nested = _map(task[key]);
      if (nested != null) {
        final value = _taskField(nested, keys, depth + 1);
        if (value != null) return value;
      }
    }
    return null;
  }

  int _taskId(Map<String, dynamic> task) =>
      _int(_deepField(task, const ['task_id', 'taskId', 'taskID', 'id']));

  String _taskKey(Map<String, dynamic> task) =>
      _text(_deepField(task, const ['task_key', 'taskKey', 'taskKEY', 'key']));

  String _taskType(Map<String, dynamic> task) =>
      _text(_deepField(task, const ['task_type', 'taskType', 'type', 'action']))
          .toLowerCase();

  bool _isEarnCoinTask(Map<String, dynamic> task) {
    final text =
        '${_taskTitle(task)} ${_taskDescription(task)} ${_taskKey(task)} '
                '${_taskType(task)}'
            .toLowerCase();
    final raw = task.toString().toLowerCase();
    final compact = raw.replaceAll(RegExp(r'\s+'), '');
    final readingNode = (raw.contains('reward_nodes') ||
            raw.contains('reward_days') ||
            raw.contains('week_rewards') ||
            raw.contains('progress_nodes')) &&
        (raw.contains('read') ||
            raw.contains('reader') ||
            raw.contains('active_seconds') ||
            raw.contains('read_duration') ||
            raw.contains('阅读') ||
            raw.contains('轻币'));
    return text.contains('15分钟') ||
        text.contains('15min') ||
        text.contains('阅读赚轻币') ||
        text.contains('earn_coin') ||
        text.contains('reading_reward') ||
        text.contains('read_coin') ||
        text.contains('daily_read_15m') ||
        raw.contains('daily_read_15m') ||
        compact.contains('15分钟') ||
        compact.contains('15min') ||
        readingNode ||
        (raw.contains('progress_minutes') &&
            (raw.contains('reward_nodes') ||
                raw.contains('reward_days') ||
                raw.contains('read_duration')));
  }

  bool _isSignTask(Map<String, dynamic> task) {
    final text =
        '${_taskTitle(task)} ${_taskDescription(task)} ${_taskKey(task)} '
                '${_taskType(task)}'
            .toLowerCase();
    final raw = task.toString().toLowerCase();
    return text.contains('签到') ||
        text.contains('sign_in') ||
        text.contains('seven_day_sign') ||
        text.contains('new_user_7day_sign') ||
        text.contains('daily_sign') ||
        text.contains('7day') ||
        text.contains('7_day') ||
        text.contains('7日') ||
        text.contains('七日') ||
        text.contains('1-7') ||
        text.contains('1～7') ||
        raw.contains('new_user_7day_sign') ||
        (raw.contains('daily_all') && raw.contains('reward')) ||
        _listFor(task, const ['sign_days', 'daily_all']).length >= 2;
  }

  bool _hasTaskIdentity(Map<String, dynamic> task) =>
      _taskId(task) > 0 || _taskKey(task).isNotEmpty;

  /// 七日阅读/签到进度在任务接口中会被拆成“第 N 天”的独立行，
  /// 但它们已经由上方专用卡片展示，不应在通用任务奖励中重复出现。
  bool _isRewardScheduleTask(Map<String, dynamic> task) {
    final title = _taskTitle(task).replaceAll(RegExp(r'\s+'), '');
    return RegExp(r'^第[1-7]天$').hasMatch(title);
  }

  bool _isSleepTask(Map<String, dynamic> task) {
    final text =
        '${_taskTitle(task)} ${_taskDescription(task)} ${_taskKey(task)} '
                '${_taskType(task)}'
            .toLowerCase();
    return text.contains('睡觉') || text.contains('sleep');
  }

  /// 判定是否属于无效的网站/第三方测试任务
  bool _isInvalidTestTask(Map<String, dynamic> task) {
    final title = _taskTitle(task).toLowerCase();
    final desc = _text(_deepField(task, const [
      'task_desc',
      'taskDesc',
      'description',
      'desc',
      'subtitle'
    ])).toLowerCase();
    final key = _taskKey(task).toLowerCase();
    final type = _taskType(task).toLowerCase();
    final url = _text(_deepField(
            task, const ['jump_url', 'jumpUrl', 'target_url', 'url', 'link']))
        .toLowerCase();
    final combined = '$title $desc $key $type $url';
    return combined.contains('测试') ||
        combined.contains('test') ||
        combined.contains('网站') ||
        combined.contains('网页') ||
        combined.contains('demo') ||
        combined.contains('第三方') ||
        combined.contains('问卷') ||
        combined.contains('广告');
  }

  /// 判定是否属于“浏览一个作品”任务
  bool _isBrowseWorkTask(Map<String, dynamic> task) {
    if (_isInvalidTestTask(task)) return false;
    final title = _taskTitle(task);
    final normTitle = title.replaceAll(RegExp(r'\s+'), '');
    final key = _taskKey(task).toLowerCase();
    final type = _taskType(task).toLowerCase();

    return normTitle == '浏览一个作品' ||
        normTitle == '浏览作品' ||
        normTitle == '浏览' ||
        normTitle == '其它任务' ||
        normTitle == '其他任务' ||
        (normTitle.contains('浏览') && !normTitle.contains('网')) ||
        (key.contains('browse') && !key.contains('web')) ||
        (type.contains('browse') && !type.contains('web'));
  }

  /// 判定是否属于“收藏一个作品”任务
  bool _isCollectWorkTask(Map<String, dynamic> task) {
    if (_isInvalidTestTask(task)) return false;
    final title = _taskTitle(task);
    final normTitle = title.replaceAll(RegExp(r'\s+'), '');
    final key = _taskKey(task).toLowerCase();
    final type = _taskType(task).toLowerCase();

    return normTitle == '收藏一个作品' ||
        normTitle == '收藏作品' ||
        normTitle == '收藏' ||
        normTitle == '加入书架' ||
        normTitle.contains('收藏') ||
        key.contains('collect') ||
        key.contains('favorite') ||
        key.contains('shelf') ||
        type.contains('collect') ||
        type.contains('favorite');
  }

  /// 任务中心仅允许“浏览一个作品”与“收藏一个作品”
  bool _isAllowedRewardTask(Map<String, dynamic> task) =>
      _isBrowseWorkTask(task) || _isCollectWorkTask(task);

  /// 过滤出任务奖励板块允许展示的任务，并进行同类去重，至多展示 2 个
  List<Map<String, dynamic>> _visibleTasks(
      Iterable<Map<String, dynamic>> tasks) {
    final candidates = tasks.where((task) =>
        _hasTaskIdentity(task) &&
        !_isRewardScheduleTask(task) &&
        !_isEarnCoinTask(task) &&
        !_isSignTask(task) &&
        !_isSleepTask(task) &&
        _isAllowedRewardTask(task));

    Map<String, dynamic>? bestBrowse;
    Map<String, dynamic>? bestCollect;

    Map<String, dynamic> pickBest(
        Map<String, dynamic>? current, Map<String, dynamic> incoming) {
      if (current == null) return incoming;

      final currentStatus = _taskStatus(current);
      final incomingStatus = _taskStatus(incoming);

      // 1. 已领取的任务具有最高权威性（当日任务已完成），绝不能被未刷新的可领取或进行中覆盖
      if (currentStatus == _TaskItemStatus.claimed) return current;
      if (incomingStatus == _TaskItemStatus.claimed) return incoming;

      // 2. 其次优先可领取（已完成待领），高于普通进行中/去完成
      if (incomingStatus == _TaskItemStatus.claimable &&
          currentStatus != _TaskItemStatus.claimable) {
        return incoming;
      }

      return current;
    }

    for (final task in candidates) {
      final normalizedTask = _isTaskClaimedToday(task)
          ? {
              ...task,
              'status': 2,
              'claimed': true,
              'is_claimed': true,
              'button_text': '已领取',
              'button_action': 'claimed',
            }
          : task;

      if (_isBrowseWorkTask(normalizedTask)) {
        bestBrowse = pickBest(bestBrowse, normalizedTask);
      } else if (_isCollectWorkTask(normalizedTask)) {
        bestCollect = pickBest(bestCollect, normalizedTask);
      }
    }

    final result = <Map<String, dynamic>>[];
    if (bestBrowse != null) result.add(bestBrowse);
    if (bestCollect != null) result.add(bestCollect);
    return result;
  }

  List<Map<String, dynamic>> get _displayTasks => _visibleTasks(_tasks);

  Map<String, dynamic> _sleepDataFor(Map<String, dynamic> data) {
    final nested = _map(data['detail']) ??
        _map(data['sleep_detail']) ??
        _map(data['sleepDetail']) ??
        _map(data['sleep']) ??
        _map(data['result']) ??
        _map(data['payload']) ??
        _map(data['data']) ??
        const <String, dynamic>{};
    // 外层是任务汇总状态,detail 才是睡眠任务的实际生命周期状态。
    // 例如外层可能为 in_progress,但 detail.status=idle,此时仍应允许开始睡觉。
    if (nested.isNotEmpty &&
        (nested.containsKey('status') ||
            nested.containsKey('sleep_start_at') ||
            nested.containsKey('remaining_seconds'))) {
      return {...data, ...nested};
    }
    if (data.containsKey('task_key') ||
        data.containsKey('sleep_start_at') ||
        data.containsKey('claim_at_text') ||
        data.containsKey('button_text')) {
      return data;
    }
    return nested;
  }

  Map<String, dynamic> get _sleepData => _sleepDataFor(_sleep);

  String get _sleepStatus =>
      _text(_taskField(_sleepData, const ['status', 'sleep_status']))
          .toLowerCase();

  bool get _sleepClaimed =>
      _flag(_taskField(_sleepData, const ['claimed', 'is_claimed'])) ||
      _statusIs(_sleepStatus, const ['claimed', 'received']);

  bool get _sleepClaimable {
    final action =
        _text(_taskField(_sleepData, const ['button_action', 'buttonAction']))
            .toLowerCase();
    return !_sleepClaimed &&
        (_flag(_taskField(_sleepData, const [
              'claimable',
              'can_claim',
              'is_claimable',
            ])) ||
            _statusIs(_sleepStatus,
                const ['claimable', 'ready', 'completed', 'finished']) ||
            action == 'claim' ||
            action == 'receive');
  }

  bool get _sleepStarted {
    if (_sleepClaimed || _sleepClaimable) return true;
    final startedAt =
        _text(_taskField(_sleepData, const ['sleep_start_at', 'started_at']));
    return startedAt.isNotEmpty ||
        _statusIs(_sleepStatus, const ['sleeping', 'in_progress', 'running']) ||
        _sleepRemainingSeconds > 0;
  }

  String get _sleepButtonText =>
      _text(_taskField(_sleepData, const ['button_text', 'buttonText']));

  String get _sleepDescription => _text(_taskField(
      _sleepData, const ['sub_title', 'subtitle', 'description', 'task_desc']));

  String get _sleepCountdown {
    if (_sleepRemainingSeconds > 0) {
      return _formatDuration(_sleepRemainingSeconds);
    }
    if (_sleepCountdownExpired) return '';
    return _text(
        _taskField(_sleepData, const ['countdown_text', 'countdownText']));
  }

  String get _sleepClaimAt => _text(_taskField(_sleepData,
      const ['claim_at_text', 'claimAtText', 'target_duration_text']));

  int _sleepRemainingSecondsFrom(Map<String, dynamic> data) {
    final sleep = _sleepDataFor(data);
    for (final key in const [
      'countdown_seconds',
      'countdownSeconds',
      'remaining_seconds',
      'remainingSeconds',
      'remain_seconds',
      'remainSeconds',
    ]) {
      final seconds = _int(_taskField(sleep, [key]));
      if (seconds > 0) return seconds;
    }
    final target = _parseServerDate(_taskField(sleep, const [
      'claim_at',
      'claimAt',
      'sleep_end_at',
      'sleepEndAt',
      'end_at',
      'endAt',
      'target_at',
      'targetAt',
    ]));
    if (target != null) {
      final remaining = target.difference(DateTime.now()).inSeconds;
      if (remaining > 0) return remaining;
    }
    final countdownText =
        _text(_taskField(sleep, const ['countdown_text', 'countdownText']));
    return _parseCountdownText(countdownText);
  }

  DateTime? _parseServerDate(dynamic value) {
    if (value is num) {
      final number = value.toInt();
      if (number <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(
          number > 20000000000 ? number : number * 1000);
    }
    final text = _text(value).trim();
    if (text.isEmpty) return null;
    final numeric = int.tryParse(text);
    if (numeric != null && numeric > 0) {
      return DateTime.fromMillisecondsSinceEpoch(
          numeric > 20000000000 ? numeric : numeric * 1000);
    }
    return DateTime.tryParse(text);
  }

  int _parseCountdownText(String text) {
    final value = text.trim();
    if (value.isEmpty) return 0;
    final parts = value.split(':');
    if (parts.length >= 2 &&
        parts.every((part) => int.tryParse(part) != null)) {
      final numbers = parts.map(int.parse).toList();
      if (numbers.length == 2) return numbers[0] * 60 + numbers[1];
      return numbers[numbers.length - 3] * 3600 +
          numbers[numbers.length - 2] * 60 +
          numbers[numbers.length - 1];
    }
    final match = RegExp(
            r'(?:(\d+)\s*(?:小时|时|h))?\s*(?:(\d+)\s*(?:分钟|分|m))?\s*(?:(\d+)\s*(?:秒|s))?')
        .firstMatch(value);
    if (match == null) return 0;
    final hours = int.tryParse(match.group(1) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(2) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(3) ?? '') ?? 0;
    return hours * 3600 + minutes * 60 + seconds;
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remaining = seconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> _earnDataFor(Map<String, dynamic> data) {
    // 详情接口已经直接返回阅读任务时，优先保留这一层。
    // 某些响应会同时带有通用 data 字段；它并不一定是阅读任务本身。
    if (data.containsKey('task_key') ||
        data.containsKey('progress') ||
        data.containsKey('button_text') ||
        data.containsKey('reader_target')) {
      return data;
    }
    return _map(data['earn_coin']) ??
        _map(data['earnCoin']) ??
        _map(data['welfare_earn_coin']) ??
        _map(data['reading_reward']) ??
        _map(data['read_earn']) ??
        _map(data['reading']) ??
        _map(data['module']) ??
        _map(data['module_data']) ??
        _map(data['reward']) ??
        _map(data['detail']) ??
        _map(data['result']) ??
        _map(data['payload']) ??
        _map(data['data']) ??
        data;
  }

  Map<String, dynamic> get _earnData => _earnDataFor(_earnCoin);

  String get _earnTaskKey => _text(
      _deepField(_earnData, const ['task_key', 'taskKey', 'reading_task_key']));

  bool get _earnClaimed {
    final btnText = _text(_taskField(
        _earnData, const ['button_text', 'buttonText', 'btn_text'])).trim();
    if (btnText == '今日已领取' || btnText == '已领取') return true;

    final btnAction = _text(_taskField(
            _earnData, const ['button_action', 'buttonAction', 'action']))
        .toLowerCase()
        .trim();
    if (btnAction == 'claimed' || btnAction == 'received') return true;

    final rawStatus = _taskField(
        _earnData, const ['status', 'claim_status', 'reward_status', 'state']);
    if (rawStatus is num && rawStatus.toInt() == 2) return true;

    final status = _taskField(_earnData, const [
      'taskClaimedToday',
      'task_claimed_today',
      'today_claimed',
      'today_reward_claimed',
      'isClaimedToday',
      'today_reward_status',
      'reward_status',
      'status',
      'reward_result',
      'claimed',
      'is_claimed',
    ]);
    final nestedStatus = _deepField(_earnData, const [
      'taskClaimedToday',
      'task_claimed_today',
      'today_claimed',
      'today_reward_claimed',
      'isClaimedToday',
      'today_reward_status',
      'reward_status',
      'claimed',
      'is_claimed',
    ]);
    return _flag(status) ||
        _statusIs(status, const ['claimed', 'received', 'rewarded']) ||
        _flag(nestedStatus) ||
        _statusIs(nestedStatus, const ['claimed', 'received', 'rewarded']);
  }

  bool get _earnClaimable {
    if (_earnClaimed) return false;

    final btnText = _text(_taskField(
        _earnData, const ['button_text', 'buttonText', 'btn_text'])).trim();
    if (btnText == '领取' ||
        btnText == '去领取' ||
        btnText == '可领取' ||
        btnText == '领取奖励') {
      return true;
    }

    final btnAction = _text(_taskField(
            _earnData, const ['button_action', 'buttonAction', 'action']))
        .toLowerCase()
        .trim();
    if (btnAction == 'claim' || btnAction == 'receive') return true;

    final rawStatus = _taskField(
        _earnData, const ['status', 'claim_status', 'reward_status', 'state']);
    if (rawStatus is num && rawStatus.toInt() == 1) return true;

    final state = _deepState(
      _earnData,
      flagKeys: const [
        'claimable',
        'can_claim',
        'is_claimable',
        'eligible',
        'is_eligible',
        'completed',
        'is_completed',
        'finished',
        'is_finished',
        'done',
        'is_done',
        'achieved',
        'is_achieved',
        'taskCompletedToday',
        'task_completed_today',
        'taskClaimableToday',
        'task_claimable_today',
      ],
      statusKeys: const [
        'claim_status',
        'reward_status',
        'status',
        'reward_result',
      ],
      trueStatuses: const [
        'claimable',
        'can_claim',
        'ready',
        'eligible',
        'completed',
        'finished',
        'done',
        'achieved',
      ],
      falseStatuses: const [
        'claimed',
        'received',
        'in_progress',
        'pending',
        'not_ready',
        'not_eligible',
        'incomplete',
      ],
    );
    if (state != null) return state;
    return _earnProgressSeconds >= _earnTargetSeconds;
  }

  List<Map<String, dynamic>> get _earnDayRewards => _listFor(_earnData, const [
        'nodes',
        'week_rewards',
        'week_plan',
        'day_rewards',
        'reward_days',
        'rewardDays',
        'reward_nodes',
        'rewardNodes',
        'reward_items',
        'rewardItems',
        'reward_list',
        'rewardList',
        'task_nodes',
        'taskNodes',
        'rewards',
        'days',
        'day_list',
        'items',
        'list',
      ]);

  int get _earnCurrentDay {
    final direct = _int(_taskField(_earnData, const [
      'campaign_day',
      'current_day',
      'today_day',
      'day',
      'reward_day',
      'current_reward_day',
      'today_reward_day',
    ]));
    if (direct > 0) return direct.clamp(1, 7);
    final index = _earnDayRewards.indexWhere((day) => !_dayClaimed(day));
    return index < 0 ? 7 : index + 1;
  }

  int get _earnProgressSeconds {
    var foundSeconds = false;
    for (final key in const [
      'active_seconds_total',
      'active_seconds',
      'read_duration_seconds',
      'today_read_seconds',
      'progress_seconds',
      'current_seconds',
    ]) {
      final value = _deepField(_earnData, [key]);
      if (value == null) continue;
      foundSeconds = true;
      final seconds = _durationSeconds(value);
      if (seconds > 0) return seconds;
    }
    for (final key in const [
      'progress_minutes',
      'today_read_minutes',
      'read_minutes',
      'active_minutes',
    ]) {
      final minutes = _deepField(_earnData, [key]);
      if (minutes == null) continue;
      final value = _durationSeconds(minutes);
      if (value > 0) return value * 60;
    }
    if (foundSeconds) return 0;
    final progress = _int(_deepField(_earnData, const [
      'progress',
      'progress_percent',
      'today_progress',
      'total_progress',
    ]));
    if (progress <= 1) return progress * 900;
    if (progress <= 100) return (progress * 9).round();
    return progress;
  }

  String get _earnProgressText => _text(_deepField(_earnData, const [
        'read_duration_text',
        'progress_text',
        'progressText',
      ]));

  int get _earnTargetSeconds {
    final seconds = _int(_deepField(_earnData, const [
      'target_seconds',
      'required_seconds',
      'duration_seconds',
      'reader_target_seconds',
    ]));
    if (seconds > 0) return seconds;
    final minutes = _int(_deepField(_earnData, const [
      'target_minutes',
      'required_minutes',
      'duration_minutes',
      'reader_target_minutes',
    ]));
    return minutes > 0 ? minutes * 60 : 900;
  }

  int _dayNumber(Map<String, dynamic> day, int fallback) =>
      _int(_taskField(day, const [
                'day',
                'day_num',
                'dayNumber',
                'campaign_day',
                'reward_day',
                'day_index',
                'sort_index',
              ])) >
              0
          ? _int(_taskField(day, const [
              'day',
              'day_num',
              'dayNumber',
              'campaign_day',
              'reward_day',
              'day_index',
              'sort_index',
            ]))
          : fallback;

  int _dayReward(Map<String, dynamic> day) => _int(_taskField(day, const [
        'reward_amount',
        'rewardAmount',
        'reward_coin',
        'light_coin',
        'daily_coin',
        'today_coin',
        'today_reward_coin',
        'today_reward_amount',
        'daily_amount',
        'coin',
        'amount',
        'reward',
      ]));

  bool _dayClaimed(Map<String, dynamic> day) {
    final status = _taskField(day, const [
      'reward_status',
      'status',
      'claimed',
      'signed',
      'completed',
      'is_claimed',
      'taskClaimedToday',
      'task_claimed_today',
      'today_claimed',
      'today_reward_claimed',
      'isClaimedToday',
    ]);
    return _flag(status) ||
        _statusIs(status, const ['claimed', 'completed', 'signed', 'done']);
  }

  List<Map<String, dynamic>> _maps(dynamic value) {
    if (value is List) {
      final result = <Map<String, dynamic>>[];
      for (var index = 0; index < value.length; index++) {
        final item = value[index];
        if (item is Map) {
          result.add(Map<String, dynamic>.from(item));
        } else if (item is num || int.tryParse(item.toString()) != null) {
          result.add({'day': index + 1, 'reward_amount': _int(item)});
        }
      }
      return result;
    }
    if (value is Map) {
      final direct = Map<String, dynamic>.from(value);
      final hasDayFields = direct.keys.any((key) => const [
            'day',
            'day_num',
            'dayNumber',
            'reward_day',
            'reward_amount',
            'reward_coin',
            'daily_coin',
          ].contains(key));
      if (hasDayFields) return [direct];

      final result = <Map<String, dynamic>>[];
      for (final entry in direct.entries) {
        final digits = entry.key.replaceAll(RegExp(r'[^0-9]'), '');
        final day = int.tryParse(digits);
        if (day == null || day <= 0 || day > 7) continue;
        if (entry.value is Map) {
          final item = Map<String, dynamic>.from(entry.value as Map);
          item.putIfAbsent('day', () => day);
          result.add(item);
        } else if (entry.value is num ||
            int.tryParse(entry.value.toString()) != null) {
          result.add({'day': day, 'reward_amount': _int(entry.value)});
        }
      }
      return result;
    }
    return const [];
  }

  /// 官方福利模型会把阅读目标放在 reward_nodes/task_nodes 的子节点中，
  /// 这里只做只读字段搜索，不改变或合并服务器返回的数据。
  dynamic _deepField(dynamic value, List<String> keys, [int depth = 0]) {
    if (depth > 6) return null;
    if (value is Map) {
      for (final key in keys) {
        if (value.containsKey(key) && value[key] != null) return value[key];
      }
      for (final child in value.values) {
        final found = _deepField(child, keys, depth + 1);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final child in value) {
        final found = _deepField(child, keys, depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _listFor(
      Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final direct = _maps(data[key]);
      if (direct.isNotEmpty) return direct;
      final nested = _map(data[key]);
      if (nested != null) {
        for (final listKey in const ['list', 'items', 'data']) {
          final list = _maps(nested[listKey]);
          if (list.isNotEmpty) return list;
        }
        for (final listKey in const [
          'days',
          'day_list',
          'week_rewards',
          'week_plan',
          'reward_days',
          'reward_nodes',
          'rewardNodes',
          'reward_items',
          'rewardItems',
          'reward_list',
          'rewardList',
          'task_nodes',
          'taskNodes',
          'rewards',
          'reward',
          'daily_rewards',
          'daily_coin',
          'reward_amounts',
          'sign_days',
          'sign_day_list',
          'signDayList',
          'daily_all',
          'list',
          'items',
          'data',
        ]) {
          final list = _maps(nested[listKey]);
          if (list.isNotEmpty) return list;
        }
      }
    }
    return const [];
  }

  /// 福利接口不同版本会把任务放在 data/result/items 等多层结构中。
  /// 只收集带任务字段的对象，避免把签到天数或宝箱信息误当成任务。
  List<Map<String, dynamic>> _extractTasks(dynamic value) {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};

    void visit(dynamic node) {
      if (node is List) {
        for (final item in node) {
          visit(item);
        }
        return;
      }
      if (node is! Map) return;
      final map = Map<String, dynamic>.from(node);
      final shallowTitle = _text(map['task_title'] ??
              map['taskTitle'] ??
              map['title'] ??
              map['task_name'] ??
              map['name'])
          .trim();
      final shallowKey =
          _text(map['task_key'] ?? map['taskKey'] ?? map['key']).trim();
      final shallowId =
          _int(map['task_id'] ?? map['taskId'] ?? map['taskID'] ?? map['id']);
      final hasShallowMarker =
          shallowTitle.isNotEmpty && (shallowKey.isNotEmpty || shallowId > 0);

      if (hasShallowMarker) {
        final isSignTask = _isSignTask(map);
        if (!isSignTask && !_isEarnCoinTask(map)) {
          final identity =
              shallowKey.isNotEmpty ? shallowKey : '$shallowTitle:$shallowId';
          if (seen.add(identity)) result.add(map);
        }
        return;
      }

      for (final child in map.values) {
        visit(child);
      }
    }

    visit(value);
    return result;
  }

  Map<String, dynamic> _section(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = _map(data[key]);
      if (value != null) return value;
    }
    return const {};
  }

  dynamic _pick(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      if (data.containsKey(key) && data[key] != null) return data[key];
    }
    return null;
  }

  int _int(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _durationSeconds(dynamic value) {
    if (value is num) return value.round();
    if (value is Map) {
      final nested = _deepField(value, const [
        'seconds',
        'active_seconds',
        'read_duration_seconds',
        'value',
        'total_progress',
      ]);
      return nested == null ? 0 : _durationSeconds(nested);
    }
    final text = value?.toString().trim() ?? '';
    final clock = RegExp(r'^(\d+):(\d{1,2})(?::(\d{1,2}))?$').firstMatch(text);
    if (clock != null) {
      final first = int.tryParse(clock.group(1)!) ?? 0;
      final second = int.tryParse(clock.group(2)!) ?? 0;
      final third = int.tryParse(clock.group(3) ?? '') ?? 0;
      return clock.group(3) == null
          ? first * 60 + second
          : first * 3600 + second * 60 + third;
    }
    return int.tryParse(text) ?? double.tryParse(text)?.round() ?? 0;
  }

  String _text(dynamic value) => value?.toString() ?? '';

  bool _flag(dynamic value) {
    return value == true || value == 1 || value == '1' || value == 'true';
  }

  bool _statusIs(dynamic value, List<String> words) {
    final status = _text(value).toLowerCase();
    return words.any(status.contains);
  }

  int _coinBalance(Map<String, dynamic> root) {
    final wallet = _map(root['wallet']) ?? _map(root['balance']);
    final value = _pick(root, const [
      'coin_balance',
      'light_coin',
      'today_light_coin',
      'coins',
      'coin',
    ]);
    return _int(value ??
        _pick(wallet ?? const {}, const [
          'coin_balance',
          'light_coin',
          'coins',
          'coin',
        ]));
  }

  Map<String, dynamic> get _rootData => _root(_home ?? const {});

  Map<String, dynamic> get _sign {
    const keys = [
      'sign',
      'sign_module',
      'welfare_sign',
      'daily_sign',
      'seven_day_sign',
      'sign_7day',
      'new_user_7day_sign_v1',
      'sign_in',
      'free_sign',
      'data',
      'result',
      'detail',
    ];
    if (_signDetail.isNotEmpty) {
      final detail = _section(_signDetail, keys);
      if (detail.isNotEmpty) return detail;
      return _signDetail;
    }
    return _section(_rootData, keys);
  }

  List<Map<String, dynamic>> get _signDays {
    final days = _listFor(_sign, const [
      'days',
      'day_list',
      'week_rewards',
      'reward_days',
      'rewardDays',
      'reward_items',
      'rewardItems',
      'reward_list',
      'rewardList',
      'week_plan',
      'sign_days',
      'sign_day_list',
      'signDayList',
      'day_rewards',
      'rewards',
      'reward',
      'items',
      'daily_rewards',
      'daily_coin',
      'reward_amounts',
      'daily_all',
      'list',
    ]);
    return days.isNotEmpty ? days : _weekDayMaps(_sign);
  }

  List<Map<String, dynamic>> _weekDayMaps(dynamic value, [int depth = 0]) {
    if (depth > 5) return const [];
    if (value is Map) {
      final days = <Map<String, dynamic>>[];
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        final match = RegExp(r'(?:week[_-]?day|day)[_-]?(\d+)').firstMatch(key);
        if (match == null) continue;
        final day = int.tryParse(match.group(1) ?? '') ?? 0;
        if (day <= 0 || day > 7) continue;
        if (entry.value is Map) {
          final item = Map<String, dynamic>.from(entry.value as Map);
          item.putIfAbsent('day', () => day);
          days.add(item);
        } else if (entry.value is num ||
            int.tryParse(entry.value.toString()) != null) {
          days.add({'day': day, 'reward_amount': _int(entry.value)});
        }
      }
      if (days.isNotEmpty) {
        days.sort((a, b) => _dayNumber(a, 0).compareTo(_dayNumber(b, 0)));
        return days;
      }
      for (final child in value.values) {
        final nested = _weekDayMaps(child, depth + 1);
        if (nested.isNotEmpty) return nested;
      }
    } else if (value is List) {
      for (final child in value) {
        final nested = _weekDayMaps(child, depth + 1);
        if (nested.isNotEmpty) return nested;
      }
    }
    return const [];
  }

  int get _signCurrentDay {
    final direct = _int(_taskField(_sign, const [
      'campaign_day',
      'current_day',
      'today_day',
      'sign_day',
      'current_sign_day',
      'reward_day',
      'day',
    ]));
    if (direct > 0) return direct.clamp(1, 7);
    final index = _signDays.indexWhere((day) => !_dayClaimed(day));
    return index < 0 ? 7 : index + 1;
  }

  bool get _signed {
    final status = _text(_taskField(_sign, const [
      'sign_status',
      'signed_status',
      'status',
      'today_status',
    ])).toLowerCase();
    if (status == 'not_signed' || status == 'unsigned') return false;
    return _flag(_taskField(_sign, const [
          'signed',
          'is_signed',
          'signed_today',
          'today_claimed',
          'today_signed',
        ])) ||
        _statusIs(status, const ['signed', 'completed', 'claimed']);
  }

  bool _taskClaimed(Map<String, dynamic> task) {
    if (_isTaskClaimedToday(task)) return true;

    final btnText = _text(_taskField(
            task, const ['button_text', 'buttonText', 'btn_text', 'btnText']))
        .trim();
    if (btnText == '已领取' ||
        btnText == '今日已领取' ||
        btnText == '已完成' ||
        btnText == '今日已完成' ||
        btnText.contains('已领')) {
      return true;
    }

    final btnAction = _text(
            _taskField(task, const ['button_action', 'buttonAction', 'action']))
        .toLowerCase()
        .trim();
    if (btnAction == 'claimed' ||
        btnAction == 'received' ||
        btnAction == 'completed') {
      return true;
    }

    final rawStatus = _taskField(task, const [
      'status',
      'claim_status',
      'reward_status',
      'state',
      'task_status'
    ]);
    if (rawStatus != null) {
      final numStatus = int.tryParse(rawStatus.toString());
      if (numStatus == 2) return true;
    }

    final statusStr = _text(rawStatus).toLowerCase().replaceAll(' ', '_');
    if (statusStr == 'claimed' ||
        statusStr == 'received' ||
        statusStr == 'rewarded' ||
        statusStr == 'already_received' ||
        statusStr == 'has_received' ||
        statusStr == 'has_claimed') {
      return true;
    }

    return _deepState(
          task,
          flagKeys: const [
            'claimed',
            'is_claimed',
            'reward_claimed',
            'is_rewarded',
            'received',
            'is_received',
            'today_claimed',
            'today_reward_claimed',
            'taskClaimedToday',
            'task_claimed_today',
          ],
          statusKeys: const [
            'claim_status',
            'reward_status',
            'status',
            'reward_result',
          ],
          trueStatuses: const ['claimed', 'received', 'rewarded'],
          falseStatuses: const [
            'unclaimed',
            'not_claimed',
            'claimable',
            'in_progress',
            'pending',
          ],
        ) ==
        true;
  }

  bool _taskClaimable(Map<String, dynamic> task) {
    if (_taskClaimed(task)) return false;

    final btnText = _text(_taskField(
            task, const ['button_text', 'buttonText', 'btn_text', 'btnText']))
        .trim();
    if (btnText == '领取' ||
        btnText == '去领取' ||
        btnText == '可领取' ||
        btnText == '领取奖励') {
      return true;
    }

    final btnAction = _text(
            _taskField(task, const ['button_action', 'buttonAction', 'action']))
        .toLowerCase()
        .trim();
    if (btnAction == 'claim' || btnAction == 'receive') return true;

    final rawStatus = _taskField(task, const [
      'status',
      'claim_status',
      'reward_status',
      'state',
      'task_status'
    ]);
    if (rawStatus != null) {
      final numStatus = int.tryParse(rawStatus.toString());
      if (numStatus == 1) return true;
    }

    final statusStr = _text(rawStatus).toLowerCase().replaceAll(' ', '_');
    if (const [
      'claimable',
      'can_claim',
      'ready',
      'eligible',
      'completed',
      'finished',
      'done',
      'achieved'
    ].contains(statusStr)) {
      return true;
    }

    final state = _deepState(
      task,
      flagKeys: const [
        'claimable',
        'can_claim',
        'is_claimable',
        'eligible',
        'is_eligible',
        'completed',
        'is_completed',
        'finished',
        'is_finished',
        'done',
        'is_done',
        'achieved',
        'is_achieved',
        'taskCompletedToday',
        'task_completed_today',
        'taskClaimableToday',
        'task_claimable_today',
      ],
      statusKeys: const [
        'claim_status',
        'reward_status',
        'status',
        'reward_result',
      ],
      trueStatuses: const [
        'claimable',
        'can_claim',
        'ready',
        'eligible',
        'completed',
        'finished',
        'done',
        'achieved',
      ],
      falseStatuses: const [
        'claimed',
        'received',
        'in_progress',
        'pending',
        'not_ready',
        'not_eligible',
        'incomplete',
      ],
    );
    if (state != null) return state;
    return _taskProgressComplete(task);
  }

  _TaskItemStatus _taskStatus(Map<String, dynamic> task) {
    if (_taskClaimed(task)) return _TaskItemStatus.claimed;
    if (_taskClaimable(task)) return _TaskItemStatus.claimable;
    return _TaskItemStatus.actionable;
  }

  String _taskButtonText(Map<String, dynamic> task) {
    final status = _taskStatus(task);
    if (status == _TaskItemStatus.claimed) return '已领取';
    if (status == _TaskItemStatus.claimable) {
      final text =
          _text(_taskField(task, const ['button_text', 'buttonText'])).trim();
      return (text.isNotEmpty && text != '进行中') ? text : '领取';
    }
    // Actionable ("去完成")
    final text =
        _text(_taskField(task, const ['button_text', 'buttonText'])).trim();
    if (text.isNotEmpty && text != '进行中' && text != '未完成') {
      return text;
    }
    final title = _taskTitle(task);
    final type = _taskType(task);
    if (type.contains('read') ||
        title.contains('阅读') ||
        title.contains('小说') ||
        title.contains('看书')) {
      return '去阅读';
    }
    if (type.contains('share') || title.contains('分享')) {
      return '去分享';
    }
    if (type.contains('comment') ||
        title.contains('评论') ||
        title.contains('书评')) {
      return '去评论';
    }
    if (type.contains('collect') ||
        type.contains('favorite') ||
        type.contains('shelf') ||
        title.contains('收藏') ||
        title.contains('书架')) {
      return '去收藏';
    }
    if (type.contains('browse') ||
        title.contains('浏览') ||
        title.contains('发现') ||
        title.contains('逛')) {
      return '去浏览';
    }
    return '去完成';
  }

  int _taskOrderWeight(Map<String, dynamic> task) {
    final status = _taskStatus(task);
    switch (status) {
      case _TaskItemStatus.claimable:
        return 0; // 可领取置顶
      case _TaskItemStatus.actionable:
        return 1; // 进行中/去完成居中
      case _TaskItemStatus.claimed:
        return 2; // 已领取下沉
    }
  }

  List<Map<String, dynamic>> _orderTasks(List<Map<String, dynamic>> tasks) {
    final list = List<Map<String, dynamic>>.from(tasks);
    list.sort((a, b) {
      final weightA = _taskOrderWeight(a);
      final weightB = _taskOrderWeight(b);
      if (weightA != weightB) return weightA.compareTo(weightB);
      return _taskId(a).compareTo(_taskId(b));
    });
    return list;
  }

  IconData _taskIcon(Map<String, dynamic> task) {
    final type = _taskType(task);
    final title = _taskTitle(task);
    if (type.contains('read') || title.contains('阅读') || title.contains('看书')) {
      return Icons.menu_book_rounded;
    }
    if (type.contains('share') || title.contains('分享')) {
      return Icons.share_rounded;
    }
    if (type.contains('comment') ||
        title.contains('评论') ||
        title.contains('书评')) {
      return Icons.chat_bubble_outline_rounded;
    }
    if (type.contains('collect') ||
        type.contains('favorite') ||
        type.contains('shelf') ||
        title.contains('收藏') ||
        title.contains('书架')) {
      return Icons.bookmark_added_outlined;
    }
    if (type.contains('browse') ||
        title.contains('浏览') ||
        title.contains('作品')) {
      return Icons.explore_outlined;
    }
    if (type.contains('sign') || title.contains('签到')) {
      return Icons.event_available_rounded;
    }
    return Icons.task_alt_rounded;
  }

  Future<void> _openTaskTarget(Map<String, dynamic> task) async {
    final jumpUrl = _text(_deepField(task, const [
      'jump_url',
      'jumpUrl',
      'target_url',
      'targetUrl',
      'url',
      'link'
    ])).trim();
    final jumpType =
        _text(_deepField(task, const ['jump_type', 'jumpType', 'type']))
            .toLowerCase()
            .trim();
    final taskKey = _taskKey(task).toLowerCase();
    final title = _taskTitle(task);

    // 1. 浏览与收藏作品任务：进入对应书籍详情或搜索选书
    if (_isBrowseWorkTask(task) ||
        _isCollectWorkTask(task) ||
        jumpType == 'browse' ||
        jumpType == 'collect' ||
        jumpType == 'favorite' ||
        jumpType == 'shelf' ||
        title.contains('浏览') ||
        title.contains('收藏') ||
        title.contains('作品') ||
        title.contains('书架')) {
      final bookId = _int(_deepField(
          task, const ['book_id', 'bookId', 'target_id', 'targetId']));
      if (bookId > 0) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => BookDetailPage(bookId: bookId)),
        );
      } else {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SearchPage()),
        );
      }
      if (mounted) _load();
      return;
    }

    // 2. 如果有明确的外部或应用链接
    if (jumpUrl.isNotEmpty) {
      final uri = Uri.tryParse(jumpUrl);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
        if (mounted) _load();
        return;
      }
    }

    // 2. 阅读类任务：进入阅读器或小说详情
    if (jumpType == 'reader' ||
        taskKey.contains('read') ||
        title.contains('阅读') ||
        title.contains('看书') ||
        title.contains('小说') ||
        title.contains('章节')) {
      final snapshot = LKReadingSession.shared.snapshot();
      final bookId = snapshot?.bookId ??
          _int(_deepField(
              task, const ['book_id', 'bookId', 'target_id', 'targetId']));
      if (bookId > 0) {
        if (snapshot != null &&
            snapshot.bookId == bookId &&
            snapshot.chapterId > 0 &&
            snapshot.volumeId > 0) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ReaderPage(
                bookId: snapshot.bookId,
                bookTitle: '最近阅读',
                chapterId: snapshot.chapterId,
                chapterTitle: '',
                volumeId: snapshot.volumeId,
              ),
            ),
          );
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BookDetailPage(bookId: bookId),
            ),
          );
        }
      } else {
        if (Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      }
      if (mounted) _load();
      return;
    }

    // 3. 浏览/找书类任务：进入书籍详情或搜索页
    if (jumpType == 'browse' ||
        jumpType == 'book' ||
        taskKey.contains('browse') ||
        title.contains('浏览') ||
        title.contains('作品') ||
        title.contains('找书')) {
      final bookId = _int(_deepField(
          task, const ['book_id', 'bookId', 'target_id', 'targetId']));
      if (bookId > 0) {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => BookDetailPage(bookId: bookId)),
        );
      } else {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SearchPage()),
        );
      }
      if (mounted) _load();
      return;
    }

    // 4. 动态/社区/评论类任务：进入动态广场
    if (jumpType == 'dynamic' ||
        jumpType == 'comment' ||
        taskKey.contains('comment') ||
        taskKey.contains('dynamic') ||
        title.contains('动态') ||
        title.contains('评论') ||
        title.contains('书评')) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DynamicPage()),
      );
      if (mounted) _load();
      return;
    }

    // 5. 分享类任务提示
    if (jumpType == 'share' ||
        taskKey.contains('share') ||
        title.contains('分享')) {
      showLkError(context, '请在小说详情页或阅读器中点击右上角进行分享');
      return;
    }

    // 6. 签到类任务
    if (taskKey.contains('sign') || title.contains('签到')) {
      if (!_signed) {
        await _claimSign();
      } else {
        showLkError(context, '今日已签到');
      }
      return;
    }

    showLkError(context, '请完成对应任务后返回领取奖励');
  }

  bool _taskProgressComplete(Map<String, dynamic> task) {
    final current = _int(_deepField(task, const [
      'progress',
      'current_progress',
      'currentProgress',
      'current',
      'current_count',
      'progress_count',
      'completed_count',
      'count',
      'value',
    ]));
    final total = _int(_deepField(task, const [
      'total',
      'total_progress',
      'totalProgress',
      'target',
      'required',
      'goal',
      'need',
      'target_count',
      'required_count',
    ]));
    if (total > 0 && current >= total) return true;
    final percent = _int(_deepField(task, const [
      'progress_percent',
      'progressPercentage',
      'completion_percent',
    ]));
    return percent >= 100;
  }

  bool? _deepState(
    dynamic value, {
    required List<String> flagKeys,
    required List<String> statusKeys,
    required List<String> trueStatuses,
    required List<String> falseStatuses,
  }) {
    int visit(dynamic node) {
      var result = -1;
      if (node is Map) {
        final map = Map<String, dynamic>.from(node);
        for (final key in flagKeys) {
          if (!map.containsKey(key)) continue;
          final parsed = _parseFlag(map[key]);
          if (parsed == true) return 1;
          if (parsed == false) result = 0;
        }
        for (final key in statusKeys) {
          if (!map.containsKey(key)) continue;
          final status = _statusState(map[key],
              trueStatuses: trueStatuses, falseStatuses: falseStatuses);
          if (status == true) return 1;
          if (status == false) result = 0;
        }
        for (final child in map.values) {
          final nested = visit(child);
          if (nested == 1) return 1;
          if (nested == 0) result = 0;
        }
      } else if (node is List) {
        for (final child in node) {
          final nested = visit(child);
          if (nested == 1) return 1;
          if (nested == 0) result = 0;
        }
      }
      return result;
    }

    final result = visit(value);
    return result < 0 ? null : result == 1;
  }

  bool? _statusState(dynamic value,
      {required List<String> trueStatuses,
      required List<String> falseStatuses}) {
    final status = _text(value).toLowerCase().replaceAll(' ', '_');
    if (status.isEmpty) return null;
    if (falseStatuses.any(status.contains)) return false;
    if (trueStatuses.any(status.contains)) return true;
    return null;
  }

  bool? _parseFlag(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = _text(value).toLowerCase();
    if (const ['1', 'true', 'yes', 'y', '是'].contains(text)) return true;
    if (const ['0', 'false', 'no', 'n', '否'].contains(text)) return false;
    return null;
  }

  String _taskTitle(Map<String, dynamic> task) => _text(_deepField(task, const [
        'task_title',
        'taskTitle',
        'task_name',
        'title',
        'name',
      ]));

  String _displayTaskTitle(String title) {
    final normalized = title.replaceAll(RegExp(r'\s+'), '');
    if (normalized == '其它任务' ||
        normalized == '其他任务' ||
        normalized == '浏览' ||
        normalized == '浏览作品' ||
        normalized == '浏览一个作品' ||
        (normalized.contains('浏览') && !normalized.contains('网'))) {
      return '浏览一个作品';
    }
    if (normalized == '收藏' ||
        normalized == '收藏作品' ||
        normalized == '加入书架' ||
        normalized == '收藏一个作品' ||
        normalized.contains('收藏')) {
      return '收藏一个作品';
    }
    return title;
  }

  String _taskDescription(Map<String, dynamic> task) {
    final customDesc = _text(_deepField(task,
        const ['task_desc', 'taskDesc', 'description', 'desc', 'subtitle']));
    if (customDesc.isNotEmpty && !_isInvalidTestTask(task)) {
      return customDesc;
    }
    if (_isBrowseWorkTask(task)) {
      return '浏览一部感兴趣的作品';
    }
    if (_isCollectWorkTask(task)) {
      return '收藏一部喜欢的作品到书架';
    }
    return customDesc;
  }

  int _taskReward(Map<String, dynamic> task) => _int(_deepField(task, const [
        'reward_amount',
        'rewardAmount',
        'reward_coin',
        'reward',
      ]));

  String _rewardText(int reward) => reward > 0 ? '+$reward 轻币' : '轻币奖励';

  @override
  Widget build(BuildContext context) {
    final animateSkeleton = _loading &&
        _home == null &&
        _error == null &&
        LKClient.shared.session.isLoggedIn &&
        !AppMotion.isDisabled(context);
    if (animateSkeleton != _animController.isAnimating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (animateSkeleton && _loading && _home == null && _error == null) {
          _animController.repeat(reverse: true);
        } else {
          _animController.stop();
        }
      });
    }
    if (!LKClient.shared.session.isLoggedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务中心')),
        body: const Center(child: Text('登录后才能使用任务中心')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('任务中心')),
      body: MotionRefreshIndicator(
        onRefresh: _load,
        child: _loading && _home == null
            ? _buildWelfareSkeleton(context)
            : _error != null && _home == null
                ? _buildErrorView(context)
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                        12, 12, 12, 24 + MediaQuery.paddingOf(context).bottom),
                    children: [
                      _buildBalanceCard(_rootData),
                      const SizedBox(height: 10),
                      _buildSignCard(),
                      if (_earnData.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _buildEarnCoinCard(),
                      ],
                      if (_sleepData.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        ValueListenableBuilder<int>(
                          valueListenable: _sleepClock,
                          builder: (_, __, ___) => _buildSleepCard(),
                        ),
                      ],
                      if (_displayTasks.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _buildTaskCard(),
                      ],
                      if (kDebugMode && _enableWelfareProtocolProbe) ...[
                        const SizedBox(height: 10),
                        _buildServerValidationCard(),
                      ],
                      const SizedBox(height: 12),
                      Text('奖励以站点实际返回结果为准',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 12)),
                    ],
                  ),
      ),
    );
  }

  Widget _buildBalanceCard(Map<String, dynamic> root) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(Icons.monetization_on_outlined,
                color: scheme.onPrimaryContainer, size: 32),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前轻币',
                    style: TextStyle(color: scheme.onPrimaryContainer)),
                const SizedBox(height: 3),
                Text('${_coinBalance(root)}',
                    style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const WelfareCoinRecordsPage()),
              ),
              child: const Text('轻币记录'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSignCard() {
    final days = _signDays;
    final currentDay = _signCurrentDay;
    final signed = _signed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                    child: Text('每日签到',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold))),
                FilledButton.tonal(
                  onPressed: signed || _action == 'sign' ? null : _claimSign,
                  child: Text(signed
                      ? '今日已签到'
                      : _action == 'sign'
                          ? '处理中'
                          : '签到'),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text('每日签到可获得对应轻币奖励',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12)),
            if (days.isNotEmpty) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 70,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: days.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, index) {
                    final day = days[index];
                    final claimed = _dayClaimed(day);
                    final reward = _dayReward(day);
                    final dayNo = _dayNumber(day, index + 1);
                    final active = dayNo == currentDay;
                    return Container(
                      width: 72,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 7),
                      decoration: BoxDecoration(
                        color: claimed || active
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                        border: active
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary)
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('第$dayNo天',
                              style: const TextStyle(fontSize: 11)),
                          const SizedBox(height: 3),
                          Text(reward > 0 ? '+$reward' : '—',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 1),
                          Text(claimed ? '已签到' : '轻币',
                              style: const TextStyle(fontSize: 10)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEarnCoinCard() {
    final target = _earnTargetSeconds;
    final progress = (_earnProgressSeconds / target).clamp(0.0, 1.0);
    final rewards = _earnDayRewards;
    final currentDay = _earnCurrentDay;
    final claimed = _earnClaimed;
    final claimable = _earnClaimable;
    final progressMinutes = _earnProgressSeconds ~/ 60;
    final targetMinutes = (target / 60).ceil();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('15分钟阅读',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                ),
                FilledButton.tonal(
                  onPressed: !claimable || _action == 'earn-coin'
                      ? null
                      : _claimEarnCoin,
                  child: Text(claimed
                      ? '今日已领取'
                      : _action == 'earn-coin'
                          ? '处理中'
                          : claimable
                              ? '领取'
                              : '未达标'),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text('每天阅读15分钟可获得对应轻币奖励',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12)),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress, minHeight: 7),
            const SizedBox(height: 6),
            Text(
                _earnProgressText.isNotEmpty
                    ? '今日阅读 $_earnProgressText'
                    : '今日阅读 $progressMinutes / $targetMinutes 分钟',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12)),
            if (rewards.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 70,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: rewards.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, index) {
                    final day = rewards[index];
                    final dayNo = _dayNumber(day, index + 1);
                    final dayClaimed = _dayClaimed(day);
                    final active = dayNo == currentDay;
                    return Container(
                      width: 72,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 7),
                      decoration: BoxDecoration(
                        color: dayClaimed || active
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                        border: active
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary)
                            : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('第$dayNo天',
                              style: const TextStyle(fontSize: 11)),
                          const SizedBox(height: 3),
                          Text('+${_dayReward(day)}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 1),
                          Text(dayClaimed ? '已领取' : '轻币',
                              style: const TextStyle(fontSize: 10)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSleepCard() {
    final claimed = _sleepClaimed;
    final claimable = _sleepClaimable;
    final started = _sleepStarted;
    final reward = _taskReward(_sleepData);
    final action = claimed
        ? ''
        : claimable
            ? 'sleep-claim'
            : started
                ? ''
                : 'sleep-start';
    final buttonText = claimed
        ? '今日已领取'
        : claimable
            ? '领取奖励'
            : started
                ? (_sleepButtonText.isEmpty ? '睡觉中' : _sleepButtonText)
                : (_sleepButtonText.isEmpty ? '开始睡觉' : _sleepButtonText);
    final description = _sleepDescription.isNotEmpty
        ? _sleepDescription
        : claimed
            ? '今日睡眠奖励已领取'
            : started
                ? '已开始睡觉，等待服务器开放领取'
                : '开始后由服务器计时，到时间即可领取奖励';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                      Theme.of(context).colorScheme.primaryContainer,
                  child: Icon(
                    claimed ? Icons.check : Icons.bedtime_outlined,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('睡觉赚轻币',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.bold)),
                      if (reward > 0)
                        Text(_rewardText(reward),
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 12)),
                    ],
                  ),
                ),
                FilledButton.tonal(
                  onPressed: action.isEmpty || _action.isNotEmpty
                      ? null
                      : action == 'sleep-claim'
                          ? _claimSleep
                          : _startSleep,
                  child: Text(_action == action && action.isNotEmpty
                      ? '处理中'
                      : buttonText),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(description,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13)),
            if (_sleepCountdown.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('倒计时：$_sleepCountdown',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
            if (_sleepClaimAt.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text('领取时间：$_sleepClaimAt',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWelfareSkeleton(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AnimatedBuilder(
      animation: _animController,
      builder: (context, _) {
        final alpha = 0.28 + _animController.value * 0.42;
        final shimmerColor =
            scheme.surfaceContainerHighest.withValues(alpha: alpha);

        return ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
              12, 12, 12, 24 + MediaQuery.paddingOf(context).bottom),
          children: [
            // Balance card skeleton
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                          color: shimmerColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                            width: 60,
                            height: 14,
                            decoration: BoxDecoration(
                                color: shimmerColor,
                                borderRadius: BorderRadius.circular(4))),
                        const SizedBox(height: 8),
                        Container(
                            width: 90,
                            height: 22,
                            decoration: BoxDecoration(
                                color: shimmerColor,
                                borderRadius: BorderRadius.circular(6))),
                      ],
                    ),
                    const Spacer(),
                    Container(
                        width: 68,
                        height: 32,
                        decoration: BoxDecoration(
                            color: shimmerColor,
                            borderRadius: BorderRadius.circular(16))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Sign in card skeleton
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                            width: 90,
                            height: 18,
                            decoration: BoxDecoration(
                                color: shimmerColor,
                                borderRadius: BorderRadius.circular(4))),
                        Container(
                            width: 76,
                            height: 32,
                            decoration: BoxDecoration(
                                color: shimmerColor,
                                borderRadius: BorderRadius.circular(16))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                        width: 160,
                        height: 12,
                        decoration: BoxDecoration(
                            color: shimmerColor,
                            borderRadius: BorderRadius.circular(4))),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 70,
                      child: Row(
                        children: List.generate(
                          5,
                          (i) => Expanded(
                            child: Container(
                              margin: EdgeInsets.only(right: i < 4 ? 8 : 0),
                              decoration: BoxDecoration(
                                  color: shimmerColor,
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            // 15-min reading skeleton
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                            width: 100,
                            height: 18,
                            decoration: BoxDecoration(
                                color: shimmerColor,
                                borderRadius: BorderRadius.circular(4))),
                        Container(
                            width: 76,
                            height: 32,
                            decoration: BoxDecoration(
                                color: shimmerColor,
                                borderRadius: BorderRadius.circular(16))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                        width: double.infinity,
                        height: 8,
                        decoration: BoxDecoration(
                            color: shimmerColor,
                            borderRadius: BorderRadius.circular(4))),
                    const SizedBox(height: 8),
                    Container(
                        width: 120,
                        height: 12,
                        decoration: BoxDecoration(
                            color: shimmerColor,
                            borderRadius: BorderRadius.circular(4))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Task list skeleton
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                        width: 80,
                        height: 18,
                        decoration: BoxDecoration(
                            color: shimmerColor,
                            borderRadius: BorderRadius.circular(4))),
                    const SizedBox(height: 12),
                    for (int i = 0; i < 3; i++) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                    color: shimmerColor,
                                    shape: BoxShape.circle)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                      width: 110,
                                      height: 14,
                                      decoration: BoxDecoration(
                                          color: shimmerColor,
                                          borderRadius:
                                              BorderRadius.circular(4))),
                                  const SizedBox(height: 6),
                                  Container(
                                      width: 150,
                                      height: 11,
                                      decoration: BoxDecoration(
                                          color: shimmerColor,
                                          borderRadius:
                                              BorderRadius.circular(4))),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Container(
                                width: 68,
                                height: 32,
                                decoration: BoxDecoration(
                                    color: shimmerColor,
                                    borderRadius: BorderRadius.circular(16))),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildErrorView(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.wifi_off_rounded,
                        size: 36, color: scheme.error),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '连接失败，请检查网络连接',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: scheme.onSurface),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '暂时无法获取任务数据，请确认网络后重试',
                    style:
                        TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.tonalIcon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重新加载'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTaskCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('任务奖励',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            for (final task in _displayTasks) _buildTaskTile(task),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskTile(Map<String, dynamic> task) {
    final title = _displayTaskTitle(_taskTitle(task));
    final description = _taskDescription(task);
    final status = _taskStatus(task);
    final claimed = status == _TaskItemStatus.claimed;
    final claimable = status == _TaskItemStatus.claimable;
    final taskId = _taskId(task);
    final taskKey = _taskKey(task);
    final key = 'task:$taskId:$taskKey';
    final progress = _int(_taskField(task, const ['progress', 'current']));
    final total = _int(_taskField(task, const ['total', 'target', 'required']));
    final reward = _taskReward(task);
    final btnText = _taskButtonText(task);

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: claimable
              ? Border.all(
                  color: scheme.primary.withValues(alpha: 0.5), width: 1.2)
              : null,
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 19,
              backgroundColor: claimed
                  ? scheme.surfaceContainerHighest
                  : claimable
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHigh,
              child: Icon(
                claimed
                    ? Icons.check_circle_rounded
                    : claimable
                        ? Icons.card_giftcard_rounded
                        : _taskIcon(task),
                size: 20,
                color: claimed
                    ? scheme.outline
                    : claimable
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title.isEmpty ? '每日任务' : title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: claimed ? scheme.outline : scheme.onSurface,
                            decoration:
                                claimed ? TextDecoration.lineThrough : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (reward > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '+$reward 轻币',
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description.isNotEmpty
                        ? description
                        : (total > 0 ? '完成进度 $progress / $total' : '完成任务领取奖励'),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (total > 0 && !claimed) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (progress / total).clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: scheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation(
                          claimable ? scheme.primary : scheme.outlineVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            _buildTaskActionButton(
              task: task,
              status: status,
              btnText: btnText,
              keyStr: key,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskActionButton({
    required Map<String, dynamic> task,
    required _TaskItemStatus status,
    required String btnText,
    required String keyStr,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isActing = _action == keyStr;

    switch (status) {
      case _TaskItemStatus.claimable:
        return FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
            minimumSize: const Size(68, 34),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
          ),
          onPressed:
              isActing || _action.isNotEmpty ? null : () => _claimTask(task),
          child: Text(isActing ? '领取中' : btnText,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        );
      case _TaskItemStatus.actionable:
        return FilledButton.tonal(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
            minimumSize: const Size(68, 34),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
          ),
          onPressed: isActing || _action.isNotEmpty
              ? null
              : () => _openTaskTarget(task),
          child: Text(btnText, style: const TextStyle(fontSize: 13)),
        );
      case _TaskItemStatus.claimed:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_rounded, size: 14, color: scheme.outline),
              const SizedBox(width: 2),
              Text(
                '已领取',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildServerValidationCard() {
    final snapshot = LKReadingSession.shared.snapshot();
    final hasSession = snapshot != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('服务器验证（调试）',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            Text(
              hasSession
                  ? '使用最近一次真实阅读会话：已阅读 ${snapshot.readDurationSeconds} 秒，进度 ${snapshot.progressPercent}%'
                  : '请先登录并打开一本小说阅读，返回后再测试。',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: hasSession && _action.isEmpty
                      ? _reportRealReadingSession
                      : null,
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: const Text('验证阅读报告'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      hasSession && _action.isEmpty ? _verifyShelfSync : null,
                  icon: const Icon(Icons.bookmark_outline, size: 18),
                  label: const Text('验证书架同步'),
                ),
                OutlinedButton.icon(
                  onPressed: hasSession && _action.isEmpty
                      ? _reportFifteenMinuteProbe
                      : null,
                  icon: const Icon(Icons.science_outlined, size: 18),
                  label: const Text('协议测试：15分钟'),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text('仅本地调试探针显示；不自动领取轻币，书架测试会临时添加后恢复原状态。',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Future<void> _reportRealReadingSession() async {
    final snapshot = LKReadingSession.shared.snapshot();
    if (snapshot == null || _action.isNotEmpty) return;
    if (snapshot.readDurationSeconds < 1) {
      if (mounted) showLkError(context, '阅读时间不足，暂时无法上报');
      return;
    }
    setState(() => _action = 'reading-report');
    try {
      final report = await LKApi.reportReadingProgress(
        bookId: snapshot.bookId,
        volumeId: snapshot.volumeId,
        chapterId: snapshot.chapterId,
        progressPercent: snapshot.progressPercent,
        readDurationSeconds: snapshot.readDurationSeconds,
        activeSecondsDelta: snapshot.readDurationSeconds > 300
            ? 300
            : snapshot.readDurationSeconds,
      );
      Map<String, dynamic>? detail;
      try {
        detail = await LKApi.welfareEarnCoinDetail();
      } catch (_) {
        // 报告成功但奖励状态查询失败时，仍展示报告结果。
      }
      if (!mounted) return;
      final taskKey = _text(_pick(report, const ['task_key', 'taskKey']));
      if (detail != null || taskKey.isNotEmpty) {
        setState(() {
          if (detail != null) _earnCoin = detail;
          if (taskKey.isNotEmpty) {
            _earnCoin = {..._earnCoin, 'task_key': taskKey};
          }
        });
      }
      final claimable = _flag(_pick(detail ?? const {}, const [
            'claimable',
            'can_claim',
            'is_claimable',
          ])) ||
          _statusIs(
              _pick(detail ?? const {}, const ['status', 'reward_status']),
              const ['claimable', 'ready']);
      await _showDiagnostic(
        '阅读报告已被服务器接受',
        [
          '服务器已收到真实阅读数据。',
          if (taskKey.isNotEmpty) '任务标识：$taskKey',
          if (detail != null) claimable ? '当前状态：有可领取奖励' : '当前状态：暂未达到领取条件',
          if (detail == null) '奖励状态：查询失败，请稍后刷新任务中心',
        ],
      );
    } catch (e) {
      if (mounted) await _showDiagnostic('阅读报告被服务器拒绝', [_errorText(e)]);
    } finally {
      if (mounted) setState(() => _action = '');
    }
  }

  /// 本地协议测试：沿用当前真实书籍、章节和进度，只将时长固定为官方
  /// 约定的 15 分钟测试值。入口需要显式 dart-define，且不触发领取。
  Future<void> _reportFifteenMinuteProbe() async {
    final snapshot = LKReadingSession.shared.snapshot();
    if (snapshot == null || _action.isNotEmpty) return;
    setState(() => _action = 'reading-probe');
    try {
      final report = await LKApi.reportReadingProgress(
        bookId: snapshot.bookId,
        volumeId: snapshot.volumeId,
        chapterId: snapshot.chapterId,
        progressPercent: snapshot.progressPercent,
        readDurationSeconds: 900,
        // active_seconds_delta 是单次心跳增量，服务器限制最大 300 秒；
        // 总计 15 分钟仍由 read_duration_seconds 表示。
        activeSecondsDelta: 300,
      );
      Map<String, dynamic>? detail;
      try {
        detail = await LKApi.welfareEarnCoinDetail();
      } catch (_) {}
      if (!mounted) return;
      final taskKey = _text(_pick(report, const ['task_key', 'taskKey']));
      if (detail != null || taskKey.isNotEmpty) {
        setState(() {
          if (detail != null) _earnCoin = detail;
          if (taskKey.isNotEmpty) {
            _earnCoin = {..._earnCoin, 'task_key': taskKey};
          }
        });
      }
      final claimable = _flag(_pick(detail ?? const {}, const [
            'claimable',
            'can_claim',
            'is_claimable',
          ])) ||
          _statusIs(
              _pick(detail ?? const {}, const ['status', 'reward_status']),
              const ['claimable', 'ready']);
      await _showDiagnostic(
        '15分钟协议测试已返回',
        [
          '服务器已接受报告请求。',
          if (taskKey.isNotEmpty) '任务标识：$taskKey',
          if (detail != null) claimable ? '当前状态：有可领取奖励' : '当前状态：暂未达到领取条件',
          if (detail == null) '奖励状态：查询失败，请稍后刷新任务中心',
          '本次未调用领取接口。',
        ],
      );
    } catch (e) {
      if (mounted) await _showDiagnostic('15分钟协议测试被服务器拒绝', [_errorText(e)]);
    } finally {
      if (mounted) setState(() => _action = '');
    }
  }

  Future<void> _verifyShelfSync() async {
    final snapshot = LKReadingSession.shared.snapshot();
    if (snapshot == null || _action.isNotEmpty) return;
    setState(() => _action = 'shelf-sync');
    try {
      final before = await LKApi.inShelf(snapshot.bookId);
      await LKApi.toggleShelf(snapshot.bookId, true);
      final afterAdd = await LKApi.inShelf(snapshot.bookId);
      var restored = true;
      if (!before) {
        await LKApi.toggleShelf(snapshot.bookId, false);
        restored = !(await LKApi.inShelf(snapshot.bookId));
      }
      if (!mounted) return;
      await _showDiagnostic(
        afterAdd ? '书架同步验证通过' : '服务器未确认加入书架',
        [
          '加入前：${before ? '已在书架' : '不在书架'}',
          '加入后：${afterAdd ? '已在书架' : '未在书架'}',
          if (!before) '恢复原状态：${restored ? '成功' : '失败'}',
        ],
      );
    } catch (e) {
      if (mounted) await _showDiagnostic('书架操作被服务器拒绝', [_errorText(e)]);
    } finally {
      if (mounted) setState(() => _action = '');
    }
  }

  Future<void> _showDiagnostic(String title, List<String> lines) async {
    await showDialog<void>(
      animationStyle: AppMotion.style(context),
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(lines.join('\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  String _errorText(Object error) =>
      error is LKException ? '${error.message}（错误码 ${error.code}）' : '$error';
}

class WelfareCoinRecordsPage extends StatelessWidget {
  const WelfareCoinRecordsPage({super.key});

  @override
  Widget build(BuildContext context) => AccountScope(
        title: '轻币记录',
        builder: (_) => const _WelfareCoinRecordsPageBody(),
      );
}

class _WelfareCoinRecordsPageBody extends StatefulWidget {
  const _WelfareCoinRecordsPageBody();

  @override
  State<_WelfareCoinRecordsPageBody> createState() =>
      _WelfareCoinRecordsPageState();
}

class _WelfareCoinRecordsPageState extends State<_WelfareCoinRecordsPageBody> {
  final _session = SessionStamp();
  final _records = <Map<String, dynamic>>[];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    if (!_session.isCurrent || _loading || append && !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await LKApi.welfareCoinRecords(append ? _page + 1 : 1);
      final raw = data['list'] ??
          data['records'] ??
          data['items'] ??
          data['free_coin_records_list'] ??
          const [];
      final items = raw is List
          ? raw
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : const <Map<String, dynamic>>[];
      final pageInfo = data['page_info'] is Map
          ? Map<String, dynamic>.from(data['page_info'] as Map)
          : const <String, dynamic>{};
      final rawMore = pageInfo['has_more'] ??
          pageInfo['hasMore'] ??
          data['has_more'] ??
          data['hasMore'];
      if (!mounted || !_session.isCurrent) return;
      setState(() {
        if (!append) _records.clear();
        _records.addAll(items);
        _page = append ? _page + 1 : 1;
        _hasMore = items.isNotEmpty &&
            (rawMore == null
                ? items.length >= 30
                : rawMore == true || rawMore == 1 || rawMore == '1');
        _error = null;
      });
    } catch (e) {
      if (mounted && _session.isCurrent) setState(() => _error = e.toString());
    } finally {
      if (mounted && _session.isCurrent) setState(() => _loading = false);
    }
  }

  String _text(dynamic value) => value?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('轻币记录')),
      body: MotionRefreshIndicator(
        onRefresh: _load,
        child: _records.isEmpty && _loading
            ? const ScrollableStatus(child: LkLoadingIndicator())
            : _records.isEmpty
                ? ScrollableStatus(
                    child: _error != null
                        ? FilledButton.tonal(
                            onPressed: _load, child: const Text('加载失败，点击重试'))
                        : const Text('暂无轻币记录'))
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _records.length + (_hasMore ? 1 : 0),
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      if (index == _records.length) {
                        if (_error != null) {
                          return Center(
                              child: TextButton(
                            onPressed: () => _load(append: true),
                            child: const Text('加载失败，点击重试'),
                          ));
                        }
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _session.isCurrent && !_loading) {
                            _load(append: true);
                          }
                        });
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: LkLoadingIndicator()),
                        );
                      }
                      final record = _records[index];
                      final amount = record['amount'] ??
                          record['coin'] ??
                          record['light_coin'] ??
                          record['reward_amount'] ??
                          '';
                      final title = _text(record['title'] ??
                          record['name'] ??
                          record['reason'] ??
                          record['description'] ??
                          '轻币变动');
                      final time = _text(record['created_at'] ??
                          record['time'] ??
                          record['record_time'] ??
                          '');
                      return ListTile(
                        leading: Icon(
                          _text(amount).startsWith('-')
                              ? Icons.remove_circle_outline
                              : Icons.add_circle_outline,
                          color: _text(amount).startsWith('-')
                              ? Colors.orange
                              : Colors.green,
                        ),
                        title: Text(title),
                        subtitle: time.isEmpty ? null : Text(time),
                        trailing: Text(_text(amount)),
                      );
                    },
                  ),
      ),
    );
  }
}
