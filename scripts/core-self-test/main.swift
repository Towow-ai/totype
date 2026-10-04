import Foundation

private var failures: [String] = []
private var checkCount = 0

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    checkCount += 1
    if actual != expected {
        failures.append("\(name)：得到 \(actual)，期望 \(expected)")
    }
}

var optionEdges = ModifierPressEdgePolicy()
expect(
    optionEdges.observe(pressed: true, nowNanoseconds: 1_000_000_000),
    .acceptedPress,
    "右 Option 首次按下触发"
)
expect(
    optionEdges.observe(pressed: true, nowNanoseconds: 1_005_000_000),
    .ignoredDuplicate,
    "CGEventTap 与 NSEvent 的同次按下只触发一次"
)
expect(
    optionEdges.observe(pressed: false, nowNanoseconds: 1_080_000_000),
    .release,
    "右 Option 松开事件正常释放锁存"
)
expect(
    optionEdges.observe(pressed: true, nowNanoseconds: 1_500_000_000),
    .acceptedPress,
    "下一次右 Option 按下可结束录音"
)

var missedReleaseEdges = ModifierPressEdgePolicy()
expect(
    missedReleaseEdges.observe(pressed: true, nowNanoseconds: 2_000_000_000),
    .acceptedPress,
    "丢松键场景先接受开始按下"
)
expect(
    missedReleaseEdges.observe(pressed: true, nowNanoseconds: 2_500_000_000),
    .acceptedPress,
    "松键事件丢失后下一次按下仍可自恢复"
)
// MARK: Modifier trigger detection (synthetic flagsChanged sequences)

