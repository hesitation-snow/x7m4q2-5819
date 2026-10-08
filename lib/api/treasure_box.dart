import 'lk_api.dart';
import 'lk_client.dart';

Map<String, dynamic> _map(Object? value) => value is Map
    ? Map<String, dynamic>.from(value)
    : <String, dynamic>{};

int _number(Object? value) => int.tryParse('$value') ?? 0;
int? _nullableNumber(Object? value) {
  if (value == null || '$value'.isEmpty) return null;
  return int.tryParse('$value');
}

bool _flag(Object? value) =>
    value == true || value == 1 || value == '1' || value == 'true';

bool? _nullableFlag(Object? value) {
  if (value == null) return null;
  if (_flag(value)) return true;
  if (value == false || value == 0 || value == '0' || value == 'false') {
    return false;
  }
  return null;
}

DateTime? _parseTime(dynamic value) {
  if (value == null || '$value'.isEmpty || '$value' == '0') return null;
  final number = num.tryParse('$value');
  if (number != null) {
    if (!number.isFinite || number <= 0 || number > 8640000000000) {
      return null;
    }
    final milliseconds = number < 100000000000 ? number * 1000 : number;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt(), isUtc: true)
        .toLocal();
  }
  return DateTime.tryParse('$value')?.toLocal();
}

enum TreasureBoxState {
  claimed,
  waiting,
  ready,
  prerequisite,
  unknown,
}

class TreasureBoxApi {
  static String? _discoveredAction;

  static void resetDiscoveredActionForTesting() {
    _discoveredAction = null;
  }

  static String? get discoveredAction => _discoveredAction;

  static Future<TreasureBoxDetail> load() async => TreasureBoxDetail.fromMap(
        await LKApi.welfareTreasureBoxDetail(),
      );

  static Future<Map<String, dynamic>> claim(TreasureBoxItem box) async =>
      LKApi.claimWelfareTreasureBox(
        boxIndex: box.boxIndex > 0 ? box.boxIndex : null,
        campaignId: box.campaignId,
        campaignDay: box.campaignDay,
        taskId: box.taskId,
        taskKey: box.taskKey,
      );

  static Future<Map<String, dynamic>> reportProgress(
    TreasureBoxItem box, {
    int duration = 15,
    String? explicitAction,
  }) async {
    final candidates = <String>[];
    if (explicitAction != null && explicitAction.isNotEmpty) {
      candidates.add(explicitAction);
    }
    if (_discoveredAction != null && _discoveredAction!.isNotEmpty) {
      candidates.add(_discoveredAction!);
    }

    if (box.isAdTask) {
      for (final a in const [
        'complete',
        'finish',
        'ad',
        'watch',
        'reward',
        'progress',
        'video',
        'done',
      ]) {
        if (!candidates.contains(a)) candidates.add(a);
      }
    } else if (box.isReadTask) {
      for (final a in const [
        'complete',
        'finish',
        'read',
        'open',
        'open_reader',
        'open_book',
        'progress',
        'done',
      ]) {
        if (!candidates.contains(a)) candidates.add(a);
      }
    } else {
      for (final a in const [
        'complete',
        'finish',
        'progress',
        'done',
      ]) {
        if (!candidates.contains(a)) candidates.add(a);
      }
    }

    LKException? lastException;
    Object? lastError;

    for (final action in candidates) {
      try {
        final res = await LKApi.reportWelfareTreasureBoxProgress(
          action: action,
          boxIndex: box.boxIndex > 0 ? box.boxIndex : null,
          campaignId: box.campaignId,
          campaignDay: box.campaignDay,
          taskId: box.taskId,
          taskKey: box.taskKey,
          adType: box.isAdTask ? 'watch_ad' : null,
          actionType: box.buttonAction.isNotEmpty
              ? box.buttonAction
              : (box.isAdTask ? 'watch_ad' : null),
          duration: duration,
          progress: 1,
        );
        _discoveredAction = action;
        return res;
      } on LKException catch (e) {
        lastException = e;
        final msg = e.message;
        if (msg.contains('Action') ||
            msg.contains('action') ||
            msg.contains('无效') ||
            msg.contains('不能为空')) {
          continue;
        }
        rethrow;
      } catch (e) {
        lastError = e;
        break;
      }
    }

    if (lastException != null) throw lastException;
    if (lastError != null) throw lastError;
    throw LKException(-1, '未能完成宝箱进度上报');
  }
}

