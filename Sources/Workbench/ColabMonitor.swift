import SwiftUI
import AppKit

// Google 官方 Colab CLI（~/.local/bin/colab）的狀態：開著哪些機器、剩多少運算單元。
// 機器清單直接讀 ~/.config/colab-cli/sessions.json（不連網；token 欄位是機密，完全不讀、不顯示、不記錄）。
// 用量跑 `colab usage`，但只有 token.json 存在（已登入）才跑——沒登入時它會要求互動登入，codenv 絕不能觸發。
// 測試（只在有 --state-dir 時生效）：CODENV_COLAB_DIR 換資料夾、CODENV_COLAB_FAKE_USAGE="12.34,1.76,1" 不跑 colab、--colab-bin 換執行檔。

final class ColabMonitor: ObservableObject {
    static let shared = ColabMonitor()

    struct Machine: Identifiable, Equatable {
        let name: String
        let hardware: String        // 例如 "T4 · STANDARD"
        let lastRun: Date?
        var id: String { name }
    }

    @Published private(set) var machines: [Machine] = []
    @Published private(set) var balance: Double?
    @Published private(set) var ratePerHour: Double?
    @Published private(set) var assignments: Int?
    @Published var busyName: String?    // 正在停止的機器

    /// 閒置超過幾分鐘就標橘字
    static let idleMinutes = 30

    private let isolated = CommandLine.arguments.contains("--state-dir")
    private var dir: String
    private var colabBin: String
    private var fakeUsage: (Double, Double, Int)?
    private var lastMTime: Date?
    private var lastUsage = Date.distantPast
    private var usageBusy = false
    private var timer: Timer?

    private init() {
        let env = ProcessInfo.processInfo.environment
        let args = CommandLine.arguments
        dir = NSString(string: "~/.config/colab-cli").expandingTildeInPath
        colabBin = NSString(string: "~/.local/bin/colab").expandingTildeInPath
        if isolated {
            if let d = env["CODENV_COLAB_DIR"], !d.isEmpty { dir = d }
            if let i = args.firstIndex(of: "--colab-bin"), i + 1 < args.count { colabBin = args[i + 1] }
            if let f = env["CODENV_COLAB_FAKE_USAGE"] {
                let p = f.split(separator: ",").map { Double($0) }
                if p.count == 3, let b = p[0], let r = p[1], let a = p[2] { fakeUsage = (b, r, Int(a)) }
            }
        }
        // 測試掛鉤（只在 --state-dir）：CODENV_COLAB_STOP_AT="秒:名稱" 跳過確認框直接停（--colab-bin 指到假腳本）
        if isolated, let spec = env["CODENV_COLAB_STOP_AT"], let c = spec.firstIndex(of: ":"), let sec = Double(spec[..<c]) {
            let name = String(spec[spec.index(after: c)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.stop(name) }
        }
        reload(force: true)
        // 每 10 秒看一次 sessions.json 有沒有變（便宜的 stat）；用量每 10 分鐘一次
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.reload(force: false) }
    }

    private var sessionsPath: String { dir + "/sessions.json" }
    private var tokenPath: String { dir + "/token.json" }