do {
    let ms: UInt64 = 1_000_000
    let nonCoalesced: UInt64 = 0x100
    func down(_ key: ModifierKeySpec, extra: UInt64 = 0) -> UInt64 {
        key.familyFlag | key.deviceMask | nonCoalesced | extra
    }
    /// Feeds (keyCode, rawFlags, ms, lastOtherInput ms) and returns the observations.
    func run(
        _ events: [(Int64, UInt64, UInt64, UInt64?)],
        detector: inout ModifierTapDetector
    ) -> [ModifierTapObservation] {
        events.map { code, flags, at, other in
            detector.observe(keyCode: code, rawFlags: flags, nowNanoseconds: at * ms,
                             lastOtherInput: { other.map { $0 * ms } })
        }
    }
    func fresh(_ key: ModifierKeySpec) -> ModifierTapDetector { ModifierTapDetector(key: key) }

    // 0. Trigger edge per key: right Option on press, the rest on release.
    expect(ModifierKeySpec.rightOption.triggerOn, .press, "右 Option 按下即触发")
    for key in [ModifierKeySpec.rightCommand, .leftOption, .leftControl, .function] {
        expect(key.triggerOn, .release, "keycode \(key.keyCode) 松开时判定")
    }

    // 1. Each of the five keys: one press toggles once.
    let keys: [(String, ModifierKeySpec)] = [
        ("右 Option", .rightOption), ("右 Command", .rightCommand), ("左 Option", .leftOption),
        ("左 Control", .leftControl), ("Fn", .function),
    ]
    for (name, key) in keys {
        var d = fresh(key)
        expect(
            run([(key.keyCode, down(key), 1_000, nil), (key.keyCode, nonCoalesced, 1_080, 900)], detector: &d),
            key.triggerOn == .press ? [.tap, .released] : [.pressStarted, .tap],
            "\(name) 单击触发一次"
        )
    }
    expect(ModifierKeySpec.rightOption.keyCode, 61, "右 Option keycode")
    expect(ModifierKeySpec.leftOption.keyCode, 58, "左 Option keycode")
    expect(ModifierKeySpec.rightCommand.keyCode, 54, "右 Command keycode")
    expect(ModifierKeySpec.leftControl.keyCode, 59, "左 Control keycode")
    expect(ModifierKeySpec.function.keyCode, 63, "Fn keycode")
    do {
        // Remapped keyboards may set no device bits: the family flag stands in.
        var d = fresh(.rightOption)
        expect(
            run([(61, ModifierKeySpec.optionFlag, 0, nil), (61, 0, 90, nil)], detector: &d),
            [.tap, .released],
            "没有设备位的键盘按族标志判断右 Option"
        )
        d = fresh(.leftOption)
        expect(
            run([(58, ModifierKeySpec.optionFlag, 0, nil), (58, 0, 90, nil)], detector: &d),
            [.pressStarted, .tap],
            "没有设备位的键盘按族标志判断左 Option"
        )
    }

    // 2. Right Option (press mode) behaves exactly as before.
    do {
        // Differential check against the unchanged ModifierPressEdgePolicy and
        // the old monitor's key-code filter and isRightOptionDown, over random
        // flagsChanged streams that mix in other modifiers.
        func oldIsRightOptionDown(rawFlags: UInt64) -> Bool {
            let leftOptionDeviceMask: UInt64 = 0x20
            let rightOptionDeviceMask: UInt64 = 0x40
            let optionFlag: UInt64 = 0x80000
            if rawFlags & (leftOptionDeviceMask | rightOptionDeviceMask) == 0 {
                return rawFlags & optionFlag != 0
            }
            return rawFlags & rightOptionDeviceMask != 0
        }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: UInt64) -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (seed >> 33) % bound
        }
        let codes: [Int64] = [61, 61, 61, 58, 56, 54, 63, 59]
        let bits: [UInt64] = [0x80000, 0x40, 0x20, 0x20000, 0x02, 0x100000, 0x10, 0x800000, 0x40000, 0x01, 0x10000]
        var mismatches = 0
        var accepted = 0
        var lastOtherCalls = 0
        for _ in 0..<2_000 {
            var old = ModifierPressEdgePolicy()
            var d = fresh(.rightOption)
            var now: UInt64 = 1_000 * ms
            for _ in 0..<40 {
                now += next(700) * ms
                let code = codes[Int(next(UInt64(codes.count)))]
                var flags = nonCoalesced
                for bit in bits where next(3) == 0 { flags |= bit }
                let actual = d.observe(keyCode: code, rawFlags: flags, nowNanoseconds: now,
                                       lastOtherInput: { lastOtherCalls += 1; return now })
                let expected: ModifierTapObservation
                if code != 61 {
                    expected = .unrelated
                } else {
                    switch old.observe(pressed: oldIsRightOptionDown(rawFlags: flags), nowNanoseconds: now) {
                    case .acceptedPress: expected = .tap; accepted += 1
                    case .release: expected = .released
                    case .ignoredDuplicate: expected = .rejected(.duplicate)
                    }
                }
                if actual != expected { mismatches += 1 }
            }
        }
        expect(mismatches, 0, "右 Option 在 8 万个随机事件上与改动前的判定逐条一致")
        expect(accepted > 1_000, true, "差分测试确实覆盖了大量触发")
        expect(lastOtherCalls, 0, "右 Option 从不查询 HID 按键时间")

        var d = fresh(.rightOption)
        expect(
            run([(61, down(.rightOption), 1_000, 1_000), (61, nonCoalesced, 1_100, 1_050)], detector: &d),
            [.tap, .released],
            "右 Option 按下即开始，之后的按键不影响（与以前一致）"
        )
        d = fresh(.rightOption)
        expect(
            run([
                (61, down(.rightOption), 0, nil), (61, nonCoalesced, 5_000, nil),
                (61, down(.rightOption), 6_000, nil),
            ], detector: &d),
            [.tap, .released, .tap],
            "右 Option 没有按住阈值：按住 5 秒后下一次按下照常触发"
        )
        d = fresh(.rightOption)
        expect(
            run([
                (61, down(.rightOption), 0, nil),
                (61, down(.rightOption), 5, nil),
                (61, nonCoalesced, 80, nil),
                (61, down(.rightOption), 150, nil), (61, nonCoalesced, 230, nil),
                (61, down(.rightOption), 600, nil),
            ], detector: &d),
            [.tap, .rejected(.duplicate), .released, .rejected(.duplicate), .released, .tap],
            "右 Option 350 ms 内的重复边沿只触发一次，之后正常"
        )
        d = fresh(.rightOption)
        expect(
            run([
                (61, down(.rightOption), 0, nil),
                (61, down(.rightOption), 2_000, nil),
                (61, down(.rightOption), 4_000, nil),
            ], detector: &d),
            [.tap, .tap, .tap],
            "右 Option 松键事件接连丢失仍每次可触发（无布尔锁存）"
        )
    }

    // 3. Left/right confusion.
    do {
        var d = fresh(.rightOption)
        expect(
            run([(58, down(.leftOption), 0, nil), (58, nonCoalesced, 80, nil)], detector: &d),
            [.unrelated, .unrelated],
            "触发键为右 Option 时左 Option 单击不触发"
        )
        d = fresh(.leftOption)
        expect(
            run([(61, down(.rightOption), 0, nil), (61, nonCoalesced, 80, nil)], detector: &d),
            [.unrelated, .unrelated],
            "触发键为左 Option 时右 Option 单击不触发"
        )
        d = fresh(.rightCommand)
        expect(
            run([(55, ModifierKeySpec.commandFlag | 0x08, 0, nil), (55, 0, 80, nil)], detector: &d),
            [.unrelated, .unrelated],
            "触发键为右 Command 时左 Command 单击不触发"
        )
        d = fresh(.leftControl)
        expect(
            run([(62, ModifierKeySpec.controlFlag | 0x2000, 0, nil), (62, 0, 80, nil)], detector: &d),
            [.unrelated, .unrelated],
            "触发键为左 Control 时右 Control 单击不触发"
        )
        // Left Option held while right Option goes down and up: the shared
        // Option flag never clears, so only the device bit shows right is up.
        d = fresh(.rightOption)
        let leftHeld = down(.leftOption)
        expect(
            run([
                (58, leftHeld, 0, nil),
                (61, leftHeld | 0x40, 100, nil),
                (61, leftHeld, 180, nil),
                (58, nonCoalesced, 300, nil),
                (61, down(.rightOption), 600, nil),
            ], detector: &d),
            [.unrelated, .tap, .released, .unrelated, .tap],
            "按住左 Option 时右 Option 抬起按设备位识别，下一次按下照常触发"
        )
        d = fresh(.leftOption)
        let rightHeld = down(.rightOption)
        expect(
            run([
                (61, rightHeld, 0, nil),
                (58, rightHeld | 0x20, 100, nil),
                (58, rightHeld, 180, nil),
                (61, nonCoalesced, 300, nil),
            ], detector: &d),
            [.unrelated, .pressStarted, .rejected(.combined), .unrelated],
            "按住右 Option 再单击左 Option 视为组合，不触发"
        )
    }

    // 4. Release keys: combinations never trigger.
    do {
        var d = fresh(.rightCommand)
        expect(
            run([(54, down(.rightCommand), 1_000, 500), (54, nonCoalesced, 1_120, 1_040)], detector: &d),
            [.pressStarted, .rejected(.combined)],
            "Command+C：按住期间有按键，不触发"
        )
        d = fresh(.leftOption)
        expect(
            run([(58, down(.leftOption), 1_000, nil), (58, nonCoalesced, 1_300, 1_200)], detector: &d),
            [.pressStarted, .rejected(.combined)],
            "左 Option+方向键或字母不触发"
        )
        d = fresh(.leftControl)
        expect(
            run([(59, down(.leftControl), 1_000, nil), (59, nonCoalesced, 1_150, 1_060)], detector: &d),
            [.pressStarted, .rejected(.combined)],
            "Control+点按（鼠标按下）不触发"
        )
        d = fresh(.function)
        expect(
            run([(63, down(.function), 1_000, nil), (63, nonCoalesced, 1_150, 1_070)], detector: &d),
            [.pressStarted, .rejected(.combined)],
            "Fn+方向键不触发"
        )
        d = fresh(.rightCommand)
        let shift = ModifierKeySpec.shiftFlag | 0x02
        expect(
            run([
                (56, shift, 0, nil),
                (54, shift | down(.rightCommand), 100, nil),
                (54, shift, 180, nil),
                (56, 0, 260, nil),
            ], detector: &d),
            [.unrelated, .pressStarted, .rejected(.combined), .unrelated],
            "先按住 Shift 再单击右 Command 不触发"
        )
        d = fresh(.leftOption)
        expect(
            run([
                (58, down(.leftOption), 0, nil),
                (56, down(.leftOption) | shift, 50, nil),
                (56, down(.leftOption), 90, nil),
                (58, nonCoalesced, 140, nil),
            ], detector: &d),
            [.pressStarted, .unrelated, .unrelated, .rejected(.combined)],
            "左 Option 按住期间按下 Shift 不触发"
        )
        d = fresh(.leftControl)
        expect(
            run([
                (59, down(.leftControl), 0, nil),
                (63, down(.leftControl) | ModifierKeySpec.functionFlag, 40, nil),
                (63, down(.leftControl), 70, nil),
                (59, nonCoalesced, 120, nil),
            ], detector: &d),
            [.pressStarted, .unrelated, .unrelated, .rejected(.combined)],
            "左 Control 按住期间按 Fn 不触发"
        )
        d = fresh(.rightCommand)
        expect(
            run([
                (54, down(.rightCommand, extra: ModifierKeySpec.functionFlag | 0x10000), 0, nil),
                (54, ModifierKeySpec.functionFlag | 0x10000, 90, nil),
            ], detector: &d),
            [.pressStarted, .tap],
            "残留的 Fn 位与 Caps Lock 位不算组合"
        )
        d = fresh(.rightCommand)
        expect(
            run([(54, down(.rightCommand), 1_000, 990), (54, nonCoalesced, 1_090, 990)], detector: &d),
            [.pressStarted, .tap],
            "按下触发键之前的打字不影响单击"
        )
        // HID key time is read only when a release key goes up.
        var calls = 0
        d = fresh(.rightCommand)
        _ = d.observe(keyCode: 54, rawFlags: down(.rightCommand), nowNanoseconds: 0, lastOtherInput: { calls += 1; return nil })
        _ = d.observe(keyCode: 56, rawFlags: down(.rightCommand), nowNanoseconds: 10 * ms, lastOtherInput: { calls += 1; return nil })
        expect(calls, 0, "松开模式只在触发键抬起时查询 HID 按键时间")
    }

    // 5. Release keys: lost modifier-up events recover.
    do {
        var d = fresh(.rightCommand)
        expect(
            run([
                (54, down(.rightCommand), 0, nil),
                (54, nonCoalesced, 80, nil),
                (54, down(.rightCommand), 5_000, nil),
                // the up event of this press is lost
                (54, down(.rightCommand), 9_000, nil),
                (54, nonCoalesced, 9_080, nil),
            ], detector: &d),
            [.pressStarted, .tap, .pressStarted, .pressRestarted, .tap],
            "结束键的抬起丢失后，下一次单击仍能结束录音"
        )
        d = fresh(.leftControl)
        expect(
            run([
                (59, down(.leftControl), 0, nil),
                // up lost; a later Shift event shows Control already up
                (56, ModifierKeySpec.shiftFlag | 0x02, 3_000, nil),
                (56, 0, 3_100, nil),
                (59, down(.leftControl), 4_000, nil),
                (59, nonCoalesced, 4_090, nil),
            ], detector: &d),
            [.pressStarted, .rejected(.releaseMissed), .unrelated, .pressStarted, .tap],
            "其他修饰键事件显示触发键已抬起时丢弃悬空的按下，之后照常单击"
        )
        d = fresh(.function)
        expect(
            run([
                // down lost; only the up arrives
                (63, nonCoalesced, 0, nil),
                (63, down(.function), 1_000, nil),
                (63, nonCoalesced, 1_090, nil),
            ], detector: &d),
            [.unrelated, .pressStarted, .tap],
            "按下事件丢失时孤立的抬起被忽略，下一次单击正常"
        )
    }

    // 6. Release keys: two quick taps in a row.
    do {
        var d = fresh(.rightCommand)
        expect(
            run([
                (54, down(.rightCommand), 0, nil), (54, nonCoalesced, 80, nil),
                (54, down(.rightCommand), 150, nil), (54, nonCoalesced, 230, nil),
                (54, down(.rightCommand), 600, nil), (54, nonCoalesced, 680, nil),
            ], detector: &d),
            [.pressStarted, .tap, .pressStarted, .rejected(.duplicate), .pressStarted, .tap],
            "350 ms 内的第二次单击视为抖动，之后的单击正常"
        )
        d = fresh(.function)
        expect(
            run([
                (63, down(.function), 0, nil), (63, nonCoalesced, 80, nil),
                (63, down(.function), 85, nil), (63, nonCoalesced, 88, nil),
            ], detector: &d),
            [.pressStarted, .tap, .pressStarted, .rejected(.duplicate)],
            "抬起时的硬件抖动只触发一次"
        )
        d = fresh(.leftOption)
        expect(
            run([
                (58, down(.leftOption), 0, nil), (58, nonCoalesced, 70, nil),
                (58, down(.leftOption), 430, nil), (58, nonCoalesced, 500, nil),
            ], detector: &d),
            [.pressStarted, .tap, .pressStarted, .tap],
            "间隔超过 350 ms 的两次单击分别开始和结束"
        )
    }

    // 7. Release keys: holding past the threshold.
    do {
        var d = fresh(.rightCommand)
        expect(
            run([(54, down(.rightCommand), 0, nil), (54, nonCoalesced, 1_200, nil)], detector: &d),
            [.pressStarted, .rejected(.heldTooLong)],
            "松开模式按住超过 1 秒不算单击"
        )
        d = fresh(.rightCommand)
        expect(
            run([(54, down(.rightCommand), 0, nil), (54, nonCoalesced, 950, nil)], detector: &d),
            [.pressStarted, .tap],
            "慢按（1 秒内）仍算单击"
        )
        expect(ModifierTapDetector.maximumTapNanoseconds, 1_000_000_000, "按住阈值为 1 秒")
        expect(ModifierTapDetector.duplicateWindowNanoseconds, ModifierPressEdgePolicy.duplicateWindowNanoseconds, "两种模式去重窗口相同")
    }

    // 8. Switching the key in place, across modes.
    do {
        var d = fresh(.rightOption)
        expect(d.observe(keyCode: 61, rawFlags: down(.rightOption), nowNanoseconds: 0), .tap, "右 Option 按下触发")
        d.setKey(.rightCommand)
        expect(d.observe(keyCode: 61, rawFlags: nonCoalesced, nowNanoseconds: 80 * ms), .unrelated, "切换触发键后旧键的抬起不触发")
        expect(d.observe(keyCode: 54, rawFlags: down(.rightCommand), nowNanoseconds: 200 * ms), .pressStarted, "切换后新键按下")
        expect(d.observe(keyCode: 54, rawFlags: nonCoalesced, nowNanoseconds: 280 * ms), .tap, "切换后新键单击立即生效")
        d.setKey(.rightOption)
        expect(d.observe(keyCode: 61, rawFlags: down(.rightOption), nowNanoseconds: 300 * ms), .tap, "切回右 Option 后按下即触发")
    }
}