class TreasureBoxDetail {
  const TreasureBoxDetail({
    required this.raw,
    required this.boxes,
    required this.opened,
    this.claimable,
    this.todayTotal,
    this.nextUnlock,
    this.taskDate = '',
    this.taskId,
    this.taskKey = '',
    this.campaignDay,
    this.campaignId,
  });

  final Map<String, dynamic> raw;
  final List<TreasureBoxItem> boxes;
  final int opened;
  final int? claimable;
  final int? todayTotal;
  final DateTime? nextUnlock;
  final String taskDate;
  final int? taskId;
  final String taskKey;
  final int? campaignDay;
  final int? campaignId;

  factory TreasureBoxDetail.fromMap(Map<String, dynamic> response) {
    var root = Map<String, dynamic>.from(response);
    final topTaskId = _nullableNumber(
      response['task_id'] ??
          response['taskId'] ??
          (response['response'] is Map
              ? (response['response']['task_id'] ?? response['response']['taskId'])
              : null),
    );
    final topTaskKey = '${response['task_key'] ?? response['taskKey'] ?? (response['response'] is Map ? (response['response']['task_key'] ?? response['response']['taskKey']) : '')}';

    // Unwrap nested wrappers like response, card, data, detail, etc.
    while (true) {
      if (root['response'] is Map) {
        final nested = _map(root['response']);
        root.remove('response');
        root = {...root, ...nested};
      } else if (root['card'] is Map) {
        final nested = _map(root['card']);
        root.remove('card');
        root = {...root, ...nested};
      } else if (root['task_card'] is Map) {
        final nested = _map(root['task_card']);
        root.remove('task_card');
        root = {...root, ...nested};
      } else if (root['data'] is Map) {
        final nested = _map(root['data']);
        root.remove('data');
        root = {...root, ...nested};
      } else if (root['detail'] is Map) {
        final nested = _map(root['detail']);
        root.remove('detail');
        root = {...root, ...nested};
      } else if (root['treasure_box'] is Map) {
        final nested = _map(root['treasure_box']);
        root.remove('treasure_box');
        root = {...root, ...nested};
      } else if (root['daily_treasure_box_v1'] is Map) {
        final nested = _map(root['daily_treasure_box_v1']);
        root.remove('daily_treasure_box_v1');
        root = {...root, ...nested};
      } else if (root['welfare_treasure_box'] is Map) {
        final nested = _map(root['welfare_treasure_box']);
        root.remove('welfare_treasure_box');
        root = {...root, ...nested};
      } else {
        break;
      }
    }

    final rawBoxes = <Map<String, dynamic>>[];
    for (final key in ['boxes', 'items', 'treasure_boxes', 'claimable_boxes']) {
      final list = root[key];
      if (list is List) {
        for (final item in list.whereType<Map>()) {
          final m = _map(item);
          final isClaimableList = key == 'claimable_boxes';
          final idx = rawBoxes.indexWhere(
            (b) =>
                b['box_index'] != null &&
                b['box_index'] == m['box_index'] &&
                b['box_index'] != 0,
          );
          if (idx >= 0) {
            if (isClaimableList) {
              rawBoxes[idx] = {...rawBoxes[idx], ...m, 'claimable': true};
            }
          } else {
            rawBoxes.add(isClaimableList ? {...m, 'claimable': true} : m);
          }
        }
      }
    }

    // Fallback: root itself is a single box
    if (rawBoxes.isEmpty &&
        (root.containsKey('box_index') ||
            root.containsKey('campaign_id') ||
            root.containsKey('campaignId'))) {
      rawBoxes.add(root);
    }

    final parsedTaskId = _nullableNumber(
      root['task_id'] ?? root['taskId'] ?? topTaskId,
    );
    final parsedTaskKey = '${root['task_key'] ?? root['taskKey'] ?? topTaskKey}';
    final parsedCampaignDay = _nullableNumber(
      root['campaign_day'] ?? root['campaignDay'],
    );
    final parsedCampaignId = _nullableNumber(
      root['campaign_id'] ?? root['campaignId'],
    );

    final boxes = rawBoxes
        .map((item) => TreasureBoxItem.fromMap(
              item,
              parent: root,
              defaultTaskId: parsedTaskId,
              defaultTaskKey: parsedTaskKey,
              defaultCampaignDay: parsedCampaignDay,
              defaultCampaignId: parsedCampaignId,
            ))
        .toList(growable: false);

    final openedCount = _number(
      root['opened_boxes'] ?? root['openedBoxes'] ?? root['opened'] ?? root['claimed'],
    );
    final claimableCount = _nullableNumber(
      root['claimable_count'] ??
          root['claimableCount'] ??
          root['claimable_boxes'] ??
          root['claimable'],
    );
    final totalCount = _nullableNumber(
      root['today_total_boxes'] ?? root['total_boxes'] ?? root['total_progress'],
    );
    final nextUnlockTime = _parseTime(
      root['next_unlock_at'] ?? root['nextUnlockAt'] ?? root['unlock_at'],
    );
    final taskDateStr = '${root['task_date'] ?? root['taskDate'] ?? root['cycle_start_date'] ?? ''}';

    return TreasureBoxDetail(
      raw: root,
      boxes: boxes,
      opened: openedCount,
      claimable: claimableCount,
      todayTotal: totalCount,
      nextUnlock: nextUnlockTime,
      taskDate: taskDateStr,
      taskId: parsedTaskId,
      taskKey: parsedTaskKey,
      campaignDay: parsedCampaignDay,
      campaignId: parsedCampaignId,
    );
  }

