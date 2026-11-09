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
    var resetAt: Date? = nil // 重置時間的原始日期（額度衝刺偵測重置用；查不到就 nil）
    var remaining: Int { max(0, 100 - used) }
}

struct MagpieAccountQuota: Identifiable {
    let id: String
    let name: String
    let buckets: [String: UsageBucket]
}

enum UsageLog {
    struct Observation {
        let pool: String
        let kind: String
        let remaining: Int
        let total: Int?
        let resetAt: Date?
    }

    private struct LatestValue {
        let kind: String
        let remaining: Int
        let total: Int?
        let resetAt: Date?
    }

    private static let queue = DispatchQueue(label: "codenv.usage-log")
    private static let limit = 5 * 1024 * 1024
    private static var latestByPool: [String: LatestValue]?

    static func percentages(_ buckets: [UsageBucket], source: String) -> [Observation] {
        buckets.map {
            Observation(pool: "\(source) · \($0.label)", kind: "percent", remaining: $0.remaining, total: 100, resetAt: $0.resetAt)
        }
    }

    static func record(_ observations: [Observation], at date: Date = Date()) {
        guard !observations.isEmpty else { return }
        queue.async {
            do {
                let url = try fileURL()
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var previous = try latestByPool ?? latestValues(active: url, archive: archiveURL(for: url))
                var lines: [Data] = []
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                for item in observations {
                    if let last = previous[item.pool],
                       last.kind == item.kind, last.remaining == item.remaining,
                       last.total == item.total, last.resetAt == item.resetAt {
                        continue
                    }
                    var row: [String: Any] = [
                        "timestamp": iso.string(from: date),
                        "pool": item.pool,
                        "kind": item.kind,
                        "remaining": item.remaining
                    ]
                    if let total = item.total { row["total"] = total }
                    row["resetAt"] = item.resetAt.map(iso.string(from:)) ?? NSNull()
                    var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    data.append(10)
                    lines.append(data)
                    previous[item.pool] = LatestValue(kind: item.kind, remaining: item.remaining, total: item.total, resetAt: item.resetAt)
                }
                if !lines.isEmpty && !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                if !lines.isEmpty {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    for line in lines { try handle.write(contentsOf: line) }
                    try handle.close()
                }
                if FileManager.default.fileExists(atPath: url.path) { try rotateIfNeeded(url) }
                latestByPool = previous
            } catch {
                NSLog("codenv usage-log 寫入失敗：%@", String(describing: error))
            }
        }
    }

    static func flushForTesting() {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        queue.sync {}
    }

