# 界面设计约定

## 方向
Material 3、内容优先、克制的阅读工具。保留现有功能和阅读正文主题，不将装饰覆盖正文的纸张与文字颜色。

## 全局约定
- 应用主题入口为 `AppTheme.build`，由 `LKApp` 使用；深浅主题共享语义色，避免页面自行拼接灰色背景。
- 页面背景用 `surface`，分组卡片用 `surfaceContainerLow`，辅助区用 `surfaceContainer`，选中项用 `secondaryContainer/onSecondaryContainer`。
- 标题、正文、说明优先使用 `Theme.textTheme`；说明色用 `onSurfaceVariant`，错误用 `error`。
- 内容区常规边距 16，分组之间 24，组内 8–12；避免嵌套多层卡片。
- 分组卡片圆角 16，弹层顶部圆角 24–28，主要按钮使用胶囊形；触控区域优先至少 48。
- 单个页面只突出一个主要行动，其余用 outlined/text 按钮。选中状态同时通过标记与色彩表达。
- 浮层可滚动，标题允许换行，兼容窄屏与大字号。通用菜单最大宽度 640。

## 行为约定
- 福利中心宝箱任务保持原有功能现状（含免广告开启等能力），不做收敛改动。
- 指示器预览是按真实布局规则缩放的示意，具体设备安全区仍以实际阅读器为准。

## 验证
新增或变更的组件应检查深浅主题、窄屏、大字号、空状态与失败状态；静态分析和 widget tests 之外，发布前仍应在设备上检查视觉与手势。

### 本轮验证记录
- `flutter analyze --no-pub`：无问题。
- 主会话独立通过：app_theme（2）、m3_menu_sheet（7）、app_update_service（6）、shelf_detail_layout（8）、shelf_actions（12）、book_detail_menus（3）、book_detail_original_badge（7）、local_shelf（2）、messages_welfare_m3（6）、welfare_page（19）、reader_settings_accessibility（3）。
- 阅读设置子任务的五组原有回归合计43项通过；宝箱子任务独立17项通过。主会话再次执行宝箱和消息整组时出现 connection closed / did not complete；相应单例（完整章节不制造阅读、禁用动画消息切换）独立复验通过。不得将中断解释为整组通过。
- 全量首次运行未通过：除运行中断与后来已修复/复验的UI测试外，EPUB builder有2项generator元数据断言失败。其生产和测试文件均与HEAD一致，实际字段为publisher_/exporter_，测试期待publisher_uid_b64/exporter_uid_b64，本轮不修改该模块。
- 尚未进行真机视觉验收、打包发布或Git提交推送。