  factory TreasureBoxDetail.fromJson(Map<String, dynamic> json) =>
      TreasureBoxDetail.fromMap(json);
}

class TreasureBoxItem {
  TreasureBoxItem({
    required this.raw,
    required this.index,
    required this.reward,
    required this.status,
    required this.requirement,
    required this.requirementText,
    required this.requirementCompleted,
    required this.claimable,
    required this.unlockAtTime,
    required this.unlockAt,
    required this.bookId,
    required this.bookTitle,
    this.taskId,
    this.taskKey = '',
    this.campaignId,
    this.campaignDay,
    this.title = '每日开宝箱',
    this.buttonText = '',
    this.buttonAction = '',
    this.volumeId,
    this.chapterId,
  });

  factory TreasureBoxItem.fromMap(
    Map<String, dynamic> data, {
    Map<String, dynamic>? parent,
    int? defaultTaskId,
    String? defaultTaskKey,
    int? defaultCampaignDay,
    int? defaultCampaignId,
  }) {
    final parentMap = parent ?? const <String, dynamic>{};
    final targetBookMap = _map(data['target_book']);
    final readerTargetMap = _map(data['reader_target']);

    final index = _number(data['box_index'] ?? data['boxIndex'] ?? data['index']);
    final reward = _number(
      data['reward_coin'] ??
          data['reward_amount'] ??
          data['reward'] ??
          data['coin'],
    );
    final status = '${data['status'] ?? data['reward_status'] ?? ''}'
        .trim()
        .toLowerCase();
    final requirement = '${data['prerequisite_type'] ?? data['requirement_type'] ?? readerTargetMap['requirement_type'] ?? ''}';
    final requirementText = '${data['prerequisite_text'] ?? readerTargetMap['requirement_text'] ?? data['requirement_text'] ?? ''}';
    final requirementCompleted = _nullableFlag(
      data['prerequisite_completed'] ?? data['requirement_completed'],
    );
    final claimable = _flag(
      data['claimable'] ?? data['can_claim'] ?? data['canClaim'],
    );
    final unlockAtRaw = '${data['unlock_at'] ?? data['unlockAt'] ?? ''}';
    final unlockAtTime = _parseTime(
      data['unlock_at'] ?? data['unlockAt'],
    );

    final bookId = _number(
      targetBookMap['book_id'] ??
          targetBookMap['bookId'] ??
          readerTargetMap['book_id'] ??
          readerTargetMap['bookId'] ??
          data['book_id'],
    );
    final bookTitle = '${targetBookMap['title'] ?? readerTargetMap['title'] ?? ''}';
    final volumeId = _nullableNumber(
      readerTargetMap['volume_id'] ??
          readerTargetMap['volumeId'] ??
          data['volume_id'],
    );
    final chapterId = _nullableNumber(
      readerTargetMap['chapter_id'] ??
          readerTargetMap['chapterId'] ??
          data['chapter_id'],
    );
    final buttonText = '${data['button_text'] ?? data['buttonText'] ?? ''}'.trim();
    final buttonAction = '${data['button_action'] ?? data['buttonAction'] ?? ''}'.trim();

    final taskId = _nullableNumber(
      data['task_id'] ?? data['taskId'] ?? parentMap['task_id'] ?? defaultTaskId,
    );
    final taskKey = '${data['task_key'] ?? data['taskKey'] ?? parentMap['task_key'] ?? defaultTaskKey ?? ''}';
    final campaignId = _nullableNumber(
      data['campaign_id'] ?? data['campaignId'] ?? parentMap['campaign_id'] ?? defaultCampaignId,
    );
    final campaignDay = _nullableNumber(
      data['campaign_day'] ?? data['campaignDay'] ?? parentMap['campaign_day'] ?? defaultCampaignDay,
    );
    final title = '${data['title'] ?? data['name'] ?? '每日开宝箱'}';

    return TreasureBoxItem(
      raw: data,
      index: index,
      reward: reward,
      status: status,
      requirement: requirement,
      requirementText: requirementText,
      requirementCompleted: requirementCompleted,
      claimable: claimable,
      unlockAtTime: unlockAtTime,
      unlockAt: unlockAtRaw,
      bookId: bookId,
      bookTitle: bookTitle,
      taskId: taskId,
      taskKey: taskKey,
      campaignId: campaignId,
      campaignDay: campaignDay,
      title: title,
      buttonText: buttonText,
      buttonAction: buttonAction,
      volumeId: volumeId,
      chapterId: chapterId,
    );
  }

