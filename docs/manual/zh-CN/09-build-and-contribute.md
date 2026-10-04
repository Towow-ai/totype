# 09 构建与贡献

[English](../en/09-build-and-contribute.md)

从源码构建只需要 macOS 15 或更高、Apple 芯片、命令行工具和网络。本章列出构建脚本、配置变量、测试入口和仓库结构，以及贡献时要遵守的原则。

## 构建与安装

| 命令 | 作用 |
|---|---|
| `scripts/build.sh` | 用 `swiftc` 构建并签名，输出 `build/Totype.app.disabled`（带后缀，不能直接运行） |
| `scripts/install.sh` | 构建后安装到 `/Applications/Totype.app`，备份旧版，原子替换，失败时回滚 |
| `scripts/install_local_signing_identity.sh` | 创建本机自签名身份，让授权跨构建保留 |
| `scripts/verify.sh` | 总入口：核心测试、各项自测程序、构建完整应用并用内置模型跑一段样本音频 |

构建使用 `xcrun --sdk macosx --show-sdk-path` 找到 SDK，需要 macOS 15.4 或更高。也可以用 Xcode 打开 `VerbatimVoice.xcodeproj` 构建。首次构建会下载约 246 MB 的模型，`VERBATIM_SENSEVOICE_DIR` 可以指向已经下载好的目录。

## 配置变量

复制 `config/local.env.example` 为 `config/local.env`（已被 git 忽略）并修改，或直接用环境变量；环境变量优先。默认值在 `scripts/lib/env.sh`。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `VERBATIM_BUNDLE_ID` | `ai.towow.totype` | Bundle ID。macOS 把辅助功能、输入监控授权绑在它上面，自己构建时建议换成自己的 |
| `VERBATIM_SIGN_IDENTITY` | `Totype Local Code Signing` | 代码签名身份。不存在时退回 ad-hoc 签名并警告 |
| `VERBATIM_APP_NAME` | `Totype` | 应用显示名、可执行文件名、安装路径 |
| `VERBATIM_APP_NAME_ZH` | 空 | 中文显示名，留空则不生成本地化 |
| `VERBATIM_DATA_DIR_NAME` | `Totype` | 安装脚本查找运行状态文件的目录名。应用自己的数据目录目前仍由源码固定为 `VerbatimVoice`，在迁移完成前，需要让安装脚本检查到运行中的应用时，把它设为 `VerbatimVoice` |
| `VERBATIM_SDK_PATH` | `xcrun` 的结果 | 指定 SDK |
| `VERBATIM_SENSEVOICE_DIR` | 空 | 已下载的模型与运行程序目录 |

## 界面语言

应用带英文和简体中文两套界面：系统语言是中文时显示中文，其他语言显示英文。代码里的中文原文就是查表的键（`String(localized: "已插入 \(n) 字")`），所以没有字符串表的构建（比如目前的 iPhone 目标）会原样回落成中文。表在 `VerbatimVoice/Resources/en.lproj/Localizable.strings`（改这一份）和 `zh-Hans.lproj/Localizable.strings`（由 `scripts/l10n.py sync-zh` 生成，值等于键）；权限用途说明在同目录的 `InfoPlist.strings`。`swiftc` 不编译 `.xcstrings`，所以 `scripts/build.sh` 负责拷贝 `.strings`，Xcode 工程里把它们列为资源。

新增或修改文案：用 `String(localized:)` 包住（SwiftUI 的 `Text("…")` 字面量自己会查表），补英文条目，运行 `scripts/l10n.py sync-zh`，再运行 `scripts/check_l10n.sh`。两张表键不一致、键和译文的格式符不一致、代码里的本地化调用没有条目时检查失败；没走本地化的中文字面量只给警告（日志和比较用的在行尾加 `// l10n:ignore`）。会被存储、写进给脚本读的日志、用于比较或发给识别引擎的字符串不要本地化。`scripts/design_preview.sh docs-en` 渲染 `docs/images/en` 里的英文截图。

## 仓库结构

```text
VerbatimVoice/            应用：AppKit/SwiftUI 界面、音频、识别引擎适配、插入
VerbatimVoiceCore/        纯 Swift 核心：个人资料、误听恢复、文本拼接、超时策略
VerbatimVoice.xcodeproj   Xcode 工程
VerbatimVoiceMobile/      iPhone 版：主 App、键盘、小组件，见 11 iPhone 版
scripts/                  构建、安装、验证和各类自测程序
config/                   本地配置示例
tools/history_report.py   从 history.jsonl 生成使用统计
docs/DESIGN.md            视觉与界面设计
docs/manual/              本说明书
```

## 贡献

欢迎提交问题和合并请求。有几条原则决定一个改动能不能被接受：

- **不改原话。** 任何引入大模型改写、润色、补全的改动都不会接受。文字改动只允许“另一个引擎佐证的已知误听恢复”。
- **一次说话最多插入一次，音频先落盘。** 插入路径的改动要说明如何保持这两点。
- **热键、event tap 和权限相关改动**需要维护者在真机上验收，请在合并请求里写明你测试过的 macOS 版本和授权状态。
- **不要提交私人数据和密钥。** 仓库里不放个人术语表、录音或 API Key。
- 提交前运行 `scripts/verify.sh`。
- 视觉上以 `docs/DESIGN.md` 为准：纯色背景，颜色只有录音红，且只在深色模式录音时出现。