    private static func fileURL() throws -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--state-dir") {
            guard i + 1 < args.count, !args[i + 1].isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            return URL(fileURLWithPath: args[i + 1], isDirectory: true).appendingPathComponent("usage-log.jsonl")
        }
        return Edition.support("usage-log.jsonl")
    }

    private static func archiveURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("usage-log.1.jsonl")
    }

    private static func latestValues(active: URL, archive: URL) throws -> [String: LatestValue] {
        var result: [String: LatestValue] = [:]
        // The archive is older. Scan the active tail first, then the archive tail only for pools
        // that have no observation in the active file.
        for url in [active, archive] where FileManager.default.fileExists(atPath: url.path) {
            forEachTailLineReverse(url, maximumBytes: limit) { line in
                guard let data = line.data(using: .utf8),
                      let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let pool = row["pool"] as? String, result[pool] == nil,
                      let kind = row["kind"] as? String,
                      let remaining = row["remaining"] as? Int else { return true }
                result[pool] = LatestValue(kind: kind, remaining: remaining, total: row["total"] as? Int, resetAt: date(row["resetAt"]))
                return result.count < 1_000
            }
            if result.count >= 1_000 { break }
        }
        return result
    }

    /// Visit complete lines from the file tail backwards. Memory use is bounded by one chunk and
    /// the largest line; no history-sized String or array is created.
    private static func forEachTailLineReverse(_ url: URL, maximumBytes: Int, visit: (String) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        let startOffset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        var scanStart = startOffset
        if startOffset > 0 {
            do {
                try handle.seek(toOffset: startOffset - 1)
                if try handle.read(upToCount: 1)?.first == 10 { scanStart = startOffset }
            } catch { return }
        }
        var cursor = size
        var trailing = Data()
        while cursor > scanStart {
            let count = Int(min(UInt64(64 * 1024), cursor - scanStart))
            cursor -= UInt64(count)
            do { try handle.seek(toOffset: cursor) } catch { return }
            guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else { return }
            let data = chunk + trailing
            var end = data.count
            while let newline = data[..<end].lastIndex(of: 10) {
                let line = data[(newline + 1)..<end]
                if !line.isEmpty, !visit(String(decoding: line, as: UTF8.self)) { return }
                end = newline
            }
            trailing = Data(data[..<end])
            if cursor == scanStart {
                // If the scan starts at the file beginning, the remaining bytes are a complete line.
                if scanStart == 0, !trailing.isEmpty { _ = visit(String(decoding: trailing, as: UTF8.self)) }
                // Otherwise trailing is a partial first record and is intentionally discarded.
            }
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func rotateIfNeeded(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > limit else { return }
        let archive = archiveURL(for: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 1 else { return }
        let midpoint = size / 2
        var splitOffset = midpoint
        try handle.seek(toOffset: midpoint)
        // Finish the line intersecting the midpoint. offset() is the exact byte split, even
        // when the line spans multiple chunks.
        while splitOffset < size {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            if let newline = chunk.firstIndex(of: 10) {
                splitOffset += UInt64(newline + 1)
                break
            }
            splitOffset += UInt64(chunk.count)
        }
        guard splitOffset > 0, splitOffset < size else { return }
        let archiveTemp = archive.deletingLastPathComponent().appendingPathComponent(".usage-log.1.\(UUID().uuidString).tmp")
        let activeTemp = url.deletingLastPathComponent().appendingPathComponent(".usage-log.\(UUID().uuidString).tmp")
        try? FileManager.default.removeItem(at: archiveTemp)
        try? FileManager.default.removeItem(at: activeTemp)
        try streamRange(handle, from: 0, to: splitOffset, into: archiveTemp)
        try streamRange(handle, from: splitOffset, to: size, into: activeTemp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveTemp.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeTemp.path)
        // Publish the older half as the single archive, then atomically trim the active file.
        if FileManager.default.fileExists(atPath: archive.path) {
            _ = try FileManager.default.replaceItem(at: archive, withItemAt: archiveTemp, backupItemName: nil, options: [], resultingItemURL: nil)
        } else {
            try FileManager.default.moveItem(at: archiveTemp, to: archive)
        }
        _ = try FileManager.default.replaceItem(at: url, withItemAt: activeTemp, backupItemName: nil, options: [], resultingItemURL: nil)
    }

    private static func streamRange(_ handle: FileHandle, from start: UInt64, to end: UInt64, into destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try handle.seek(toOffset: start)
        var remaining = end - start
        while remaining > 0 {
            let count = Int(min(UInt64(64 * 1024), remaining))
            let chunk = try handle.read(upToCount: count) ?? Data()
            guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }
}

final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()
    @Published var buckets: [UsageBucket] = []
    @Published var agyBuckets: [UsageBucket] = []
    @Published var magpieQuotaTips: [String: String] = [:]
    @Published var magpieAccounts: [MagpieAccountQuota] = []
    @Published var codexBuckets: [UsageBucket] = []
    @Published var codexResets = 0      // Codex 送的「全部重置」還有幾次沒用
    @Published var codexResetExpiries: [Date] = []   // 每一張重置券什麼時候過期（早的在前；後端有給明細才有，不會過期的不列）
    @Published var codexResetBusy = false           // 正在呼叫 consume（按鈕變灰）
    @Published var codexResetStatus: String?        // 重置的結果（白話，貼在 Codex 那組的附註下面，一陣子後清掉）
    @Published var copilotBuckets: [UsageBucket] = []
    @Published var copilotNote = ""     // 「剩 199／200 次」
    @Published var updated: Date?
    @Published var loading = false
    @Published var error: String?
    private var timer: Timer?
    private var magpieQuotaCheckedAt = Date.distantPast
    private let magpieQuotaLock = NSLock()
    private var cachedMagpieQuota: (buckets: [UsageBucket], tips: [String: String], accounts: [MagpieAccountQuota])?

    private init() {
        refresh()
        // 網路回來（例如斷網一陣子）：馬上補查一次，不用等下一輪
        AgyNet.start()
        NotificationCenter.default.addObserver(forName: AgyNet.back, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        restartTimer()
        // 測試用（要有 --state-dir）：CODENV_CODEX_RESET_AUTO=<秒> 開機後自動走一次「重置」流程（不用真的點按鈕）
        if CommandLine.arguments.contains("--state-dir"), let sec = Double(ProcessInfo.processInfo.environment["CODENV_CODEX_RESET_AUTO"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.requestCodexReset() }
            // CODENV_USAGE_FAKE_SET_RESETS=秒:次數：到時候把假資料的剩餘重置次數改掉（模擬別處已經扣了）
            if let spec = ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_SET_RESETS"], let c = spec.firstIndex(of: ":"), let t = Double(spec[..<c]), let n = Int(spec[spec.index(after: c)...]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { Self.fakeResetsLeft = n }
            }
            // CODENV_USAGE_REFRESH_AT=秒,秒…：之後在這些時間「按重新整理」（等於 UsageMonitor.refresh()）
            for t in (ProcessInfo.processInfo.environment["CODENV_USAGE_REFRESH_AT"] ?? "").split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    if let prefix = ProcessInfo.processInfo.environment["CODENV_CODEX_RESET_SHOT"] {
                        let line = "按重新整理（第 \(t) 秒）\n"
                        if let h = FileHandle(forWritingAtPath: prefix + ".txt") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: prefix + ".txt", atomically: true, encoding: .utf8) }
                    }
                    self?.refresh()
                }
            }
            // CODENV_CODEX_RESET_AGAIN=秒,秒…：之後再「按」幾次（測連按只送出一次），每次先把當時的狀態寫進測試紀錄
            for t in (ProcessInfo.processInfo.environment["CODENV_CODEX_RESET_AGAIN"] ?? "").split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    guard let self else { return }
                    if let prefix = ProcessInfo.processInfo.environment["CODENV_CODEX_RESET_SHOT"] {
                        let line = "再按一次（第 \(t) 秒）：busy=\(self.codexResetBusy) 剩 \(self.codexResets) 次 狀態=\(self.codexResetStatus ?? "無")\n"
                        if let h = FileHandle(forWritingAtPath: prefix + ".txt") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: prefix + ".txt", atomically: true, encoding: .utf8) }
                    }
                    self.requestCodexReset()
                }
            }
        }
        sink = Prefs.shared.$usageMinutes.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.restartTimer() }
    }

    static let fakeSprintReset: Date? = {
        guard CommandLine.arguments.contains("--state-dir"), let s = Double(ProcessInfo.processInfo.environment["CODENV_SPRINT_FAKE_RESET_AFTER"] ?? "") else { return nil }
        return Date().addingTimeInterval(s)
    }()
    private static let fakeUsageStartedAt = Date()
    private var sink: AnyCancellable?
    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, Prefs.shared.usageMinutes) * 60), repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !loading else { return }
        let startedAt = Date()
        if CommandLine.arguments.contains("--state-dir"), ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE"] == "1", let prefix = ProcessInfo.processInfo.environment["CODENV_CODEX_RESET_SHOT"] {
            let line = "假查詢開始（\(Date().timeIntervalSince1970 - Self.t0 > 0 ? String(format: "%.1f", Date().timeIntervalSince1970 - Self.t0) : "0") 秒）\n"
            if let h = FileHandle(forWritingAtPath: prefix + ".txt") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: prefix + ".txt", atomically: true, encoding: .utf8) }
        }
        // 測試用：CODENV_USAGE_FAKE=1 不查任何真的用量，直接放一組假資料（五家都有，Codex 有免費重置、Copilot 有剩餘次數）。
        // CODENV_USAGE_FAKE_DELAY=<秒>：假的查詢要這麼久才回來（測重置後讀回新次數之前按鈕要維持停用）
        if ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE"] == "1"
            || (CommandLine.arguments.contains("--state-dir") && CommandLine.arguments.contains("--usage-fake")) {
            let apply = { [weak self] in
                guard let self else { return }
                if self.resetSettledAt != nil, Self.fakeReadFailsLeft > 0 {
                    Self.fakeReadFailsLeft -= 1
                    self.loading = false
                    self.codexReadFinished(startedAt: startedAt, success: false)
                    return
                }
                // 假資料的重置時間一律相對現在（寫死日期會被當成明年，倒數變成「356d」）
                func r(_ hours: Int, _ minutes: Int) -> Date { Self.fakeUsageStartedAt.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60)) }
                func h(_ hours: Int, _ minutes: Int) -> String { Self.when(r(hours, minutes)) }
                // 測試用（要有 --state-dir）：CODENV_SPRINT_FAKE_RESET_AFTER=<秒>：開機後這麼久「5 小時」額度重置（用量掉到 2、下次重置延後 5 小時）
                var five = UsageBucket(label: "5 小時", used: 34, resets: h(2, 13), resetAt: r(2, 13))
                if let at = Self.fakeSprintReset {
                    let done = Date() >= at
                    let next = done ? at.addingTimeInterval(5 * 3600) : at
                    five = UsageBucket(label: "5 小時", used: done ? 2 : 34, resets: Self.when(next), resetAt: next)
                }
                self.buckets = [five, UsageBucket(label: "每週", used: 61, resets: h(4*24+6, 0), resetAt: r(4*24+6, 0)), UsageBucket(label: "Opus 每週", used: 12, resets: h(4*24+6, 0), resetAt: r(4*24+6, 0))]
                // 跟真的 parseAgy 結果同一種標籤（11/7 實際：Gemini 5 小時／每週、Claude 5 小時／每週、Argon 只有每週）
                self.agyBuckets = [UsageBucket(label: "Gemini 5 小時", used: 6, resets: h(3, 41), resetAt: r(3, 41)), UsageBucket(label: "Gemini 每週", used: 2, resets: h(6*24+21, 5), resetAt: r(6*24+21, 5)),
                                   UsageBucket(label: "Claude 5 小時", used: 0, resets: h(3, 41), resetAt: r(3, 41)), UsageBucket(label: "Claude 每週", used: 55, resets: h(4*24+18, 30), resetAt: r(4*24+18, 30)),
                                   UsageBucket(label: "Argon 每週", used: ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_ARGON_LOW"] == "1" ? 85 : 0, resets: h(6*24+23, 12), resetAt: r(6*24+23, 12))]
                // CODENV_USAGE_FAKE_CODEX_HIGH=1：用量比較高的版本（測「用量還不高」那句不出現）
                let hi = ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_CODEX_HIGH"] == "1"
                self.codexBuckets = [UsageBucket(label: "5 小時", used: hi ? 72 : 5, resets: h(1, 48), resetAt: r(1, 48)), UsageBucket(label: "每週", used: hi ? 88 : 47, resets: h(5*24+9, 20), resetAt: r(5*24+9, 20))]
                self.codexResets = Self.fakeResetsLeft
                self.codexResetExpiries = Array([Date().addingTimeInterval(2 * 86400), Date().addingTimeInterval(26 * 86400), Date().addingTimeInterval(27 * 86400)].prefix(Self.fakeResetsLeft))
                self.reconcilePendingKey()
                self.copilotBuckets = [UsageBucket(label: "每月", used: 3, resets: h(23*24+4, 0), resetAt: r(23*24+4, 0))]
                self.copilotNote = "剩 194／200 次"
                self.updated = Date(); self.error = nil
                if CommandLine.arguments.contains("--state-dir") {
                    UsageLog.record(
                        UsageLog.percentages(self.buckets, source: "Claude Code")
                            + UsageLog.percentages(self.agyBuckets, source: "agy")
                            + UsageLog.percentages(self.codexBuckets, source: "Codex")
                            + [UsageLog.Observation(pool: "Copilot · Chat / 每月", kind: "count", remaining: 194, total: 200, resetAt: self.copilotBuckets.first?.resetAt)]
                    )
                }
                self.loading = false
                self.codexReadFinished(startedAt: startedAt, success: true)
            }
            if let d = Double(ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_DELAY"] ?? ""), d > 0 {
                loading = true
                DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: apply)
            } else { apply() }
            return
        }
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 三邊同時查（各自最多 60 秒）
            var agyOut: String?
            var magpieQuota: (buckets: [UsageBucket], tips: [String: String], accounts: [MagpieAccountQuota])?
            var codexOut: [String: Any]?
            var copilotOut: String?
            let g = DispatchGroup()
            var shouldReadMagpie = false
            self?.magpieQuotaLock.lock()
            if Prefs.shared.agyMagpie, let self {
                if Date().timeIntervalSince(self.magpieQuotaCheckedAt) >= 60 {
                    self.magpieQuotaCheckedAt = Date()
                    shouldReadMagpie = true
                } else {
                    magpieQuota = self.cachedMagpieQuota
                }
            }
            self?.magpieQuotaLock.unlock()
            if shouldReadMagpie {
                if CommandLine.arguments.contains("--state-dir") {
                    if let fake = ProcessInfo.processInfo.environment["CODENV_MAGPIE_ACCOUNTS_FAKE"],
                       let data = fake.data(using: .utf8) {
                        magpieQuota = Self.parseMagpieAccounts(data)
                    }
                } else {
                    let output = Self.run("/Applications/magpie.app/Contents/MacOS/magpie", ["accounts", "antigravity", "--json"])
                    if let output, let data = output.data(using: .utf8) { magpieQuota = Self.parseMagpieAccounts(data) }
                }
                if let magpieQuota {
                    self?.magpieQuotaLock.lock()
                    self?.cachedMagpieQuota = magpieQuota
                    self?.magpieQuotaLock.unlock()
                }
            }
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
                var gotNew = false
            let recordedAt = Date()
            var observations: [UsageLog.Observation] = []
                if let magpieQuota, !magpieQuota.buckets.isEmpty {
                    self.agyBuckets = magpieQuota.buckets
                    self.magpieQuotaTips = magpieQuota.tips
                    self.magpieAccounts = magpieQuota.accounts
                    observations += UsageLog.percentages(magpieQuota.buckets, source: "agy")
                    gotNew = true
                } else if let agyOut {
                    let a = Self.parseAgy(agyOut)
                    if !a.isEmpty { self.agyBuckets = a; self.magpieQuotaTips = [:]; self.magpieAccounts = []; gotNew = true }
                    if !a.isEmpty { observations += UsageLog.percentages(a, source: "agy") }
                }
                var codexOK = false
                if let codexOut {
                    let c = Self.parseCodex(codexOut)
                    if !c.buckets.isEmpty {
                        self.codexBuckets = c.buckets
                        self.codexResets = c.resets
                        self.codexResetExpiries = c.expiries
                        observations += UsageLog.percentages(c.buckets, source: "Codex")
                        codexOK = true
                        gotNew = true
                        self.reconcilePendingKey()
                    }
                }
                // 成功或失敗都結束「重置後等新次數」的等待（失敗時顯示讀不到、按鈕維持停用，下一次成功的讀取才解鎖）
                self.codexReadFinished(startedAt: startedAt, success: codexOK)
                if let copilotOut, let c = Self.parseCopilot(copilotOut) {
                    self.copilotBuckets = c.buckets
                    self.copilotNote = c.note
                    observations.append(UsageLog.Observation(pool: "Copilot · Chat / 每月", kind: "count", remaining: c.remaining, total: c.total, resetAt: c.buckets.first?.resetAt))
                    gotNew = true
                }
                let parsed = out.map(Self.parse) ?? []
                if parsed.isEmpty && !gotNew {
                    self.error = L("查不到用量")
                } else {
                    // Claude 這次沒讀到、只有別的來源讀到：Claude 那組留著舊數字，要標出來，不能顯示成剛更新
                    if !parsed.isEmpty {
                        self.buckets = parsed
                        observations += UsageLog.percentages(parsed, source: "Claude Code")
                        self.error = nil
                    }
                    else { self.error = L("Claude 用量這次查不到") }
                    self.updated = Date()
                }
                UsageLog.record(observations, at: recordedAt)
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            guard p.isRunning else { return }
            p.terminate()
            // 不理 SIGTERM 的話 readDataToEndOfFile 會永遠等下去，loading 永遠是 true、之後的用量都查不了：5 秒後強制結束
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func environment() -> [String: String] {
        var env: [String: String] = [:]
        for kv in Workspace.environment() { if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) } }
        return env
    }

    // MARK: Codex 免費「全部重置」（account/rateLimitResetCredit/consume）
    // 參數（codex 0.165.0，codex app-server generate-json-schema --experimental 產生的 ConsumeAccountRateLimitResetCreditParams）：
    // idempotencyKey（必填，一次重置動作一個 UUID）、creditId（選填，不給就由後端挑下一張）。
    // 回覆 outcome：reset（已重置）、nothingToReset（沒有時段需要重置）、noCredit（沒有重置次數了）、alreadyRedeemed（同一個 key 已經成功過）。
    // 這會消耗使用者的額度（總共只有幾次），所以：結果不明（逾時、管線斷掉、解析失敗）時把這次的 key 記在 appDefaults，
    // 下次再按用同一個 key 重送（後端靠 key 擋重複，不會多扣）；結果確定了才清掉。

    enum ResetOutcome: Equatable {
        case reset, nothingToReset, noCredit, alreadyRedeemed
        /// sent：consume 這個請求已經送出去了（送出去之後的失敗，不知道有沒有扣；還沒送出去的失敗，確定沒扣）
        case failed(String, sent: Bool)
    }

    static let pendingResetKeyDefaults = "codexResetPendingKey"
    static let pendingResetResetsDefaults = "codexResetPendingKeyResets"   // 存 key 時剩幾次

    private static func clearPendingResetKey() {
        appDefaults.removeObject(forKey: pendingResetKeyDefaults)
        appDefaults.removeObject(forKey: pendingResetResetsDefaults)
    }

    /// 讀回的次數比「存 key 時剩的次數」少＝結果不明的那次其實已經扣了：把 key 清掉，不然下次真的想重置時會先拿到 alreadyRedeemed
    func reconcilePendingKey() {
        guard appDefaults.string(forKey: Self.pendingResetKeyDefaults) != nil,
              let stored = appDefaults.object(forKey: Self.pendingResetResetsDefaults) as? Int, codexResets < stored else { return }
        Self.clearPendingResetKey()
    }

    /// 結果的白話說明（標題、內文）
    static func resetOutcomeText(_ o: ResetOutcome) -> (title: String, body: String) {
        switch o {
        case .reset: return (L("已重置"), L("用量已經重置，下面會重新讀一次剩多少。"))
        case .nothingToReset: return (L("現在沒有需要重置的"), L("目前沒有任何時段可以重置，這次沒有用掉次數。"))
        case .noCredit: return (L("沒有免費重置次數了"), L("這個帳號已經沒有可用的免費全部重置，這次沒有用掉任何東西。"))
        case .alreadyRedeemed: return (L("這次已經重置過了"), L("同一次重置之前就成功了，沒有重複扣次數。"))
        case .failed(let why, let sent):
            let reason = why.isEmpty ? "" : "（\(why)）"
            return sent ? (L("重置結果不明"), L("沒有確認有沒有用掉次數。下次再按「重置」會用同一次重試，不會重複扣。\(reason)"))
                        : (L("重置沒有成功"), L("請求沒有送出去，沒有用掉次數。\(reason)"))
        }
    }

    // MARK: 測試旁路（絕不能碰到真的 consume）

    /// 只要設了任何一個 CODENV_CODEX_RESET_*、CODENV_USAGE_FAKE*，或帶 --state-dir：就是測試，絕對不能叫真的 codex consume
    private static var testingReset: Bool {
        let env = ProcessInfo.processInfo.environment
        return CommandLine.arguments.contains("--state-dir") || env.keys.contains { $0.hasPrefix("CODENV_CODEX_RESET_") || $0.hasPrefix("CODENV_USAGE_FAKE") }
    }

    /// 測試用的假回覆：一律不開真的 codex。CODENV_CODEX_RESET_FAKE=reset/nothingToReset/noCredit/alreadyRedeemed/unknown（送出後結果不明）/error
    /// （送出前就失敗）；CODENV_CODEX_RESET_FAKE_BIN=<假 codex 的腳本路徑>（要有 --state-dir）：用假腳本走完整的 JSON-RPC 握手與解析。
    /// 沒設假回覆（或設了不認得的值）：直接拒絕，不呼叫真的 consume。回傳 nil＝不是測試，走真的
    private static func fakeResetOutcome(key: String) -> ResetOutcome? {
        guard testingReset else { return nil }
        let env = ProcessInfo.processInfo.environment
        func note(_ what: String) {
            guard let prefix = env["CODENV_CODEX_RESET_SHOT"] else { return }
            let line = "consume 呼叫：\(what) key=\(key)\n"
            if let h = FileHandle(forWritingAtPath: prefix + ".txt") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: prefix + ".txt", atomically: true, encoding: .utf8) }
        }
        if CommandLine.arguments.contains("--state-dir"), let bin = env["CODENV_CODEX_RESET_FAKE_BIN"], !bin.isEmpty {
            note("假 codex 腳本")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-fc", "exec " + "'" + bin.replacingOccurrences(of: "'", with: "'\\''") + "'"]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            let t = TimeInterval(env["CODENV_CODEX_RESET_TIMEOUT"] ?? "") ?? 45
            return driveConsume(p, key: key, timeout: t)
        }
        // CODENV_USAGE_FAKE 要剛好是 "1" 才算假資料模式（預設假回覆 reset）；其他值（例如殘留的 =0）一律走預設拒絕，絕不回假成功
        switch env["CODENV_CODEX_RESET_FAKE"] ?? (env["CODENV_USAGE_FAKE"] == "1" ? "reset" : "") {
        case "reset": note("reset"); fakeResetsLeft = max(0, fakeResetsLeft - 1); return .reset
        case "nothingToReset": note("nothingToReset"); return .nothingToReset
        case "noCredit": note("noCredit"); return .noCredit
        case "alreadyRedeemed": note("alreadyRedeemed"); return .alreadyRedeemed
        case "unknown": note("unknown"); return .failed(L("測試用：結果不明"), sent: true)
        case "error": note("error"); return .failed(L("測試用：送出前失敗"), sent: false)
        default: return .failed(L("測試模式不會真的重置"), sent: false)
        }
    }

    private static let t0 = Date().timeIntervalSince1970

    /// 測試用：CODENV_USAGE_FAKE_READ_FAIL=<次數>：重置之後的前幾次假查詢「讀不到」（不更新任何資料）
    static var fakeReadFailsLeft: Int = Int(ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_READ_FAIL"] ?? "") ?? 0

    /// 假資料模式下 Codex 還剩幾次免費重置（假的 reset 會減 1，之後的假 refresh 才跟著變）
    static var fakeResetsLeft = 2

    // MARK: 跟 codex app-server 對話

    /// 真的 consume：開 codex app-server。測試中（testingReset）一律拒絕，不會走到這裡
    private static func runCodexConsume(key: String) -> ResetOutcome {
        guard !testingReset else { return .failed(L("測試模式不會真的重置"), sent: false) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec codex app-server"]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.environment = environment()
        return driveConsume(p, key: key, timeout: 45)
    }

    /// 跑這個 app-server 行程，照 JSON-RPC 握手：送 initialize → 等 id 1 的回覆 → 才送 initialized 和 consume → 等 id 2 的回覆。
    /// 任何帶 error 的回覆（包括 id 是 null 的）都當成失敗，不等到逾時。逾時、EOF、寫入失敗：送出前是確定沒扣、送出後是結果不明。
    /// 收尾：關掉寫入端和讀取端、送 SIGTERM、等行程真的結束（寬限 3 秒後 SIGKILL）
    private static func driveConsume(_ p: Process, key: String, timeout: TimeInterval) -> ResetOutcome {
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return .failed(L("開不起 codex"), sent: false) }
        let timedOut = NSLock(); var timedOutFlag = false
        let timer = DispatchWorkItem {
            timedOut.lock(); timedOutFlag = true; timedOut.unlock()
            if p.isRunning { p.terminate() }
            // 它不理 SIGTERM、讀取端又卡在 availableData 的話，defer 裡的收尾永遠到不了：2 秒後直接 SIGKILL，讓管線 EOF、讀取一定會返回
            // （不從別的執行緒關掉讀取端：對正在讀的 FileHandle 做 close 會丟例外）
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        func send(_ o: [String: Any]) -> Bool {
            guard let d = try? JSONSerialization.data(withJSONObject: o) else { return false }
            do { try input.fileHandleForWriting.write(contentsOf: d + Data("\n".utf8)); return true } catch { return false }
        }
        var buffer = Data()
        /// 讀到符合的那一行為止：nextMatching 回 .some(結果) 就結束；EOF 回 nil
        func readLines(_ handle: (([String: Any]) -> ResetOutcome??)) -> ResetOutcome? {
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<nl])
                    buffer = Data(buffer[(nl + 1)...])
                    guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if let done = handle(o) { return done }
                }
            }
        }
        func errText(_ o: [String: Any]) -> String {
            let e = o["error"] as? [String: Any]
            return L("伺服器回報錯誤") + ((e?["code"] as? NSNumber).map { " \($0)" } ?? "")
        }
        func isTimedOut() -> Bool { timedOut.lock(); defer { timedOut.unlock() }; return timedOutFlag }
        defer {
            timer.cancel()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if p.isRunning { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            p.waitUntilExit()
        }
        // 1) 握手：initialize 回來才往下
        guard send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codenv", "version": "0"]]]) else { return .failed(L("寫入失敗"), sent: false) }
        let initReply = readLines { o in
            if o["error"] != nil { return .some(.failed(errText(o), sent: false)) }     // 任何 error（含 id 是 null）
            if o["id"] as? Int == 1, o["result"] != nil { return .some(.reset) }          // 只是借 .reset 表示「握手成功」，下面不會當結果用
            return .none
        }
        guard let ir = initReply else { return .failed(isTimedOut() ? L("逾時") : L("程序提早結束"), sent: false) }
        if case .failed = ir { return ir }
        // 2) 送 consume（這一步之後，失敗都是「結果不明」）
        guard send(["method": "initialized"]), send(["id": 2, "method": "account/rateLimitResetCredit/consume", "params": ["idempotencyKey": key]]) else {
            return .failed(L("寫入失敗"), sent: true)
        }
        let reply = readLines { o in
            if o["error"] != nil { return .some(.failed(errText(o), sent: true)) }
            guard o["id"] as? Int == 2 else { return .none }
            guard let r = o["result"] as? [String: Any], let name = r["outcome"] as? String else { return .some(.failed(L("看不懂的回覆"), sent: true)) }
            switch name {
            case "reset": return .some(.reset)
            case "nothingToReset": return .some(.nothingToReset)
            case "noCredit": return .some(.noCredit)
            case "alreadyRedeemed": return .some(.alreadyRedeemed)
            default: return .some(.failed(L("不認得的回覆"), sent: true))
            }
        }
        return reply ?? .failed(isTimedOut() ? L("逾時") : L("沒有收到回覆"), sent: true)
    }

    /// 確認框的內文：剩幾次、現在各時段「剩」多少（跟卡片上的百分比同一個方向）；剩下都還多（所有時段剩 > 50%）就多提醒一句
    func resetConfirmText(retry: Bool) -> String {
        let remaining = codexBuckets.map { L("剩 \($0.remaining)%（\($0.label)）") }.joined(separator: L("、"))
        var t = L("（還有 \(codexResets) 次") + (remaining.isEmpty ? "）" : L("；") + remaining + "）")
        if retry { t = L("上次的重置結果不明，這次會用同一個請求重送，不會重複扣次數。") + "\n" + t }
        else if !codexBuckets.isEmpty, codexBuckets.allSatisfy({ $0.remaining > 50 }) { t += "\n" + L("現在用量還不高，要不要等快用完再重置？") }
        return t
    }

    /// 測試用（要有 --state-dir）：CODENV_CODEX_RESET_SHOT=<前綴> 不顯示對話框，把它畫成 <前綴>-<名字>.png 並記進 <前綴>.txt；
    /// CODENV_CODEX_RESET_CONFIRM=yes 時確認框自動按「重置」，其他（預設）按「取消」。回傳按到的是第幾顆按鈕（依加入順序，0 起算）
    private func present(_ alert: NSAlert, tag: String, autoPressIndex: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        if CommandLine.arguments.contains("--state-dir"), let prefix = env["CODENV_CODEX_RESET_SHOT"] {
            // 預設只記文字、不開任何視窗（測試規則：不佔使用者的螢幕）；要截圖才設 CODENV_CODEX_RESET_PNG=1
            if env["CODENV_CODEX_RESET_PNG"] == "1" {
            alert.layout()
            // 沒顯示過的視窗畫不全：先擺到前面讓它真的排版一下，再整個視窗（含標題列框）畫成圖，畫完收起來
            alert.window.center()
            alert.window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let v = alert.window.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-" + tag + ".png"))
            }
            alert.window.orderOut(nil)
            }
            let buttons = alert.buttons.map(\.title).joined(separator: "|")
            let def = alert.buttons.first?.title ?? ""
            let log = "\(tag)：\(alert.messageText)｜\(alert.informativeText)｜按鈕（加入順序）=\(buttons)｜預設=\(def)｜顯示時 busy=\(codexResetBusy)\n"
            if let h = FileHandle(forWritingAtPath: prefix + ".txt") { h.seekToEndOfFile(); h.write(Data(log.utf8)); try? h.close() } else { try? log.write(toFile: prefix + ".txt", atomically: true, encoding: .utf8) }
            return env["CODENV_CODEX_RESET_CONFIRM"] == "yes" ? autoPressIndex : 0
        }
        let r = alert.runModal()
        switch r {
        case .alertFirstButtonReturn: return 0
        case .alertSecondButtonReturn: return 1
        default: return 0
        }
    }

    /// 還在等「結果之後讀回來的新次數」：這個時間點之後「開始」的用量查詢讀成功，才算拿到新次數（更早開始的查詢可能還是舊值）
    private var resetSettledAt: Date?

    /// 一次用量讀取完成（startedAt＝那次查詢開始的時間；success＝這次有讀到 Codex 的次數）：只看重置結果之後才開始的查詢。
    /// 成功：解除重置鈕的停用。失敗（讀不到、沒有可解析的資料）：等待結束，但按鈕維持停用，卡片寫「讀不到新的次數，按重新整理再試」；
    /// 之後任何一次成功的讀取（使用者按重新整理、或定時查詢）都會解鎖，不會卡到重開 App
    func codexReadFinished(startedAt: Date, success: Bool) {
        guard codexResetBusy, let at = resetSettledAt, startedAt >= at else { return }
        if success {
            resetSettledAt = nil
            codexResetBusy = false
            if codexResetStatus == L("讀不到新的次數，按重新整理再試") { codexResetStatus = nil }   // 讀到了：那句失敗提示不用再留著
            // 沒有確定結果的失敗時狀態字保留（提醒使用者可以重試），其他的過一陣子清掉
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.resetUnknownPending == false, self?.codexResetBusy == false { self?.codexResetStatus = nil }
            }
        } else {
            codexResetStatus = L("讀不到新的次數，按重新整理再試")
        }
    }

    var resetUnknownPending: Bool { appDefaults.string(forKey: Self.pendingResetKeyDefaults) != nil }

    private var resetRefreshWork: DispatchWorkItem?

    /// 重置結果出來後馬上重新讀一次用量：現在有一次查詢在跑就等它結束（舊的查詢可能拿到舊的次數）。
    /// 只留一個待處理的工作（重複呼叫會取代前一個），最多等 60 秒（測試用 CODENV_USAGE_RESET_WAIT 可縮短）；
    /// 等不到就照讀取失敗處理：寫「讀不到新的次數，按重新整理再試」，按鈕維持停用，之後任何一次成功的讀取才解鎖
    private func refreshAfterReset() {
        resetRefreshWork?.cancel()
        resetRefreshWork = nil
        let wait = Double(ProcessInfo.processInfo.environment["CODENV_USAGE_RESET_WAIT"] ?? "") ?? 60
        let deadline = Date().addingTimeInterval(wait)
        func attempt(_ me: UsageMonitor) {
            if !me.loading { me.resetRefreshWork = nil; me.refresh(); return }
            if Date() >= deadline {
                me.resetRefreshWork = nil
                if me.codexResetBusy { me.codexResetStatus = L("讀不到新的次數，按重新整理再試") }
                return
            }
            let w = DispatchWorkItem { [weak me] in if let me { attempt(me) } }
            me.resetRefreshWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
        }
        attempt(self)
    }

    /// 按「重置」：先確認（預設按鈕是取消）→ 用掉 1 次免費全部重置 → 白話顯示結果 → 重新讀一次用量。
    /// 讀回新的次數之前按鈕都停用（codexResetBusy），不然舊的次數還在、可以再按一次多扣；結果不明（送出後失敗）時 key 留在 appDefaults，下次用同一個 key
    func requestCodexReset() {
        guard !codexResetBusy, codexResets > 0 else { return }
        let pendingKey = appDefaults.string(forKey: Self.pendingResetKeyDefaults)
        let retry = pendingKey != nil
        let confirm = NSAlert()
        confirm.messageText = retry ? L("用同一次重試重置？") : L("用掉 1 次免費全部重置？")
        confirm.informativeText = resetConfirmText(retry: retry)
        confirm.alertStyle = .warning
        // 第一個加進去的是預設按鈕（按 Return）：先放「取消」，畫面上「重置」在它左邊
        confirm.addButton(withTitle: L("取消"))
        let go = confirm.addButton(withTitle: retry ? L("重試") : L("重置"))
        go.hasDestructiveAction = true
        // 確認框跳出的期間就先當成忙碌（別的觸發不能再開第二個確認框／第二次重置），按取消就還原
        codexResetBusy = true
        guard present(confirm, tag: "confirm", autoPressIndex: 1) == 1 else { codexResetBusy = false; return }   // 明確比對「重置」（第二顆）才算確認
        let key = pendingKey ?? UUID().uuidString.lowercased()
        // 先記下這次的 key：送出去之後程式被關掉也能用同一個 key 重試。確定結果了才清掉。
        // 同時記下當時的剩餘次數：之後讀回的次數比它少，代表結果不明的那次其實已經扣了，要把 key 清掉（見 reconcilePendingKey）
        appDefaults.set(key, forKey: Self.pendingResetKeyDefaults)
        if pendingKey == nil { appDefaults.set(codexResets, forKey: Self.pendingResetResetsDefaults) }
        resetSettledAt = nil
        codexResetStatus = L("重置中…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.fakeResetOutcome(key: key) ?? Self.runCodexConsume(key: key)
            DispatchQueue.main.async {
                guard let self else { return }
                let t = Self.resetOutcomeText(outcome)
                self.codexResetStatus = t.title + "：" + t.body
                var unknown = false
                var notSettled = false   // 失敗（沒有確定「已扣」的結果）：不需要等讀回新次數才解鎖
                switch outcome {
                case .reset:
                    Self.clearPendingResetKey()
                    self.codexResets = max(0, self.codexResets - 1)    // 本地先減 1：讀回新的次數之前不會顯示舊值
                case .nothingToReset, .noCredit, .alreadyRedeemed:
                    Self.clearPendingResetKey()
                case .failed(_, let sent):
                    if sent { unknown = true } else { Self.clearPendingResetKey() }
                    // 送出後失敗＝結果不明：按鈕可以再按（會用同一個 key 重試，後端擋重複）；送出前就失敗＝確定沒扣：也不用等讀回次數
                    self.codexResetBusy = false
                    notSettled = true
                }
                // 確定的結果：codexResetBusy 維持 true，等結果框關掉之後「開始」的用量查詢讀成功才解除（讀取失敗就一直停用，等下一次成功的讀取）
                let info = NSAlert()
                info.messageText = t.title
                info.informativeText = t.body
                info.alertStyle = outcome == .reset || outcome == .alreadyRedeemed ? .informational : .warning
                info.addButton(withTitle: L("好"))
                _ = self.present(info, tag: "outcome", autoPressIndex: 0)
                if !notSettled { self.resetSettledAt = Date() }   // 結果框關掉的時間之後才開始的查詢才算數
                self.refreshAfterReset()
            }
        }
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            if p.isRunning {
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            }
        }
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
    static func parseCodex(_ r: [String: Any]) -> (buckets: [UsageBucket], resets: Int, expiries: [Date]) {
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
                let span = mins == 300 ? L("5 小時") : mins == 10080 ? L("每週") : mins >= 1440 ? L("\(mins / 1440) 天") : mins > 0 ? L("\(mins / 60) 小時") : key
                let resetDate = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let resets = resetDate.map(when) ?? ""
                out.append(UsageBucket(label: [name, span].compactMap { $0 }.joined(separator: " "), used: Int(used.rounded()), resets: resets, resetAt: resetDate))
            }
        }
        let credits = r["rateLimitResetCredits"] as? [String: Any]
        let resets = (credits?["availableCount"] as? NSNumber)?.intValue ?? 0
        // 明細（credits）：還能用的那幾張各自的過期時間（expiresAt 是 Unix 秒；null＝不會過期）
        let expiries = ((credits?["credits"] as? [[String: Any]]) ?? [])
            .filter { ($0["status"] as? String ?? "available") == "available" }
            .compactMap { ($0["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
            .sorted()
        return (out, resets, expiries)
    }

    /// gh 裝在 Homebrew（登入 shell 的 PATH 不一定有）；沒裝就不查 Copilot
    static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// gh api /copilot_internal/user：quota_snapshots.chat 是對話的額度（免費方案 200 次／月），quota_reset_date_utc 什麼時候重置
    static func parseCopilot(_ text: String) -> (buckets: [UsageBucket], note: String, remaining: Int, total: Int)? {
        guard let d = text.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let chat = (o["quota_snapshots"] as? [String: Any])?["chat"] as? [String: Any],
              chat["unlimited"] as? Bool != true, let total = (chat["entitlement"] as? NSNumber)?.intValue, total > 0 else { return nil }
        let left = (chat["remaining"] as? NSNumber)?.intValue ?? 0
        let pct = (chat["percent_remaining"] as? NSNumber)?.doubleValue ?? Double(left) / Double(total) * 100
        let resetRaw = o["quota_reset_date_utc"] as? String ?? o["quota_reset_date"] as? String
        let iso = ISO8601DateFormatter()
        var resetAt = resetRaw.flatMap { iso.date(from: $0) }
        if resetAt == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetAt = resetRaw.flatMap { iso.date(from: $0) }
        }
        let resets = resetAt.map(when) ?? (resetRaw ?? "")
        return ([UsageBucket(label: L("每月"), used: Int((100 - pct).rounded()), resets: resets, resetAt: resetAt)], L("剩 \(left)／\(total) 次"), left, total)
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
            if what == "session" { label = L("5 小時") }
            else if what.hasPrefix("week (all") { label = L("每週") }
            else if what.hasPrefix("week ("), let name = what.split(separator: "(").last?.dropLast() { label = L("\(name) 每週") }
            else { label = what }
            if hidden.contains(where: { label.hasPrefix($0) }) { continue }
            out.append(UsageBucket(label: label, used: used, resets: g(3).map { friendly($0, zone: g(4)) } ?? "", resetAt: g(3).flatMap { friendlyDate($0, zone: g(4)) }))
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
            let span = f[1].contains("Five Hour") ? L("5 小時") : f[1].contains("Weekly") ? L("每週") : f[1]
            var resets = ""
            var resetDate: Date?
            if f.count >= 4, let d = iso.date(from: f[3]) { resets = when(d); resetDate = d }
            out.append(UsageBucket(label: "\(group) \(span)", used: 100 - left, resets: resets, resetAt: resetDate))
        }
        // 跟上面 Claude Code 那組一樣：同一組 5 小時在前、每週在後
        let rank = { (b: UsageBucket) -> Int in (b.label.hasPrefix("Gemini") ? 0 : b.label.hasPrefix("Claude") ? 10 : 20) + (b.label.hasSuffix("5 小時") ? 0 : 1) }
        return out.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Magpie accounts JSON：相同 pool 的 remaining 在帳號間等權平均；只接受完整、可解析的帳號集合。
    static func parseMagpieAccounts(_ data: Data) -> (buckets: [UsageBucket], tips: [String: String], accounts: [MagpieAccountQuota])? {
        guard let accounts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !accounts.isEmpty else { return nil }
        guard accounts.allSatisfy({ $0["windows"] is [[String: Any]] }) else { return nil }
        struct Entry { let account: String; let remaining: Double; let reset: Date? }
        var grouped: [String: [String: Entry]] = [:]
        var accountValues: [String: [String: UsageBucket]] = [:]
        let labels = ["gemini5": "Gemini 5 小時", "geminiWeek": "Gemini 每週", "argonWeek": "Argon 每週"]
        let iso = ISO8601DateFormatter()
        for (index, account) in accounts.enumerated() {
            let accountName = (account["email"] as? String) ?? (account["name"] as? String) ?? (account["id"] as? String) ?? "帳號 \(index + 1)"
            let accountID = (account["email"] as? String) ?? (account["id"] as? String) ?? "\(index)"
            guard let windows = account["windows"] as? [[String: Any]] else { continue }
            for window in windows {
                // pool 在 Claude／GPT-OSS 個別模型視窗可能為 null；名稱不相關時直接略過。
                guard let name = window["name"] as? String,
                      let raw = window["remaining"], let remaining = (raw as? NSNumber)?.doubleValue ?? Double(String(describing: raw).replacingOccurrences(of: "%", with: "")) else { continue }
                let pool = window["pool"] as? String ?? ""
                let model = (window["model"] as? String) ?? (window["modelName"] as? String) ?? (window["label"] as? String) ?? ""
                let key = magpiePoolKey(pool: pool + " " + model, name: name)
                guard let key else { continue }
                let resetText = (window["resetsAt"] as? String) ?? (window["resetAt"] as? String) ?? (window["reset"] as? String)
                let reset = resetText.flatMap { iso.date(from: $0) }
                let clamped = min(100, max(0, remaining))
                grouped[key, default: [:]][accountID] = Entry(account: accountName, remaining: clamped, reset: reset)
                let label = labels[key]!
                accountValues[accountID, default: [:]][label] = UsageBucket(label: label, used: 100 - Int(clamped.rounded()), resets: reset.map(when) ?? "", resetAt: reset)
            }
        }
        guard !grouped.isEmpty else { return nil }
        var buckets: [UsageBucket] = []
        var tips: [String: String] = [:]
        for key in ["gemini5", "geminiWeek", "argonWeek"] {
            guard let rowsByAccount = grouped[key], !rowsByAccount.isEmpty else { continue }
            let rows = rowsByAccount.values.sorted { $0.account < $1.account }
            let left = Int((rows.map(\.remaining).reduce(0, +) / Double(rows.count)).rounded())
            let resets = rows.compactMap(\.reset).min()
            let label = labels[key]!
            buckets.append(UsageBucket(label: label, used: 100 - left, resets: resets.map(when) ?? "", resetAt: resets))
            tips[label] = rows.map { row in
                "\(row.account)：剩 \(Int(row.remaining.rounded()))%" + (row.reset.map { "，\(when($0)) 重置" } ?? "")
            }.joined(separator: "\n")
        }
        let accountDetails = accounts.enumerated().map { index, account in
            let id = (account["email"] as? String) ?? (account["id"] as? String) ?? "\(index)"
            let name = (account["email"] as? String) ?? (account["name"] as? String) ?? (account["id"] as? String) ?? "帳號 \(index + 1)"
            return MagpieAccountQuota(id: id, name: name, buckets: accountValues[id] ?? [:])
        }
        return buckets.isEmpty ? nil : (buckets, tips, accountDetails)
    }

    /// 三欄的整體用量文字（供狀態列與純邏輯考卷共用）。
    static func magpieGlanceText(_ buckets: [UsageBucket]) -> String {
        func remaining(_ label: String) -> String {
            guard let bucket = buckets.first(where: { $0.label == label }) else { return "—" }
            return "\(bucket.remaining)%"
        }
        return "\(remaining("Gemini 5 小時"))  \(remaining("Gemini 每週"))  阿公 \(remaining("Argon 每週"))"
    }

    private static func magpiePoolKey(pool: String, name: String) -> String? {
        // Magpie 使用中點分隔模型名稱與週期（例如「Gemini 4 Argon · 7 days」）。
        let s = (pool + " " + name).lowercased().replacingOccurrences(of: "·", with: " ")
        if s.contains("argon") || s.contains("gemini 4") || s.contains("gemini4") { return s.contains("week") || s.contains("weekly") || s.contains("每週") ? "argonWeek" : nil }
        if s.contains("five hour") || s.contains("5 hour") || s.contains("5 小時") || s.contains("5h") || s.contains("session") { return "gemini5" }
        if s.contains("weekly") || s.contains("week") || s.contains("每週") { return "geminiWeek" }
        if s.contains("gemini") { return "geminiWeek" }
        return nil
    }

    /// 「Oct 22 at 10pm」→「今天 22:00」；「Oct 24 at 1am」→「10/24 01:00」
    static func friendly(_ s: String, zone: String?) -> String {
        friendlyDate(s, zone: zone).map(when) ?? s
    }

    static func friendlyDate(_ s: String, zone: String?, now: Date = Date()) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        let year = Calendar.current.component(.year, from: now)
        // 字串沒有年份：今年、明年、去年都試，取離現在最近的（12 月底讀到「Jan 1」要算明年，1 月初讀到「Dec 31」要算去年）
        for fmt in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy"] {
            f.dateFormat = fmt
            let hits = [year, year + 1, year - 1].compactMap { f.date(from: s + " \($0)") }
            if let d = hits.min(by: { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }) { return d }
        }
        return nil
    }
}

