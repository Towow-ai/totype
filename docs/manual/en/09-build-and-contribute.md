# 09 Build and contribute

[简体中文](../zh-CN/09-build-and-contribute.md)

Building from source needs macOS 15 or later, Apple silicon, the Command Line Tools and network access. This chapter lists the build scripts, configuration variables, test entry points and repository layout, and the principles a contribution must respect.

## Build and install

| Command | Purpose |
|---|---|
| `scripts/build.sh` | Builds with `swiftc` and signs; outputs `build/Totype.app.disabled` (suffixed, not directly runnable) |
| `scripts/install.sh` | Builds, then installs to `/Applications/Totype.app`, backs up the old copy, swaps atomically and rolls back on failure |
| `scripts/install_local_signing_identity.sh` | Creates a local self-signed identity so grants survive rebuilds |
| `scripts/verify.sh` | Main entry: core tests, the self-test programs, a full app build and a sample audio run with the bundled model |

The build finds the SDK with `xcrun --sdk macosx --show-sdk-path`; it must be macOS 15.4 or later. You can also open `VerbatimVoice.xcodeproj` in Xcode. The first build downloads about 246 MB of model files; `VERBATIM_SENSEVOICE_DIR` can point at a directory you already downloaded.

## Configuration variables

Copy `config/local.env.example` to `config/local.env` (ignored by git) and edit it, or use environment variables, which take precedence. Defaults live in `scripts/lib/env.sh`.

| Variable | Default | Notes |
|---|---|---|
| `VERBATIM_BUNDLE_ID` | `ai.towow.totype` | Bundle ID. macOS ties Accessibility and Input Monitoring grants to it; use your own when you build yourself |
| `VERBATIM_SIGN_IDENTITY` | `Totype Local Code Signing` | Code-signing identity. Falls back to ad-hoc signing with a warning if missing |
| `VERBATIM_APP_NAME` | `Totype` | Display name, executable name and install path |
| `VERBATIM_APP_NAME_ZH` | empty | Chinese display name; empty means no localized name is generated |
| `VERBATIM_DATA_DIR_NAME` | `Totype` | Folder name where the install script looks for the running app's status files. The app's own data folder is still fixed to `VerbatimVoice` in source; until that is migrated, set this to `VerbatimVoice` if the install script must find a running app |
| `VERBATIM_SDK_PATH` | result of `xcrun` | Pins an SDK |
| `VERBATIM_SENSEVOICE_DIR` | empty | Directory with already downloaded model and runtime files |

## Repository layout

```text
VerbatimVoice/            The app: AppKit/SwiftUI UI, audio, engine adapters, insertion
VerbatimVoiceCore/        Pure Swift core: profile, mishearing restoration, text joining, timeout policy
VerbatimVoice.xcodeproj   Xcode project
scripts/                  Build, install, verification and self-test programs
config/                   Local configuration example
tools/history_report.py   Usage statistics from history.jsonl
docs/DESIGN.md            Visual and interface design
docs/manual/              This manual
```

## Contributing

Issues and pull requests are welcome. These principles decide whether a change can be accepted:

- **Do not change the speaker's words.** Changes that introduce LLM rewriting, polishing or completion will not be accepted. The only permitted text change is restoring a known mishearing that another engine confirms.
- **Insert at most once per utterance, and write audio to disk first.** A change to the insertion path must explain how it keeps both.
- **Hotkey, event tap and permission changes** need the maintainer to verify them on a real Mac. State in the pull request which macOS version and permission state you tested.
- **Do not commit private data or secrets.** No personal glossaries, recordings or API keys in the repository.
- Run `scripts/verify.sh` before submitting.
- Visual design follows `docs/DESIGN.md`: solid backgrounds, and the only color is the recording red, shown only in dark mode while recording.
