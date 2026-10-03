# 02 First run and permissions

[简体中文](../zh-CN/02-first-run.md)

Totype needs three system permissions: Microphone to record, Accessibility to insert text into the focused field, and Input Monitoring to listen for Right Option and Esc. Once all three are granted, a tap on Right Option starts dictation. After granting Input Monitoring the app usually has to be quit and reopened before it takes effect.

## First-run guide

On the first launch Totype opens a window titled `开始之前` (Before you start) with five steps: Microphone, Accessibility, Input Monitoring, Local model, and a test sentence. Each step shows a check mark once it is done, and the next step that needs you has the filled button. Input Monitoring may show `立即重启` (Restart now), because the hotkey only works after a restart. The local model step has a `下载` (Download) button; if you have already saved a cloud key, it says the local model can be installed later. In the last step, click the box, tap Right Option, speak, and tap again. When everything is done the button reads `完成` (Done); otherwise `稍后再说` (Later) closes the window.

![First-run guide](../../images/onboarding.png)

The window does not open if all three permissions are already granted and a local model or cloud key is available. You can reopen it any time: menu bar icon → `⋯` → `打开入门引导…` (Open the first-run guide…). If you skip it, do the same things by hand as described below.

## Granting permissions by hand

The app lives only in the menu bar and has no Dock icon. After launch, look for its icon at the top of the screen.

1. **Microphone.** The first time you start recording, macOS asks for permission. Click Allow. If you clicked Don't Allow, go to System Settings → Privacy & Security → Microphone and switch Totype on.
2. **Accessibility.** Click the menu bar icon to open the menu panel, click `⋯` at the bottom right, and choose `检查辅助功能` (Check Accessibility). macOS takes you toward System Settings → Privacy & Security → Accessibility. Switch Totype on; if it is not in the list, click "+" and add `/Applications/Totype.app`. When the `插入` (Insertion) column of the menu panel reads `辅助功能 · 可用` (Accessibility · available), it worked.
3. **Input Monitoring.** In the same `⋯` menu choose `检查输入监控` (Check Input Monitoring), then switch Totype on under System Settings → Privacy & Security → Input Monitoring. Quit the app and open it again.
4. **Say a test sentence.** Click into any text field, tap Right Option, say a sentence, and tap Right Option again. If the text appears at the cursor and the overlay shows `已插入 N 字` (Inserted N characters), the whole chain works.

## When a grant stops working

If Input Monitoring is not in effect, Right Option does nothing, or the overlay shows `Esc 不可用` (Esc unavailable) while recording. The menu panel then shows `Esc 取消不可用：需要重新授权输入监控` with an `打开设置` (Open Settings) button. Delete Totype from the Input Monitoring list, add it again, and restart the app.

With a non-notarized build this can happen after every update, because macOS binds the grant to the build's code signature. Check all three lists: delete the old entry, grant again, restart. If you build from source, a stable local signing identity avoids the repeated grants; see [01 Install](01-install.md).