expect(
    RealtimeCompletionPolicy.primaryPreferenceNanoseconds,
    750_000_000,
    "云端主模型偏好窗口不再固定拖延 2.5 秒"
)
expect(SonioxRecoveryPolicy.maximumRecoveryAttempts, 1, "Soniox 会话内恢复严格限为一次")
expect(SonioxRecoveryPolicy.isRetryableServerError("request_timeout"), true, "Soniox request_timeout 可恢复")
expect(SonioxRecoveryPolicy.isRetryableServerError("service_unavailable"), true, "Soniox 过载可恢复")
expect(SonioxRecoveryPolicy.isRetryableServerError("internal_error"), true, "Soniox 内部错误只重试一次")
expect(SonioxRecoveryPolicy.isRetryableServerError("unauthenticated"), false, "Soniox 凭据错误不得重试")
expect(SonioxRecoveryPolicy.isRetryableServerError("invalid_request"), false, "Soniox 配置错误不得重试")
let threeMinutePCMBytes = HistoryRetranscriptionPolicy.pcmBytesPerSecond * 180
expect(
    LocalFallbackPolicy.minimumBudgetNanoseconds(pcmByteCount: threeMinutePCMBytes),
    UInt64(16_000_000_000),
    "local fallback budget scales with a three-minute recording"
)
expect(
    SonioxRecoveryPolicy.configurationSendDeadlineNanoseconds >= 5_000_000_000,
    true,
    "Soniox setup tolerates a slow hotspot handshake"
)
expect(
    HistoryRetranscriptionPolicy.audioDurationNanoseconds(pcmByteCount: threeMinutePCMBytes),
    180_000_000_000,
    "历史音频时长由 PCM 字节数确定"
)
expect(
    HistoryRetranscriptionPolicy.deadlineNanoseconds(
        pcmByteCount: threeMinutePCMBytes,
        isRealtimeCloud: true
    ),
    210_000_000_000,
    "三分钟云端重转写不会再被固定 20 秒截止误杀"
)
expect(
    HistoryRetranscriptionPolicy.progressPercent(completedChunks: 3, totalChunks: 4),
    75,
    "历史重转写进度按已发送音频计算"
)
expect(
    HistoryRetranscriptionPolicy.cloudReplayPacingNanoseconds(
        cumulativePCMByteCount: 3_840,
        elapsedNanoseconds: 20_000_000
    ),
    100_000_000,
    "云端历史回放以绝对音频时间轴节流并扣除发送耗时"
)
expect(
    HistoryRetranscriptionPolicy.cloudReplayPacingNanoseconds(
        cumulativePCMByteCount: 3_840,
        elapsedNanoseconds: 150_000_000
    ),
    0,
    "云端发送已经落后音频时间轴时不再额外等待"
)

var ring = BoundedByteRing(capacity: 5)
ring.append(Data([1, 2, 3]))
ring.append(Data([4, 5, 6]))
expect(Array(ring.snapshot()), [2, 3, 4, 5, 6], "环形缓冲只保留最新数据")

var boundary = SequencedCaptureBuffer<String>()
boundary.begin()
boundary.append("snapshot-tail", sequence: 10)
boundary.append("opening", sequence: 11)
boundary.append("next", sequence: 12)
boundary.end()
boundary.append("after-release", sequence: 13)
expect(boundary.drain(after: 10), ["opening", "next"], "启动扫描期间音频无缝衔接且不重复 pre-roll")
boundary.begin()
boundary.append("discard", sequence: 20)
boundary.cancel()
expect(boundary.drain(after: 0), [], "取消启动时清除暂存音频")

let chat = TextJoinConfiguration(removeTerminalPeriodInChat: true)
expect(TextJoinPolicy.prepare(transcript: "今天就这样。", precedingCharacter: nil, appKind: .chat, configuration: chat), "今天就这样", "聊天句号")
expect(TextJoinPolicy.prepare(transcript: "真的吗？", precedingCharacter: nil, appKind: .chat, configuration: chat), "真的吗？", "保留问号")
expect(TextJoinPolicy.prepare(transcript: "等等...", precedingCharacter: nil, appKind: .chat, configuration: chat), "等等...", "保留省略号")
expect(TextJoinPolicy.prepare(transcript: "版本是 1.0.", precedingCharacter: nil, appKind: .chat, configuration: chat), "版本是 1.0.", "保留版本句点")
expect(TextJoinPolicy.prepare(transcript: "Code is ready", precedingCharacter: "e", appKind: .document, configuration: .init(addSpaceBetweenLatinRuns: true)), " Code is ready", "显式启用英文词组连接")
expect(TextJoinPolicy.prepare(transcript: "Claude Code", precedingCharacter: "是", appKind: .document, configuration: .init()), "Claude Code", "中英文连接不多加空格")
expect(TextJoinPolicy.prepare(transcript: "Claude Code", precedingCharacter: nil, appKind: .chat, configuration: .init(appendTrailingSpaceAfterLatin: true)), "Claude Code ", "英文尾部空格")
expect(TextJoinPolicy.prepare(transcript: "你好", precedingCharacter: nil, appKind: .chat, configuration: .init(appendTrailingSpaceAfterLatin: true)), "你好", "中文尾部不加空格")
expect(TextJoinPolicy.prepare(transcript: "Code is ready。", precedingCharacter: "e", appKind: .chat, configuration: .init()), "Code is ready。", "严格默认不改标点和连接空格")
expect(InsertionTextEvidence.containsNewOccurrence(insertedText: "保留我的原话", originalText: "使用 ChatGPT", currentText: "保留我的原话"), true, "识别 Electron 占位文字被真实输入替换")
expect(InsertionTextEvidence.containsNewOccurrence(insertedText: "新增内容", originalText: "当前人设：逐字", currentText: "当前人设：逐字\n新增内容"), true, "识别组合 AXValue 中新增的输入")
expect(InsertionTextEvidence.containsNewOccurrence(insertedText: "同一句", originalText: "同一句", currentText: "同一句"), false, "不把原有文字误判为新插入")

