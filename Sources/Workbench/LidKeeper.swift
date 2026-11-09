import AppKit
import Foundation
import IOKit
import IOKit.ps

// 「闔蓋做完這一段」：闔上螢幕時若有聊天室正在做事，讓 Mac 先不睡（Battery 的 root 小幫手 v6 的 nosleep
// 連線一斷就自動改回正常），請它們做完目前這一段就停；全部停下、撐滿 1 小時、電量低於 30%、溫度過高就解除。
// 邏輯和硬體分開：LidEnv 可以換成假的（測試用 --lid-sim），不會真的闔蓋或動 pmset。

enum NoSleepResult: Equatable { case ok, unsupported, failed(String) }

protocol LidEnv: AnyObject {
    func lidClosed() -> Bool
    /// 有沒有外接螢幕在線上（接著外接螢幕闔蓋是合蓋模式，Mac 本來就不睡，不算「闔蓋」：）
    func externalDisplayOnline() -> Bool
    func battery() -> (percent: Int, onAC: Bool)?
    func maxTemperature() -> Double?
    func setNoSleep(_ on: Bool) -> NoSleepResult
    /// 蓋子還闔著時解除後要主動讓 Mac 睡：闔蓋睡眠只在「闔上那一刻」觸發，事後把 disablesleep 改回 0 不會補睡（實測）
    func sleepNow()
    /// 小幫手那邊 nosleep 現在是不是開著：true／false；連不上、不支援回 nil
    func noSleepStatus() -> Bool?
}

final class LidKeeper {
    struct Limits {
        var maxHold: TimeInterval = 3600          // 最久撐 1 小時
        var minBattery = 30                       // 沒插電且低於這個電量就解除
        var hotCelsius = 95.0                     // SoC 最高溫度
        var hotSeconds: TimeInterval = 60         // 連續超過多久才算
        var logEvery: TimeInterval = 60           // 撐著時每多久記一行
        var statusEvery: TimeInterval = 30        // 擋著時每多久向小幫手確認一次還擋著
        var preholdRetry: TimeInterval = 30       // 螢幕開著預擋失敗後，隔多久才再試（背景試，不卡主執行緒）
        var preholdOffDelay: TimeInterval = 30    // 螢幕開著、聊天室都做完後，等多久才放掉預擋（防抖）
        var wakeGap: TimeInterval = 10            // 兩次檢查間隔超過這麼久＝Mac 睡過（醒來外接螢幕可能還沒回來，給它一段寬限）
        var externalDropDelay: TimeInterval = 4   // 外接螢幕斷線要持續這麼久才算斷（HDMI 重新協商、換輸入源會掉 1～2 秒）
    }

    static let stopMessage = "使用者闔上螢幕了：做完目前這一段就停，不要開始下一段，等他回來再繼續。"
    static let resumeMessage = "使用者打開螢幕回來了：可以繼續剛才停下的工作。"

    let env: LidEnv
    var limits = Limits()
    var now: () -> Date = Date.init
    var enabled: () -> Bool = { true }
    /// 目前「工作中」的聊天室數（假事件測試可以覆蓋）
    var workingCount: () -> Int = { 0 }
    var workingIDs: () -> [UUID] = { [] }
    var sendStop: (UUID) -> Bool = { _ in false }
    /// 螢幕打開後恢復先前實際收到 stop 的聊天室。
    var resumeEnabled: () -> Bool = { true }
    var sendResume: (UUID) -> Void = { _ in }
    var sessionIsAvailable: (UUID) -> Bool = { _ in false }
    var sessionIsArchived: (UUID) -> Bool = { _ in true }
    var resumeDelay: TimeInterval = 3
    /// 打開螢幕後只有出事才提醒：標題、內文
    var notify: (String, String) -> Void = { _, _ in }
    let logURL: URL
    let markerURL: URL

    private(set) var holdingSince: Date?
    private var lastLog = Date.distantPast
    private var hotSince: Date?
    private var maxTempSeen: Double?
    private var windowMaxTemp: Double?      // 自上一行每分鐘紀錄以來的最高溫（每次檢查都取樣，尖峰才看得到）
    private var wasClosed = false
    private var handledThisClosure = false     // 這次闔蓋已經處理過（撐過、或 helper 不支援）：不重複，也不再撐第二輪
    private var pending: (reason: String, detail: String)?
    var isHolding: Bool { holdingSince != nil }

