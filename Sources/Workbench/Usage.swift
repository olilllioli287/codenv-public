import SwiftUI
import Foundation
import Combine

// 右側欄位上面的用量：5 小時剩多少、每週剩多少、Fable 這類模型自己的額度池剩多少。
// 資料來源是 Claude Code 自己的 /usage（claude -p "/usage" --no-session-persistence）：本機查詢、不叫模型、不留對話紀錄，
// 也不用工作台去碰使用者的登入憑證。每 5 分鐘查一次，點一下面板立刻查。
// 有裝 agy（Gemini，AgyBridge.swift）的話也查它的 /usage（agy -p=/usage）：Gemini 和 agy 裡 Claude／GPT 的額度池，另外列一組。
// 有裝 codex（ChatGPT，CodexBridge.swift）的話開一個 codex app-server 問 account/rateLimits/read，問完就關，再列一組。
// 有 gh（GitHub Copilot）的話問 gh api /copilot_internal/user 的 quota_snapshots.chat（免費方案每月 200 次）。
// 右側欄只列「目前這個分頁裡每一格用到的」額度池（沒有別的就只有 Claude Code）；點「用量剩餘」開置中的完整用量頁（UsageSheet）。

struct UsageBucket: Identifiable, Equatable {
    var id: String { label }
    let label: String        // 顯示的名字：5 小時、每週、Fable 每週…
    let used: Int            // 用掉的百分比
    let resets: String       // 什麼時候重置（已經轉成「今天 22:00」「10/24 01:00」）
    var remaining: Int { max(0, 100 - used) }
}

