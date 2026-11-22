import Foundation
import FoundationModels

// 輸入框的灰字建議（猜使用者下一句）：Claude Code 自己會猜（--prompt-suggestions），
// 其他聊天室（Gemini、ChatGPT、Copilot、本機模型）沒有這個功能，所以每輪結束後另外找模型猜一句：
// Gemini 4 Hydrogen 的聊天室用 Hydrogen 自己（low，經 agy）；其他的用 Apple 內建模型（0.3～1.3 秒，不花額度）。
// 指定這樣分。猜的模型不能用就不猜，不互相退回。設定頁的「建議下一句」關掉也不猜。

enum NextGuess {
    /// 每個聊天室一個：記下這輪使用者打的字和助手說的話，這輪結束就去猜
    final class Tracker {
        private var user = ""                     // 最近送出的一則（沒有回送事件的橋接，就配這個）
        private var pending: [String: String] = [:]   // uuid → 送出的字：等「真的讀進去」的回送事件再配上這一輪
        private var current: String?              // 正在做的這一輪，是哪一則讀進去的
        private var texts: [String] = []
        private var cancel: (() -> Void)?        // 還沒猜完的那個：新的一輪開始就停掉
        private var round = 0                     // 每輪加一：舊的猜測晚到就丟掉

        /// 使用者送出一則（新的一輪開始）：之前還沒猜完的作廢
        func sent(_ text: String, uuid: String? = nil) {
            user = text
            if let uuid { if pending.count >= 20 { pending.removeAll() }; pending[uuid.lowercased()] = text }
            // 上一輪還在做（current 有值）就別動 texts：它的回覆和 result 還會陸續來，不能拿新訊息去配舊回覆
            if current == nil { texts = [] }
            round += 1
            cancel?()
            cancel = nil
        }

        /// 畫面收到的每個事件（Claude Code 格式）都丟進來；這輪結束（result）而且有回覆文字時，猜好呼叫 done。
        /// useHydrogen：這是 Hydrogen 聊天室，用 Hydrogen low 猜
        func saw(_ obj: [String: Any], useHydrogen: Bool, done: @escaping (String) -> Void) {
            switch obj["type"] as? String {
            case "user":
                // 回送：這則訊息真的被讀進去了，新的一輪從這裡開始
                if obj["isReplay"] as? Bool == true, let u = (obj["uuid"] as? String)?.lowercased(), let t = pending.removeValue(forKey: u) {
                    current = t
                    texts = []
                }
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for b in content where b["type"] as? String == "text" {
                    if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { texts.append(t) }
                }
            case "result":
                let user = current ?? self.user      // 有回送就用讀進去的那一則，沒有回送的橋接照舊配最近送的
                current = nil
                guard obj["is_error"] as? Bool != true, !texts.isEmpty else { texts = []; return }
                let reply = texts.joined(separator: "\n\n")
                texts = []
                round += 1
                let r = round
                cancel?()
                let got: (String) -> Void = { [weak self] s in
                    guard let self, self.round == r else { return }
                    self.cancel = nil
                    done(s)
                }
                cancel = useHydrogen ? NextGuess.runHydrogen(user: user, assistant: reply, done: got) : NextGuess.run(user: user, assistant: reply, done: got)
            default:
                break
            }
        }
    }

    static func prompt(user: String, assistant: String) -> String {
        """
        你是輸入法的預測功能。下面是使用者和 AI 助手最近一輪的對話。請猜使用者下一句最可能打的話：繁體中文、使用者自己的口吻、20 字以內（英文單字一個算一字）。只輸出那句話本身，不要引號、不要解釋、不要用任何工具。真的猜不到就只輸出「（無）」。

        使用者：\(user.suffix(1000))
        助手：\(assistant.suffix(2000))
        """
    }

    /// 背景請 Apple 模型猜一句；猜不到（或模型不能用、設定關掉）就不呼叫 done。done 在主執行緒。回傳停掉它的方法
    static func run(user: String, assistant: String, done: @escaping (String) -> Void) -> (() -> Void)? {
        guard Prefs.shared.promptSuggestions, AppleBridge.available else { return nil }
        let prompt = prompt(user: user, assistant: assistant)
        guard #available(macOS 26.4, *) else { return nil }
        let t = Task {
            // 上下文只有約 8K：上面已經截短；被拒答、太長、出錯都當沒猜到
            guard let r = try? await LanguageModelSession().respond(to: prompt), !Task.isCancelled else { return }
            let s = clean(r.content)
            guard !s.isEmpty, !s.hasPrefix("無法") else { return }
            await MainActor.run { done(s) }
        }
        return { t.cancel() }
    }