    init(env: LidEnv, logURL: URL, markerURL: URL) {
        self.env = env
        self.logURL = logURL
        self.markerURL = markerURL
    }

    // MARK: 紀錄

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    func log(_ s: String) {
        let line = "\(Self.stamp.string(from: now())) \(s)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
    }

    // MARK: 還原

    /// 啟動時呼叫：上次留著標記檔（codenv 被砍、當掉）就改回正常睡眠
    func recoverIfNeeded() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        _ = env.setNoSleep(false)
        try? FileManager.default.removeItem(at: markerURL)
        log("上次沒有正常解除闔蓋不睡（codenv 結束或當掉），已改回正常睡眠")
    }

    /// codenv 結束前呼叫
    func shutdown() {
        if isHolding { endHold(reason: "codenv 結束", problem: false, keepNoSleep: false) }
        if noSleepOn { turnOff(); log("結束預擋：codenv 結束") }
    }

    // MARK: 每次檢查（外面用計時器呼叫）

    /// nosleep 現在是不是開著（預擋或正式撐著都算；同一條連線）
    private(set) var noSleepOn = false
    private var idleSince: Date?
    private var unsupportedLogged = false
    private var lastStatusCheck = Date.distantPast
    private var externalNoted = false
    private var lastExternalSeen: Date?
    private var externalSince: Date?
    private var externalCapped = false          // 外接螢幕闔蓋期間撐到上限，已放掉預擋；到蓋子打開或外接螢幕斷線前不再擋
    private var retrying = false
    private var preholdFailedBefore = false     // 預擋失敗過：之後改到背景重試
    private var preholdTrying = false
    private var preholdNextTry = Date.distantPast
    private var statusChecking = false
    private var noSleepGen = 0      // 擋睡眠的狀態每換一次加一：背景結果回來時，不是同一代就不能套用
    private var lastTickAt: Date?
    private var lastRetry = Date.distantPast
    private var retryFailLogged = false
    private(set) var stoppedSessionIDs: Set<UUID> = []
    private var resumeGeneration = 0

    private func turnOn(_ t: Date) -> NoSleepResult {
        if noSleepOn { return .ok }
        let r = env.setNoSleep(true)
        if r == .ok {
            noSleepOn = true; noSleepGen += 1; lastStatusCheck = t
            try? "{\"since\":\(Int(t.timeIntervalSince1970))}".write(to: markerURL, atomically: true, encoding: .utf8)
        }
        return r
    }

    private func turnOff() {
        guard noSleepOn else { return }
        noSleepOn = false; noSleepGen += 1
        if case .failed(let why) = env.setNoSleep(false) { log("改回正常睡眠失敗：\(why)（小幫手會在連線中斷時自己改回）") }
        try? FileManager.default.removeItem(at: markerURL)
    }

    func tick() {
        let t = now()
        let lidShut = env.lidClosed()
        // 外接螢幕每次都取樣；消失要持續 externalDropDelay 秒才算斷（閃斷不能把聊天室叫停）
        // 睡眠期間不會取樣：醒來第一次檢查若外接螢幕還沒回來，不能立刻當成「闔蓋且無外接」叫停聊天室。
        // 睡之前是外接闔蓋狀態，就把「最後看到外接」更新成現在，等 externalDropDelay 再判
        if let last = lastTickAt, t.timeIntervalSince(last) > limits.wakeGap, externalNoted, lidShut {
            lastExternalSeen = t
            log("剛從睡眠醒來，外接螢幕給 \(Int(limits.externalDropDelay)) 秒寬限")
        }
        lastTickAt = t
        if env.externalDisplayOnline() { lastExternalSeen = t }
        let external = lidShut && (lastExternalSeen.map { t.timeIntervalSince($0) < limits.externalDropDelay } ?? false)
        if external != externalNoted {
            externalNoted = external
            hotSince = nil      // 外接模式和撐著共用溫度計時：換模式時清掉，不然殘留的過熱計時會讓下一次一開始就判過熱
            if external { externalSince = t; externalCapped = false; log("蓋子闔著但有外接螢幕在線上，當作沒闔蓋（不通知停止、不主動睡；撐著的上限、電量、溫度照樣管）") }
            else { externalSince = nil; externalCapped = false }
        }
        let closed = lidShut && !external
        let on = enabled()
        let working = workingCount()
        let batt = env.battery()
        let lowBattery = batt.map { !$0.onAC && $0.percent < limits.minBattery } ?? false

        // 小幫手可能被別人（別的 codenv 實例、手動 pmset）改回 0：擋著時定期確認，被解除就重新擋。
        // 確認和重擋都要連 socket（最多等 2 秒），放到背景做，結果回主執行緒套用
        if noSleepOn, !statusChecking, t.timeIntervalSince(lastStatusCheck) >= limits.statusEvery {
            lastStatusCheck = t
            statusChecking = true
            let gen = noSleepGen
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                // false＝小幫手那邊被別人改回 0；nil＝連線已經斷了（小幫手重啟／重裝時會發生：11/7 18:07 裝 v7，之後的 off 送到死連線沒回應）
                let st = self.env.noSleepStatus()
                let rehold: NoSleepResult? = st == true ? nil : self.env.setNoSleep(true)
                DispatchQueue.main.async {
                    self.statusChecking = false
                    guard let r = rehold else { return }
                    let why = st == false ? "被別人解除" : "連線斷了"
                    if gen != self.noSleepGen || !self.noSleepOn {
                        // 背景工作期間主執行緒已經放掉（或換了一輪）：剛擋上的不該留著
                        if r == .ok, !self.noSleepOn {
                            _ = self.env.setNoSleep(false)
                            if self.env.lidClosed(), !self.externalNoted, !self.isHolding { self.log("蓋子還闔著，補送主動睡"); self.env.sleepNow() }
                        }
                        return
                    }
                    if r == .ok { self.log("\(why)，重新擋"); return }
                    // 重擋失敗：舊連線可能還握著擋睡眠。送 off／關掉舊連線（失敗路徑，連不上時立刻返回），之後的「放掉」才真的做得到
                    self.noSleepOn = false; self.noSleepGen += 1
                    _ = self.env.setNoSleep(false)
                    try? FileManager.default.removeItem(at: self.markerURL)
                    self.log("\(why)，重新擋失敗，先當作沒擋（舊連線已放掉）")
                }
            }
        }

        // 螢幕打開了：正式撐著的結束（還在工作中就退回預擋，不切 pmset）
        if closed {
            cancelPendingResume()
        }
        if !closed, wasClosed {
            wasClosed = false; handledThisClosure = false
            if isHolding { endHold(reason: "螢幕打開了", problem: false, keepNoSleep: true) }
            scheduleResume()
        }
        if closed { wasClosed = true }

        if !on {
            cancelPendingResume()
            stoppedSessionIDs.removeAll()
            if isHolding { endHold(reason: "設定關閉了這個功能", problem: false, keepNoSleep: false) }
            if noSleepOn { turnOff(); log("結束預擋：設定關閉了這個功能") }
            flushPending(closed: closed)
            return
        }

        if !closed {
            // 外接螢幕闔蓋（Mac 本來就不睡）：不叫停、不主動睡，但「撐著不睡」的 1 小時上限、電量、溫度照樣管，
            // 不然 Sidecar／遠端桌面等被誤當外接，或螢幕其實關了，放在包包裡會一直悶著
            if external, let since = externalSince, !externalCapped {
                let temp = env.maxTemperature()
                if let temp, temp >= limits.hotCelsius { if hotSince == nil { hotSince = t } } else { hotSince = nil }
                var why: String?
                if t.timeIntervalSince(since) >= limits.maxHold { why = "撐滿 \(Int(limits.maxHold / 60)) 分鐘" }
                else if lowBattery { why = "電量只剩 \(batt?.percent ?? 0)%（低於 \(limits.minBattery)%）" }
                else if let h = hotSince, t.timeIntervalSince(h) >= limits.hotSeconds { why = "溫度過高" }
                if let why {
                    externalCapped = true
                    if noSleepOn { turnOff() }
                    log("外接螢幕闔蓋期間不再擋睡眠：\(why)")
                }
            }
            // 預擋：螢幕開著時只要有聊天室工作中就先讓 Mac 不睡（闔蓋睡眠不能否決，等偵測到才擋會來不及）
            if working > 0 && !lowBattery && !externalCapped {
                idleSince = nil
                if !noSleepOn, !preholdTrying, t >= preholdNextTry {
                    if !preholdFailedBefore {
                        // 第一次：照舊同步試（小幫手正常時很快，行為跟以前一樣）
                        switch turnOn(t) {
                        case .ok: unsupportedLogged = false; log("預擋：有 \(working) 段工作中，先讓 Mac 不睡（螢幕開著，不影響平常使用）")
                        case .unsupported: preholdFailedBefore = true; preholdNextTry = t.addingTimeInterval(limits.preholdRetry); if !unsupportedLogged { unsupportedLogged = true; log("Battery 的小幫手還沒支援 nosleep（要 v6），闔蓋照常睡眠") }
                        case .failed(let why): preholdFailedBefore = true; preholdNextTry = t.addingTimeInterval(limits.preholdRetry); if !unsupportedLogged { unsupportedLogged = true; log("預擋失敗（\(why)），闔蓋照常睡眠") }
                        }
                    } else {
                        // 失敗過：改到背景試（連小幫手的 socket 最多等 2 秒，不要每一拍都卡住主執行緒），失敗後 30 秒才再試
                        preholdTrying = true
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self else { return }
                            let r = self.env.setNoSleep(true)
                            DispatchQueue.main.async {
                                self.preholdTrying = false
                                let t2 = self.now()
                                guard r == .ok else { self.preholdNextTry = t2.addingTimeInterval(self.limits.preholdRetry); return }
                                // 回來時已經不需要擋了（做完、開始闔蓋流程、到上限）：剛擋上的放掉；闔蓋流程自己有擋就不動
                                if self.noSleepOn { return }
                                let lowNow = self.env.battery().map { !$0.onAC && $0.percent < self.limits.minBattery } ?? false      // 回來時重新看電量，不用派發當下的舊值
                                if self.workingCount() > 0, !self.env.lidClosed(), !lowNow, !self.externalCapped {
                                    self.noSleepOn = true; self.noSleepGen += 1; self.lastStatusCheck = t2
                                    try? "{\"since\":\(Int(t2.timeIntervalSince1970))}".write(to: self.markerURL, atomically: true, encoding: .utf8)
                                    self.preholdFailedBefore = false; self.unsupportedLogged = false
                                    self.log("預擋：有 \(self.workingCount()) 段工作中，先讓 Mac 不睡（重試成功）")
                                } else { _ = self.env.setNoSleep(false) }
                            }
                        }
                    }
                }
            } else if noSleepOn {
                if lowBattery && working > 0 {
                    turnOff(); log("結束預擋：電量只剩 \(batt?.percent ?? 0)%（低於 \(limits.minBattery)%），沒插電，照常讓系統管")
                } else {
                    // 全部做完：等一下再放（防抖，不要每則回覆都切 pmset）
                    if idleSince == nil { idleSince = t }
                    if t.timeIntervalSince(idleSince!) >= limits.preholdOffDelay { turnOff(); idleSince = nil; log("結束預擋：聊天室都做完了") }
                }
            }
            flushPending(closed: false)
            return
        }

        // 闔蓋中
        if let since = holdingSince {
            // 撐著時小幫手那邊被解除、重擋又失敗過（noSleepOn 被設回 false）：每 5 秒再試，否則 Mac 會在撐著的期間睡掉
            if !noSleepOn, !retrying, t.timeIntervalSince(lastRetry) >= 5 {
                lastRetry = t
                retrying = true
                let holdAtStart = holdingSince
                // 連小幫手的 socket 最多等 2 秒：放到背景，不卡主執行緒；結果回主執行緒套用
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else { return }
                    let r = self.env.setNoSleep(true)
                    DispatchQueue.main.async {
                        self.retrying = false
                        // 回來時這一輪撐著已經結束（開蓋、做完、到上限）：剛擋上的要放掉，不然會莫名其妙一直不睡
                        if r == .ok, !self.noSleepOn, self.holdingSince == nil || self.holdingSince != holdAtStart {
                            _ = self.env.setNoSleep(false)
                            self.log("重新擋成功時撐著已結束，改回正常睡眠")
                            // 撐著結束那一輪的 sleepnow 可能被這次剛擋上的擋睡眠拒絕：蓋子還闔著、沒外接螢幕就補送
                            if self.env.lidClosed(), !self.externalNoted { self.log("蓋子還闔著，補送主動睡"); self.env.sleepNow() }
                        } else if r == .ok, !self.noSleepOn {
                            let t2 = self.now()
                            self.noSleepOn = true; self.noSleepGen += 1; self.lastStatusCheck = t2
                            try? "{\"since\":\(Int(t2.timeIntervalSince1970))}".write(to: self.markerURL, atomically: true, encoding: .utf8)
                            self.retryFailLogged = false; self.log("撐著時重新擋成功")
                        } else if r != .ok, !self.retryFailLogged { self.retryFailLogged = true; self.log("撐著時重新擋失敗，每 5 秒再試") }
                    }
                }
            }
            let temp = env.maxTemperature()
            if let temp { maxTempSeen = max(maxTempSeen ?? temp, temp); windowMaxTemp = max(windowMaxTemp ?? temp, temp) }
            if let temp, temp >= limits.hotCelsius { if hotSince == nil { hotSince = t } } else { hotSince = nil }
            if working == 0 { endHold(reason: "全部做完了", problem: false, keepNoSleep: false, sleep: true) }
            else if t.timeIntervalSince(since) >= limits.maxHold { endHold(reason: "撐滿 \(Int(limits.maxHold / 60)) 分鐘還沒做完", problem: true, keepNoSleep: false, sleep: true) }
            else if lowBattery { endHold(reason: "電量只剩 \(batt?.percent ?? 0)%（低於 \(limits.minBattery)%）", problem: true, keepNoSleep: false, sleep: true) }
            else if let h = hotSince, t.timeIntervalSince(h) >= limits.hotSeconds {
                endHold(reason: "溫度過高（連續 \(Int(limits.hotSeconds)) 秒 ≥ \(Int(limits.hotCelsius))°C）", problem: true, keepNoSleep: false, sleep: true)
            } else if t.timeIntervalSince(lastLog) >= limits.logEvery {
                lastLog = t
                let peak = windowMaxTemp ?? temp
                windowMaxTemp = nil
                log("撐著 電量 \(batt.map { "\($0.percent)%\($0.onAC ? "（插電）" : "")" } ?? "?") 這一分鐘最高溫 \(peak.map { String(format: "%.1f°C", $0) } ?? "?")（現在 \(temp.map { String(format: "%.1f°C", $0) } ?? "?")） 工作中 \(working) 段")
            }
        } else if !handledThisClosure, working > 0 {
            handledThisClosure = true
            switch turnOn(t) {       // 預擋中就已經開著，這裡不會再切
            case .ok:
                holdingSince = t; lastLog = t; hotSince = nil; maxTempSeen = env.maxTemperature(); windowMaxTemp = maxTempSeen; idleSince = nil
                let ids = workingIDs()
                log("闔蓋，撐著讓它做完這一段：工作中 \(working) 段，已通知 \(ids.count) 個聊天室；最久 \(Int(limits.maxHold / 60)) 分鐘")
                for id in ids {
                    if sendStop(id) { stoppedSessionIDs.insert(id) }
                }
            case .unsupported:
                log("闔蓋時有 \(working) 段工作中，但 Battery 的小幫手還沒支援 nosleep（要 v6），照常睡眠")
            case .failed(let why):
                log("闔蓋時想撐著但失敗（\(why)），照常睡眠")
            }
        } else if noSleepOn, working == 0 {
            // 預擋中闔蓋、但聊天室剛好都做完了：不用撐，讓系統睡
            turnOff(); log("闔蓋時聊天室都已做完，結束預擋，蓋子闔著，主動讓 Mac 睡"); env.sleepNow()
        }
        flushPending(closed: true)
    }

    private func cancelPendingResume() { resumeGeneration += 1 }

    private func scheduleResume() {
        guard !stoppedSessionIDs.isEmpty else { return }
        guard enabled(), resumeEnabled() else { stoppedSessionIDs.removeAll(); return }
        resumeGeneration += 1
        let generation = resumeGeneration
        let delay = resumeDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.resumeGeneration == generation, !self.env.lidClosed() else { return }
            guard self.enabled(), self.resumeEnabled() else { self.stoppedSessionIDs.removeAll(); return }
            let ids = self.stoppedSessionIDs
            for id in ids where self.sessionIsAvailable(id) && !self.sessionIsArchived(id) {
                self.sendResume(id)
            }
            self.stoppedSessionIDs.removeAll()
        }
    }

    private func endHold(reason: String, problem: Bool, keepNoSleep: Bool, sleep: Bool = false) {
        let t = now()
        let mins = holdingSince.map { Int(t.timeIntervalSince($0) / 60) } ?? 0
        let temp = maxTempSeen.map { String(format: "%.1f°C", $0) } ?? "?"
        if !keepNoSleep { turnOff() }
        holdingSince = nil; hotSince = nil
        if sleep { log("蓋子闔著，主動讓 Mac 睡"); env.sleepNow() }
        log("解除闔蓋不睡：\(reason)（撐了約 \(mins) 分鐘，最高溫 \(temp)）\(keepNoSleep && noSleepOn ? "；還在工作中，退回預擋" : "")")
        if problem { pending = ("闔蓋時沒能做完這一段", "\(reason)\n撐了約 \(mins) 分鐘，期間最高溫 \(temp)。聊天室可能停在做到一半的地方，可以接著問。") }
    }

    /// 出事的才提醒，而且等使用者打開螢幕之後
    private func flushPending(closed: Bool) {
        guard let p = pending, !closed else { return }
        pending = nil
        notify(p.reason, p.detail)
    }
}

