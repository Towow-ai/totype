# Totype iPhone 版：开发者说明

iPhone 上的语音输入。主 App 录音并调用 Soniox（主）和百炼（热备）逐字转写，两把 Key 都没有时用 iPhone 本机识别；结果写进 App Group 里的 mailbox，由自定义键盘插入到当前输入框。转写结果原样交付：不润色、不总结，保留口头语和重复。

安装步骤、签名和私有 API 开关的说明面向使用者，在 `../docs/manual/zh-CN/11-iphone.md`；这里写代码结构和调试方法。

完整 Xcode 环境的日常检查用仓库根目录的 `scripts/verify-ios.sh`：共享行为自测 + 三个原生 iOS target 的无签名 Release 构建。GitHub CI 调用同一入口。工具版本、日志与签名安装的分工见 [CI/CD 维护说明](../docs/CI-CD.md)。

## 目录

| 路径 | 内容 | 编进哪个 target |
|---|---|---|
| `Shared/` | mailbox、Darwin 通知、会话状态、原子写和文件锁，纯 Foundation | 三个都有 |
| `Intents/` | `AudioRecordingIntent`（开始、停止、切换）和 Live Activity 的 attributes | 主 App、Widgets |
| `App/` | SwiftUI 主 App：录音、识别、会话协调、历史、词库、设置 | 主 App |
| `Design/` | design-v2 落地层：`Tokens.swift`（设计稿的颜色与尺寸）、字阶、列栅格、麦克风圆⇄胶囊（`MicControl`）、波形、发丝线、Live Activity 外观 | 三个都有 |
| `KeyboardUI/` | 键盘外观（语音层、字母层、状态行），只吃一个状态值，不依赖扩展；主 App 的 DEBUG 设计预览也用它 | 主 App、键盘 |
| `Keyboard/` | 键盘扩展：把 `KeyboardModel` 映射成 `KeyboardUI` 的状态；插入、会话协议；`HostIdentity.m` 认宿主（私有 API，见“自动返回原 App”） | 键盘 |
| `Widgets/` | Control（控制中心、锁屏、操作按钮）和 Live Activity（锁屏、灵动岛） | Widgets |
| `project.yml` | XcodeGen 工程描述 | — |
| `scripts/typecheck.sh` | 三个 target 的 Mac Catalyst 类型检查 | — |
| `scripts/shared-self-test.sh` | `Shared/` 的断言测试，在 macOS 上编译运行 | — |

主 App 直接编译 macOS 端的以下文件，不复制、不修改：`VerbatimVoiceCore/Sources/VerbatimCore/*.swift`，以及 `project.yml` 里 `BEGIN mac-reuse` 区块列出的 Provider、模型、存储、音频和 `AppSettings.swift`。`typecheck.sh` 从同一个区块读取文件清单，所以本地检查和 Xcode 构建用的是同一组文件。

`KeychainStore.swift` 和 `ActiveDictationSession.swift` 没有复用：前者同文件里的 `PersonalSecretStore` 用了 iOS 没有的 `homeDirectoryForCurrentUser`；后者依赖 AppKit 侧的类型。iOS 侧分别写了 `MobileKeychain` 和 `MobileTranscriptionSession`，后者的流分发、主备竞速和截止逻辑照搬 macOS（主模型偏好 750 ms，停止后 8 秒云端硬截止）。

## 关键约定