let nativeEditorLease = InputTargetLeaseEvidence(
    processExists: true,
    bundleIdentifierMatches: true,
    applicationIsFrontmost: true,
    secureInputEnabled: false,
    liveEditableTargetAvailable: true,
    liveTargetIsSecure: false,
    liveTargetHasComposition: false
)
expect(InputTargetLeasePolicy.resolve(nativeEditorLease), .liveEditableTarget, "原生和网页编辑框统一使用提交时焦点")

let customCanvasLease = InputTargetLeaseEvidence(
    processExists: true,
    bundleIdentifierMatches: true,
    applicationIsFrontmost: true,
    secureInputEnabled: false,
    liveEditableTargetAvailable: false,
    liveTargetIsSecure: false,
    liveTargetHasComposition: false
)
expect(InputTargetLeasePolicy.resolve(customCanvasLease), .keyboardFocus, "无 AX 编辑框统一使用当前键盘焦点")

let changedApplicationLease = InputTargetLeaseEvidence(
    processExists: true,
    bundleIdentifierMatches: false,
    applicationIsFrontmost: true,
    secureInputEnabled: false,
    liveEditableTargetAvailable: true,
    liveTargetIsSecure: false,
    liveTargetHasComposition: false
)
expect(InputTargetLeasePolicy.resolve(changedApplicationLease), .reject(.applicationIdentityChanged), "进程身份改变时拒绝插入")

let secureLease = InputTargetLeaseEvidence(
    processExists: true,
    bundleIdentifierMatches: true,
    applicationIsFrontmost: true,
    secureInputEnabled: false,
    liveEditableTargetAvailable: true,
    liveTargetIsSecure: true,
    liveTargetHasComposition: false
)
expect(InputTargetLeasePolicy.resolve(secureLease), .reject(.secureField), "安全输入框拒绝插入")

let compositionLease = InputTargetLeaseEvidence(
    processExists: true,
    bundleIdentifierMatches: true,
    applicationIsFrontmost: true,
    secureInputEnabled: false,
    liveEditableTargetAvailable: true,
    liveTargetIsSecure: false,
    liveTargetHasComposition: true
)
expect(InputTargetLeasePolicy.resolve(compositionLease), .reject(.compositionActive), "输入法组合文本未上屏时拒绝插入")

let exitedApplicationLease = InputTargetLeaseEvidence(
    processExists: false,
    bundleIdentifierMatches: true,
    applicationIsFrontmost: true,
    secureInputEnabled: false,
    liveEditableTargetAvailable: true,
    liveTargetIsSecure: false,
    liveTargetHasComposition: false
)
expect(InputTargetLeasePolicy.resolve(exitedApplicationLease), .reject(.applicationExited), "原应用退出时拒绝插入")

let backgroundApplicationLease = InputTargetLeaseEvidence(
    processExists: true,
    bundleIdentifierMatches: true,
    applicationIsFrontmost: false,
    secureInputEnabled: false,
    liveEditableTargetAvailable: true,
    liveTargetIsSecure: false,
    liveTargetHasComposition: false
)
expect(InputTargetLeasePolicy.resolve(backgroundApplicationLease), .reject(.applicationNotFrontmost), "目标应用不在前台时拒绝插入")

let secureInputLease = InputTargetLeaseEvidence(
    processExists: true,
    bundleIdentifierMatches: true,
    applicationIsFrontmost: true,
    secureInputEnabled: true,
    liveEditableTargetAvailable: false,
    liveTargetIsSecure: false,
    liveTargetHasComposition: false
)
expect(InputTargetLeasePolicy.resolve(secureInputLease), .reject(.secureInputEnabled), "无 AX 控件时仍尊重系统 Secure Input")

let originalEditor = "前文 Claude Coed 后文"
let correctedEditor = "前文 Claude Code 后文"
let correctedMutation = CorrectionInference.mutation(from: originalEditor, to: correctedEditor)!
let correctedTracking = CorrectionInference.track(
    mutation: correctedMutation,
    oldWholeText: originalEditor,
    newWholeText: correctedEditor,
    insertedRange: NSRange(location: 3, length: 11)
)!
expect(correctedTracking.correctedText, "Claude Code", "只捕获插入范围内的词语修正")

let appendedEditor = "前文 Claude Coed 后文，另外一件事"
let appendMutation = CorrectionInference.mutation(from: originalEditor, to: appendedEditor)!
let appendTracking = CorrectionInference.track(
    mutation: appendMutation,
    oldWholeText: originalEditor,
    newWholeText: appendedEditor,
    insertedRange: NSRange(location: 3, length: 11)
)!
expect(appendTracking.correctedText, nil, "插入范围外追加内容不算纠错")

let prefixedEditor = "新前文 Claude Coed 后文"
let prefixMutation = CorrectionInference.mutation(from: originalEditor, to: prefixedEditor)!
let shiftedTracking = CorrectionInference.track(
    mutation: prefixMutation,
    oldWholeText: originalEditor,
    newWholeText: prefixedEditor,
    insertedRange: NSRange(location: 3, length: 11)
)!
expect(shiftedTracking.updatedInsertedRange.location, 4, "前方编辑只移动跟踪范围")

let punctuatedEditor = "前文 Claude Coed？ 后文"
let punctuationMutation = CorrectionInference.mutation(from: originalEditor, to: punctuatedEditor)!
let punctuationTracking = CorrectionInference.track(
    mutation: punctuationMutation,
    oldWholeText: originalEditor,
    newWholeText: punctuatedEditor,
    insertedRange: NSRange(location: 3, length: 11)
)!
expect(punctuationTracking.correctedText, "Claude Coed？", "句末补标点可作为纠错")

let replacement = CorrectionInference.replacement(from: "Claude Coed", to: "Claude Code")!
expect(replacement.original, "ed", "纠错差异保留错误片段")
expect(replacement.corrected, "de", "纠错差异保留修正片段")

let builtInContextTerms = (1...56).map { "built-in-\($0)" }
let contextCandidates = builtInContextTerms + ["Ada Lovelace", "Project Phoenix", "ada lovelace", "  "]
let rankedContext = ContextBudgeter.select(
    candidates: contextCandidates,
    builtInTerms: builtInContextTerms,
    capacity: 50
)
expect(rankedContext.candidateCount, 58, "上下文编译先去空值和重复")
expect(Array(rankedContext.selectedTerms.prefix(2)), ["Ada Lovelace", "Project Phoenix"], "个人新增术语优先")
expect(rankedContext.selectedTerms.count, 50, "Soniox 上下文容量严格受限")
expect(rankedContext.selectedUserTermCount, 2, "单独计数已选个人术语")
expect(rankedContext.selectedBuiltInTermCount, 48, "内置术语填充剩余容量")
expect(rankedContext.droppedCount, 8, "如实计数未发送候选词")
expect(
    ContextBudgeter.select(candidates: contextCandidates, builtInTerms: builtInContextTerms, capacity: 0).selectedTerms,
    [],
    "零容量不发送术语"
)

var pcmBatcher = PCMFrameBatcher(targetFrameBytes: 8)
let firstPCMFrames = pcmBatcher.append(Data([0, 1, 2]))
let secondPCMFrames = pcmBatcher.append(Data([3, 4, 5, 6, 7, 8, 9, 10, 11]))
expect(firstPCMFrames.count, 0, "不足一帧时等待更多 PCM")
expect(secondPCMFrames.map(Array.init), [[0, 1, 2, 3, 4, 5, 6, 7]], "跨采集块无损合成网络帧")
expect(Array(pcmBatcher.flush() ?? Data()), [8, 9, 10, 11], "停止时刷新不足整帧的尾音频")
expect(
    RealtimeCompletionPolicy.sonioxDidFinish(finishedFlag: true, sawLegacyFinalMarker: false),
    true,
    "接受 Soniox 当前 finished 完成信号"
)
expect(
    RealtimeCompletionPolicy.sonioxDidFinish(finishedFlag: nil, sawLegacyFinalMarker: true),
    true,
    "兼容 Soniox 旧版 fin token 完成信号"
)
expect(AudioInputRecoveryPolicy.delaysNanoseconds.count, 5, "音频设备恢复使用有界退避")
expect(
    AudioInputRecoveryPolicy.receivedFreshFrame(sequenceBeforeStart: 41, sequenceAfterProbe: 42),
    true,
    "收到新音频帧后才把设备恢复视为成功"
)
expect(
    AudioInputRecoveryPolicy.receivedFreshFrame(sequenceBeforeStart: 41, sequenceAfterProbe: 41),
    false,
    "AVAudioEngine 仅启动但没有音频帧时继续重试"
)
let firstStaleAudioProbe = AudioInputWatchdogPolicy.nextStaleProbeCount(
    engineClaimsRunning: true,
    previousSequence: 41,
    currentSequence: 41,
    previousStaleProbeCount: 0
)
expect(firstStaleAudioProbe, 1, "音频引擎声称运行但无新 PCM 时累计 watchdog 证据")
expect(
    AudioInputWatchdogPolicy.nextStaleProbeCount(
        engineClaimsRunning: true,
        previousSequence: 41,
        currentSequence: 42,
        previousStaleProbeCount: firstStaleAudioProbe
    ),
    0,
    "收到新 PCM 后清除 watchdog 断流计数"
)
expect(
    AudioInputWatchdogPolicy.nextStaleProbeCount(
        engineClaimsRunning: false,
        previousSequence: 41,
        currentSequence: 41,
        previousStaleProbeCount: 1
    ),
    0,
    "恢复过程中不把未运行状态重复计算为静默断流"
)
expect(
    AudioInputWatchdogPolicy.engineStartDeadlineNanoseconds,
    2_000_000_000,
    "CoreAudio 启动调用最多阻塞用户恢复路径两秒"
)
expect(
    AudioInputWatchdogPolicy.maximumOutstandingStartAttempts,
    2,
    "系统级启动阻塞时限制隔离调用数量"
)
var longPCM = PCMFrameBatcher(targetFrameBytes: 3_840)
let longFrames = longPCM.append(Data(repeating: 1, count: 1_875_200))
let longTailCount = longPCM.flush()?.count ?? 0
expect(longFrames.count, 488, "约 58.6 秒音频只产生约 120ms 一帧的网络消息")
expect(longFrames.reduce(0) { $0 + $1.count } + longTailCount, 1_875_200, "长录音合帧保持全部字节")

