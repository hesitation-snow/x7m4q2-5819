# 注册与邮箱重置密码

## 核实来源

仅对 https://www.lightnovel.fun/ 及其公开加载的 JavaScript 做 GET 静态核实，未注册账号、发送验证码或提交重置密码。web_fetch 因域名解析限制失败，使用 curl 获取公开页面与脚本。已阅读 browser-automation 技能；本次不需浏览器交互，证据为实际公开前端代码而非推测路由。

- 首页引用 `/_nuxt/mvlyor97/BuA3ZCNH.js`（AuthPromptModal）：登录、邮箱注册、忘记密码为同一弹窗三个模式，不存在已核实的独立注册/找回 URL。注册必填邮箱、邮箱验证码、昵称、密码、确认密码；未显示条款勾选项。
- `/_nuxt/mvlyor97/hMCf8bqB.js` 将 auth 动态加载至 `BGXGNkFB.js`。
- https://www.lightnovel.fun/_nuxt/mvlyor97/BGXGNkFB.js：下列端点和字段。
- https://www.lightnovel.fun/_nuxt/mvlyor97/C-VQavZl.js：默认网关 `/api/pc-proxy`，JSON POST，非零 code 读取服务端 message。
- https://www.lightnovel.fun/_nuxt/mvlyor97/BuA3ZCNH.js：邮箱格式、密码 8–16 位且大写/小写/数字/所列特殊符号至少三类；没有图形验证或协议确认控件。构建哈希可能随官网升级改变。

## 接口契约

均为 `https://www.lightnovel.fun/api/pc-proxy` 后附以下路径，JSON POST：

| 路径 | 字段 |
| --- | --- |
| `/api/bff/auth-email-status-v1` | email |
| `/api/bff/auth-email-register-captcha-send-v1` | email |
| `/api/bff/auth-email-register-v1` | email, captcha, code（同captcha）, nickname, password |
| `/api/bff/auth-reset-password-captcha-send-v1` | email |
| `/api/bff/auth-reset-password-v1` | email, captcha, new_password |

注册发送验证码前按官网先查询邮箱是否已注册。所有请求均不附当前 security_key，API 不修改 session，不写入缓存或保存密码。注册接口虽返回官网登录信息，本客户端不自动消费该会话；成功后提示使用新账号显式登录，保留原登录/退出逻辑。

## 实现与限制

登录页增加注册与找回入口，采用现有 M3 控件；表单本地校验、操作期间禁重复提交、发送成功后本地 60 秒冷却（本地防重复策略，非声称服务端规定）、释放计时器和控制器，显示服务端错误。冷却期间锁定邮箱，避免误将验证码用于其他邮箱。

找回仅支持已有绑定邮箱重置密码，不支持查询遗忘的用户名或失去访问权的邮箱。若官网要求网页验证或接口策略变化，通过既有外部链接服务打开已验证官网首页，用户进入“登入/注册”→“邮箱注册”或“忘记密码”，不模拟或绕过验证。

项目内 glob 检查 APK/Java/smali 及 official/lightnovel 等文件名，仅发现 Yomiru 自身构建 APK 和 Flutter 插件产物，不将本项目构建产物作为官方证据。

随后使用官方 Android 客户端样本进行静态核对。SHA256：`bbc2d196fa05d584f0fe9ef836a2dc224995fcbf67d756fbb171e0cb45916c25`。未运行安装包，使用本机 Python zipfile/re 对其中 `lib/arm64-v8a/libapp.so` 静态提取 ASCII/UTF-16LE 字符串，确认包含上述五个相同 BFF 路径，以及 `sendEmailRegisterCaptcha`、`registerByEmail`、`captcha_invalid`、`captcha_expired`、`captcha_send_too_frequent` 标记。另发现 `/api/bff/agreement-v1`、`agreement_key`、`_buildAgreementRow`、`_toggleAgreement` 和“用户协议”“隐私协议”“同意协议”文本（例如 UTF-16LE 字符串偏移 0x56f86、0x6dcf3、0x9d1e4）。这表明 App 有协议相关实现，但仅字符串不足以确定注册页的必填行为、协议 key 或请求参数绑定；本机无 jadx/apktool/7z，且该样本为 Flutter AOT，不安装大型逆向依赖。当前参数严格采用已核实的官网 JS；未猜测添加协议字段或声称完整复原 App 流程。官网弹窗当前未观察到协议确认控件，App 与网站协议呈现可能存在差异。

执行 `flutter analyze --no-pub` 与 `flutter test --no-pub --no-enable-impeller --concurrency=1 test/account_access_test.dart`。测试覆盖五个端点及请求字段、会话隔离、无效邮箱/空字段/密码确认、忙碌按钮禁用、服务端错误展示、已注册邮箱阻断发信、冷却与离页计时器释放。测试使用 MockClient，无真实邮件或账号操作。真实邮件投递、验证码有效期、注册成功返回结构和密码重置效果未做端到端验证；需由用户在正常流程中验证。