  final Map<String, dynamic> raw;
  final int index;
  final int reward;
  final String status;
  final String requirement;
  final String requirementText;
  final bool? requirementCompleted;
  final bool claimable;
  final DateTime? unlockAtTime;
  final String unlockAt;
  final int bookId;
  final String bookTitle;
  final int? taskId;
  final String taskKey;
  final int? campaignId;
  final int? campaignDay;
  final String title;
  final String buttonText;
  final String buttonAction;
  final int? volumeId;
  final int? chapterId;

  int get boxIndex => index;

  String get key => index > 0
      ? 'box:$index'
      : (campaignId != null && campaignDay != null)
          ? 'campaign:$campaignId:$campaignDay'
          : 'item:$reward';

  bool get opened {
    if (status == 'waiting_task' ||
        status == 'waiting_time' ||
        status == 'waiting' ||
        status == 'locked' ||
        status == 'claimable' ||
        status == 'ready' ||
        status == 'in_progress') {
      return false;
    }
    if (const ['opened', 'claimed', 'received'].contains(status)) {
      return true;
    }
    if (buttonText == '已领取' || buttonText == '已开启') {
      return true;
    }
    if (_flag(raw['opened']) ||
        _flag(raw['claimed']) ||
        _flag(raw['is_claimed'])) {
      return true;
    }
    final openedAt = _parseTime(raw['opened_at'] ?? raw['openedAt']);
    if (openedAt != null) {
      return true;
    }
    return false;
  }

  bool get isAdTask =>
      requirement == 'watch_ad' ||
      buttonAction == 'watch_ad' ||
      requirementText.contains('广告') ||
      buttonText.contains('广告');

  bool get isReadTask =>
      requirement == 'read_book' ||
      buttonAction == 'open_reader' ||
      bookId > 0 ||
      requirementText.contains('浏览') ||
      requirementText.contains('阅读');

  TreasureBoxState state(DateTime now) {
    if (opened) return TreasureBoxState.claimed;
    if (claimable || status == 'claimable' || status == 'ready') {
      return TreasureBoxState.ready;
    }
    if (status == 'waiting_time' ||
        (unlockAtTime != null && unlockAtTime!.isAfter(now))) {
      return TreasureBoxState.waiting;
    }
    if (status == 'waiting_task' || requirementCompleted == false) {
      return TreasureBoxState.prerequisite;
    }
    if (requirementCompleted == true && !opened) {
      return TreasureBoxState.ready;
    }
    return TreasureBoxState.unknown;
  }

  bool canClaim(DateTime now) => state(now) == TreasureBoxState.ready;

  String get description {
    if (opened) return '已开启';
    if (requirementText.isNotEmpty) return requirementText;
    if (isAdTask) return '需要观看广告';
    if (isReadTask) return '需要浏览指定作品';
    return '开启条件以服务器返回为准';
  }
}
