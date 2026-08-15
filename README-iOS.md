# iOS 打包与安装指南(LK 轻小说)

> ⚠ **硬性前提:iOS 应用(iPA)只能在 macOS + Xcode 上编译。** Windows 无法直接出 IPA。
> 没有 Mac 也没关系——用方案 B(云构建),全程 Windows + 浏览器即可。

## 当前工程状态(已就绪)

- `ios/` 平台工程已生成
- Bundle ID:`com.lkfun.lkapp`
- 显示名:已改为 **LK轻小说**
- 依赖(http/shared_preferences/cached_network_image/wakelock_plus)全部支持 iOS
- 代码零平台特定逻辑,iOS 上 API 照常可用(正式服 API 走 HTTPS,无 ATS 问题)

---

## 方案 A:有 Mac(最正统)

```bash
cd lkapp_flutter
flutter build ipa --release          # 需要配置签名
# 或 Xcode 打开 ios/Runner.xcworkspace,选设备 -> Product -> Archive
```

- **免费 Apple ID**:只能真机调试,7 天过期;上不了商店
- **开发者账号($99/年)**:`flutter build ipa` 后 `xcodebuild`/Transporter 上传,或直接 Archive → Distribute App → App Store Connect → TestFlight 内测

## 方案 B:没有 Mac —— GitHub Actions 云构建(已配好,推荐)

工程里已经带了工作流 `.github/workflows/build-ios.yml`,推上 GitHub 即可:

1. 把 `lkapp_flutter` 整个目录作为仓库根目录推到 GitHub(私有仓库也行,免费额度 2000 分钟/月,一次构建约 15-25 分钟)
2. 仓库 → **Actions** 页 → 左侧 `Build iOS IPA (unsigned)` → **Run workflow**(或直接 push 触发)
3. 构建完成后,该次运行页面底部 **Artifacts** 里下载:
   - `lk-unsigned-ipa` → 未签名 IPA(Sideloadly 自签用)
   - `lk-android-apk` → 附赠的安卓 release APK
4. 下载后用**方案 C** 签名安装到 iPhone

说明:macos-latest 云机器上自动完成 Flutter 安装 → `flutter build ios --release --no-codesign` → 打包成 `lk-unsigned.ipa`。Artifact 保留 90 天。

（备选:Codemagic 也是同类的云构建,若 GitHub 用不了再考虑。）

## 方案 C:安装到手机(没有开发者账号)

- **[Sideloadly](https://sideloadly.io/)(Windows/Mac 都有)**:USB 连 iPhone → 拖入 IPA → 填**免费 Apple ID** → 自动签名安装。
  限制:签名 **7 天过期**(到期重新签一次即可)、同一 Apple ID 最多 3 个侧载 App。
- **[AltStore](https://altstore.io/)**:类似,支持手机端 Wi-Fi 刷新续签。
- **TrollStore**(仅限特定 iOS 版本 + 已越狱/可越狱):永久签名,不推荐折腾。

## 说明

- App 名字会显示为「LK轻小说」;首次打开无网络权限弹窗问题(HTTPS 直连)。
- 如果后面要上 TestFlight/App Store,记得在开发者后台注册 bundle id `com.lkfun.lkapp`,并在我这边把 build number 管理起来。
