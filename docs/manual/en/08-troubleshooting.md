# 08 Troubleshooting

[简体中文](../zh-CN/08-troubleshooting.md)

Most problems come from one of three places: a permission that is not in effect, a cloud key or balance problem, or a target app that will not accept insertion. Check the menu panel first; it states the current problem and the next step.

## The menu bar icon is not visible

Limited menu bar space, macOS menu bar display settings or a menu bar management tool may hide the icon; this does not necessarily mean Totype has quit. Check these settings, but a missing icon alone does not establish the cause.

If Totype is already running, double-click it in Finder or find and open it through Spotlight to show the Settings window. A minimized window is restored. This alternative entry point does not guarantee that the menu bar icon stays visible. Initial launch and launch at login follow their existing behavior.

## Right Option does nothing

1. Does the top of the menu panel say `Esc 取消不可用：需要重新授权输入监控`? Then the Input Monitoring grant has gone stale. Follow [02 First run and permissions](02-first-run.md): delete the old entry, grant again, restart the app.
2. Does the status say Secure Input is on (`Secure Input 正在开启`)? Password fields and some apps make macOS hold keyboard events exclusively. Leave the password field or close the app that holds it.
3. Is the app running? Open Totype through Finder or Spotlight; a missing menu bar icon does not necessarily mean the app has quit.
4. Is Right Option taken by other software, such as a key remapper or another voice input tool?

## Esc does not cancel

Usually the Input Monitoring grant is missing. The overlay and menu panel show `Esc 不可用`. Grant it again and restart the app.

## No text inserted, only a preview card

The preview card means Totype cannot confirm where the text should go; see [03 Daily use](03-daily-use.md). Click `插入当前输入框` or `复制`. If it happens all the time, check that the `插入` column of the menu panel reads `辅助功能 · 可用`; if not, grant Accessibility again.

## Grants lost after an update

The code signature of a non-notarized build changes with each update, and the three grants may become invalid. Delete the old Totype entries from Microphone, Accessibility and Input Monitoring, grant them again, and restart. Source builds with a stable local signing identity avoid this.

## Cloud messages

| Message | Meaning and fix |
|---|---|
| `已选择 Soniox，但未配置 API Key；不会切换到系统听写` | Soniox is the primary engine but no key is saved. Save a key in settings, or switch to local |
| `Soniox 余额不足，已改用阿里云` | The Soniox balance is too low; the standby handled this recording. Click `去充值` in the menu panel, then `重试` after topping up |
| A message with a `检查 Key` button | The provider rejected the key. Check the key and that the region matches, then save it again |
| `云端较慢，已改用本地` / `云端不可用，已改用本地` | The cloud did not answer in time; the saved audio was transcribed locally |
| `主云不可用，已采用热备结果` | The primary engine failed; the other cloud's result was used |
| `没有得到可用的转写结果` | No available engine returned text; error details follow the message. The audio is still in history and can be transcribed again later |

For Alibaba Cloud connection problems, click `测试阿里云连接` in settings first. It shows `连接成功：<region>` (connected) or the concrete failure. A wrong region is a common cause.

## Local model problems

`本地 SenseVoice 模型不完整` (the local SenseVoice model is incomplete) means model files are missing or damaged. Source builds: run `scripts/install.sh` again. Lite builds: open `设置` → `识别` and use the `下载` or `重试` button on the `本地模型` (Local model) row; the app also shows this path when the local engine is selected but the model is missing. `未配置` after `主引擎` in the menu panel has the same cause.

## Results are not good enough

- A cloud engine with your glossary and speaker background usually helps; see [05 Personalization](05-personalization.md).
- The local engine returns text only after you stop, has no live captions, and handles mixed-in English terms less reliably than the cloud engines.
- In history, use `重新转写` to compare with another engine.

## Collecting diagnostics

When you report a problem, include: macOS version, chip, app version, engine, the state of the three permissions, and the primary engine, hot standby, insertion method and timeline rows from `详情` of the affected recording. You do not need to paste the transcript, and never paste an API key. For more detail, `tools/history_report.py` in the repository can summarize `history.jsonl`; read the output before you share it.
