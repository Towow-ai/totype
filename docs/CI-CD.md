# 构建、检查与交付

日常维护从这里开始。macOS 和 iOS 共用部分核心与 Provider 源码，因此分支 push 和 PR 同时运行两个独立检查。macOS 的正式交付是 GitHub Release 中的 ARM64 DMG；iOS 仍按自己的 Apple 团队签名并装机，不自动上传 App Store 或 TestFlight。

## 日常开发

| 改动 / 目标 | 本地入口 | CI 与产物 |
|---|---|---|
| Mac 及共用核心、Provider | `scripts/verify.sh` | `.github/workflows/ci.yml` 的 `verify`；核心/协议回归、完整 App、内置 SenseVoice 固定音频识别 |
| iOS App、键盘、Widgets 及共用源码 | `scripts/verify-ios.sh` | 同工作流的 `ios`；mailbox/会话共享行为测试、三个原生 iOS Release target，无签名 |
| Mac 安装包 | `scripts/make-dmg.sh dist` | `dist/Totype-<version>-arm64.dmg` 和 `dist/SHA256SUMS`；公开身份、lite、ad-hoc 签名 |
| 自用 iPhone | `VerbatimVoiceMobile/scripts/install-device.sh <device-id>` | 读取本机 `Config/Local.xcconfig`，签名并安装；详见 [iPhone 说明](manual/zh-CN/11-iphone.md) |

Mac 检查需要 Apple 芯片、macOS 15+ 和 macOS 15.4+ SDK；完整检查会下载校验过的公开模型，并使用系统中文朗读语音生成样本。iOS 原生检查需要完整 Xcode（含 iOS SDK）与 XcodeGen。CI 固定 Xcode 26.3 和 XcodeGen 2.46.0；本地检查打印实际工具版本。不调用付费云接口。

iOS 无签名检查固定公开身份和 `TOTYPE_PRIVATE_HOST_RETURN=NO`，覆盖 ActivityKit 等 Catalyst 检查跳过的代码。产物在 `VerbatimVoiceMobile/.build/ci-ios/Build/Products/Release-iphoneos/`；它只用于编译检查，不能直接安装。共享行为测试失败直接显示断言；原生构建失败显示日志末尾，完整日志在 `VerbatimVoiceMobile/.build/ci-ios-build.log`，Actions 失败附件保留 7 天。只有命令行工具时仍可运行 `VerbatimVoiceMobile/scripts/typecheck.sh`，但它不能代替原生 iOS CI。

在受限执行沙箱中，Darwin 通知或本地 WebSocket 可能被禁止；应在正常本机环境复现同一命令，不能把环境阻止误报为产品回归。不要跳过失败断言让检查通过。

## Mac 发布与恢复

1. 对准备发布的提交运行 `scripts/verify.sh`；共用源码或 iOS 改动同时跑 `scripts/verify-ios.sh`。维护者使用独立开发仓时，沿用 `scripts/publish-public.sh <public-checkout> --commit '<message>'` 的白名单导出及私人词扫描，确认差异后推送公开分支。该命令本身不推送。
2. 在 `VerbatimVoice.xcodeproj/project.pbxproj` 更新版本和构建号，填写 `CHANGELOG.md` 对应版本章节；等分支 / PR 检查通过并整合。
3. 按既有发布授权创建并推送与应用版本一致的 `v<version>` tag。`.github/workflows/release.yml` 先运行同一个 `scripts/verify.sh`，再构建 lite DMG，验证 tag、SHA256 和磁盘映像，最后创建 Release。tag 不再另起一份重复的普通 CI。失败时从该 tag 的 Release 日志定位；修复形成新提交后用新版本发布，不覆盖已发布资产。
4. 对公开下载的 DMG 执行 `shasum -a 256 -c SHA256SUMS`，只读挂载检查内容。在有维护者验收的机器上安装，再检查权限、录音、取消后再录、转写与实际输入。发布包为 ad-hoc，尚未 notarize；保持 [安装说明](manual/zh-CN/01-install.md) 所述授权步骤。
5. 用该 Release 的实际 SHA256 更新 `packaging/homebrew/totype.rb` 与 Homebrew tap 的 `Casks/totype.rb`。两处版本与散列必须一致；不要对本地重新构建的 DMG 取散列来填写已发布版本。

使用本机安装脚本时保留其一个回滚备份；公开 DMG 用户可重新安装上一版 Release，保留用户数据和设置。涉及数据格式变化时，先在变更中写明向前兼容 / 恢复办法；换回旧程序不自动恢复已经改写的数据。

## 修改与排障位置

检查逻辑在 `scripts/verify.sh`、`scripts/verify-ios.sh` 和它们调用的自测脚本；工作流只负责触发、工具环境、缓存与发布。Xcode 升级改 `scripts/ci-select-xcode.sh`，XcodeGen 升级改 `ci.yml` 中的版本和官方发布 SHA256，先用分支验证两个平台。模型版本、下载地址和散列以 `scripts/setup_local_sensevoice.sh` 为入口。保留现有下载缓存；不要缓存私人配置或签名材料。

外部 PR 用只读 token 跑检查，需要维护者授权执行时保留 GitHub 的审批；不改用 `pull_request_target` 执行外部代码。发行凭据不交给 PR。设备录音、键盘跳转、后台行为、跨应用输入与系统权限仍需真机验收；通过 CI 只说明相应自动检查和构建成功。

参考：[GitHub 工作流安全](https://docs.github.com/en/actions/reference/security/secure-use)、[Apple 命令行构建](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)、[XcodeGen 发布](https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0)。