- **首个 PCM buffer 到达前不显示“录音中”。** 按钮按下后是“启动中”，主 App 界面、共享状态、Live Activity 都在第一个 buffer 到达时才切到录音。
- **每次说话最多提交一次。** `DictationSessionCoordinator.claimCommit` 控制写 mailbox，mailbox 的 `post` 对同一个 sessionID 也是幂等的。
- **mailbox 原子性。** 所有写操作都在 `flock` 排他锁内完成读改写，先写临时文件再 `rename`。键盘插入前先 claim，要求条目仍是 pending 且 revision 与预览时一致，所以同一条最多插入一次。文件损坏时把坏文件改名备份，重建空 mailbox，新 revision 从当前毫秒时间戳开始，保证仍大于之前所有 revision。
- **音频是真相源。** 每次录音写到 `Application Support/VerbatimVoice/audio/`（先 WAV，结束后转 FLAC）。识别失败时历史里保留音频，可以重新转写；新结果追加为版本，不覆盖原稿。
- **Darwin 通知不带数据。** 它只提醒对方重读文件；键盘每次出现时也会主动重读。
- **会话。** 每次录音先“布防”：激活 `playAndRecord`、启动 `AVAudioEngine` 并一直运行（后台存活靠它），不录时 PCM 进 1 秒环形缓冲，开始录音时先送最近 300 ms。最后一次听写结束后空闲 N 分钟（设置里 1/5/15/60/手动，默认 5）停引擎、释放音频会话。来电等中断：先把正在录的转写完，会话转为“暂停”（键盘改走打开 App），中断结束且带 `shouldResume`、或 App 回到前台时恢复；线路变化去抖 200 ms 后重启引擎，失败才结束会话；媒体服务复位直接结束。中断结束时，`mixWithOthers` 打开就不等 `shouldResume` 直接尝试恢复（那个标志是给播放类 App 的提示，别的 App 停止录音时常常不带它）。心跳里每秒检查引擎，布防状态下连续 3 秒没在跑就按线路变化重启，失败则结束会话。引擎每次布防新建，激活与启停都在后台串行队列上做，带 2 秒期限。`mixWithOthers` 默认打开。心跳在会话存活期间（含待命和暂停）1 Hz 写入，计时器是专用串行队列上的 `DispatchSourceTimer`，写入也在那条队列上，不 fsync，不经过主线程；电平 ~15 Hz 同样不 fsync、不在主线程写。Live Activity 只在一次听写的启动中、正在听、识别中存在，听写结束即结束；会话待命不在灵动岛和锁屏显示，剩余时间只在首页会话行里。**后台触发的听写不显示灵动岛**：键盘在会话里直接开始的听写，主 App 在后台，iOS 拒绝启动 Live Activity（`ActivityAuthorization` visibility），这时键盘本身显示录音状态；不做变通，失败只在日志里按种类记一次（`liveActivity.unavailable`，之后的同类只计数）。
- **键盘 ↔ App 协议。** 共享状态 `session-state.json`（秒级小数时间）带 `sessionActive`、心跳、会话空闲超时 `sessionIdleTimeout`、`originRequestID`、`handledRequestID/Result`、`lastError`。键盘的决策（`SharedSessionState.keyboardRoute`）：暂停或没有会话就直接打开 App；`sessionActive` 且心跳年龄不超过空闲超时（“手动结束”时上限 60 分钟）就写 `keyboard-request.json`（requestID、start/stop/cancel/retry、时间、目标 sessionID、键盘看到的心跳）并发 `.keyboardRequest`；心跳比空闲超时还旧，说明 App 已经不在，直接打开 App。心跳年龄按读文件那一刻算，不按渲染时刻算。旧做法拿缓存的心跳和渲染时的时钟比：键盘待命时不重读文件，任何一次重绘（撤销提示 5 秒后消失、打字）只要离上次读取超过 2.5 秒，就把麦克风换成直接打开 App 的 `Link`。2026-10-01 真机日志里 10 次跳 App 有 4 次是这样（`why=stale`，`hb` 3.0–8.2 秒），而 App 那边 `maxBeatGap` 一直是 1.07 秒。现在键盘可见时每秒重读一次，录音或等回答时 ~15 Hz。App 对读到的每个请求都回答 accepted/ignored/needsForeground，超过 3 秒的请求忽略。键盘 800 ms 内没收到回答或收到 needsForeground，就打开 `<scheme>://record|stop|cancel|retry?request=<id>&why=…`，App 用同一个 ID 回答，不会重复执行；超时一次后，直到看到更新的心跳之前，麦克风直接打开 App（`why=unanswered`），不再每次等 800 ms。`why`（noSession / paused / stale / timeout / unanswered / needsForeground / writeFailed）、`hb`（读文件时的心跳年龄，毫秒）、`hbAt`（键盘读到的心跳时刻）、`rd`（读文件到生成 URL 的毫秒数）、`active`、`paused` 只用于诊断日志；App 在 `url.open` 和 `keyboard.request` 里记 `hbLagMs`（App 最近一次写入比键盘读到的心跳新多少毫秒，正常在 0–1000）和 `appBeatAgeMs`。键盘在 `viewWillAppear` 里不碰 `textDocumentProxy` 和 `needsInputModeSwitchKey`（从 App 滑回来时会在 `_controllerState` 里崩溃，iOS 随即换回系统键盘），这些值在 `viewDidAppear` 之后读，并缓存上一次的值。
- **自动插入。** 键盘只在内存里记住自己发起或结束的 sessionID；对应结果出现且键盘仍可见时立即 claim 并插入，之后 5 秒内可“撤销”（按插入字数退格，仅在光标前文本与插入后完全一致时）。键盘消失或进程重建就忘掉这些 ID，结果留在“插入”按钮后面。电平以 ~15 Hz 写 `levels.json`（不 fsync），键盘只在录音时读。宿主从后台回来时（`NSExtensionHostWillEnterForeground` / `DidBecomeActive`）键盘也重读一次：宿主回前台不一定再走一遍出现回调，挂起期间的 Darwin 通知也会丢。
- **键盘里重试。** 没得到可用结果的听写也进 mailbox，状态是 `failed`（带原因）。键盘状态行显示“没插入 · 原因”和“重试”；点重试发 `retry` 请求（会话不在就打开 `<scheme>://retry?session=<id>`，App 布防会话后立刻回原 App），App 在后台用归档音频重新转写（复用历史里的重新转写路径，按实时节奏回放）。同一条 mailbox 条目原地变化：`failed → retrying → pending`（成功文本），或回到 `failed`（最新原因）；历史里同一条记录追加一个版本。重试多少次，用户都只看到一个结果。重试仍失败时多出“稍后再试”：条目转为 `deferred`，键盘不再显示；网络恢复（`NWPathMonitor` 变为 satisfied）或下一次会话开始时自动再试一次（每条每个进程最多两次，只试 24 小时内的），成功后进“插入”。成功的结果如果键盘还在同一个输入框可见，就自动插入，可撤销。整段识别接口（Soniox 异步、百炼 `qwen-audio-3.0-asr-flash`）代码里还没有，接入后可以把回放换成一次上传。

