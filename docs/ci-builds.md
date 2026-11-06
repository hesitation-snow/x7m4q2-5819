# 仓库构建

当前工程的源码远端为 `hesitation-snow/x7m4q2-5819`。`hesitation-snow/Yomiru` 的 main 是独立历史及精选组件/展示结构，不把当前完整工程覆盖到该仓库。

## Android ARM64 Release

[Android ARM64 Release CI](https://github.com/hesitation-snow/x7m4q2-5819/actions/workflows/android-ci.yml) 在 main 的应用源码、依赖、Android配置或相关测试更新时自动运行，也可在 Actions 页面选择 Run workflow 手动构建。

流程包含：

1. Java 17、Flutter 3.47.0，与已有发布流程一致。
2. 解析依赖、全项目静态分析。
3. 逐文件运行完整目录核验与混合权限识别核心回归；不对真实断言失败作自动重试。
4. 使用维护者配置的正式密钥构建仅 `arm64-v8a` 的 **Release APK**。
5. 校验原生架构与APK签名，上传APK及SHA-256到该次运行的Artifacts。

不创建Git标签、不自动发布GitHub Release、不发送Telegram，也不回退使用Debug密钥。

需预先在源码仓库的 Settings → Secrets and variables → Actions 配置以下已有发布Secrets（只在GitHub的Secrets界面配置，勿提交到Git）：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

缺少配置时，构建会明确失败，不输出伪装成正式包的Debug产物。签名文件仅在runner临时使用，结束时清理；上传目录仅含安装包和校验文件。

## 本地验证记录与实验文件

此前文档中 `build/verification/`、`build/app/outputs/` 等链接指本地历史验证产物，并不随源码提交。以后下载仓库构建请打开对应Actions运行，在Artifacts里取安装包。

大型ONNX/训练权重、`.yomiru-voice`、基准音频和本地签名配置不入库。实验性的模型转换/声线包管理工具不作为已完成Android本地GPT-SoVITS推理交付；当前应用仍明确显示本地推理未实现。
