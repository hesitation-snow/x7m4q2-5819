# 混合权限书：完整目录核验优化

本次继续处理 [Issue #3](https://github.com/hesitation-snow/Yomiru/issues/3) 中前部公开、后部夹有勇者章节的情况，替代上一版每卷前5条的抽查。

## 实际样本

用户提供：https://www.lightnovel.fun/reader/33172

已通过未登录的公开目录元数据核对：

- 书籍33172，第一卷50815，共13条目录。
- 第九章「難忘之夜」的章节ID为324018，实际目录`chapter_no=11`，权限为`access_type=brave`、`brave_required=1`。
- 末尾「人物設計」ID324146同样标为brave。
- 书籍详情未提供直接的勇者属性，而`read_state.is_readable=1`只说明有可读入口，不是全书所有章节公开的证明。
- [权限元数据样本](../test/fixtures/mixed_access_book_33172.json)仅保留目录标题、ID和权限字段，不包含正文、账号或凭据。

## 核验流程

1. 每轮先读取新鲜的书籍元数据，比较`updatedAt + volumeCount + chapterCount`指纹。目录版本或计数变化会清掉旧扫描游标。
2. 分页获取卷目录，并依次分页获取每卷的章节权限目录。不再只选首尾卷或前5章。
3. 任一章节明确为勇者，立即确认书籍含勇者章节，复用已有正标缓存和列表刷新事件。
4. 全部目录页处理完、已知数量对齐、每章都明确public，才返回本次核验的noBrave。缺标、空/截断响应、重复页或计数矛盾仍为unknown。
5. 书籍入口`public`和旧的缓存`book_access_state=public`不再使完整核验被跳过；public只在单章作用域作为直接证据。
6. 已完整遍历但缺少元数据的unknown，在后续外部查询也可重新核验，避免同一指纹永久保留缺标结果。

实现：[分轮核验器](../lib/services/book_catalog_verifier.dart)、[调度与正标传播](../lib/services/book_access_probe.dart)、[严格分页API](../lib/api/lk_api.dart)。

## 预算与生命周期

| 限制 | 当前值 |
|---|---|
| 同时处理的后台轮次 | 2 |
| 在途/排队书籍 | 最多32 |
| 每轮请求数量 | 最多4，包含当轮书籍详情 |
| 每轮时间预算 | 8秒 |
| 每个外部查询自动轮次 | 最多8轮，即最多32次元数据请求 |
| 每页请求大小 | 50；接受服务端收紧至1–50 |
| 轮次让出 | 释放队列后再延迟150ms，其他书籍可获得轮次 |
| 扫描游标 | 最多128本，内存LRU，进行中的游标不被驱逐 |
| 轮数耗尽 | 保留游标，15秒短冷却后再次显示/刷新可继续 |
| 未明确结果冷却 | 5分钟，新的正标记始终优先 |

- 离开路由、关闭隐藏或开启省流后不再启动后续请求。已发出的网络请求可能收尾，但迟到响应不推进扫描游标；核验专用API不直接写共享正标记，只有当前仍有效的Probe才可提交，过期结果也不会污染其本地正标记memo。
- 游标目前只在进程内保留；进程重启后重新核验，不声称可跨重启续扫。
- 未完成的目录仍为unknown，不会因为预算耗尽被假装为公开，也不会将所有未知书籍一律隐藏。因此不承诺核验完成之前列表绝无短暂漏显示。
- 仅读取目录元数据，**不读取章节正文、不绕过访问权限**。
- 该功能不改变「隐藏勇者书籍」与「封面模糊」相互独立的用户设置。

## 回归验证

新增回归覆盖：
- 33172真实目录结构，第11项才出现勇者；通过普通调用链发现它，只需详情/卷目录/章目录3次元数据请求。
- 第一页全部public、第二页最后一章brave；多个卷跨轮次后才出现brave。
- 服务端pageSize收紧、未返回total、恰好满页、额外空终止页、明确total=0与非空列表矛盾。
- 完整public与含unknown区分、重复/截断分页、异常重试、取消与迟到响应隔离。
- 指纹变化清游标、轮次上限保留进度、调度公平、离页后不再续轮。

可重复运行：[verify_issue3.ps1](../tools/verify_issue3.ps1)。

- 全项目`flutter analyze --no-pub`：No issues found。
- 24个相关测试文件、173项测试最终通过；其中分区过滤测试进程曾仅报告`did not complete`，未出现断言或异常栈。使用显式`-RetryIncomplete`选项仅复核一次后通过，原始日志、`initialExitCode`和`attempts`均保留，并非宣称所有文件初次执行全绿。
- [最终测试汇总](../build/verification/issue-3-20261106-144709/summary.json)、[静态分析](../build/verification/issue-3-20261106-144709/analyze.log)、[原始未完成记录](../build/verification/issue-3-20261106-144709/filtered_pagination_test.dart.log)、[复核记录](../build/verification/issue-3-20261106-144709/filtered_pagination_test.dart.rerun.log)。真正的断言/编译/超时错误不会被该选项自动重试。
- 最后一次后台空闲等待逻辑修订后，另对完整调用链9项、双列表4项、路由1项、分区1项逐文件复核通过；其中路由测试也有一次进程报告`No tests were found`/未完成，保留该工具运行记录，不将它冒充应用断言成功。
- 当前测试进程存在间歇性未完成情况，原因尚未确定；相关日志是已知验证风险，不据此声称整个项目所有功能已通过。
- 已构建[混合目录核验ARM64 Debug包](../build/app/outputs/flutter-apk/yomiru-mixed-catalog-arm64-debug.apk)，126,871,876字节（约121 MiB）。
- 已核对包名`moe.yutro.yomiru.debug`、版本`1.6.0`/`2014`、minSdk24、仅`arm64-v8a`，APK v2签名验证通过；`git diff --check`通过。
- SHA-256：`9563A865D80B9FF5DFC2C17B602BD466ACC96DE4AE48BA435F11E768EA5ECC93`。
- 最终ADB无设备，未安装到手机；Gradle既有Kotlin迁移警告未作本轮无关迁移。

## 边界

真实站点只核对了匿名目录接口；代码回归使用目录快照和MockClient，没有登录两种真实账号，没有取得Android真机运行结果。未提交/推送Git，未向Issue回复或关闭Issue。没有把33172或其章节ID硬编码进生产逻辑。
