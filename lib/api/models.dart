import 'dart:convert';

// 数据模型(手写 fromJson,字段与服务端 snake_case 一一对应)

Map<String, dynamic>? _jsonMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

Map<String, dynamic>? _firstJsonMap(dynamic value) {
  final direct = _jsonMap(value);
  if (direct != null) return direct;
  if (value is List) {
    for (final item in value) {
      final map = _jsonMap(item);
      if (map != null) return map;
    }
  }
  return null;
}

bool _jsonFlag(dynamic value) =>
    value == true || value == 1 || value == '1' || value == 'true';

int _jsonInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _jsonIntOrNull(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

Map<String, dynamic> _bookPublisher(Map<String, dynamic> json) =>
    _jsonMap(json['publisher']) ??
    _jsonMap(json['poster_user']) ??
    _jsonMap(json['posterUser']) ??
    _jsonMap(json['publisher_info']) ??
    _jsonMap(json['publisherInfo']) ??
    _firstJsonMap(json['poster_users']) ??
    _firstJsonMap(json['posterUsers']) ??
    _firstJsonMap(json['series_owners']) ??
    _firstJsonMap(json['seriesOwners']) ??
    const <String, dynamic>{};

String _bookAuthorName(Map<String, dynamic> json) {
  final raw =
      json['author_name'] ?? json['writer_name'] ?? json['author'] ?? '';
  if (raw is Map) {
    return (raw['name'] ?? raw['nickname'] ?? raw['username'] ?? '').toString();
  }
  return raw.toString();
}

String _bookPublisherName(Map<String, dynamic> json) {
  final publisher = _bookPublisher(json);
  final rawPublisher = json['publisher'];
  final raw = json['publisher_name'] ??
      json['publisher_nickname'] ??
      (rawPublisher is String ? rawPublisher : null) ??
      publisher['nickname'] ??
      publisher['username'] ??
      publisher['name'] ??
      '';
  return raw.toString();
}

int _bookPublisherUid(Map<String, dynamic> json) {
  final publisher = _bookPublisher(json);
  return _jsonInt(json['publisher_uid'] ??
      json['publisher_id'] ??
      json['publisher_user_id'] ??
      json['publisherUserId'] ??
      publisher['uid'] ??
      publisher['user_id'] ??
      publisher['userId'] ??
      publisher['id']);
}

String _bookPublisherAvatar(Map<String, dynamic> json) {
  final publisher = _bookPublisher(json);
  return (json['publisher_avatar'] ??
          json['publisher_avatar_url'] ??
          publisher['avatar'] ??
          publisher['avatar_url'] ??
          '')
      .toString();
}

bool _bookPublisherFollowed(Map<String, dynamic> json) {
  final publisher = _bookPublisher(json);
  final relation = (json['publisher_relation_state'] ??
          publisher['relation_state'] ??
          publisher['relationState'] ??
          '')
      .toString()
      .trim()
      .toLowerCase();
  return _jsonFlag(json['publisher_followed'] ??
          publisher['followed'] ??
          publisher['is_followed']) ||
      relation == 'following' ||
      relation == 'followed';
}

String dynamicEventLabel(String value) {
  final normalized =
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  if (normalized.endsWith('book_created')) return '新作品';
  if (normalized.endsWith('volume_created')) return '更新了新卷';
  if (normalized.endsWith('chapter_published')) return '更新了新章节';
  if (normalized.contains('book')) return '作品';
  if (normalized.endsWith('short_post_published')) return '动态';
  if (normalized.contains('repost')) return '转发';
  return normalized.replaceAll('_', ' ');
}

String dynamicWebsiteUrl(int dynamicId) =>
    'https://www.lightnovel.fun/activity/$dynamicId';

class LKUser {
  final int uid;
  final String nickname;
  final String avatar;
  final String sign;
  LKUser({this.uid = 0, this.nickname = '', this.avatar = '', this.sign = ''});
  factory LKUser.fromJson(Map<String, dynamic> j) => LKUser(
        uid: (j['uid'] as num?)?.toInt() ?? 0,
        nickname: (j['nickname'] as String?) ?? '',
        avatar: (j['avatar'] as String?) ?? '',
        sign: (j['sign'] as String?) ?? (j['signature'] as String?) ?? '',
      );
}

/// 当前登录用户的个人页资料(只读)
class LKMyProfile {
  final int uid;
  final String nickname;
  final String avatar;
  final String signature;
  final String levelName;
  final int level;
  final int coin;
  final bool isBrave;
  final int followersCount;
  final int followingCount;
  final int postCount;
  final int? bookshelfCount;
  final int? historyCount;
  final List<LKMedal> medals;

  LKMyProfile({
    this.uid = 0,
    this.nickname = '',
    this.avatar = '',
    this.signature = '',
    this.levelName = '',
    this.level = 0,
    this.coin = 0,
    this.isBrave = false,
    this.followersCount = 0,
    this.followingCount = 0,
    this.postCount = 0,
    this.bookshelfCount,
    this.historyCount,
    this.medals = const [],
  });

  factory LKMyProfile.fromJson(Map<String, dynamic> j) {
    final profile = _jsonMap(j['profile']) ?? j;
    final stats = _jsonMap(j['stats']) ?? const <String, dynamic>{};
    final balance = _jsonMap(profile['balance']) ?? const <String, dynamic>{};
    final levelObject = _jsonMap(profile['level']);
    final rawMedals = profile['medals'] ??
        profile['medal_list'] ??
        profile['equipped_medals'] ??
        j['medals'];
    final medals = rawMedals is List
        ? rawMedals
            .whereType<Map>()
            .map((e) => LKMedal.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.image.isNotEmpty)
            .take(5)
            .toList()
        : const <LKMedal>[];
    final rawLevel =
        levelObject?['level'] ?? profile['level_number'] ?? profile['level'];
    final levelName = (profile['level_name'] ??
            profile['levelName'] ??
            profile['level_title'] ??
            profile['group_name'] ??
            profile['user_group_name'] ??
            profile['rank_name'] ??
            profile['role_name'] ??
            levelObject?['name'] ??
            levelObject?['title'] ??
            '')
        .toString();
    return LKMyProfile(
      uid: _jsonInt(profile['uid'] ?? profile['user_id'] ?? profile['id']),
      nickname: (profile['nickname'] ?? profile['username'] ?? '').toString(),
      avatar: (profile['avatar'] ?? profile['avatar_url'] ?? '').toString(),
      signature: (profile['sign'] ?? profile['signature'] ?? '').toString(),
      levelName: levelName,
      level: _jsonInt(rawLevel),
      coin: _jsonInt(profile['coin'] ??
          profile['light_coin'] ??
          profile['lightCoin'] ??
          balance['coin'] ??
          balance['light_coin'] ??
          balance['lightCoin'] ??
          profile['balance']),
      isBrave: _jsonFlag(profile['passer'] ??
          profile['is_passer'] ??
          profile['isBrave'] ??
          profile['brave']),
      followersCount: _jsonInt(stats['followers'] ??
          stats['fans'] ??
          stats['fans_count'] ??
          profile['followers'] ??
          profile['fans_count']),
      followingCount: _jsonInt(stats['following'] ??
          stats['following_count'] ??
          profile['following'] ??
          profile['following_count']),
      postCount: _jsonInt(stats['publish_articles'] ??
          stats['post_count'] ??
          stats['posts'] ??
          profile['post_count'] ??
          j['publish_articles'] ??
          j['post_count']),
      bookshelfCount: _jsonIntOrNull(stats['bookshelf_count'] ??
          stats['my_bookshelf_count'] ??
          stats['my_bookshelf_count_value'] ??
          profile['bookshelf_count'] ??
          profile['my_bookshelf_count'] ??
          j['bookshelf_count'] ??
          j['my_bookshelf_count'] ??
          j['my_bookshelf_count_value'] ??
          j['bookshelfCount']),
      historyCount: _jsonIntOrNull(stats['history_count'] ??
          stats['my_history_count'] ??
          stats['my_history_count_value'] ??
          stats['reading_count'] ??
          profile['history_count'] ??
          profile['my_history_count'] ??
          j['history_count'] ??
          j['my_history_count'] ??
          j['my_history_count_value'] ??
          j['reading_count'] ??
          j['historyCount']),
      medals: medals,
    );
  }
}

/// 关注/粉丝列表中的用户(只读)
class LKFollowUser {
  final int uid;
  final String nickname;
  final String avatar;
  final String signature;
  final String levelName;
  final bool isBrave;
  final bool followed;

  LKFollowUser({
    this.uid = 0,
    this.nickname = '',
    this.avatar = '',
    this.signature = '',
    this.levelName = '',
    this.isBrave = false,
    this.followed = false,
  });

  factory LKFollowUser.fromJson(Map<String, dynamic> j) {
    final relation = _jsonMap(j['relation']) ??
        _jsonMap(j['interaction_state']) ??
        const <String, dynamic>{};
    final levelObject = _jsonMap(j['level']);
    return LKFollowUser(
      uid: _jsonInt(j['uid'] ?? j['user_id'] ?? j['id']),
      nickname:
          (j['nickname'] ?? j['username'] ?? j['name'] ?? j['nick_name'] ?? '')
              .toString(),
      avatar: (j['avatar'] ?? j['avatar_url'] ?? '').toString(),
      signature: (j['sign'] ?? j['signature'] ?? '').toString(),
      levelName: (j['level_name'] ??
              j['levelName'] ??
              j['level_title'] ??
              j['group_name'] ??
              levelObject?['name'] ??
              levelObject?['title'] ??
              '')
          .toString(),
      isBrave: _jsonFlag(j['passer'] ??
          j['is_passer'] ??
          j['isBrave'] ??
          j['brave'] ??
          relation['is_passer'] ??
          relation['isBrave']),
      followed: _jsonFlag(relation['followed'] ??
          relation['is_followed'] ??
          j['followed'] ??
          j['is_followed']),
    );
  }

  LKFollowUser copyWith({bool? followed}) => LKFollowUser(
        uid: uid,
        nickname: nickname,
        avatar: avatar,
        signature: signature,
        levelName: levelName,
        isBrave: isBrave,
        followed: followed ?? this.followed,
      );
}

class LKFollowPage {
  final List<LKFollowUser> items;
  final int page;
  final int pageSize;
  final int total;
  final bool hasMore;

  LKFollowPage({
    this.items = const [],
    this.page = 1,
    this.pageSize = 20,
    this.total = 0,
    this.hasMore = false,
  });

  factory LKFollowPage.fromJson(Map<String, dynamic> j,
      {int fallbackPage = 1, int fallbackPageSize = 20}) {
    final rawList = j['items'] ?? j['list'] ?? j['cards'];
    final items = rawList is List
        ? rawList
            .whereType<Map>()
            .map((e) => LKFollowUser.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : const <LKFollowUser>[];
    final pageInfo = _jsonMap(j['pagination']) ??
        _jsonMap(j['page_info']) ??
        const <String, dynamic>{};
    final page = _jsonInt(pageInfo['page'] ??
        pageInfo['current_page'] ??
        j['page'] ??
        fallbackPage);
    final pageSize = _jsonInt(pageInfo['page_size'] ??
        pageInfo['pageSize'] ??
        pageInfo['per_page'] ??
        j['page_size'] ??
        j['pageSize'] ??
        fallbackPageSize);
    final total = _jsonInt(pageInfo['total'] ??
        pageInfo['total_count'] ??
        pageInfo['count'] ??
        j['total'] ??
        items.length);
    final rawHasMore = pageInfo['has_more'] ??
        pageInfo['hasMore'] ??
        pageInfo['has_next'] ??
        j['has_more'] ??
        j['hasMore'] ??
        j['has_next'];
    final hasMore = rawHasMore == null
        ? (total > page * pageSize || items.length >= pageSize)
        : _jsonFlag(rawHasMore);
    return LKFollowPage(
      items: items,
      page: page > 0 ? page : fallbackPage,
      pageSize: pageSize > 0 ? pageSize : fallbackPageSize,
      total: total,
      hasMore: hasMore,
    );
  }
}

class LKMedal {
  final int medalId;
  final String name;
  final String image;
  final bool equipped;

  LKMedal({
    this.medalId = 0,
    this.name = '',
    this.image = '',
    this.equipped = false,
  });

  factory LKMedal.fromJson(Map<String, dynamic> j) => LKMedal(
        medalId: _jsonInt(j['medal_id'] ?? j['id'] ?? j['goods_id']),
        name: (j['name'] ?? j['title'] ?? '').toString(),
        image: (j['image'] ?? j['img'] ?? j['icon'] ?? j['icon_url'] ?? '')
            .toString(),
        equipped: _jsonFlag(j['equipped'] ?? j['equip'] ?? j['is_equipped']),
      );
}

/// 勇者考试当前状态。
///
/// 题库接口的字段由站点统一返回，但不同版本可能把状态包在 status/state
/// 下，或使用 snake_case/camelCase。这里集中做兼容解析，页面只关心稳定字段。
class LKBraveQuizStatus {
  final bool answered;
  final bool available;
  final bool passed;
  final int score;
  final int passingScore;
  final int questionCount;
  final String message;

  const LKBraveQuizStatus({
    this.answered = false,
    this.available = true,
    this.passed = false,
    this.score = 0,
    this.passingScore = 60,
    this.questionCount = 50,
    this.message = '',
  });

  factory LKBraveQuizStatus.fromJson(Map<String, dynamic> json) {
    final nested = _jsonMap(json['status']) ??
        _jsonMap(json['state']) ??
        _jsonMap(json['result']) ??
        const <String, dynamic>{};

    dynamic pick(List<String> keys) {
      for (final key in keys) {
        if (nested.containsKey(key)) return nested[key];
        if (json.containsKey(key)) return json[key];
      }
      return null;
    }

    final explicitAnswered = pick(const [
      'is_answered',
      'isAnswered',
      'answered',
      'already_answered',
      'alreadyAnswered',
      'today_answered',
      'todayAnswered',
      'completed',
      'done',
    ]);
    final attemptedToday = pick(const ['attempted_today', 'attemptedToday']);
    // 当前接口用 attempted_today/can_start 表示每日答题状态，而不是
    // is_answered/available。优先使用明确字段，兼容旧版本字段名。
    final answered = explicitAnswered == null
        ? _jsonFlag(attemptedToday)
        : _jsonFlag(explicitAnswered);
    final availableValue = pick(const [
      'available',
      'can_answer',
      'canAnswer',
      'is_available',
      'isAvailable',
      'enabled',
    ]);
    final canStartValue = pick(const ['can_start', 'canStart']);
    return LKBraveQuizStatus(
      answered: answered,
      available: canStartValue != null
          ? _jsonFlag(canStartValue)
          : availableValue == null
              ? !answered
              : _jsonFlag(availableValue),
      passed: _jsonFlag(pick(const [
        'passed',
        'is_passed',
        'isPassed',
        'pass',
      ])),
      score: _jsonInt(pick(const ['score', 'score_snapshot'])),
      passingScore: _jsonInt(pick(const [
                'passing_score',
                'passingScore',
                'pass_score',
              ])) >
              0
          ? _jsonInt(pick(const [
              'passing_score',
              'passingScore',
              'pass_score',
            ]))
          : 60,
      questionCount: _jsonInt(pick(const [
                'question_count',
                'questionCount',
                'total_questions',
                'count',
              ])) >
              0
          ? _jsonInt(pick(const [
              'question_count',
              'questionCount',
              'total_questions',
            ]))
          : 50,
      message:
          (pick(const ['message', 'msg', 'reason', 'notice']) ?? '').toString(),
    );
  }
}

class LKBraveQuizOption {
  final int optionId;
  final String optionKey;
  final String text;

  const LKBraveQuizOption({
    this.optionId = 0,
    this.optionKey = '',
    this.text = '',
  });

  /// 保留服务端返回的数值 id 或 key，交卷时优先使用数值 id。
  dynamic get submissionValue => optionId > 0
      ? optionId
      : optionKey.isNotEmpty
          ? optionKey
          : text;

  String get stableKey => optionId > 0
      ? 'id:$optionId'
      : optionKey.isNotEmpty
          ? 'key:$optionKey'
          : 'text:$text';

  factory LKBraveQuizOption.fromJson(dynamic raw) {
    if (raw is String) {
      return LKBraveQuizOption(optionKey: raw, text: raw);
    }
    final json = _jsonMap(raw) ?? const <String, dynamic>{};
    final id = _jsonInt(
        json['option_id'] ?? json['optionId'] ?? json['id'] ?? json['value']);
    final rawKey = json['option_key'] ??
        json['optionKey'] ??
        json['key'] ??
        json['code'] ??
        (id > 0 ? '' : json['value']);
    final text = (json['text'] ??
            json['label'] ??
            json['content'] ??
            json['title'] ??
            json['name'] ??
            '')
        .toString();
    return LKBraveQuizOption(
      optionId: id,
      optionKey: rawKey?.toString() ?? '',
      text: text,
    );
  }
}

class LKBraveQuizQuestion {
  final int questionId;
  final String prompt;
  final List<LKBraveQuizOption> options;

  const LKBraveQuizQuestion({
    this.questionId = 0,
    this.prompt = '',
    this.options = const [],
  });

  factory LKBraveQuizQuestion.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'] ??
        json['option_list'] ??
        json['optionList'] ??
        json['choices'] ??
        const [];
    final options = rawOptions is List
        ? rawOptions
            .map(LKBraveQuizOption.fromJson)
            .where((option) =>
                option.text.isNotEmpty || option.optionKey.isNotEmpty)
            .toList(growable: false)
        : const <LKBraveQuizOption>[];
    return LKBraveQuizQuestion(
      questionId: _jsonInt(json['question_id'] ??
          json['questionId'] ??
          json['id'] ??
          json['qid']),
      prompt: (json['question'] ??
              json['title'] ??
              json['content'] ??
              json['stem'] ??
              json['text'] ??
              '')
          .toString(),
      options: options,
    );
  }
}

class LKBraveQuizPaper {
  final String sessionId;
  final String status;
  final String expiresAt;
  final int ttl;
  final List<LKBraveQuizQuestion> questions;
  final int passingScore;
  final int pointsPerQuestion;

  const LKBraveQuizPaper({
    this.sessionId = '',
    this.status = '',
    this.expiresAt = '',
    this.ttl = 0,
    this.questions = const [],
    this.passingScore = 60,
    this.pointsPerQuestion = 0,
  });

  factory LKBraveQuizPaper.fromJson(Map<String, dynamic> json) {
    final paper = _jsonMap(json['paper']) ??
        _jsonMap(json['quiz']) ??
        _jsonMap(json['data']) ??
        json;
    final rawQuestions = paper['questions'] ??
        json['questions'] ??
        paper['list'] ??
        json['list'] ??
        paper['items'] ??
        json['items'] ??
        const [];
    final questions = rawQuestions is List
        ? rawQuestions
            .whereType<Map>()
            .map((item) =>
                LKBraveQuizQuestion.fromJson(Map<String, dynamic>.from(item)))
            .where((question) => question.prompt.isNotEmpty)
            .toList(growable: false)
        : const <LKBraveQuizQuestion>[];
    int positiveInt(List<String> keys, int fallback) {
      for (final key in keys) {
        final value = _jsonInt(paper[key] ?? json[key]);
        if (value > 0) return value;
      }
      return fallback;
    }

    String stringValue(List<String> keys) {
      for (final key in keys) {
        final value = paper[key] ?? json[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString();
        }
      }
      return '';
    }

    String findSessionId(dynamic value, {bool allowPlainId = false}) {
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        for (final key in const [
          'session_id',
          'sessionId',
          'quiz_session_id',
          'quizSessionId',
          'exam_session_id',
          'examSessionId',
        ]) {
          final raw = map[key];
          if (raw != null && raw.toString().trim().isNotEmpty) {
            return raw.toString();
          }
        }
        if (allowPlainId) {
          final raw = map['id'];
          if (raw != null && raw.toString().trim().isNotEmpty) {
            return raw.toString();
          }
        }
        for (final key in const [
          'session',
          'quiz_session',
          'quizSession',
          'exam_session',
          'examSession',
        ]) {
          final raw = map[key];
          if (raw is String && raw.trim().isNotEmpty) return raw;
          if (raw is num) return raw.toString();
          final nested = findSessionId(raw, allowPlainId: true);
          if (nested.isNotEmpty) return nested;
        }
        for (final key in const ['paper', 'quiz', 'data', 'payload']) {
          final nested = findSessionId(map[key]);
          if (nested.isNotEmpty) return nested;
        }
        for (final child in map.values) {
          final nested = findSessionId(child);
          if (nested.isNotEmpty) return nested;
        }
      } else if (value is List) {
        for (final item in value) {
          final nested = findSessionId(item);
          if (nested.isNotEmpty) return nested;
        }
      }
      return '';
    }

    return LKBraveQuizPaper(
      sessionId: findSessionId(json),
      status: stringValue(const ['status', 'state']),
      expiresAt: stringValue(const ['expires_at', 'expiresAt']),
      ttl: positiveInt(const ['ttl', 'expires_in', 'expiresIn'], 0),
      questions: questions,
      passingScore: positiveInt(
          const ['passing_score', 'passingScore', 'pass_score'], 60),
      pointsPerQuestion:
          positiveInt(const ['points_per_question', 'pointsPerQuestion'], 0),
    );
  }
}