## 设计预览（仅 DEBUG）

`-designPreview <画面>` 用固定数据渲染一个 design-v2 画面，`-designTheme dark` 切深色。画面名见 `App/DesignPreview.swift`（`kb-idle`、`kb-listening`、`app-home`、`app-detail`、`island`、`lockscreen` 等）。对照截图用 393×852 的模拟器（iPhone 16 机型、iOS 27）截，与设计稿同尺寸。

## 不装 Xcode 时的验证

```bash
cd VerbatimVoiceMobile
bash scripts/shared-self-test.sh   # mailbox / 会话状态 / Darwin 通知断言，约 45 秒
bash scripts/typecheck.sh          # 主 App、键盘、Widgets 三组 Catalyst 类型检查
```

Catalyst 检查有三处盲区：

1. ActivityKit 在 Catalyst 下不可用。`Intents/RecordingActivityAttributes.swift`、`Widgets/RecordingLiveActivity.swift` 和 `App/LiveActivityController.swift` 的 ActivityKit 分支用 `#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)` 包着，检查时被跳过，**要等 iOS SDK 构建才算验证**。
2. Catalyst 暴露了一些 iOS 没有的 macOS Foundation API；复用文件已人工检查过（没有 `Process`、`NSSound`、`homeDirectoryForCurrentUser` 等）。
3. 主 App 组额外隐式导入了 CoreAudio：iOS 和 macOS 上 `import AVFoundation` 会带进 `UnsafeMutableAudioBufferListPointer`（复用的 `PCMConverter.swift` 用到），Catalyst 不会。

## 装好 Xcode 之后

