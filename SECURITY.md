# 安全政策 · Security Policy

简体中文 · [English](#security-policy-english)

## 报告漏洞

请不要在公开 issue 里描述安全问题。使用 GitHub 的私密漏洞报告：打开本仓库的 [Security 页面](https://github.com/Towow-ai/totype/security/advisories/new)，点“Report a vulnerability”，写明受影响的版本、复现步骤和你判断的影响。请不要在报告里附上真实的 API Key、录音或转写原文。

我们会尽快确认收到，并在修复发布前与你保持沟通。修复发布后，如果你愿意，我们会在更新日志里致谢。

只有最新发布的版本会得到安全修复。

## 威胁模型

Totype 是运行在你自己 Mac 上的菜单栏应用，没有自己的服务器。下面是它保护什么、依赖什么，以及不保护什么。

**API Key 是明文文件。** 云端引擎的 Key 保存在数据目录下的 `personal-secrets.json`，没有加密，也不进 Keychain。数据目录的权限是 0700，文件权限是 0600，所以其他普通用户读不到；同一账户下运行的任何程序、管理员，以及能离线读取磁盘的人，都读得到。对离线读取的防护完全依赖 FileVault 磁盘加密，请在 系统设置 → 隐私与安全性 里打开它。备份数据目录时请排除这个文件。

**录音、转写和历史**保存在同一个数据目录里，保护方式相同。使用云端引擎时，音频、术语表和转写提示词会发给你选择的服务商，服务商如何处理由它们的条款决定；配置了两个云端时，音频会同时发给两家。本地引擎不联网。除下载本地模型（来自 Hugging Face，下载后校验固定的 SHA-256）和你配置的云端服务外，应用不主动联网。

**三项系统权限的含义：**

- 麦克风：录音。
- 辅助功能：向其他应用当前的输入框插入文字，也能读取该输入框的内容。“自动学习”用它观察插入之后你手动改了什么。
- 输入监控：监听全局按键，用来识别右 Option 和 Esc。这意味着应用能看到你的键盘事件。右 Option 通过修饰键事件识别，Esc 只在录音期间监听；应用只用它判断这两个键，不记录其他按键。

授予这三项，等于相信这个应用不会滥用它们。请只运行你信任的构建；从源码构建的人，可以先读代码再授权。

**ad-hoc 签名。** 发布的 dmg 使用 ad-hoc 签名，没有 Apple 开发者证书，也没有经过公证。这有两个后果。第一，系统不会替你验证发布者，所以请用 Release 页面里的 `SHA256SUMS` 核对下载的文件。第二，ad-hoc 签名在每次更新后都会变化，macOS 把三项授权绑定在代码签名上，更新后授权会失效，需要在系统设置里删掉旧条目重新添加。这是预期行为，不是漏洞。

**不在范围内：** 已经获得你账户或物理访问权限的攻击者；你自己授权给其他程序的权限；第三方云服务商自身的安全问题；对本机 Gatekeeper 提示的绕过，因为放行是用户的主动操作。

---

## Security Policy (English)

### Reporting a vulnerability

Please do not describe security problems in a public issue. Use GitHub's private vulnerability reporting: open the repository's [Security page](https://github.com/Towow-ai/totype/security/advisories/new) and choose "Report a vulnerability". Include the affected version, steps to reproduce and the impact you see. Do not attach real API keys, recordings or transcript text.

We will acknowledge the report as soon as we can and keep you informed until a fix ships. After the fix is released we will credit you in the changelog if you wish.

Only the latest release receives security fixes.

### Threat model

Totype is a menu-bar app that runs on your own Mac and has no server of its own. This is what it protects, what it relies on, and what it does not protect.

**API keys are a plain file.** Cloud-engine keys are stored in `personal-secrets.json` in the data directory, unencrypted and outside the Keychain. The directory has mode 0700 and the file 0600, so other ordinary users cannot read it. Any program running as your account, an administrator, and anyone who can read the disk offline can. Protection against offline reading relies entirely on FileVault disk encryption; please turn it on in System Settings → Privacy & Security. Exclude this file when you back up the data directory.

**Recordings, transcripts and history** live in the same data directory and are protected the same way. With a cloud engine, audio, glossary terms and the transcription prompt go to the provider you chose, and their terms decide how it is handled; with two cloud engines configured, the audio goes to both. The local engine stays offline. Apart from downloading the local model (from Hugging Face, checked against a pinned SHA-256) and the cloud services you configure, the app does not connect to the network on its own.

**What the three system permissions mean:**

- Microphone: records your voice.
- Accessibility: inserts text into the focused field of another app, and can read that field's content. "Learn from edits" uses it to see what you changed by hand after an insertion.
- Input Monitoring: listens to global key events to detect Right Option and Esc. That means the app can see your keyboard events. Right Option is detected from modifier-key events, and Esc is watched only while recording. The app uses the events only to recognize those two keys and does not record other keys.

Granting these three is trusting the app not to misuse them. Run only builds you trust; if you build from source, you can read the code before you grant them.

**Ad-hoc signing.** The published dmg is signed ad-hoc: it has no Apple developer certificate and is not notarized. Two consequences follow. First, the system does not verify the publisher for you, so check the download against `SHA256SUMS` on the Release page. Second, an ad-hoc signature changes with every update, and macOS ties the three permissions to the code signature, so they stop working after an update and you need to remove the old entries in System Settings and add them again. This is expected behavior, not a vulnerability.

**Out of scope:** attackers who already have your account or physical access; permissions you granted to other programs; security problems of third-party cloud providers; bypassing the local Gatekeeper prompt, since approving the app is the user's own action.