class LKBraveQuizResult {
  final bool passed;
  final int score;
  final int correctCount;
  final int points;
  final String message;

  const LKBraveQuizResult({
    this.passed = false,
    this.score = 0,
    this.correctCount = 0,
    this.points = 0,
    this.message = '',
  });

  factory LKBraveQuizResult.fromJson(Map<String, dynamic> json) {
    final result = _jsonMap(json['result']) ??
        _jsonMap(json['score']) ??
        _jsonMap(json['data']) ??
        json;
    dynamic pick(List<String> keys) {
      for (final key in keys) {
        if (result.containsKey(key)) return result[key];
        if (json.containsKey(key)) return json[key];
      }
      return null;
    }

    return LKBraveQuizResult(
      passed: _jsonFlag(pick(const [
        'passed',
        'is_passed',
        'isPassed',
        'pass',
        'brave',
      ])),
      score: _jsonInt(pick(const ['score', 'score_snapshot'])),
      correctCount: _jsonInt(pick(const ['correct_count', 'correctCount'])),
      points: _jsonInt(pick(const ['points', 'reward_points'])),
      message: (pick(const ['message', 'msg', 'notice']) ?? '').toString(),
    );
  }
}

/// 公开用户主页资料
class LKPublicUserProfile {
  final int uid;
  final String nickname;
  final String avatar;
  final String signature;
  final String levelName;
  final int level;
  final bool isBrave;
  final int followersCount;
  final int followingCount;
  final int postCount;
  final List<LKMedal> medals;
  final bool followed;
  final bool isSelf;
  final bool canFollow;
  final bool publicBookshelf;

  const LKPublicUserProfile({
    this.uid = 0,
    this.nickname = '',
    this.avatar = '',
    this.signature = '',
    this.levelName = '',
    this.level = 0,
    this.isBrave = false,
    this.followersCount = 0,
    this.followingCount = 0,
    this.postCount = 0,
    this.medals = const [],
    this.followed = false,
    this.isSelf = false,
    this.canFollow = true,
    this.publicBookshelf = false,
  });