    /// 讀機器清單；檔案有變、或超過 10 分鐘沒查用量時順便更新用量
    func reload(force: Bool) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: sessionsPath))?[.modificationDate] as? Date
        let changed = mtime != lastMTime
        if changed || force {
            lastMTime = mtime
            let list = Self.parseSessions(path: sessionsPath)
            if list != machines { machines = list }
        }
        if force || changed || Date().timeIntervalSince(lastUsage) >= 600 { refreshUsage() }
    }

    static func parseSessions(path: String) -> [Machine] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [Machine] = []
        for (key, v) in obj {
            guard let d = v as? [String: Any] else { continue }
            let name = (d["name"] as? String) ?? key
            let acc = (d["accelerator"] as? String) ?? "NONE"
            let shape = (d["machine_shape"] as? String) ?? "STANDARD"
            var hw = acc == "NONE" ? "CPU" : acc
            if shape != "STANDARD" { hw += " · " + shape }
            var last: Date?
            if let le = d["last_execution"] as? [Any], let ts = le.last as? String { last = parseDate(ts) }
            out.append(Machine(name: name, hardware: hw, lastRun: last))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Python 的 isoformat 可能沒有時區：當 UTC
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX"); g.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            g.dateFormat = fmt
            if let d = g.date(from: s) { return d }
        }
        return nil
    }

    func refreshUsage() {
        lastUsage = Date()
        if let f = fakeUsage { balance = f.0; ratePerHour = f.1; assignments = f.2; return }
        guard !usageBusy, FileManager.default.fileExists(atPath: tokenPath) else {
            if !FileManager.default.fileExists(atPath: tokenPath), balance != nil { balance = nil; ratePerHour = nil; assignments = nil }
            return
        }
        usageBusy = true
        let bin = colabBin
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = RPShell.run(bin, ["usage"], timeout: 20)
            let parsed = r.status == 0 && !r.timedOut ? Self.parseUsage(r.out) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.usageBusy = false
                if let p = parsed { self.balance = p.0; self.ratePerHour = p.1; self.assignments = p.2 }
            }
        }
    }

    /// 三行：Current balance: 12.34 compute units／Usage rate: 1.76/hr／Active assignments: 1
    static func parseUsage(_ text: String) -> (Double, Double, Int)? {
        func num(_ key: String) -> Double? {
            for line in text.split(separator: "\n") where line.contains(key) {
                guard let c = line.firstIndex(of: ":") else { continue }
                let rest = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                let digits = rest.prefix { "0123456789.-".contains($0) }
                if let v = Double(digits) { return v }
            }
            return nil
        }
        guard let b = num("Current balance"), let r = num("Usage rate"), let a = num("Active assignments") else { return nil }
        return (b, r, Int(a))
    }

    /// 停止一台（呼叫前要先問過使用者）。背景跑 colab stop，跑完重讀
    func stop(_ name: String) {
        guard busyName == nil else { return }
        busyName = name
        let bin = colabBin
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = RPShell.run(bin, ["stop", "-s", name], timeout: 60)
            DispatchQueue.main.async {
                self?.busyName = nil
                self?.reload(force: true)
            }
        }
    }

    /// 閒置分鐘數；沒執行過回 nil
    func idleMinutes(_ m: Machine, now: Date = Date()) -> Int? {
        guard let t = m.lastRun else { return nil }
        return max(0, Int(now.timeIntervalSince(t) / 60))
    }

    static func ago(_ minutes: Int) -> String {
        if minutes < 1 { return L("剛剛") }
        if minutes < 60 { return L("\(minutes) 分鐘前") }
        if minutes < 1440 { return L("\(minutes / 60) 小時前") }
        return L("\(minutes / 1440) 天前")
    }

    /// 確認框；確認才停
    func confirmAndStop(_ m: Machine) {
        let a = NSAlert()
        a.messageText = L("停止 Colab 機器「\(m.name)」？")
        a.informativeText = L("上面的變數和沒下載的檔案都會消失。")
        a.addButton(withTitle: L("停止"))
        a.addButton(withTitle: L("取消"))
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { stop(m.name) }
    }
}

/// 右欄「視窗」分頁的 Colab 膠囊內容
struct ColabPopover: View {
    @ObservedObject private var colab = ColabMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(colab.machines) { m in
                let idle = colab.idleMinutes(m)
                let stale = (idle ?? Int.max) >= ColabMonitor.idleMinutes
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(m.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(m.hardware).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        Button(colab.busyName == m.name ? L("停止中…") : L("停止")) { colab.confirmAndStop(m) }
                            .controlSize(.small).disabled(colab.busyName != nil)
                    }
                    if let idle {
                        Text(stale ? L("閒置 \(idle) 分，還在扣點") : L("最後執行 \(ColabMonitor.ago(idle))"))
                            .font(.system(size: 10.5)).foregroundStyle(stale ? Color.orange : Color.secondary)
                    } else {
                        Text(L("沒執行過，還在扣點")).font(.system(size: 10.5)).foregroundStyle(Color.orange)
                    }
                }
            }
        }
        .padding(10).frame(minWidth: 280)
    }
}
