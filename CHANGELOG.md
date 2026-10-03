# 更新日志 · Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。每个版本先写中文，再写英文。

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/). Each release lists Chinese first, then English.

## [Unreleased]

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