/// 一組額度池（照模型的來源分）：右側欄只列目前分頁用到的組，完整用量頁全部列
enum UsagePool: String, CaseIterable {
    case cc, gemini, claudeAgy, codex, copilot, local
    var title: String {
        switch self {
        case .cc: "Claude Code"
        case .gemini: L("Gemini（agy）")
        case .claudeAgy: L("agy 裡的 Claude／GPT")
        case .codex: L("ChatGPT（Codex）")
        case .copilot: "GitHub Copilot"
        case .local: L("本機模型")
        }
    }
    /// 名字左邊的圖示（跟模型清單分頁同一套）
    var icon: ModelTab { switch self { case .cc, .claudeAgy: .claude; case .gemini: .gemini; case .codex: .chatgpt; case .copilot: .copilot; case .local: .local } }
    /// 實際畫的圖示：Gemini（agy）那組用 Antigravity 去背的「A」（App 沒裝才退回 Gemini 星芒），其他照 icon
    var glyph: AppIcons.Glyph? {
        if self == .gemini, let g = AppIcons.glyph(for: "agy") { return g }
        return icon.image.map { AppIcons.Glyph(image: $0, template: icon.monochrome) }
    }

    /// 對話存的模型代號 → 顯示名稱（agy:gemini-3.8-flash-medium → Gemini 3.8 Flash）；nil＝Claude Code 的預設
    static func modelName(_ model: String?) -> String {
        guard let m = model, !m.isEmpty else {
            let k = ModelChoice.known, d = k.first { $0.value == "default" }
            return k.first { $0.resolved == d?.resolved && $0.value != "default" }?.name ?? L("Claude（預設）")
        }
        if m.hasPrefix("agy:") { return AgyBridge.name(String(m.dropFirst(4))) }
        if m.hasPrefix("codex:") { return CodexBridge.name(String(m.dropFirst(6))) }
        if m.hasPrefix("copilot:") { return CopilotBridge.name(String(m.dropFirst(8))) }
        if m.hasPrefix("local:apple:") { return AppleBridge.name(String(m.dropFirst(12))) }
        if m.hasPrefix("local:mlx:") { return LocalBridge.name(String(m.dropFirst(10))) }
        if m.hasPrefix("local:") { return LocalModel.all.first { "local:" + $0.id.uuidString == m }?.name ?? L("本機模型") }
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
        case .codex:
            guard codexResets > 0 else { return nil }
            guard !codexResetExpiries.isEmpty else { return L("另有 \(codexResets) 次免費全部重置") }
            // 每一張的過期時間都列出來；三天內過期的標「快到期」（不用就浪費了）
            let list = codexResetExpiries.map { Self.when($0) + ($0.timeIntervalSinceNow < 3 * 86400 ? L("（快到期）") : "") }
            return L("另有 \(codexResets) 次免費全部重置") + "\n" + L("過期：") + list.joined(separator: L("、"))
        case .copilot: return copilotNote.isEmpty ? nil : copilotNote
        case .local: return L("本機模型：在這台 Mac 上跑，不花額度")
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
                if let i = out.firstIndex(where: { $0.model == m }) { out[i].titles.append(c.title) }
                else { out.append((m, [c.title])) }
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
    var detail: String? = nil
    var body: some View {
        let b = row.bucket
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                if let gl = row.pool.glyph {
                    Image(nsImage: gl.image).resizable().renderingMode(gl.template ? .template : .original)
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
            if !b.resets.isEmpty { Text(L("\(b.resets) 重置")).font(.system(size: 11 * s)).foregroundStyle(.tertiary) }
        }
        .help(detail ?? "")
    }
    /// 剩兩成以下紅，其他綠
    static func color(_ remaining: Int) -> Color { isLow(remaining) ? .red : .green }
    static func isLow(_ remaining: Int) -> Bool { remaining <= 20 }
}

struct UsagePanel: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var m: UsageMonitor
    @ObservedObject var store: Store
    var compact: (UUID) -> Void = { _ in }