let restoreRules = MisrecognitionNormalizer.rules(from: [
    PersonalTerm(canonical: "skill", aliases: ["SKU"]),
    PersonalTerm(canonical: "星河", aliases: ["Zephyr"]),
    PersonalTerm(canonical: "Agent to Agent", aliases: ["Agent 和 Agent"]),
    PersonalTerm(canonical: "Sonnet", aliases: ["Sonet"]),
])
expect(
    MisrecognitionNormalizer.apply("我们做星河", rules: restoreRules, corroboration: nil).text,
    "我们做星河",
    "没有第二引擎结果时不做任何恢复"
)
expect(
    MisrecognitionNormalizer.apply("这个Zephyr服务", rules: restoreRules, corroboration: "").text,
    "这个Zephyr服务",
    "第二引擎为空时不做任何恢复"
)
expect(
    MisrecognitionNormalizer.apply("这个Zephyr服务要做好", rules: restoreRules, corroboration: "这个星河服务要做好").text,
    "这个星河服务要做好",
    "第二引擎在同一位置听到原词时恢复"
)
expect(
    MisrecognitionNormalizer.apply("不是SKU，是skill", rules: restoreRules, corroboration: "不是SKU，是skill").text,
    "不是SKU，是skill",
    "两边都写误听词时保留原话"
)
expect(
    MisrecognitionNormalizer.apply("用Zephyr付款，然后星河", rules: restoreRules, corroboration: "用 Zephyr 付款，然后星河").text,
    "用Zephyr付款，然后星河",
    "第二引擎别处出现原词不算佐证"
)
expect(
    MisrecognitionNormalizer.apply("Agent 和 Agent 的协议", rules: restoreRules, corroboration: "Agent to Agent 的协议").text,
    "Agent to Agent 的协议",
    "恢复结果不会被其他规则再次改写"
)
expect(
    MisrecognitionNormalizer.apply("用Sonet写，再用Sonet审", rules: restoreRules, corroboration: "用Sonnet写，再用sonnet审").text,
    "用Sonnet写，再用Sonnet审",
    "每处误听分别对照并恢复"
)
expect(
    MisrecognitionNormalizer.apply("Sonetwork", rules: restoreRules, corroboration: "Sonnetwork").text,
    "Sonetwork",
    "英文误听词不在单词内部匹配"
)

// MARK: Provider failure classification (2026-10-01 Soniox balance incident)

for type in ProviderFailureClassifier.sonioxBillingTypes {
    expect(ProviderFailureClassifier.soniox(errorType: type, errorCode: 402), .billing, "Soniox \(type) 归为 billing")
    expect(SonioxRecoveryPolicy.isRetryableServerError(type), false, "Soniox \(type) 不在会话内重试")
}
for type in ProviderFailureClassifier.sonioxAuthTypes {
    expect(ProviderFailureClassifier.soniox(errorType: type, errorCode: nil), .auth, "Soniox \(type) 归为 auth")
    expect(SonioxRecoveryPolicy.isRetryableServerError(type), false, "Soniox \(type) 不在会话内重试")
}
for type in ProviderFailureClassifier.sonioxTransientTypes {
    expect(ProviderFailureClassifier.soniox(errorType: type, errorCode: nil), .transient, "Soniox \(type) 归为 transient")
    expect(SonioxRecoveryPolicy.isRetryableServerError(type), true, "Soniox \(type) 仍可重试一次")
}
expect(ProviderFailureClassifier.soniox(errorType: "limit_exceeded", errorCode: 429), .other, "Soniox 限流不算余额问题也不立即重试")
expect(ProviderFailureClassifier.soniox(errorType: "some_future_type", errorCode: 402), .billing, "未知 Soniox 类型按 402 归为 billing")
expect(ProviderFailureClassifier.soniox(errorType: "model_not_available", errorCode: 400), .other, "Soniox 配置错误归为 other")

expect(ProviderFailureClassifier.aliyun(code: "Arrearage", message: "Access denied, please make sure your account is in good standing."), .billing, "阿里云 Arrearage 归为 billing")
expect(ProviderFailureClassifier.aliyun(code: "AllocationQuota.FreeTierOnly", message: nil), .billing, "阿里云免费额度用尽归为 billing")
expect(ProviderFailureClassifier.aliyun(code: "BudgetLimitExceeded", message: nil), .billing, "阿里云预算停机归为 billing")
expect(ProviderFailureClassifier.aliyun(code: "AccessDenied.Unpurchased", message: nil), .billing, "阿里云未购买模型归为 billing 而非 auth")
expect(ProviderFailureClassifier.aliyun(code: "InvalidApiKey", message: "Invalid API-key provided."), .auth, "阿里云 InvalidApiKey 归为 auth")
expect(ProviderFailureClassifier.aliyun(code: "AccessDenied", message: nil), .auth, "阿里云 AccessDenied 归为 auth")
expect(ProviderFailureClassifier.aliyun(code: "Throttling.AllocationQuota", message: "Allocated quota exceeded, please increase your quota limit."), .other, "阿里云 TPM 限流不是余额问题")
expect(ProviderFailureClassifier.aliyun(code: "insufficient_quota", message: "Free allocated quota exceeded."), .billing, "阿里云免费额度耗尽的 quota 错误归为 billing")
expect(ProviderFailureClassifier.aliyun(code: "InternalError", message: nil), .transient, "阿里云 InternalError 归为 transient")
expect(ProviderFailureClassifier.httpStatus(402), .billing, "HTTP 402 归为 billing")
expect(ProviderFailureClassifier.httpStatus(401), .auth, "HTTP 401 归为 auth")
expect(ProviderFailureClassifier.httpStatus(403), .auth, "HTTP 403 归为 auth")
expect(ProviderFailureClassifier.httpStatus(503), .transient, "HTTP 503 归为 transient")
expect(ProviderFailureClassifier.httpStatus(429), .other, "HTTP 429 归为 other")
expect(
    ProviderFailureClassifier.classify(message: "服务端错误：organization_balance_exhausted: Organization balance exhausted. Please either add funds manually or enable autopay. request_id=5098dbfc"),
    .billing,
    "历史里的事故原文可按文本归为 billing"
)
expect(ProviderFailureClassifier.classify(message: "服务端错误：unauthenticated: Incorrect API key provided."), .auth, "历史文本 unauthenticated 归为 auth")
expect(ProviderFailureClassifier.classify(message: "等待超时：主云在 2.5 秒软截止前未完成"), .other, "普通超时文本不误判为 billing")
expect(
    ProviderFailureClassifier.notice(kind: .billing, providerName: "Soniox", fallbackName: "阿里云"),
    "Soniox 余额不足，已改用阿里云",
    "余额提示文案"
)
expect(ProviderFailureKind.billing.disablesProvider && ProviderFailureKind.auth.disablesProvider, true, "billing/auth 让主引擎不可用")
expect(ProviderFailureKind.transient.disablesProvider || ProviderFailureKind.other.disablesProvider, false, "transient/other 不让主引擎不可用")

