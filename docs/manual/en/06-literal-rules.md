# 06 How much to change

[简体中文](../zh-CN/06-literal-rules.md)

How much Totype changes your words is your decision. By default the text it inserts is exactly the text the engine recognized: no trailing punctuation removed, no spaces added, nothing rewritten. Tidying happens in three places. Before recognition, the transcription prompt, glossary and speaker background steer the engine ([05 Personalization](05-personalization.md)). After recognition, alias restoration and learning from your manual edits correct words you have taught it. At insertion, two optional preferences adjust the end of the text. This chapter covers the defaults and those two preferences, which are off by default, have no switch in the interface, and are turned on by importing a profile file.

## The default: verbatim

- Sentence-final punctuation, periods included, is kept.
- No trailing space is added after English, and no joining space is inserted between two English runs.
- No language model is involved. The only processing of the engine's text is the alias restoration described in [05 Personalization](05-personalization.md), which needs a second engine to confirm.
- Return is never pressed for you. In a terminal, the inserted text carries no trailing newline, so a command is not run by itself.

## Two optional preferences

| Switch | Effect | Profile field |
|---|---|---|
| `聊天应用里去掉句末句号` | Removes the final period of a sentence in chat-type apps | `removeChatTerminalPeriod` |
| `英文结尾补空格` | Adds one space after text that ends in English, so you can keep typing | `appendTrailingSpaceAfterEnglish` |

"Chat-type apps" are decided by app identity and currently include ChatGPT, Codex, WeChat, Slack, Discord, Telegram, Feishu, Lark, and the browsers Safari, Chrome and Arc. Terminals (Terminal, iTerm2, Warp) and common editors (VS Code, Cursor, Xcode, Windsurf) do not get either preference. Other apps can only get the trailing space.

Turn them on under Settings → `个人资料` (Profile) → `插入` (Insertion): `聊天应用里去掉句末句号` (remove the final period in chat apps) and `英文结尾补空格` (add a space after English). Both are off by default, and both travel with an exported profile.

## Input method protection

When you start recording and the field still holds uncommitted input method text (for example Pinyin composition), Totype does not start. It asks you to commit the text or cancel the composition, so it does not interrupt what you are typing. Whether this can be detected depends on whether the target app exposes that information to the system.

## Differences between apps

Totype sends text through macOS Accessibility and keyboard events. Native apps and most web inputs allow it to confirm the insertion. Electron apps, custom-drawn interfaces and some web editors do not expose the field's text, so it cannot read the result back. In that case it sends the text once and records it in history as `已发送` (Sent). It never inserts again to verify, and never switches to pasting.

The insertion target is the app that had focus when you started recording. If you switch apps while recording, Totype does not push the text into the new app; it shows a preview card instead, see [03 Daily use](03-daily-use.md).
