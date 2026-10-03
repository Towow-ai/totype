# 01 Install

[简体中文](../zh-CN/01-install.md)

You can build from source today. A prebuilt dmg is coming: it is a lite build without the speech model, which downloads on first run. The lite build already works from source (see Option 2). Because the app is not notarized by Apple, the first launch needs one extra manual approval.

## Option 1: prebuilt dmg (coming soon)

The dmg will be published on GitHub Releases (`https://github.com/Towow-ai/totype/releases`) together with a `SHA256SUMS` file. It will be the lite build, which does not include the local model: you download it from the `本地模型` (Local model) row under `设置` → `识别` (Recognition), or from the first-run guide. It is about 246 MB from Hugging Face, checked against checksums, and stored in `~/Library/Application Support/Totype/models/`.

1. Download the dmg. You can compare `shasum -a 256 <file>` with `SHA256SUMS`.
2. Open the dmg and drag Totype into the Applications folder.
3. Double-click Totype in Applications. macOS shows a message that it cannot open or verify the developer. Click Done.
4. Open System Settings → Privacy & Security, scroll to the bottom, find the message about Totype, click Open Anyway, and enter your login password.
5. Launch it again and follow [02 First run and permissions](02-first-run.md).

Since macOS 15, right-clicking and choosing Open no longer bypasses the check, so steps 3 and 4 are required. If you prefer the command line, remove the quarantine flag and open the app:

```bash
xattr -dr com.apple.quarantine /Applications/Totype.app
```

Screenshot placeholder: ![Open Anyway](../../images/gatekeeper-open-anyway.png)

## Option 2: build from source

A source build bundles the local model into the app, so it behaves like a full build. You need the Xcode Command Line Tools; full Xcode is not required. The SDK must be macOS 15.4 or later.

1. Install the tools: `xcode-select --install`.
2. Clone the repository: `git clone https://github.com/Towow-ai/totype.git`, then enter the directory.
3. Optional: copy `config/local.env.example` to `config/local.env` and adjust the app name, bundle ID and signing identity (see "Signing and stable permissions" below).
4. Run `scripts/install.sh`. It builds the app, installs it to `/Applications/Totype.app`, backs up any existing copy first, and launches it.
5. To build without installing, run `scripts/build.sh`. The result is in `build/`. It carries a `.disabled` suffix and cannot be launched by double-clicking; use `scripts/install.sh` to install it.

The first build downloads about 246 MB of runtime and model files and verifies pinned SHA-256 checksums. Downloads are cached in `.build/downloads/`. On a slow network or behind a proxy, download the files yourself into one directory and point the environment variable `VERBATIM_SENSEVOICE_DIR` at it. The directory must contain `llama-funasr-sensevoice`, `sensevoice-small-q8.gguf` and `fsmn-vad.gguf`.

To build the lite app without the model, run `VERBATIM_BUNDLE_MODEL=0 scripts/build.sh` (or the same prefix on `scripts/install.sh`). The app then downloads the model on first use: use the first-run guide, or the `本地模型` row under `设置` → `识别`, which shows `已内置` (Bundled), `已下载` (Downloaded), `未安装` (Not installed, with a `下载` button), `下载中` (Downloading, with progress and `取消`) or `校验失败` (Verification failed, with `重试`). If you only use cloud engines, you can skip the model.

### Signing and stable permissions

macOS ties Microphone, Accessibility and Input Monitoring grants to the app's code signature. Without a usable signing identity, the build script falls back to ad-hoc signing and prints a warning; the signature then changes on every rebuild and macOS may revoke your grants. `scripts/install_local_signing_identity.sh` creates a self-signed identity in your login keychain, named after `VERBATIM_SIGN_IDENTITY`. Later builds reuse it, and the grants survive rebuilds.

## Updating

- Source build: pull the new code and run `scripts/install.sh` again.
- dmg (once published): download the new version and replace the one in Applications.

After an update of a non-notarized build, macOS may invalidate the three grants. Typical symptoms are a dead hotkey, or the menu panel showing `Esc 取消不可用：需要重新授权输入监控` (Esc cancel unavailable: Input Monitoring must be granted again). Fix: open System Settings → Privacy & Security, delete the old Totype entries from Microphone, Accessibility and Input Monitoring, grant them again, and restart the app.

## Uninstalling

1. If you turned on `登录后自动启动` (Launch at login), turn it off first, under `高级与诊断` (Advanced and diagnostics) on the `设置` (Settings) page of the history window.
2. Quit the app and move `/Applications/Totype.app` to the Trash.
3. To remove data, follow "Wiping all data" in [07 Data and privacy](07-data-and-privacy.md).
4. Delete Totype from the three lists in System Settings → Privacy & Security, or run `tccutil reset All ai.towow.totype`.