// MARK: Cloud selection policy (shared by macOS AppModel.finish and iOS selectResult)

expect(CloudSelectionPolicy.decide(primary: .usable, standby: .usable, stage: .softDeadline), .takePrimary(reason: "primary_completed"), "主引擎可用时总是优先")
expect(CloudSelectionPolicy.decide(primary: .usable, standby: .pending, stage: .race), .takePrimary(reason: "primary_completed_after_soft_deadline"), "软截止后主引擎先到仍采用主引擎")
expect(CloudSelectionPolicy.decide(primary: .failed(.billing), standby: .usable, stage: .preference), .takeStandby(reason: "standby_after_primary_billing"), "billing：热备已有结果时立即采用，不等偏好窗口")
expect(CloudSelectionPolicy.decide(primary: .failed(.auth), standby: .usable, stage: .softDeadline), .takeStandby(reason: "standby_after_primary_auth"), "auth：热备已有结果时立即采用")
expect(CloudSelectionPolicy.decide(primary: .failed(.billing), standby: .pending, stage: .preference), .waitForStandby, "billing：热备未完成时只等热备")
expect(CloudSelectionPolicy.decide(primary: .failed(.billing), standby: .usable, stage: .race), .takeStandby(reason: "standby_after_primary_billing"), "billing：热备在截止前完成即采用")
expect(CloudSelectionPolicy.decide(primary: .failed(.billing), standby: .pending, stage: .deadline), .noUsableResult, "billing：热备超过云端截止则失败交给本地兜底")
expect(CloudSelectionPolicy.decide(primary: .failed(.billing), standby: nil, stage: .softDeadline), .noUsableResult, "billing 且无热备时直接失败，不重试主引擎")
expect(CloudSelectionPolicy.decide(primary: .failed(.billing), standby: .failed(.transient), stage: .race), .noUsableResult, "两路都失败时没有结果")
expect(CloudSelectionPolicy.decide(primary: .pending, standby: .usable, stage: .preference), .waitForPrimary, "普通情况下偏好窗口内仍等主引擎")
expect(CloudSelectionPolicy.decide(primary: .pending, standby: .usable, stage: .softDeadline), .takeStandby(reason: "standby_ready_at_soft_deadline"), "软截止时热备已完成则采用热备")
expect(CloudSelectionPolicy.decide(primary: .pending, standby: .pending, stage: .softDeadline), .waitForFirstUsable, "软截止后两路都未完成时谁先到用谁")
expect(CloudSelectionPolicy.decide(primary: .pending, standby: .usable, stage: .race), .takeStandby(reason: "standby_won_after_soft_deadline"), "竞速中热备先到")
expect(CloudSelectionPolicy.decide(primary: .failed(.transient), standby: .usable, stage: .softDeadline), .takeStandby(reason: "standby_ready_at_soft_deadline"), "transient 失败沿用原有软截止标签")
expect(CloudSelectionPolicy.decide(primary: .failed(.transient), standby: .pending, stage: .softDeadline), .waitForStandby, "transient 失败后等待热备")
expect(CloudSelectionPolicy.decide(primary: .pending, standby: nil, stage: .softDeadline), .waitForPrimary, "无热备时等主引擎到云端截止")
expect(CloudSelectionPolicy.decide(primary: .failed(nil), standby: nil, stage: .softDeadline), .noUsableResult, "主引擎空结果且无热备")

// MARK: Availability routing and recovery

let outageStart = Date(timeIntervalSince1970: 1_000_000)
let sonioxOutage = ProviderOutage(providerID: "soniox", kind: .billing, message: "organization_balance_exhausted", since: outageStart)
expect(
    ProviderAvailabilityPolicy.route(configuredPrimaryID: "soniox", configuredStandbyID: "aliyun", outages: [:]),
    ProviderAvailabilityPolicy.Route(primaryID: "soniox", standbyID: "aliyun", bypassedOutage: nil),
    "无故障时按配置路由"
)
expect(
    ProviderAvailabilityPolicy.route(configuredPrimaryID: "soniox", configuredStandbyID: "aliyun", outages: ["soniox": sonioxOutage]),
    ProviderAvailabilityPolicy.Route(primaryID: "aliyun", standbyID: nil, bypassedOutage: sonioxOutage),
    "主引擎不可用时之后的会话直接以热备为主"
)
expect(
    ProviderAvailabilityPolicy.route(configuredPrimaryID: "aliyun", configuredStandbyID: "soniox", outages: ["soniox": sonioxOutage]),
    ProviderAvailabilityPolicy.Route(primaryID: "aliyun", standbyID: nil, bypassedOutage: nil),
    "热备不可用时不再启动它"
)
expect(
    ProviderAvailabilityPolicy.route(configuredPrimaryID: "soniox", configuredStandbyID: nil, outages: ["soniox": sonioxOutage]),
    ProviderAvailabilityPolicy.Route(primaryID: "soniox", standbyID: nil, bypassedOutage: nil),
    "没有热备时仍尝试主引擎"
)
expect(ProviderAvailabilityPolicy.shouldProbe(outage: sonioxOutage, lastProbeAt: nil, now: outageStart), true, "进入故障后可立即探测一次")
expect(ProviderAvailabilityPolicy.shouldProbe(outage: sonioxOutage, lastProbeAt: outageStart, now: outageStart.addingTimeInterval(599)), false, "10 分钟内不重复探测")
expect(ProviderAvailabilityPolicy.shouldProbe(outage: sonioxOutage, lastProbeAt: outageStart, now: outageStart.addingTimeInterval(600)), true, "10 分钟后再次探测")
expect(ProviderAvailabilityPolicy.shouldProbe(outage: sonioxOutage, lastProbeAt: outageStart, now: outageStart, userRequested: true), true, "用户点重试时立即探测")
expect(ProviderAvailabilityPolicy.shouldProbe(outage: nil, lastProbeAt: nil, now: outageStart), false, "没有故障就不探测")
expect(ProviderAvailabilityPolicy.apply(probe: .available, now: outageStart, current: sonioxOutage), nil, "探测成功即恢复")
expect(ProviderAvailabilityPolicy.apply(probe: .failed(kind: .transient, message: "探测超时"), now: outageStart.addingTimeInterval(5), current: sonioxOutage), sonioxOutage, "探测超时不证明恢复也不改记录")
expect(
    ProviderAvailabilityPolicy.apply(probe: .failed(kind: .billing, message: "again"), now: outageStart.addingTimeInterval(5), current: sonioxOutage)?.confirmedAt,
    outageStart.addingTimeInterval(5),
    "探测再次遇到 billing 时刷新确认时间"
)
expect(
    ProviderAvailabilityPolicy.record(providerID: "soniox", completed: false, failureKind: .transient, message: "timeout", now: outageStart, current: nil),
    nil,
    "transient 失败不进入不可用状态"
)
expect(
    ProviderAvailabilityPolicy.record(providerID: "soniox", completed: true, failureKind: nil, message: nil, now: outageStart, current: sonioxOutage),
    nil,
    "主引擎正常定稿后清除故障"
)

let tracker = ProviderOutageTracker()
expect(tracker.record(providerID: "soniox", completed: false, failureKind: .other, message: "x", now: outageStart), .unchanged, "other 失败不记录故障")
let began = tracker.record(providerID: "soniox", completed: false, failureKind: .billing, message: "balance", now: outageStart)
expect(began, .began(ProviderOutage(providerID: "soniox", kind: .billing, message: "balance", since: outageStart)), "billing 失败开始故障状态（只在这一刻提示）")
if case .began = tracker.record(providerID: "soniox", completed: false, failureKind: .billing, message: "balance", now: outageStart.addingTimeInterval(1)) {
    failures.append("已在故障中再次失败不应再次提示")
}
checkCount += 1
expect(tracker.beginProbeIfDue(providerID: "soniox", now: outageStart.addingTimeInterval(2)), true, "首次探测领取成功")
expect(tracker.beginProbeIfDue(providerID: "soniox", now: outageStart.addingTimeInterval(3)), false, "探测节流")
expect(tracker.beginProbeIfDue(providerID: "soniox", now: outageStart.addingTimeInterval(3), userRequested: true), true, "重试按钮绕过节流")
expect(tracker.apply(probe: .available, providerID: "soniox", now: outageStart.addingTimeInterval(4)), .recovered(providerID: "soniox"), "探测成功恢复主引擎")
expect(tracker.outage(for: "soniox"), nil, "恢复后不再有故障记录")

