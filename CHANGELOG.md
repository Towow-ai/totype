# 更新日志 · Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。每个版本先写中文，再写英文。

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/). Each release lists Chinese first, then English.

## [Unreleased]

- 修复通过 ⌘, 打开的 macOS 设置窗口：首次打开时直接显示设置页，顶部的“个人资料”和“设置”按钮不再被标题栏遮挡。
- Fix the macOS Settings window opened with Command+Comma: it now shows the settings page on first open, and the title bar no longer covers the Profile and Settings buttons.

## [0.5.0] - 2026-10-04

- 菜单面板新增“设置…”（⌘,）和“个人资料…”入口。单次录音默认上限从 3 分钟提高到 10 分钟，可在设置里调到 30 分钟。
- The menu panel gains Settings… (⌘,) and Profile… entries. The default limit for one recording rises from 3 to 10 minutes and can be raised to 30 minutes in Settings.

- 英文界面：菜单面板、浮窗、设置页（含个人资料和触发键）、历史窗口、引导窗口、通知、错误与状态提示、权限用途说明都有英文版。系统语言是中文时仍显示现在的中文，其他语言一律显示英文。文案放在 `VerbatimVoice/Resources/{en,zh-Hans}.lproj`，`scripts/check_l10n.sh`（已并入 `verify.sh`）检查两张表的键一致、代码里每个本地化调用都有条目，并列出疑似漏网的中文字面量；`scripts/design_preview.sh docs-en` 渲染英文截图（`docs/images/en`），README.en.md 和英文说明书改用这组截图。

- English interface: the menu panel, overlay, Settings (including Profile and Trigger key), History window, first-run guide, notifications, error and status messages and the permission prompts now come in English. A Chinese system language still shows the current Chinese text; every other language shows English. The strings live in `VerbatimVoice/Resources/{en,zh-Hans}.lproj`. `scripts/check_l10n.sh` (part of `verify.sh`) checks that both tables have the same keys and that every localized call in the code has an entry, and lists Chinese literals that may have escaped localization. `scripts/design_preview.sh docs-en` renders English screenshots (`docs/images/en`), which README.en.md and the English manual now use.

- 界面语言可以在 设置 → 界面语言 里选择：跟随系统（默认）、简体中文或 English，改完点“立即重启”生效。这项选择也包含在导出和导入的配置里（`interface.language`）。

- Choose the interface language in Settings → Language: Follow system (default), 简体中文 or English; click Restart now to apply it. The choice is part of exported and imported profiles (`interface.language`).

- 可选触发键：在设置 → 触发键里，可以把开始和结束录音的键从右 Option 换成右 Command、左 Option、左 Control 或 Fn（🌐），选好立即生效，导出的配置里也会带上这项。右 Option 仍然是按下就开始。另外四个键平时常用于快捷键，所以改成单独按一下、松开时才开始；和其他键或鼠标一起按（比如 Command+C）不会开始录音，按住超过 1 秒也不算。选 Fn 时，先到 系统设置 → 键盘，把“按下 🌐 键时”改为“不执行任何操作”。

- Choose your trigger key: in Settings → Trigger key, the key that starts and stops recording can be Right Command, Left Option, Left Control or Fn (🌐) instead of Right Option. The change applies at once and is included in exported settings. Right Option still starts on press. The other four keys are everyday shortcut keys, so they start on release, only after a press on its own: pressed together with another key or the mouse (Command+C, for example) they do nothing, and a hold longer than 1 second does not count. Before using Fn, set System Settings → Keyboard → "Press 🌐 key to" to "Do Nothing".

## [0.4.0] - 2026-10-04

首个公开版本。

- 在任意应用的输入框里语音输入：右 Option 开始，再按一下结束并插入，Esc 取消；屏幕底部的浮窗显示状态；在终端里只输入文字，不替你按回车。
- 三种识别引擎：本地 SenseVoice（离线、免费）、Soniox（`stt-rt-v5`）和阿里云百炼（`qwen-audio-3.0-asr-flash-streaming`）实时识别，云端用自己的 API Key。
- 默认逐字输出，不用大模型改写；转写提示词、术语表、说话人背景、聊天应用去句末句号、英文结尾补空格由你按需调整。一次说话最多插入一次。
- 两个云端互为热备：主引擎出错或太慢时用热备的结果；云端都失败时，用保留的音频在本地转写；浮窗说明这次由哪个引擎完成。
- 音频先写入磁盘再识别；识别失败、取消或切换应用后，录音仍在历史里，可以再转写。取消录音后有 5 秒可以撤销。
- 个人词库：术语表、说话人背景、入门词包，以及误听别名（只有另一个引擎听到的正是正确写法时才替换）；配置可导出和导入为 JSON，不含 Key、历史和录音。
- 自动学习：插入后你手动改了某个词，同样的修正出现两次，就加入个人词库；只影响以后的识别，设置里可以关掉。
- 历史记录：搜索、回放原始音频、用另一个引擎重新转写，结果存为新版本。
- 预编译 dmg 是不含语音模型的精简版，模型在首次使用时下载（约 246 MB，下载后校验）。应用使用 ad-hoc 签名，未经 Apple 公证，首次打开需要手动放行，见 [README](README.md#快速开始)。

First public release.

- Voice input into any text field: Right Option starts, a second press stops and inserts, Esc cancels. A floating panel at the bottom of the screen shows the state. In a terminal it types text only and never presses Return.
- Three recognition engines: local SenseVoice (offline, free), Soniox (`stt-rt-v5`) and Alibaba Cloud Bailian (`qwen-audio-3.0-asr-flash-streaming`) real-time recognition. Cloud engines use your own API key.
- Verbatim by default, with no LLM rewriting. A transcription prompt, glossary, speaker background, dropping the final period in chat apps and a trailing space after English let you tune the result. At most one insertion per utterance.
- Two cloud engines back each other up: if the primary fails or is slow, the backup's result is used. If all cloud engines fail, the saved audio is transcribed locally. The panel says which engine finished the job.
- Audio is written to disk before recognition. After a failure, a cancel or an app switch the recording stays in history and can be transcribed again. A cancelled recording can be undone for 5 seconds.
- Personal lexicon: glossary, speaker background, starter word packs, and mishearing aliases (replaced only when another engine heard the correct spelling). Settings export and import as JSON without keys, history or recordings.
- Learning from edits: when you fix a word after insertion and the same fix appears twice, it joins your lexicon. It only affects later recognition and can be turned off in settings.
- History: search, replay the original audio, and re-transcribe with another engine; the result is saved as a new version.
- The prebuilt dmg is a lite build without the speech model, which downloads on first use (about 246 MB, checked after download). The app is ad-hoc signed and not notarized by Apple, so the first launch needs a manual approval; see the [README](README.en.md#quick-start).