  factory LKPublicUserProfile.fromJson(Map<String, dynamic> j) {
    final profile = _jsonMap(j['profile']) ?? j;
    final stats = _jsonMap(j['stats']) ?? const <String, dynamic>{};
    final relation = _jsonMap(j['relation']) ?? const <String, dynamic>{};
    final modules = _jsonMap(j['modules']) ?? const <String, dynamic>{};
    final privacy = _jsonMap(j['privacy']) ?? const <String, dynamic>{};
    final levelObject = _jsonMap(profile['level']);
    final rawMedals = profile['medals'] ??
        profile['medal_list'] ??
        profile['equipped_medals'];
    final medals = rawMedals is List
        ? rawMedals
            .whereType<Map>()
            .map((e) => LKMedal.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.image.isNotEmpty)
            .take(5)
            .toList()
        : const <LKMedal>[];
    final rawCanFollow = relation['can_follow'];
    return LKPublicUserProfile(
      uid: _jsonInt(profile['uid'] ?? profile['user_id'] ?? profile['id']),
      nickname:
          (profile['nickname'] ?? profile['username'] ?? profile['name'] ?? '')
              .toString(),
      avatar: (profile['avatar'] ?? profile['avatar_url'] ?? '').toString(),
      signature: (profile['sign'] ?? profile['signature'] ?? '').toString(),
      levelName: (profile['level_name'] ??
              profile['levelName'] ??
              profile['level_title'] ??
              profile['group_name'] ??
              profile['user_group_name'] ??
              profile['rank_name'] ??
              levelObject?['name'] ??
              levelObject?['title'] ??
              '')
          .toString(),
      level: _jsonInt(
          levelObject?['level'] ?? profile['level_number'] ?? profile['level']),
      isBrave: _jsonFlag(profile['passer'] ??
          profile['is_passer'] ??
          profile['isBrave'] ??
          profile['brave']),
      followersCount: _jsonInt(stats['followers'] ??
          stats['fans'] ??
          stats['fans_count'] ??
          profile['followers'] ??
          profile['fans_count']),
      followingCount: _jsonInt(stats['following'] ??
          stats['following_count'] ??
          profile['following'] ??
          profile['following_count']),
      postCount: _jsonInt(stats['publish_articles'] ??
          stats['post_count'] ??
          stats['posts'] ??
          profile['post_count']),
      medals: medals,
      followed: _jsonFlag(relation['followed'] ??
          relation['is_followed'] ??
          profile['followed']),
      isSelf: _jsonFlag(relation['is_self'] ?? relation['self']),
      canFollow: rawCanFollow == null || _jsonFlag(rawCanFollow),
      publicBookshelf: _jsonFlag(modules['public_bookshelf'] ??
          modules['publicBookshelf'] ??
          privacy['bookshelf_visible'] ??
          privacy['bookshelfVisible']),
    );
  }
}

class LKPublicBook {
  final int bookId;
  final String title;
  final String coverUrl;
  final String summary;
  final String updatedAt;
  final String typeText;
  final bool isBrave;

  LKPublicBook({
    this.bookId = 0,
    this.title = '',
    this.coverUrl = '',
    this.summary = '',
    this.updatedAt = '',
    this.typeText = '',
    this.isBrave = false,
  });

  LKPublicBook copyWith({
    int? bookId,
    String? title,
    String? coverUrl,
    String? summary,
    String? updatedAt,
    String? typeText,
    bool? isBrave,
  }) =>
      LKPublicBook(
        bookId: bookId ?? this.bookId,
        title: title ?? this.title,
        coverUrl: coverUrl ?? this.coverUrl,
        summary: summary ?? this.summary,
        updatedAt: updatedAt ?? this.updatedAt,
        typeText: typeText ?? this.typeText,
        isBrave: isBrave ?? this.isBrave,
      );

  factory LKPublicBook.fromJson(Map<String, dynamic> j) => LKPublicBook(
        bookId: _jsonInt(j['book_id'] ??
            j['bookId'] ??
            j['article_id'] ??
            j['aid'] ??
            j['id']),
        title: (j['title'] ?? j['subject'] ?? j['name'] ?? '').toString(),
        coverUrl: (j['cover_url'] ?? j['cover'] ?? j['image'] ?? j['img'] ?? '')
            .toString(),
        summary:
            (j['summary'] ?? j['description'] ?? j['content'] ?? '').toString(),
        updatedAt: (j['updated_at'] ??
                j['updatedAt'] ??
                j['created_at'] ??
                j['createdAt'] ??
                '')
            .toString(),
        typeText: (j['type_text'] ??
                j['typeText'] ??
                j['category_name'] ??
                j['kind'] ??
                '')
            .toString(),
        isBrave: _isBraveBook(j),
      );
}

class LKPublicUserPage {
  final LKPublicUserProfile profile;
  final List<LKPublicBook> publications;
  final int page;
  final int pageSize;
  final int total;
  final bool hasMore;

  LKPublicUserPage({
    this.profile = const LKPublicUserProfile(),
    this.publications = const [],
    this.page = 1,
    this.pageSize = 20,
    this.total = 0,
    this.hasMore = false,
  });

  factory LKPublicUserPage.fromJson(Map<String, dynamic> j,
      {int fallbackPage = 1, int fallbackPageSize = 20}) {
    final profile = LKPublicUserProfile.fromJson(j);
    final publish = _jsonMap(j['publish']) ?? const <String, dynamic>{};
    final books = _jsonMap(publish['books']) ?? const <String, dynamic>{};
    final rawList = j['articles'] ??
        j['article_list'] ??
        books['list'] ??
        books['items'] ??
        const [];
    final publications = rawList is List
        ? rawList
            .whereType<Map>()
            .map((e) => LKPublicBook.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.bookId > 0 && e.title.isNotEmpty)
            .toList()
        : const <LKPublicBook>[];
    final pageInfo = _jsonMap(j['article_page']) ??
        _jsonMap(j['articlePage']) ??
        _jsonMap(books['page_info']) ??
        const <String, dynamic>{};
    final page = _jsonInt(pageInfo['page'] ??
        pageInfo['current_page'] ??
        j['page'] ??
        fallbackPage);
    final pageSize = _jsonInt(pageInfo['page_size'] ??
        pageInfo['pageSize'] ??
        j['page_size'] ??
        j['pageSize'] ??
        fallbackPageSize);
    final total = _jsonInt(pageInfo['total'] ??
        pageInfo['count'] ??
        j['total'] ??
        publications.length);
    final rawHasMore = pageInfo['has_more'] ??
        pageInfo['hasMore'] ??
        pageInfo['has_next'] ??
        j['has_more'] ??
        j['hasMore'];
    final hasMore = rawHasMore == null
        ? total > page * pageSize || publications.length >= pageSize
        : _jsonFlag(rawHasMore);
    return LKPublicUserPage(
      profile: profile,
      publications: publications,
      page: page > 0 ? page : fallbackPage,
      pageSize: pageSize > 0 ? pageSize : fallbackPageSize,
      total: total,
      hasMore: hasMore,
    );
  }
}

class LKPublicBookshelfPage {
  final bool visible;
  final List<LKPublicBook> books;
  final int page;
  final int pageSize;
  final int total;
  final bool hasMore;

  LKPublicBookshelfPage({
    this.visible = false,
    this.books = const [],
    this.page = 1,
    this.pageSize = 20,
    this.total = 0,
    this.hasMore = false,
  });

  factory LKPublicBookshelfPage.fromJson(Map<String, dynamic> j,
      {int fallbackPage = 1, int fallbackPageSize = 20}) {
    final privacy = _jsonMap(j['privacy']) ?? const <String, dynamic>{};
    final rawList = j['list'] ?? j['items'] ?? j['books'] ?? const [];
    final books = rawList is List
        ? rawList
            .whereType<Map>()
            .map((e) => LKPublicBook.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.bookId > 0 && e.title.isNotEmpty)
            .toList()
        : const <LKPublicBook>[];
    final pageInfo = _jsonMap(j['page_info']) ??
        _jsonMap(j['pagination']) ??
        const <String, dynamic>{};
    final page = _jsonInt(pageInfo['page'] ?? j['page'] ?? fallbackPage);
    final pageSize = _jsonInt(pageInfo['page_size'] ??
        pageInfo['pageSize'] ??
        j['page_size'] ??
        fallbackPageSize);
    final total = _jsonInt(pageInfo['total'] ?? j['total'] ?? books.length);
    final rawHasMore = pageInfo['has_more'] ??
        pageInfo['hasMore'] ??
        pageInfo['has_next'] ??
        j['has_more'] ??
        j['hasMore'];
    return LKPublicBookshelfPage(
      visible: _jsonFlag(j['visible'] ??
          privacy['bookshelf_visible'] ??
          privacy['bookshelfVisible']),
      books: books,
      page: page > 0 ? page : fallbackPage,
      pageSize: pageSize > 0 ? pageSize : fallbackPageSize,
      total: total,
      hasMore: rawHasMore == null
          ? total > page * pageSize || books.length >= pageSize
          : _jsonFlag(rawHasMore),
    );
  }
}

