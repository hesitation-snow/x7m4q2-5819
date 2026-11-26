# Yomiru 离线缓存与修订静默替换设计计划书

## 1. 背景与产品原则

Yomiru 对接的轻小说站点本质上具有**论坛帖子属性**——作者或译者随时可能修订错别字、调整段落排版、补全或更换插画、调整卷章顺序或变更锁稿/权限。

基于这一特性，离线能力不采用传统“本地下载管理器”的重交互模式，而是遵循两条核心原则：

1. **零负担离线阅读（Zero-Friction Offline）**
   - 用户无需特意点击“缓存/下载/管理任务”。
   - 日常联网浏览和阅读过程中自动沉淀必要数据，在地铁、飞机或断网环境下打开 App，沿 **书架 → 书籍详情/目录 → 正文** 链路即可直接进入并连续阅读已缓存章节。
2. **修订静默替换（Silent Revision Replacement）**
   - 联网复核发现章节内容更新时，在后台静默落盘并平滑替换当前展示内容，**不弹出“检测到章节更新，是否重新加载”类打扰提示**。
   - 替换过程保持不跳行、不闪屏、不中断手指滑动与 TTS 朗读。

### 隐私与权限边界
- **账号严格隔离**：沿用 `ReaderContentCache` 的 `ownerUid` 隔离机制（`ownerUid = 0` 仅代表公开匿名作用域），不同账号绝不串读正文缓存。
- **付费/锁稿红线**：严格遵守“只缓存公开正文或当前账号已解锁的付费章节”，`detail.locked && !detail.unlocked` 的试读正文绝不持久化。
- **权限回收生效**：若后台复核返回无权限/已删除（`accessRestricted` / 403）或已变为未解锁锁定章，立即清理该章本地缓存并更新页面状态。

---

## 2. 现状盘点与瓶颈分析

