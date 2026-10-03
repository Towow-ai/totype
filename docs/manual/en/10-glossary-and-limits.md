# 10 Glossary and limits

[简体中文](../zh-CN/10-glossary-and-limits.md)

## Glossary

| Term | Meaning |
|---|---|
| Primary engine | The recognition engine chosen in settings; it handles the recording |
| Hot standby | When two clouds are configured, the other cloud recognizes in the background at the same time; its result is used if the primary fails or is slow |
| Local fallback | When the cloud does not answer in time, the saved audio is transcribed locally. Controlled by `云端异常时自动使用本地模型` in settings |
| Final result (定稿) | The engine's final text for a recording |
| Overlay | The capsule at the bottom of the screen showing recording state |
| Preview card | The card that shows the text and lets you insert or copy it when the target cannot be confirmed |
| Personal lexicon | Words and mishearing aliases you registered, plus words learned automatically |
| Alias | A wrong spelling an engine often produces for a word |
| Restoration | Swapping an alias back to the correct spelling when another engine confirms it; the only text change |
| Re-transcribe | Recognize the saved audio again; the result is added as a new version |
| Accessibility | macOS permission to send text into other apps' fields |
| Input Monitoring | macOS permission to listen for Right Option and Esc |
| Secure Input | A macOS mechanism that holds keyboard events exclusively, for example in password fields; the global hotkey may stop working meanwhile |
| Notarization | Apple's security check for distributed apps; the prebuilt version of Totype is not notarized |

## Known limitations

- Apple silicon and macOS 15 or later only.
- The local engine returns text in one piece after you stop, has no live captions, uses no personal lexicon, speaker background or prompt, and handles mixed-in English terms less reliably than the cloud engines.
- Alias restoration needs both a Soniox and an Alibaba Cloud key; it does not work in local-only mode.
- The app interface is Simplified Chinese only.
- The app is not notarized by Apple: the first launch needs a manual approval, and the three permissions may need granting again after an update.
- Electron apps, custom-drawn interfaces and some web editors do not expose the field's content, so Totype cannot confirm the insertion; history records it as `已发送` (Sent).
- A single recording lasts 180 seconds by default.
- The history window shows only the latest 20 entries; older ones remain in the data folder.
- Whether an app counts as chat-type comes from a fixed list of app identities, and browsers are all treated as chat-type.
- The prebuilt dmg on GitHub Releases is coming soon; until then, build from source (`VERBATIM_BUNDLE_MODEL=0` gives the lite build).
