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
        var preholdOffDelay: TimeInterval = 30    // 螢幕開著、聊天室都做完後，等多久才放掉預擋（防抖）
    }

    static let stopMessage = "使用者闔上螢幕了：做完目前這一段就停，不要開始下一段，等他回來再繼續。"

    let env: LidEnv
    var limits = Limits()
    var now: () -> Date = Date.init
    var enabled: () -> Bool = { true }
    /// 目前「工作中」的聊天室數（假事件測試可以覆蓋）
    var workingCount: () -> Int = { 0 }
    var workingIDs: () -> [UUID] = { [] }
    var sendStop: (UUID) -> Void = { _ in }
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

    private func turnOn(_ t: Date) -> NoSleepResult {
        if noSleepOn { return .ok }
        let r = env.setNoSleep(true)
        if r == .ok {
            noSleepOn = true; lastStatusCheck = t
            try? "{\"since\":\(Int(t.timeIntervalSince1970))}".write(to: markerURL, atomically: true, encoding: .utf8)
        }
        return r
    }

    private func turnOff() {
        guard noSleepOn else { return }
        noSleepOn = false
        if case .failed(let why) = env.setNoSleep(false) { log("改回正常睡眠失敗：\(why)（小幫手會在連線中斷時自己改回）") }
        try? FileManager.default.removeItem(at: markerURL)
    }

    func tick() {
        let t = now()
        let closed = env.lidClosed()
        let on = enabled()
        let working = workingCount()
        let batt = env.battery()
        let lowBattery = batt.map { !$0.onAC && $0.percent < limits.minBattery } ?? false

        // 小幫手可能被別人（別的 codenv 實例、手動 pmset）改回 0：擋著時定期確認，被解除就重新擋
        if noSleepOn, t.timeIntervalSince(lastStatusCheck) >= limits.statusEvery {
            lastStatusCheck = t
            // false＝小幫手那邊被別人改回 0；nil＝連線已經斷了（小幫手重啟／重裝時會發生：11/7 18:07 裝 v7，之後的 off 送到死連線沒回應）
            let st = env.noSleepStatus()
            if st != true {
                let why = st == false ? "被別人解除" : "連線斷了"
                if env.setNoSleep(true) == .ok { log("\(why)，重新擋") }
                else { noSleepOn = false; try? FileManager.default.removeItem(at: markerURL); log("\(why)，重新擋失敗，先當作沒擋") }
            }
        }

        // 螢幕打開了：正式撐著的結束（還在工作中就退回預擋，不切 pmset）
        if !closed, wasClosed {
            wasClosed = false; handledThisClosure = false
            if isHolding { endHold(reason: "螢幕打開了", problem: false, keepNoSleep: true) }
        }
        if closed { wasClosed = true }

        if !on {
            if isHolding { endHold(reason: "設定關閉了這個功能", problem: false, keepNoSleep: false) }
            if noSleepOn { turnOff(); log("結束預擋：設定關閉了這個功能") }
            flushPending(closed: closed)
            return
        }

        if !closed {
            // 預擋：螢幕開著時只要有聊天室工作中就先讓 Mac 不睡（闔蓋睡眠不能否決，等偵測到才擋會來不及）
            if working > 0 && !lowBattery {
                idleSince = nil
                if !noSleepOn {
                    switch turnOn(t) {
                    case .ok: unsupportedLogged = false; log("預擋：有 \(working) 段工作中，先讓 Mac 不睡（螢幕開著，不影響平常使用）")
                    case .unsupported: if !unsupportedLogged { unsupportedLogged = true; log("Battery 的小幫手還沒支援 nosleep（要 v6），闔蓋照常睡眠") }
                    case .failed(let why): if !unsupportedLogged { unsupportedLogged = true; log("預擋失敗（\(why)），闔蓋照常睡眠") }
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
                ids.forEach(sendStop)
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
    private let socketPath = "/var/run/com.local.toolbox.fan.sock"
    private var smc: LidSMC? = LidSMC()

    func lidClosed() -> Bool {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard s != 0 else { return false }
        defer { IOObjectRelease(s) }
        let v = IORegistryEntryCreateCFProperty(s, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
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
    func lidClosed() -> Bool { closed }
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
