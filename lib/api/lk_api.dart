import 'lk_client.dart';
import 'models.dart';

/// 全接口分组封装(静态方法,统一走 LKClient.shared)
class LKApi {
  static final LKClient client = LKClient.shared;

  // ==================== 鉴权 ====================

  static Future<void> login(String username, String password) async {
    final d = await client.post('/api/bff/auth-password-login-v1', {
      'username': username,
      'password': password,
    });
    final auth = (d['auth'] as Map<String, dynamic>?) ?? const {};
    final key = (auth['security_key'] as String?) ?? '';
    if (key.isEmpty) throw LKException(-1, '登录响应缺少 auth');
    client.session
      ..securityKey = key
      ..uid = (auth['uid'] as num?)?.toInt() ?? 0;
    final u = (d['user'] as Map<String, dynamic>?) ?? const {};
    client.session
      ..nickname = (u['nickname'] as String?) ?? ''
      ..avatar = (u['avatar'] as String?) ?? '';
  }

  static Future<bool> validateSession() async {
    if (!client.session.isLoggedIn) return false;
    final d = await client.post('/api/bff/auth-session-v1', client.authed());
    final ok = (d['logged_in'] as num?)?.toInt() == 1;
    if (!ok) client.session.securityKey = '';
    return ok;
  }

  static Future<void> logout() async {
    if (client.session.isLoggedIn) {
      try {
        await client.post('/api/bff/logout-v1', client.authed());
      } catch (_) {}
    }
    client.session.securityKey = '';
  }

  // ==================== 首页 / 发现 ====================

  static Future<List<LKBook>> homeFeed(String channel, int page,
      {int pageSize = 20}) async {
    final d = await client.post('/api/bff/home-feed-v1', {
      'channel': channel, 'page': page,
      'pageSize': pageSize, 'page_size': pageSize,
    });
    return _bookList(d);
  }

  static Future<List<LKBook>> channelFeed(String path, int page,
      {int pageSize = 20}) async {
    final d = await client
        .post(path, {'page': page, 'pageSize': pageSize, 'page_size': pageSize});
    return _bookList(d);
  }

  static Future<List<LKBook>> rank(int page, {int pageSize = 20}) async {
    final d = await client.post('/api/bff/book-rank-list-v1',
        {'page': page, 'pageSize': pageSize});
    return _bookList(d);
  }

  static Future<List<LKBook>> search(String q, int page,
      {int pageSize = 20,
      String sort = 'relevance',
      String primaryTag = '',
      String preset = '',
      String channelCode = '',
      String workType = ''}) async {
    final d = await client.post('/api/bff/apk-search-result-v1', {
      'q': q,
      'page': page,
      'pageSize': pageSize,
      'sort': sort,
      'primary_tag': primaryTag,
      'preset': preset,
      'channel_code': channelCode,
      'work_type': workType,
      'filters': '{}',
    });
    return _bookList(d);
  }

  /// 搜索分类(标签/频道/预设)
  static Future<Map<String, dynamic>> searchTaxonomy() async =>
      client.post('/api/bff/apk-search-taxonomy-v1', const {});

  static Future<List<LKBook>> searchSuggest(String q) async {
    final d = await client.post('/api/bff/apk-search-suggest-v1',
        {'q': q, 'limit': 10});
    return _bookList(d);
  }

