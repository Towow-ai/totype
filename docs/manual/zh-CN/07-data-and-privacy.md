# 07 数据与隐私

[English](../en/07-data-and-privacy.md)

用本地引擎时，你的声音和文字不离开这台电脑。用云端引擎时，音频和你登记的术语等会发给你选的云服务商。所有数据放在你自己的用户目录里，API Key 是明文文件，依赖 FileVault 保护。

## 数据放在哪里

数据目录是 `~/Library/Application Support/Totype/`（早期版本使用的目录名是 `VerbatimVoice`）。目录权限只对当前用户开放。里面有：

| 文件 | 内容 |
|---|---|
| `history.jsonl` | 每次录音的文字、引擎、耗时、插入结果 |
| `history-actions.jsonl` | 你对记录的人工修正和插入后观察到的改动 |
| `history-revisions.jsonl` | 重新转写产生的版本 |
| `audio/` | 保留的录音，优先存为 FLAC，转码失败时为 WAV |
| `personal-lexicon-v1.jsonl` | 个人词库与别名 |
| `personal-secrets.json` | API Key，明文 JSON，文件权限 0600 |
| `models/` | 下载的本地模型（精简版首次使用时下载） |

术语表、说话人背景、转写提示词和各项开关保存在 macOS 的应用偏好里，文件是 `~/Library/Preferences/` 下以应用的 Bundle ID 命名的 plist（默认 `ai.towow.totype.plist`）。

“打开数据目录”可以从菜单面板的“⋯”或设置里直接打开这个文件夹。

## 哪些内容会发给云端

| 内容 | Soniox | 阿里云百炼 | 本地 |
|---|---|---|---|
| 录音音频 | 发送 | 发送 | 不发送 |
| 术语表与个人词库中的词 | 发送 | 发送（作为热词） | 不发送 |
| 说话人背景 | 发送 | 不发送 | 不发送 |
| 转写提示词 | 发送 | 发送（最多 400 字） | 不发送 |
| 误听别名 | 不发送 | 不发送 | 不发送 |
| API Key | 用于鉴权 | 用于鉴权 | 不涉及 |

只配置一个云端 Key 时，音频只发给你选的那个。两个云端 Key 都保存后，同一段音频会同时发给两家：一家主用，一家热备，见 [04 引擎与 API Key](04-engines-and-keys.md)。不想让音频发给某一家，清空它的 Key，或把主引擎设为“本地”。

服务商如何处理这些数据，由它们各自的条款决定，请在使用前阅读。 Totype 本身不运行服务器，也不上传历史。

## API Key 的保存与风险

Key 保存在 `personal-secrets.json` 里，是明文，没有额外加密。目录权限 0700、文件权限 0600，只有你的账户（和管理员）能读，并依赖系统的 FileVault 磁盘加密来防止他人离线读取。因此：

- 在 系统设置 → 隐私与安全性 里打开 FileVault。
- 备份数据目录时排除 `personal-secrets.json`。
- 导出的个人资料不含 Key，可以共享。
- 怀疑 Key 泄露时，到服务商控制台作废它并重新创建。

## 历史与录音的保留

默认保留 30 天、最多 2048 MB 的音频，超出时自动清理旧音频，应用启动和每次保存后都会检查。可以在设置的“高级与诊断”里调整“音频保留”和“音频上限”。“保留录音与历史”开关在“识别”一节。历史窗口只显示最近 20 条。

## 清除全部数据

1. 退出应用。如果开启过“登录后自动启动”，先在设置里关掉它。
2. 删除数据目录：`rm -rf ~/Library/Application\ Support/Totype`，如果你用过早期版本，也删除 `~/Library/Application\ Support/VerbatimVoice`。
3. 删除偏好：`defaults delete ai.towow.totype`。
4. 重置授权：`tccutil reset All ai.towow.totype`。
5. 把 `/Applications/Totype.app` 移到废纸篓。

只想清掉录音而保留设置，删除数据目录里的 `audio/` 文件夹即可，历史里对应记录会显示“没有保留音频”。