    static let hydrogenModel = "gemini-4-hydrogen-low"
    private static let swapModeTracker = AgySwapModeTracker()

    /// 測試用：供 `--agy-background-probe next` / `next-cancel` 與單元測試呼叫；回傳 stop closure（若沒啟動則立刻回報 onFinish 並回 nil）。
    static func probeRunHydrogen(
        user: String,
        assistant: String,
        swapConfig: AgySwapConfig = AgySwapConfig.current(),
        tracker: AgySwapModeTracker? = nil,
        ignoreAgyEnabledPref: Bool = false,
        legacyExecutableOverride: String? = nil,
        legacyOnlineOverride: Bool? = nil,
        beforeLegacyLaunchHook: (() -> Void)? = nil,
        onFinish: @escaping (AgyBackgroundProbeOutcome) -> Void,
        done: @escaping (String) -> Void = { _ in }
    ) -> (() -> Void)? {
        runHydrogenInternal(
            user: user,
            assistant: assistant,
            ignoreSuggestionsPref: true,
            ignoreAgyEnabledPref: ignoreAgyEnabledPref,
            swapConfig: swapConfig,
            tracker: tracker ?? Self.swapModeTracker,
            legacyExecutableOverride: legacyExecutableOverride,
            legacyOnlineOverride: legacyOnlineOverride,
            beforeLegacyLaunchHook: beforeLegacyLaunchHook,
            onFinish: onFinish,
            done: done
        )
    }

    /// 背景跑 agy 的 Hydrogen（low）猜一句；agy 沒裝、設定關掉、逾時都不呼叫 done。done 在主執行緒。回傳停掉它的方法
    static func runHydrogen(user: String, assistant: String, done: @escaping (String) -> Void) -> (() -> Void)? {
        runHydrogenInternal(
            user: user,
            assistant: assistant,
            ignoreSuggestionsPref: false,
            ignoreAgyEnabledPref: false,
            swapConfig: AgySwapConfig.current(),
            tracker: Self.swapModeTracker,
            legacyExecutableOverride: nil,
            legacyOnlineOverride: nil,
            beforeLegacyLaunchHook: nil,
            onFinish: nil,
            done: done
        )
    }

