# 07 Data and privacy

[简体中文](../zh-CN/07-data-and-privacy.md)

With the local engine, your voice and text stay on this computer. With a cloud engine, audio and the terms you registered go to the provider you chose. All data lives in your user folder, and API keys sit in a plain-text file that relies on FileVault for protection.

## Where data lives

The data folder is `~/Library/Application Support/Totype/` (early versions used the folder name `VerbatimVoice`). Only your user account can open it. It contains:

| File | Contents |
|---|---|
| `history.jsonl` | Text, engine, timings and insertion result of every recording |
| `history-actions.jsonl` | Your manual corrections and edits observed after insertion |
| `history-revisions.jsonl` | Versions created by re-transcription |
| `audio/` | Saved recordings, FLAC by default, WAV if conversion fails |
| `personal-lexicon-v1.jsonl` | Personal lexicon and aliases |
| `personal-secrets.json` | API keys, plain-text JSON, file mode 0600 |
| `models/` | The downloaded local model (lite builds download it on first use) |

The glossary, speaker background, transcription prompt and all switches are stored in macOS app preferences: a plist under `~/Library/Preferences/` named after the bundle ID (`ai.towow.totype.plist` by default).

`打开数据目录` (Open data folder), in the `⋯` menu of the menu panel or in settings, opens the folder.

## What goes to the cloud

| Item | Soniox | Alibaba Cloud Bailian | Local |
|---|---|---|---|
| Recorded audio | Sent | Sent | Not sent |
| Glossary and personal lexicon words | Sent | Sent (as hotwords) | Not sent |
| Speaker background | Sent | Not sent | Not sent |
| Transcription prompt | Sent | Sent (up to 400 characters) | Not sent |
| Mishearing aliases | Not sent | Not sent | Not sent |
| API key | Used to authenticate | Used to authenticate | Not involved |

With one cloud key, audio goes only to the engine you chose. With both keys saved, the same audio goes to both providers at once, one as primary and one as hot standby; see [04 Engines and API keys](04-engines-and-keys.md). To keep audio away from a provider, clear its key or set the primary engine to local.

How providers handle this data is governed by their own terms; read them before use. Totype itself runs no server and uploads no history.

## API key storage and risk

Keys are stored in `personal-secrets.json` in plain text with no extra encryption. The folder mode is 0700 and the file mode 0600, so only your account (and administrators) can read it, and FileVault disk encryption keeps others from reading it offline. Therefore:

- Turn on FileVault in System Settings → Privacy & Security.
- Exclude `personal-secrets.json` when you back up the data folder.
- An exported profile contains no keys and is safe to share.
- If you suspect a key leaked, revoke it in the provider console and create a new one.

## Keeping history and audio

By default Totype keeps 30 days and at most 2048 MB of audio, and cleans up older audio automatically at launch and after each save. Adjust `音频保留` (Audio retention) and `音频上限` (Audio limit) under `高级与诊断` in `设置`. The switch `保留录音与历史` (Keep recordings and history) is in the `识别` section. The history window shows only the latest 20 entries.

## Wiping all data

1. Quit the app. If you ever turned on `登录后自动启动`, turn it off in settings first.
2. Delete the data folder: `rm -rf ~/Library/Application\ Support/Totype`. If you used an early version, also delete `~/Library/Application\ Support/VerbatimVoice`.
3. Delete preferences: `defaults delete ai.towow.totype`.
4. Reset permissions: `tccutil reset All ai.towow.totype`.
5. Move `/Applications/Totype.app` to the Trash.

To clear only the recordings and keep your settings, delete the `audio/` folder inside the data folder. The matching history entries then show that no audio is kept.