    /// 內容比欄位高時可以往下捲（捲軸自動隱藏），不會畫到桌寵格裡（項目多時蓋到桌寵格）
    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                content.frame(minHeight: geo.size.height, alignment: .topLeading)    // 內容少時照舊撐滿欄位（底下的 Spacer 才推得到底）
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryBlock()
            HStack {
                // 點「用量剩餘」：置中打開完整用量頁（每一組都列）
                Button(action: { UsageSheet.toggle() }) {
                    HStack(spacing: 4) {
                        Text(L("用量剩餘")).font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9 * s, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("看全部的用量（Claude、Gemini、ChatGPT、Copilot）"))
                Spacer()
                if m.loading { ProgressView().controlSize(.mini) }
                else {
                    Button(action: { m.refresh() }) { Image(systemName: "arrow.clockwise").font(.system(size: 11 * s)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help(L("現在重新查"))
                }
            }
            // 只列目前這個分頁裡每一格用到的額度池（換模型、換分頁就跟著變）
            ForEach(store.usagePoolsInCurrentWindow, id: \.pool) { p in
                ForEach(m.rows(p.pool, argon: p.argon)) { r in UsageRowView(row: r) }
                // 這個池是哪些格、哪個模型在用
                ForEach(store.modelsInCurrentWindow(p.pool), id: \.model) { u in
                    // 聊天室名字放下一行（括號被拆在兩行中間不好讀）
                    Text(L("使用中：\(u.model)\n（\(u.titles.joined(separator: "、"))）"))
                        .font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PoolNote(m: m, pool: p.pool)
            }
            if m.buckets.isEmpty && !m.loading {
                Text(m.error ?? L("查詢中…")).font(.system(size: 12 * s)).foregroundStyle(.tertiary)
            }
            SprintCard()
            ContextBlock(store: store, compact: compact)
            ActivityBlock(store: store)
            Spacer(minLength: 0)
            if let u = m.updated {
                Text(m.error != nil ? L("更新於 \(u.formatted(date: .omitted, time: .shortened))（這次查不到，顯示的是舊資料）") : L("更新於 \(u.formatted(date: .omitted, time: .shortened))")).font(.system(size: 10 * s)).foregroundStyle(m.error != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 一組底下的附註（Codex 的免費重置次數、Copilot 剩幾次）。Codex 還有免費重置時，右下角多一顆小的「重置」鈕
struct PoolNote: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var m: UsageMonitor
    let pool: UsagePool

    var body: some View {
        let canReset = pool == .codex && m.codexResets > 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                if let n = m.note(pool) { Text(n).font(.system(size: 11 * s)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 4)
                if canReset {
                    Button(action: { m.requestCodexReset() }) {
                        Text(m.codexResetBusy ? L("重置中…") : L("重置")).font(.system(size: 10.5 * s))
                            .padding(.horizontal, 8 * s).padding(.vertical, 2 * s)
                            .overlay(Capsule().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(m.codexResetBusy)
                    .help(L("用掉 1 次免費全部重置（會先問你）") + (m.codexResetExpiries.isEmpty ? "" : "\n" + L("各張過期時間：") + m.codexResetExpiries.map { UsageMonitor.when($0) }.joined(separator: "、")))
                }
            }
            if pool == .codex, let st = m.codexResetStatus {
                Text(st).font(.system(size: 10.5 * s)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 完整用量頁：每一組都列（有資料的），組名前面有圖示
struct UsageFullPage: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var m: UsageMonitor
    var scroll = true
    /// 一列放幾家（1～3）：一家一張卡片，排成格子；放不下三欄時由 UsageSheet 依視窗寬度退成兩欄或一欄
    var columns = 3

    static let cardWidth: CGFloat = 300
    static let gap: CGFloat = 12
    static let pad: CGFloat = 18
    static func width(columns: Int, scale: CGFloat) -> CGFloat {
        (cardWidth * CGFloat(columns) + gap * CGFloat(columns - 1) + pad * 2) * scale
    }

    var body: some View {
        Group {
            if scroll { ScrollView { content } } else { content }
        }
        .frame(width: Self.width(columns: columns, scale: s))
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("全部的用量")).font(.system(size: 16 * s, weight: .semibold))
                Spacer()
                if m.loading { ProgressView().controlSize(.small) }
                else {
                    Button(action: { m.refresh() }) { Image(systemName: "arrow.clockwise").font(.system(size: 12 * s)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L("現在重新查"))
                }
            }
            let pools = UsagePool.allCases.filter { !m.rows($0).isEmpty }
            VStack(alignment: .leading, spacing: Self.gap * s) {
                ForEach(Array(stride(from: 0, to: pools.count, by: max(1, columns))), id: \.self) { start in
                    HStack(alignment: .top, spacing: Self.gap * s) {
                        ForEach(Array(pools[start..<min(pools.count, start + max(1, columns))]), id: \.self) { p in card(p) }
                    }
                }
            }
            if let u = m.updated {
                Text((m.error != nil ? L("更新於 \(u.formatted(date: .omitted, time: .shortened))（這次查不到，顯示的是舊資料）") : L("更新於 \(u.formatted(date: .omitted, time: .shortened))")) + L("　按 Esc 或點外面關掉"))
                    .font(.system(size: 10 * s)).foregroundStyle(m.error != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary)).padding(.top, 4)
            }
        }
        .padding(Self.pad * s)
    }

    private func card(_ p: UsagePool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let gl = p.glyph {
                    Image(nsImage: gl.image).resizable().renderingMode(gl.template ? .template : .original)
                        .aspectRatio(contentMode: .fit).frame(width: 15 * s, height: 15 * s)
                }
                Text(p.title).font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(m.rows(p)) { r in
                UsageRowView(row: r, detail: p == .gemini ? m.magpieQuotaTips[r.bucket.label] : nil)
            }
            PoolNote(m: m, pool: p)
        }
        .padding(12 * s)
        .frame(width: Self.cardWidth * s, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}

/// 完整用量頁的浮動視窗：置中在主視窗上，點外面或按 Esc 關掉；再點一次「用量剩餘」也會關
enum UsageSheet {
    private static weak var panel: FloatingPanel?
    private static var closedAt = Date.distantPast
    private static weak var focusWindow: NSWindow?
    private static weak var focusResponder: NSResponder?
    private static var focusApp: NSRunningApplication?
    private static var shouldRestoreExternalApp = false
    private static var actionSequence: UInt64 = 0
    private static var isClosing = false

    static func toggle(preservingFocus: Bool = false, in sourceWindow: NSWindow? = nil, allowImmediateReopen: Bool = false) {
        actionSequence &+= 1
        let sequence = actionSequence
        if let p = panel, p.isVisible {
            if isClosing {
                isClosing = false
                p.alphaValue = 1
                return
            }
            isClosing = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                p.animator().alphaValue = 0
            }, completionHandler: {
                guard actionSequence == sequence, isClosing, panel === p else { return }
                isClosing = false
                p.close()
            })
            return
        }
        // 點「用量剩餘」想關掉：面板在按下時已經自己關了，放開時別又打開
        if !allowImmediateReopen && Date().timeIntervalSince(closedAt) < 0.4 { return }
        guard let win = sourceWindow ?? NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        if preservingFocus {
            let priorApp = NSWorkspace.shared.frontmostApplication
            focusApp = priorApp
            shouldRestoreExternalApp = priorApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            focusWindow = sourceWindow ?? NSApp.keyWindow ?? win
            focusResponder = focusWindow?.firstResponder
        } else {
            clearFocusTarget()
        }
        let scale = UIScale.shared.f
        // 一列三家；主視窗寬度（的 95%）放不下就退成兩欄、一欄。只看視窗寬度、不看現在有幾家有資料：
        // 剛開 App 用量還沒查回來時打開，欄數若按「現在有幾家」算會被鎖成一欄，資料到了也不會重排
        var cols = 3
        while cols > 1 && UsageFullPage.width(columns: cols, scale: scale) > win.frame.width * 0.95 { cols -= 1 }
        let host = NSHostingView(rootView: UsageFullPage(m: .shared, columns: cols).environment(\.uiScale, scale))
        host.sizingOptions = []
        // 量高度：不捲動的版本多高就多高，最多主視窗的 85%
        let natural = NSHostingView(rootView: UsageFullPage(m: .shared, scroll: false, columns: cols).environment(\.uiScale, scale)).fittingSize
        let size = NSSize(width: natural.width, height: min(natural.height, win.frame.height * 0.85))
        let f = win.frame
        let p = FloatingPanel(content: host)
        p.onClose = { [weak p] in
            guard actionSequence == sequence, panel === p else { return }
            panel = nil
            isClosing = false
            closedAt = Date()
            if preservingFocus { restoreFocus(panelWasKey: p?.wasKeyBeforeClose == true) }
            clearFocusTarget()
        }
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        win.addChildWindow(p, ordered: .above)
        if preservingFocus { p.orderFront(nil) }
        else { p.makeKeyAndOrderFront(nil) }
        panel = p
        isClosing = false
    }

    private static func restoreFocus(panelWasKey: Bool) {
        FocusRestoration.restore(window: focusWindow, responder: focusResponder, app: focusApp,
                                 external: shouldRestoreExternalApp, panelWasKey: panelWasKey)
    }

    private static func clearFocusTarget() {
        focusWindow = nil
        focusResponder = nil
        focusApp = nil
        shouldRestoreExternalApp = false
    }

    static func toggleForShortcut(in window: NSWindow?) {
        let wasOpen = panel?.isVisible == true
        toggle(preservingFocus: true, in: window, allowImmediateReopen: true)
        if !wasOpen, panel?.isVisible == true { UsageMonitor.shared.refresh() }
    }

    /// 測試用：現在開著的那個
    static var current: NSPanel? { panel }
    static func owns(_ window: NSWindow?) -> Bool { window === panel }
}

/// 一眼看完的用量
/// 每家一組，輸入框下面那條（UsageGlanceStrip）和左下角（SidebarFooter）共用。
/// agy 實際只有 Gemini 5 小時／Gemini 每週／Argon 每週（Argon 沒有自己的 5 小時），所以 agy 是「5 小時 · 週 · 阿公 週」三個數字。
struct UsageGlanceItem {
    let tag: String?          // 數字前面的小字（只有「阿公」）
    let what: String          // 滑過說明用的全名
    let bucket: UsageBucket?  // nil＝查不到，顯示「—」
    var detail: String? = nil
}

struct UsageGlanceGroup {
    let key: String
    let name: String
    let symbol: String        // SF Symbols（不用各家商標圖檔）
    let items: [UsageGlanceItem]

    /// 「64% · 90%」「94% · 98% · 阿公 100%」，每一段標好要不要紅
    /// compact＝左下角窄欄用：分隔不留空格、標籤貼著數字
    func parts(compact: Bool = false, tight: Bool = false) -> [(text: String, low: Bool)] {
        var out: [(String, Bool)] = []
        for (i, it) in items.enumerated() {
            if i > 0 { out.append((compact ? "·" : " · ", false)) }
            if let t = it.tag { out.append((compact ? t : t + " ", false)) }
            if let b = it.bucket { out.append(("\(b.remaining)" + (tight && i < items.count - 1 ? "" : "%"), UsageRowView.isLow(b.remaining))) }
            else { out.append(("—", false)) }
        }
        return out
    }
    var plain: String { parts().map(\.text).joined() }

    /// 滑過的說明：每個數字是什麼、多久後重置
    var tip: String {
        items.map { it in
            guard let b = it.bucket else { return it.what + L("：查不到") }
            var t = it.what + L("：剩 \(b.remaining)%")
            if let c = SidebarFooter.countdown(b.resets) { t += L("，\(c) 後重置（\(b.resets)）") }
            else if !b.resets.isEmpty { t += L("，\(b.resets) 重置") }
            if let detail = it.detail { t += "\n" + detail }
            return t
        }.joined(separator: "\n")
    }
}

extension UsageMonitor {
    /// Claude 一定列；Codex、agy 有裝（或已經有資料）才列
    var glance: [UsageGlanceGroup] {
        let five = L("5 小時"), week = L("每週")
        func find(_ list: [UsageBucket], _ ok: (String) -> Bool) -> UsageBucket? { list.first { ok($0.label) } }
        var out = [UsageGlanceGroup(key: "cc", name: "Claude", symbol: "asterisk", items: [
            UsageGlanceItem(tag: nil, what: L("Claude 5 小時"), bucket: find(buckets) { $0 == five }),
            UsageGlanceItem(tag: nil, what: L("Claude 每週"), bucket: find(buckets) { $0 == week }),
        ])]
        if CodexBridge.installed || !codexBuckets.isEmpty {
            out.append(UsageGlanceGroup(key: "codex", name: "Codex", symbol: "hexagon", items: [
                UsageGlanceItem(tag: nil, what: L("Codex 5 小時"), bucket: find(codexBuckets) { $0 == five }),
                UsageGlanceItem(tag: nil, what: L("Codex 每週"), bucket: find(codexBuckets) { $0 == week }),
            ]))
        }
        if AgyBridge.enabled || !agyBuckets.isEmpty {
            out.append(UsageGlanceGroup(key: "agy", name: "agy", symbol: "sparkle", items: [
                UsageGlanceItem(tag: nil, what: L("agy Gemini 5 小時（3.8 Flash 等共用）"), bucket: find(agyBuckets) { $0.hasPrefix("Gemini") && $0.hasSuffix(five) }, detail: magpieQuotaTips["Gemini 5 小時"]),
                UsageGlanceItem(tag: nil, what: L("agy Gemini 每週"), bucket: find(agyBuckets) { $0.hasPrefix("Gemini") && $0.hasSuffix(week) }, detail: magpieQuotaTips["Gemini 每週"]),
                UsageGlanceItem(tag: L("阿公"), what: L("agy 阿公（Argon）每週"), bucket: find(agyBuckets) { $0.contains("Argon") && $0.hasSuffix(week) }, detail: magpieQuotaTips["Argon 每週"]),
            ]))
        }
        return out
    }
}