    private static func runHydrogenInternal(
        user: String,
        assistant: String,
        ignoreSuggestionsPref: Bool,
        ignoreAgyEnabledPref: Bool,
        swapConfig: AgySwapConfig,
        tracker: AgySwapModeTracker,
        legacyExecutableOverride: String?,
        legacyOnlineOverride: Bool?,
        beforeLegacyLaunchHook: (() -> Void)?,
        onFinish: ((AgyBackgroundProbeOutcome) -> Void)?,
        done: @escaping (String) -> Void
    ) -> (() -> Void)? {
        let legacyExecutablePath = legacyExecutableOverride ?? AgyBridge.executable
        let legacyExecutableReady: Bool
        if let legacyExecutableOverride {
            legacyExecutableReady = FileManager.default.isExecutableFile(atPath: legacyExecutableOverride)
        } else {
            legacyExecutableReady = AgyBridge.canLaunchInCurrentInstance
                && FileManager.default.isExecutableFile(atPath: legacyExecutablePath)
        }
        let allowedByPrefs = ignoreSuggestionsPref || Prefs.shared.promptSuggestions
        let agyAllowed = ignoreAgyEnabledPref || AgyBridge.enabled
        guard allowedByPrefs, agyAllowed,
              (swapConfig.backgroundSwapEnabled || legacyExecutableReady) else {
            onFinish?(AgyBackgroundProbeOutcome(
                launched: false,
                mode: swapConfig.backgroundSwapEnabled ? "swap" : "legacy",
                argv: [],
                exitStatus: nil,
                stoppedByUs: false
            ))
            return nil
        }

        // 在暫存資料夾跑：不讀任何專案檔
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-next-guess")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = AgyNet.newLogFile()
        let agyArgs = ["--model", hydrogenModel, "--print-timeout", "30s", "--log-file", log.path, "-p=" + prompt(user: user, assistant: assistant)]

        let lock = NSLock()
        var stopped = false
        var statusHandle: AgySwapProcessHandle?
        var swapHandle: AgySwapProcessHandle?
        var legacyProcess: Process?
        var legacyStoppedByUs = false
        var finishReported = false

        func reportFinish(_ outcome: AgyBackgroundProbeOutcome) {
            lock.lock()
            if finishReported {
                lock.unlock()
                return
            }
            finishReported = true
            lock.unlock()
            onFinish?(outcome)
        }

        func runLegacy() {
            guard legacyExecutableReady else {
                reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "legacy", argv: [], exitStatus: nil, stoppedByUs: false))
                return
            }
            let online = legacyOnlineOverride ?? AgyNet.canCall()
            lock.lock()
            let cancelledBeforeLaunch = stopped
            lock.unlock()
            guard online, !cancelledBeforeLaunch else {
                reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "legacy", argv: [], exitStatus: nil, stoppedByUs: cancelledBeforeLaunch))
                return
            }

            let executable = legacyExecutablePath
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = agyArgs
            p.currentDirectoryURL = dir
            let out = Pipe()
            // stderr 寫檔不接 Pipe：量大時管線塞滿會讓 agy 卡住
            let errURL = dir.appendingPathComponent("err-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            p.standardOutput = out
            let errFile = try? FileHandle(forWritingTo: errURL)
            p.standardError = errFile ?? FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let d = out.fileHandleForReading.readDataToEndOfFile()
                let e = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: errURL)
                AgyNet.check(log: log)
                lock.lock()
                if legacyProcess === proc { legacyProcess = nil }
                let wasStopped = legacyStoppedByUs
                lock.unlock()
                reportFinish(AgyBackgroundProbeOutcome(
                    launched: true,
                    mode: "legacy",
                    argv: [executable] + agyArgs,
                    exitStatus: proc.terminationStatus,
                    stoppedByUs: wasStopped
                ))
                // 逾時 agy 仍回 0，輸出只有半句：丟掉
                let s = (wasStopped || e.contains("print timeout")) ? "" : clean(String(data: d, encoding: .utf8) ?? "")
                DispatchQueue.main.async { if proc.terminationStatus == 0, !s.isEmpty { done(s) } }
            }

            defer { try? errFile?.close() }
            beforeLegacyLaunchHook?()
            // 修正單第 4 項：先在鎖內檢查 stopped 並登記 legacyProcess，再啟動 p.run()；
            // 若 stop 在啟動前已呼叫則不啟動，在啟動期間或啟動後呼叫則保證 terminate。
            lock.lock()
            if stopped {
                lock.unlock()
                try? FileManager.default.removeItem(at: errURL)
                reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "legacy", argv: [], exitStatus: nil, stoppedByUs: true))
                return
            }
            legacyProcess = p
            do {
                try p.run()
            } catch {
                legacyProcess = nil
                lock.unlock()
                try? FileManager.default.removeItem(at: errURL)
                reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "legacy", argv: [executable] + agyArgs, exitStatus: nil, stoppedByUs: false))
                return
            }
            let stoppedRightAfterLaunch = stopped
            if stoppedRightAfterLaunch {
                legacyStoppedByUs = true
            }
            lock.unlock()
            if stoppedRightAfterLaunch, p.isRunning {
                p.terminate()
            }
        }

        DispatchQueue.global(qos: .utility).async {
            if swapConfig.backgroundSwapEnabled {
                lock.lock()
                let cancelledBeforeStatus = stopped
                lock.unlock()
                if cancelledBeforeStatus {
                    reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "swap", argv: [], exitStatus: nil, stoppedByUs: true))
                    return
                }

                let statusResult = AgySwapClient.fetchStatus(config: swapConfig) { h in
                    lock.lock()
                    statusHandle = h
                    let alreadyStopped = stopped
                    lock.unlock()
                    if alreadyStopped { h.terminate() }
                }
                lock.lock()
                statusHandle = nil
                let cancelledDuringStatus = stopped
                lock.unlock()
                if cancelledDuringStatus {
                    reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "swap", argv: [], exitStatus: nil, stoppedByUs: true))
                    return
                }

                let decision = tracker.evaluate(hasBinary: true, statusResult: statusResult)
                switch decision {
                case .skipRound(let reason, let failures):
                    NSLog("codenv NextGuess：agy-swap status 失敗（第 %d 輪：%@），略過本輪", failures, reason)
                    reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "swap", argv: [], exitStatus: nil, stoppedByUs: false))
                    return

                case .degradedLegacy(let reason, let failures):
                    NSLog("codenv NextGuess：agy-swap status 連續 %d 輪失敗（%@），降級為非換帳號模式", failures, reason)
                    EventLog.log("agy-swap", "NextGuess 連續 \(failures) 輪 status 失敗（\(reason)），降級為非換帳號模式")
                    runLegacy()
                    return

                case .legacy:
                    runLegacy()
                    return

                case .swap(let status):
                    if status.switching || status.recoveryPending {
                        NSLog("codenv NextGuess：agy-swap %@，略過本輪", status.switching ? "switching=true" : "recovery_pending=true")
                        reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "swap", argv: [], exitStatus: nil, stoppedByUs: false))
                        return
                    }
                    guard AgySwapClient.canCallAgy(config: swapConfig) else {
                        reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "swap", argv: [], exitStatus: nil, stoppedByUs: false))
                        return
                    }
                    lock.lock()
                    let cancelledBeforeRun = stopped
                    lock.unlock()
                    if cancelledBeforeRun {
                        reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "swap", argv: [], exitStatus: nil, stoppedByUs: true))
                        return
                    }

                    guard let started = AgySwapClient.startRun(
                        config: swapConfig,
                        agyArguments: agyArgs,
                        workingDirectory: dir,
                        timeout: swapConfig.nextGuessTimeout
                    ) else {
                        reportFinish(AgyBackgroundProbeOutcome(launched: false, mode: "swap", argv: [], exitStatus: nil, stoppedByUs: false))
                        return
                    }
                    defer { try? FileManager.default.removeItem(at: started.anFile) }

                    lock.lock()
                    swapHandle = started.handle
                    let cancelledAfterSpawn = stopped
                    lock.unlock()
                    if cancelledAfterSpawn {
                        started.handle.terminate()
                    }

                    let exec = started.handle.wait()
                    lock.lock()
                    swapHandle = nil
                    lock.unlock()

                    AgyNet.check(log: log)
                    let outcome = AgySwapClient.classifyExit(exec)
                    if case .failed(let code) = outcome, !exec.weTerminated, (code == 143 || code == 137) {
                        NSLog("codenv NextGuess：agy-swap run 遭外部終止（結束碼 %d）", code)
                    }
                    reportFinish(AgyBackgroundProbeOutcome(
                        launched: exec.launched,
                        mode: "swap",
                        argv: exec.argv,
                        exitStatus: exec.launched ? exec.exitCode : nil,
                        stoppedByUs: exec.weTerminated
                    ))
                    if outcome == .ok, !exec.stderr.contains("print timeout") {
                        let s = clean(exec.stdout)
                        if !s.isEmpty {
                            DispatchQueue.main.async { done(s) }
                        }
                    }
                    return
                }
            } else {
                runLegacy()
            }
        }

        return {
            lock.lock()
            stopped = true
            let sh = statusHandle
            let rh = swapHandle
            let lp = legacyProcess
            if lp != nil { legacyStoppedByUs = true }
            lock.unlock()

            if let sh { sh.terminate() }
            if let rh {
                // 規格 3 A：NextGuess stop closure 只對 agy-swap run 送 SIGTERM（killGrace 後才 SIGKILL 群組）
                rh.terminate()
            } else if let lp, lp.isRunning {
                lp.terminate()
            }
        }
    }

    /// 只留第一行、拿掉引號；「（無）」或太長（多半是在解釋）就當沒猜到。長度用 length 算：英文單字一個算一字
    static func clean(_ raw: String) -> String {
        var s = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        for (a, b) in [("「", "」"), ("\"", "\""), ("“", "”"), ("『", "』")] where s.hasPrefix(a) && s.hasSuffix(b) && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if s.contains("（無）") || s.contains("(無)") || length(s) > 40 { return "" }
        return s
    }

    /// 中文一個字算一字，連在一起的英文字母、數字（含 _ . - / 這類寫在名稱裡的符號）整串算一字，空白不算
    static func length(_ s: String) -> Int {
        var n = 0, inWord = false
        for ch in s {
            if ch.isASCII, ch.isLetter || ch.isNumber || "_.-/".contains(ch) {
                if !inWord { n += 1; inWord = true }
            } else {
                inWord = false
                if !ch.isWhitespace { n += 1 }
            }
        }
        return n
    }
}