final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()
    @Published var buckets: [UsageBucket] = []
    @Published var agyBuckets: [UsageBucket] = []
    @Published var codexBuckets: [UsageBucket] = []
    @Published var codexResets = 0      // Codex 送的「全部重置」還有幾次沒用
    @Published var copilotBuckets: [UsageBucket] = []
    @Published var copilotNote = ""     // 「剩 199／200 次」
    @Published var updated: Date?
    @Published var loading = false
    @Published var error: String?
    private var timer: Timer?

    private init() {
        refresh()
        // 網路回來（例如斷網一陣子）：馬上補查一次，不用等下一輪
        AgyNet.start()
        NotificationCenter.default.addObserver(forName: AgyNet.back, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        restartTimer()
        sink = Prefs.shared.$usageMinutes.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.restartTimer() }
    }

    private var sink: AnyCancellable?
    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, Prefs.shared.usageMinutes) * 60), repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 三邊同時查（各自最多 60 秒）
            var agyOut: String?
            var codexOut: [String: Any]?
            var copilotOut: String?
            let g = DispatchGroup()
            // 連不上 Google 就不查 agy：斷網時 agy 會一直開瀏覽器登入頁（AgyNet.canCall）
            if AgyBridge.enabled, AgyBridge.executable != "agy", AgyNet.canCall() {
                g.enter()
                DispatchQueue.global(qos: .utility).async {
                    let log = AgyNet.newLogFile()
                    agyOut = Self.run(AgyBridge.executable, ["-p=/usage", "--print-timeout", "60s", "--log-file", log.path])
                    AgyNet.check(log: log)
                    g.leave()
                }
            }
            if CodexBridge.installed {
                g.enter()
                DispatchQueue.global(qos: .utility).async { codexOut = Self.runCodex(); g.leave() }
            }
            if Self.ghPath != nil {
                g.enter()
                DispatchQueue.global(qos: .utility).async { copilotOut = Self.run(Self.ghPath!, ["api", "/copilot_internal/user"]); g.leave() }
            }
            let out = Self.run("claude", ["-p", "/usage", "--no-session-persistence"])
            g.wait()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                if let agyOut { let a = Self.parseAgy(agyOut); if !a.isEmpty { self.agyBuckets = a } }
                if let codexOut {
                    let c = Self.parseCodex(codexOut)
                    if !c.buckets.isEmpty { self.codexBuckets = c.buckets; self.codexResets = c.resets }
                }
                if let copilotOut, let c = Self.parseCopilot(copilotOut) { self.copilotBuckets = c.buckets; self.copilotNote = c.note }
                let parsed = out.map(Self.parse) ?? []
                if parsed.isEmpty {
                    self.error = "查不到用量"
                } else {
                    self.buckets = parsed
                    self.updated = Date()
                    self.error = nil
                }
            }
        }
    }

    private static func run(_ command: String, _ args: [String]) -> String? {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec " + ([q(command)] + args.map(q)).joined(separator: " ")]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.environment = environment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice   // 沒人讀的管子塞滿會卡住
        guard (try? p.run()) != nil else { return nil }
        // 卡住（要登入、網路不通）最多等 60 秒，不然之後的查詢全被擋住
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func environment() -> [String: String] {
        var env: [String: String] = [:]
        for kv in Workspace.environment() { if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) } }
        return env
    }

    /// Codex 沒有印用量的指令，要走 app-server 的 JSON-RPC：initialize → initialized → account/rateLimits/read，拿到回覆就關
    private static func runCodex() -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec codex app-server"]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.environment = environment()
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if p.isRunning { p.terminate() } }
        let requests: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codenv", "version": "0"]]],
            ["method": "initialized"],
            ["id": 2, "method": "account/rateLimits/read"],
        ]
        for r in requests {
            guard let d = try? JSONSerialization.data(withJSONObject: r) else { continue }
            try? input.fileHandleForWriting.write(contentsOf: d + Data("\n".utf8))
        }
        var buffer = Data()
        var result: [String: Any]?
        reading: while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }   // 結束了（或 60 秒到被關掉）
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<nl])
                buffer = Data(buffer[(nl + 1)...])
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], o["id"] as? Int == 2 {
                    result = o["result"] as? [String: Any]
                    break reading
                }
            }
        }
        try? input.fileHandleForWriting.close()
        if p.isRunning { p.terminate() }
        return result
    }

    /// account/rateLimits/read 的回覆：每個額度（limitId）有 primary、secondary 兩個時段，各自用掉幾 %、多久一輪、什麼時候重置
    /// 免費方案只有一個 30 天的（primary，windowDurationMins 43200）
    static func parseCodex(_ r: [String: Any]) -> (buckets: [UsageBucket], resets: Int) {
        var limits = (r["rateLimitsByLimitId"] as? [String: [String: Any]]).map { Array($0.values) } ?? []
        if limits.isEmpty, let one = r["rateLimits"] as? [String: Any] { limits = [one] }
        limits.sort { ($0["limitId"] as? String == "codex" ? 0 : 1, $0["limitId"] as? String ?? "") < ($1["limitId"] as? String == "codex" ? 0 : 1, $1["limitId"] as? String ?? "") }
        var out: [UsageBucket] = []
        for l in limits {
            // 主要那個（codex）不加名字；其他模型自己的額度才在前面寫名字
            let name = l["limitId"] as? String == "codex" ? nil : (l["limitName"] as? String ?? l["limitId"] as? String)
            for key in ["primary", "secondary"] {
                guard let w = l[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
                let span = mins == 300 ? "5 小時" : mins == 10080 ? "每週" : mins >= 1440 ? "\(mins / 1440) 天" : mins > 0 ? "\(mins / 60) 小時" : key
                let resets = (w["resetsAt"] as? NSNumber).map { when(Date(timeIntervalSince1970: $0.doubleValue)) } ?? ""
                out.append(UsageBucket(label: [name, span].compactMap { $0 }.joined(separator: " "), used: Int(used.rounded()), resets: resets))
            }
        }
        let resets = ((r["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? NSNumber)?.intValue ?? 0
        return (out, resets)
    }

    /// gh 裝在 Homebrew（登入 shell 的 PATH 不一定有）；沒裝就不查 Copilot
    static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// gh api /copilot_internal/user：quota_snapshots.chat 是對話的額度（免費方案 200 次／月），quota_reset_date_utc 什麼時候重置
    static func parseCopilot(_ text: String) -> (buckets: [UsageBucket], note: String)? {
        guard let d = text.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let chat = (o["quota_snapshots"] as? [String: Any])?["chat"] as? [String: Any],
              chat["unlimited"] as? Bool != true, let total = (chat["entitlement"] as? NSNumber)?.intValue, total > 0 else { return nil }
        let left = (chat["remaining"] as? NSNumber)?.intValue ?? 0
        let pct = (chat["percent_remaining"] as? NSNumber)?.doubleValue ?? Double(left) / Double(total) * 100
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resets = (o["quota_reset_date_utc"] as? String).flatMap { iso.date(from: $0) }.map(when) ?? (o["quota_reset_date"] as? String ?? "")
        return ([UsageBucket(label: "每月", used: Int((100 - pct).rounded()), resets: resets)], "剩 \(left)／\(total) 次")
    }

    /// 重置時間：今天、明天寫字，其他寫日期
    static func when(_ d: Date) -> String {
        let o = DateFormatter()
        o.dateFormat = Calendar.current.isDateInToday(d) ? "'今天' HH:mm" : (Calendar.current.isDateInTomorrow(d) ? "'明天' HH:mm" : "M/d HH:mm")
        return o.string(from: d)
    }

    /// 不顯示的額度池：Fable 預設不列（10/22）
    static let hidden = ["Fable"]

    /// 解析「Current session: 20% used · resets Oct 22 at 10pm (Asia/Taipei)」這種行
    static func parse(_ text: String) -> [UsageBucket] {
        let re = try! NSRegularExpression(pattern: #"^Current ([^:]+): (\d+)% used(?: · resets (.+?))?(?: \(([^)]+)\))?\s*$"#, options: [.anchorsMatchLines])
        var out: [UsageBucket] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            func g(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
            guard let what = g(1), let used = g(2).flatMap(Int.init) else { continue }
            let label: String
            if what == "session" { label = "5 小時" }
            else if what.hasPrefix("week (all") { label = "每週" }
            else if what.hasPrefix("week ("), let name = what.split(separator: "(").last?.dropLast() { label = "\(name) 每週" }
            else { label = what }
            if hidden.contains(where: { label.hasPrefix($0) }) { continue }
            out.append(UsageBucket(label: label, used: used, resets: g(3).map { friendly($0, zone: g(4)) } ?? ""))
        }
        return out
    }

    /// agy 的 /usage：一行一個額度池，用 tab 分開「哪一組、名稱、剩多少、什麼時候重置（ISO 時間）」
    /// 例如「Gemini Models	Five Hour Limit Remaining	99%	2026-10-23T16:47:42Z」
    static func parseAgy(_ text: String) -> [UsageBucket] {
        let iso = ISO8601DateFormatter()
        var out: [UsageBucket] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3, let left = Int(f[2].replacingOccurrences(of: "%", with: "")) else { continue }
            // 名字要短，右側欄窄（「Gemini 4 Argon 每週」會被截掉）
            let group = f[0] == "Gemini Models" ? "Gemini" : f[0] == "Claude and GPT models" ? "Claude" : f[0].replacingOccurrences(of: "Gemini 4 ", with: "")
            let span = f[1].contains("Five Hour") ? "5 小時" : f[1].contains("Weekly") ? "每週" : f[1]
            var resets = ""
            if f.count >= 4, let d = iso.date(from: f[3]) { resets = when(d) }
            out.append(UsageBucket(label: "\(group) \(span)", used: 100 - left, resets: resets))
        }
        // 跟上面 Claude Code 那組一樣：同一組 5 小時在前、每週在後
        let rank = { (b: UsageBucket) -> Int in (b.label.hasPrefix("Gemini") ? 0 : b.label.hasPrefix("Claude") ? 10 : 20) + (b.label.hasSuffix("5 小時") ? 0 : 1) }
        return out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// 「Oct 22 at 10pm」→「今天 22:00」；「Oct 24 at 1am」→「10/24 01:00」
    static func friendly(_ s: String, zone: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        let year = Calendar.current.component(.year, from: Date())
        for fmt in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s + " \(year)") { return when(d) }
        }
        return s
    }
}

/// 一組額度池（照模型的來源分）：右側欄只列目前分頁用到的組，完整用量頁全部列
enum UsagePool: String, CaseIterable {
    case cc, gemini, claudeAgy, codex, copilot, local
    var title: String {
        switch self {
        case .cc: "Claude Code"
        case .gemini: "Gemini（agy）"
        case .claudeAgy: "agy 裡的 Claude／GPT"
        case .codex: "ChatGPT（Codex）"
        case .copilot: "GitHub Copilot"
        case .local: "本機模型"
        }
    }
    /// 名字左邊的圖示（跟模型清單分頁同一套）
    var icon: ModelTab { switch self { case .cc, .claudeAgy: .claude; case .gemini: .gemini; case .codex: .chatgpt; case .copilot: .copilot; case .local: .local } }

    /// 對話存的模型代號 → 顯示名稱（agy:gemini-3.8-flash-medium → Gemini 3.8 Flash）；nil＝Claude Code 的預設
    static func modelName(_ model: String?) -> String {
        guard let m = model, !m.isEmpty else {
            let k = ModelChoice.known, d = k.first { $0.value == "default" }
            return k.first { $0.resolved == d?.resolved && $0.value != "default" }?.name ?? "Claude（預設）"
        }
        if m.hasPrefix("agy:") { return AgyBridge.name(String(m.dropFirst(4))) }
        if m.hasPrefix("codex:") { return CodexBridge.name(String(m.dropFirst(6))) }
        if m.hasPrefix("copilot:") { return CopilotBridge.name(String(m.dropFirst(8))) }
        if m.hasPrefix("local:apple:") { return AppleBridge.name(String(m.dropFirst(12))) }
        if m.hasPrefix("local:mlx:") { return LocalBridge.name(String(m.dropFirst(10))) }
        if m.hasPrefix("local:") { return LocalModel.all.first { "local:" + $0.id.uuidString == m }?.name ?? "本機模型" }
        let k = ModelChoice.known
        if m == "default" { return modelName(nil) }
        return k.first { $0.value == m }?.name ?? m
    }

    /// 某格聊天室的模型用哪一組（沒設模型、終端機格＝Claude Code）；Argon 另外有自己的每週額度
    static func of(model: String?) -> (pool: UsagePool, argon: Bool) {
        let m = (model ?? "").lowercased()
        if m.hasPrefix("agy:") { return m.contains("claude") || m.contains("gpt") ? (.claudeAgy, false) : (.gemini, m.contains("argon")) }
        if m.hasPrefix("codex:") { return (.codex, false) }
        if m.hasPrefix("copilot:") { return (.copilot, false) }
        if m.hasPrefix("local:") { return (.local, false) }   // 本機（LFM、Apple 模型、自訂端點）：不花任何額度
        return (.cc, false)
    }
}

struct UsageRow: Identifiable {
    var id: String { pool.rawValue + "|" + bucket.label }
    let pool: UsagePool
    let label: String       // 組內的名字（圖示已經看得出是誰，前面的「Gemini」「Claude」拿掉）
    let bucket: UsageBucket
}

extension UsageMonitor {
    /// 某一組的每一列；argon＝false 時不列 Argon 自己那條
    func rows(_ pool: UsagePool, argon: Bool = true) -> [UsageRow] {
        switch pool {
        case .cc: return buckets.map { UsageRow(pool: pool, label: $0.label, bucket: $0) }
        case .gemini:
            return agyBuckets.filter { !$0.label.hasPrefix("Claude") && (argon || !$0.label.hasPrefix("Argon")) }
                .map { UsageRow(pool: pool, label: $0.label.replacingOccurrences(of: "Gemini ", with: ""), bucket: $0) }
        case .claudeAgy:
            return agyBuckets.filter { $0.label.hasPrefix("Claude") }
                .map { UsageRow(pool: pool, label: $0.label.replacingOccurrences(of: "Claude ", with: "") + " (agy)", bucket: $0) }
        case .codex: return codexBuckets.map { UsageRow(pool: pool, label: $0.label, bucket: $0) }
        case .copilot: return copilotBuckets.map { UsageRow(pool: pool, label: $0.label, bucket: $0) }
        case .local: return []
        }
    }
    /// 這組底下的附註（Codex 的免費重置次數、Copilot 剩幾次）
    func note(_ pool: UsagePool) -> String? {
        switch pool {
        case .codex: return codexResets > 0 ? "另有 \(codexResets) 次免費全部重置" : nil
        case .copilot: return copilotNote.isEmpty ? nil : copilotNote
        case .local: return "本機模型：在這台 Mac 上跑，不花額度"
        default: return nil
        }
    }
}

extension Store {
    /// 這個分頁裡用這個額度池的格子：模型名稱 → 哪幾格（右側欄「使用中」那行）
    func modelsInCurrentWindow(_ pool: UsagePool) -> [(model: String, titles: [String])] {
        var out: [(model: String, titles: [String])] = []
        for id in currentWindow?.root?.leaves ?? [] {
            guard let c = conversation(id), !c.isBrowser, UsagePool.of(model: c.terminal == true ? nil : c.model).pool == pool else { continue }
            let m = displayModel(id)
            if let i = out.firstIndex(where: { $0.model == m }) { out[i].titles.append(c.title) } else { out.append((m, [c.title])) }
        }
        // 背景跑的（本機模型自動壓縮請 Haiku 整理摘要）：算在 Claude Code 的額度
        if pool == .cc {
            for id in currentWindow?.root?.leaves ?? [] {
                guard let m = backgroundModel[id], let c = conversation(id) else { continue }
                out.append((m, [c.title]))
            }
        }
        return out
    }

    /// 目前這個分頁裡每一格用到的額度池（照第一次出現的順序；沒有別的就只有 Claude Code）
    var usagePoolsInCurrentWindow: [(pool: UsagePool, argon: Bool)] {
        var out: [(pool: UsagePool, argon: Bool)] = []
        for id in currentWindow?.root?.leaves ?? [] {
            guard let c = conversation(id), !c.isBrowser else { continue }   // 瀏覽器不花額度
            let p = UsagePool.of(model: c.terminal == true ? nil : c.model)
            if let i = out.firstIndex(where: { $0.pool == p.pool }) { out[i].argon = out[i].argon || p.argon } else { out.append(p) }
        }
        if !out.contains(where: { $0.pool == .cc }), (currentWindow?.root?.leaves ?? []).contains(where: { backgroundModel[$0] != nil }) { out.append((.cc, false)) }
        if out.isEmpty { out = [(.cc, false)] }
        return out.sorted { UsagePool.allCases.firstIndex(of: $0.pool)! < UsagePool.allCases.firstIndex(of: $1.pool)! }
    }
}

/// 一列：圖示＋名字＋剩幾 %＋進度條＋什麼時候重置（右側欄和完整用量頁共用）
struct UsageRowView: View {
    @Environment(\.uiScale) private var s
    let row: UsageRow
    var body: some View {
        let b = row.bucket
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                if let img = row.pool.icon.image {
                    Image(nsImage: img).resizable().renderingMode(row.pool.icon.monochrome ? .template : .original)
                        .aspectRatio(contentMode: .fit).frame(width: 13 * s, height: 13 * s).foregroundStyle(.secondary)
                }
                Text(row.label).font(.system(size: 12 * s)).lineLimit(1)
                Spacer()
                Text("\(b.remaining)%").font(.system(size: 15 * s, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(UsageRowView.color(b.remaining))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(UsageRowView.color(b.remaining)).frame(width: g.size.width * CGFloat(b.remaining) / 100)
                }
            }
            .frame(height: 5)
            if !b.resets.isEmpty { Text(b.resets + " 重置").font(.system(size: 11 * s)).foregroundStyle(.tertiary) }
        }
    }
    /// 剩兩成以下紅，其他綠
    static func color(_ remaining: Int) -> Color { remaining <= 20 ? .red : .green }
}

struct UsagePanel: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var m: UsageMonitor
    @ObservedObject var store: Store
    var compact: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryBlock()
            HStack {
                // 點「用量剩餘」：置中打開完整用量頁（每一組都列）
                Button(action: { UsageSheet.toggle() }) {
                    HStack(spacing: 4) {
                        Text("用量剩餘").font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9 * s, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("看全部的用量（Claude、Gemini、ChatGPT、Copilot）")
                Spacer()
                if m.loading { ProgressView().controlSize(.mini) }
                else {
                    Button(action: { m.refresh() }) { Image(systemName: "arrow.clockwise").font(.system(size: 11 * s)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("現在重新查")
                }
            }
            // 只列目前這個分頁裡每一格用到的額度池（換模型、換分頁就跟著變）
            ForEach(store.usagePoolsInCurrentWindow, id: \.pool) { p in
                ForEach(m.rows(p.pool, argon: p.argon)) { r in UsageRowView(row: r) }
                // 使用者 10/24：這個池是哪些格、哪個模型在用
                ForEach(store.modelsInCurrentWindow(p.pool), id: \.model) { u in
                    // 聊天室名字放下一行（使用者 10/25：括號被拆在兩行中間不好讀）
                    Text("使用中：\(u.model)\n（\(u.titles.joined(separator: "、"))）")
                        .font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let n = m.note(p.pool) { Text(n).font(.system(size: 11 * s)).foregroundStyle(.tertiary) }
            }
            if m.buckets.isEmpty && !m.loading {
                Text(m.error ?? "查詢中…").font(.system(size: 12 * s)).foregroundStyle(.tertiary)
            }
            ContextBlock(store: store, compact: compact)
            ActivityBlock(store: store)
            Spacer(minLength: 0)
            if let u = m.updated {
                Text("更新於 " + u.formatted(date: .omitted, time: .shortened)).font(.system(size: 10 * s)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 完整用量頁：每一組都列（有資料的），組名前面有圖示
struct UsageFullPage: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var m: UsageMonitor
    var scroll = true

    var body: some View {
        Group {
            if scroll { ScrollView { content } } else { content }
        }
        .frame(width: 380 * s)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("全部的用量").font(.system(size: 16 * s, weight: .semibold))
                Spacer()
                if m.loading { ProgressView().controlSize(.small) }
                else {
                    Button(action: { m.refresh() }) { Image(systemName: "arrow.clockwise").font(.system(size: 12 * s)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("現在重新查")
                }
            }
            ForEach(UsagePool.allCases, id: \.self) { p in
                let rows = m.rows(p)
                if !rows.isEmpty {
                    HStack(spacing: 6) {
                        if let img = p.icon.image {
                            Image(nsImage: img).resizable().renderingMode(p.icon.monochrome ? .template : .original)
                                .aspectRatio(contentMode: .fit).frame(width: 15 * s, height: 15 * s)
                        }
                        Text(p.title).font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                    ForEach(rows) { r in UsageRowView(row: r) }
                    if let n = m.note(p) { Text(n).font(.system(size: 11 * s)).foregroundStyle(.tertiary) }
                }
            }
            if let u = m.updated {
                Text("更新於 " + u.formatted(date: .omitted, time: .shortened) + "　按 Esc 或點外面關掉").font(.system(size: 10 * s)).foregroundStyle(.tertiary).padding(.top, 4)
            }
        }
        .padding(18)
    }
}

/// 完整用量頁的浮動視窗：置中在主視窗上，點外面或按 Esc 關掉；再點一次「用量剩餘」也會關
enum UsageSheet {
    private static weak var panel: FloatingPanel?
    private static var closedAt = Date.distantPast

    static func toggle() {
        if let p = panel, p.isVisible { p.close(); return }
        // 點「用量剩餘」想關掉：面板在按下時已經自己關了，放開時別又打開
        if Date().timeIntervalSince(closedAt) < 0.4 { return }
        guard let win = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        let scale = UIScale.shared.f
        let host = NSHostingView(rootView: UsageFullPage(m: .shared).environment(\.uiScale, scale))
        host.sizingOptions = []
        // 量高度：不捲動的版本多高就多高，最多主視窗的 85%
        let natural = NSHostingView(rootView: UsageFullPage(m: .shared, scroll: false).environment(\.uiScale, scale)).fittingSize
        let size = NSSize(width: natural.width, height: min(natural.height, win.frame.height * 0.85))
        let f = win.frame
        let p = FloatingPanel(content: host)
        p.onClose = { closedAt = Date() }
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        win.addChildWindow(p, ordered: .above)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
    /// 測試用：現在開著的那個
    static var current: NSPanel? { panel }
}
