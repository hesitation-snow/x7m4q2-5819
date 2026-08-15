# LK 轻小说 Flutter 客户端(基础版)

基于 lightnovel.fun 正式服 API 的 Flutter 客户端。**走 pc-proxy 网关,无需处理签名**;含登录、首页 7 频道、搜索、榜单、书籍详情、卷章节、阅读器(字号/上下章/段评/解锁/云进度)、服务器书架、云端历史(网页同步)、书评、动态广场、消息中心+私信、福利中心、设置与资料。

## 目录结构

```
lib/
├── main.dart                 # 入口(会话恢复 + MaterialApp)
├── api/
│   ├── lk_client.dart        # HTTP 客户端(pc-proxy/异常/会话/multipart)
│   ├── lk_api.dart           # 全接口分组封装(鉴权/首页/阅读/书评段评/书架历史/动态/消息/福利/用户/作者)
│   ├── models.dart           # 数据模型(fromJson)
│   └── store.dart            # 会话持久化(shared_preferences)
├── widgets/
│   └── common.dart           # CoverImage(缓存封面)/BookCard/错误提示
└── pages/
    ├── home_page.dart        # 4 Tab:首页 feed/榜单/云端历史/我的
    ├── login_page.dart       # 登录/登出
    ├── search_page.dart      # 搜索 + 服务器书架 + 书评
    ├── book_detail_page.dart # 详情 + 卷章节列表
    ├── reader_page.dart      # 阅读器 + 段评弹层
    ├── dynamic_page.dart     # 动态广场 + 消息中心
    ├── dm_chat_page.dart     # 私信聊天 + 福利中心 + 设置
```

## 运行

```bash
cd lkapp_flutter
flutter create .        # 生成 android/ios 等平台工程(已有 lib/ 不会被覆盖)
flutter pub get
flutter run             # 或 flutter build apk
```

要求:Flutter 3.x(Dart 3,使用了 switch 表达式)、Android SDK 34 / Xcode 15+。

## 已实现的接口(与服务端文档 1:1)

- 鉴权:`auth-password-login-v1`、`auth-session-v1`、`logout-v1`(⚠ 登出作废全端会话)
- 首页:`home-feed-v1` + 5 个频道 feed、`book-rank-list-v1`、`apk-search-result-v1`
- 阅读:`get-book-detail/volumes/volume-chapters/chapter-detail/chapter-paragraphs`
- 书评/段评:`get/publish/like`(段评含段落定位)
- 书架/历史:`toggle-book-shelf`、`bookshelf-v1`、`history-v1`、`save/delete-book-history`、`unlock-chapter`
- 动态:`get-feed-v1(tab=follow)`、`publish-short-post-v1(带 request_id)`、`toggle-like/favorite`、`delete-dynamic-v1`、`get-comments-v1`
- 消息:`message-*-v1` 4 类 + `mark-read`、`dm-conversations/messages/send`
- 福利:`welfare-home/sign-detail/claim-sign/task-list/claim-task/sleep/treasure/coin-records`
- 用户:`my-home`、`update-profile`、`change-password`、`toggle-follow`、`toggle-medal`、`invite-my-code`、`settings-about-v1`、`settings-update-check-v1`、`upload-avatar`(multipart)
- 作者:`author-center-status-v1`、`apply-author-v1`

## 关键约定(踩坑提醒)

1. `pageSize` 上限 50(客户端已自动 clamp)。
2. 动态发布必带 `request_id`(幂等键)。
3. `logout-v1` 会作废**所有端**会话——客户端登出前可先提示用户。
4. 头像上传 `md5` = 文件内容 MD5(服务端以 md5 命名文件)。
5. 动态 feed 合法 tab 仅 `follow`(其它值报"Tab是无效的")。
6. 登录后接口统一用 `client.authed({...})` 注入 `security_key`。
7. 云端历史续读:用 `history` 子对象的 `volume_id/chapter_id/progress_percent`,别用书籍卡片里的 `last_read_chapter_id`(那是"最新章节"不是"读到")。

## 扩展方向

- 本地书架缓存 / 离线正文缓存(Hive 或 sqflite)
- 头像上传接 `file_picker` + md5 工具包
- 阅读进度自动回跳(打开章节滚到 `last_position`)
- 打赏/充值支付流程
- 作者中心编辑器
