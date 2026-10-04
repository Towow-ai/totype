# 11 iPhone 版（预览）

[English](../en/11-iphone.md)

Totype 的 iPhone 版由三部分组成：主 App 负责录音和识别，自定义键盘把结果插入任何输入框，灵动岛、锁屏和控制中心显示录音状态并提供开始、结束按钮。它目前只能从源码安装：用你自己的 Apple ID 签名，装到你自己的手机上。本章说明需要准备什么、怎么构建安装、日常怎么用，以及“自动返回原 App”这个可选功能的代价。

## 需要准备什么

- 一台装了完整 Xcode 的 Mac。只有命令行工具不够，构建 iPhone 应用需要 Xcode 自带的 iOS SDK；本地识别用到的 `SpeechAnalyzer` 需要 Xcode 26 或更高。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`。仓库里不放 Xcode 工程文件，工程由 `VerbatimVoiceMobile/project.yml` 生成。
- 你自己的 Apple ID，在 Xcode → Settings → Accounts 里登录。免费账号就能用。
- iOS 18 或更高的 iPhone，用数据线连到 Mac。第一次连接时在手机上点“信任此电脑”，再到 设置 → 隐私与安全性 → 开发者模式 里打开开发者模式。

### 免费账号的限制

免费 Apple ID 会得到一个 Personal Team。用它签名的应用 **7 天后失效**，失效后图标还在，但打不开。到期后连上 Mac 重新运行一次安装命令即可，Bundle ID 和 App Group 不变，历史、词库和已保存的 Key 都会保留。付费开发者账号签名的有效期是一年。

免费账号每周能注册的 App ID 数量也有限。主 App、键盘和小组件各占一个，所以先想好前缀再构建，不要反复改。

## 构建与安装

1. 复制本地配置文件。它已被 git 忽略，只存在你的电脑上。

   ```bash
   cd VerbatimVoiceMobile
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

2. 编辑 `Config/Local.xcconfig`，至少填三项：

   ```text
   DEVELOPMENT_TEAM = ABCDE12345
   TOTYPE_BUNDLE_ID = com.yourname.totype
   TOTYPE_APP_GROUP = group.com.yourname.totype
   ```

   Team ID 在 Xcode → Settings → Accounts 里选中你的账号、点团队后能看到，也可以在 Keychain Access 里看开发证书的“组织单位”。Bundle ID 和 App Group 在所有 Apple 开发者账号之间全局唯一，公开默认值 `ai.towow.totype` 已经属于别人，必须换成你自己的。键盘的 Bundle ID 是 `<TOTYPE_BUNDLE_ID>.keyboard`，小组件是 `<TOTYPE_BUNDLE_ID>.widgets`，钥匙串共享组是 `<TOTYPE_BUNDLE_ID>.shared`，都会自动推出来。

3. 生成工程、构建并安装到连着的 iPhone：

   ```bash
   scripts/install-device.sh
   ```

   这个脚本依次运行 `xcodegen` 和 `xcodebuild`，再用 `devicectl` 安装。也可以只运行 `xcodegen`，然后用 Xcode 打开 `VerbatimVoiceMobile.xcodeproj`，选中手机后点运行。第一次用免费账号注册 App ID 或 App Group 时，命令行偶尔会失败；遇到时用 Xcode 打开工程，在三个 target 的 Signing & Capabilities 页各点一次，之后命令行就能复用。

4. 第一次打开 App 前，到 设置 → 通用 → VPN 与设备管理 里信任你的开发者证书。

所有配置项都在 `Config/Shared.xcconfig` 里，带说明：

| 变量 | 公开默认值 | 作用 |
|---|---|---|
| `DEVELOPMENT_TEAM` | 无 | 签名用的 Team ID |
| `TOTYPE_BUNDLE_ID` | `ai.towow.totype` | 主 App 的 Bundle ID，其他标识都从它推出 |
| `TOTYPE_APP_GROUP` | `group.ai.towow.totype` | 主 App、键盘和小组件共享的 App Group |
| `TOTYPE_URL_SCHEME` | `totype` | 键盘打开主 App 用的 URL scheme |
| `TOTYPE_DISPLAY_NAME` | `Totype` | 主屏幕、键盘列表和界面里显示的名字 |
| `TOTYPE_PRIVATE_HOST_RETURN` | `NO` | 自动返回原 App，见本章最后一节 |