### 1. 一次性准备

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
brew install xcodegen
```

在 Xcode → Settings → Accounts 里登录 Apple ID（命令行自动签名依赖这个已登录账号）。iPhone 用线连 Mac，点“信任此电脑”，在 设置 → 隐私与安全性 → 开发者模式 里打开开发者模式。

复制本地配置，填团队 ID 和自己的 Bundle ID、App Group（`Config/Shared.xcconfig` 里有每一项的说明；`Local.xcconfig` 已被 git 忽略）：

```bash
cp VerbatimVoiceMobile/Config/Local.xcconfig.example VerbatimVoiceMobile/Config/Local.xcconfig
```

| 变量 | 公开默认值 | 作用 |
|---|---|---|
| `DEVELOPMENT_TEAM` | 无 | 签名团队 |
| `TOTYPE_BUNDLE_ID` | `ai.towow.totype` | 主 App；键盘 `.keyboard`、Widgets `.widgets`；钥匙串共享组 `.shared`；钥匙串 service 名、Darwin 通知、控制中心控件 kind 都以它为前缀 |
| `TOTYPE_APP_GROUP` | `group.ai.towow.totype` | 三个 target 共享的 App Group |
| `TOTYPE_URL_SCHEME` | `totype` | 键盘打开主 App 的 URL scheme |
| `TOTYPE_DISPLAY_NAME` | `Totype` | 主屏幕、键盘列表和界面文字里的名字 |
| `TOTYPE_PRIVATE_HOST_RETURN` | `NO` | 是否编译“自动返回原 App”的两处私有 API |

这些值由 `project.yml` 写进三个 target 的 Info.plist（`TotypeAppBundleID`、`TotypeAppGroup`、`TotypeURLScheme`），运行时由 `Shared/MobileIdentity.swift` 读取。装好以后不要再改 Bundle ID 和 App Group：改了就是另一个 App，旧的历史、键盘授权和钥匙串里的 Key 都对不上。

### 2. 生成工程并构建

```bash
cd VerbatimVoiceMobile
scripts/prepare-seed.sh      # 默认什么都不复制；设了 VERBATIM_LEXICON_SEED / VERBATIM_PROFILE_SEED 才把词库、个人资料放进安装包
xcodegen                     # 生成 VerbatimVoiceMobile.xcodeproj、Info.plist 和 entitlements
xcodebuild -project VerbatimVoiceMobile.xcodeproj -scheme VerbatimVoiceMobile \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath build/DD \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

第一次在免费账号下创建 App ID 或 App Group 偶尔会在命令行失败。遇到时用 Xcode 打开工程，在三个 target 的 Signing & Capabilities 页各点一次，之后命令行就能复用。

### 3. 安装到 iPhone

```bash
xcrun devicectl list devices                       # 记下设备的 Identifier
DEVICE=<设备 Identifier>
xcrun devicectl device install app --device "$DEVICE" \
  build/DD/Build/Products/Debug-iphoneos/VerbatimVoiceMobile.app
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"   # Local.xcconfig 里的 TOTYPE_BUNDLE_ID
```

免费账号首次运行还要在 设置 → 通用 → VPN 与设备管理 里信任开发者证书。

### 4. 手机上的首次设置

1. 打开 App → 设置，粘贴 Soniox Key 和百炼 Key，各点一次“连接测试”。不填 Key 就用本机识别，第一次录音时允许语音识别。
2. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 选这个 App 的键盘，再点进去打开“允许完全访问”。
3. 控制中心编辑 → 添加控制 → 搜索 App 名，加入“<App 名> 录音”。

日常用法：在输入框切到 Verbatim 键盘点麦克风。第一次（或会话已结束）会跳到主 App 并立即开始录音，打开 `TOTYPE_PRIVATE_HOST_RETURN` 的构建在录音真正开始后自动回到原 App（见下一节）；没打开这个开关、认不出原 App 或返回失败时停在引导页，提示点状态栏左上角的“◀ 原 App 名”或沿底部横条右滑回去（iOS 26.4 起系统不再自动返回，也没有公开 API）；回去后继续说，点一下键盘中间的波形结束（左边 ✕ 是取消），文字自动插入，5 秒内可撤销。会话期间（主页会话行可见剩余时间）再点麦克风不再跳转。

## 自动返回原 App

从键盘跳到主 App 录音后，主 App 在收到第一个 PCM buffer 之后回到用户原来所在的 App，用户接着说，再点键盘中间的胶囊结束。这一步用了两处私有 API，只适合个人签名自用，不能上架。它们只在 `TOTYPE_PRIVATE_HOST_RETURN = YES` 时编译：开关关闭时两段代码都不进二进制，键盘不报宿主，设置里也没有这个开关。下面的行为是 2026-10-01 在 iPhone 14 Pro、iOS 26.6 beta 上真机测出来的。

