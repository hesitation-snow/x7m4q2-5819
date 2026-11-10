# 听书界面与交互优化验证说明

## 本轮范围

- 听书面板：顶部当前语段/真实状态与语段进度，底部固定上一段/播放暂停/下一段/停止按钮；设置滚动时操作栏保持可达。
- 系统、Azure、自定义音源使用带说明的选择卡片；语速直接可调，语言筛选/间隔/睡眠定时/连读归入「播放设置」。
- 语音服务设置采用「连接、音色、认证、试听」分组，保留完整HTTPS地址并提供Azure区域入口。草稿密钥直接用于试听/音色目录，仅保存操作才持久化。
- 取消、重复试听和旧页面销毁有代次保护；旧试听适配器只停止自己拥有的源，WAV字节按WAV播放。
- 系统引擎ID纳入语音缓存身份，分语言配置采用不可变快照；切换音色会真实更新合成配置。
- 媒体服务未连接时显示兼容模式和重连按钮，不允许用户操作没有实际执行器的睡眠定时等功能。
- 清除没有实际调用的ONNX Android依赖。本轮没有实现Android GPT-SoVITS推理；该能力保持明确不可用。电脑转换工具和声线文件不等于手机推理实现。
- 全量测试额外发现的阅读器deactivate后手势访问context问题一并修复。

## 验证类型与边界

1. 静态分析、Widget测试、受控异步测试：验证接口、布局、状态机和假服务条件下的回调行为。
2. UI预览：由`reader_listening_sheet_test.dart`渲染的明确测试场景，不是真机听书截图，不证明声音/网络服务成功。
3. Android构建与签名/ABI检查：证明安装包构建及其静态属性，不证明某台手机实际出声。
4. 真机测试：提供`integration_test/reader_audio_device_test.dart`。尝试运行时Flutter未找到最初连接的设备，未取得真机成功证据。
5. Azure/自定义远端服务：本轮未使用真实密钥请求云服务，不声称云API已实测。

## 测试记录

- 已执行一次全目录测试，该轮没有全绿；发现试听ID同微秒碰撞、阅读器退出手势回调、Windows测试临时目录句柄占用等问题，后续修复并逐文件复测。
- 该轮还出现福利页「免广告」文本断言及部分测试未完成条目，不把部分通过计数冒充全目录通过。福利页用例 `Tapping watch_ad treasure box triggers ad report and claim` 已单独复跑，仍在 `test/welfare_page_test.dart:1032` 的文案查找处失败；本轮没有修改该页领取/奖励逻辑。
- 后续逐文件回归：13个文件、95项测试全部通过；包含听书面板、系统/自定义语音、受控异步竞态、书签、阅读器手势与指示器等。
- `flutter analyze --no-pub`：No issues found。
- 最终ARM64 Debug APK已构建；包名 `moe.yutro.yomiru.debug`，versionName `1.6.0`，versionCode `2014`，minSdk `24`，ABI仅 `arm64-v8a`；APK v2签名验证通过。
- 交付文件：[yomiru-tts-ui-arm64-debug.apk](../build/app/outputs/flutter-apk/yomiru-tts-ui-arm64-debug.apk)，大小126,838,070字节（约121 MiB），相比此前144,395,408字节减少17,557,338字节（约16.7 MiB）。
- SHA-256：`E049F83B406B55157F1CF9C68D28B66BA8A645253A36CAE2253CB7D0D78A0DF4`。
- [浅色预览](../build/ui-previews/listening-light.png)、[深色预览](../build/ui-previews/listening-dark.png)：两个截图用例通过，已目视审查图标、文本、层级及固定播放栏；测试场景不是实际小说或已验证的音频播放。
- `git diff --check`最终通过。Gradle仍提示现有Kotlin插件迁移弃用警告，本轮没有作无关迁移。
- 最终 `adb devices -l`无设备；真机测试尝试因Flutter没有找到设备而结束，未获得安装/音频成功证据。

## 重现命令

```powershell
flutter pub get --offline
flutter analyze --no-pub
flutter test --no-pub --concurrency=1 test/reader_controls_test.dart
flutter test --no-pub --concurrency=1 test/reader_listening_sheet_test.dart
flutter test --no-pub --concurrency=1 test/reader_speech_races_test.dart
flutter test --no-pub --concurrency=1 test/reader_audio_handler_test.dart
flutter test --no-pub --concurrency=1 test/custom_tts_settings_page_test.dart

# 可选UI预览；字体路径根据本机实际资源填写
$env:YOMIRU_CAPTURE_UI='true'
$env:CJK_PREVIEW_FONT='C:\Windows\Fonts\msyh.ttc'
$env:MATERIAL_ICON_PREVIEW_FONT='D:\Codex\Yomiru\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf'
flutter test --no-pub test/reader_listening_sheet_test.dart --plain-name 'capture listening'

# 设备测试必须使用独立包，避免覆盖正常应用数据
$env:YOMIRU_DEVICE_SMOKE='true'
flutter test --no-pub -d DEVICE_ID integration_test/reader_audio_device_test.dart

# 正常交付包
$env:YOMIRU_DEVICE_SMOKE='false'
$env:YOMIRU_SIDE_BY_SIDE_DEBUG='true'
flutter build apk --debug --no-pub --target-platform android-arm64 --split-per-abi
```

未提交或推送Git；没有改动原训练权重或删除声线包。