当前代码库已经具备基础的离线设施：
- 正文缓存：[lib/api/reader_cache.dart](file:///D:/Codex/Yomiru/lkapp/lib/api/reader_cache.dart) 中的 `ReaderContentCache` 实现了按 `ownerUid` 隔离的磁盘 JSON 缓存与内存 LRU。
- 插画缓存：[lib/services/illustration_cache.dart](file:///D:/Codex/Yomiru/lkapp/lib/services/illustration_cache.dart) 中的 `YomiruIllustrationCache` 已通过 `illustrationCacheKey(url)` 剥离临时签名参数，并保留 30 天磁盘缓存（`maxNrOfCacheObjects: 2000`）。
- 书架本地快照：[lib/pages/shelf_page.dart](file:///D:/Codex/Yomiru/lkapp/lib/pages/shelf_page.dart) 已接入 `LKStore.cachedBooksPage` 秒开云书架。
- 网络层回退：[lib/api/lk_client.dart](file:///D:/Codex/Yomiru/lkapp/lib/api/lk_client.dart) 中 `LKClient.post(..., cacheKey: ..., allowCachedFallback: true)` 支持超时或 5xx 时回退缓存。
- 阅读器双阶段加载：[lib/pages/reader_page.dart](file:///D:/Codex/Yomiru/lkapp/lib/pages/reader_page.dart) 中 `_load()` 已实现先读 `ReaderContentCache.read` 秒开，再后台执行 `_refreshFromNetwork()`。

但要真正做到“断网即读 + 无感静默替换”，目前存在 **5 个关键瓶颈**：

1. **冷启动入口断网卡死在网络超时**
   - `BookDetailPage._loadPrimary`（[lib/pages/book_detail_page.dart](file:///D:/Codex/Yomiru/lkapp/lib/pages/book_detail_page.dart)）优先请求无 `cacheKey` 的 `LKApi.readerBootstrap`（20s 超时），失败后才降级请求 `LKApi.bookDetail`（30s 超时）。
   - `LKClient.post()` 在冷启动时 `_validatedCacheKeys` 为空，即使磁盘已存有 `book_detail`、`book_volumes`、`volume_chapters`，仍需等待 20–30s 网络超时后才回退缓存。
2. **书架断网刷新提示打扰**
   - `ShelfPage._load(silent: true)` 在已有本地缓存且后台静默刷新失败时，仍触发 `_showRefreshError()` 弹出错误提示。
3. **正文缓存容量偏小且存在性检查开销高**
   - `ReaderContentCache._maxEntries` 当前仅为 `50` 章，且缺少总字节上限控制。
   - `ReaderContentCache.contains()` 目前会直接读盘并反序列化整份正文 JSON。
4. **滚动预取深度不足**
   - `ReaderPage._prefetchAdjacentChapters()` 目前仅预取前后各 1 章（`_nextId` 与 `_prevId`），无法支撑离线通勤时的连续多章阅读。
5. **修订静默替换的 4 类体验问题**
   - **伪变更重排**：论坛插画 URL 签名参数轮换会导致 `LKChapterDetail.hasSameContent` 返回 `false`，引发无意义重排版甚至 TTS 重启。
   - **手势期跳动**：用户正在拖动/惯性滑动或翻页时若后台刷新返回，直接 `_renderDetail()` 会引起闪烁或手势被中断。
   - **上方增删段导致锚点漂移**：`_renderDetail()` 仅按旧 `blockIndex` / 进度比例恢复位置，若作者在当前阅读位置上方插入或删除段落，屏幕内容会突然跳段。
   - **断网横幅告警感强**：`_refreshFromNetwork` 捕获异常后将 `_cachedRefreshFailed = true`，在已有缓存可正常阅读时仍展示失败横幅。

---

## 3. 核心模块详细设计

### 模块一：离线入口打通（SWR 零等待链路）

目标：**书架 → 书详情 → 目录 → 正文** 全链路冷启动 0 等待，弱网/断网秒开。

- **网络缓存只读暴露**（[lib/api/lk_client.dart](file:///D:/Codex/Yomiru/lkapp/lib/api/lk_client.dart)）
  - 新增 `readCached(String cacheKey)` 方法，允许业务层在发起网络请求前同步/异步读取已持久化 JSON（受账号及缓存版本隔离控制）。
  - 支持 SWR（Stale-While-Revalidate）调用模式：先立即返回本地快照用于首屏渲染，同时后台刷新并更新界面。
- **聚合接口纳入缓存**（[lib/api/lk_api.dart](file:///D:/Codex/Yomiru/lkapp/lib/api/lk_api.dart)）
  - 为 `LKApi.readerBootstrap(int bookId)` 补充 `cacheKey: 'reader_bootstrap_${client.session.uid}-$bookId'` 及可选只读缓存读取。
- **书详情 & 目录先显缓存**（[lib/pages/book_detail_page.dart](file:///D:/Codex/Yomiru/lkapp/lib/pages/book_detail_page.dart)）
  - `_load()` 进入时先并行读取本地缓存的 `readerBootstrap`、`bookDetail`、卷列表及预览目录页并立即渲染，确保封面、简介、目录与“继续阅读”按钮立即可用。
  - 随后在后台静默刷新：有新数据则无感更新，断网或超时则保留缓存内容且不弹阻塞式错误。
- **书架静默降噪**（[lib/pages/shelf_page.dart](file:///D:/Codex/Yomiru/lkapp/lib/pages/shelf_page.dart)）
  - 仅在用户主动下拉刷新或当前书架为空时展示刷新报错；已有本地快照且处于冷启动后台刷新时失败静默处理。

---

### 模块二：无感滚动预缓与容量策略

目标：随着用户正常阅读自动向后铺设缓冲带，无需手动点下载，同时不对论坛服务器与设备存储造成负担。

#### 1. 升级 `ReaderContentCache`（[lib/api/reader_cache.dart](file:///D:/Codex/Yomiru/lkapp/lib/api/reader_cache.dart)）
- **双上限 LRU 淘汰**：
  - 章节数上限：`50 → 500` 章。
  - 磁盘体积上限：`50 MB`（任一上限超限即按 `lastModified` 淘汰最久未读章节）。
- **轻量存在性索引**：
  - 维护按 `ownerUid` 划分的轻量内存存在集 / 元数据索引，预取前判断章节是否已缓存时无需每次反序列化完整正文 JSON。
- **预取新鲜度控制**：
  - 写入时已有 `saved_at` 字段，后台滚动预取可跳过短期内（如 24 小时内）已缓存的章节；但当用户**实际打开该章阅读时**，仍按 SWR 在后台向服务端核对一次修订。

#### 2. 串行滚动预取器（[lib/pages/reader_page.dart](file:///D:/Codex/Yomiru/lkapp/lib/pages/reader_page.dart)）
- **预取范围**：
  - 打开第 `i` 章并完成加载后，自动向后依次预取后续 **`5` 章**（`i+1 .. i+5`）；当开启 `LKStore.dataSaverMode`（省流模式）时自动收敛为仅预取 `i+1`。
  - 跨卷场景复用本地目录分页/卷列表缓存自动衔接到下一卷首章。
- **请求礼貌性与生命周期**：
  - 并发度严格限制为 **1（串行队列）**，每章之间间隔 **300–400ms**，避免短时间并发请求触发站点限流。
  - 遇到锁定且未解锁的付费章（`locked && !unlocked`）立即终止继续向后预取。
  - 用户切章或退出阅读页时，通过递增预取序列号（如 `_prefetchSerial`）立即中止未开始的预取任务。
- **插画预缓边界**：
  - 文本预取与插画预热分离：默认仅对下一章（`i+1`）调用 `YomiruIllustrationCache` 少量预热，第 `i+2 .. i+5` 章默认仅预取文本，避免后台流量和图片缓存膨胀。

---

### 模块三：阅读中「静默替换修订」精确机制

目标：当 `_refreshFromNetwork()` 拉回的最新章节与本地缓存不一致时，做到**真正无感替换**。

```text
后台拉取最新章 detail
   ├── 权限失效 (403 / locked && !unlocked) ──▶ 删除本地缓存，更新锁定/受限视图
   ├── _isSemanticallySameDetail == true     ──▶ 仅静默覆写磁盘缓存 & _detail 元数据（零重排、不断 TTS）
   └── 正文确有语义修订
         ├── 落盘新缓存
         ├── 用户正在滚动/翻页 (_isUserInteracting) ──▶ 暂存 _pendingRevisedDetail，等待手势停稳 (~250ms)
         └── 手势空闲 ──▶ 捕获当前可视锚点文本指纹 ──▶ _parseBlocks ──▶ 邻域匹配重映射 blockIndex ──▶ 平滑更新视图 / TTS
```

#### 1. 语义等价对比（屏蔽 CDN 签名轮换伪变更）
- 新增 `_isSemanticallySameDetail(LKChapterDetail old, LKChapterDetail fresh)`：
  - 对比标题、锁定/解锁状态、规范化纯文本段落，以及经 `illustrationCacheKey(url)`（[lib/services/illustration_cache.dart](file:///D:/Codex/Yomiru/lkapp/lib/services/illustration_cache.dart)）剥离时效签名后的插画序列。
  - 若仅仅是插画 URL 的临时签名参数或无关 HTML 属性变化：只静默更新磁盘缓存与 `_detail` 引用，**跳过 `_renderDetail` 重排，也不打断 TTS**。

#### 2. 手势期延迟应用（防滑动中掉帧/错位）
- 在阅读器滚动与 `PageView` 翻页监听中维护 `_isUserInteracting` 标志：手指拖动/惯性滚动期间置为 `true`，滚动或翻页结束后延迟约 `250ms` 置回 `false`。
- 若网络修订在交互期到达：先写入 `ReaderContentCache`，并将新 `LKChapterDetail` 暂存到 `_pendingRevisedDetail`；待手势停稳且仍停留在同一章时再静默触发替换。

#### 3. 段落文本指纹锚定（上方增删段落不跳行）
- 替换 `_blocks` 前，读取当前顶部/聚焦可视块的**文本指纹**（去除空白后的前 24–36 字，必要时附带相邻前/后段落片段）。
- 生成新 `_blocks` 后，优先在 `[oldIndex - 10 .. oldIndex + 10]` 邻域内查找匹配指纹（未命中则全章扫描）；命中后将 `_ReadingAnchor.blockIndex` 重映射到新的 `newIndex` 并保持原段内 `textOffset`。
- **滚屏模式与翻页模式统一**：翻页模式下将重映射后的锚点写入 `_pendingPagedAnchor`，避免整章页码微调时把用户抛回章首或错位页；仅当当前段落本身被重写无法匹配时才兜底保留夹紧后的原索引。

#### 4. TTS 朗读中修订与权限回收兜底
- TTS 播放期间若 `_sameSpeakableBlocks` 成立，继续零中断播放。
- 若可朗读文本确实发生修订，复用文本指纹映射后的 `activeSpeechBlock` 续播修订后的对应段落，避免从第 0 段重念。
- 若刷新返回 `accessRestricted` 或已锁定，立即清理本地缓存，防止离线继续展示已被撤回或锁稿的内容。

---

### 模块四：离线 UI 降噪与极轻兜底

- **收敛阅读器离线报错横幅**：移除当前 `ReaderPage` 中告警感较强的 `_cachedRefreshFailed` 提示条；在已有缓存可正常阅读时，仅在用户呼出阅读菜单或主动点击刷新时以温和弱化文案提示离线状态。
- **目录离线可读感**：后续可配合 `ReaderContentCache` 轻量索引，在目录列表中以温和字色或极小圆点区分本地已缓存章节，帮助用户断网时直观选章，不增加下载进度条或管理弹窗。
- **空间清理入口**：复用现有设置页缓存统计与一键清理功能。

---

## 4. 分阶段实施路线与验证

| 阶段 | 范围 | 核心交付物 |
| --- | --- | --- |
| **Phase 1：缓存与网络地基** | `lib/api/reader_cache.dart`、`lib/api/lk_client.dart`、`lib/api/lk_api.dart` | 500 章 / 50 MB 双上限 LRU、轻量存在索引、`readCached`、`readerBootstrap` 缓存化 |
| **Phase 2：离线入口秒开** | `lib/pages/book_detail_page.dart`、`lib/pages/shelf_page.dart` | 书详情/目录 SWR 先渲染缓存再后台刷新；书架后台刷新失败降噪 |
| **Phase 3：阅读器预取与静默修订** | `lib/pages/reader_page.dart` | 串行滚动预取（向后 5 章/省流 1 章）、语义等价过滤、手势延迟、文本指纹重映射、权限回收清缓存、UI 降噪 |
| **Phase 4：自动化测试与回归** | `test/reader_offline_cache_test.dart`（新建）及既有阅读器/TTS 测试 | 覆盖双上限淘汰、伪变更零重排、上方插段锚点不漂移、手势延迟应用、权限回收清缓存，并执行 `flutter analyze --no-pub` |

---

## 5. 待拍板默认值（开工实现前确认）

1. **自动滚动预取章数**：默认向后预取 **5 章**（省流模式降为 1 章），或调整为 **10 章**？
2. **插画预缓范围**：仅预热 **下一章（`i+1`）** 插画，还是后续几章插画一并预热？
3. **长途断网备用入口**：是否在书详情/目录菜单中保留一个克制的 **「缓存后续 20 章 / 本卷」** 备用项，供坐飞机/高铁前主动触发？