// MARK: Network resilience (0.3.79): silent primary, liveness, cloud/local race

expect(CloudSelectionPolicy.preferenceWindowNanoseconds(primarySilent: false), 750_000_000, "主引擎正常时保留 750 ms 偏好窗口")
expect(CloudSelectionPolicy.preferenceWindowNanoseconds(primarySilent: true), 0, "主引擎无声时不等偏好窗口")
expect(CloudSelectionPolicy.decide(primary: .pending, standby: .usable, stage: .softDeadline, primarySilent: true), .takeStandby(reason: "standby_primary_silent"), "主引擎无声且热备已好：立即采用热备并单独标注")
expect(CloudSelectionPolicy.decide(primary: .pending, standby: .pending, stage: .softDeadline, primarySilent: true), .waitForFirstUsable, "主引擎无声但热备未好：两路竞速")
expect(CloudSelectionPolicy.decide(primary: .usable, standby: .usable, stage: .softDeadline, primarySilent: true), .takePrimary(reason: "primary_completed"), "无声判断不压过主引擎的可用结果")

let s3: UInt64 = 3_000_000_000
expect(ProviderLivenessPolicy.isSilent(ProviderLivenessView(sinceStarted: 2_900_000_000)), false, "未连上不足 3 s 不算无声")
expect(ProviderLivenessPolicy.isSilent(ProviderLivenessView(sinceStarted: s3)), true, "3 s 未连上且无任何服务端消息算无声")
expect(ProviderLivenessPolicy.isSilent(ProviderLivenessView(sinceStarted: 20_000_000_000, sinceConnected: 19_000_000_000, sinceLastServerMessage: 10_000_000_000)), false, "已连上且未报错：即使安静也不跳过偏好窗口（Soniox 回包节奏未知）")
expect(ProviderLivenessPolicy.isSilent(ProviderLivenessView(sinceStarted: 20_000_000_000, sinceConnected: 19_000_000_000, failed: true)), true, "已报错（传输中断）算无声")
expect(ProviderLivenessPolicy.isDead(ProviderLivenessView(sinceStarted: 20_000_000_000, sinceConnected: 19_000_000_000, sinceLastServerMessage: 200_000_000)), false, "连上且刚有回包：活")
expect(ProviderLivenessPolicy.isDead(ProviderLivenessView(sinceStarted: 30_000_000_000, sinceConnected: 29_000_000_000, sinceLastServerMessage: 9_000_000_000)), true, "连上后 8 s 以上没有任何服务端消息：半死")
expect(ProviderLivenessPolicy.isDead(ProviderLivenessView(sinceStarted: 4_000_000_000)), true, "录音 4 s 仍未建连：死")
expect(ProviderLivenessPolicy.isDead(ProviderLivenessView(sinceStarted: 1_000_000_000, finishedWithoutResult: true)), true, "任务已失败结束：死")
expect(ProviderLivenessPolicy.isDead(ProviderLivenessView(sinceStarted: 20_000_000_000, sinceConnected: 19_000_000_000, sinceLastServerMessage: 1_000_000_000, failed: true)), false, "连上后传输中断但仍可补发恢复：不算死")
expect(ProviderLivenessPolicy.cloudsDeadAtStop(primary: ProviderLivenessView(sinceStarted: 5_000_000_000), standby: ProviderLivenessView(sinceStarted: 5_000_000_000, finishedWithoutResult: true)), true, "两家都死：停止即跑本地")
expect(ProviderLivenessPolicy.cloudsDeadAtStop(primary: ProviderLivenessView(sinceStarted: 5_000_000_000), standby: ProviderLivenessView(sinceStarted: 5_000_000_000, sinceConnected: 4_000_000_000, sinceLastServerMessage: 300_000_000)), false, "只有主引擎死：照常走云端")

let probe = ProviderLivenessProbe()
let probeOrigin = ContinuousClock.now
probe.markStarted(at: probeOrigin.advanced(by: .milliseconds(200)))
probe.markConnected(reused: true, at: probeOrigin.advanced(by: .milliseconds(210)))
probe.markServerMessage(at: probeOrigin.advanced(by: .milliseconds(900)))
probe.markServerMessage(at: probeOrigin.advanced(by: .milliseconds(1_500)))
expect(
    probe.record(origin: probeOrigin),
    ProviderLivenessRecord(startedAtMilliseconds: 200, connectedAtMilliseconds: 210, firstServerMessageAtMilliseconds: 900, lastServerMessageAtMilliseconds: 1_500, serverMessageCount: 2, reusedConnection: true),
    "liveness 记录相对会话起点的建连、首末服务端消息偏移"
)

// Fake timelines, nanoseconds after stop. Local time follows the forensics
// fit: 836 ms + 21 ms per audio second.
func localNs(audioSeconds: Double) -> UInt64 { UInt64((0.836 + 0.021 * audioSeconds) * 1_000_000_000) }
typealias Race = CloudLocalRaceSimulator
func race(_ scenario: Race.Scenario) -> (String, UInt64, String?) {
    let outcome = Race.simulate(scenario)
    return (outcome.source.rawValue, outcome.selectedAt / 1_000_000, outcome.reason)
}
func same(_ a: (String, UInt64, String?), _ b: (String, UInt64, String?), _ name: String) {
    expect("\(a.0)@\(a.1)ms \(a.2 ?? "-")", "\(b.0)@\(b.1)ms \(b.2 ?? "-")", name)
}
same(race(.init(cloudUsableAt: 390_000_000, localDuration: localNs(audioSeconds: 27))), ("cloud", 390, nil), "正常：Soniox 0.39 s 定稿，不启动本地")
same(race(.init(cloudUsableAt: 1_630_000_000, localDuration: localNs(audioSeconds: 12))), ("cloud", 1_630, nil), "Soniox 迟到 1.63 s：仍用云端，本地未启动")
same(race(.init(cloudUsableAt: 2_460_000_000, localDuration: localNs(audioSeconds: 20))), ("cloud", 2_460, nil), "阿里云 2.46 s 接管：早于 2.5 s，本地未启动")
same(race(.init(cloudUsableAt: nil, localDuration: localNs(audioSeconds: 106))), ("local", 5_562, "local_raced_cloud_stalled"), "8 s 悬崖（样例 F，106 s 录音）：2.5 s 起本地，5.56 s 出结果（旧 11.06 s）")
same(race(.init(cloudUsableAt: nil, cloudsDeadAtStop: true, localDuration: localNs(audioSeconds: 20))), ("local", 1_256, "local_raced_clouds_dead"), "录音期间两家已死：停止即跑本地")
same(race(.init(cloudUsableAt: 3_000_000_000, localDuration: 3_000_000_000)), ("cloud", 3_000, nil), "本地运行中云端 3.0 s 先到：用云端")
same(race(.init(cloudUsableAt: 6_000_000_000, localDuration: 1_500_000_000)), ("local", 4_000, "local_raced_cloud_stalled"), "本地 4.0 s 先完成、云端 6 s 才到：先到先用本地")
same(race(.init(cloudUsableAt: 4_000_000_000, localDuration: 1_500_000_000)), ("cloud", 4_000, nil), "云端与本地同一刻到达：云端优先")
same(race(.init(cloudUsableAt: 7_000_000_000, localDuration: nil)), ("cloud", 7_000, nil), "本地失败：继续等云端到截止前")
same(race(.init(cloudUsableAt: nil, localDuration: nil)), ("none", 8_000, "all_providers_failed"), "本地失败且云端耗尽：没有结果")
same(race(.init(cloudUsableAt: nil, localAvailable: false, localDuration: nil)), ("none", 8_000, "all_providers_failed"), "无本地模型：行为与旧版相同")
same(race(.init(cloudUsableAt: nil, cloudExhaustedAt: 1_000_000_000, localDuration: 1_000_000_000)), ("local", 2_000, "dual_cloud_failed_local_completed"), "两家云 1 s 内都明确失败：立即本地，沿用旧标签")
same(race(.init(cloudUsableAt: nil, cloudsDeadAtStop: true, localDuration: nil)), ("none", 8_000, "all_providers_failed"), "两家已死且本地失败：等满云端预算后失败")

// MARK: Personal profile