**键盘认宿主**（`Keyboard/HostIdentity.m`）。扩展加载时用 C 构造函数把 `+[_UIKeyboardArbiterClient enabled]` 换成返回 YES，键盘进程里的仲裁器客户端就会带上 `currentClientState`。键盘出现后（`viewDidAppear` 之后一轮主队列，不在 `viewWillAppear` 里，也不碰 `textDocumentProxy`）在 0、150、400 ms 各查一次，找到就停：把仲裁器状态里的 (pid → bundle ID) 记进进程内的表，再用控制器的 `_hostProcessIdentifier` 查表。仲裁器的“当前来源”不直接用，真机上它会停在上一个 App。查到的宿主写进麦克风 `Link` 的 URL：`<scheme>://record?…&host=<bundle ID>&hostPid=<pid>&hsrc=pidMap&htry=<第几次查到>&swz=<替换结果>`；查不到时带 `hostPid` 和 `hmiss=<查了几次>`，不带 `host`。`Link` 的地址在渲染时就定了，所以重试只能放在点击之前；800 ms 超时后程序化打开 App 的那条路径在拼 URL 前再查一次。宿主是本 App 自己、SpringBoard 或 Spotlight 时不返回。

**主 App 返回**（`App/HostReturn.swift`）。只用键盘给的宿主；主 App 自己能看到的 `_UIRemoteKeyboards` 状态在真机上给出过期的宿主（人在备忘录里，它仍是微信），不作来源。返回条件：设置里的开关打开，URL 带了宿主，第一个 buffer 已到（说明音频会话已激活、引擎在出数据）后再等 100 ms，App 处于前台。原先还要求距 URL 到达至少 1 秒；2026-10-01 的日志里第一个 buffer 在 URL 后 0.5–0.7 秒就到了，那 1 秒下限只是在空等，已去掉。离开前台会不会让录音断掉，由每次返回后的 `autoReturn.postReturnAudio` 检查：从发起返回到进入后台后 2 秒内，PCM buffer 是否连续（最大间隔 ≤400 ms 记 `ok`，否则 `gap`），带 `buffers`、`maxGapMs`。手段依次是：

1. `[[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:]`，运行时解析并检查签名。真机上微信和备忘录都直接回到原界面，没有弹窗，调用约 35 ms，约 0.8–0.9 秒后主 App 进入后台。
2. 上一步不存在或返回 NO 时，查 bundle ID → URL scheme 表，表里只放验证过的：`com.tencent.xin` → `weixin://`（第一次会弹“想要打开微信”）。
3. 都不行，或没有宿主：留在返回引导页，行为与没有这个功能时一样。

`suspendReturningToLastApp:` 在真机上回到主屏幕，没有采用。

**风险与降级。**

- 两处都是私有 API，iOS 升级可能让它们失效。每一步都判空、检查方法签名并捕获异常，失效时的表现是“认不出宿主”或“返回调用不可用”，退回引导页；录音本身不依赖返回是否成功。
- 唯一可能伤到键盘的是加载时的替换。如果 Apple 改了仲裁器，最坏情况是键盘出不来（其他开源键盘遇到过），这时把 `TOTYPE_PRIVATE_HOST_RETURN` 改回 `NO` 重新构建，其余代码会把宿主当作未知。
- pid → bundle ID 表只在键盘进程内存里，进程重建就清空。备忘录第一次测试就是这种情况：宿主 pid 一直查不到，没有返回，停在引导页。
- iOS 的 pid 在很长时间后才会复用，表里理论上可能留着一个被复用的旧 pid；遇到时会回到错误的 App，日志里能看到 `host` 与实际不符。
- 设置 → 会话与录音 → “录音开始后自动返回原 App” 可以关掉整个功能（默认开）。

**诊断日志里的事件。** `url.open` 带上键盘给的 `kb.host / kb.hostPid / kb.hsrc / kb.htry / kb.hmiss / kb.swz`；`autoReturn.skip`（`disabled`、`noHost`、`unsupportedHost`、`invalidHost`、`notActive`、`dictationEnded`）；`autoReturn.plan`（宿主、来源、第几次查到、`msSinceUrl`、`msSinceFirstBuffer`）；`autoReturn.attempt`（`method=workspace returned=0/1 ms=…`，或 `unavailable=…`，或 `method=scheme ok=…`）；`autoReturn.result`（`leftForeground=1 msToBackground=…`，或 3 秒内没进后台时 `leftForeground=0 guide=shown`）；`autoReturn.postReturnAudio`（`ok`/`gap`、`buffers`、`maxGapMs`、`msAttemptToBackground`）。

## 无 Key：本机识别

