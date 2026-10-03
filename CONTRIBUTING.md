# 参与贡献 · Contributing

简体中文 · [English](#contributing-english)

感谢你愿意改进 Totype。提 issue、改文档、修 bug、加功能都欢迎。动手做大改动之前，请先开一个 issue 说明想法，免得双方做重复的工作。参与本项目即表示同意遵守[行为准则](CODE_OF_CONDUCT.md)。

## 不改原话

Totype 的核心承诺是不改你说的话。识别出什么就插入什么，唯一允许的文字变动，是“另一个引擎佐证的已知误听恢复”：只有另一个引擎在同一位置听到的正是用户登记的正确写法，才会替换。

因此，凡是引入大模型改写、润色、补全、翻译或纠错的合并请求，都需要在描述里专门说明：它改变了什么，默认是否开启，以及为什么不违背这条原则。默认开启的改写不会被接受。

另外两条同样不变：一次说话最多插入一次；音频先写入磁盘，再识别。改动插入路径时，请说明如何保持这两点。

## 构建与验证

需要 Apple 芯片的 Mac、macOS 15 或更高版本，以及能提供 macOS 15.4 SDK 的命令行工具（`xcode-select --install`），不要求完整的 Xcode。

```bash
git clone https://github.com/Towow-ai/totype.git
cd totype
scripts/build.sh     # 只构建，产物在 build/Totype.app.disabled
scripts/verify.sh    # 提交前必跑
```

`scripts/verify.sh` 依次运行核心测试、各项自测程序，构建完整应用，并用内置的 SenseVoice 模型转写一段样本音频。首次运行会下载约 246 MB 的模型，样本音频由 macOS 自带的中文语音合成，需要装有中文朗读语音（系统设置 → 辅助功能 → 朗读内容）。依赖个人资料文件的测试在文件缺失时会自动跳过，这是预期行为。

测试不调用任何付费接口，也不需要 API Key。合并请求会在 GitHub Actions 里跑同一个 `scripts/verify.sh`，通过后才合并。

配置项见 `config/local.env.example`。自己构建时建议换一个 `VERBATIM_BUNDLE_ID`，免得和已安装的 Totype 争用系统授权。更多细节见[构建与贡献](docs/manual/zh-CN/09-build-and-contribute.md)。

## 需要维护者真机验收的改动

热键、event tap、权限（麦克风、辅助功能、输入监控）和文字插入路径的行为取决于真实的系统状态，自动化测试覆盖不到。这类改动，请在合并请求里写明你测试过的 macOS 版本、芯片和三项授权状态，维护者会在真机上再验收一遍才合并。热键相关代码的改动最容易在别人的机器上出问题，请尽量缩小改动范围。

## 提交规范

- 一个提交做一件事。标题用一句话说明改了什么，建议加范围前缀，如 `hotkey: ...`、`docs: ...`、`scripts: ...`；英文或中文都可以。
- 正文写清楚为什么改，必要时附上复现步骤或日志。
- 合并请求保持小而聚焦，附带的重构请单独提交。
- 不要提交私人数据和密钥：个人术语表、录音、转写原文、API Key、`config/local.env` 都不进仓库。
- 视觉与界面以 [docs/DESIGN.md](docs/DESIGN.md) 为准：纯色背景，颜色只有录音红，且只在深色模式录音时出现。
- 修改用户可见的行为时，同步更新 `CHANGELOG.md` 的 `[Unreleased]` 部分和相关说明书章节。

---

## Contributing (English)

Thank you for helping improve Totype. Issues, documentation fixes, bug fixes and features are all welcome. For anything larger than a small fix, please open an issue first so we do not duplicate work. By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

### Verbatim first

Totype's core promise is that it does not change what you said. What the engine recognizes is what gets inserted. The only permitted text change is a known-mishearing recovery that a second engine confirms: a word is replaced only when another engine heard, at the same position, the spelling the user registered as correct.

A pull request that introduces LLM rewriting, polishing, completion, translation or correction therefore needs its own explanation in the description: what it changes, whether it is on by default, and why it keeps this promise. Rewriting that is on by default will not be accepted.

Two more rules do not change: at most one insertion per utterance, and audio is written to disk before recognition. If you touch the insertion path, say how both still hold.

### Build and verify

You need an Apple-silicon Mac on macOS 15 or later, with command line tools that provide the macOS 15.4 SDK (`xcode-select --install`). Full Xcode is not required.

```bash
git clone https://github.com/Towow-ai/totype.git
cd totype
scripts/build.sh     # build only; output is build/Totype.app.disabled
scripts/verify.sh    # run before every commit
```

`scripts/verify.sh` runs the core tests and the self-test programs, builds the full app, and transcribes a sample recording with the bundled SenseVoice model. The first run downloads about 246 MB of model files. The sample is synthesized with the macOS text-to-speech, so a Chinese voice must be installed (System Settings → Accessibility → Spoken Content). Tests that need personal profile files skip themselves when the files are missing; that is expected.

Tests call no paid service and need no API key. Pull requests run the same `scripts/verify.sh` in GitHub Actions and must pass before merging.

See `config/local.env.example` for settings. When you build for yourself, set your own `VERBATIM_BUNDLE_ID` so it does not compete with an installed Totype for system permissions. More in [Build and contribute](docs/manual/en/09-build-and-contribute.md).

### Changes that need a maintainer's on-device check

Hotkey, event-tap, permission (Microphone, Accessibility, Input Monitoring) and text-insertion behavior depends on real system state that automated tests cannot reproduce. For these changes, state in the pull request which macOS version, chip and permission state you tested. A maintainer will test again on a real machine before merging. Hotkey code is the most likely to break on other people's machines, so keep those changes as small as you can.

### Commits

- One commit, one change. Write a one-line title that says what changed, preferably with a scope prefix such as `hotkey: ...`, `docs: ...` or `scripts: ...`. English or Chinese is fine.
- Use the body to explain why, with reproduction steps or logs when they help.
- Keep pull requests small and focused; put incidental refactoring in a separate commit.
- Never commit private data or secrets: personal glossaries, recordings, transcript text, API keys or `config/local.env`.
- Visual design follows [docs/DESIGN.md](docs/DESIGN.md): solid backgrounds, and the only color is the recording red, shown only in dark mode while recording.
- When you change user-visible behavior, update the `[Unreleased]` part of `CHANGELOG.md` and the relevant manual chapter.
