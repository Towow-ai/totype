# Totype

简体中文 · [English](README.en.md)

**Totype 是 macOS 语音输入法：接最好的识别模型，按一下说话，文字直接打进任何输入框；改不改你的原话，由你决定。**

![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)
![Platform: macOS 15+ · Apple Silicon](https://img.shields.io/badge/platform-macOS%2015%2B%20%C2%B7%20Apple%20Silicon-lightgrey)

[从源码安装](#快速开始) · [下载 dmg](https://github.com/Towow-ai/totype/releases/latest) · [使用说明书](docs/manual/zh-CN/00-overview.md)

<p align="center"><img src="docs/images/demo.gif" width="800" alt="按一下右 Option，开口说，再按一下：原话插进光标处。"></p>

Totype 常驻菜单栏。光标停在任意应用的输入框里，按一下右 Option 开始录音，再按一下，识别出的文字就插入光标处。它支持中文、英文和中英文夹杂。云端引擎可以接 Soniox 和阿里云百炼的实时识别模型；不想联网，就用本地的 SenseVoice。

## 功能

- **任意应用里直接输入。** 右 Option 开始，再按一下结束并插入，Esc 取消。屏幕底部的浮窗显示状态。在终端里只输入文字，不替你按回车。
- **接一流的识别模型。** 云端接入 Soniox（`stt-rt-v5`）和阿里云百炼的 Qwen 实时识别（`qwen-audio-3.0-asr-flash-streaming`），实时识别，说完几乎立刻出结果。中英混说的识别准确率是我们选型的首要标准；一句话里夹英文术语，云端引擎比本地引擎更准。
- **你决定改多少。** 默认逐字输出，不用大模型改写，重复、口头语、自我修正都留着。想要整理得更干净，由你自己调：转写提示词（随录音发给云端引擎，可以写下你对标点、口头语的要求，引擎把它当作提示而不是命令）、术语表与说话人背景（帮引擎写对你的专有名词）、误听别名、聊天应用里去掉句末句号、英文结尾补空格，以及自动学习你的人工修改。一次说话最多插入一次。
- **本地离线，免费可用。** 内置本地 SenseVoice 模型，不需要账号和网络。想要实时识别，可以接 Soniox 或阿里云百炼的实时识别，用自己的 Key，按量向服务商付费。
- **热备与自动回退。** 配置两个云端时，一个主用，另一个同时在后台热备；主引擎出错或太慢，就用热备的结果。云端都失败时，自动用保留的音频在本地转写。浮窗会说明这次由哪个引擎完成，从不静默改用系统听写。
- **失败不丢录音。** 音频先写入磁盘，再识别。识别失败、被取消，或你切换了应用，录音都在历史里，可以再转写。
- **个人词库。** 术语表、说话人背景、入门词包，以及误听别名：你登记常被听错的词，只有另一个引擎听到的正是正确写法时，才替换。配置可导出和导入为 JSON，不含 Key、历史和录音。
- **历史记录。** 搜索过去的记录，回放原始音频，用另一个引擎重新转写，结果作为新版本保存。
- **撤销。** 取消录音后有 5 秒可以撤销，恢复并继续转写。

需要 Apple 芯片的 Mac 和 macOS 15 或更高版本。应用界面目前只有简体中文。

## 功能演示

### 换引擎，用自己的 Key

<p align="center"><img src="docs/images/feature-engines.gif" width="720" alt="本地、阿里云或 Soniox，用自己的 Key；两个云端互为热备，失败自动回退。"></p>

主模型可以选本地、阿里云百炼或 Soniox，云端用你自己的 API Key。两个云端都配置时互为热备，主引擎出错或太慢就用另一个的结果；云端都失败时，用保存好的录音在本地转写。浮窗会说明这次由哪个引擎完成。

### 误听纠正

<p align="center"><img src="docs/images/feature-alias.gif" width="720" alt="登记正确写法和常听错的样子；另一个引擎听到原词，才替换。"></p>

在“个人资料”里登记一个词的正确写法和它常被听错的样子。只有另一个引擎在同一位置听到的正是正确写法时才替换，所以不会把你真说的话改掉。

### 自动学习

<p align="center"><img src="docs/images/feature-learn.gif" width="720" alt="插入后手动改的词，同样的修正出现两次，就自动进个人词库。"></p>

插入后，你在输入框里手动改了某个词，同样的修正出现两次，这个词就自动加入个人词库，之后作为热词随录音发给云端引擎，让它下次写对。它只影响以后的识别，不会改写已经插入的文字；不想要可以在设置里关掉。

### 整理程度由你定

<p align="center"><img src="docs/images/feature-tidy.gif" width="720" alt="默认逐字，口头语都保留；转写提示词随录音发给引擎参考。"></p>

默认逐字输出，重复、口头语、自我修正都保留，不用大模型改写。想整理得干净一些，就在转写提示词里写下要求（比如“加标点，去掉嗯啊”），它随录音发给云端引擎作为参考；再配合术语表、说话人背景，以及“聊天应用里去掉句末句号”“英文结尾补空格”两个开关。

## 快速开始

### 1. 安装

**下载 dmg（推荐）。** 到 [GitHub Releases](https://github.com/Towow-ai/totype/releases/latest) 下载 `Totype-<版本>-arm64.dmg`，打开后把 Totype 拖进“应用程序”。它是不含语音模型的精简版，模型在应用里下载（约 246 MB）；同页的 `SHA256SUMS` 用来核对文件（`shasum -a 256 -c SHA256SUMS`）。

**用 Homebrew 安装。**

```bash
brew install --cask towow-ai/tap/totype
```

安装后第一次打开同样要按下面的步骤放行。

应用未经 Apple 公证，第一次打开会被 Gatekeeper 拦下：双击一次，点“完成”；打开 系统设置 → 隐私与安全性，滚到底部，点 Totype 提示旁的“仍要打开”，输入登录密码。也可以运行 `xattr -dr com.apple.quarantine /Applications/Totype.app` 后直接打开。详见[安装](docs/manual/zh-CN/01-install.md)。

**或者从源码构建。** 需要通过命令行工具（`xcode-select --install`）安装 macOS 15.4 或更高 SDK，不要求完整的 Xcode。

```bash
git clone https://github.com/Towow-ai/totype.git
cd totype
scripts/install.sh      # 构建并安装到 /Applications/Totype.app，已有版本先备份
```

首次构建会下载约 246 MB 的模型文件并校验。`scripts/install_local_signing_identity.sh` 创建稳定的本机签名身份，授权就能跨构建保留。`scripts/build.sh` 只构建不安装，配置项见 `config/local.env.example`。详见[安装](docs/manual/zh-CN/01-install.md)。

### 2. 授予三项权限

在 系统设置 → 隐私与安全性 里授予：

- **麦克风**：录音。
- **辅助功能**：向其他应用的输入框插入文字。
- **输入监控**：监听右 Option 和 Esc。授权后退出应用再打开。

应用未经 Apple 公证，更新后三项权限可能需要重新授予：删掉列表里 Totype 的旧条目，再加一次。详见[首次运行与授权](docs/manual/zh-CN/02-first-run.md)。

### 3. 说第一句话

把光标放进任何输入框，按一下右 Option，说话，再按一下。浮窗显示“已插入 N 字”，文字就在光标处。默认使用本地引擎，不需要任何账号。

## 选哪个引擎

| | 本地（SenseVoice） | Soniox | 阿里云百炼 |
|---|---|---|---|
| 模型 | SenseVoiceSmall | `stt-rt-v5` | `qwen-audio-3.0-asr-flash-streaming` |
| 联网 | 不需要 | 需要 | 需要 |
| API Key | 不需要 | 需要，自己申请 | 需要，自己申请 |
| 实时识别 | 没有，结束后一次出结果 | 有，菜单面板里能看到实时文字 | 有，菜单面板里能看到实时文字 |
| 个人词库 | 不使用 | 术语表、说话人背景、提示词 | 热词、提示词 |
| 费用 | 免费 | 按量向 Soniox 付费 | 按量向阿里云付费 |
| 适合 | 离线、隐私优先、先试用 | 想要更快更准，并用术语表和说话人背景提高准确度 | 想要更快更准，已有阿里云账号 |

两个云端都配置时，可以互为热备，也才能启用误听别名恢复。云端价格和免费额度以服务商价格页为准，使用前建议在服务商控制台设置额度上限。详见[引擎与 API Key](docs/manual/zh-CN/04-engines-and-keys.md)。

## 隐私

用本地引擎时，没有任何内容离开你的 Mac。用云端引擎时，音频、术语表和转写提示词发给你选的服务商；配置两个云端时，音频会同时发给两家。 Totype 没有自己的服务器。API Key 保存在本机的 JSON 文件里（目录权限 0700、文件权限 0600），不进 Keychain。详见[数据与隐私](docs/manual/zh-CN/07-data-and-privacy.md)。

## 常见问题

**需要联网吗？** 不需要。默认的本地引擎完全离线，首次构建时下载一次模型。云端引擎才需要网络。

**会改写我说的话吗？** 默认不会：识别出什么就插入什么，没有大模型参与。改多少由你决定，转写提示词、术语表、别名和插入偏好见[个性化](docs/manual/zh-CN/05-personalization.md)与[改多少](docs/manual/zh-CN/06-literal-rules.md)。

**要花钱吗？** 应用和本地引擎免费。云端引擎由服务商按用量向你收费，Totype 不经手也不收费。

**第一次打开提示无法验证开发者？** 应用未经公证。双击一次，再到 系统设置 → 隐私与安全性 点“仍要打开”；或者运行 `xattr -dr com.apple.quarantine /Applications/Totype.app`。

**按右 Option 没反应？** 先确认“输入监控”已授权，并且授权后重启过应用。在密码框里，或有其他应用占用了系统的 Secure Input 时，热键会暂停。排查步骤见[故障排查](docs/manual/zh-CN/08-troubleshooting.md)。

**能在 Intel Mac 或 Windows 上用吗？** 目前不能，只支持 Apple 芯片和 macOS 15 或更高版本。

已知限制的完整列表见[名词与限制](docs/manual/zh-CN/10-glossary-and-limits.md)。

## iPhone 版（源码安装，预览）

仓库里还有一个 iPhone 版：主 App 录音识别，自定义键盘把文字插进任何输入框，灵动岛和控制中心显示录音状态。它需要完整的 Xcode、XcodeGen 和你自己的 Apple ID，用你自己的签名装到你自己的手机上；免费账号的签名 7 天过期，到期后重新安装。没有云端 Key 时用 iPhone 本机识别，准确率不如云端。“录音后自动返回原 App”用到私有 API，默认不编译，打开后无法上架 App Store 或 TestFlight。步骤和风险见 [iPhone 版](docs/manual/zh-CN/11-iphone.md)。

## 文档

[使用说明书](docs/manual/zh-CN/00-overview.md)：安装、首次运行、日常使用、引擎与 Key、个性化、插入规则、数据与隐私、故障排查、构建与贡献、iPhone 版。

## 参与贡献

构建、测试、配置和仓库结构见[构建与贡献](docs/manual/zh-CN/09-build-and-contribute.md)。发现问题或有想法，欢迎提 issue。提交前请读[贡献指南](CONTRIBUTING.md)；安全问题请按[安全政策](SECURITY.md)私下报告。更新历史见[更新日志](CHANGELOG.md)。

## 许可证与第三方署名

Totype 以 [Apache License 2.0](LICENSE) 发布，另见 [NOTICE](NOTICE)。

本地引擎使用 FunASR / FunAudioLLM（Alibaba Group）的 **SenseVoiceSmall** 模型，经 `llama-funasr-sensevoice`（MIT）和 ggml / llama.cpp（MIT）运行，并使用 FSMN-VAD 模型（Apache-2.0）。SenseVoiceSmall 权重适用 FunASR Model Open Source License v1.1，要求注明出处与作者并保留模型名称，我们保持模型名与文件名不变。使用权重前请阅读该协议，特别是关于用途的条款；打算商用的话请注意，上游项目对商用问题的答复目前仍标注为非最终确认。各许可证全文与版本见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。仓库本身不包含模型权重，构建和精简版应用会从原始来源下载。
