# 11 iPhone (preview)

[简体中文](../zh-CN/11-iphone.md)

The iPhone version of Totype has three parts: the main app records and transcribes, a custom keyboard inserts the result into any text field, and the Dynamic Island, Lock Screen and Control Center show the recording state with start and stop buttons. For now it installs only from source: you sign it with your own Apple ID and put it on your own phone. This chapter covers what you need, how to build and install, daily use, and the cost of the optional "return to the previous app" feature.

## What you need

- A Mac with the full Xcode. Command Line Tools are not enough, because building an iPhone app needs the iOS SDK that ships with Xcode; the on-device engine uses `SpeechAnalyzer`, which needs Xcode 26 or later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`. The repository holds no Xcode project; it is generated from `VerbatimVoiceMobile/project.yml`.
- Your own Apple ID, signed in under Xcode → Settings → Accounts. A free account works.
- An iPhone with iOS 18 or later, connected to the Mac with a cable. On first connection tap Trust on the phone, then turn on Settings → Privacy & Security → Developer Mode.

### Limits of a free account

A free Apple ID comes with a Personal Team. Apps signed by it **stop working after 7 days**: the icon stays, but the app no longer opens. When that happens, connect the phone and run the install command again. The bundle ID and App Group stay the same, so history, glossary and saved keys are kept. A paid developer account signs for a year.

A free account can also register only a few App IDs per week. The app, the keyboard and the widgets take one each, so settle on a prefix before you build.

## Build and install

1. Copy the local configuration. Git ignores it; it stays on your machine.

   ```bash
   cd VerbatimVoiceMobile
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

2. Edit `Config/Local.xcconfig` and set at least these three values:

   ```text
   DEVELOPMENT_TEAM = ABCDE12345
   TOTYPE_BUNDLE_ID = com.yourname.totype
   TOTYPE_APP_GROUP = group.com.yourname.totype
   ```

   Your Team ID appears in Xcode → Settings → Accounts when you select your account and its team; it is also the Organizational Unit of your development certificate in Keychain Access. Bundle IDs and App Groups are unique across all Apple developer accounts, and the public default `ai.towow.totype` belongs to someone else, so you must use your own. The keyboard becomes `<TOTYPE_BUNDLE_ID>.keyboard`, the widgets `<TOTYPE_BUNDLE_ID>.widgets` and the shared keychain group `<TOTYPE_BUNDLE_ID>.shared`.

3. Generate the project, build, and install on the connected iPhone:

   ```bash
   scripts/install-device.sh
   ```

   The script runs `xcodegen` and `xcodebuild`, then installs with `devicectl`. You can also run only `xcodegen`, open `VerbatimVoiceMobile.xcodeproj` in Xcode, pick your phone and press Run. The first registration of an App ID or App Group on a free account sometimes fails from the command line; if it does, open the project in Xcode and visit the Signing & Capabilities tab of each of the three targets once. The command line works after that.

4. Before the first launch, trust your developer certificate under Settings → General → VPN & Device Management.

Every setting is documented in `Config/Shared.xcconfig`:

| Variable | Public default | Purpose |
|---|---|---|
| `DEVELOPMENT_TEAM` | none | Team ID used for signing |
| `TOTYPE_BUNDLE_ID` | `ai.towow.totype` | Bundle ID of the main app; the other identifiers derive from it |
| `TOTYPE_APP_GROUP` | `group.ai.towow.totype` | App Group shared by the app, keyboard and widgets |
| `TOTYPE_URL_SCHEME` | `totype` | URL scheme the keyboard opens the app with |
| `TOTYPE_DISPLAY_NAME` | `Totype` | Name on the home screen, in the keyboard list and in the app |
| `TOTYPE_PRIVATE_HOST_RETURN` | `NO` | Return to the previous app; see the last section |

Do not change `TOTYPE_BUNDLE_ID` or `TOTYPE_APP_GROUP` after installing. The phone would treat the result as a different app, and the old app's history, keyboard permission and keychain keys would not carry over.

## Add the keyboard