  static List<LKBook> _bookList(Map<String, dynamic> d) {
    final list = d['list'];
    if (list == null) {
      throw LKException(-1, '接口未返回列表(字段: ${d.keys.join(', ')})');
    }
    return (list as List)
        .map((e) => LKBook.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ==================== 阅读 ====================

  static Future<LKBook> bookDetail(int bookId) async =>
      LKBook.fromJson(await client.post('/api/new-content-read/get-book-detail',
          client.authed({'book_id': bookId, 'with_volumes': 0})));

  static Future<List<LKVolume>> volumes(int bookId, int page,
      {int pageSize = 50}) async {
    final d = await client.post('/api/new-content-read/get-book-volumes', {
      'book_id': bookId, 'page': page, 'pageSize': LKClient.clampPageSize(pageSize),
    });
    return ((d['list'] as List?) ?? const [])
        .map((e) => LKVolume.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<List<LKChapter>> chapters(int bookId, int volumeId, int page,
      {int pageSize = 50}) async {
    final d = await client.post('/api/new-content-read/get-volume-chapters', {
      'book_id': bookId, 'volume_id': volumeId, 'page': page,
      'pageSize': LKClient.clampPageSize(pageSize),
    });
    return ((d['list'] as List?) ?? const [])
        .map((e) => LKChapter.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<LKChapterDetail> chapterDetail(int bookId, int chapterId) async =>
      LKChapterDetail.fromJson(
          await client.post('/api/new-content-read/get-chapter-detail',
              client.authed({'book_id': bookId, 'chapter_id': chapterId})));

  static Future<List<LKParagraph>> paragraphs(int bookId, int chapterId) async {
    final d = await client.post('/api/new-content-read/get-chapter-paragraphs',
        {'book_id': bookId, 'chapter_id': chapterId});
    final list = (d['paragraphs'] as List?) ?? (d['list'] as List?) ?? const [];
    return list.map((e) => LKParagraph.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ==================== 书评 / 段评 ====================

  static Future<List<LKComment>> bookComments(int bookId, int page) async {
    final d = await client.post('/api/new-content-read/get-book-comments', {
      'book_id': bookId, 'page': page, 'pageSize': 20,
      'rating_filter': 'all', 'include_user_interactions': 1,
    });
    return _commentList(d);
  }

  static Future<void> publishBookComment(int bookId, String content) =>
      client.post('/api/discuss/publish-book-comment', client.authed({
        'scope': 'book', 'book_id': bookId, 'volume_id': 0, 'chapter_id': 0,
        'root_comment_id': 0, 'reply_comment_id': 0, 'content': content,
        'rating_stars': 0, 'read_duration_seconds': 0,
      }));

  static Future<void> likeBookComment(int bookId, int commentId, bool like) =>
      client.post('/api/discuss/like-book-comment', client.authed({
        'scope': 'book', 'book_id': bookId, 'volume_id': 0, 'chapter_id': 0,
        'comment_id': commentId, 'root_comment_id': 0,
        'act': like ? 'like' : 'unlike',
      }));

  static Future<List<LKComment>> paragraphComments(int bookId, int chapterId,
      LKParagraph p) async {
    final d = await client.post('/api/new-content-read/get-paragraph-comments', {
      'book_id': bookId, 'chapter_id': chapterId,
      'paragraph_hash': p.hash, 'body_version': p.bodyVersion,
      'paragraph_no': p.paragraphNo, 'page': 1, 'pageSize': 20,
    });
    return _commentList(d);
  }

  static Future<void> publishParagraphComment(int bookId, int chapterId,
      LKParagraph p, String content) =>
      client.post('/api/new-content-read/publish-paragraph-comment', client.authed({
        'book_id': bookId, 'chapter_id': chapterId,
        'paragraph_hash': p.hash, 'body_version': p.bodyVersion,
        'paragraph_no': p.paragraphNo, 'content': content, 'parent_comment_id': 0,
      }));

  static List<LKComment> _commentList(Map<String, dynamic> d) =>
      ((d['list'] as List?) ?? const [])
          .map((e) => LKComment.fromJson(e as Map<String, dynamic>))
          .toList();

  // ==================== 书架 / 历史 / 进度 ====================

  static Future<bool> inShelf(int bookId) async {
    final d = await client.post('/api/new-content-read/get-book-library-state',
        client.authed({'book_id': bookId}));
    return (d['in_shelf'] as num?)?.toInt() == 1;
  }

  static Future<void> toggleShelf(int bookId, bool add) =>
      client.post('/api/new-content-read/toggle-book-shelf', client.authed({
        'book_id': bookId, 'action': add ? 'add' : 'remove', 'source': 'pc_web',
      }));

  static Future<List<LKBook>> bookshelf(int page, {int pageSize = 50}) async {
    final d = await client.post('/api/bff/bookshelf-v1',
        client.authed({'page': page, 'pageSize': LKClient.clampPageSize(pageSize)}));
    return _bookList(d);
  }

  static Future<List<LKHistoryItem>> cloudHistory(int page,
      {int pageSize = 50}) async {
    final d = await client.post('/api/bff/history-v1',
        client.authed({'page': page, 'pageSize': LKClient.clampPageSize(pageSize)}));
    return ((d['list'] as List?) ?? const [])
        .map((e) => LKHistoryItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> saveHistory(int bookId, int volumeId, int chapterId,
      int progressPercent) =>
      client.post('/api/new-content-read/save-book-history', client.authed({
        'book_id': bookId, 'volume_id': volumeId, 'chapter_id': chapterId,
        'progress_percent': progressPercent,
      }));

  static Future<void> deleteHistory(int bookId) =>
      client.post('/api/new-content-read/delete-book-history',
          client.authed({'book_id': bookId}));

  static Future<void> unlockChapter(int chapterId) =>
      client.post('/api/new-content-read/unlock-chapter',
          client.authed({'chapter_id': chapterId}));

  // ==================== 动态 ====================

  static Future<List<LKDynamicItem>> dynamicFeed(
      {String tab = 'follow', String cursor = '', int pageSize = 20}) async {
    final d = await client.post('/api/dynamic/get-feed-v1', client.authed({
      'tab': tab, 'cursor': cursor, 'page': 1,
      'page_size': pageSize, 'pageSize': pageSize,
    }));
    return ((d['list'] as List?) ?? const [])
        .map((e) => LKDynamicItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<List<LKComment>> dynamicComments(int dynamicId) async {
    final d = await client.post('/api/dynamic/get-comments-v1', client.authed({
      'dynamic_id': dynamicId, 'comment_id': 0, 'cursor': '',
      'sort': 'latest', 'page_size': 20, 'pageSize': 20,
    }));
    return _commentList(d);
  }

  static Future<void> publishShortPost(String content) =>
      client.post('/api/dynamic/publish-short-post-v1', client.authed({
        'title': '', 'summary': content, 'content': content, 'media_json': '',
        'request_id': 'app-${DateTime.now().millisecondsSinceEpoch}',
      }));

  static Future<void> toggleDynamicLike(int dynamicId, bool like) =>
      client.post('/api/dynamic/toggle-like-v1',
          client.authed({'dynamic_id': dynamicId, 'act': like ? 'like' : 'unlike'}));

  static Future<void> toggleDynamicFavorite(int dynamicId, bool fav) =>
      client.post('/api/dynamic/toggle-favorite-v1', client.authed(
          {'dynamic_id': dynamicId, 'act': fav ? 'favorite' : 'unfavorite'}));

  static Future<void> deleteDynamic(int dynamicId) =>
      client.post('/api/dynamic/delete-dynamic-v1',
          client.authed({'dynamic_id': dynamicId}));

  // ==================== 消息 / 私信 ====================

  static Future<Map<String, dynamic>> messageUnread() async =>
      client.post('/api/bff/message-unread-v1', client.authed());

  static Future<List<LKMessageItem>> messages(String type, int page) async {
    final path = switch (type) {
      'like' => '/api/bff/message-likes-v1',
      'fan' => '/api/bff/message-fans-v1',
      'system' => '/api/bff/message-system-v1',
      _ => '/api/bff/message-replies-v1',
    };
    final d = await client.post(path,
        client.authed({'page': page, 'page_size': 20}));
    return ((d['list'] as List?) ?? const [])
        .map((e) => LKMessageItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> markMessagesRead(String scope) =>
      client.post('/api/bff/message-mark-read-v1', client.authed({
        'scope': scope,
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'nonce': DateTime.now().microsecondsSinceEpoch.toRadixString(16),
      }));

  static Future<List<LKConversation>> dmConversations() async {
    final d = await client.post('/api/bff/dm-conversations-v1',
        client.authed({'page': 1, 'page_size': 20}));
    return ((d['list'] as List?) ?? const [])
        .map((e) => LKConversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<List<LKDMMessage>> dmMessages(int peerUid) async {
    final d = await client.post('/api/bff/dm-messages-v1',
        client.authed({'peer_uid': peerUid, 'page': 1, 'page_size': 30}));
    return ((d['list'] as List?) ?? const [])
        .map((e) => LKDMMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> dmSend(int peerUid, String content) =>
      client.post('/api/bff/dm-send-v1', client.authed({
        'peer_uid': peerUid, 'content_text': content,
        'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'nonce': DateTime.now().microsecondsSinceEpoch.toRadixString(16),
        'client_msg_id': 'app-${DateTime.now().millisecondsSinceEpoch}',
      }));

  // ==================== 福利 ====================

  static Future<Map<String, dynamic>> welfareHome() async =>
      client.post('/api/bff/welfare-home-v1', client.authed());

  static Future<Map<String, dynamic>> signDetail() async =>
      client.post('/api/bff/welfare-sign-detail-v1', client.authed());

  static Future<void> claimSign() =>
      client.post('/api/bff/claim-welfare-sign-v1', client.authed());

  static Future<Map<String, dynamic>> taskList() async =>
      client.post('/api/bff/welfare-task-list-v1', client.authed());

  static Future<void> claimTask(int taskId) =>
      client.post('/api/bff/claim-welfare-task-v1',
          client.authed({'task_id': taskId}));

  static Future<void> startSleep() =>
      client.post('/api/bff/start-welfare-sleep-v1', client.authed());

  static Future<void> finishSleep() =>
      client.post('/api/bff/finish-welfare-sleep-v1', client.authed());

  static Future<void> claimSleep() =>
      client.post('/api/bff/claim-welfare-sleep-v1', client.authed());

  static Future<Map<String, dynamic>> treasureDetail() async =>
      client.post('/api/bff/welfare-treasure-box-detail-v1', client.authed());

  static Future<void> claimTreasure() =>
      client.post('/api/bff/claim-welfare-treasure-box-v1', client.authed());

  static Future<Map<String, dynamic>> coinRecords() async =>
      client.post('/api/bff/welfare-coin-records-v1',
          client.authed({'page': 1, 'pageSize': 20}));

  // ==================== 用户 / 设置 ====================

  static Future<Map<String, dynamic>> myHome() async =>
      client.post('/api/bff/my-home-v1', client.authed());

  static Future<void> updateProfile(String nickname, String sign) =>
      client.post('/api/bff/update-my-profile-v1', client.authed(
          {'nickname': nickname, 'sign': sign, 'signature': sign}));

  static Future<void> changePassword(String oldPwd, String newPwd) =>
      client.post('/api/bff/settings-change-password-v1',
          client.authed({'password': oldPwd, 'new_password': newPwd}));

  static Future<void> toggleFollow(int uid, bool follow) =>
      client.post('/api/bff/toggle-user-follow-v1',
          client.authed({'uid': uid, 'act': follow ? 'follow' : 'unfollow'}));

  static Future<void> toggleMedal(int medalId, bool equip) =>
      client.post('/api/bff/toggle-my-medal-v1',
          client.authed({'medal_id': medalId, 'act': equip ? 'equip' : 'unequip'}));

  static Future<Map<String, dynamic>> inviteCode() async =>
      client.post('/api/bff/invite-my-code-v1', client.authed());

  static Future<Map<String, dynamic>> about() async =>
      client.post('/api/bff/settings-about-v1', const {});

  static Future<Map<String, dynamic>> updateCheck() async =>
      client.post('/api/bff/settings-update-check-v1', const {});

  // ==================== 作者中心 ====================

  static Future<Map<String, dynamic>> authorStatus() async =>
      client.post('/api/bff/author-center-status-v1', client.authed());

  static Future<void> applyAuthor() =>
      client.post('/api/bff/apply-author-v1', client.authed());
}