do {
    let full = PersonalProfile(
        glossary: ["Alpha", "Beta"],
        lexicon: [.init(canonical: "星河", aliases: ["Zephyr"], pinned: true)],
        speakerBackground: "说话人是一名产品经理。",
        transcriptionPrompt: "逐字听写。",
        engine: .init(primaryProvider: "soniox", aliyunRegion: "singapore", languageHints: ["zh", "en"],
                      comparisonModeEnabled: false, automaticLocalFallback: true),
        insertion: .init(removeChatTerminalPeriod: true, appendTrailingSpaceAfterEnglish: false),
        retention: .init(audioRetentionDays: 14, audioQuotaMegabytes: 512)
    )
    let roundTripped = try PersonalProfile.decode(from: full.encoded())
    expect(roundTripped, full, "profile 编码后再解码保持一致")

    let emptyProfile = try PersonalProfile.decode(from: PersonalProfile().encoded())
    expect(emptyProfile, PersonalProfile(), "空 profile 往返")
    expect(emptyProfile.glossary == nil && emptyProfile.speakerBackground == nil, true, "空 profile 不带任何内容")

    let old = try PersonalProfile.decode(from: Data(#"{"glossary":["Alpha"],"engine":{"aliyunRegion":"beijing"}}"#.utf8))
    expect(old.version, 1, "缺少 version 的旧文件按版本 1 读取")
    expect(old.glossary ?? [], ["Alpha"], "旧文件保留已有字段")
    expect(old.speakerBackground == nil && old.insertion == nil && old.retention == nil, true, "旧文件缺失的字段为 nil，不会清空当前值")
    expect(old.engine?.primaryProvider == nil, true, "缺失的子字段为 nil")
    let unknownKeys = try PersonalProfile.decode(from: Data(#"{"version":1,"futureThing":{"a":1},"glossary":[]}"#.utf8))
    expect(unknownKeys.glossary ?? ["x"], [], "未知字段被忽略")
    var newer = false
    do { _ = try PersonalProfile.decode(from: Data(#"{"version":99}"#.utf8)) } catch PersonalProfileError.newerVersion { newer = true }
    expect(newer, true, "更高版本的文件被拒绝而不是误读")

    // Lexicon merge: add missing canonicals and aliases, never remove or demote.
    let existing = [
        PersonalTerm(canonical: "Sonnet", aliases: ["Sonet"], pinned: false),
        PersonalTerm(canonical: "星河", aliases: [], pinned: true, state: .retired),
    ]
    let incoming = PersonalProfile(lexicon: [
        .init(canonical: "sonnet", aliases: ["sonet", "Sonnett"]),
        .init(canonical: "星河", aliases: ["Zephyr", "zephyr"]),
        .init(canonical: "Orbit", aliases: ["Orbyt", " "], pinned: true),
        .init(canonical: "  ", aliases: ["x"]),
    ])
    let upserts = incoming.lexiconUpserts(into: existing)
    expect(upserts.count, 3, "只对有变化的词生成写入")
    expect(upserts.first { $0.canonical == "Sonnet" }?.aliases ?? [], ["Sonet", "Sonnett"], "已有词只补缺失别名，大小写不敏感")
    expect(upserts.first { $0.canonical == "星河" }?.aliases ?? [], ["Zephyr"], "同一导入里重复写法只补一次")
    expect(upserts.first { $0.canonical == "星河" }?.state, .retired, "合并不改变已有词的状态")
    expect(upserts.first { $0.canonical == "Orbit" }?.aliases ?? [], ["Orbyt"], "新词带去空后的别名")
    expect(upserts.first { $0.canonical == "Orbit" }?.pinned ?? false, true, "新词沿用文件里的钉住设置")
    expect(incoming.lexiconUpserts(into: upserts + [existing[1]]).isEmpty, false, "第二次合并以现有词库为准")
    let applied = upserts + existing.filter { term in !upserts.contains { $0.canonical == term.canonical } }
    expect(incoming.lexiconUpserts(into: applied).isEmpty, true, "合并后再次导入同一文件没有变化")
    expect(PersonalProfile.entries(from: existing).map(\.canonical), ["Sonnet"], "导出只含启用中的词")

    // Diff shown before an import.
    let current = PersonalProfile(glossary: ["Alpha"], speakerBackground: "旧", insertion: .init(removeChatTerminalPeriod: false))
    let changes = PersonalProfile.changes(
        current: current,
        incoming: PersonalProfile(glossary: ["alpha", "Beta"], speakerBackground: "旧", insertion: .init(removeChatTerminalPeriod: true))
    )
    expect(changes.map(\.title), ["术语表", "聊天句尾去句号"], "预览只列出会变的项")
    expect(PersonalProfile.changes(current: current, incoming: PersonalProfile()).isEmpty, true, "空文件不改变任何东西")
    let hotkeyProfile = PersonalProfile(hotkey: .init(trigger: "fn"))
    expect(try PersonalProfile.decode(from: hotkeyProfile.encoded()), hotkeyProfile, "触发键随配置导出再导入")
    expect(old.hotkey == nil, true, "旧文件没有触发键时保持当前设置")
    expect(
        PersonalProfile.changes(current: PersonalProfile(hotkey: .init(trigger: "rightOption")), incoming: hotkeyProfile).map(\.title),
        ["触发键"],
        "导入预览列出触发键变化"
    )

    // Interface language: the setting <-> the AppleLanguages value in the app's defaults domain.
    expect(InterfaceLanguage.system.appleLanguages == nil, true, "跟随系统时删除 AppleLanguages")
    expect(InterfaceLanguage.simplifiedChinese.appleLanguages ?? [], ["zh-Hans"], "简体中文写入 zh-Hans")
    expect(InterfaceLanguage.english.appleLanguages ?? [], ["en"], "English 写入 en")
    for language in InterfaceLanguage.allCases {
        expect(InterfaceLanguage(appleLanguages: language.appleLanguages), language, "界面语言写入后读回一致：\(language.rawValue)")
    }
    expect(InterfaceLanguage(appleLanguages: nil), .system, "没有 AppleLanguages 读作跟随系统")
    expect(InterfaceLanguage(appleLanguages: []), .system, "空列表读作跟随系统")
    expect(InterfaceLanguage(appleLanguages: ["zh-Hans-AU", "en"]), .simplifiedChinese, "以第一项为准：zh-Hans-AU")
    expect(InterfaceLanguage(appleLanguages: ["en-US", "zh-Hans-AU"]), .english, "以第一项为准：en-US")
    expect(InterfaceLanguage(appleLanguages: ["fr"]), .system, "不支持的语言读作跟随系统")
    expect(InterfaceLanguage(profileValue: "zh-Hans"), .simplifiedChinese, "配置里的语言名")
    expect(InterfaceLanguage(profileValue: "klingon") == nil, true, "未知语言名不改变设置")
    let interfaceProfile = PersonalProfile(interface: .init(language: "en"))
    expect(try PersonalProfile.decode(from: interfaceProfile.encoded()), interfaceProfile, "界面语言随配置导出再导入")
    expect(old.interface == nil, true, "旧文件没有界面语言时保持当前设置")
    expect(
        PersonalProfile.changes(current: PersonalProfile(interface: .init(language: "system")), incoming: interfaceProfile).map(\.title),
        ["界面语言"],
        "导入预览列出界面语言变化"
    )

    // Terms sent after the lexicon: glossary first, then the starter pack, no duplicates.
    expect(
        ContextTermSources.builtInTerms(glossary: ["Alpha", " ", "beta"], starterPack: ["BETA", "Gamma"]),
        ["Alpha", "beta", "Gamma"],
        "术语尾部：术语表优先，入门词包去重补充"
    )
    expect(ContextTermSources.builtInTerms(glossary: [], starterPack: []), [], "两者都空时不发送任何内置术语")

    let packURL = FileManager.default.temporaryDirectory.appendingPathComponent("starter-\(UUID().uuidString).json")
    try Data(#"{"version":1,"name":"测试词包","terms":["Alpha","Beta"]}"#.utf8).write(to: packURL)
    defer { try? FileManager.default.removeItem(at: packURL) }
    expect(StarterGlossary.load(from: packURL), ["Alpha", "Beta"], "入门词包从 JSON 加载")
    expect(StarterGlossary.load(from: nil), [], "词包资源缺失时返回空")
    expect(StarterGlossary.load(from: URL(fileURLWithPath: "/nonexistent/pack.json")), [], "词包文件不存在时返回空")
} catch {
    failures.append("personal profile 自测抛出错误：\(error)")
}

if failures.isEmpty {
    print("core self-test: \(checkCount) passed")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}