钥匙串里两把 Key 都没有时，`DictationController` 把 `OnDeviceSpeechProvider`（`App/OnDeviceSpeechProvider.swift`，ID `apple-on-device`）当作主引擎，没有热备，也不参与余额探测。键盘发起的重试和历史里的重新转写同样在没有 Key 时用它。它和云端引擎实现同一个 `ASRProvider` 接口，所以录音、归档、mailbox、“最多插入一次”这些路径都不变。

每次听写开始时选一个引擎：

1. iOS 26 及以上，且 `SpeechTranscriber` 的简体中文模型已经装好：用 `SpeechAnalyzer`。App 启动时如果没有 Key，会在前台触发模型下载（`OnDeviceSpeech.prepareAnalyzerModel()`）；没装好之前走第 2 条。
2. 否则用 `SFSpeechRecognizer`，设 `requiresOnDeviceRecognition`，个人词库的前 100 个词作为 `contextualStrings`。它需要语音识别权限，也需要手机支持离线中文；不满足时开始录音就报错，提示去设置里填 Key。

语音识别权限只在前台申请：第一次没有 Key 的录音会和麦克风权限一起弹出，设置页的“本机识别”一行也可以点。准确率明显不如云端，人名、术语、中英混说尤其明显，设置页和引导页都写明了。

## 诊断日志

主 App 把会话事件追加到 App Group 容器的 `Library/diagnostics/session-log.txt`（`devicectl` 只能从容器的 Library、Documents、tmp 拷文件），保留最近约 1 MB，不写转写文本。记录：App 启动与前后台、内存警告、会话开始/暂停/恢复/结束、引擎启停与失败、AVAudioSession 激活/停用与错误（含四字符 OSStatus）、中断开始/结束、线路变化（只记端口类型）、键盘请求与回答、键盘改走打开 App 的原因、自动返回原 App 的宿主来源与结果、听写开始/结束/结果（只记字数）、Live Activity 开始/结束/失败、心跳写入失败；会话期间每 30 秒一行 `session.alive`（前后台、`backgroundTimeRemaining`、引擎是否在跑、30 秒内最大心跳间隔、剩余时间、线路、内存占用）。

```bash
xcrun devicectl device copy from --device "$DEVICE" --domain-type appGroupDataContainer \
  --domain-identifier "$APP_GROUP" \
  --source Library/diagnostics/session-log.txt --destination session-log.txt
```

键盘自己的事件在同一目录的 `keyboard-log.txt`（需要“允许完全访问”才写得进，约 256 KB）：键盘实例出现/消失、宿主前后台、键盘看到的阶段变化及其来源（出现回调、Darwin 通知、轮询、每秒重读）、请求/回答/改走 URL 的原因与当时的心跳年龄，以及每次听写的波形读取统计（`kb.levels`：读了几次、几次有数据、几次文件缺失或属于别的听写、第一次有数据的时刻）。拉取命令把 `--source` 换成 `Library/diagnostics/keyboard-log.txt`。

DEBUG 构建可以不录音直接开一个会话：`xcrun devicectl device process launch --device "$DEVICE" --terminate-existing -- "$BUNDLE_ID" -armSessionOnLaunch YES`，再启动别的 App（如 `com.apple.mobilenotes`）把它推到后台，看日志里的 `session.alive` 是否持续。

## 还没验证的部分

| 项 | 为什么没验证 | 什么时候验 |
|---|---|---|
| Live Activity、灵动岛、锁屏 UI 的运行效果 | 原生 CI 编译 ActivityKit 分支，Catalyst 不覆盖；构建不证明运行效果 | 真机 UI 和录音测试 |
| `AudioRecordingIntent` 从控制中心冷启动或后台启动能否录音 | 行为取决于系统，公开资料互相矛盾 | 真机测试 |
| 键盘里 `Link` 打开主 App | 依赖“允许完全访问”和 iOS 版本 | 真机测试 |
| 会话：后台引擎存活时长、Darwin 唤醒延迟、800 ms 后程序化打开 URL 是否被允许、耗电 | 只能真机测 | 第一次真机安装 |
| 免费账号能否签下“键盘 + Widgets + App Group + 钥匙串共享” | 需要真实签名 | 第一次真机安装 |
| 本机识别在 App 退到后台录音时能否持续出字 | 只能真机测 | 第一次无 Key 真机安装 |