装好以后不要再改 `TOTYPE_BUNDLE_ID` 和 `TOTYPE_APP_GROUP`。改了之后手机会把它当成另一个 App：旧 App 的历史、键盘授权和钥匙串里的 Key 都不会带过来。

## 添加键盘

1. 打开 设置 → 通用 → 键盘 → 键盘 → 添加新键盘，选 Totype（或你设置的名字）。
2. 点进刚添加的键盘，打开“允许完全访问”。

键盘需要完全访问，才能和主 App 通过 App Group 交换文字和开始、结束指令。键盘本身不联网，也不录音；录音和识别都在主 App 里完成。

## 识别引擎

主 App 的设置页可以填 Soniox Key 和阿里云百炼 Key，和 Mac 版一样：Soniox 是主引擎，百炼是热备，Key 只存在本机钥匙串里。两个云端引擎的说明见 [04 引擎与 API Key](04-engines-and-keys.md)。

两把 Key 都不填，App 就用 iPhone 自带的语音识别在本机转写，音频不离开手机，也不花钱。它的准确率明显不如云端，人名、专业术语和中英混说时尤其明显。具体用哪个系统引擎由手机决定：

- iOS 26 及以上用 `SpeechAnalyzer`。它的中文模型需要下载一次，App 在没有 Key 时打开就会开始下载；下载完成前先用下一种。
- 其他情况用 `SFSpeechRecognizer` 的离线模式。它需要“语音识别”权限，第一次录音时系统会询问，也可以在 App 设置页点“本机识别”一行。不支持离线中文识别的手机上无法使用，这时只能填云端 Key。

Mac 版的本地引擎 SenseVoice 不能在 iPhone 上运行。本机识别在 App 退到后台、你回到原 App 继续说话时的表现还在验证；如果某次没出字，录音已经保存在历史里，回到 App 可以重新转写。

## 日常使用

在任意输入框里切到 Totype 键盘，点麦克风：

1. 第一次（或者会话已经结束）时，键盘会打开主 App 并立即开始录音。iOS 不允许键盘扩展自己录音，所以这一跳绕不开。
2. 录音开始后，点状态栏左上角的“◀ 原 App 名”回到刚才的 App，或者沿屏幕底部横条向右滑。
3. 接着说，说完点一下键盘中间的波形。文字直接插入输入框，5 秒内可以撤销；左边的 ✕ 是取消，音频仍留在历史里。

之后的一段时间里（设置里的“会话空闲后结束”，默认 5 分钟），麦克风在后台待命，再点键盘上的麦克风不用跳转。代价是系统的麦克风指示点一直亮着，也更耗电。控制中心可以添加“Totype 录音”控件，灵动岛和锁屏会显示录音状态。

## 自动返回原 App（私有 API，默认关闭）

打开 `TOTYPE_PRIVATE_HOST_RETURN = YES` 后，上面第 2 步可以省掉：录音真正开始后，主 App 自动回到你刚才所在的 App。它用到两处私有 API：

- 键盘在加载时替换系统键盘仲裁器的一个方法（`Keyboard/HostIdentity.m`），用来认出当前输入框属于哪个 App。
- 主 App 用 `LSApplicationWorkspace` 打开这个 App（`App/HostReturn.swift`）。打不开时，对验证过的 App（目前是微信）改用它的 URL scheme。

默认关闭时，这两段代码完全不编译进安装包，设置页里也没有这个开关，录音后停在提示你点左上角返回的页面。打开前请了解代价：

- **iOS 升级后可能失效。** 每一步都做了检查，失效时退回提示页，录音不受影响。最坏的情况是 Apple 改了键盘仲裁器，键盘加载不出来；这时把开关改回 `NO` 重新安装。
- **无法上架。** 带私有 API 的构建通不过 App Store 和 TestFlight 审核，只能以“源码加你自己的签名”的方式安装到你自己的设备上。
- 认不出原 App、原 App 是主屏幕或 Spotlight、或者你在设置里关掉了“录音开始后自动返回原 App”时，行为和关闭时一样。

## 已知限制

- 免费账号的签名 7 天过期，需要重新安装。
- 键盘每次从主 App 回来都需要你切回原 App（打开自动返回时除外）。
- 本机识别比云端差，且依赖 iOS 版本和手机型号；它在后台长时间录音时的表现还没有经过充分的真机验证。
- iPhone 版处于预览阶段，界面和设置可能还会变。