class LKBook {
  final int bookId;
  final String title;
  final String authorName;
  final int publisherUid;
  final String publisherName;
  final String publisherAvatar;
  final bool publisherFollowed;
  final String coverUrl;
  final String summary;
  final List<String> tags;
  final int wordCount;
  final int volumeCount;
  final int chapterCount;
  final int defaultVolumeId;
  final int defaultChapterId;
  final String serialStatus;
  final bool isCompleted;
  final String lastReadChapterTitle;
  final int unreadChapterCount;
  final double ratingScore;
  final String updatedAt;
  final bool isBrave;
  LKBook({
    this.bookId = 0,
    this.title = '',
    this.authorName = '',
    this.publisherUid = 0,
    this.publisherName = '',
    this.publisherAvatar = '',
    this.publisherFollowed = false,
    this.coverUrl = '',
    this.summary = '',
    this.tags = const [],
    this.wordCount = 0,
    this.volumeCount = 0,
    this.chapterCount = 0,
    this.defaultVolumeId = 0,
    this.defaultChapterId = 0,
    this.serialStatus = '',
    this.isCompleted = false,
    this.lastReadChapterTitle = '',
    this.unreadChapterCount = 0,
    this.ratingScore = 0,
    this.updatedAt = '',
    this.isBrave = false,
  });
  factory LKBook.fromJson(Map<String, dynamic> j) => LKBook(
        bookId: (j['book_id'] as num?)?.toInt() ?? 0,
        title: (j['title'] as String?) ?? '',
        authorName: _bookAuthorName(j),
        publisherUid: _bookPublisherUid(j),
        publisherName: _bookPublisherName(j),
        publisherAvatar: _bookPublisherAvatar(j),
        publisherFollowed: _bookPublisherFollowed(j),
        coverUrl: (j['cover_url'] as String?) ?? '',
        summary:
            (j['summary'] as String?) ?? (j['summary_short'] as String?) ?? '',
        tags:
            (j['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        wordCount: (j['word_count'] as num?)?.toInt() ?? 0,
        volumeCount: (j['volume_count'] as num?)?.toInt() ?? 0,
        chapterCount: (j['chapter_count'] as num?)?.toInt() ?? 0,
        defaultVolumeId: (j['default_volume_id'] as num?)?.toInt() ?? 0,
        defaultChapterId: (j['default_chapter_id'] as num?)?.toInt() ?? 0,
        serialStatus: _bookSerialStatus(j),
        isCompleted: _jsonFlag(j['is_completed'] ?? j['isCompleted']),
        lastReadChapterTitle: (j['last_read_chapter_title'] as String?) ?? '',
        unreadChapterCount: (j['unread_chapter_count'] as num?)?.toInt() ?? 0,
        ratingScore: (j['rating_score'] as num?)?.toDouble() ?? 0,
        updatedAt: (j['latest_book_updated_at'] as String?) ??
            (j['updated_at'] as String?) ??
            '',
        isBrave: _isBraveBook(j),
      );

  Map<String, dynamic> toJson() => {
        'book_id': bookId,
        'title': title,
        'author_name': authorName,
        'publisher_uid': publisherUid,
        'publisher_name': publisherName,
        'publisher_avatar': publisherAvatar,
        'publisher_followed': publisherFollowed,
        'cover_url': coverUrl,
        'summary': summary,
        'tags': tags,
        'word_count': wordCount,
        'volume_count': volumeCount,
        'chapter_count': chapterCount,
        'default_volume_id': defaultVolumeId,
        'default_chapter_id': defaultChapterId,
        'serial_status': serialStatus,
        'is_completed': isCompleted ? 1 : 0,
        'last_read_chapter_title': lastReadChapterTitle,
        'unread_chapter_count': unreadChapterCount,
        'rating_score': ratingScore,
        'updated_at': updatedAt,
        'is_brave': isBrave ? 1 : 0,
      };

  LKBook copyWith({
    int? bookId,
    String? title,
    String? authorName,
    int? publisherUid,
    String? publisherName,
    String? publisherAvatar,
    bool? publisherFollowed,
    String? coverUrl,
    String? summary,
    List<String>? tags,
    int? wordCount,
    int? volumeCount,
    int? chapterCount,
    int? defaultVolumeId,
    int? defaultChapterId,
    String? serialStatus,
    bool? isCompleted,
    String? lastReadChapterTitle,
    int? unreadChapterCount,
    double? ratingScore,
    String? updatedAt,
    bool? isBrave,
  }) =>
      LKBook(
        bookId: bookId ?? this.bookId,
        title: title ?? this.title,
        authorName: authorName ?? this.authorName,
        publisherUid: publisherUid ?? this.publisherUid,
        publisherName: publisherName ?? this.publisherName,
        publisherAvatar: publisherAvatar ?? this.publisherAvatar,
        publisherFollowed: publisherFollowed ?? this.publisherFollowed,
        coverUrl: coverUrl ?? this.coverUrl,
        summary: summary ?? this.summary,
        tags: tags ?? this.tags,
        wordCount: wordCount ?? this.wordCount,
        volumeCount: volumeCount ?? this.volumeCount,
        chapterCount: chapterCount ?? this.chapterCount,
        defaultVolumeId: defaultVolumeId ?? this.defaultVolumeId,
        defaultChapterId: defaultChapterId ?? this.defaultChapterId,
        serialStatus: serialStatus ?? this.serialStatus,
        isCompleted: isCompleted ?? this.isCompleted,
        lastReadChapterTitle:
            lastReadChapterTitle ?? this.lastReadChapterTitle,
        unreadChapterCount: unreadChapterCount ?? this.unreadChapterCount,
        ratingScore: ratingScore ?? this.ratingScore,
        updatedAt: updatedAt ?? this.updatedAt,
        isBrave: isBrave ?? this.isBrave,
      );
}

bool Function(int bookId)? _externalBraveChecker;
void setBraveBookChecker(bool Function(int bookId)? checker) {
  _externalBraveChecker = checker;
}

bool _isBraveBook(Map<String, dynamic> j) {
  final bookId = _jsonInt(j['book_id'] ?? j['id']);
  if (bookId > 0 && (_externalBraveChecker?.call(bookId) ?? false)) {
    return true;
  }

  if (_jsonFlag(j['is_brave'] ?? j['isBrave'])) return true;
  if (_jsonFlag(j['brave_required'] ?? j['braveRequired'])) return true;

  final accessType =
      (j['access_type'] ?? j['accessType'])?.toString().trim().toLowerCase();
  if (accessType == 'brave') return true;

  final metaJson = _jsonMap(j['meta_json']);
  if (metaJson != null) {
    final braveScope =
        (metaJson['brave_scope'] as String?)?.trim().toLowerCase();
    if (braveScope == 'brave') return true;
  }

  final tags = j['tags'];
  if (tags is List &&
      tags.any((t) {
        final s = t.toString().trim();
        return s == '勇者' || s == '勇者可读';
      })) {
    return true;
  }

  final badge = (j['display_badge_code'] ?? '').toString().toLowerCase();
  if (badge.contains('brave')) return true;

  return false;
}

String _bookSerialStatus(Map<String, dynamic> json) {
  final explicit = json['serial_status'] ??
      json['serialStatus'] ??
      json['status_text'] ??
      json['statusText'];
  final explicitText = explicit?.toString().trim() ?? '';
  if (explicitText.isNotEmpty) return explicitText;

  // Some feeds expose a textual status/state instead of serial_status. Numeric
  // status values describe publication visibility, so they must not be treated
  // as the serialization state.
  for (final value in [json['status'], json['state']]) {
    if (value is String && _knownBookStatus(value)) return value.trim();
  }
  return '';
}

bool _knownBookStatus(String value) {
  final status = value.trim().toLowerCase().replaceAll('-', '_');
  return const {
    'serial',
    'serializing',
    'ongoing',
    'in_progress',
    'publishing',
    'complete',
    'completed',
    'finished',
    'done',
    'ended',
    'end',
    '连载',
    '连载中',
    '未完结',
    '完结',
    '已完结',
    '完本',
  }.contains(status);
}

/// 阅读入口聚合数据。该接口只负责书籍壳、书架状态和有效阅读目标，
/// 正文与完整目录仍由各自接口渐进加载。
class LKReaderBootstrap {
  final LKBook book;
  final bool inShelf;
  final bool hasHistory;
  final int readVolumeId;
  final int readChapterId;
  final String readChapterTitle;
  final bool resumeAvailable;

  const LKReaderBootstrap({
    required this.book,
    this.inShelf = false,
    this.hasHistory = false,
    this.readVolumeId = 0,
    this.readChapterId = 0,
    this.readChapterTitle = '',
    this.resumeAvailable = false,
  });

  factory LKReaderBootstrap.fromJson(Map<String, dynamic> j) {
    final rawBook = _jsonMap(j['book']) ?? const <String, dynamic>{};
    final summary = _jsonMap(j['book_summary']) ?? const <String, dynamic>{};
    final stats = _jsonMap(j['book_stats']) ?? const <String, dynamic>{};
    final readTarget = _jsonMap(j['read_target']) ?? const <String, dynamic>{};
    final effective =
        _jsonMap(j['effective_read_target']) ?? const <String, dynamic>{};
    final library = _jsonMap(j['library_state']) ?? const <String, dynamic>{};
    final defaultVolume =
        _jsonMap(j['default_volume']) ?? const <String, dynamic>{};

    final rawSummary = j['book_summary'];
    final fullSummary =
        (summary['summary'] ?? (rawSummary is String ? rawSummary : ''))
            .toString()
            .trim();
    final shortSummary =
        (summary['summary_short'] ?? rawBook['summary_short'] ?? '')
            .toString()
            .trim();
    final mergedBook = <String, dynamic>{
      ...rawBook,
      if (fullSummary.isNotEmpty) 'summary': fullSummary,
      if (fullSummary.isEmpty && shortSummary.isNotEmpty)
        'summary_short': shortSummary,
      if (_jsonInt(rawBook['volume_count']) <= 0)
        'volume_count': stats['volume_count'],
      if (_jsonInt(rawBook['chapter_count']) <= 0)
        'chapter_count': stats['chapter_count'],
      if (_jsonInt(rawBook['default_volume_id']) <= 0)
        'default_volume_id':
            readTarget['default_volume_id'] ?? defaultVolume['volume_id'],
      if (_jsonInt(rawBook['default_chapter_id']) <= 0)
        'default_chapter_id': readTarget['default_chapter_id'] ??
            defaultVolume['first_chapter_id'],
    };
    final book = LKBook.fromJson(mergedBook);
    final readVolumeId = _jsonInt(effective['volume_id'] ??
        library['last_read_volume_id'] ??
        book.defaultVolumeId);
    final readChapterId = _jsonInt(effective['chapter_id'] ??
        library['last_read_chapter_id'] ??
        book.defaultChapterId);
    final resumeAvailable = _jsonFlag(effective['resume_available']) ||
        (effective['source'] ?? '').toString() == 'history';

    return LKReaderBootstrap(
      book: book,
      inShelf: _jsonFlag(library['in_shelf']),
      hasHistory: _jsonFlag(library['has_history']) || resumeAvailable,
      readVolumeId: readVolumeId,
      readChapterId: readChapterId,
      readChapterTitle: (effective['chapter_title'] ??
              library['last_read_chapter_title'] ??
              book.lastReadChapterTitle)
          .toString(),
      resumeAvailable: resumeAvailable,
    );
  }
}

String bookStatusLabel(LKBook book) {
  final status = book.serialStatus.trim().toLowerCase().replaceAll('-', '_');
  if (const {
    'serial',
    'serializing',
    'ongoing',
    'in_progress',
    'publishing',
    '0',
    '连载',
    '连载中',
    '未完结',
  }.contains(status)) {
    return '连载';
  }
  if (const {
    'complete',
    'completed',
    'finished',
    'done',
    'ended',
    'end',
    '1',
    '完结',
    '已完结',
    '完本',
  }.contains(status)) {
    return '完结';
  }
  return book.isCompleted ? '完结' : '连载';
}

class LKVolume {
  final int volumeId;
  final String title;
  final String intro;
  final int chapterCount;
  final int firstChapterId;
  final int lastChapterId;
  LKVolume({
    this.volumeId = 0,
    this.title = '',
    this.intro = '',
    this.chapterCount = 0,
    this.firstChapterId = 0,
    this.lastChapterId = 0,
  });
  factory LKVolume.fromJson(Map<String, dynamic> j) => LKVolume(
        volumeId: (j['volume_id'] as num?)?.toInt() ?? 0,
        title: (j['title'] as String?) ?? '',
        intro: (j['intro'] as String?) ?? '',
        chapterCount: _jsonInt(j['chapter_count']),
        firstChapterId: _jsonInt(j['first_chapter_id']),
        lastChapterId: _jsonInt(j['last_chapter_id']),
      );
}

class LKChapter {
  final int chapterId;
  final int chapterNo;
  final String title;
  final int wordCount;
  final bool locked;
  final bool unlocked;
  final String accessType;
  final bool braveRequired;
  LKChapter({
    this.chapterId = 0,
    this.chapterNo = 0,
    this.title = '',
    this.wordCount = 0,
    this.locked = false,
    this.unlocked = false,
    this.accessType = '',
    this.braveRequired = false,
  });
  factory LKChapter.fromJson(Map<String, dynamic> j) => LKChapter(
        chapterId: (j['chapter_id'] as num?)?.toInt() ?? 0,
        chapterNo: (j['chapter_no'] as num?)?.toInt() ?? 0,
        title: (j['title'] as String?) ?? '',
        wordCount: (j['word_count'] as num?)?.toInt() ?? 0,
        locked: (j['locked'] as num?)?.toInt() == 1,
        unlocked: (j['unlocked'] as num?)?.toInt() == 1,
        accessType:
            (j['access_type'] as String?) ?? (j['accessType'] as String?) ?? '',
        braveRequired: _jsonFlag(j['brave_required'] ?? j['braveRequired']),
      );

  bool get braveOnly => accessType.toLowerCase() == 'brave' || braveRequired;
}

class LKChapterPage {
  final List<LKChapter> items;
  final int page;
  final int pageSize;
  final int total;
  final bool hasMore;

  const LKChapterPage({
    this.items = const [],
    this.page = 1,
    this.pageSize = 50,
    this.total = 0,
    this.hasMore = false,
  });

  factory LKChapterPage.fromJson(Map<String, dynamic> j,
      {int fallbackPage = 1, int fallbackPageSize = 50}) {
    final rawList = j['list'] ?? j['items'] ?? const [];
    final items = rawList is List
        ? rawList
            .whereType<Map>()
            .map((item) => LKChapter.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false)
        : const <LKChapter>[];
    final pagination = _jsonMap(j['pagination']) ?? const <String, dynamic>{};
    final pageInfo = _jsonMap(j['page_info']) ?? const <String, dynamic>{};
    final page = _jsonInt(pagination['page'] ??
        pagination['current_page'] ??
        pageInfo['cur'] ??
        j['page'] ??
        fallbackPage);
    final pageSize = _jsonInt(pagination['page_size'] ??
        pagination['pageSize'] ??
        pagination['per_page'] ??
        pageInfo['size'] ??
        j['page_size'] ??
        j['pageSize'] ??
        fallbackPageSize);
    final total = _jsonInt(pagination['total'] ??
        pagination['total_count'] ??
        pageInfo['count'] ??
        j['chapter_count'] ??
        j['total']);
    final rawHasMore = pagination['has_more'] ??
        pagination['hasMore'] ??
        pagination['has_next'] ??
        pageInfo['has_next'] ??
        j['has_more'] ??
        j['hasMore'] ??
        j['has_next'];
    final effectivePage = page > 0 ? page : fallbackPage;
    final effectivePageSize = pageSize > 0 ? pageSize : fallbackPageSize;
    return LKChapterPage(
      items: items,
      page: effectivePage,
      pageSize: effectivePageSize,
      total: total,
      hasMore: rawHasMore == null
          ? total > effectivePage * effectivePageSize ||
              items.length >= effectivePageSize
          : _jsonFlag(rawHasMore),
    );
  }
}

class LKChapterDetail {
  final int chapterId;
  final int chapterNo;
  final int volumeId;
  final String title;
  final String bookTitle;
  final String bodyText;
  final String? bodyHtml;
  final bool locked;
  final bool unlocked;
  final int coinPrice;
  final int? prevChapterId;
  final String? prevTitle;
  final int? prevVolumeId;
  final int? nextChapterId;
  final String? nextTitle;
  final int? nextVolumeId;
  LKChapterDetail({
    this.chapterId = 0,
    this.chapterNo = 0,
    this.volumeId = 0,
    this.title = '',
    this.bookTitle = '',
    this.bodyText = '',
    this.bodyHtml,
    this.locked = false,
    this.unlocked = false,
    this.coinPrice = 0,
    this.prevChapterId,
    this.prevTitle,
    this.prevVolumeId,
    this.nextChapterId,
    this.nextTitle,
    this.nextVolumeId,
  });

  /// 本地正文缓存专用序列化,不包含登录凭据或其他会话信息。
  Map<String, dynamic> toCacheJson() => {
        'chapter_id': chapterId,
        'chapter_no': chapterNo,
        'volume_id': volumeId,
        'title': title,
        'book_title': bookTitle,
        'body_text': bodyText,
        'body_html': bodyHtml,
        'locked': locked,
        'unlocked': unlocked,
        'coin_price': coinPrice,
        'prev_chapter_id': prevChapterId,
        'prev_title': prevTitle,
        'prev_volume_id': prevVolumeId,
        'next_chapter_id': nextChapterId,
        'next_title': nextTitle,
        'next_volume_id': nextVolumeId,
      };

  factory LKChapterDetail.fromCacheJson(Map<String, dynamic> j) =>
      LKChapterDetail(
        chapterId: (j['chapter_id'] as num?)?.toInt() ?? 0,
        chapterNo: (j['chapter_no'] as num?)?.toInt() ?? 0,
        volumeId: (j['volume_id'] as num?)?.toInt() ?? 0,
        title: (j['title'] as String?) ?? '',
        bookTitle: (j['book_title'] as String?) ?? '',
        bodyText: (j['body_text'] as String?) ?? '',
        bodyHtml: j['body_html'] as String?,
        locked: j['locked'] == true,
        unlocked: j['unlocked'] == true,
        coinPrice: (j['coin_price'] as num?)?.toInt() ?? 0,
        prevChapterId: (j['prev_chapter_id'] as num?)?.toInt(),
        prevTitle: j['prev_title'] as String?,
        prevVolumeId: (j['prev_volume_id'] as num?)?.toInt(),
        nextChapterId: (j['next_chapter_id'] as num?)?.toInt(),
        nextTitle: j['next_title'] as String?,
        nextVolumeId: (j['next_volume_id'] as num?)?.toInt(),
      );

  bool hasSameContent(LKChapterDetail other) =>
      bodyText == other.bodyText &&
      bodyHtml == other.bodyHtml &&
      locked == other.locked &&
      unlocked == other.unlocked;

  factory LKChapterDetail.fromJson(Map<String, dynamic> j) {
    String body = '';
    String? html;
    final snap = _firstJsonMap(j['body_snapshot']);
    if (snap != null) {
      if (snap['body_text'] is String) body = snap['body_text'] as String;
      if (snap['body_html'] is String) html = snap['body_html'] as String;
    }
    if (body.isEmpty) {
      final prev = _firstJsonMap(j['render_preview']);
      if (prev != null && prev['body_text'] is String) {
        body = prev['body_text'] as String;
      }
    }
    final nav = _jsonMap(j['navigation']);
    // prev_chapter/next_chapter 可能是对象,也可能是数组(服务端形态不一)
    final prevRaw = nav?['prev_chapter'];
    Map<String, dynamic>? prev0;
    if (prevRaw is Map<String, dynamic>) {
      prev0 = prevRaw;
    } else if (prevRaw is List &&
        prevRaw.isNotEmpty &&
        prevRaw.first is Map<String, dynamic>) {
      prev0 = prevRaw.first as Map<String, dynamic>;
    }
    final nextRaw = nav?['next_chapter'];
    Map<String, dynamic>? next;
    if (nextRaw is Map<String, dynamic>) {
      next = nextRaw;
    } else if (nextRaw is List &&
        nextRaw.isNotEmpty &&
        nextRaw.first is Map<String, dynamic>) {
      next = nextRaw.first as Map<String, dynamic>;
    }
    return LKChapterDetail(
      chapterId: (j['chapter_id'] as num?)?.toInt() ?? 0,
      chapterNo: (j['chapter_no'] as num?)?.toInt() ?? 0,
      volumeId: (j['volume_id'] as num?)?.toInt() ?? 0,
      title: (j['title'] as String?) ?? '',
      bookTitle: (j['book_title'] as String?) ?? '',
      bodyText: body,
      bodyHtml: html,
      locked: _jsonFlag(j['locked']),
      unlocked: _jsonFlag(j['unlocked']),
      coinPrice: (j['coin_price'] as num?)?.toInt() ?? 0,
      prevChapterId:
          prev0 != null ? (prev0['chapter_id'] as num?)?.toInt() : null,
      prevTitle: prev0 != null ? (prev0['title'] as String?) : null,
      prevVolumeId:
          prev0 != null ? (prev0['volume_id'] as num?)?.toInt() : null,
      nextChapterId:
          next != null ? (next['chapter_id'] as num?)?.toInt() : null,
      nextTitle: next != null ? (next['title'] as String?) : null,
      nextVolumeId: next != null ? (next['volume_id'] as num?)?.toInt() : null,
    );
  }
}

class LKParagraph {
  final int paragraphNo;
  final String hash;
  final int bodyVersion;
  final String text;
  LKParagraph(
      {this.paragraphNo = 0,
      this.hash = '',
      this.bodyVersion = 0,
      this.text = ''});
  factory LKParagraph.fromJson(Map<String, dynamic> j) => LKParagraph(
        paragraphNo: (j['paragraph_no'] as num?)?.toInt() ?? 0,
        hash: (j['paragraph_hash'] as String?) ?? '',
        bodyVersion: (j['body_version'] as num?)?.toInt() ?? 0,
        text: (j['paragraph_text'] as String?) ??
            (j['paragraph_excerpt'] as String?) ??
            '',
      );
}

/// 评论表情(单个)
class LKEmojiItem {
  final String id;
  final String code; // 如 {:neko3:} 或原生 emoji 字符
  final String url; // 图片地址(原生 emoji 时为空字符串)
  LKEmojiItem({this.id = '', this.code = '', this.url = ''});
  bool get isImage => url.startsWith('http');
  factory LKEmojiItem.fromJson(Map<String, dynamic> j) {
    // id 可能是数字或字符串("13")
    final rawId = j['id'];
    return LKEmojiItem(
      id: rawId is num ? rawId.toString() : (rawId as String? ?? ''),
      code: (j['code'] as String?) ?? '',
      url: (j['url'] as String?) ?? '',
    );
  }
}

/// 评论表情分组
class LKEmojiGroup {
  final String name;
  final String icon; // 分组图标(网络图)
  final List<LKEmojiItem> items;
  LKEmojiGroup({this.name = '', this.icon = '', this.items = const []});
  factory LKEmojiGroup.fromJson(Map<String, dynamic> j) => LKEmojiGroup(
        name: (j['name'] as String?) ?? '',
        icon: (j['icon'] as String?) ?? '',
        items: ((j['items'] as List?) ?? const [])
            .map((e) => LKEmojiItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class LKComment {
  final int commentId;
  final int rootCommentId;
  final int replyToCommentId;
  final int userUid;
  final String nickname;
  final String replyToNickname;
  final String avatar;
  final String content;
  final int likeCount;
  final String time;
  final bool liked;
  final List<LKDynamicMedia> media;
  final int replyCount;
  final List<LKComment> replies;
  LKComment({
    this.commentId = 0,
    this.rootCommentId = 0,
    this.replyToCommentId = 0,
    this.userUid = 0,
    this.nickname = '',
    this.replyToNickname = '',
    this.avatar = '',
    this.content = '',
    this.likeCount = 0,
    this.time = '',
    this.liked = false,
    this.media = const [],
    this.replyCount = 0,
    this.replies = const [],
  });

  static List<LKComment> _parseReplies(dynamic value) {
    dynamic raw = value;
    if (raw is Map) {
      raw = raw['list'] ?? raw['items'] ?? raw['replies'];
    }
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => LKComment.fromJson(Map<String, dynamic>.from(e),
            parseReplies: false))
        .toList();
  }

  factory LKComment.fromJson(Map<String, dynamic> j,
      {bool parseReplies = true}) {
    final author = _jsonMap(j['author']) ??
        _jsonMap(j['user']) ??
        const <String, dynamic>{};
    final replyAuthor = _jsonMap(j['reply_to_user']) ??
        _jsonMap(j['reply_author']) ??
        _jsonMap(j['replyToUser']) ??
        const <String, dynamic>{};
    final replyTarget = _jsonMap(j['reply_to']) ??
        _jsonMap(j['replyTo']) ??
        const <String, dynamic>{};
    final inter = _jsonMap(j['interaction_state']) ?? const <String, dynamic>{};
    final stats = _jsonMap(j['stats']) ?? const <String, dynamic>{};
    dynamic rawMedia =
        j['media_json'] ?? j['media'] ?? j['images'] ?? j['image_list'];
    if (rawMedia is String && rawMedia.isNotEmpty) {
      try {
        rawMedia = jsonDecode(rawMedia);
      } catch (_) {
        rawMedia = null;
      }
    }
    final media = rawMedia is List
        ? rawMedia
            .whereType<Map>()
            .map((e) => LKDynamicMedia.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.url.isNotEmpty)
            .toList()
        : const <LKDynamicMedia>[];
    final rawReplies =
        j['replies'] ?? j['reply_list'] ?? j['reply_preview'] ?? j['children'];
    return LKComment(
      commentId:
          _jsonInt(j['comment_id'] ?? j['tid'] ?? j['commentId'] ?? j['id']),
      rootCommentId: _jsonInt(j['root_comment_id'] ?? j['rootCommentId']),
      replyToCommentId: _jsonInt(j['reply_comment_id'] ??
          j['replyCommentId'] ??
          j['parent_comment_id'] ??
          j['parentCommentId'] ??
          replyTarget['comment_id'] ??
          replyTarget['id']),
      userUid: _jsonInt(author['uid'] ??
          author['user_id'] ??
          author['id'] ??
          j['author_uid'] ??
          j['user_uid'] ??
          j['uid'] ??
          j['user_id']),
      nickname: (author['nickname'] ?? j['nickname'] ?? '').toString(),
      replyToNickname: (replyAuthor['nickname'] ??
              j['reply_to_nickname'] ??
              j['replyToNickname'] ??
              replyTarget['nickname'] ??
              '')
          .toString(),
      avatar: (author['avatar'] ?? j['avatar'] ?? '').toString(),
      content:
          (j['content'] as String?) ?? (j['content_text'] as String?) ?? '',
      likeCount: _jsonInt(j['like_count'] ??
          j['likeCount'] ??
          j['likes'] ??
          stats['like_count']),
      time:
          (j['publish_time'] as String?) ?? (j['created_at'] as String?) ?? '',
      liked: _jsonFlag(j['liked'] ?? j['is_liked']) ||
          _jsonFlag(inter['liked'] ?? inter['is_liked']),
      media: media,
      replyCount: _jsonInt(j['reply_count'] ??
          j['replyCount'] ??
          j['replies_count'] ??
          j['repliesCount'] ??
          stats['reply_count'] ??
          stats['replies_count'] ??
          (rawReplies is List ? rawReplies.length : 0)),
      replies: parseReplies ? _parseReplies(rawReplies) : const [],
    );
  }
}

/// A page of root comments or replies.
///
/// Book comments use page numbers while dynamic comments use cursors. Keeping
/// both signals avoids guessing pagination from the number of returned rows.
class LKCommentPage {
  final List<LKComment> items;
  final int page;
  final int pageSize;
  final int total;
  final String nextCursor;
  final bool hasMore;
  final LKComment? rootComment;

  const LKCommentPage({
    this.items = const [],
    this.page = 1,
    this.pageSize = 20,
    this.total = 0,
    this.nextCursor = '',
    this.hasMore = false,
    this.rootComment,
  });

  factory LKCommentPage.fromJson(
    Map<String, dynamic> j, {
    int fallbackPage = 1,
    int fallbackPageSize = 20,
  }) {
    dynamic rawList = j['list'] ??
        j['comments'] ??
        j['replies'] ??
        j['reply_list'] ??
        j['items'];
    if (rawList is Map) {
      rawList = rawList['list'] ??
          rawList['comments'] ??
          rawList['replies'] ??
          rawList['items'];
    }
    final items = rawList is List
        ? rawList
            .whereType<Map>()
            .map((item) => LKComment.fromJson(Map<String, dynamic>.from(item)))
            .toList(growable: false)
        : const <LKComment>[];
    final pageInfo = _jsonMap(j['page_info']) ??
        _jsonMap(j['pagination']) ??
        const <String, dynamic>{};
    final page = _jsonInt(pageInfo['cur'] ??
        pageInfo['page'] ??
        pageInfo['current_page'] ??
        j['page'] ??
        fallbackPage);
    final pageSize = _jsonInt(pageInfo['size'] ??
        pageInfo['page_size'] ??
        pageInfo['pageSize'] ??
        j['page_size'] ??
        j['pageSize'] ??
        fallbackPageSize);
    final total = _jsonInt(pageInfo['count'] ??
        pageInfo['total'] ??
        pageInfo['total_count'] ??
        j['total']);
    final nextCursor =
        (j['next_cursor'] ?? pageInfo['next_cursor'] ?? '').toString();
    final rawHasMore = j['has_more'] ??
        j['hasMore'] ??
        j['has_next'] ??
        pageInfo['has_more'] ??
        pageInfo['hasMore'] ??
        pageInfo['has_next'];
    final effectivePage = page > 0 ? page : fallbackPage;
    final effectivePageSize = pageSize > 0 ? pageSize : fallbackPageSize;
    final rawRoot = _jsonMap(j['root_comment']);
    final rootComment =
        rawRoot != null && _jsonInt(rawRoot['comment_id'] ?? rawRoot['id']) > 0
            ? LKComment.fromJson(rawRoot)
            : null;
    return LKCommentPage(
      items: items,
      page: effectivePage,
      pageSize: effectivePageSize,
      total: total,
      nextCursor: nextCursor,
      hasMore: rawHasMore == null
          ? nextCursor.isNotEmpty ||
              total > effectivePage * effectivePageSize ||
              items.length >= effectivePageSize
          : _jsonFlag(rawHasMore),
      rootComment: rootComment,
    );
  }
}

typedef LKBookCommentReplyIds = ({
  int rootCommentId,
  int replyCommentId,
});

LKBookCommentReplyIds resolveBookCommentReplyIds(
  LKComment target, {
  int parentCommentId = 0,
}) {
  if (target.commentId <= 0) {
    return (rootCommentId: 0, replyCommentId: 0);
  }
  final isNested = parentCommentId > 0 || target.rootCommentId > 0;
  final rootCommentId = parentCommentId > 0
      ? parentCommentId
      : target.rootCommentId > 0
          ? target.rootCommentId
          : target.commentId;
  return (
    rootCommentId: rootCommentId,
    replyCommentId: isNested ? target.commentId : 0,
  );
}

class LKHistoryItem {
  final int bookId;
  final String title;
  final String authorName;
  final String coverUrl;
  final int volumeId;
  final int chapterId;
  final String chapterTitle;
  final int progressPercent;
  final String lastReadAt;
  final int unreadChapters;
  final bool isBrave;
  LKHistoryItem({
    this.bookId = 0,
    this.title = '',
    this.authorName = '',
    this.coverUrl = '',
    this.volumeId = 0,
    this.chapterId = 0,
    this.chapterTitle = '',
    this.progressPercent = 0,
    this.lastReadAt = '',
    this.unreadChapters = 0,
    this.isBrave = false,
  });
  factory LKHistoryItem.fromJson(Map<String, dynamic> j) {
    final h =
        (j['history'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    return LKHistoryItem(
      bookId: (j['book_id'] as num?)?.toInt() ?? 0,
      title: (j['title'] as String?) ?? '',
      authorName: (j['author_name'] as String?) ?? '',
      coverUrl: (j['cover_url'] as String?) ?? '',
      volumeId: (h['volume_id'] as num?)?.toInt() ??
          (j['default_volume_id'] as num?)?.toInt() ??
          0,
      chapterId: (h['chapter_id'] as num?)?.toInt() ??
          (j['last_read_chapter_id'] as num?)?.toInt() ??
          0,
      chapterTitle: (h['chapter_title'] as String?) ??
          (j['last_read_chapter_title'] as String?) ??
          '',
      progressPercent: (h['progress_percent'] as num?)?.toInt() ?? 0,
      lastReadAt: (h['last_read_at'] as String?) ?? '',
      unreadChapters: (j['unread_chapter_count'] as num?)?.toInt() ?? 0,
      isBrave: _isBraveBook(j),
    );
  }
}

class LKDynamicMedia {
  final String url;
  final int width;
  final int height;
  final String resId;
  final String resUrl;
  final String resPath;
  final String storedUrl;
  final String sourceUrl;

  const LKDynamicMedia({
    this.url = '',
    this.width = 0,
    this.height = 0,
    this.resId = '',
    this.resUrl = '',
    this.resPath = '',
    this.storedUrl = '',
    this.sourceUrl = '',
  });

  factory LKDynamicMedia.fromJson(Map<String, dynamic> j) => LKDynamicMedia(
        url: (j['url'] ??
                j['src'] ??
                j['res_url'] ??
                j['stored_url'] ??
                j['source_url'] ??
                '')
            .toString(),
        width: _jsonInt(j['width']),
        height: _jsonInt(j['height']),
        resId: (j['res_id'] ?? j['resId'] ?? '').toString(),
        resUrl: (j['res_url'] ?? j['resUrl'] ?? '').toString(),
        resPath: (j['res_path'] ?? j['resPath'] ?? '').toString(),
        storedUrl: (j['stored_url'] ?? j['storedUrl'] ?? '').toString(),
        sourceUrl: (j['source_url'] ?? j['sourceUrl'] ?? '').toString(),
      );
}

class LKDynamicPollOption {
  final String id;
  final String text;
  final String image;
  final int voteCount;
  final double percent;
  final bool selected;

  const LKDynamicPollOption({
    this.id = '',
    this.text = '',
    this.image = '',
    this.voteCount = 0,
    this.percent = 0,
    this.selected = false,
  });

  factory LKDynamicPollOption.fromJson(Map<String, dynamic> j, int index) {
    final rawId = j['option_id'] ?? j['optionId'] ?? j['id'] ?? index + 1;
    return LKDynamicPollOption(
      id: rawId.toString(),
      text: (j['text'] ??
              j['title'] ??
              j['content'] ??
              j['label'] ??
              j['name'] ??
              '')
          .toString(),
      image: (j['image'] ?? j['image_url'] ?? j['imageUrl'] ?? '').toString(),
      voteCount: _jsonInt(j['vote_count'] ?? j['votes']),
      percent: (j['percent'] is num)
          ? (j['percent'] as num).toDouble()
          : double.tryParse('${j['percent'] ?? j['ratio'] ?? ''}') ?? 0,
      selected: _jsonFlag(j['voted']),
    );
  }
}

class LKDynamicPoll {
  final String pollId;
  final String title;
  final String description;
  final String deadlineAt;
  final int participantCount;
  final bool ended;
  final bool voted;
  final bool multiple;
  final List<LKDynamicPollOption> options;

  const LKDynamicPoll({
    this.pollId = '',
    this.title = '',
    this.description = '',
    this.deadlineAt = '',
    this.participantCount = 0,
    this.ended = false,
    this.voted = false,
    this.multiple = false,
    this.options = const [],
  });

  static LKDynamicPoll? tryParse(dynamic raw) {
    final j = _jsonMap(raw);
    if (j == null) return null;
    final source = _jsonMap(j['poll']) ?? j;
    final viewer = source['viewer_option_ids'] is List
        ? (source['viewer_option_ids'] as List).map((e) => e.toString()).toSet()
        : <String>{};
    final rawOptions = source['options'] ??
        source['option_list'] ??
        source['optionList'] ??
        source['items'] ??
        source['vote_options'] ??
        const [];
    if (rawOptions is! List) return null;
    final options = rawOptions
        .whereType<Map>()
        .toList()
        .asMap()
        .entries
        .map((e) {
          final option = LKDynamicPollOption.fromJson(
              Map<String, dynamic>.from(e.value), e.key);
          return viewer.contains(option.id) && !option.selected
              ? LKDynamicPollOption(
                  id: option.id,
                  text: option.text,
                  image: option.image,
                  voteCount: option.voteCount,
                  percent: option.percent,
                  selected: true,
                )
              : option;
        })
        .where(
            (e) => e.id.isNotEmpty && (e.text.isNotEmpty || e.image.isNotEmpty))
        .toList();
    if (options.isEmpty) return null;
    return LKDynamicPoll(
      pollId: (source['poll_id'] ?? source['id'] ?? '').toString(),
      title: (source['title'] ?? source['question'] ?? '').toString(),
      description: (source['description'] ?? source['desc'] ?? '').toString(),
      deadlineAt:
          (source['deadline_at'] ?? source['deadlineAt'] ?? '').toString(),
      participantCount: _jsonInt(source['participant_count'] ??
          source['participantCount'] ??
          source['vote_user_count'] ??
          source['user_count'] ??
          source['total_votes']),
      ended:
          _jsonFlag(source['ended'] ?? source['is_ended'] ?? source['expired']),
      voted: _jsonFlag(source['viewer_voted'] ?? source['voted']) ||
          options.any((e) => e.selected),
      multiple: _jsonFlag(source['allow_multiple'] ?? source['multiple']),
      options: options,
    );
  }
}

class LKDynamicItem {
  final int dynamicId;
  final int authorUid;
  final String targetType;
  final String eventType;
  final String nickname;
  final String avatar;
  final List<LKMedal> authorMedals;
  final String title;
  final String summary;
  final int likeCount;
  final int commentCount;
  final int favoriteCount;
  final bool liked;
  final bool favorited;
  final bool read;
  final String time;
  final int bookId; // 作品卡(带作品链接的动态)
  final String bookTitle;
  final String bookCover;
  final List<LKDynamicMedia> media;
  final LKDynamicPoll? poll;
  String get displayContent {
    if (summary.trim().isNotEmpty) return summary;
    if (title.trim().isNotEmpty) return title;
    // 纯动态的标题由接口放在 target_brief.title 中；作品动态的同一字段
    // 是书名，不能把书名误当成动态正文。
    if (!isWorkPost && bookTitle.trim().isNotEmpty) return bookTitle;
    return '';
  }

  bool get isWorkPost =>
      bookId > 0 ||
      const {
        'book_created',
        'volume_created',
        'chapter_published',
      }.contains(eventType) ||
      const {'book', 'volume', 'chapter'}.contains(targetType);

  LKDynamicItem({
    this.dynamicId = 0,
    this.authorUid = 0,
    this.targetType = '',
    this.eventType = '',
    this.nickname = '',
    this.avatar = '',
    this.authorMedals = const [],
    this.title = '',
    this.summary = '',
    this.likeCount = 0,
    this.commentCount = 0,
    this.favoriteCount = 0,
    this.liked = false,
    this.favorited = false,
    this.read = false,
    this.time = '',
    this.bookId = 0,
    this.bookTitle = '',
    this.bookCover = '',
    this.media = const [],
    this.poll,
  });
  factory LKDynamicItem.fromJson(Map<String, dynamic> j) {
    final author = _jsonMap(j['author']) ?? const <String, dynamic>{};
    final stats = _jsonMap(j['stats']) ?? const <String, dynamic>{};
    final ist = _jsonMap(j['interaction_state']) ?? const <String, dynamic>{};
    final brief = _jsonMap(j['target_brief']) ?? const <String, dynamic>{};
    final targetType =
        (j['target_type'] ?? brief['target_type'] ?? '').toString();
    // target_brief.target_id 对纯动态指向动态内容本身，不能当作书号。
    final rawBookId = brief['book_id'] ??
        (targetType == 'book' ? brief['target_id'] : j['book_id']);
    final rawMedia = j['media'];
    final rawMedals = author['medals'] ??
        author['medal_list'] ??
        author['equipped_medals'] ??
        const [];
    final authorMedals = rawMedals is List
        ? rawMedals
            .whereType<Map>()
            .map((e) => LKMedal.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.image.isNotEmpty)
            .take(5)
            .toList()
        : const <LKMedal>[];
    final media = rawMedia is List
        ? rawMedia
            .whereType<Map>()
            .map((e) => LKDynamicMedia.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.url.isNotEmpty)
            .toList()
        : const <LKDynamicMedia>[];
    return LKDynamicItem(
      dynamicId: _jsonInt(
          j['dynamic_id'] ?? j['activity_id'] ?? j['feed_id'] ?? j['id']),
      authorUid: _jsonInt(author['uid'] ??
          author['user_id'] ??
          author['id'] ??
          j['author_uid'] ??
          j['user_uid'] ??
          j['uid'] ??
          j['user_id']),
      targetType: targetType,
      eventType: (j['event_type'] ?? '').toString(),
      nickname: (author['nickname'] ?? j['nickname'] ?? '').toString(),
      avatar: (author['avatar'] ?? j['avatar'] ?? '').toString(),
      authorMedals: authorMedals,
      title: (j['title'] ?? '').toString(),
      summary:
          (j['summary'] ?? j['content'] ?? j['content_text'] ?? '').toString(),
      likeCount: _jsonInt(stats['like_count'] ?? j['like_count'] ?? j['likes']),
      commentCount: _jsonInt(
          stats['comment_count'] ?? j['comment_count'] ?? j['comments']),
      favoriteCount: _jsonInt(
          stats['favorite_count'] ?? stats['favorites'] ?? j['favorite_count']),
      liked: _jsonFlag(ist['liked']),
      favorited: _jsonFlag(ist['favorited']),
      read: _jsonFlag(ist['read'] ?? j['read'] ?? j['is_read']),
      time: (j['feed_time'] ??
              j['publish_time'] ??
              j['created_at'] ??
              j['createdAt'] ??
              j['time'] ??
              '')
          .toString(),
      bookId: _jsonInt(rawBookId),
      bookTitle: (brief['title'] ?? '').toString(),
      bookCover: (brief['cover_url'] ?? '').toString(),
      media: media,
      poll: LKDynamicPoll.tryParse(
          j['poll'] ?? j['vote'] ?? j['poll_json'] ?? j['extension']),
    );
  }
}

class LKDynamicPage {
  final List<LKDynamicItem> items;
  final String cursor;
  final bool hasMore;

  LKDynamicPage({
    this.items = const [],
    this.cursor = '',
    this.hasMore = false,
  });

  factory LKDynamicPage.fromJson(Map<String, dynamic> j) {
    final rawList = j['list'] ?? j['items'] ?? j['feed'] ?? const [];
    final items = rawList is List
        ? rawList
            .whereType<Map>()
            .map((e) => LKDynamicItem.fromJson(Map<String, dynamic>.from(e)))
            .toList()
        : const <LKDynamicItem>[];
    final pageInfo = _jsonMap(j['page_info']) ??
        _jsonMap(j['pagination']) ??
        const <String, dynamic>{};
    final cursor =
        (j['next_cursor'] ?? j['cursor'] ?? pageInfo['next_cursor'] ?? '')
            .toString();
    final rawHasMore = j['has_more'] ??
        j['hasMore'] ??
        j['has_next'] ??
        pageInfo['has_more'] ??
        pageInfo['hasMore'] ??
        pageInfo['has_next'];
    return LKDynamicPage(
      items: items,
      cursor: cursor,
      hasMore: rawHasMore == null ? cursor.isNotEmpty : _jsonFlag(rawHasMore),
    );
  }
}

class LKConversation {
  final int conversationId;
  final int peerUid;
  final String peerName;
  final String peerAvatar;
  final String lastMessage;
  final int unread;
  final String updatedAt;
  LKConversation({
    this.conversationId = 0,
    this.peerUid = 0,
    this.peerName = '',
    this.peerAvatar = '',
    this.lastMessage = '',
    this.unread = 0,
    this.updatedAt = '',
  });
  factory LKConversation.fromJson(Map<String, dynamic> j) {
    final peerRaw = j['peer'] ?? j['user'] ?? j['target_user'];
    final peer = _jsonMap(peerRaw) ?? const <String, dynamic>{};
    final lastMessage = _jsonMap(j['last_message']);
    return LKConversation(
      conversationId:
          _jsonInt(j['conversation_id'] ?? j['thread_id'] ?? j['id']),
      peerUid: _jsonInt(j['peer_uid'] ?? peer['uid'] ?? peer['id']),
      peerName: (peer['nickname'] ??
              peer['username'] ??
              j['peer_name'] ??
              j['nickname'] ??
              '')
          .toString(),
      peerAvatar:
          (peer['avatar'] ?? peer['avatar_url'] ?? j['peer_avatar'] ?? '')
              .toString(),
      lastMessage: _msgText(j['last_message'] ??
          j['last_message_text'] ??
          j['summary'] ??
          j['content']),
      unread: _jsonInt(j['unread_count'] ?? j['unreadCount'] ?? j['unread']),
      updatedAt: (j['updated_at'] ??
              j['last_message_at'] ??
              lastMessage?['created_at'] ??
              lastMessage?['time'] ??
              j['time'] ??
              '')
          .toString(),
    );
  }
}

/// 消息文本:可能是 String 或 {content/preview/text} 对象
String _msgText(dynamic v) {
  if (v is String) return v;
  if (v is Map) {
    for (final k in const [
      'preview',
      'content',
      'content_text',
      'text',
      'summary',
      'message',
      'title',
    ]) {
      final s = v[k];
      if (s is String && s.isNotEmpty) return s;
    }
  }
  return '';
}

class LKDMMessage {
  final int id;
  final int senderUid;
  final String content;
  final String time;
  bool isMine(int myUid) => senderUid == myUid;
  LKDMMessage(
      {this.id = 0, this.senderUid = 0, this.content = '', this.time = ''});
  factory LKDMMessage.fromJson(Map<String, dynamic> j) => LKDMMessage(
        id: _jsonInt(j['message_id'] ?? j['id']),
        senderUid: _jsonInt(j['sender_uid'] ??
            _jsonMap(j['sender'])?['uid'] ??
            _jsonMap(j['user'])?['uid']),
        content: _msgText(
            j['content_text'] ?? j['content'] ?? j['body'] ?? j['text']),
        time: (j['created_at'] ?? j['sent_at'] ?? j['time'] ?? '').toString(),
      );
}

class LKMessageSummary {
  final int unreadCount;
  final int replyCount;
  final int mentionCount;
  final int likeCount;
  final int fanCount;
  final int systemCount;
  final int dmCount;

  const LKMessageSummary({
    this.unreadCount = 0,
    this.replyCount = 0,
    this.mentionCount = 0,
    this.likeCount = 0,
    this.fanCount = 0,
    this.systemCount = 0,
    this.dmCount = 0,
  });

  factory LKMessageSummary.fromJson(Map<String, dynamic> j) {
    final counts = _jsonMap(j['counts']) ??
        _jsonMap(j['unread']) ??
        const <String, dynamic>{};
    dynamic value(List<String> keys) {
      for (final key in keys) {
        if (j.containsKey(key)) return j[key];
        if (counts.containsKey(key)) return counts[key];
      }
      return null;
    }

    final reply = _jsonInt(value(const ['reply_count', 'replies']));
    final mention = _jsonInt(value(const ['mention_count', 'mentions']));
    final like = _jsonInt(value(const ['like_count', 'likes']));
    final fan = _jsonInt(value(const ['fan_count', 'fans', 'follow_count']));
    final system = _jsonInt(
        value(const ['system_count', 'notifications', 'notice_count']));
    final dm = _jsonInt(
        value(const ['dm_count', 'dm_unread', 'direct_message_count']));
    final totalValue =
        value(const ['unread_count', 'unreadCount', 'total_unread', 'total']);
    return LKMessageSummary(
      unreadCount: totalValue == null
          ? reply + mention + like + fan + system + dm
          : _jsonInt(totalValue),
      replyCount: reply,
      mentionCount: mention,
      likeCount: like,
      fanCount: fan,
      systemCount: system,
      dmCount: dm,
    );
  }

  int countFor(String type) => switch (type) {
        'reply' => replyCount,
        'mention' => mentionCount,
        'like' => likeCount,
        'fan' => fanCount,
        'system' => systemCount,
        'dm' => dmCount,
        _ => unreadCount,
      };

  LKMessageSummary clearCategory(String type) {
    final cleared = LKMessageSummary(
      replyCount: type == 'reply' ? 0 : replyCount,
      mentionCount: type == 'mention' ? 0 : mentionCount,
      likeCount: type == 'like' ? 0 : likeCount,
      fanCount: type == 'fan' ? 0 : fanCount,
      systemCount: type == 'system' ? 0 : systemCount,
      dmCount: type == 'dm' ? 0 : dmCount,
    );
    return cleared._withCalculatedTotal();
  }

  LKMessageSummary clearDm([int count = 0]) {
    final nextDm = count <= 0 ? 0 : (dmCount - count).clamp(0, dmCount);
    final cleared = LKMessageSummary(
      replyCount: replyCount,
      mentionCount: mentionCount,
      likeCount: likeCount,
      fanCount: fanCount,
      systemCount: systemCount,
      dmCount: nextDm,
    );
    return cleared._withCalculatedTotal();
  }

  LKMessageSummary clearNotifications() =>
      LKMessageSummary(dmCount: dmCount, unreadCount: dmCount);

  LKMessageSummary _withCalculatedTotal() => LKMessageSummary(
        unreadCount: replyCount +
            mentionCount +
            likeCount +
            fanCount +
            systemCount +
            dmCount,
        replyCount: replyCount,
        mentionCount: mentionCount,
        likeCount: likeCount,
        fanCount: fanCount,
        systemCount: systemCount,
        dmCount: dmCount,
      );
}

class LKMessageUser {
  final int uid;
  final String nickname;
  final String avatar;

  const LKMessageUser({
    this.uid = 0,
    this.nickname = '',
    this.avatar = '',
  });

  factory LKMessageUser.fromJson(Map<String, dynamic> j) {
    final uid = _jsonInt(j['uid'] ?? j['id'] ?? j['user_id']);
    final nickname =
        (j['nickname'] ?? j['username'] ?? j['name'] ?? '').toString();
    final avatar =
        (j['avatar'] ?? j['avatar_url'] ?? j['headimgurl'] ?? '').toString();
    return LKMessageUser(uid: uid, nickname: nickname, avatar: avatar);
  }
}

class LKMessageItem {
  final int id;
  final String type;
  final String messageKind;
  final String categoryCode;
  final String title;
  final String content;
  final String quoteText;
  final String relatedTitle;
  final String categoryText;
  final String sourceName;
  final String sourceAvatar;
  final int uid;
  final String nickname;
  final String avatar;
  final String time;
  final String targetType;
  final String targetUrl;
  final String contentTargetUrl;
  final int targetBookId;
  final int targetVolumeId;
  final int targetChapterId;
  final int targetDynamicId;
  final int targetCommentId;
  final int targetReplyId;
  final int rootCommentId;
  final bool unread;
  final List<LKMessageUser> likeUsers;
  final int likeCount;
  final String jumpType;
  final String jumpTarget;
  final String jumpValue;
  final String targetBookTitle;
  final String targetCover;

  const LKMessageItem({
    this.id = 0,
    this.type = '',
    this.messageKind = '',
    this.categoryCode = '',
    this.title = '',
    this.content = '',
    this.quoteText = '',
    this.relatedTitle = '',
    this.categoryText = '',
    this.sourceName = '',
    this.sourceAvatar = '',
    this.uid = 0,
    this.nickname = '',
    this.avatar = '',
    this.time = '',
    this.targetType = '',
    this.targetUrl = '',
    this.contentTargetUrl = '',
    this.targetBookId = 0,
    this.targetVolumeId = 0,
    this.targetChapterId = 0,
    this.targetDynamicId = 0,
    this.targetCommentId = 0,
    this.targetReplyId = 0,
    this.rootCommentId = 0,
    this.unread = false,
    this.likeUsers = const [],
    this.likeCount = 0,
    this.jumpType = '',
    this.jumpTarget = '',
    this.jumpValue = '',
    this.targetBookTitle = '',
    this.targetCover = '',
  });

  factory LKMessageItem.fromJson(Map<String, dynamic> j, {String type = ''}) {
    final userRaw = j['user'] ?? j['author'];
    final peer = _jsonMap(userRaw ?? j['sender']) ?? const <String, dynamic>{};
    final source = _jsonMap(j['source']) ?? const <String, dynamic>{};
    final target = _jsonMap(j['target']) ?? const <String, dynamic>{};
    final book = _jsonMap(j['book']) ?? const <String, dynamic>{};
    final volume = _jsonMap(j['volume']) ?? const <String, dynamic>{};
    final chapter = _jsonMap(j['chapter']) ?? const <String, dynamic>{};
    final dynamicItem = _jsonMap(j['dynamic']) ?? const <String, dynamic>{};
    final comment = _jsonMap(j['comment']) ?? const <String, dynamic>{};
    final reply = _jsonMap(j['reply']) ?? const <String, dynamic>{};
    final rootComment =
        _jsonMap(j['root_comment']) ?? const <String, dynamic>{};
    final targetUrl = (j['target_url'] ?? '').toString();
    final contentTargetUrl = (j['content_target_url'] ?? '').toString();
    int idFromUrl(RegExp pattern) {
      final match = pattern.firstMatch('$targetUrl $contentTargetUrl');
      return _jsonInt(match?.group(1));
    }

    int firstPositiveId(Iterable<dynamic> values) {
      for (final value in values) {
        final id = _jsonInt(value);
        if (id > 0) return id;
      }
      return 0;
    }

    final urlCommentId = idFromUrl(RegExp(r'[?&]comment_id=(\d+)'));
    final urlReplyId = idFromUrl(RegExp(r'[?&]reply_id=(\d+)'));

    final unreadValue = j['unread'];
    final unread = unreadValue != null
        ? _jsonFlag(unreadValue)
        : j.containsKey('is_read')
            ? !_jsonFlag(j['is_read'])
            : false;

    final fallbackTitle = switch (type) {
      'reply' => '回复我的',
      'mention' => '提及我的',
      'like' => '收到的赞',
      'fan' => '新的粉丝',
      _ => '系统通知',
    };

    final usersRaw = j['users'] ?? j['like_users'] ?? j['actors'];
    final likeUsers = <LKMessageUser>[];
    if (usersRaw is List) {
      for (final u in usersRaw) {
        if (u is Map) {
          likeUsers.add(LKMessageUser.fromJson(Map<String, dynamic>.from(u)));
        }
      }
    }
    final singleUid = _jsonInt(j['source_uid'] ??
        source['uid'] ??
        source['id'] ??
        peer['uid'] ??
        peer['id']);
    final singleNick = (peer['nickname'] ??
            peer['username'] ??
            peer['name'] ??
            source['nickname'] ??
            source['name'] ??
            '')
        .toString();
    final singleAvatar = (peer['avatar'] ??
            peer['avatar_url'] ??
            source['avatar'] ??
            source['avatar_url'] ??
            '')
        .toString();
    if (likeUsers.isEmpty &&
        (singleUid > 0 || singleNick.isNotEmpty || singleAvatar.isNotEmpty)) {
      likeUsers.add(LKMessageUser(
        uid: singleUid,
        nickname: singleNick,
        avatar: singleAvatar,
      ));
    }

    final likeCount = _jsonInt(j['like_count'] ??
        j['likes_count'] ??
        (likeUsers.isNotEmpty ? likeUsers.length : 0));

    final jumpMap = _jsonMap(j['message_jump'] ?? j['jump']) ??
        const <String, dynamic>{};
    final jumpType = (j['jump_type'] ??
            jumpMap['type'] ??
            jumpMap['jump_type'] ??
            '')
        .toString();
    final jumpTarget = (j['jump_target'] ??
            jumpMap['target'] ??
            jumpMap['jump_target'] ??
            '')
        .toString();
    final jumpValue = (j['jump_value'] ??
            jumpMap['value'] ??
            jumpMap['jump_value'] ??
            '')
        .toString();

    final targetBookTitle = (j['target_book_title'] ??
            target['book_title'] ??
            target['title'] ??
            book['title'] ??
            book['book_name'] ??
            '')
        .toString();
    final targetCover = (j['cover_url'] ??
            j['cover'] ??
            target['cover_url'] ??
            target['cover'] ??
            book['cover_url'] ??
            book['cover'] ??
            '')
        .toString();

    final resolvedTargetType = (j['target_type'] ??
            j['targetType'] ??
            target['type'] ??
            jumpType)
        .toString();

    final rawQuoteText = (j['quote_text'] ??
            j['target_text'] ??
            j['target_brief'] ??
            j['quote_info'] ??
            target['text'] ??
            target['content'] ??
            dynamicItem['content'] ??
            '')
        .toString();

    return LKMessageItem(
      id: _jsonInt(j['message_id'] ?? j['id']),
      type: type,
      messageKind: (j['message_kind'] ?? '').toString(),
      categoryCode: (j['category_code'] ?? '').toString(),
      title: (j['title'] ?? j['category_text'] ?? fallbackTitle).toString(),
      content: _msgText(j['content'] ??
          j['content_text'] ??
          j['message'] ??
          j['summary'] ??
          j['body']),
      quoteText: rawQuoteText,
      relatedTitle: (j['related_title'] ?? targetBookTitle).toString(),
      categoryText: (j['category_text'] ?? '').toString(),
      sourceName: (j['source_name'] ??
              source['nickname'] ??
              source['name'] ??
              singleNick)
          .toString(),
      sourceAvatar: (j['source_avatar'] ??
              source['avatar'] ??
              source['avatar_url'] ??
              singleAvatar)
          .toString(),
      uid: singleUid,
      nickname: singleNick,
      avatar: singleAvatar,
      time: (j['created_at'] ?? j['time'] ?? '').toString(),
      targetType: resolvedTargetType,
      targetUrl: targetUrl,
      contentTargetUrl: contentTargetUrl,
      targetBookId: firstPositiveId([
        j['target_book_id'],
        target['book_id'],
        book['book_id'],
        dynamicItem['book_id'],
        if (jumpType == 'book') jumpValue,
        idFromUrl(RegExp(r'/book/(\d+)')),
        idFromUrl(RegExp(r'/reader/(\d+)/\d+')),
      ]),
      targetVolumeId: firstPositiveId([
        j['target_volume_id'],
        target['volume_id'],
        volume['volume_id'],
        volume['id'],
      ]),
      targetChapterId: firstPositiveId([
        j['target_chapter_id'],
        target['chapter_id'],
        chapter['chapter_id'],
        chapter['id'],
        idFromUrl(RegExp(r'/reader/\d+/(\d+)')),
      ]),
      targetDynamicId: firstPositiveId([
        j['target_dynamic_id'],
        target['dynamic_id'],
        dynamicItem['dynamic_id'],
        dynamicItem['id'],
        if (jumpType == 'dynamic' || jumpType == 'activity') jumpValue,
        idFromUrl(RegExp(r'/activity/(\d+)')),
      ]),
      targetCommentId: firstPositiveId([
        j['target_comment_id'],
        comment['comment_id'],
        comment['id'],
        if (jumpType == 'comment') jumpValue,
        urlCommentId,
      ]),
      targetReplyId: firstPositiveId([
        j['target_reply_id'],
        reply['reply_id'],
        reply['id'],
        urlReplyId,
      ]),
      rootCommentId: firstPositiveId([
        j['root_comment_id'],
        rootComment['comment_id'],
        rootComment['id'],
        urlCommentId,
      ]),
      unread: unread,
      likeUsers: likeUsers,
      likeCount: likeCount,
      jumpType: jumpType,
      jumpTarget: jumpTarget,
      jumpValue: jumpValue,
      targetBookTitle: targetBookTitle,
      targetCover: targetCover,
    );
  }
}

class LKMessagePage {
  final List<LKMessageItem> items;
  final int page;
  final int pageSize;
  final int total;
  final bool hasMore;

  const LKMessagePage({
    this.items = const [],
    this.page = 1,
    this.pageSize = 20,
    this.total = 0,
    this.hasMore = false,
  });

  factory LKMessagePage.fromJson(Map<String, dynamic> j,
      {required String type, int fallbackPage = 1, int fallbackPageSize = 20}) {
    final rawList = j['items'] ?? j['list'] ?? j['cards'] ?? const [];
    final items = rawList is List
        ? rawList
            .whereType<Map>()
            .map((item) => LKMessageItem.fromJson(
                Map<String, dynamic>.from(item),
                type: type))
            .toList(growable: false)
        : const <LKMessageItem>[];
    final pagination = _jsonMap(j['pagination']) ??
        _jsonMap(j['page_info']) ??
        const <String, dynamic>{};
    final pageSize = _jsonInt(pagination['page_size'] ??
        pagination['pageSize'] ??
        j['page_size'] ??
        fallbackPageSize);
    final total = _jsonInt(pagination['total'] ??
        pagination['total_count'] ??
        j['total'] ??
        items.length);
    final rawHasMore = pagination['has_next'] ??
        pagination['has_more'] ??
        pagination['hasMore'] ??
        j['has_next'] ??
        j['has_more'] ??
        j['hasMore'];
    final effectivePageSize = pageSize > 0 ? pageSize : fallbackPageSize;
    return LKMessagePage(
      items: items,
      page: fallbackPage,
      pageSize: effectivePageSize,
      total: total,
      hasMore: rawHasMore == null
          ? total > fallbackPage * effectivePageSize ||
              items.length >= effectivePageSize
          : _jsonFlag(rawHasMore),
    );
  }
}

/// GitHub Release 信息(检查更新)
class LKRelease {
  final String tag; // 如 v0.1.0
  final String name;
  final String url;
  final String body;
  LKRelease({this.tag = '', this.name = '', this.url = '', this.body = ''});
  factory LKRelease.fromJson(Map<String, dynamic> j) => LKRelease(
        tag: (j['tag_name'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        url: (j['html_url'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
      );
}

/// 版本号比较(忽略前导 v 与构建号),a>b 返回 1,a<b 返回 -1
int compareVersions(String a, String b) {
  final pa = a.replaceFirst(RegExp(r'^v'), '').split('+').first.split('.');
  final pb = b.replaceFirst(RegExp(r'^v'), '').split('+').first.split('.');
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? (int.tryParse(pa[i]) ?? 0) : 0;
    final y = i < pb.length ? (int.tryParse(pb[i]) ?? 0) : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}