1. Open Settings → General → Keyboard → Keyboards → Add New Keyboard and choose Totype (or the name you set).
2. Tap the keyboard you just added and turn on Allow Full Access.

Full Access lets the keyboard exchange text and start/stop requests with the main app through the App Group. The keyboard itself never uses the network and never records; recording and recognition happen in the main app.

## Recognition engines

The app's settings take a Soniox key and an Alibaba Cloud Bailian key, as on the Mac: Soniox is the primary engine, Bailian the hot standby, and keys stay in the phone's keychain. The cloud engines are described in [04 Engines and API keys](04-engines-and-keys.md).

With neither key saved, the app transcribes with the iPhone's own speech recognition. Audio stays on the phone and nothing is billed. Accuracy is clearly lower than the cloud engines, most of all for names, technical terms and mixed Chinese and English. The phone decides which system engine runs:

- On iOS 26 and later, `SpeechAnalyzer`. Its Chinese model is downloaded once; the app starts the download when it opens without a key, and uses the next engine until the model is installed.
- Otherwise, `SFSpeechRecognizer` in offline mode. It needs the Speech Recognition permission, which the system asks for on the first recording; you can also tap the 本机识别 (on-device recognition) row in the app's settings. Phones without offline Chinese recognition cannot use it and need a cloud key.

The Mac's local engine, SenseVoice, does not run on the iPhone. How on-device recognition behaves while the app is in the background and you keep talking in another app is still being tested. If a dictation produces no text, its audio is already in the history, and you can transcribe it again from the app.

## Daily use

In any text field, switch to the Totype keyboard and tap the microphone:

1. The first time, or after the session has ended, the keyboard opens the main app and recording starts at once. iOS does not let a keyboard extension record, so this jump cannot be avoided.
2. Once recording runs, tap "◀ <previous app>" at the top left of the status bar, or swipe right along the bar at the bottom of the screen, to go back.
3. Keep talking, then tap the waveform in the middle of the keyboard. The text goes straight into the field and can be undone for 5 seconds; the ✕ on the left cancels, and the audio stays in the history.

For a while afterwards (Settings → 会话空闲后结束, "end session after idle", 5 minutes by default) the microphone waits in the background, and tapping the keyboard's microphone no longer jumps to the app. The cost is the system's microphone indicator staying on, and more battery use. Control Center can hold a "Totype 录音" (Totype recording) control, and the Dynamic Island and Lock Screen show the recording state.

## Return to the previous app (private API, off by default)

With `TOTYPE_PRIVATE_HOST_RETURN = YES`, step 2 above goes away: once recording runs, the app switches back to the app you came from. This uses two private APIs:

- At load time the keyboard replaces one method of the system keyboard arbiter (`Keyboard/HostIdentity.m`), so it can tell which app the text field belongs to.
- The main app opens that app with `LSApplicationWorkspace` (`App/HostReturn.swift`). If that fails, it uses the URL scheme of apps that were verified to work (WeChat for now).

When the switch is off, neither piece of code is compiled into the app, settings have no auto-return switch, and after recording starts the app shows the page that points you to the top-left link. Before you turn it on, know the cost:

- **An iOS update can break it.** Every step is checked, and a failure falls back to the guide page without affecting the recording. The worst case is an Apple change to the keyboard arbiter that stops the keyboard from loading; set the switch back to `NO` and reinstall.
- **It cannot be distributed through Apple.** A build with private APIs does not pass App Store or TestFlight review. It can only be installed from source, signed by you, on your own devices.
- When the previous app is unknown, is the home screen or Spotlight, or you turned off 录音开始后自动返回原 App (return to the previous app after recording starts) in settings, the app behaves as if the switch were off.

## Known limits

- Free-account signatures expire after 7 days and need a reinstall.
- After the keyboard opens the app, you switch back by hand unless auto-return is on.
- On-device recognition is less accurate than the cloud and depends on the iOS version and phone model; long background recordings with it have not been fully tested on devices.
- The iPhone version is a preview; its screens and settings may still change.