// MARK: - 真正的硬體

final class RealLidEnv: LidEnv {
    private var fd: Int32 = -1
    private let lock = NSLock()      // 重擋重試在背景執行緒、其他呼叫在主執行緒，fd 要排隊用
    private let socketPath = "/var/run/com.local.toolbox.fan.sock"
    private var smc: LidSMC? = LidSMC()

    func lidClosed() -> Bool {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard s != 0 else { return false }
        defer { IOObjectRelease(s) }
        let v = IORegistryEntryCreateCFProperty(s, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }

    func externalDisplayOnline() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        // active＝真的在顯示的（鏡像組只列一個）；再排除內建的、虛擬的（AirPlay、Sidecar、BetterDisplay 假螢幕、遠端桌面），只剩實體外接螢幕
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return false }
        return ids.prefix(Int(n)).contains {
            Self.isRealExternal(builtin: CGDisplayIsBuiltin($0) != 0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0), asleep: CGDisplayIsAsleep($0) != 0,
                                size: CGDisplayScreenSize($0))
        }
    }

    /// 實體外接螢幕：不是內建的、有真的廠商編號（虛擬螢幕沒有，或是 0xFFFFFFFF 未知）、沒在睡眠
    /// 限制：沒有公開的「是不是虛擬螢幕」API（CGDisplayIsVirtual 不存在）。這裡用「廠商編號不是 0／未知」加「回報了實體尺寸」兩個條件，
    /// 虛擬螢幕通常沒有實體尺寸；有自訂廠商又假報尺寸的假螢幕擋不住，靠外接闔蓋期間的 1 小時／電量／溫度上限兜底
    static func isRealExternal(builtin: Bool, vendor: UInt32, model: UInt32, asleep: Bool, size: CGSize = CGSize(width: 1, height: 1)) -> Bool {
        !builtin && !asleep && vendor != 0 && vendor != 0xFFFF_FFFF && size.width > 0 && size.height > 0
    }

    func battery() -> (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (cur * 100 / max, (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    func maxTemperature() -> Double? { smc?.maxTemperature() }

    private func request(_ fd: Int32, _ line: String) -> String? {
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard write(fd, line + "\n", line.utf8.count + 1) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(decoding: buf[..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connectHelper() -> Int32? {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: Array(socketPath.utf8).prefix(raw.count - 1)) }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(s); return nil }
        return s
    }

    func noSleepStatus() -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, let r = request(fd, "nosleep status") else { return nil }
        if r.hasPrefix("on") { return true }
        if r == "off" { return false }
        return nil
    }

    func sleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// on：開一條連線送 nosleep on，連線留著（小幫手靠它偵測 codenv 結束或當掉就自動改回）；off：送 off 再關掉
    func setNoSleep(_ on: Bool) -> NoSleepResult {
        lock.lock(); defer { lock.unlock() }
        if on {
            guard let s = connectHelper() else { return .unsupported }   // 沒裝小幫手＝同樣照常睡
            let r = request(s, "nosleep on")
            if r == "ok" { if fd >= 0 { close(fd) }; fd = s; return .ok }
            close(s)
            if let r, r.contains("不認得") { return .unsupported }
            return .failed(r ?? "小幫手沒回應")
        }
        let s = fd >= 0 ? fd : connectHelper()
        defer { if let s { close(s) }; fd = -1 }
        guard let s else { return .ok }      // 連不上＝小幫手不在，沒有東西需要還原
        let r = request(s, "nosleep off")
        if r == "ok" { return .ok }
        if let r, r.contains("不認得") { return .ok }
        return .failed(r ?? "小幫手沒回應")
    }
}

/// 唯讀的 SMC 溫度（Tp 系列＝CPU／SoC 核心），取最高。寫法同 Hub 的 DeepSMC
final class LidSMC {
    private var connection: io_connect_t = 0
    private var keys: [UInt32]?
    private static let structSize = 80
    private static let floatType: UInt32 = 0x666C_7420

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func call(command: UInt8, key: UInt32 = 0, dataSize: UInt32 = 0, index: UInt32 = 0) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Self.structSize)
        var output = [UInt8](repeating: 0, count: Self.structSize)
        withUnsafeBytes(of: key) { input.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: dataSize) { input.replaceSubrange(28..<32, with: $0) }
        withUnsafeBytes(of: index) { input.replaceSubrange(44..<48, with: $0) }
        input[42] = command
        var outSize = Self.structSize
        guard IOConnectCallStructMethod(connection, 2, input, Self.structSize, &output, &outSize) == KERN_SUCCESS, output[40] == 0 else { return nil }
        return output
    }
    private func u32(_ b: [UInt8], _ o: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
    private func code(_ n: String) -> UInt32 { n.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }

    private func scan() -> [UInt32] {
        guard let info = call(command: 9, key: code("#KEY")),
              let cnt = call(command: 5, key: code("#KEY"), dataSize: u32(info, 28)) else { return [] }
        let total = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(cnt[48 + $1]) }
        guard total > 0, total < 100_000 else { return [] }
        var out: [UInt32] = []
        for i in 0..<total {
            guard let named = call(command: 8, index: i) else { continue }
            let k = u32(named, 0)
            guard (k >> 16) == 0x5470 else { continue }          // "Tp"
            guard let ki = call(command: 9, key: k), u32(ki, 28) == 4, u32(ki, 32) == Self.floatType else { continue }
            out.append(k)
        }
        return out
    }

    func maxTemperature() -> Double? {
        if keys == nil { keys = scan() }
        let vals = (keys ?? []).compactMap { k -> Double? in
            guard let o = call(command: 5, key: k, dataSize: 4) else { return nil }
            let bits = UInt32(o[48]) | UInt32(o[49]) << 8 | UInt32(o[50]) << 16 | UInt32(o[51]) << 24
            let v = Double(Float(bitPattern: bits))
            return v.isFinite && v > 0 && v < 150 ? v : nil
        }
        return vals.max()
    }
}

/// 假事件（--lid-sim）：不碰硬體；nosleep 的呼叫記進紀錄檔
final class SimLidEnv: LidEnv {
    var closed = false
    var percent = 80
    var onAC = false
    var temp = 50.0
    var helper = "ok"            // ok | unsupported | fail
    var onCall: (String) -> Void = { _ in }
    var external = false
    func lidClosed() -> Bool { closed }
    func externalDisplayOnline() -> Bool { external }
    func battery() -> (percent: Int, onAC: Bool)? { (percent, onAC) }
    func maxTemperature() -> Double? { temp }
    var actualOn = false
    var connDead = false      // 假裝小幫手重啟、連線已斷
    func noSleepStatus() -> Bool? { helper == "ok" && !connDead ? actualOn : nil }
    func sleepNow() { onCall("[假] pmset sleepnow（蓋子闔著，主動睡）") }
    func setNoSleep(_ on: Bool) -> NoSleepResult {
        onCall("[假小幫手] nosleep \(on ? "on" : "off")（\(helper)）")
        if on { connDead = false }
        if !on { actualOn = false; return .ok }
        switch helper { case "unsupported": return .unsupported; case "fail": return .failed("假的失敗"); default: actualOn = true; return .ok }
    }
}
