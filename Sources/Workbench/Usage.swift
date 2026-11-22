import SwiftUI
import Foundation
import Combine
import AppKit

// 右側欄位上面的用量：5 小時剩多少、每週剩多少、Fable 這類模型自己的額度池剩多少。
// 資料來源是 Claude Code 自己的 /usage（claude -p "/usage" --no-session-persistence）：本機查詢、不叫模型、不留對話紀錄，
// 也不用工作台去碰使用者的登入憑證。每 5 分鐘查一次，點一下面板立刻查。
// 有裝 agy（Gemini，AgyBridge.swift）的話也查它的 /usage（agy -p=/usage）：Gemini 和 agy 裡 Claude／GPT 的額度池，另外列一組。
// Codex 額度優先讀 magpie accounts codex；app-server 保留目前帳號的免費重置券與 Magpie 失敗時的退路。
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

    var maskedName: String { Self.mask(name) }

    static func mask(_ name: String) -> String {
        if let at = name.lastIndex(of: "@") {
            return String(name[..<at].prefix(3)) + "***" + String(name[at...])
        }
        return name.count <= 3 ? "***" : String(name.prefix(3)) + "***"
    }
}

struct CodexUsageAccountQuota: Identifiable {
    let id: String
    let user: String
    let alias: String?
    let plan: String
    let active: Bool
    let buckets: [UsageBucket]
    let resetCredits: Int
    let resetExpiries: [Date]

    init(id: String, user: String, plan: String, active: Bool, buckets: [UsageBucket],
         resetCredits: Int, resetExpiries: [Date], alias: String? = nil) {
        self.id = id
        self.user = user
        let cleanedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alias = cleanedAlias?.isEmpty == false ? cleanedAlias : nil
        self.plan = plan
        self.active = active
        self.buckets = buckets
        self.resetCredits = resetCredits
        self.resetExpiries = resetExpiries
    }

    var displayPlan: String {
        let value = plan.lowercased()
        if value.contains("plus") { return "Plus" }
        if value.contains("pro") { return "Pro" }
        if value.contains("free") { return L("免費") }
        return plan.isEmpty ? L("未知方案") : plan
    }

    var maskedUser: String {
        guard let at = user.lastIndex(of: "@") else { return user }
        return String(user[..<at].prefix(3)) + "***" + String(user[at...])
    }
}

struct CodexUsageSnapshot {
    let accounts: [CodexUsageAccountQuota]
    let currentBuckets: [UsageBucket]
    let resetCredits: Int
    let resetExpiries: [Date]
    let usedMagpie: Bool
}

struct ExtraKeyPool: Identifiable {
    let name: String
    let source: String
    let buckets: [UsageBucket]
    var notes: [String] = []        // 卡片下方的附註（OpenRouter 付費帳號的花費摘要）
    var message: String? = nil      // 取代整張卡片內容的說明（例如「沒權限讀金鑰（鑰匙圈）」）
    var actionTitle: String? = nil
    var actionURL: String? = nil
    var kaggleQuotas: [KaggleQuotaLine] = []
    var id: String { name }
}

struct ClaudeLoginExpiry: Equatable {
    enum Level: Equatable {
        case normal, warning, expired
    }
    let expiresAt: Date
}

enum Agy2QuotaStatus: Equatable {
    case down
    case unreadable
    case available([UsageBucket])
}

/// 執行唯讀外部查詢指令：以獨立行程群組啟動，結束或逾時後一律清理整個行程群組（SIGTERM，1 秒後仍未結束再 SIGKILL）。
enum ExternalCommand {
    struct Result {
        let stdout: String
        let stderr: String
        let status: Int32
        let timedOut: Bool
        let eofTimedOut: Bool

        var succeeded: Bool { !timedOut && !eofTimedOut && status == 0 }

        init(
            stdout: String,
            stderr: String = "",
            status: Int32,
            timedOut: Bool,
            eofTimedOut: Bool = false
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.status = status
            self.timedOut = timedOut
            self.eofTimedOut = eofTimedOut
        }
    }

    static func environment(arguments: [String] = CommandLine.arguments) -> [String: String]? {
        guard !arguments.contains("--state-dir") else { return nil }
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        for dir in extra where !parts.contains(dir) {
            parts.append(dir)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 5,
        killGrace: TimeInterval = 1,
        environment: [String: String]? = ExternalCommand.environment()
    ) -> Result? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        // 包一層 perl 建新 session／行程群組領頭後再 exec，確保 pid == pgid 且不接控制終端。
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "use POSIX (); POSIX::setsid(); exec {$ARGV[0]} @ARGV or exit 127",
            executable
        ] + arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        var didTimeout = false
        let outEOF = DispatchSemaphore(value: 0)
        let errEOF = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)

        func attachReader(
            _ handle: FileHandle,
            eof: DispatchSemaphore,
            append: @escaping (Data) -> Void
        ) {
            handle.readabilityHandler = { readable in
                let chunk = readable.availableData
                if chunk.isEmpty {
                    readable.readabilityHandler = nil
                    eof.signal()
                    return
                }
                append(chunk)
            }
        }

        attachReader(outPipe.fileHandleForReading, eof: outEOF) { chunk in
            lock.lock()
            outData.append(chunk)
            lock.unlock()
        }
        attachReader(errPipe.fileHandleForReading, eof: errEOF) { chunk in
            lock.lock()
            errData.append(chunk)
            lock.unlock()
        }
        process.terminationHandler = { _ in
            exited.signal()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let pid = process.processIdentifier
        let finishedInTime = exited.wait(timeout: .now() + timeout) == .success

        if !finishedInTime {
            lock.lock()
            didTimeout = true
            lock.unlock()

            cleanupProcessGroup(pid: pid, process: process, killGrace: killGrace)
            _ = exited.wait(timeout: .now() + 0.5)
        } else {
            process.waitUntilExit()
        }

        let eofDeadline = DispatchTime.now() + (didTimeout ? 0.25 : 2.0)
        let outGotEOF = outEOF.wait(timeout: eofDeadline) == .success
        let errGotEOF = errEOF.wait(timeout: eofDeadline) == .success
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let eofTimedOut = !outGotEOF || !errGotEOF
        // 正常結束且 EOF 正常到達時不做群組清理（避免 pid 重用誤殺）；
        // 僅在 EOF 等待逾時（疑似殘留持有管線的子程序）時才清理一次，不重試。
        if finishedInTime && eofTimedOut {
            cleanupProcessGroup(pid: pid, process: process, killGrace: killGrace)
        }

        lock.lock()
        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        let timedOut = didTimeout
        lock.unlock()

        let status: Int32 = timedOut ? -1 : process.terminationStatus
        return Result(
            stdout: stdout,
            stderr: stderr,
            status: status,
            timedOut: timedOut,
            eofTimedOut: eofTimedOut
        )
    }

    private static func cleanupProcessGroup(pid: pid_t, process: Process, killGrace: TimeInterval) {
        guard pid > 1 else {
            if process.isRunning { process.terminate() }
            return
        }
        let pgid = getpgid(pid)
        let ownGroupID = getpgrp()
        let hasOwnGroup: Bool
        if pid == ownGroupID {
            hasOwnGroup = false
        } else if pgid == pid {
            hasOwnGroup = true
        } else if pgid == -1 {
            // 主行程已結束並被 waitpid 回收時 getpgid(pid) 會回 -1（ESRCH）；
            // 僅在 killpg(pid, 0) 成功（確認同屬我們的行程群組仍存活）時才清理，
            // 失敗（如 ESRCH、EPERM）一律不動。
            hasOwnGroup = killpg(pid, 0) == 0
        } else {
            hasOwnGroup = false
        }

        if pgid == -1 && !hasOwnGroup {
            return
        }

        func isGroupAlive() -> Bool {
            guard hasOwnGroup else { return false }
            return killpg(pid, 0) == 0
        }

        guard process.isRunning || isGroupAlive() else { return }

        if hasOwnGroup {
            _ = killpg(pid, SIGTERM)
        } else if process.isRunning {
            process.terminate()
        }

        let graceDeadline = Date().addingTimeInterval(killGrace)
        while Date() < graceDeadline {
            if !process.isRunning && !isGroupAlive() { break }
            Thread.sleep(forTimeInterval: 0.025)
        }

        if process.isRunning || isGroupAlive() {
            if hasOwnGroup { _ = killpg(pid, SIGKILL) }
            if process.isRunning { _ = kill(pid, SIGKILL) }
            let killDeadline = Date().addingTimeInterval(1.0)
            while Date() < killDeadline {
                if !process.isRunning && !isGroupAlive() { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
    }
}

/// 同種查詢只允許一個進行中；TTL 內或進行中時直接回傳快取／舊值，不排隊也不重啟外部指令。
private final class SingleFlightTTLProbe<Value> {
    private let lock = NSLock()
    private let ttl: TimeInterval
    private var inFlight = false
    private var checkedAt: Date?
    private var cached: Value

    init(ttl: TimeInterval, initial: Value) {
        self.ttl = ttl
        self.cached = initial
    }

    func value(now: Date = Date(), fetch: () -> Value) -> Value {
        lock.lock()
        if inFlight {
            let previous = cached
            lock.unlock()
            return previous
        }
        if let checkedAt, now.timeIntervalSince(checkedAt) >= 0, now.timeIntervalSince(checkedAt) < ttl {
            let current = cached
            lock.unlock()
            return current
        }
        inFlight = true
        lock.unlock()

        let next = fetch()

        lock.lock()
        cached = next
        checkedAt = now
        inFlight = false
        lock.unlock()
        return next
    }

    func reset(to initial: Value) {
        lock.lock()
        inFlight = false
        checkedAt = nil
        cached = initial
        lock.unlock()
    }
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

/// `--usage-panel-move` 的單筆移動指令（`<來源key>:<目標key>`）。
struct UsagePanelMoveSpec: Equatable {
    let sourceKey: String
    let targetKey: String
    let after: Bool

    init(sourceKey: String, targetKey: String, after: Bool = false) {
        self.sourceKey = sourceKey
        self.targetKey = targetKey
        self.after = after
    }

    var dropTarget: UsageCardOrder.DropTarget {
        if targetKey.isEmpty { return .end }
        return after ? .after(targetKey) : .before(targetKey)
    }
}

/// `--usage-panel-screen <寬>x<高>[+<左缺>]` 模擬螢幕可見區規格。
struct UsagePanelScreenSpec: Equatable {
    let width: CGFloat
    let height: CGFloat
    let leftInset: CGFloat

    func visibleFrame(baseOrigin: CGPoint = .zero) -> CGRect {
        CGRect(x: baseOrigin.x + leftInset, y: baseOrigin.y, width: width, height: height)
    }
}

/// `--usage-panel-open`、`--usage-panel-dump <檔>` 與 r2 面板測試旗標的隔離設定（只在 `--state-dir` 測試實例生效）。
struct UsagePanelDumpConfig: Equatable {
    let isTestInstance: Bool
    let openOnLaunch: Bool
    let dumpURL: URL?
    let parentSize: CGSize?
    let screenSpec: UsagePanelScreenSpec?
    let uiScaleOverride: CGFloat?
    let moves: [UsagePanelMoveSpec]

    var hasAnyPanelHook: Bool {
        openOnLaunch || dumpURL != nil || parentSize != nil || screenSpec != nil || uiScaleOverride != nil || !moves.isEmpty
    }

    static func current() -> UsagePanelDumpConfig {
        from(arguments: CommandLine.arguments)
    }

    static func parseSize(_ raw: String) -> CGSize? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "x", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]),
              w.isFinite, h.isFinite, w > 0, h > 0 else {
            return nil
        }
        return CGSize(width: CGFloat(w), height: CGFloat(h))
    }

    static func parseScreenSpec(_ raw: String) -> UsagePanelScreenSpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "+", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let size = parseSize(String(parts[0])) else {
            return nil
        }
        let leftInset: Double
        if parts.count == 2 {
            guard let inset = Double(parts[1]), inset.isFinite, inset >= 0 else { return nil }
            leftInset = inset
        } else {
            leftInset = 0
        }
        return UsagePanelScreenSpec(width: size.width, height: size.height, leftInset: CGFloat(leftInset))
    }

    static func parseUIScale(_ raw: String) -> CGFloat? {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0, value <= 4.0 else {
            return nil
        }
        return CGFloat(value)
    }

    private static func isValidCardKey(_ key: String) -> Bool {
        if key.hasPrefix("pool:") { return key.count > 5 }
        if key.hasPrefix("extra:") { return key.count > 6 }
        return false
    }

    /// 解析舊 `<來源key>:<目標key>` 與新 `<來源key>:before|after:<目標key>`；key 本身可含冒號。
    static func parseMoveSpecs(_ raw: String) -> [UsagePanelMoveSpec] {
        var specs: [UsagePanelMoveSpec] = []
        for segment in raw.split(separator: ",", omittingEmptySubsequences: true) {
            let token = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            var parsed: UsagePanelMoveSpec?
            for (marker, after) in [(":before:", false), (":after:", true)] {
                var search = token.startIndex
                while search < token.endIndex,
                      let range = token.range(of: marker, range: search..<token.endIndex) {
                    let sourceKey = String(token[..<range.lowerBound])
                    let targetKey = String(token[range.upperBound...])
                    if isValidCardKey(sourceKey), isValidCardKey(targetKey) {
                        parsed = UsagePanelMoveSpec(sourceKey: sourceKey, targetKey: targetKey, after: after)
                        break
                    }
                    search = range.upperBound
                }
                if parsed != nil { break }
            }
            if parsed == nil, token.hasSuffix(":end") {
                let sourceKey = String(token.dropLast(4))
                if isValidCardKey(sourceKey) {
                    parsed = UsagePanelMoveSpec(sourceKey: sourceKey, targetKey: "", after: true)
                }
            }
            if parsed == nil {
                let searchStart = token.index(after: token.startIndex)
                let poolSep = token.range(of: ":pool:", options: .backwards, range: searchStart..<token.endIndex)
                let extraSep = token.range(of: ":extra:", options: .backwards, range: searchStart..<token.endIndex)
                let chosen: Range<String.Index>?
                switch (poolSep, extraSep) {
                case let (p?, e?): chosen = p.lowerBound >= e.lowerBound ? p : e
                case let (p?, nil): chosen = p
                case let (nil, e?): chosen = e
                case (nil, nil): chosen = nil
                }
                if let sep = chosen {
                    let sourceKey = String(token[..<sep.lowerBound])
                    let targetKey = String(token[token.index(after: sep.lowerBound)...])
                    if isValidCardKey(sourceKey), isValidCardKey(targetKey) {
                        parsed = UsagePanelMoveSpec(sourceKey: sourceKey, targetKey: targetKey, after: false)
                    }
                }
            }
            if let parsed { specs.append(parsed) }
        }
        return specs
    }

    static func from(arguments: [String]) -> UsagePanelDumpConfig {
        func flagValue(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            let val = arguments[i + 1]
            return val.isEmpty || val.hasPrefix("--") ? nil : val
        }
        guard let rawState = flagValue("--state-dir") else {
            return UsagePanelDumpConfig(
                isTestInstance: false,
                openOnLaunch: false,
                dumpURL: nil,
                parentSize: nil,
                screenSpec: nil,
                uiScaleOverride: nil,
                moves: []
            )
        }
        let stateRoot = URL(fileURLWithPath: rawState, isDirectory: true).standardizedFileURL
        var resolvedDump: URL?
        if let rawDump = flagValue("--usage-panel-dump") {
            let candidate = URL(fileURLWithPath: rawDump).standardizedFileURL
            if isTestProbeOutput(candidate, inside: stateRoot) {
                resolvedDump = candidate
            }
        }
        return UsagePanelDumpConfig(
            isTestInstance: true,
            openOnLaunch: arguments.contains("--usage-panel-open"),
            dumpURL: resolvedDump,
            parentSize: flagValue("--usage-panel-parent-size").flatMap(parseSize),
            screenSpec: flagValue("--usage-panel-screen").flatMap(parseScreenSpec),
            uiScaleOverride: flagValue("--usage-panel-ui-scale").flatMap(parseUIScale),
            moves: flagValue("--usage-panel-move").map(parseMoveSpecs) ?? []
        )
    }
}

struct UsagePanelCardSnapshot: Equatable {
    let key: String
    let title: String
    let lines: [String]
}

final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()
    static let extraKeychainReadTimeout: TimeInterval = 5
    static let extraStaleInterval: TimeInterval = 5 * 60
    enum AgyLastOutcome: String, Equatable {
        case ok, failed, stopped, skipped, none
    }

    @Published var buckets: [UsageBucket] = []
    @Published var agyBuckets: [UsageBucket] = []
    @Published var agySwapMode = false
    @Published var agySwapAccounts: [AgySwapAccountDisplay] = []
    @Published var agyActiveAccount: String? = nil
    @Published var lastAgyOutcome: AgyLastOutcome = .none
    @Published var agyLoading = false
    @Published var magpieQuotaTips: [String: String] = [:]
    @Published var magpieAccounts: [MagpieAccountQuota] = []
    @Published var codexBuckets: [UsageBucket] = []
    @Published var codexAccounts: [CodexUsageAccountQuota] = []
    @Published var codexResets = 0      // Codex 送的「全部重置」還有幾次沒用
    @Published var codexResetExpiries: [Date] = []   // 每一張重置券什麼時候過期（早的在前；後端有給明細才有，不會過期的不列）
    @Published var codexResetBusy = false           // 正在呼叫 consume（按鈕變灰）
    @Published var codexResetStatus: String?        // 重置的結果（白話，貼在 Codex 那組的附註下面，一陣子後清掉）
    @Published var copilotBuckets: [UsageBucket] = []
    @Published var copilotNote = ""     // 「剩 199／200 次」
    @Published var copilotFootnote: String? = nil
    @Published var copilotRemaining: Int? = nil
    @Published var copilotTotal: Int? = nil
    @Published var claudeLoginExpiry: ClaudeLoginExpiry? = nil
    @Published var agy2Status: Agy2QuotaStatus? = nil
    @Published private(set) var extraKeyPools: [ExtraKeyPool] = []
    @Published private(set) var localExtraPools: [ExtraKeyPool] = []
    @Published private(set) var extraLoadedAt: Date? = nil
    @Published var updated: Date?
    @Published var loading = false
    @Published var error: String?
    private var timer: Timer?
    private var extraRemoteInFlight = false
    private var extraLocalInFlight = false
    private var extraRemoteDone = false
    private var extraLocalDone = false

    /// 畫面上實際顯示的所有額外卡（遠端／鑰匙圈額外卡串接純本機額外卡）。
    var allExtraKeyPools: [ExtraKeyPool] { extraKeyPools + localExtraPools }
    var isExtraRefreshInFlight: Bool { extraRemoteInFlight || extraLocalInFlight }
    private let claudeLoginProbe = SingleFlightTTLProbe<ClaudeLoginExpiry?>(ttl: 30 * 60, initial: nil)
    private let agy2Probe = SingleFlightTTLProbe<Agy2QuotaStatus?>(ttl: 10 * 60, initial: nil)
    private let agySwapModeTracker = AgySwapModeTracker()
    private let agyContainerTracker = AgyContainerAttemptTracker()
    /// 最近一輪成功進入換帳號模式的 status（供後續 status 失敗 `.skipRound` 時顯示磁碟舊快取）。
    private var lastSuccessfulSwapStatus: AgySwapStatus? = nil
    /// 記憶體中的即時 agy 額度改以帳號為鍵，防止切換帳號後新現用無資料時顯示舊帳號數字。
    private var agyLiveBucketsByAccount: [String: [UsageBucket]] = [:]
    private var agyLegacyAccountName: String? = nil
    /// legacy 模式下若由 `.skipRound` 掃到單一磁碟舊快取，記錄其 `read_at` 與 `source`（僅用於顯示與 dump，絕不設 `agySwapAccounts` 或 `agySwapMode`）。
    private var agyLegacyCachedReadAt: Date? = nil
    private var agyLegacyCachedSource: String? = nil
    /// 本輪換帳號容器讀取時 docker CLI 被呼叫的總次數（供 `--usage-card-dump` 的 `containerCalls` 使用）。
    private(set) var lastRoundContainerCalls: Int = 0
    private var refreshCycleID: UInt64 = 0

    func resetContainerAttemptTrackerForTest() {
        agyContainerTracker.reset()
    }

    /// 統一換帳號多帳號顯示門檻（fix2 第 3 項）：`UsageFullPage`／`UsagePanel`／`agyGlanceGroup`／dump 一律看 `agySwapMode && !agySwapAccounts.isEmpty`。
    var usesSwapAccountDisplay: Bool {
        agySwapMode && !agySwapAccounts.isEmpty
    }
    private var mainCycleDone = false
    private var mainCycleGotClaude = false
    private var mainCycleGotOther = false
    private var agyCycleGotData = false

    private convenience init() {
        self.init(startMonitoring: true)
    }

    static func makeForUnitTest() -> UsageMonitor {
        UsageMonitor(startMonitoring: false)
    }

    private init(startMonitoring: Bool) {
        guard startMonitoring else { return }
        refresh(includeExtraKeys: false)
        // 網路回來（例如斷網一陣子）：馬上補查一次，不用等下一輪
        AgyNet.start()
        NotificationCenter.default.addObserver(forName: AgyNet.back, object: nil, queue: .main) { [weak self] _ in self?.refresh(includeExtraKeys: false) }
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

    /// 判斷額外卡是否需要補刷新：從未載入或距上次載入超過 5 分鐘。
    static func shouldRefreshExtraPools(lastLoadedAt: Date?, now: Date = Date(),
                                        interval: TimeInterval = extraStaleInterval) -> Bool {
        guard let lastLoadedAt else { return true }
        return now.timeIntervalSince(lastLoadedAt) > interval
    }

    /// 面板顯示時檢查額外卡是否尚未載入或過期；不受 `loading` 影響，單獨刷新額外卡（不動其他來源）。
    @discardableResult
    func refreshExtraPoolsIfStale(now: Date = Date(), trigger: (() -> Void)? = nil) -> Bool {
        guard Self.shouldRefreshExtraPools(lastLoadedAt: extraLoadedAt, now: now) else {
            return false
        }
        if let trigger {
            trigger()
        } else {
            refreshExtraKeyPools()
        }
        return true
    }

    /// 供單元測試設定額外卡與上次載入時間。
    func setExtraLoadedAtForTest(_ date: Date?) {
        extraLoadedAt = date
    }

    func setExtraPoolsForTest(remote: [ExtraKeyPool], local: [ExtraKeyPool] = []) {
        extraKeyPools = remote
        localExtraPools = local
    }

    /// 供單元測試驗證本機額外卡與遠端額外卡為獨立背景路徑，以及完成後的 `extraLoadedAt` 更新。
    func runExtraKeyRefreshForTest(
        remote: @escaping () -> [ExtraKeyPool],
        local: @escaping () -> [ExtraKeyPool],
        now: @escaping () -> Date = Date.init,
        onLocalUpdated: (() -> Void)? = nil,
        onAllCompleted: (() -> Void)? = nil
    ) {
        let startRemote = !extraRemoteInFlight
        let startLocal = !extraLocalInFlight
        guard startRemote || startLocal else { return }
        if startRemote {
            extraRemoteInFlight = true
            extraRemoteDone = false
        }
        if startLocal {
            extraLocalInFlight = true
            extraLocalDone = false
        }
        if startLocal {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let localPools = local()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.localExtraPools = localPools
                    self.extraLocalInFlight = false
                    self.extraLocalDone = true
                    onLocalUpdated?()
                    self.finishExtraKeyRefreshIfComplete(now: now, onCompleted: onAllCompleted)
                }
            }
        }
        if startRemote {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let remotePools = remote()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.extraKeyPools = remotePools
                    self.extraRemoteInFlight = false
                    self.extraRemoteDone = true
                    self.finishExtraKeyRefreshIfComplete(now: now, onCompleted: onAllCompleted)
                }
            }
        }
    }

    private func finishExtraKeyRefreshIfComplete(now: () -> Date = Date.init, onCompleted: (() -> Void)? = nil) {
        guard !extraRemoteInFlight && !extraLocalInFlight && extraRemoteDone && extraLocalDone else { return }
        extraLoadedAt = now()
        onCompleted?()
        UsageSheet.schedulePanelDumpIfNeeded()
    }

    private static func makeLocalExtraKeySources(isolated: Bool, arguments: [String], environment: [String: String]) -> ExtraKeySources {
        if isolated {
            if let path = environment["CODENV_EXTRA_KEY_FAKE"],
               let data = FileManager.default.contents(atPath: path),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return .fake(root)
            }
            return .isolatedEmpty()
        }
        var sources = ExtraKeySources.isolatedEmpty()
        sources.fetchQwenLedger = { ExtraKeyPools.fetchQwenLedger(arguments: arguments) }
        return sources
    }

    /// 從鑰匙圈讀 OpenRouter／Groq／DeepSeek key，並以獨立快速背景 job 讀純本機 Qwen 帳本；
    /// 只保留額度數字，不把 credential 放進狀態或畫面（解析與卡片組裝在 ExtraKeyPools.swift）。
    private func refreshExtraKeyPools() {
        let isolated = KeyVault.isTestInstance
        let startRemote = !extraRemoteInFlight
        let startLocal = !extraLocalInFlight
        guard startRemote || startLocal else { return }
        if startRemote {
            extraRemoteInFlight = true
            extraRemoteDone = false
        }
        if startLocal {
            extraLocalInFlight = true
            extraLocalDone = false
        }
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment

        if startLocal {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let localSources = Self.makeLocalExtraKeySources(isolated: isolated, arguments: args, environment: env)
                let localPools = ExtraKeyPools.localPools(localSources)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.localExtraPools = localPools
                    self.extraLocalInFlight = false
                    self.extraLocalDone = true
                    self.finishExtraKeyRefreshIfComplete()
                }
            }
        }

        if startRemote {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let sources: ExtraKeySources
                let poolUsage = PoolUsageSnapshot.load()
                if isolated {
                    // 測試實例不連網、不讀正式鑰匙圈；CODENV_EXTRA_KEY_FAKE 與 --state-dir/pool-usage.json 都是本題假資料。
                    let deepSeekBaseURL = ExtraKeyPools.deepSeekTestBaseURL(arguments: args)
                    if let path = env["CODENV_EXTRA_KEY_FAKE"],
                       let data = FileManager.default.contents(atPath: path),
                       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        sources = .fake(root, poolUsage: poolUsage, deepSeekBaseURL: deepSeekBaseURL)
                    } else {
                        sources = .isolatedEmpty(poolUsage: poolUsage)
                    }
                } else {
                    // codenv 自己用 SecItemAdd 存的項目（有末四碼註解）：走原本 KeyVault 路徑，ACL 只有 codenv，不會跳授權。
                    // 外部用指令建的項目（沒有末四碼註解）：改叫系統 security 讀，ACL 信任它，才不會跳 codenv 的授權視窗。
                    // 分辨只用屬性查詢（KeyVault.status，不讀祕密內容、不跳視窗）。
                    func externalKey(_ service: String) -> KeyVault.Read {
                        if KeyVault.isCodenvOwned(service: service) { return KeyVault.classify(KeyVault.reader(service)) }
                        guard let value = NonoSandbox.keychain(service: service,
                                                               timeout: Self.extraKeychainReadTimeout), !value.isEmpty else { return .missing }
                        return .value(value)
                    }
                    // 只判斷有沒有：不讀出祕密內容（security 不帶 -w）
                    func externalHasKey(_ service: String) -> Bool {
                        if KeyVault.isCodenvOwned(service: service) { return true }
                        return NonoSandbox.keychainExists(service: service, timeout: Self.extraKeychainReadTimeout)
                    }
                    sources = ExtraKeySources(
                        readKey: { externalKey(KeyVault.service($0)) },
                        hasKey: { id in
                            switch id {
                            case "nvidia": return externalHasKey(KeyVault.service("nvidia"))
                            case "ai_studio": return externalHasKey(KeyVault.service("gemini-free"))
                            case "kaggle": return externalHasKey("kaggle-api-token")
                            default: return false
                            }
                        },
                        fetchOpenRouter: { Self.probe(url: "https://openrouter.ai/api/v1/key", key: $0)?.data },
                        fetchGroq: { ExtraKeyPools.groqProbe(key: $0) },
                        fetchDeepSeek: { ExtraKeyPools.fetchDeepSeekBalance(key: $0, baseURL: ExtraKeyPools.officialDeepSeekBaseURL).data },
                        fetchKaggleQuota: { ExtraKeyPools.fetchKaggleQuota() },
                        fetchQwenLedger: { ExtraKeyPools.fetchQwenLedger(arguments: args) },
                        localEstimate: { Self.localEstimate(service: $0) },
                        poolUsage: poolUsage,
                        now: Date.init)
                }
                let pools = ExtraKeyPools.pools(sources)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.extraKeyPools = pools
                    self.extraRemoteInFlight = false
                    self.extraRemoteDone = true
                    self.finishExtraKeyRefreshIfComplete()
                }
            }
        }
    }

    private static func localEstimate(service: String) -> [UsageBucket] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = support.appendingPathComponent("codenv", isDirectory: true).appendingPathComponent("key-usage.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = root[service] as? [String: Any],
              let date = row["date"] as? String,
              date == String(ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date())).prefix(10)),
              let calls = row["calls"] as? Int, let limit = row["limit"] as? Int, limit > 0 else { return [] }
        let remaining = max(0, min(100, Int((Double(limit - calls) / Double(limit) * 100).rounded())))
        return [UsageBucket(label: "今天呼叫 \(calls)／\(limit) 次", used: 100 - remaining, resets: "")]
    }

    private static func probe(url: String, key: String) -> (data: Data, headers: [String: String])? {
        guard !KeyVault.isTestInstance else { return nil }
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data, [String: String])?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = (data, Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
                    guard let k = key as? String, let v = value as? String else { return nil }; return (k.lowercased(), v)
                }))
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 13)
        return result.map { (data: $0.0, headers: $0.1) }
    }

    func refresh(includeExtraKeys: Bool = true) {
        guard !loading else { return }
        if includeExtraKeys { refreshExtraKeyPools() }
        let testInstance = CommandLine.arguments.contains("--state-dir")
        let swapConfig = AgySwapConfig.current()
        let startedAt = Date()
        if CommandLine.arguments.contains("--state-dir"), ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE"] == "1", let prefix = ProcessInfo.processInfo.environment["CODENV_CODEX_RESET_SHOT"] {
            let line = "假查詢開始（\(Date().timeIntervalSince1970 - Self.t0 > 0 ? String(format: "%.1f", Date().timeIntervalSince1970 - Self.t0) : "0") 秒）\n"
            if let h = FileHandle(forWritingAtPath: prefix + ".txt") { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: prefix + ".txt", atomically: true, encoding: .utf8) }
        }
        // 測試用：CODENV_USAGE_FAKE=1 不查任何真的用量，直接放一組假資料（五家都有，Codex 有免費重置、Copilot 有剩餘次數）。
        // CODENV_USAGE_FAKE_DELAY=<秒>：假的查詢要這麼久才回來（測重置後讀回新次數之前按鈕要維持停用）
        // 若同時給了 --usage-fake 與 --agy-usage-test（含 --agy-swap-bin），其他來源照假資料顯示，agy 分支另外走真實流程（規格 3 F）。
        if ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE"] == "1"
            || (CommandLine.arguments.contains("--state-dir") && CommandLine.arguments.contains("--usage-fake")) {
            let runRealAgyBranch = swapConfig.usageSwapEnabled
            let cycle = beginRefreshCycleOnMain()
            if runRealAgyBranch && !agyLoading {
                startAgyRefreshBranch(cycle: cycle, config: swapConfig, fakeMainMode: true)
            }
            let apply = { [weak self] in
                guard let self else { return }
                if self.resetSettledAt != nil, Self.fakeReadFailsLeft > 0 {
                    Self.fakeReadFailsLeft -= 1
                    self.loading = false
                    self.codexReadFinished(startedAt: startedAt, success: false)
                    self.writeUsageCardDumpIfNeeded()
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
                if !runRealAgyBranch {
                    // 跟真的 parseAgy 結果同一種標籤（11/7 實際：Gemini 5 小時／每週、Claude 5 小時／每週、Argon 只有每週）
                    self.agyLegacyCachedReadAt = nil
                    self.agyLegacyCachedSource = nil
                    self.lastRoundContainerCalls = 0
                    self.agyBuckets = [UsageBucket(label: "Gemini 5 小時", used: 6, resets: h(3, 41), resetAt: r(3, 41)), UsageBucket(label: "Gemini 每週", used: 2, resets: h(6*24+21, 5), resetAt: r(6*24+21, 5)),
                                       UsageBucket(label: "Claude 5 小時", used: 0, resets: h(3, 41), resetAt: r(3, 41)), UsageBucket(label: "Claude 每週", used: 55, resets: h(4*24+18, 30), resetAt: r(4*24+18, 30)),
                                       UsageBucket(label: "Argon 每週", used: ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_ARGON_LOW"] == "1" ? 85 : 0, resets: h(6*24+23, 12), resetAt: r(6*24+23, 12))]
                }
                // CODENV_USAGE_FAKE_CODEX_HIGH=1：用量比較高的版本（測「用量還不高」那句不出現）
                let hi = ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_CODEX_HIGH"] == "1"
                self.codexBuckets = [UsageBucket(label: "5 小時", used: hi ? 72 : 5, resets: h(1, 48), resetAt: r(1, 48)), UsageBucket(label: "每週", used: hi ? 88 : 47, resets: h(5*24+9, 20), resetAt: r(5*24+9, 20))]
                self.codexAccounts = []
                self.codexResets = Self.fakeResetsLeft
                self.codexResetExpiries = Array([Date().addingTimeInterval(2 * 86400), Date().addingTimeInterval(26 * 86400), Date().addingTimeInterval(27 * 86400)].prefix(Self.fakeResetsLeft))
                self.reconcilePendingKey()
                let copilotStudent = ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_COPILOT_STUDENT"] == "1"
                let copilotResetAt = copilotStudent ? r(14 * 24, 0) : r(23 * 24 + 4, 0)
                let copilotRemaining = copilotStudent ? 199 : 194
                let copilotTotal = 200
                let copilotUsed = copilotStudent ? 1 : 3
                self.copilotBuckets = [UsageBucket(label: L("每月"), used: copilotUsed, resets: Self.when(copilotResetAt), resetAt: copilotResetAt)]
                self.copilotNote = copilotStudent ? L("剩 199／200 次額度") : "剩 194／200 次"
                self.copilotFootnote = copilotStudent ? L("補全不限，對話用額度") : nil
                self.copilotRemaining = copilotRemaining
                self.copilotTotal = copilotTotal
                if let rawExpiry = ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_LOGIN_EXPIRES"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let seconds = Double(rawExpiry), seconds.isFinite {
                    self.claudeLoginExpiry = ClaudeLoginExpiry(expiresAt: Date().addingTimeInterval(seconds))
                } else {
                    self.claudeLoginExpiry = nil
                }
                if !runRealAgyBranch {
                    self.agy2Status = Self.fakeAgy2StatusFromEnv(h: h, r: r)
                }
                self.updated = Date(); self.error = nil
                self.mainCycleDone = true
                self.mainCycleGotClaude = true
                self.mainCycleGotOther = true
                if CommandLine.arguments.contains("--state-dir") {
                    var obs = UsageLog.percentages(self.buckets, source: "Claude Code")
                        + UsageLog.percentages(self.codexBuckets, source: "Codex")
                        + [UsageLog.Observation(pool: "Copilot · Chat / 每月", kind: "count", remaining: copilotRemaining, total: copilotTotal, resetAt: self.copilotBuckets.first?.resetAt)]
                    if !runRealAgyBranch {
                        obs += UsageLog.percentages(self.agyBuckets, source: "agy")
                    }
                    UsageLog.record(obs)
                }
                self.loading = false
                self.codexReadFinished(startedAt: startedAt, success: true)
                self.writeUsageCardDumpIfNeeded()
            }
            if let d = Double(ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_DELAY"] ?? ""), d > 0 {
                loading = true
                DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: apply)
            } else { apply() }
            return
        }
        let cycle = beginRefreshCycleOnMain()
        loading = true
        // agy 分支（含依帳號數決定的 agy2）從 DispatchGroup g 拆出，避免拖住 Claude／Codex／Copilot。
        if !agyLoading {
            startAgyRefreshBranch(cycle: cycle, config: swapConfig, fakeMainMode: false)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 非 agy 來源同時查（各自最多 60 秒）
            var codexOut: [String: Any]?
            var codexMagpieData: Data?
            var copilotOut: String?
            var loginExpiry: ClaudeLoginExpiry?
            let g = DispatchGroup()
            g.enter()
            DispatchQueue.global(qos: .utility).async {
                if CommandLine.arguments.contains("--state-dir") {
                    if let fake = ProcessInfo.processInfo.environment["CODENV_MAGPIE_CODEX_FAKE"] {
                        codexMagpieData = fake.data(using: .utf8)
                    }
                } else if let output = Self.run("/Applications/magpie.app/Contents/MacOS/magpie", ["accounts", "codex", "--json"]) {
                    codexMagpieData = output.data(using: .utf8)
                }
                g.leave()
            }
            if CodexBridge.installed {
                g.enter()
                DispatchQueue.global(qos: .utility).async { codexOut = Self.runCodex(); g.leave() }
            }
            if !testInstance, Self.ghPath != nil {
                g.enter()
                DispatchQueue.global(qos: .utility).async { copilotOut = Self.run(Self.ghPath!, ["api", "/copilot_internal/user"]); g.leave() }
            }
            if let self {
                g.enter()
                DispatchQueue.global(qos: .utility).async { loginExpiry = self.fetchClaudeLoginExpiryCached(); g.leave() }
            }
            let out = testInstance ? nil : Self.run("claude", ["-p", "/usage", "--no-session-persistence"])
            g.wait()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.claudeLoginExpiry = loginExpiry
                var gotOther = false
                let recordedAt = Date()
                var observations: [UsageLog.Observation] = []
                let codex = Self.resolveCodexUsage(magpieData: codexMagpieData, appServerResult: codexOut)
                self.codexAccounts = codex.accounts
                var codexOK = false
                if !codex.currentBuckets.isEmpty || !codex.accounts.isEmpty {
                    self.codexBuckets = codex.currentBuckets
                    self.codexResets = codex.resetCredits
                    self.codexResetExpiries = codex.resetExpiries
                    if codex.accounts.isEmpty {
                        observations += UsageLog.percentages(codex.currentBuckets, source: "Codex")
                    } else {
                        for account in codex.accounts {
                            observations += UsageLog.percentages(account.buckets, source: "Codex · \(account.displayPlan)")
                        }
                    }
                    codexOK = true
                    gotOther = true
                    self.reconcilePendingKey()
                }
                // 成功或失敗都結束「重置後等新次數」的等待（失敗時顯示讀不到、按鈕維持停用，下一次成功的讀取才解鎖）
                self.codexReadFinished(startedAt: startedAt, success: codexOK)
                if let copilotOut, let c = Self.parseCopilot(copilotOut) {
                    self.copilotBuckets = c.buckets
                    self.copilotNote = c.note
                    self.copilotFootnote = c.footnote
                    self.copilotRemaining = c.remaining
                    self.copilotTotal = c.total
                    if let remaining = c.remaining, let total = c.total {
                        observations.append(UsageLog.Observation(pool: "Copilot · Chat / 每月", kind: "count", remaining: remaining, total: total, resetAt: c.buckets.first?.resetAt))
                    }
                    gotOther = true
                }
                let parsed = out.map(Self.parse) ?? []
                if !parsed.isEmpty {
                    self.buckets = parsed
                    observations += UsageLog.percentages(parsed, source: "Claude Code")
                }
                self.completeMainCycleOnMain(cycle: cycle, gotClaude: !parsed.isEmpty, gotOther: gotOther)
                UsageLog.record(observations, at: recordedAt)
                self.writeUsageCardDumpIfNeeded()
            }
        }
    }

    private static func fakeAgy2StatusFromEnv(
        h: (Int, Int) -> String,
        r: (Int, Int) -> Date
    ) -> Agy2QuotaStatus? {
        switch ProcessInfo.processInfo.environment["CODENV_USAGE_FAKE_AGY2"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ok":
            return .available([
                UsageBucket(label: "Gemini \(L("5 小時"))", used: 10, resets: h(3, 15), resetAt: r(3, 15)),
                UsageBucket(label: "Gemini \(L("每週"))", used: 4, resets: h(6*24+12, 0), resetAt: r(6*24+12, 0)),
                UsageBucket(label: "Claude \(L("5 小時"))", used: 0, resets: h(3, 15), resetAt: r(3, 15)),
                UsageBucket(label: "Claude \(L("每週"))", used: 25, resets: h(5*24+8, 0), resetAt: r(5*24+8, 0)),
                UsageBucket(label: "Argon \(L("每週"))", used: 0, resets: h(6*24+18, 0), resetAt: r(6*24+18, 0)),
            ])
        case "down":
            return .down
        case "unreadable":
            return .unreadable
        default:
            return nil
        }
    }

    /// 開始新一輪主刷新（主執行緒呼叫）；重置本輪 main／agy 完成旗標，回傳本輪序號。
    @discardableResult
    func beginRefreshCycleOnMain(markAgyLoadingIfIdle: Bool = false) -> UInt64 {
        refreshCycleID &+= 1
        mainCycleDone = false
        mainCycleGotClaude = false
        mainCycleGotOther = false
        agyCycleGotData = false
        if markAgyLoadingIfIdle && !agyLoading {
            agyLoading = true
        }
        return refreshCycleID
    }

    /// 主流程（Claude／Codex／Copilot）結束時於主執行緒回報結果並調和狀態。
    func completeMainCycleOnMain(cycle: UInt64, gotClaude: Bool, gotOther: Bool) {
        if cycle == self.refreshCycleID {
            self.mainCycleDone = true
            self.mainCycleGotClaude = gotClaude
            self.mainCycleGotOther = gotOther
            self.reconcileRefreshStatus()
        } else if gotClaude {
            self.error = nil
            self.updated = Date()
        }
    }

    /// 獨立 agy 分支結束（含上一輪延續到本輪的舊分支）時於主執行緒套用結果並調和狀態（修正單第 5、6 項）。
    func finishAgyRefreshBranchOnMain(gotData: Bool) {
        self.agyLoading = false
        self.agyCycleGotData = gotData
        if self.mainCycleDone {
            self.reconcileRefreshStatus()
        } else if gotData {
            self.updated = Date()
        }
    }

    /// 調和主流程（Claude／Codex／Copilot）與獨立 agy 分支的 error／updated 狀態，
    /// 避免 agy 拆出後在「只有 agy 有資料」或 agy 還在跑時誤報「查不到用量」。
    private func reconcileRefreshStatus() {
        if mainCycleGotClaude {
            self.error = nil
            self.updated = Date()
            return
        }
        if mainCycleGotOther || agyCycleGotData {
            self.error = L("Claude 用量這次查不到")
            self.updated = Date()
            return
        }
        if mainCycleDone && !agyLoading {
            self.error = L("查不到用量")
        }
    }

    /// 修正單第 9 項：非換帳號路徑的 agy2（docker）與 agy `/usage` 並行執行，
    /// agy 一完成立刻觸發 `onAgyReady`（不等 docker 完成），兩邊皆完成後再觸發 `onBothDone`。
    static func runLegacyAgyAndAgy2InParallel(
        fetchAgy2: @escaping () -> Agy2QuotaStatus?,
        fetchAgy: @escaping () -> (ran: Bool, parsed: [UsageBucket]),
        onAgyReady: @escaping ((ran: Bool, parsed: [UsageBucket])) -> Void = { _ in },
        onBothDone: @escaping ((agy2: Agy2QuotaStatus?, ran: Bool, parsed: [UsageBucket])) -> Void
    ) {
        let group = DispatchGroup()
        let resultLock = NSLock()
        var agy2Result: Agy2QuotaStatus? = nil
        var agyResult: (ran: Bool, parsed: [UsageBucket]) = (false, [])

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let res = fetchAgy2()
            resultLock.lock()
            agy2Result = res
            resultLock.unlock()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let res = fetchAgy()
            resultLock.lock()
            agyResult = res
            resultLock.unlock()
            onAgyReady(res)
            group.leave()
        }

        group.notify(queue: DispatchQueue.global(qos: .utility)) {
            resultLock.lock()
            let finalAgy2 = agy2Result
            let finalAgy = agyResult
            resultLock.unlock()
            onBothDone((finalAgy2, finalAgy.ran, finalAgy.parsed))
        }
    }

    /// 修正單第 11 項＋fix2 第 3 項：`.skipRound`（status 失敗／逾時／accounts_error）時組出磁碟舊快取顯示清單。
    /// 順序：上一輪成功的換帳號清單 → `accounts_error` 仍帶的 `accounts` → 掃快取目錄 `usage-*.json`。
    /// `swapMode` 僅在「曾確認過換帳號模式」、「`accounts_error` 帶 ≥2 個帳號」或「掃到 ≥2 份有效磁碟快取」時為 true，否則維持 legacy（false）。
    static func resolveSkipRoundDisplay(
        prevSwapMode: Bool,
        prevSwapStatus: AgySwapStatus?,
        statusResult: AgySwapStatusFetchResult,
        cacheStateDir: URL,
        containerMapEnabled: Bool = false,
        now: Date = Date()
    ) -> (displays: [AgySwapAccountDisplay], swapMode: Bool) {
        if let prevSwapStatus, !prevSwapStatus.accounts.isEmpty {
            let skippedStatuses: [String: AgyContainerAccountStatus] = containerMapEnabled
                ? Dictionary(prevSwapStatus.accounts.map { ($0.name, .skipped) }, uniquingKeysWith: { first, _ in first })
                : [:]
            let displays = AgySwapUsageCache.buildDisplayAccounts(
                status: prevSwapStatus,
                liveAccount: nil,
                liveBuckets: nil,
                liveReadAt: nil,
                containerStatuses: skippedStatuses,
                cacheLoader: { AgySwapUsageCache.read(account: $0, stateDir: cacheStateDir) },
                now: now
            )
            return (displays, true)
        }
        if case .success(let errStatus) = statusResult, !errStatus.accounts.isEmpty {
            let swapMode = prevSwapMode || errStatus.accounts.count >= 2
            let skippedStatuses: [String: AgyContainerAccountStatus] = (swapMode && containerMapEnabled)
                ? Dictionary(errStatus.accounts.map { ($0.name, .skipped) }, uniquingKeysWith: { first, _ in first })
                : [:]
            let displays = AgySwapUsageCache.buildDisplayAccounts(
                status: errStatus,
                liveAccount: nil,
                liveBuckets: nil,
                liveReadAt: nil,
                containerStatuses: skippedStatuses,
                cacheLoader: { AgySwapUsageCache.read(account: $0, stateDir: cacheStateDir) },
                now: now
            )
            return (displays, prevSwapMode || displays.count >= 2)
        }
        let scanned = AgySwapUsageCache.scanDiskCache(stateDir: cacheStateDir)
        let swapMode = prevSwapMode || scanned.count >= 2
        let skippedStatuses: [String: AgyContainerAccountStatus] = (swapMode && containerMapEnabled)
            ? Dictionary(scanned.map { ($0.account, .skipped) }, uniquingKeysWith: { first, _ in first })
            : [:]
        let displays = AgySwapUsageCache.buildDisplayAccountsFromCacheScan(
            entries: scanned,
            containerStatuses: skippedStatuses,
            now: now
        )
        return (displays, prevSwapMode || displays.count >= 2)
    }

    /// 供單元測試直接驅動真實 `startAgyRefreshBranch`（不需啟動 App 或讀取全域 `CommandLine.arguments`）。
    func runAgyRefreshBranchForTest(
        config: AgySwapConfig,
        fakeMainMode: Bool = false,
        ignoreAgyEnabledPref: Bool = true,
        recordUsageLog: Bool = false,
        nowProvider: @escaping () -> Date = Date.init,
        containerFileExists: ((String) -> Bool)? = nil,
        containerRunner: ((String, [String], TimeInterval) -> ExternalCommand.Result?)? = nil,
        onPartialUpdate: (() -> Void)? = nil,
        onComplete: @escaping () -> Void
    ) {
        startAgyRefreshBranch(
            cycle: refreshCycleID,
            config: config,
            fakeMainMode: fakeMainMode,
            ignoreAgyEnabledPref: ignoreAgyEnabledPref,
            recordUsageLog: recordUsageLog,
            nowProvider: nowProvider,
            containerFileExists: containerFileExists,
            containerRunner: containerRunner,
            onPartialUpdate: onPartialUpdate,
            onComplete: onComplete
        )
    }

    /// 獨立於 DispatchGroup g 執行的 agy 額度分支（含換帳號模式、容器並行讀取與 agy2 條件式查詢）。
    private func startAgyRefreshBranch(
        cycle: UInt64,
        config: AgySwapConfig,
        fakeMainMode: Bool,
        ignoreAgyEnabledPref: Bool = false,
        recordUsageLog: Bool = true,
        nowProvider: @escaping () -> Date = Date.init,
        containerFileExists: ((String) -> Bool)? = nil,
        containerRunner: ((String, [String], TimeInterval) -> ExternalCommand.Result?)? = nil,
        onPartialUpdate: (() -> Void)? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        _ = cycle
        agyLoading = true
        lastRoundContainerCalls = 0
        let prevSwapMode = self.agySwapMode
        let prevSwapStatus = self.lastSuccessfulSwapStatus
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            func fetchAgy2IfAllowed() -> Agy2QuotaStatus? {
                if fakeMainMode {
                    if UsageMonitor.dockerPath != nil {
                        return self.fetchAgy2StatusCached()
                    }
                    func r(_ hours: Int, _ minutes: Int) -> Date { Self.fakeUsageStartedAt.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60)) }
                    func h(_ hours: Int, _ minutes: Int) -> String { Self.when(r(hours, minutes)) }
                    return Self.fakeAgy2StatusFromEnv(h: h, r: r)
                }
                return self.fetchAgy2StatusCached()
            }

            func runLegacyPath(legacyAccountName: String?) {
                Self.runLegacyAgyAndAgy2InParallel(
                    fetchAgy2: { fetchAgy2IfAllowed() },
                    fetchAgy: {
                        var parsed: [UsageBucket] = []
                        var ran = false
                        // 連不上 Google 就不查 agy：斷網時 agy 會一直開瀏覽器登入頁（AgyNet.canCall）
                        if (ignoreAgyEnabledPref || AgyBridge.enabled), AgyBridge.canLaunchInCurrentInstance,
                           AgyBridge.executable != "agy", AgyNet.canCall() {
                            ran = true
                            let log = AgyNet.newLogFile()
                            let agyOut = Self.run(AgyBridge.executable, ["-p=/usage", "--print-timeout", "60s", "--log-file", log.path])
                            AgyNet.check(log: log)
                            if let agyOut { parsed = Self.parseAgy(agyOut) }
                        }
                        return (ran, parsed)
                    },
                    onAgyReady: { agyRes in
                        guard !agyRes.parsed.isEmpty else { return }
                        DispatchQueue.main.async {
                            self.agySwapMode = false
                            self.agySwapAccounts = []
                            self.agyActiveAccount = nil
                            self.lastSuccessfulSwapStatus = nil
                            self.agyLegacyAccountName = legacyAccountName
                            self.agyLegacyCachedReadAt = nil
                            self.agyLegacyCachedSource = nil
                            self.lastRoundContainerCalls = 0
                            self.agyBuckets = agyRes.parsed
                            self.magpieQuotaTips = [:]
                            self.magpieAccounts = []
                            self.agyLiveBucketsByAccount = [:]
                            if recordUsageLog {
                                UsageLog.record(UsageLog.percentages(agyRes.parsed, source: "agy"), at: Date())
                            }
                            self.agyCycleGotData = true
                            if self.mainCycleDone {
                                self.reconcileRefreshStatus()
                            } else {
                                self.updated = Date()
                            }
                        }
                    },
                    onBothDone: { combined in
                        let outcome: AgyLastOutcome = combined.ran ? (combined.parsed.isEmpty ? .failed : .ok) : .skipped
                        DispatchQueue.main.async {
                            self.agySwapMode = false
                            self.agySwapAccounts = []
                            self.agyActiveAccount = nil
                            self.lastSuccessfulSwapStatus = nil
                            self.agyLegacyAccountName = legacyAccountName
                            self.lastRoundContainerCalls = 0
                            if !combined.parsed.isEmpty {
                                self.agyLegacyCachedReadAt = nil
                                self.agyLegacyCachedSource = nil
                            }
                            self.agy2Status = combined.agy2
                            self.lastAgyOutcome = outcome
                            var gotData = !combined.parsed.isEmpty
                            if case .available(let agy2Buckets) = combined.agy2, !agy2Buckets.isEmpty { gotData = true }
                            self.finishAgyRefreshBranchOnMain(gotData: gotData)
                            self.writeUsageCardDumpIfNeeded(config: config)
                            onComplete?()
                        }
                    }
                )
            }

            // 未啟用 agy-swap 路徑（正式沒裝 agy-swap，或測試沒同時給 --agy-swap-bin 與 --agy-usage-test）
            guard config.usageSwapEnabled else {
                runLegacyPath(legacyAccountName: nil)
                return
            }

            // 設定頁關掉 agy 時不呼叫 agy-swap
            guard ignoreAgyEnabledPref || AgyBridge.enabled else {
                let agy2 = fetchAgy2IfAllowed()
                DispatchQueue.main.async {
                    self.agySwapMode = false
                    self.agySwapAccounts = []
                    self.agyActiveAccount = nil
                    self.lastSuccessfulSwapStatus = nil
                    self.lastRoundContainerCalls = 0
                    if self.agyBuckets.isEmpty {
                        self.agyLegacyCachedReadAt = nil
                        self.agyLegacyCachedSource = nil
                    }
                    self.agy2Status = agy2
                    self.lastAgyOutcome = .skipped
                    var gotData = false
                    if case .available(let agy2Buckets) = agy2, !agy2Buckets.isEmpty { gotData = true }
                    self.finishAgyRefreshBranchOnMain(gotData: gotData)
                    self.writeUsageCardDumpIfNeeded(config: config)
                    onComplete?()
                }
                return
            }

            let statusResult = AgySwapClient.fetchStatus(config: config)
            let decision = self.agySwapModeTracker.evaluate(hasBinary: true, statusResult: statusResult)

            switch decision {
            case .skipRound(let reason, let failures):
                NSLog("codenv usage：agy-swap status 失敗（第 %d 輪：%@），略過本輪並顯示舊快取", failures, reason)
                // .skipRound 不讀容器、不記錄節流嘗試，只用磁碟快取組顯示與合計。
                let containerMapEnabled = AgyContainerMap.load(from: config.containerMapURL).isEnabled
                let resolved = Self.resolveSkipRoundDisplay(
                    prevSwapMode: prevSwapMode,
                    prevSwapStatus: prevSwapStatus,
                    statusResult: statusResult,
                    cacheStateDir: config.cacheStateDir,
                    containerMapEnabled: containerMapEnabled,
                    now: nowProvider()
                )
                DispatchQueue.main.async {
                    self.lastAgyOutcome = .skipped
                    self.lastRoundContainerCalls = 0
                    if resolved.swapMode {
                        self.agySwapMode = true
                        self.agyLegacyCachedReadAt = nil
                        self.agyLegacyCachedSource = nil
                        if !resolved.displays.isEmpty {
                            self.agySwapAccounts = resolved.displays
                            let activeDisplay = resolved.displays.first(where: \.isActive)
                            self.agyActiveAccount = activeDisplay?.name
                            // 修正單 fix2 第 4 項：比照 .swap 分支，swapMode == true 時有 active 用其 buckets，否則清為 []，
                            // 避免右欄在「還沒讀過」下面殘留上一輪舊百分比。
                            self.agyBuckets = activeDisplay?.buckets ?? []
                        }
                    } else {
                        // 修正單 fix2 第 3 項：swapMode == false（只掃到 1 份快取或 accounts_error 只帶 1 個帳號）時
                        // 維持 legacy 顯示，不把 displays 寫進 agySwapAccounts、agySwapMode 維持 false。
                        self.agySwapMode = false
                        if resolved.displays.count == 1, let single = resolved.displays.first {
                            if single.state == .cached, !single.buckets.isEmpty,
                               (self.agyBuckets.isEmpty || self.agyLegacyCachedReadAt != nil) {
                                self.agyLegacyAccountName = single.name
                                self.agyBuckets = single.buckets
                                self.agyLegacyCachedReadAt = single.readAt
                                self.agyLegacyCachedSource = single.source
                            } else if self.agyBuckets.isEmpty {
                                self.agyLegacyAccountName = single.name
                            }
                        }
                    }
                    // 修正單第 6、11 項：舊快取只用於顯示，不算本輪讀到資料（agyCycleGotData = false，不刷新 updated）。
                    self.finishAgyRefreshBranchOnMain(gotData: false)
                    self.writeUsageCardDumpIfNeeded(config: config)
                    onComplete?()
                }
                return

            case .degradedLegacy(let reason, let failures):
                NSLog("codenv usage：agy-swap status 連續 %d 輪失敗（%@），降級為非換帳號模式", failures, reason)
                EventLog.log("agy-swap", "額度查詢連續 \(failures) 輪 status 失敗（\(reason)），降級為非換帳號模式")
                runLegacyPath(legacyAccountName: nil)
                return

            case .legacy(let legacyStatus):
                let name = legacyStatus?.liveMatches ?? legacyStatus?.active ?? legacyStatus?.accounts.first?.name
                runLegacyPath(legacyAccountName: name)
                return

            case .swap(let preStatus):
                // ≥2 帳號：隱藏舊 agy2 區塊；非現用帳號若在 agy-container-map.json 內且符合條件，經 config.dockerPath 並行讀取。
                let nowStart = nowProvider()
                let containerMap = AgyContainerMap.load(from: config.containerMapURL)
                let canCallAgy = AgySwapClient.canCallAgy(config: config)
                // 嚴格只吃 config.dockerPath，絕不呼叫 UsageMonitor.dockerPath。
                let eligibleTargets = AgyContainerUsage.eligibleTargets(
                    status: preStatus,
                    containerMap: containerMap,
                    dockerPath: config.dockerPath,
                    canCallAgy: canCallAgy
                )
                let containerModeEnabled = containerMap.isEnabled

                let stateLock = NSLock()
                var macDisplayStatus: AgySwapStatus? = nil
                var macLiveAccount: String? = nil
                var macLiveBuckets: [UsageBucket]? = nil
                var macLiveReadAt: Date? = nil
                var macOutcome: AgyLastOutcome = .skipped
                var latestContainerPostStatus: AgySwapStatus? = nil
                var containerStatuses: [String: AgyContainerAccountStatus] = containerModeEnabled
                    ? Dictionary(preStatus.accounts.map { ($0.name, .skipped) }, uniquingKeysWith: { first, _ in first })
                    : [:]
                var containerLive: [String: (readAt: Date, container: String)] = [:]
                var containerCallsCount = 0
                var remainingContainers = eligibleTargets.count
                var branchFinalized = false

                let group = DispatchGroup()

                // 1) Mac 現用帳號分支（沿用方案 A 路徑，與容器讀取並行）
                group.enter()
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else {
                        group.leave()
                        return
                    }
                    var localDisplayStatus: AgySwapStatus? = nil
                    var localLiveAccount: String? = nil
                    var localLiveBuckets: [UsageBucket]? = nil
                    var localLiveReadAt: Date? = nil
                    let localOutcome: AgyLastOutcome

                    if preStatus.switching || preStatus.recoveryPending || !canCallAgy {
                        // switching／recovery_pending／斷網：略過 run，但照樣讀磁碟快取顯示。
                        localOutcome = .skipped
                    } else {
                        let logURL = AgyNet.newLogFile()
                        let call = AgySwapClient.run(
                            config: config,
                            agyArguments: ["-p=/usage", "--print-timeout", "60s", "--log-file", logURL.path],
                            workingDirectory: FileManager.default.temporaryDirectory,
                            timeout: config.usageRunTimeout
                        )
                        AgyNet.check(log: logURL)
                        let exitKind = AgySwapClient.classifyExit(call.exec)
                        switch exitKind {
                        case .stoppedByUs:
                            localOutcome = .stopped
                        case .failed(let code):
                            if !call.exec.weTerminated && (code == 143 || code == 137) {
                                NSLog("codenv usage：agy-swap run 遭外部終止（結束碼 %d）", code)
                            } else {
                                NSLog("codenv usage：agy-swap run 失敗（結束碼 %d）", code)
                            }
                            localOutcome = .failed
                        case .ok:
                            if call.exec.outputTruncated {
                                // 修正單 fix2 第 1 項：run 輸出超過上限遭截斷，視為失敗且不得寫入快取。
                                NSLog("codenv usage：agy-swap run 輸出超過上限已截斷，視為失敗且不覆蓋舊快取")
                                localOutcome = .failed
                            } else {
                                let parsed = Self.parseAgy(call.exec.stdout)
                                let postResult = AgySwapClient.fetchStatus(config: config)
                                let postStatus: AgySwapStatus?
                                if case .success(let ps) = postResult {
                                    postStatus = ps
                                } else {
                                    postStatus = nil
                                }
                                if let validAccount = AgySwapUsageCache.shouldWriteCache(
                                    execResult: call.exec,
                                    parsedBuckets: parsed,
                                    anInfo: call.anInfo,
                                    postStatus: postStatus
                                ), let postStatus {
                                    let readAt = nowProvider()
                                    let wroteCache = AgySwapUsageCache.write(
                                        account: validAccount,
                                        readAt: readAt,
                                        buckets: parsed,
                                        stateDir: config.cacheStateDir,
                                        source: "mac"
                                    )
                                    localDisplayStatus = postStatus
                                    if wroteCache {
                                        localLiveAccount = validAccount
                                        localLiveBuckets = parsed
                                        localLiveReadAt = readAt
                                        localOutcome = .ok
                                    } else {
                                        // 修正單第 7 項：快取寫入失敗不標 ok、不設 live（顯示改用磁碟舊快取）。
                                        NSLog("codenv usage：寫入帳號 %@ 的額度快取檔失敗，不標為 ok、顯示改用磁碟舊快取", validAccount)
                                        localOutcome = .failed
                                    }
                                } else {
                                    NSLog("codenv usage：寫快取條件未成立，不覆蓋舊快取（an=%@ parsed=%d）",
                                          call.anInfo?.account ?? "nil", parsed.count)
                                    if let postStatus, !postStatus.accountsError, postStatus.accounts.count >= 2 {
                                        localDisplayStatus = postStatus
                                    }
                                    localOutcome = .failed
                                }
                            }
                        }
                    }

                    stateLock.lock()
                    macDisplayStatus = localDisplayStatus
                    macLiveAccount = localLiveAccount
                    macLiveBuckets = localLiveBuckets
                    macLiveReadAt = localLiveReadAt
                    macOutcome = localOutcome
                    let containersStillRunning = remainingContainers > 0
                    let snapshotStatuses = containerStatuses
                    let snapshotContainerLive = containerLive
                    stateLock.unlock()

                    // Mac 先完成且仍有容器在跑：先更新一次畫面，但不結束 agyLoading、不寫 dump、不叫 onComplete。
                    if containersStillRunning {
                        let partialStatus = localDisplayStatus ?? preStatus
                        let partialNow = max(nowStart, localLiveReadAt ?? nowProvider())
                        let partialDisplays = AgySwapUsageCache.buildDisplayAccounts(
                            status: partialStatus,
                            liveAccount: localLiveAccount,
                            liveBuckets: localLiveBuckets,
                            liveReadAt: localLiveReadAt,
                            containerLive: snapshotContainerLive,
                            containerStatuses: snapshotStatuses,
                            cacheLoader: { AgySwapUsageCache.read(account: $0, stateDir: config.cacheStateDir) },
                            now: partialNow
                        )
                        DispatchQueue.main.async {
                            stateLock.lock()
                            let alreadyDone = branchFinalized
                            stateLock.unlock()
                            guard !alreadyDone else { return }
                            self.agySwapMode = true
                            self.lastSuccessfulSwapStatus = partialStatus
                            self.agy2Status = nil
                            self.agySwapAccounts = partialDisplays
                            self.agyLegacyAccountName = nil
                            self.agyLegacyCachedReadAt = nil
                            self.agyLegacyCachedSource = nil
                            self.magpieQuotaTips = [:]
                            self.magpieAccounts = []
                            self.lastAgyOutcome = localOutcome
                            let activeDisplay = partialDisplays.first(where: \.isActive)
                            self.agyActiveAccount = activeDisplay?.name
                            self.agyBuckets = activeDisplay?.buckets ?? []
                            onPartialUpdate?()
                        }
                    }

                    group.leave()
                }

                // 2) 非現用帳號容器讀取分支（各容器獨立並行；只准呼叫 docker 與 agy-swap status）
                if let dockerPath = config.dockerPath {
                    let fileExistsCheck = containerFileExists ?? { FileManager.default.fileExists(atPath: $0) }
                    let baseRunner = containerRunner ?? { ExternalCommand.run($0, arguments: $1, timeout: $2) }

                    for target in eligibleTargets {
                        group.enter()
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            defer {
                                stateLock.lock()
                                remainingContainers = max(0, remainingContainers - 1)
                                stateLock.unlock()
                                group.leave()
                            }
                            guard let self else { return }

                            let attemptNow = nowProvider()
                            guard self.agyContainerTracker.beginAttemptIfAllowed(
                                container: target.container,
                                now: attemptNow,
                                successTTL: config.containerSuccessTTL,
                                failureTTL: config.containerFailureTTL
                            ) else {
                                stateLock.lock()
                                containerStatuses[target.account] = .throttled
                                stateLock.unlock()
                                return
                            }

                            let fetchResult = Self.fetchContainerQuota(
                                container: target.container,
                                dockerPath: dockerPath,
                                fileExists: fileExistsCheck,
                                runner: { executable, arguments, timeout in
                                    stateLock.lock()
                                    containerCallsCount += 1
                                    stateLock.unlock()
                                    return baseRunner(executable, arguments, timeout)
                                }
                            )

                            switch fetchResult {
                            case .down:
                                self.agyContainerTracker.recordAttempt(container: target.container, succeeded: false, at: nowProvider())
                                stateLock.lock()
                                containerStatuses[target.account] = .down
                                stateLock.unlock()

                            case .unreadable:
                                self.agyContainerTracker.recordAttempt(container: target.container, succeeded: false, at: nowProvider())
                                stateLock.lock()
                                containerStatuses[target.account] = .unreadable
                                stateLock.unlock()

                            case .available(let buckets):
                                let readAt = nowProvider()
                                // 寫入前重新呼叫 agy-swap status 驗證（規格 8.2，絕不呼叫 run／switch）。
                                let postResult = AgySwapClient.fetchStatus(config: config)
                                let postStatus: AgySwapStatus?
                                if case .success(let ps) = postResult {
                                    postStatus = ps
                                } else {
                                    postStatus = nil
                                }
                                let existingCache = AgySwapUsageCache.read(account: target.account, stateDir: config.cacheStateDir)
                                if AgyContainerUsage.shouldWriteContainerCache(
                                    account: target.account,
                                    container: target.container,
                                    fetchResult: .available(buckets),
                                    preGen: preStatus.gen,
                                    postStatus: postStatus,
                                    readAt: readAt,
                                    existingCache: existingCache
                                ) {
                                    let wrote = AgySwapUsageCache.write(
                                        account: target.account,
                                        readAt: readAt,
                                        buckets: buckets,
                                        stateDir: config.cacheStateDir,
                                        source: "container:\(target.container)"
                                    )
                                    self.agyContainerTracker.recordAttempt(container: target.container, succeeded: wrote, at: readAt)
                                    stateLock.lock()
                                    if wrote {
                                        containerStatuses[target.account] = .fresh
                                        containerLive[target.account] = (readAt: readAt, container: target.container)
                                    } else {
                                        containerStatuses[target.account] = .unreadable
                                    }
                                    if let postStatus, !postStatus.accountsError, postStatus.accounts.count >= 2 {
                                        latestContainerPostStatus = postStatus
                                    }
                                    stateLock.unlock()
                                } else {
                                    self.agyContainerTracker.recordAttempt(container: target.container, succeeded: false, at: readAt)
                                    stateLock.lock()
                                    containerStatuses[target.account] = .skipped
                                    if let postStatus, !postStatus.accountsError, postStatus.accounts.count >= 2 {
                                        latestContainerPostStatus = postStatus
                                    }
                                    stateLock.unlock()
                                }
                            }
                        }
                    }
                }

                // 3) 全部（Mac＋所有容器）結束後做最終更新、設 agyLoading = false、寫 dump、觸發 onComplete。
                group.notify(queue: DispatchQueue.global(qos: .utility)) { [weak self] in
                    guard let self else { return }
                    stateLock.lock()
                    let finalDisplayStatus = macDisplayStatus ?? latestContainerPostStatus ?? preStatus
                    let finalLiveAccount = macLiveAccount
                    let finalLiveBuckets = macLiveBuckets
                    let finalLiveReadAt = macLiveReadAt
                    let finalOutcome = macOutcome
                    let finalContainerLive = containerLive
                    var finalContainerStatuses = containerStatuses
                    if containerModeEnabled {
                        for acc in finalDisplayStatus.accounts where finalContainerStatuses[acc.name] == nil {
                            finalContainerStatuses[acc.name] = .skipped
                        }
                    }
                    let finalContainerCalls = containerCallsCount
                    stateLock.unlock()

                    let latestContainerReadAt = finalContainerLive.values.map(\.readAt).max() ?? nowStart
                    let renderNow = max(nowStart, max(finalLiveReadAt ?? nowStart, max(latestContainerReadAt, nowProvider())))
                    let displays = AgySwapUsageCache.buildDisplayAccounts(
                        status: finalDisplayStatus,
                        liveAccount: finalLiveAccount,
                        liveBuckets: finalLiveBuckets,
                        liveReadAt: finalLiveReadAt,
                        containerLive: finalContainerLive,
                        containerStatuses: finalContainerStatuses,
                        cacheLoader: { AgySwapUsageCache.read(account: $0, stateDir: config.cacheStateDir) },
                        now: renderNow
                    )

                    DispatchQueue.main.async {
                        stateLock.lock()
                        branchFinalized = true
                        stateLock.unlock()

                        self.agySwapMode = true
                        self.lastSuccessfulSwapStatus = finalDisplayStatus
                        self.agy2Status = nil
                        self.agySwapAccounts = displays
                        self.agyLegacyAccountName = nil
                        self.agyLegacyCachedReadAt = nil
                        self.agyLegacyCachedSource = nil
                        self.magpieQuotaTips = [:]
                        self.magpieAccounts = []
                        self.lastAgyOutcome = finalOutcome
                        self.lastRoundContainerCalls = finalContainerCalls

                        let activeDisplay = displays.first(where: \.isActive)
                        self.agyActiveAccount = activeDisplay?.name

                        if let acc = finalLiveAccount, let buckets = finalLiveBuckets, !buckets.isEmpty {
                            self.agyLiveBucketsByAccount[acc] = buckets
                            // 換帳號模式下 UsageLog pool 名稱帶帳號，避免帳號切換那一輪算出跨帳號錯誤消耗。
                            // 容器讀取不寫 UsageLog（規格 8.2）。
                            if recordUsageLog {
                                UsageLog.record(UsageLog.percentages(buckets, source: "agy · \(acc)"), at: renderNow)
                            }
                        }
                        let validAccountNames = Set(displays.map(\.name))
                        for d in displays where d.state == .invalid {
                            self.agyLiveBucketsByAccount.removeValue(forKey: d.name)
                        }
                        self.agyLiveBucketsByAccount = self.agyLiveBucketsByAccount.filter { validAccountNames.contains($0.key) }

                        // 切換後新現用沒有即時資料時，只能用新現用自己的快取或空陣列，絕不殘留前一帳號數字。
                        self.agyBuckets = activeDisplay?.buckets ?? []

                        // Mac 即時成功或任一容器本輪成功寫入皆視為本輪有資料；容器全失敗不影響既有判定。
                        let gotAgyData = (finalLiveBuckets?.isEmpty == false) || !finalContainerLive.isEmpty
                        self.finishAgyRefreshBranchOnMain(gotData: gotAgyData)
                        self.writeUsageCardDumpIfNeeded(config: config)
                        onComplete?()
                    }
                }
                return
            }
        }
    }

    // MARK: - 額度卡多帳號摘要與測試 dump（規格 3 B / F；修正單第 8 項單一文字來源）

    /// `UsagePanel` 與 `--usage-card-dump` 的 `panelText` 共用此單一結構，避免兩套文案分歧。
    struct AgyPanelPresentation: Equatable {
        let showSwapHeader: Bool
        let accountName: String?
        let activeBadgeText: String?
        let ageText: String?
        let statusText: String?
        let isStatusError: Bool
        let othersText: String?
        let numbersText: String

        var summaryText: String {
            guard showSwapHeader else { return numbersText }
            let head: String
            if let accountName {
                let activeTag = activeBadgeText.map { "（\($0)）" } ?? ""
                if let statusText {
                    head = "\(accountName)\(activeTag)：\(statusText)"
                } else {
                    let ageSuffix = ageText.map { "（\($0)）" } ?? ""
                    head = "\(accountName)\(activeTag)：\(numbersText)\(ageSuffix)"
                }
            } else {
                head = statusText ?? numbersText
            }
            if let othersText {
                return "\(head)\n\(othersText)"
            }
            return head
        }
    }

    /// 右欄（`UsagePanel`）實際渲染用的 agy 多帳號狀態與文字；`agyPanelSummaryText()` 直接取同一份輸出。
    func agyPanelPresentation() -> AgyPanelPresentation {
        if usesSwapAccountDisplay {
            let active = agySwapAccounts.first(where: \.isActive)
            let primary = active ?? (agySwapAccounts.count == 1 ? agySwapAccounts.first : nil)
            let others = max(0, agySwapAccounts.count - 1)
            let othersText = others > 0 ? L("另有 \(others) 個帳號") : nil
            if let primary {
                let badge = primary.isActive ? L("使用中") : nil
                switch primary.state {
                case .invalid:
                    return AgyPanelPresentation(
                        showSwapHeader: true,
                        accountName: primary.name,
                        activeBadgeText: badge,
                        ageText: nil,
                        statusText: L("登入失效"),
                        isStatusError: true,
                        othersText: othersText,
                        numbersText: "—"
                    )
                case .never:
                    return AgyPanelPresentation(
                        showSwapHeader: true,
                        accountName: primary.name,
                        activeBadgeText: badge,
                        ageText: nil,
                        statusText: L("還沒讀過"),
                        isStatusError: false,
                        othersText: othersText,
                        numbersText: "—"
                    )
                case .live, .cached:
                    return AgyPanelPresentation(
                        showSwapHeader: true,
                        accountName: primary.name,
                        activeBadgeText: badge,
                        ageText: primary.state == .cached ? primary.ageText : nil,
                        statusText: nil,
                        isStatusError: false,
                        othersText: othersText,
                        numbersText: Self.agyThreeNumbersText(primary.buckets)
                    )
                }
            }
            return AgyPanelPresentation(
                showSwapHeader: true,
                accountName: nil,
                activeBadgeText: nil,
                ageText: nil,
                statusText: L("還沒讀過"),
                isStatusError: false,
                othersText: othersText,
                numbersText: "—"
            )
        }
        return AgyPanelPresentation(
            showSwapHeader: false,
            accountName: nil,
            activeBadgeText: nil,
            ageText: nil,
            statusText: nil,
            isStatusError: false,
            othersText: nil,
            numbersText: Self.agyThreeNumbersText(agyBuckets)
        )
    }

    /// 右欄（UsagePanel）agy 摘要文字：與 `UsagePanel` 畫面共用 `agyPanelPresentation()`。
    func agyPanelSummaryText() -> String {
        agyPanelPresentation().summaryText
    }

    /// 底列（`UsageGlanceStrip`／`SidebarFooter`）實際渲染用的 agy `UsageGlanceGroup`；
    /// `glance` 與 `agyGlanceText()`（dump 的 `glanceText`）共用此單一來源。
    func agyGlanceGroup() -> UsageGlanceGroup {
        let week = L("每週"), five = L("5 小時")
        if usesSwapAccountDisplay {
            let active = agySwapAccounts.first(where: \.isActive)
            let primary = active ?? (agySwapAccounts.count == 1 ? agySwapAccounts.first : nil)
            let others = max(0, agySwapAccounts.count - 1)
            let statusText: String?
            if let primary {
                switch primary.state {
                case .invalid: statusText = L("登入失效")
                case .never: statusText = L("還沒讀過")
                case .live, .cached: statusText = nil
                }
            } else {
                statusText = nil
            }
            let othersText = others > 0 ? L("另有 \(others) 個帳號") : nil
            let footerParts = [
                primary.map { $0.isActive ? L("使用中：\($0.name)") : "\($0.name)（\($0.ageText)）" },
                statusText,
                othersText,
            ].compactMap { $0 }
            return UsageGlanceGroup(
                key: "agy",
                name: primary.map { "agy (\($0.name))" } ?? "agy",
                symbol: "sparkle",
                items: Self.agyGlanceItems(primary?.buckets ?? [], tips: [:], week: week, five: five),
                footer: footerParts.isEmpty ? nil : footerParts.joined(separator: "｜"),
                accountLabel: primary?.name,
                statusText: statusText,
                othersText: othersText
            )
        }
        return UsageGlanceGroup(
            key: "agy",
            name: "agy",
            symbol: "sparkle",
            items: Self.agyGlanceItems(agyBuckets, tips: magpieQuotaTips, week: week, five: five)
        )
    }

    /// 底列（UsageGlanceGroup）agy 摘要文字：直接取 `agyGlanceGroup().summaryText`。
    func agyGlanceText() -> String {
        agyGlanceGroup().summaryText
    }

    private static func agyThreeNumbersText(_ buckets: [UsageBucket]) -> String {
        guard !buckets.isEmpty else { return "—" }
        let items = agyGlanceItems(buckets, tips: [:], week: L("每週"), five: L("5 小時"))
        return items.map { item in
            let label = item.short ?? item.what
            let val = item.bucket.map { "\($0.remaining)%" } ?? "—"
            return "\(label) \(val)"
        }.joined(separator: " · ")
    }

    /// 依規格 3 F 與 8.5 產生 `--usage-card-dump` JSON 物件（既有欄名一字不改，僅新增鍵）。
    func buildUsageCardDumpPayload() -> [String: Any] {
        var otherSources: [String] = []
        if !buckets.isEmpty || claudeLoginExpiry != nil { otherSources.append("claude") }
        if !codexBuckets.isEmpty || !codexAccounts.isEmpty { otherSources.append("codex") }
        if !copilotBuckets.isEmpty || !(copilotFootnote?.isEmpty ?? true) { otherSources.append("copilot") }

        let accountsArray: [[String: Any]]
        let totalPayload: Any
        if usesSwapAccountDisplay {
            accountsArray = agySwapAccounts.map { account in
                [
                    "name": account.name,
                    "state": account.state.rawValue,
                    "readAt": account.readAt.map(AgySwapUsageCache.formatISO8601UTC) ?? NSNull(),
                    "ageText": account.ageText,
                    "source": account.source ?? NSNull(),
                    "containerStatus": account.containerStatus?.rawValue ?? NSNull(),
                    "rows": account.buckets.map { [
                        "label": $0.label,
                        "remainingPercent": $0.remaining,
                    ] as [String: Any] },
                ]
            }
            totalPayload = AgyContainerUsage.computeTotalSummary(accounts: agySwapAccounts)?.dumpPayload() ?? NSNull()
        } else {
            let hasBuckets = !agyBuckets.isEmpty
            let name = agyLegacyAccountName ?? "default"
            let state: AgySwapAccountState
            let readAt: Any
            let ageText: String
            let source: Any
            if hasBuckets, let cachedReadAt = agyLegacyCachedReadAt {
                state = .cached
                readAt = AgySwapUsageCache.formatISO8601UTC(cachedReadAt)
                ageText = AgySwapUsageCache.formatAgeText(readAt: cachedReadAt)
                source = agyLegacyCachedSource ?? NSNull()
            } else if hasBuckets {
                state = .live
                readAt = updated.map(AgySwapUsageCache.formatISO8601UTC) ?? NSNull()
                ageText = L("剛剛")
                source = "mac"
            } else {
                state = .never
                readAt = NSNull()
                ageText = L("還沒讀過")
                source = NSNull()
            }
            accountsArray = [[
                "name": name,
                "state": state.rawValue,
                "readAt": readAt,
                "ageText": ageText,
                "source": source,
                "containerStatus": NSNull(),
                "rows": agyBuckets.map { [
                    "label": $0.label,
                    "remainingPercent": $0.remaining,
                ] as [String: Any] },
            ]]
            totalPayload = NSNull()
        }

        let agySectionsPayload: [[String: Any]] = usesSwapAccountDisplay
            ? AgyAccountSectionPresentation.dumpSections(accounts: agySwapAccounts)
            : []
        let agyTotalSummaryPayload: Any = usesSwapAccountDisplay
            ? (AgyContainerUsage.computeTotalSummary(accounts: agySwapAccounts).map { [
                "title": $0.title,
                "accountCount": $0.accountCount,
            ] as [String: Any] } ?? NSNull())
            : NSNull()

        return [
            "mode": agySwapMode ? "swap" : "legacy",
            "error": error ?? NSNull(),
            "updatedAt": updated.map(AgySwapUsageCache.formatISO8601UTC) ?? NSNull(),
            "mainLoading": loading,
            "agyLoading": agyLoading,
            "otherSourcesShown": otherSources,
            "agy2Visible": agySwapMode ? false : (agy2Status != nil),
            "lastAgyOutcome": lastAgyOutcome.rawValue,
            "containerCalls": lastRoundContainerCalls,
            "fullPage": [
                "accounts": accountsArray,
                "total": totalPayload,
            ],
            "agyAccountSections": agySectionsPayload,
            "agyTotalSummary": agyTotalSummaryPayload,
            "panelText": agyPanelSummaryText(),
            "glanceText": agyGlanceText(),
        ]
    }

    func writeUsageCardDumpIfNeeded(config: AgySwapConfig = AgySwapConfig.current()) {
        UsageSheet.schedulePanelDumpIfNeeded()
        guard config.isTestInstance, let dumpURL = config.usageCardDumpURL else { return }
        let payload = buildUsageCardDumpPayload()
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: dumpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dumpURL, options: .atomic)
    }

    private static func rowDisplayLines(_ row: UsageRow) -> [String] {
        var lines = ["\(row.label) \(row.bucket.remaining)%"]
        if !row.bucket.resets.isEmpty {
            if row.bucket.resets.hasSuffix("回補") {
                lines.append(row.bucket.resets)
            } else {
                lines.append(L("\(row.bucket.resets) 重置"))
            }
        }
        return lines
    }

    private static func agy2DisplayLines(_ status: Agy2QuotaStatus) -> [String] {
        var lines = [L("agy2（第二個帳號）")]
        switch status {
        case .down:
            lines.append(L("agy2 未啟動"))
        case .unreadable:
            lines.append(L("agy2 讀不到"))
        case .available(let buckets):
            for bucket in buckets {
                lines.append(contentsOf: rowDisplayLines(UsageRow(pool: .gemini, label: bucket.label, bucket: bucket)))
            }
        }
        return lines
    }

    private func poolNoteDisplayLines(_ pool: UsagePool, now: Date) -> [String] {
        var lines: [String] = []
        if let n = note(pool), !n.isEmpty {
            lines.append(contentsOf: n.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        if pool == .copilot, let footnote = copilotFootnote, !footnote.isEmpty {
            lines.append(footnote)
        }
        if pool == .copilot, let hint = copilotExpiringSoonHint(now: now) {
            lines.append(hint)
        }
        if pool == .codex, let st = codexResetStatus, !st.isEmpty {
            lines.append(st)
        }
        return lines
    }

    private func standardPoolDisplayLines(_ pool: UsagePool, now: Date, defaults: UserDefaults = appDefaults) -> [String] {
        if pool == .gemini, usesSwapAccountDisplay {
            var lines: [String] = []
            if let summary = AgyContainerUsage.computeTotalSummary(accounts: agySwapAccounts) {
                lines.append(summary.title)
                for row in summary.rows {
                    lines.append("\(row.displayLabel) \(row.percent)%")
                    if let footnote = row.footnoteText(now: now) {
                        lines.append(footnote)
                    }
                }
            }
            for account in AgyAccountSectionPresentation.displayedAccounts(agySwapAccounts) {
                let collapsed = AgyAccountSectionPresentation.isCollapsed(accountKey: account.name, defaults: defaults)
                if collapsed {
                    lines.append(AgyAccountSectionPresentation.collapsedHeaderLine(for: account))
                    continue
                }
                var head = [account.name]
                if account.isActive { head.append(L("使用中")) }
                if account.state == .cached { head.append(account.ageText) }
                lines.append(head.joined(separator: " "))
                if let sourceLabel = AgyContainerUsage.sourceDisplayLabel(account.source) {
                    lines.append(sourceLabel)
                }
                let geminiRows = account.buckets
                    .filter { !$0.label.hasPrefix("Claude") }
                    .map { UsageRow(pool: .gemini, label: $0.label.replacingOccurrences(of: "Gemini ", with: ""), bucket: $0) }
                let claudeAgyRows = account.buckets
                    .filter { $0.label.hasPrefix("Claude") }
                    .map { UsageRow(pool: .claudeAgy, label: $0.label.replacingOccurrences(of: "Claude ", with: "") + " (agy)", bucket: $0) }
                for row in geminiRows { lines.append(contentsOf: Self.rowDisplayLines(row)) }
                if !claudeAgyRows.isEmpty {
                    lines.append(L("Claude／GPT（agy）"))
                    for row in claudeAgyRows { lines.append(contentsOf: Self.rowDisplayLines(row)) }
                }
            }
            return lines
        }
        if pool == .gemini, !magpieAccounts.isEmpty {
            var lines: [String] = []
            let summaryRows = rows(.gemini)
            for row in summaryRows { lines.append(contentsOf: Self.rowDisplayLines(row)) }
            let accountCount = magpieAccounts.filter { account in
                summaryRows.contains { account.buckets[$0.bucket.label] != nil }
            }.count
            lines.append(L("帳號明細（\(accountCount) 個帳號）"))
            for account in magpieAccounts {
                let accountRows = summaryRows.compactMap { summary -> UsageRow? in
                    account.buckets[summary.bucket.label].map { UsageRow(pool: .gemini, label: summary.label, bucket: $0) }
                }
                if !accountRows.isEmpty {
                    let cells = ["Gemini 5 小時", "Gemini 每週", "Argon 每週", "agy Claude 每週"]
                    let values = cells.map { label in
                        accountRows.first { $0.bucket.label == label }.map { "\($0.bucket.remaining)%" } ?? "—"
                    }.joined(separator: " ")
                    lines.append("\(account.maskedName) \(values)")
                }
            }
            let claudeAgyRows = rows(.claudeAgy)
            if !claudeAgyRows.isEmpty {
                lines.append(L("Claude／GPT（agy）"))
                for row in claudeAgyRows { lines.append(contentsOf: Self.rowDisplayLines(row)) }
            }
            if let agy2Status {
                lines.append(contentsOf: Self.agy2DisplayLines(agy2Status))
            }
            return lines
        }
        if pool == .codex, !codexAccounts.isEmpty {
            var lines: [String] = []
            let paidAccounts = codexAccounts.filter { !$0.plan.lowercased().contains("free") }
            let freeAccounts = UsageMonitor.codexFreeAccounts(codexAccounts)
            for account in paidAccounts {
                var head = [account.displayPlan]
                if account.active { head.append(L("目前登入")) }
                head.append(account.maskedUser)
                lines.append(head.joined(separator: " "))
                for bucket in account.buckets {
                    lines.append(contentsOf: Self.rowDisplayLines(UsageRow(pool: .codex, label: bucket.label, bucket: bucket)))
                }
                if account.resetCredits > 0 {
                    lines.append(L("另有 \(account.resetCredits) 次免費全部重置"))
                    if !account.resetExpiries.isEmpty {
                        lines.append(L("過期：") + account.resetExpiries.map { UsageMonitor.when($0) }.joined(separator: L("、")))
                    }
                    if account.active, let status = codexResetStatus {
                        lines.append(status)
                    }
                }
            }
            if !freeAccounts.isEmpty {
                lines.append(L("免費額度池（\(freeAccounts.count) 個帳號）"))
                for account in freeAccounts {
                    let quota = UsageMonitor.codexFreeQuotaBucket(account)
                    var parts = [UsageMonitor.codexFreeAccountLabel(account)]
                    if account.alias != nil { parts.append(account.maskedUser) }
                    if account.active { parts.append(L("目前登入")) }
                    if let resetText = UsageMonitor.codexFreeResetText(account) { parts.append(resetText) }
                    parts.append(quota.map { "\($0.remaining)%" } ?? "—")
                    lines.append(parts.joined(separator: " "))
                    if let hint = UsageMonitor.codexFreeExpiringSoonHint(account) {
                        lines.append(hint)
                    }
                }
            }
            return lines
        }
        var lines: [String] = []
        if pool == .cc, let expiry = claudeLoginExpiry, let info = Self.loginExpiryText(expiresAt: expiry.expiresAt, now: now) {
            lines.append(info.text)
        }
        for row in rows(pool) {
            lines.append(contentsOf: Self.rowDisplayLines(row))
        }
        if pool == .gemini {
            let claudeAgyRows = rows(.claudeAgy)
            if !claudeAgyRows.isEmpty {
                lines.append(L("Claude／GPT（agy）"))
                for row in claudeAgyRows { lines.append(contentsOf: Self.rowDisplayLines(row)) }
            }
            if !agySwapMode, let agy2Status {
                lines.append(contentsOf: Self.agy2DisplayLines(agy2Status))
            }
        }
        lines.append(contentsOf: poolNoteDisplayLines(pool, now: now))
        return lines
    }

    /// 依 `UsageFullPage` 實際顯示順序與文字組出面板卡片快照（不含任何金鑰）。
    func buildUsagePanelCards(
        onlyPool: UsagePool? = nil,
        now: Date = Date(),
        savedOrder: [String] = UsageCardOrderStore.shared.savedOrder,
        defaults: UserDefaults = appDefaults
    ) -> [UsagePanelCardSnapshot] {
        let items = UsageFullPage.orderedItems(for: self, onlyPool: onlyPool, savedOrder: savedOrder)
        return items.map { item in
            switch item {
            case .pool(let pool):
                return UsagePanelCardSnapshot(
                    key: UsageCardOrder.poolKey(pool),
                    title: pool.title,
                    lines: standardPoolDisplayLines(pool, now: now, defaults: defaults)
                )
            case .extra(let extra):
                return UsagePanelCardSnapshot(
                    key: UsageCardOrder.extraKey(extra),
                    title: extra.name,
                    lines: ExtraKeyPoolCard.displayLines(for: extra, now: now)
                )
            }
        }
    }

    private static func rectPayload(_ rect: CGRect) -> [String: Double] {
        [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "w": Double(rect.size.width),
            "h": Double(rect.size.height),
        ]
    }

    /// 產生 `--usage-panel-dump` JSON 物件（不含任何金鑰）。
    func buildUsagePanelDumpPayload(
        panelFrame: CGRect?,
        screenVisibleFrame: CGRect?,
        columns: Int?,
        panelScale: CGFloat?,
        now: Date = Date(),
        savedOrder: [String] = UsageCardOrderStore.shared.savedOrder,
        defaults: UserDefaults = appDefaults
    ) -> [String: Any] {
        let items = UsageFullPage.orderedItems(for: self, onlyPool: nil, savedOrder: savedOrder)
        let cards = buildUsagePanelCards(now: now, savedOrder: savedOrder, defaults: defaults)
        let cardsPayload: [[String: Any]] = cards.map { card in
            [
                "key": card.key,
                "title": card.title,
                "lines": card.lines,
            ]
        }
        let lightHex = UsageHighlightColor.hexString(for: .aqua)
        let darkHex = UsageHighlightColor.hexString(for: .darkAqua)
        var purpleFieldsPayload: [[String: Any]] = []
        for item in items {
            let fields = purpleSemanticFields(for: item, defaults: defaults)
            for field in fields {
                purpleFieldsPayload.append([
                    "cardKey": item.key,
                    "field": field.rawValue,
                    "lightHex": lightHex,
                    "darkHex": darkHex,
                ])
            }
        }
        let agySectionsPayload: [[String: Any]] = usesSwapAccountDisplay
            ? AgyAccountSectionPresentation.dumpSections(accounts: agySwapAccounts, defaults: defaults)
            : []
        let agyTotalSummaryPayload: Any = usesSwapAccountDisplay
            ? (AgyContainerUsage.computeTotalSummary(accounts: agySwapAccounts).map { [
                "title": $0.title,
                "accountCount": $0.accountCount,
            ] as [String: Any] } ?? NSNull())
            : NSNull()
        return [
            "cards": cardsPayload,
            "extraLoaded": extraLoadedAt != nil,
            "extraLoadedAt": extraLoadedAt.map(AgySwapUsageCache.formatISO8601UTC) ?? NSNull(),
            "columns": columns ?? NSNull(),
            "panelScale": panelScale.map { Double($0) } ?? NSNull(),
            "panelFrame": panelFrame.map(Self.rectPayload) ?? NSNull(),
            "screenVisibleFrame": screenVisibleFrame.map(Self.rectPayload) ?? NSNull(),
            "order": cards.map(\.key),
            "agyAccountSections": agySectionsPayload,
            "agyTotalSummary": agyTotalSummaryPayload,
            "purpleFields": purpleFieldsPayload,
        ]
    }

    private func purpleSemanticFields(
        for item: UsageCardItem,
        defaults: UserDefaults = appDefaults
    ) -> [UsagePurpleSemanticField] {
        var seen = Set<UsagePurpleSemanticField>()
        var out: [UsagePurpleSemanticField] = []
        func add(_ field: UsagePurpleSemanticField) {
            if seen.insert(field).inserted { out.append(field) }
        }
        switch item {
        case .pool(let pool):
            if pool == .gemini, usesSwapAccountDisplay {
                for account in AgyAccountSectionPresentation.displayedAccounts(agySwapAccounts) {
                    guard !AgyAccountSectionPresentation.isCollapsed(accountKey: account.name, defaults: defaults) else {
                        continue
                    }
                    if account.buckets.contains(where: { !$0.resets.isEmpty }) {
                        add(.resetTime)
                    }
                }
            } else if pool == .codex, !codexAccounts.isEmpty {
                let paidAccounts = codexAccounts.filter { !$0.plan.lowercased().contains("free") }
                let freeAccounts = UsageMonitor.codexFreeAccounts(codexAccounts)
                if paidAccounts.contains(where: { $0.buckets.contains { !$0.resets.isEmpty } })
                    || freeAccounts.contains(where: { UsageMonitor.codexFreeResetText($0) != nil }) {
                    add(.resetTime)
                }
            } else {
                if rows(pool).contains(where: { !$0.bucket.resets.isEmpty }) {
                    add(.resetTime)
                }
                if pool == .gemini {
                    if rows(.claudeAgy).contains(where: { !$0.bucket.resets.isEmpty }) {
                        add(.resetTime)
                    }
                    if !agySwapMode, case .available(let agy2Buckets) = agy2Status,
                       agy2Buckets.contains(where: { !$0.resets.isEmpty }) {
                        add(.resetTime)
                    }
                }
                if pool == .copilot, let n = note(.copilot), !n.isEmpty {
                    for seg in UsageNoteStyling.segments(for: n) {
                        if let field = seg.purpleField { add(field) }
                    }
                }
            }
        case .extra(let extra):
            if extra.buckets.contains(where: { !$0.resets.isEmpty }) {
                add(.resetTime)
            }
            for note in extra.notes {
                for seg in UsageNoteStyling.segments(for: LV(note)) {
                    if let field = seg.purpleField { add(field) }
                }
            }
        }
        return out
    }

    private static func run(_ command: String, _ args: [String]) -> String? {
        // 用量查詢的測試實例只准跑明確指定的假 agy（agy-swap 路徑由 AgySwapClient 獨立放行 --agy-swap-bin）。
        // magpie、gh、Claude 等真實來源必須由假資料分支處理，不能因為測試機剛好裝了 CLI 就連外或開 OAuth。
        if CommandLine.arguments.contains("--state-dir"),
           !(AgyBridge.canLaunchInCurrentInstance && command == AgyBridge.executable) { return nil }
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
        let testInstance = CommandLine.arguments.contains("--state-dir")
        guard !testInstance || CodexBridge.testExecutable != nil else { return nil }
        let executable = testInstance ? CodexBridge.testExecutable! : CodexBridge.executable
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec \(q(executable)) app-server"]
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

    /// 解析 `magpie accounts codex --json`；不讀取或保存任何 Codex 權杖。
    static func parseMagpieCodexAccounts(_ data: Data) -> [CodexUsageAccountQuota]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let accounts = (root as? [[String: Any]]) ?? ((root as? [String: Any])?["accounts"] as? [[String: Any]])
        guard let accounts, !accounts.isEmpty, accounts.allSatisfy({ $0["windows"] is [[String: Any]] }) else { return nil }
        let iso = ISO8601DateFormatter()
        var parsed: [CodexUsageAccountQuota] = []
        for (index, account) in accounts.enumerated() {
            let userObject = account["user"]
            let user = (userObject as? String) ?? ((userObject as? [String: Any])?["email"] as? String)
                ?? (account["email"] as? String) ?? (account["id"] as? String) ?? L("帳號 \(index + 1)")
            let id = (account["id"] as? String) ?? user
            let alias = account["alias"] as? String
            let plan = (account["plan"] as? String) ?? ((account["plan"] as? [String: Any])?["name"] as? String) ?? ""
            let active = (account["active"] as? Bool) ?? false
            var buckets: [UsageBucket] = []
            for window in account["windows"] as? [[String: Any]] ?? [] {
                guard let name = window["name"] as? String, let raw = window["remaining"] else { continue }
                let remaining = (raw as? NSNumber)?.doubleValue ?? Double(String(describing: raw).replacingOccurrences(of: "%", with: ""))
                guard let remaining, remaining.isFinite else { continue }
                let clamped = min(100, max(0, remaining))
                let label = codexWindowLabel(name)
                let resetText = (window["resetsAt"] as? String) ?? (window["resetAt"] as? String)
                var reset = resetText.flatMap { iso.date(from: $0) }
                if reset == nil, let resetText {
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    reset = iso.date(from: resetText)
                    iso.formatOptions = [.withInternetDateTime]
                }
                let bucket = UsageBucket(label: label, used: 100 - Int(clamped.rounded()), resets: reset.map(when) ?? resetText ?? "", resetAt: reset)
                if let existing = buckets.firstIndex(where: { $0.label == label }) {
                    if buckets[existing].remaining < bucket.remaining { buckets[existing] = bucket }
                } else {
                    buckets.append(bucket)
                }
            }
            parsed.append(CodexUsageAccountQuota(id: id, user: user, plan: plan, active: active,
                                                 buckets: buckets, resetCredits: 0, resetExpiries: [], alias: alias))
        }
        return parsed.contains(where: { !$0.buckets.isEmpty }) ? parsed : nil
    }

    private static func codexWindowLabel(_ name: String) -> String {
        let value = name.lowercased()
        if value.contains("5 hour") || value.contains("five hour") || value.contains("5 小時") { return L("5 小時") }
        if value.contains("weekly") || value.contains("week") || value.contains("7 day") || value.contains("每週") { return L("每週") }
        if value.contains("30 day") || value.contains("30 天") { return L("30 天") }
        if let range = value.range(of: #"(\d+)\s*days?"#, options: .regularExpression),
           let days = Int(value[range].filter(\.isNumber)) { return L("\(days) 天") }
        return name
    }

    /// Magpie 提供各帳號額度；app-server 僅補目前登入帳號的免費重置券，並在 Magpie 失敗時完整退回舊資料。
    static func resolveCodexUsage(magpieData: Data?, appServerResult: [String: Any]?) -> CodexUsageSnapshot {
        let legacy = appServerResult.map(parseCodex) ?? (buckets: [], resets: 0, expiries: [])
        if let magpieData, let accounts = parseMagpieCodexAccounts(magpieData) {
            let enriched = accounts.map { account in
                CodexUsageAccountQuota(id: account.id, user: account.user, plan: account.plan, active: account.active,
                                       buckets: account.buckets,
                                       resetCredits: account.active ? legacy.resets : 0,
                                       resetExpiries: account.active ? legacy.expiries : [], alias: account.alias)
            }
            let active = enriched.first(where: \.active)
            let currentBuckets = active?.buckets.isEmpty == false ? active!.buckets : legacy.buckets
            return CodexUsageSnapshot(accounts: enriched, currentBuckets: currentBuckets,
                                      resetCredits: legacy.resets, resetExpiries: legacy.expiries, usedMagpie: true)
        }
        return CodexUsageSnapshot(accounts: [], currentBuckets: legacy.buckets, resetCredits: legacy.resets,
                                  resetExpiries: legacy.expiries, usedMagpie: false)
    }

    private static func glanceItem(_ bucket: UsageBucket, what: String, detail: String? = nil) -> UsageGlanceItem {
        UsageGlanceItem(tag: nil, what: what, bucket: bucket, detail: detail, short: compactGlanceLabel(bucket.label))
    }

    /// 底部列照使用者指定用短標籤；完整名稱仍放在 what／tooltip。
    private static func compactGlanceLabel(_ label: String) -> String {
        let folded = label.lowercased()
        if folded.contains("argon") && (label.contains("每週") || label.contains("每周") || folded.contains("week")) { return "argon" }
        if label.contains("每週") || label.contains("每周") || folded.contains("weekly") || folded.contains("week") { return "week" }
        if label.contains("5 小時") || label.contains("5小时") || folded.contains("5 hour") || folded.contains("5h") { return "5h" }
        if let range = label.range(of: #"\d+\s*(?:天|日)"#, options: .regularExpression) {
            return String(label[range].filter { $0.isNumber }) + "d"
        }
        if let range = label.range(of: #"(?i)\d+\s*(?:days?|d)\b"#, options: .regularExpression) {
            return String(label[range].filter { $0.isNumber }) + "d"
        }
        return label
    }

    /// 用付費帳號作底部 Codex 摘要；只有免費帳號時用 active 帳號實際提供的窗口。
    static func codexGlanceItems(accounts: [CodexUsageAccountQuota], fallback: [UsageBucket]) -> [UsageGlanceItem] {
        let paid = accounts.filter { $0.plan.lowercased().contains("plus") || $0.plan.lowercased().contains("pro") }
        let candidates = paid.isEmpty ? accounts.filter(\.active) : paid
        let selected = candidates.max { left, right in
            func score(_ account: CodexUsageAccountQuota) -> Double {
                let preferred = account.buckets.filter { $0.label == L("每週") || $0.label == L("5 小時") }
                let values = preferred.isEmpty ? account.buckets : preferred
                guard !values.isEmpty else { return -1 }
                return values.map { Double($0.remaining) }.reduce(0, +) / Double(values.count)
            }
            return score(left) < score(right)
        }
        let buckets = selected?.buckets ?? fallback
        let owner = selected.map { "Codex（\($0.displayPlan) · \($0.maskedUser)）" } ?? "Codex"
        let week = L("每週"), five = L("5 小時")
        let weekly = buckets.first { $0.label == week }
        let fiveHour = buckets.first { $0.label == five }
        if let weekly, let fiveHour {
            return [glanceItem(weekly, what: owner + " " + week), glanceItem(fiveHour, what: owner + " " + five)]
        }
        if !buckets.isEmpty { return buckets.map { glanceItem($0, what: owner + " " + $0.label) } }
        return [
            UsageGlanceItem(tag: nil, what: owner + " " + week, bucket: nil, short: "week"),
            UsageGlanceItem(tag: nil, what: owner + " " + five, bucket: nil, short: "5h"),
        ]
    }

    /// 免費池先依 Magpie alias 排序；缺 alias 的帳號排最後，並沿用遮罩信箱識別。
    static func codexFreeAccounts(_ accounts: [CodexUsageAccountQuota]) -> [CodexUsageAccountQuota] {
        accounts.filter { $0.plan.lowercased().contains("free") }.sorted { left, right in
            switch (left.alias, right.alias) {
            case let (a?, b?):
                let order = a.localizedStandardCompare(b)
                return order == .orderedSame ? left.id < right.id : order == .orderedAscending
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let order = left.maskedUser.localizedStandardCompare(right.maskedUser)
                return order == .orderedSame ? left.id < right.id : order == .orderedAscending
            }
        }
    }

    static func codexFreeAccountLabel(_ account: CodexUsageAccountQuota) -> String {
        account.alias ?? account.maskedUser
    }

    static func codexFreeQuotaBucket(_ account: CodexUsageAccountQuota) -> UsageBucket? {
        account.buckets.first { $0.label == L("30 天") || $0.label == L("30 days") }
            ?? (account.buckets.count == 1 ? account.buckets.first : nil)
    }

    /// 取得 Codex 免費帳號 30 天額度的重置日期顯示文字（使用獨立的 Asia/Taipei DateFormatter，不改動共用的 `when(_:)`）。
    /// - Parameter account: Codex 帳號額度資料（取自 `buckets` 中「30 天」／「30 days」桶的 `resetAt`；若僅有一個桶則退回該桶）。
    /// - Returns: 有 `resetAt` 時回傳 `"M/d 重置"`（台北時區），無日期則回傳 `nil`。
    static func codexFreeResetText(_ account: CodexUsageAccountQuota) -> String? {
        guard let resetAt = codexFreeQuotaBucket(account)?.resetAt else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "M/d"
        return L("\(formatter.string(from: resetAt)) 重置")
    }

    static func codexFreeExpiringSoonHint(_ account: CodexUsageAccountQuota, now: Date = Date()) -> String? {
        guard let quota = codexFreeQuotaBucket(account) else { return nil }
        return expiringSoonHint(
            poolName: "",
            remainingFraction: Double(quota.remaining) / 100.0,
            resetAt: quota.resetAt,
            cycleDays: poolCycleDays["Codex 免費帳號"],
            now: now,
            remainingText: "\(quota.remaining)%"
        )
    }

    /// 已知週期的額度池週期天數對照表；其餘週期未知的額度池不收錄（不顯示快過期提示）。
    static let poolCycleDays: [String: Double] = [
        "Kaggle": 7,
        "Copilot": 30,
        "Codex 免費帳號": 30,
    ]

    /// 計算額度池的「快過期提醒」文字（純函式，不依賴 UI）。
    ///
    /// - Parameters:
    ///   - poolName: 顯示於開頭的額度池名稱（例如 `"Kaggle"`、`"Copilot"`）；傳空字串 `""` 則省略前綴。
    ///   - remainingFraction: 未取整的原始剩餘比例（`0.0...1.0`）：
    ///     - count 類優先以原始計數計算 `Double(remaining) / Double(total)`；
    ///     - percent 類應以未四捨五入前的百分比計算 `(100.0 - rawUsed) / 100.0`；
    ///     - 若現有資料結構僅存已四捨五入的 `Int`（如 `UsageBucket.used` / `remaining`），呼叫處應優先改傳原始 `remaining / total` 或未取整前的 `used`。
    ///   - resetAt: 該額度池的重置時間。
    ///   - cycleDays: 週期總天數（可查 `poolCycleDays`）；為 `nil` 表示週期未知，一律回傳 `nil`。
    ///   - now: 計算基準時間。
    ///   - remainingText: 嵌在「剩 `<remainingText>`」的剩餘量文字（例如 `"$25.00"`、`"180 次"`、`"80%"`）。
    /// - Returns: 符合條件時回傳 `"<poolName> 剩 <remainingText>，<N> 天後重置"`（`poolName` 為空字串時省略 `"<poolName> "` 前綴；剩餘不到 1 天寫 `"1 天內重置"`），否則回傳 `nil`。
    ///
    /// 規則：
    /// 1. `cycleDays` 為 `nil` 或 `<= 0` → `nil`
    /// 2. `remainingFraction` 為 `nil` 或 `<= 0.5`（嚴格大於 0.5 才提示）→ `nil`
    /// 3. `resetAt` 為 `nil` 或 `resetAt <= now` → `nil`
    /// 4. 剩餘時間 `resetAt - now` 需嚴格小於 `min(7 天, cycleDays / 2)` 才提示
    ///
    /// 使用範例：
    /// ```swift
    /// let fraction = Double(remaining) / Double(total)
    /// let hint = UsageMonitor.expiringSoonHint(
    ///     poolName: "Copilot",
    ///     remainingFraction: fraction,
    ///     resetAt: bucket.resetAt,
    ///     cycleDays: UsageMonitor.poolCycleDays["Copilot"],
    ///     now: Date(),
    ///     remainingText: "\(remaining) 次"
    /// )
    /// ```
    static func expiringSoonHint(
        poolName: String,
        remainingFraction: Double?,
        resetAt: Date?,
        cycleDays: Double?,
        now: Date = Date(),
        remainingText: String
    ) -> String? {
        guard let cycleDays, cycleDays.isFinite, cycleDays > 0,
              let remainingFraction, remainingFraction.isFinite, remainingFraction > 0.5,
              let resetAt else { return nil }
        let remainingSeconds = resetAt.timeIntervalSince(now)
        guard remainingSeconds > 0 else { return nil }
        let secondsPerDay = 86_400.0
        let thresholdSeconds = min(7.0, cycleDays / 2.0) * secondsPerDay
        guard remainingSeconds < thresholdSeconds else { return nil }
        if remainingSeconds < secondsPerDay {
            return poolName.isEmpty
                ? L("剩 \(remainingText)，1 天內重置")
                : L("\(poolName) 剩 \(remainingText)，1 天內重置")
        }
        let days = max(1, Int(ceil(remainingSeconds / secondsPerDay)))
        return poolName.isEmpty
            ? L("剩 \(remainingText)，\(days) 天後重置")
            : L("\(poolName) 剩 \(remainingText)，\(days) 天後重置")
    }

    static func standardGlanceItems(_ name: String, buckets: [UsageBucket], week: String, five: String) -> [UsageGlanceItem] {
        let weekly = buckets.first { $0.label == week }, fiveHour = buckets.first { $0.label == five }
        if let weekly, let fiveHour {
            return [glanceItem(weekly, what: name + " " + week), glanceItem(fiveHour, what: name + " " + five)]
        }
        if !buckets.isEmpty { return buckets.map { glanceItem($0, what: name + " " + $0.label) } }
        return [
            UsageGlanceItem(tag: nil, what: name + " " + week, bucket: nil, short: "week"),
            UsageGlanceItem(tag: nil, what: name + " " + five, bucket: nil, short: "5h"),
        ]
    }

    static func agyGlanceItems(_ buckets: [UsageBucket], tips: [String: String], week: String, five: String) -> [UsageGlanceItem] {
        let available = buckets.filter { !$0.label.hasPrefix("Claude") }
        let weekly = available.first { $0.label.hasPrefix("Gemini") && $0.label.hasSuffix(week) }
        let fiveHour = available.first { $0.label.hasPrefix("Gemini") && $0.label.hasSuffix(five) }
        let argon = available.first { $0.label.contains("Argon") && $0.label.hasSuffix(week) }
        if let weekly, let fiveHour {
            return [glanceItem(weekly, what: L("agy Gemini 每週"), detail: tips[weekly.label]),
                    glanceItem(fiveHour, what: L("agy Gemini 5 小時（Hydrogen 等共用）"), detail: tips[fiveHour.label])]
                + (argon.map { [glanceItem($0, what: L("agy 阿公（Argon）每週"), detail: tips[$0.label])] } ?? [])
        }
        if !available.isEmpty { return available.map { glanceItem($0, what: L("agy \($0.label)"), detail: tips[$0.label]) } }
        return [
            UsageGlanceItem(tag: nil, what: L("agy Gemini 每週"), bucket: nil, detail: tips["Gemini 每週"], short: "week"),
            UsageGlanceItem(tag: nil, what: L("agy Gemini 5 小時（Hydrogen 等共用）"), bucket: nil, detail: tips["Gemini 5 小時"], short: "5h"),
            UsageGlanceItem(tag: nil, what: L("agy 阿公（Argon）每週"), bucket: nil, detail: tips["Argon 每週"], short: "argon"),
        ]
    }

    /// gh 裝在 Homebrew（登入 shell 的 PATH 不一定有）；沒裝就不查 Copilot。
    /// 測試實例（帶 `--state-dir` 啟動參數）會先讀取環境變數 `CODENV_GH_PATH`，否則使用固定路徑。
    static var ghPath: String? {
        ghPath(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
    }

    /// 依啟動參數與環境變數解析 `gh` 執行檔路徑。
    /// - Parameters:
    ///   - environment: 環境變數字典；僅在測試實例（`arguments` 含 `--state-dir`）讀取 `CODENV_GH_PATH`。
    ///   - arguments: 啟動參數陣列。
    /// - Returns: 測試覆寫路徑或第一個可執行的系統 `gh` 路徑；找不到則回傳 `nil`。
    static func ghPath(environment: [String: String], arguments: [String]) -> String? {
        if arguments.contains("--state-dir"),
           let override = environment["CODENV_GH_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var claudePath: String? {
        claudePath(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
    }

    static func claudePath(environment: [String: String], arguments: [String]) -> String? {
        if arguments.contains("--state-dir") {
            guard let override = environment["CODENV_CLAUDE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !override.isEmpty else { return nil }
            return override
        }
        let homeClaude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
        return [homeClaude, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static var dockerPath: String? {
        dockerPath(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
    }

    static func dockerPath(environment: [String: String], arguments: [String]) -> String? {
        if arguments.contains("--state-dir") {
            guard let override = environment["CODENV_DOCKER_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !override.isEmpty else { return nil }
            return override
        }
        return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// 只解析 `loggedIn` 與 `loginExpiresAt`，不保留或記錄任何帳號個資欄位。
    static func parseClaudeLoginExpiry(_ output: String) -> ClaudeLoginExpiry? {
        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["loggedIn"] as? Bool == true,
              let raw = obj["loginExpiresAt"] as? String,
              !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: raw)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: raw)
        }
        return date.map { ClaudeLoginExpiry(expiresAt: $0) }
    }

    static func loginExpiryText(expiresAt: Date?, now: Date = Date()) -> (text: String, level: ClaudeLoginExpiry.Level)? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 {
            return (L("登入已過期"), .expired)
        }
        let secondsPerDay = 86_400.0
        if remaining >= secondsPerDay {
            let days = Int(floor(remaining / secondsPerDay))
            let level: ClaudeLoginExpiry.Level = remaining <= 2.0 * secondsPerDay ? .warning : .normal
            return (L("登入 \(days) 天後到期"), level)
        }
        let hours = max(1, Int(floor(remaining / 3600.0)))
        return (L("登入 \(hours) 小時後到期"), .warning)
    }

    static func taipeiDateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "M/d HH:mm"
        return L("台北時間 \(formatter.string(from: date)) 到期")
    }

    static func parseDockerSocketPath(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = list.first,
              let endpoints = first["Endpoints"] as? [String: Any],
              let docker = endpoints["docker"] as? [String: Any],
              let host = docker["Host"] as? String else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("unix://") else { return nil }
        let path = String(trimmed.dropFirst("unix://".count))
        return path.isEmpty ? nil : path
    }

    static func fetchClaudeLoginExpiry(
        claudePath: String,
        runner: (String, [String], TimeInterval) -> ExternalCommand.Result? = {
            ExternalCommand.run($0, arguments: $1, timeout: $2)
        }
    ) -> ClaudeLoginExpiry? {
        guard let result = runner(claudePath, ["auth", "status"], 5),
              result.succeeded else { return nil }
        return parseClaudeLoginExpiry(result.stdout)
    }

    /// 判斷 `docker inspect` 是否明確因「連不到 Docker daemon / socket」失敗。
    /// 依據：Docker CLI 連不到 daemon（Kiri / Docker 未啟動，或殘留舊 socket 檔導致 dial 失敗）時，
    /// 會以非零結束碼（通常為 1）並在 stderr 輸出特徵文字：
    /// - "Cannot connect to the Docker daemon ..."（`cannot connect` / `is the docker daemon running`）
    /// - "error during connect: ... dial unix ...: connect: connection refused"（`connection refused`）
    /// - "error during connect: ... dial unix ...: connect: no such file or directory"（`dial unix` + `no such file or directory`）
    /// 反之，若 container 不存在（"No such object: agy2"）、權限不足、逾時或 stderr 無上述特徵，皆歸為 `.unreadable`。
    static func isDockerConnectionFailure(_ result: ExternalCommand.Result) -> Bool {
        guard !result.timedOut, !result.eofTimedOut, result.status != 0 else { return false }
        let err = result.stderr.lowercased()
        if err.contains("cannot connect")
            || err.contains("connection refused")
            || err.contains("is the docker daemon running") {
            return true
        }
        if err.contains("dial unix") && err.contains("no such file or directory") {
            return true
        }
        return false
    }

    /// 泛化容器額度讀取：只執行 `context inspect kiri`（5s）、`inspect -f {{.State.Running}} <容器>`（5s）、
    /// `exec <容器> agy -p=/usage`（10s）；不叫起 Docker，不保存原始輸出或 stderr。
    static func fetchContainerQuota(
        container: String,
        dockerPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        runner: (String, [String], TimeInterval) -> ExternalCommand.Result? = {
            ExternalCommand.run($0, arguments: $1, timeout: $2)
        }
    ) -> Agy2QuotaStatus {
        guard AgyContainerMap.isValidContainerName(container) else {
            return .unreadable
        }
        guard let contextResult = runner(dockerPath, ["context", "inspect", "kiri"], 5),
              contextResult.succeeded,
              let socketPath = parseDockerSocketPath(contextResult.stdout) else {
            return .unreadable
        }
        guard fileExists(socketPath) else {
            return .down
        }
        guard let inspectResult = runner(dockerPath, ["--context", "kiri", "inspect", "-f", "{{.State.Running}}", container], 5) else {
            return .unreadable
        }
        if !inspectResult.succeeded {
            return isDockerConnectionFailure(inspectResult) ? .down : .unreadable
        }
        switch inspectResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true":
            break
        case "false":
            return .down
        default:
            return .unreadable
        }
        guard let execResult = runner(dockerPath, ["--context", "kiri", "exec", container, "agy", "-p=/usage"], 10),
              execResult.succeeded else {
            return .unreadable
        }
        let buckets = parseAgy(execResult.stdout)
        return buckets.isEmpty ? .unreadable : .available(buckets)
    }

    static func fetchAgy2Quota(
        dockerPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        runner: (String, [String], TimeInterval) -> ExternalCommand.Result? = {
            ExternalCommand.run($0, arguments: $1, timeout: $2)
        }
    ) -> Agy2QuotaStatus {
        fetchContainerQuota(container: "agy2", dockerPath: dockerPath, fileExists: fileExists, runner: runner)
    }

    func fetchClaudeLoginExpiryCached(
        now: Date = Date(),
        claudePath: String? = UsageMonitor.claudePath,
        runner: ((String, [String], TimeInterval) -> ExternalCommand.Result?)? = nil
    ) -> ClaudeLoginExpiry? {
        guard let claudePath else { return nil }
        return claudeLoginProbe.value(now: now) {
            if let runner {
                return Self.fetchClaudeLoginExpiry(claudePath: claudePath, runner: runner)
            }
            return Self.fetchClaudeLoginExpiry(claudePath: claudePath)
        }
    }

    func fetchAgy2StatusCached(
        now: Date = Date(),
        dockerPath: String? = UsageMonitor.dockerPath,
        fileExists: ((String) -> Bool)? = nil,
        runner: ((String, [String], TimeInterval) -> ExternalCommand.Result?)? = nil,
        arguments: [String] = CommandLine.arguments
    ) -> Agy2QuotaStatus? {
        guard let dockerPath else {
            // 測試實例（--state-dir 且未設 CODENV_DOCKER_PATH）維持不查、不顯示；
            // 正式環境找不到 Docker CLI 時回傳 .unreadable（「agy2 讀不到」）。
            return arguments.contains("--state-dir") ? nil : .unreadable
        }
        return agy2Probe.value(now: now) {
            Self.fetchAgy2Quota(
                dockerPath: dockerPath,
                fileExists: fileExists ?? { FileManager.default.fileExists(atPath: $0) },
                runner: runner ?? { ExternalCommand.run($0, arguments: $1, timeout: $2) }
            )
        }
    }

    /// 解析 `gh api /copilot_internal/user` 的 JSON 回應。
    /// - Parameter text: API 回應的原始 JSON 字串。
    /// - Returns: 額度桶陣列、主要額度文字 `note`、選填小字 `footnote`、可選的剩餘／總次數；無有效資料或解析失敗時回傳 `nil`。
    ///   - 免費方案（`chat.unlimited != true` 且 `chat.entitlement > 0`）：讀取 `chat`，`note` 為「剩 N／M 次」，`footnote` 為 `nil`。
    ///   - 對話不限方案（`chat.unlimited == true`，如學生版）：改讀 `quota_snapshots.premium_interactions`，`note` 為「剩 N／M 次額度」；
    ///     若 `completions.unlimited == true`，`footnote` 為「補全不限，對話用額度」，否則為 `nil`；
    ///     若 `premium_interactions` 缺失且有 `footnote`，回傳無 bucket／次數為 `nil` 且僅含 `footnote` 的結果。
    static func parseCopilot(_ text: String) -> (buckets: [UsageBucket], note: String, footnote: String?, remaining: Int?, total: Int?)? {
        func intValue(_ raw: Any?) -> Int? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.intValue
        }
        func doubleValue(_ raw: Any?) -> Double? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        guard let d = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let snapshots = o["quota_snapshots"] as? [String: Any],
              let chat = snapshots["chat"] as? [String: Any] else { return nil }

        func parseResetDate() -> (resets: String, resetAt: Date?) {
            let resetRaw = o["quota_reset_date_utc"] as? String ?? o["quota_reset_date"] as? String
            let iso = ISO8601DateFormatter()
            var resetAt = resetRaw.flatMap { iso.date(from: $0) }
            if resetAt == nil {
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resetAt = resetRaw.flatMap { iso.date(from: $0) }
            }
            return (resetAt.map(when) ?? (resetRaw ?? ""), resetAt)
        }

        func buildQuota(
            from snapshot: [String: Any],
            footnote: String?,
            formatNote: (Int, Int) -> String
        ) -> (buckets: [UsageBucket], note: String, footnote: String?, remaining: Int?, total: Int?)? {
            guard let total = intValue(snapshot["entitlement"]), total > 0 else { return nil }
            let left = intValue(snapshot["remaining"]) ?? 0
            let pct = doubleValue(snapshot["percent_remaining"]) ?? Double(left) / Double(total) * 100
            let (resets, resetAt) = parseResetDate()
            let bucket = UsageBucket(label: L("每月"), used: Int((100 - pct).rounded()), resets: resets, resetAt: resetAt)
            return ([bucket], formatNote(left, total), footnote, left, total)
        }

        if chat["unlimited"] as? Bool != true {
            return buildQuota(from: chat, footnote: nil) { left, total in
                L("剩 \(left)／\(total) 次")
            }
        }

        let completionsUnlimited = (snapshots["completions"] as? [String: Any])?["unlimited"] as? Bool == true
        let footnote: String? = completionsUnlimited ? L("補全不限，對話用額度") : nil

        if let premium = snapshots["premium_interactions"] as? [String: Any],
           let parsed = buildQuota(from: premium, footnote: footnote, formatNote: { left, total in
               L("剩 \(left)／\(total) 次額度")
           }) {
            return parsed
        }

        if let footnote {
            return ([], "", footnote, nil, nil)
        }
        return nil
    }

    /// 重置時間：今天、明天寫字，其他寫日期
    static func when(_ d: Date) -> String {
        let o = DateFormatter()
        o.dateFormat = Calendar.current.isDateInToday(d) ? "'今天' HH:mm" : (Calendar.current.isDateInTomorrow(d) ? "'明天' HH:mm" : "M/d HH:mm")
        return o.string(from: d)
    }

    /// 「21:10 回補」「11/14 15:46 回補」：今天的時間不寫「今天」
    static func refillText(_ d: Date) -> String {
        when(d).replacingOccurrences(of: "今天 ", with: "") + " 回補"
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
        var out: [UsageBucket] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3, let left = Int(f[2].replacingOccurrences(of: "%", with: "")) else { continue }
            // 名字要短，右側欄窄（「Gemini 4 Argon 每週」會被截掉）
            let group = f[0] == "Gemini Models" ? "Gemini" : f[0] == "Claude and GPT models" ? "Claude" : f[0].replacingOccurrences(of: "Gemini 4 ", with: "")
            let span = f[1].contains("Five Hour") ? L("5 小時") : f[1].contains("Weekly") ? L("每週") : f[1]
            var resets = ""
            var resetDate: Date?
            if f.count >= 4, let d = AgySwapUsageCache.parseISO8601(f[3]) { resets = when(d); resetDate = d }
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
        let labels = [
            "gemini5": "Gemini 5 小時", "geminiWeek": "Gemini 每週", "argonWeek": "Argon 每週",
            "agyClaude5": "agy Claude 5 小時", "agyClaudeWeek": "agy Claude 每週",
        ]
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
                let candidate = Entry(account: accountName, remaining: clamped, reset: reset)
                if let previous = grouped[key]?[accountID], previous.remaining <= clamped { continue }
                grouped[key, default: [:]][accountID] = candidate
                let label = labels[key]!
                let resetLabel = reset.map { refillText($0) } ?? ""
                accountValues[accountID, default: [:]][label] = UsageBucket(label: label, used: 100 - Int(clamped.rounded()), resets: resetLabel, resetAt: reset)
            }
        }
        guard !grouped.isEmpty else { return nil }
        var buckets: [UsageBucket] = []
        var tips: [String: String] = [:]
        for key in ["gemini5", "geminiWeek", "argonWeek", "agyClaude5", "agyClaudeWeek"] {
            guard let rowsByAccount = grouped[key], !rowsByAccount.isEmpty else { continue }
            let rows = rowsByAccount.values.sorted { $0.account < $1.account }
            let left = Int((rows.map(\.remaining).reduce(0, +) / Double(rows.count)).rounded())
            let nextReset = rows.compactMap { row in row.reset.map { ($0, row.account) } }.min {
                if $0.0 == $1.0 { return $0.1 < $1.1 }
                return $0.0 < $1.0
            }
            let label = labels[key]!
            let resetLabel = nextReset.map { refillText($0.0) } ?? ""
            buckets.append(UsageBucket(label: label, used: 100 - left, resets: resetLabel, resetAt: nextReset?.0))
            let details = rows.map { row in
                "\(row.account)：剩 \(Int(row.remaining.rounded()))%" + (row.reset.map { "，\(when($0)) 重置" } ?? "")
            }.joined(separator: "\n")
            tips[label] = L("多帳號依同一額度池的剩餘百分比平均；重置時間取最早。") + "\n" + details
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
        // Claude & GPT 池只取總池 5 小時／每週窗口；逐模型條目不帶此 pool，略過。
        if s.contains("claude & gpt") {
            if s.contains("five hour") || s.contains("5 hour") || s.contains("5 小時") || s.contains("5h") { return "agyClaude5" }
            if s.contains("weekly") || s.contains("week") || s.contains("7 day") || s.contains("每週") { return "agyClaudeWeek" }
            return nil
        }
        if s.contains("argon") { return "argonWeek" }
        if s.contains("gemini 4") || s.contains("gemini4") { return s.contains("week") || s.contains("weekly") || s.contains("每週") ? "argonWeek" : nil }
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

    /// 對話存的模型代號 → 顯示名稱（agy:gemini-4-hydrogen-medium → Gemini 4 Hydrogen）；nil＝Claude Code 的預設
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

    func copilotExpiringSoonHint(now: Date = Date()) -> String? {
        guard let resetAt = copilotBuckets.first?.resetAt else { return nil }
        let fraction: Double
        let remainingText: String
        if let remaining = copilotRemaining, let total = copilotTotal, total > 0 {
            fraction = Double(remaining) / Double(total)
            remainingText = L("\(remaining) 次")
        } else if let bucket = copilotBuckets.first {
            fraction = Double(bucket.remaining) / 100.0
            remainingText = "\(bucket.remaining)%"
        } else {
            return nil
        }
        return Self.expiringSoonHint(
            poolName: "Copilot",
            remainingFraction: fraction,
            resetAt: resetAt,
            cycleDays: Self.poolCycleDays["Copilot"],
            now: now,
            remainingText: remainingText
        )
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

/// agy 帳號區塊的呈現狀態；完整用量卡與測試 dump 共用同一套顯示／收合判斷。
enum AgyAccountSectionPresentation {
    static func hasNumericData(_ account: AgySwapAccountDisplay) -> Bool {
        (account.state == .live || account.state == .cached) && !account.buckets.isEmpty
    }

    static func displayedAccounts(_ accounts: [AgySwapAccountDisplay]) -> [AgySwapAccountDisplay] {
        accounts.filter(hasNumericData)
    }

    static func defaultsKey(accountKey: String) -> String {
        "agyUsageAccountCollapsed.\(accountKey)"
    }

    static func isCollapsed(accountKey: String, defaults: UserDefaults = appDefaults) -> Bool {
        defaults.object(forKey: defaultsKey(accountKey: accountKey)) as? Bool ?? true
    }

    static func setCollapsed(_ collapsed: Bool, accountKey: String, defaults: UserDefaults = appDefaults) {
        defaults.set(collapsed, forKey: defaultsKey(accountKey: accountKey))
    }

    static func dumpSections(
        accounts: [AgySwapAccountDisplay],
        defaults: UserDefaults = appDefaults
    ) -> [[String: Any]] {
        accounts.map { account in
            let displayed = hasNumericData(account)
            let collapsed = isCollapsed(accountKey: account.name, defaults: defaults)
            return [
                "accountKey": account.name,
                "displayed": displayed,
                "collapsed": collapsed,
                "visibleBucketLabels": displayed && !collapsed ? account.buckets.map(\.label) : [],
            ]
        }
    }

    /// 收合單列摘要用的 5 小時／每週剩餘百分比。
    static func collapsedSummaryPercents(for account: AgySwapAccountDisplay) -> (fiveHour: Int?, weekly: Int?) {
        let five = L("5 小時")
        let week = L("每週")
        let fiveBucket = account.buckets.first { $0.label == "Gemini \(five)" }
            ?? account.buckets.first { !$0.label.hasPrefix("Claude") && $0.label.contains(five) }
        let weekBucket = account.buckets.first { $0.label == "Gemini \(week)" }
            ?? account.buckets.first { !$0.label.hasPrefix("Claude") && !$0.label.contains("Argon") && $0.label.contains(week) }
        return (fiveBucket?.remaining, weekBucket?.remaining)
    }

    /// 收合狀態下的單列顯示文字（供 dump 與畫面一致）。
    static func collapsedHeaderLine(for account: AgySwapAccountDisplay) -> String {
        var parts = [account.name]
        if account.isActive { parts.append(L("使用中")) }
        let summary = collapsedSummaryPercents(for: account)
        if let f = summary.fiveHour { parts.append(L("5 小時 \(f)%")) }
        if let w = summary.weekly { parts.append(L("每週 \(w)%")) }
        return parts.joined(separator: " ")
    }
}

/// F12 面板中「重置時間」與「剩餘額度／餘額／已花上限」的單一紫色定義（淺／深色高對比）。
enum UsageHighlightColor {
    static let lightNSColor = NSColor(srgbRed: 0x6D / 255.0, green: 0x28 / 255.0, blue: 0xD9 / 255.0, alpha: 1.0)
    static let darkNSColor = NSColor(srgbRed: 0xC4 / 255.0, green: 0xB5 / 255.0, blue: 0xFD / 255.0, alpha: 1.0)

    static let nsColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkNSColor : lightNSColor
    }

    static var color: Color { Color(nsColor: nsColor) }

    /// 從 View 實際套用的動態 `nsColor` 解析指定外觀下的 `#RRGGBB` 色票（不另造探針常數）。
    static func hexString(for appearanceName: NSAppearance.Name) -> String {
        var resolved = lightNSColor
        if let appearance = NSAppearance(named: appearanceName) {
            appearance.performAsCurrentDrawingAppearance {
                resolved = nsColor.usingColorSpace(.sRGB) ?? lightNSColor
            }
        }
        let r = Int((resolved.redComponent * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

enum UsagePurpleSemanticField: String, Equatable, Hashable {
    case resetTime
    case remainingQuota
    case balance
    case spentLimit
}

struct StyledNoteSegment: Equatable {
    let text: String
    let purpleField: UsagePurpleSemanticField?
}

/// 附註文字分段著色：只把「剩餘額度／餘額／已花上限／重置時間」數字段標紫，括號說明與本機計數等維持灰字。
enum UsageNoteStyling {
    static func segments(for text: String) -> [StyledNoteSegment] {
        guard !text.isEmpty else { return [] }
        func splitParenthetical(_ s: String, field: UsagePurpleSemanticField) -> [StyledNoteSegment] {
            if let idx = s.firstIndex(where: { $0 == "（" || $0 == "(" }) {
                let prefix = String(s[..<idx])
                let suffix = String(s[idx...])
                var result: [StyledNoteSegment] = []
                if !prefix.isEmpty { result.append(StyledNoteSegment(text: prefix, purpleField: field)) }
                if !suffix.isEmpty { result.append(StyledNoteSegment(text: suffix, purpleField: nil)) }
                return result
            }
            return [StyledNoteSegment(text: s, purpleField: field)]
        }

        if text.hasPrefix("餘額 ") {
            return splitParenthetical(text, field: .balance)
        }
        if text.hasPrefix("已花 ") {
            return splitParenthetical(text, field: .spentLimit)
        }
        if text.contains("剩 ") && (text.contains("次額度") || text.contains("小時") || text.hasPrefix("剩 ")) {
            if let range = text.range(of: "，下次重置 ") {
                let left = String(text[..<range.lowerBound])
                let right = String(text[text.index(after: range.lowerBound)...])
                var result: [StyledNoteSegment] = []
                if !left.isEmpty { result.append(StyledNoteSegment(text: left, purpleField: .remainingQuota)) }
                result.append(StyledNoteSegment(text: "，", purpleField: nil))
                if !right.isEmpty { result.append(StyledNoteSegment(text: right, purpleField: .resetTime)) }
                return result
            }
            return splitParenthetical(text, field: .remainingQuota)
        }
        return [StyledNoteSegment(text: text, purpleField: nil)]
    }

    static func attributedText(for text: String) -> AttributedString {
        var out = AttributedString()
        for seg in segments(for: text) {
            var part = AttributedString(seg.text)
            if seg.purpleField != nil {
                part.foregroundColor = UsageHighlightColor.color
            } else {
                part.foregroundColor = Color(nsColor: .tertiaryLabelColor)
            }
            out.append(part)
        }
        return out
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
                Text(row.label).font(InterfaceFont.swiftUIFont(size: 12 * s))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("\(b.remaining)%").font(InterfaceFont.swiftUIFont(size: 15 * s, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(UsageRowView.color(b.remaining))
                    .fixedSize()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(UsageRowView.color(b.remaining)).frame(width: g.size.width * CGFloat(b.remaining) / 100)
                }
            }
            .frame(height: 5)
            if !b.resets.isEmpty {
                if b.resets.hasSuffix("回補") {
                    Text(b.resets).font(InterfaceFont.swiftUIFont(size: 11 * s)).foregroundStyle(UsageHighlightColor.color)
                } else {
                    Text(L("\(b.resets) 重置")).font(InterfaceFont.swiftUIFont(size: 11 * s)).foregroundStyle(UsageHighlightColor.color)
                }
            }
        }
        .help(detail ?? "")
    }
    /// 剩兩成以下紅，其他綠
    static func color(_ remaining: Int) -> Color { isLow(remaining) ? .red : .green }
    static func isLow(_ remaining: Int) -> Bool { remaining <= 20 }
}

/// 右欄顯示某個額度池目前在分頁中使用的模型與聊天室名稱。
private struct ActiveUsageModelsView: View {
    @Environment(\.uiScale) private var s
    let models: [(model: String, titles: [String])]

    var body: some View {
        ForEach(models, id: \.model) { u in
            // 聊天室名字放下一行（括號被拆在兩行中間不好讀）
            Text(L("使用中：\(u.model)\n（\(u.titles.joined(separator: "、"))）"))
                .font(InterfaceFont.swiftUIFont(size: 11 * s)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Gemini（agy）卡片／右欄內嵌的 Claude／GPT（agy）分段，保留細分隔線與小標。
private struct ClaudeAgyUsageSection: View {
    @Environment(\.uiScale) private var s
    let rows: [UsageRow]
    var models: [(model: String, titles: [String])] = []
    var topPadding: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            Divider().opacity(0.25)
            Text(L("Claude／GPT（agy）"))
                .font(InterfaceFont.swiftUIFont(size: 11.5 * s, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows) { row in
                UsageRowView(row: row)
            }
            ActiveUsageModelsView(models: models)
        }
        .padding(.top, topPadding * s)
    }
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
                        Text(L("用量剩餘")).font(InterfaceFont.swiftUIFont(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary)
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
            // 只列目前這個分頁裡每一格用到的額度池（換模型、換分頁就跟著變）；.claudeAgy 併入 .gemini 分段顯示
            let windowPools = store.usagePoolsInCurrentWindow
            let hasGemini = windowPools.contains { $0.pool == .gemini }
            let hasClaudeAgy = windowPools.contains { $0.pool == .claudeAgy }
            let geminiArgon = windowPools.first { $0.pool == .gemini }?.argon ?? false
            let panelPools = windowPools.reduce(into: [(pool: UsagePool, argon: Bool)]()) { out, item in
                if item.pool == .gemini || item.pool == .claudeAgy {
                    if !out.contains(where: { $0.pool == .gemini }) { out.append((.gemini, geminiArgon)) }
                } else {
                    out.append(item)
                }
            }
            ForEach(panelPools, id: \.pool) { p in
                if p.pool == .gemini {
                    let agyPanel = m.agyPanelPresentation()
                    if agyPanel.showSwapHeader {
                        if let accountName = agyPanel.accountName {
                            HStack(spacing: 5) {
                                Text(accountName)
                                    .font(InterfaceFont.swiftUIFont(size: 11.5 * s, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let activeBadge = agyPanel.activeBadgeText {
                                    Text(activeBadge)
                                        .font(InterfaceFont.swiftUIFont(size: 9.5 * s, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5 * s).padding(.vertical, 1.5 * s)
                                        .background(Capsule().fill(Color.white.opacity(0.08)))
                                }
                                Spacer(minLength: 4)
                                if let ageText = agyPanel.ageText {
                                    Text(ageText)
                                        .font(InterfaceFont.swiftUIFont(size: 10 * s))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if let statusText = agyPanel.statusText {
                            Text(statusText)
                                .font(InterfaceFont.swiftUIFont(size: 11 * s))
                                .foregroundStyle(agyPanel.isStatusError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                        }
                    }
                    if hasGemini {
                        ForEach(m.rows(.gemini, argon: p.argon)) { r in UsageRowView(row: r) }
                        ActiveUsageModelsView(models: store.modelsInCurrentWindow(.gemini))
                    }
                    if hasClaudeAgy {
                        let claudeAgyRows = m.rows(.claudeAgy)
                        if !claudeAgyRows.isEmpty {
                            ClaudeAgyUsageSection(rows: claudeAgyRows, models: store.modelsInCurrentWindow(.claudeAgy))
                        }
                    }
                    if let othersText = agyPanel.othersText {
                        Text(othersText)
                            .font(InterfaceFont.swiftUIFont(size: 11 * s))
                            .foregroundStyle(.tertiary)
                    }
                    PoolNote(m: m, pool: .gemini)
                } else {
                    ForEach(m.rows(p.pool, argon: p.argon)) { r in UsageRowView(row: r) }
                    // 這個池是哪些格、哪個模型在用
                    ActiveUsageModelsView(models: store.modelsInCurrentWindow(p.pool))
                    PoolNote(m: m, pool: p.pool)
                }
            }
            ForEach(m.extraKeyPools) { extra in
                ExtraKeyPoolCard(pool: extra, compact: true)
            }
            ForEach(m.localExtraPools) { extra in
                ExtraKeyPoolCard(pool: extra, compact: true)
            }
            if m.buckets.isEmpty && !m.loading {
                Text(m.error ?? L("查詢中…")).font(InterfaceFont.swiftUIFont(size: 12 * s)).foregroundStyle(.tertiary)
            }
            SprintCard()
            ContextBlock(store: store, compact: compact)
            ActivityBlock(store: store)
            Spacer(minLength: 0)
            if let u = m.updated {
                Text(m.error != nil ? L("更新於 \(u.formatted(date: .omitted, time: .shortened))（這次查不到，顯示的是舊資料）") : L("更新於 \(u.formatted(date: .omitted, time: .shortened))")).font(InterfaceFont.swiftUIFont(size: 10 * s)).foregroundStyle(m.error != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
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
        let noteText = m.note(pool)
        let canReset = pool == .codex && m.codexResets > 0
        let copilotHint = pool == .copilot ? m.copilotExpiringSoonHint() : nil
        VStack(alignment: .leading, spacing: 4) {
            if noteText != nil || canReset {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    if let n = noteText {
                        if pool == .copilot {
                            Text(UsageNoteStyling.attributedText(for: n))
                                .font(InterfaceFont.swiftUIFont(size: 11 * s))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(n).font(InterfaceFont.swiftUIFont(size: 11 * s)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if canReset {
                        Button(action: { m.requestCodexReset() }) {
                            Text(m.codexResetBusy ? L("重置中…") : L("重置")).font(InterfaceFont.swiftUIFont(size: 10.5 * s))
                                .padding(.horizontal, 8 * s).padding(.vertical, 2 * s)
                                .overlay(Capsule().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(m.codexResetBusy)
                        .help(L("用掉 1 次免費全部重置（會先問你）") + (m.codexResetExpiries.isEmpty ? "" : "\n" + L("各張過期時間：") + m.codexResetExpiries.map { UsageMonitor.when($0) }.joined(separator: "、")))
                    }
                }
            }
            if pool == .copilot, let footnote = m.copilotFootnote, !footnote.isEmpty {
                Text(footnote).font(InterfaceFont.swiftUIFont(size: 10.5 * s)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let copilotHint {
                Text(copilotHint).font(InterfaceFont.swiftUIFont(size: 10.5 * s)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if pool == .codex, let st = m.codexResetStatus {
                Text(st).font(InterfaceFont.swiftUIFont(size: 10.5 * s)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UsageCardFramesPreference: Equatable {
    var size = CGSize.zero
    var frames: [String: CGRect] = [:]
}

private struct UsageCardFramesPreferenceKey: PreferenceKey {
    static var defaultValue = UsageCardFramesPreference()
    static func reduce(value: inout UsageCardFramesPreference, nextValue: () -> UsageCardFramesPreference) {
        let next = nextValue()
        if next.size != .zero { value.size = next.size }
        value.frames.merge(next.frames) { _, new in new }
    }
}

private struct UsageMasonryLayout: Layout {
    let cardWidth: CGFloat
    let gap: CGFloat

    static func columnCount(width: CGFloat, cardWidth: CGFloat, gap: CGFloat) -> Int {
        min(4, max(1, Int(floor((max(0, width) + gap + 0.5) / (cardWidth + gap)))))
    }

    private func placements(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let count = Self.columnCount(width: width, cardWidth: cardWidth, gap: gap)
        var bottoms = Array(repeating: CGFloat.zero, count: count)
        var frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil))
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            let frame = CGRect(x: CGFloat(column) * (cardWidth + gap), y: bottoms[column], width: cardWidth, height: size.height)
            frames.append(frame)
            bottoms[column] = frame.maxY + gap
        }
        let height = bottoms.max().map { $0 - (subviews.isEmpty ? 0 : gap) } ?? 0
        return (frames, max(0, height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(cardWidth, proposal.width ?? cardWidth)
        return CGSize(width: width, height: placements(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = placements(width: bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: cardWidth, height: frame.height))
        }
    }
}

enum UsageCardItem: Identifiable {
    case pool(UsagePool)
    case extra(ExtraKeyPool)

    var key: String {
        switch self {
        case .pool(let p): return UsageCardOrder.poolKey(p)
        case .extra(let e): return UsageCardOrder.extraKey(e)
        }
    }

    var id: String { key }
}

/// F12 面板卡片拖曳狀態機：負責半透明跟隨層座標、目標高亮，以及 Esc／關閉／卡消失時取消當前手勢。
final class UsageCardDragState: ObservableObject {
    static let inactive = UsageCardDragState()

    struct Commit: Equatable {
        let sourceKey: String
        let target: UsageCardOrder.DropTarget
    }

    @Published private(set) var activeKey: String? = nil
    @Published private(set) var currentLocation: CGPoint = .zero
    @Published private(set) var grabOffset: CGSize = .zero
    @Published private(set) var dropTarget: UsageCardOrder.DropTarget? = nil

    private var activeStartLocation: CGPoint? = nil
    private var cancelledStartLocation: CGPoint? = nil
    private var isGestureCancelled = false

    var isDragging: Bool { activeKey != nil }

    var ghostOrigin: CGPoint {
        CGPoint(x: currentLocation.x - grabOffset.width, y: currentLocation.y - grabOffset.height)
    }

    func updateDrag(
        key: String,
        startLocation: CGPoint,
        location: CGPoint,
        gridSize: CGSize,
        cardFrames: [String: CGRect],
        visibleKeys: [String],
        bottomMargin: CGFloat
    ) {
        if isGestureCancelled {
            // 同一次滑鼠拖曳已被 Esc／卡消失取消：在放開前忽略後續 onChanged
            if let cancelledStart = cancelledStartLocation,
               abs(cancelledStart.x - startLocation.x) < 0.01,
               abs(cancelledStart.y - startLocation.y) < 0.01 {
                return
            }
            isGestureCancelled = false
            cancelledStartLocation = nil
        }

        guard visibleKeys.contains(key) else {
            cancelCurrentDrag()
            return
        }

        if activeKey != key {
            activeKey = key
            activeStartLocation = startLocation
            if let frame = cardFrames[key] {
                grabOffset = CGSize(width: startLocation.x - frame.minX, height: startLocation.y - frame.minY)
            } else {
                grabOffset = .zero
            }
        }
        currentLocation = location
        dropTarget = UsageCardOrder.dropTarget(
            at: location,
            gridSize: gridSize,
            cardFrames: cardFrames,
            visibleOrder: visibleKeys,
            bottomMargin: bottomMargin
        )
    }

    func finishDrag(
        key: String,
        location: CGPoint,
        gridSize: CGSize,
        cardFrames: [String: CGRect],
        visibleKeys: [String],
        bottomMargin: CGFloat
    ) -> Commit? {
        if isGestureCancelled {
            isGestureCancelled = false
            cancelledStartLocation = nil
            clearActiveVisuals()
            return nil
        }
        let sourceKey = activeKey ?? key
        clearActiveVisuals()
        guard visibleKeys.contains(sourceKey),
              let target = UsageCardOrder.dropTarget(
                at: location,
                gridSize: gridSize,
                cardFrames: cardFrames,
                visibleOrder: visibleKeys,
                bottomMargin: bottomMargin
              ) else {
            return nil
        }
        return Commit(sourceKey: sourceKey, target: target)
    }

    func cancelCurrentDrag() {
        if activeKey != nil {
            isGestureCancelled = true
            cancelledStartLocation = activeStartLocation
        }
        clearActiveVisuals()
    }

    func handleVisibleKeysChanged(_ visibleKeys: [String]) {
        if let activeKey, !visibleKeys.contains(activeKey) {
            cancelCurrentDrag()
        }
    }

    private func clearActiveVisuals() {
        activeKey = nil
        dropTarget = nil
        activeStartLocation = nil
        grabOffset = .zero
    }
}

/// 完整用量頁：照排序把卡片放進目前最矮的一欄，並支援左鍵拖曳重排（單卡模式不啟用）
struct UsageFullPage: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var m: UsageMonitor
    @ObservedObject var cardOrderStore: UsageCardOrderStore = .shared
    @ObservedObject var dragState: UsageCardDragState = .inactive
    var scroll = true
    var onLayout: ((CGSize, [String: CGRect]) -> Void)? = nil
    var onlyPool: UsagePool? = nil
    var isDragEnabled = true
    var fixedWidth: CGFloat? = nil

    @State private var gridSize: CGSize = .zero
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var agyCollapseRevision = 0

    static let cardWidth: CGFloat = 300
    static let gap: CGFloat = 12
    static let pad: CGFloat = 18
    static let scrollReserve: CGFloat = 16
    static func width(columns: Int, scale: CGFloat) -> CGFloat {
        (cardWidth * CGFloat(columns) + gap * CGFloat(columns - 1) + pad * 2) * scale
    }

    /// 供單元測試直接驗證 `UsageMasonryLayout.columnCount` 的 0.5pt 容差。
    static func columnCount(width: CGFloat, cardWidth: CGFloat, gap: CGFloat) -> Int {
        UsageMasonryLayout.columnCount(width: width, cardWidth: cardWidth, gap: gap)
    }

    /// 依 `savedOrder` 組出畫面與 `--usage-panel-dump` 共用的卡片清單（單卡模式維持原樣不重排）。
    static func orderedItems(
        for m: UsageMonitor,
        onlyPool: UsagePool? = nil,
        savedOrder: [String] = []
    ) -> [UsageCardItem] {
        var defaultItems: [UsageCardItem] = visiblePools(for: m, onlyPool: onlyPool).map { .pool($0) }
        if onlyPool == nil {
            defaultItems.append(contentsOf: m.extraKeyPools.map { .extra($0) })
            defaultItems.append(contentsOf: m.localExtraPools.map { .extra($0) })
        }
        guard onlyPool == nil else { return defaultItems }

        var byKey: [String: UsageCardItem] = [:]
        var defaultKeys: [String] = []
        for item in defaultItems {
            if byKey[item.key] == nil {
                byKey[item.key] = item
                defaultKeys.append(item.key)
            }
        }
        let orderedKeys = UsageCardOrder.orderedKeys(currentKeys: defaultKeys, savedOrder: savedOrder)
        return orderedKeys.compactMap { byKey[$0] }
    }

    var body: some View {
        let base = Group {
            if scroll { ScrollView { content } } else { content }
        }
        Group {
            if let fixedWidth {
                base.frame(width: fixedWidth, alignment: .topLeading)
            } else {
                base.frame(minWidth: Self.width(columns: 1, scale: s),
                           idealWidth: Self.width(columns: 3, scale: s) + Self.scrollReserve * s,
                           maxWidth: Self.width(columns: 4, scale: s) + Self.scrollReserve * s,
                           alignment: .topLeading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    static func visiblePools(for m: UsageMonitor, onlyPool: UsagePool? = nil) -> [UsagePool] {
        UsagePool.allCases.filter { pool in
            pool != .claudeAgy
                && (onlyPool == nil || onlyPool == pool)
                && (!m.rows(pool).isEmpty
                    || (pool == .cc && m.claudeLoginExpiry != nil)
                    || (pool == .gemini && (!m.rows(.claudeAgy).isEmpty || m.usesSwapAccountDisplay || !m.magpieAccounts.isEmpty || m.agy2Status != nil))
                    || (pool == .codex && !m.codexAccounts.isEmpty)
                    || (pool == .copilot && !(m.copilotFootnote?.isEmpty ?? true)))
        }
    }

    private var content: some View {
        let items = Self.orderedItems(
            for: m,
            onlyPool: onlyPool,
            savedOrder: onlyPool == nil ? cardOrderStore.savedOrder : []
        )
        let visibleKeys = items.map(\.key)
        let dragActive = isDragEnabled && onlyPool == nil

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("全部的用量")).font(InterfaceFont.swiftUIFont(size: 16 * s, weight: .semibold))
                Spacer()
                if m.loading { ProgressView().controlSize(.small) }
                else {
                    Button(action: { m.refresh() }) { Image(systemName: "arrow.clockwise").font(.system(size: 12 * s)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(L("現在重新查"))
                }
            }
            UsageMasonryLayout(cardWidth: Self.cardWidth * s, gap: Self.gap * s) {
                ForEach(items) { item in
                    draggableCard(for: item, dragEnabled: dragActive, visibleKeys: visibleKeys)
                        .background(cardFrame(item.key))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if dragActive {
                    dragOverlay(items: items)
                }
            }
            .coordinateSpace(name: "usage-card-grid")
            .background(GeometryReader { geometry in
                Color.clear.preference(key: UsageCardFramesPreferenceKey.self,
                                       value: UsageCardFramesPreference(size: geometry.size))
            })
            .onPreferenceChange(UsageCardFramesPreferenceKey.self) { value in
                gridSize = value.size
                cardFrames = value.frames
                onLayout?(value.size, value.frames)
            }
            .onChange(of: visibleKeys) { _, newKeys in
                if dragActive {
                    dragState.handleVisibleKeysChanged(newKeys)
                }
            }
            if let u = m.updated {
                Text((m.error != nil ? L("更新於 \(u.formatted(date: .omitted, time: .shortened))（這次查不到，顯示的是舊資料）") : L("更新於 \(u.formatted(date: .omitted, time: .shortened))")) + L("　按 Esc 或點外面關掉"))
                    .font(InterfaceFont.swiftUIFont(size: 10 * s)).foregroundStyle(m.error != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary)).padding(.top, 4)
            }
        }
        .padding(Self.pad * s)
    }

    @ViewBuilder
    private func cardItemView(_ item: UsageCardItem) -> some View {
        switch item {
        case .pool(let pool):
            card(pool)
        case .extra(let extra):
            extraCard(extra)
        }
    }

    @ViewBuilder
    private func draggableCard(for item: UsageCardItem, dragEnabled: Bool, visibleKeys: [String]) -> some View {
        let isBeingDragged = dragEnabled && dragState.activeKey == item.key
        let base = cardItemView(item)
            .opacity(isBeingDragged ? 0.28 : 1.0)
        if dragEnabled {
            base
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .gesture(cardDragGesture(for: item.key, visibleKeys: visibleKeys))
        } else {
            base
        }
    }

    private func cardDragGesture(for key: String, visibleKeys: [String]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("usage-card-grid"))
            .onChanged { value in
                dragState.updateDrag(
                    key: key,
                    startLocation: value.startLocation,
                    location: value.location,
                    gridSize: gridSize,
                    cardFrames: cardFrames,
                    visibleKeys: visibleKeys,
                    bottomMargin: Self.pad * s
                )
            }
            .onEnded { value in
                guard let commit = dragState.finishDrag(
                    key: key,
                    location: value.location,
                    gridSize: gridSize,
                    cardFrames: cardFrames,
                    visibleKeys: visibleKeys,
                    bottomMargin: Self.pad * s
                ) else { return }
                cardOrderStore.moveCard(
                    sourceKey: commit.sourceKey,
                    target: commit.target,
                    visibleKeys: visibleKeys
                )
            }
    }

    @ViewBuilder
    private func dragOverlay(items: [UsageCardItem]) -> some View {
        let visibleKeys = items.map(\.key)
        ZStack(alignment: .topLeading) {
            if let activeKey = dragState.activeKey,
               let indicator = insertionIndicator(for: dragState.dropTarget, activeKey: activeKey, visibleKeys: visibleKeys) {
                Capsule().fill(Color.accentColor.opacity(0.95))
                    .frame(width: indicator.width, height: indicator.height)
                    .offset(x: indicator.minX, y: indicator.minY)
                    .allowsHitTesting(false)
            }
            if let activeKey = dragState.activeKey,
               let activeItem = items.first(where: { $0.key == activeKey }) {
                cardItemView(activeItem)
                    .opacity(0.76)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .scaleEffect(1.01)
                    .offset(x: dragState.ghostOrigin.x, y: dragState.ghostOrigin.y)
                    .allowsHitTesting(false)
                    .transformPreference(UsageCardFramesPreferenceKey.self) { $0 = UsageCardFramesPreference() }
            }
        }
        .allowsHitTesting(false)
    }

    private func insertionIndicator(for target: UsageCardOrder.DropTarget?, activeKey: String, visibleKeys: [String]) -> CGRect? {
        guard let target else { return nil }
        if target == .end {
            guard gridSize.width > 0 else { return nil }
            return CGRect(x: 0, y: gridSize.height + 3, width: gridSize.width, height: 3)
        }
        let key: String
        let after: Bool
        switch target {
        case .before(let value): key = value; after = false
        case .after(let value): key = value; after = true
        case .end: return nil
        }
        guard key != activeKey, let frame = cardFrames[key] else { return nil }
        let visibleCardFrames = visibleKeys.compactMap { cardFrames[$0] }
        let distinctColumns = Set(visibleCardFrames.map { Int(($0.minX * 100).rounded()) }).count
        if distinctColumns > 1 {
            return CGRect(x: after ? frame.maxX - 1.5 : frame.minX - 1.5,
                          y: frame.minY, width: 3, height: frame.height)
        }
        return CGRect(x: frame.minX, y: after ? frame.maxY - 1.5 : frame.minY - 1.5,
                      width: frame.width, height: 3)
    }

    private func cardFrame(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: UsageCardFramesPreferenceKey.self,
                                   value: UsageCardFramesPreference(frames: [key: geometry.frame(in: .named("usage-card-grid"))]))
        }
    }

    @ViewBuilder
    private func card(_ p: UsagePool) -> some View {
        if p == .gemini, m.usesSwapAccountDisplay {
            agyAccountsCard()
        } else if p == .gemini, !m.magpieAccounts.isEmpty {
            legacyMagpieAgyAccountsCard()
        } else if p == .codex, !m.codexAccounts.isEmpty {
            codexAccountsCard()
        } else {
            standardCard(p)
        }
    }

    private func standardCard(_ p: UsagePool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let gl = p.glyph {
                    Image(nsImage: gl.image).resizable().renderingMode(gl.template ? .template : .original)
                        .aspectRatio(contentMode: .fit).frame(width: 15 * s, height: 15 * s)
                }
                Text(p.title).font(InterfaceFont.swiftUIFont(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if p == .cc, let expiry = m.claudeLoginExpiry, let info = UsageMonitor.loginExpiryText(expiresAt: expiry.expiresAt) {
                    Spacer(minLength: 4)
                    Text(info.text)
                        .font(InterfaceFont.swiftUIFont(size: 10.5 * s))
                        .foregroundStyle(loginExpiryColor(info.level))
                        .lineLimit(1)
                        .help(UsageMonitor.taipeiDateTimeText(expiry.expiresAt))
                }
            }
            ForEach(m.rows(p)) { r in
                UsageRowView(row: r, detail: p == .gemini ? m.magpieQuotaTips[r.bucket.label] : nil)
            }
            if p == .gemini {
                let claudeAgyRows = m.rows(.claudeAgy)
                if !claudeAgyRows.isEmpty {
                    ClaudeAgyUsageSection(rows: claudeAgyRows, topPadding: 2)
                }
            }
            if p == .gemini, !m.agySwapMode, let agy2Status = m.agy2Status {
                agy2Section(agy2Status)
            }
            PoolNote(m: m, pool: p)
        }
        .padding(12 * s)
        .frame(width: Self.cardWidth * s, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    /// 換帳號模式（≥2 帳號）的 Gemini（agy）多帳號卡片：最上方為合計列（有資料才顯示），下方僅顯示有數字的帳號且可收合，不顯示舊 agy2。
    private func agyAccountsCard() -> some View {
        let totalSummary = AgyContainerUsage.computeTotalSummary(accounts: m.agySwapAccounts)
        let displayedAccounts = AgyAccountSectionPresentation.displayedAccounts(m.agySwapAccounts)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let gl = UsagePool.gemini.glyph {
                    Image(nsImage: gl.image).resizable().renderingMode(gl.template ? .template : .original)
                        .aspectRatio(contentMode: .fit).frame(width: 15 * s, height: 15 * s)
                }
                Text(UsagePool.gemini.title)
                    .font(InterfaceFont.swiftUIFont(size: 13 * s, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let totalSummary {
                agyTotalSection(totalSummary)
                if !displayedAccounts.isEmpty {
                    Divider().opacity(0.35)
                }
            }
            ForEach(Array(displayedAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Divider().opacity(0.25)
                }
                agySwapAccountSection(account)
            }
        }
        .padding(12 * s)
        .frame(width: Self.cardWidth * s, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    /// 合計區塊（規格 8.2）：使用獨立的簡單列畫面，不複用 `UsageRowView`、不顯示重置時間。
    private func agyTotalSection(_ summary: AgyTotalSummary) -> some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 7 * s) {
            Text(summary.title)
                .font(InterfaceFont.swiftUIFont(size: 12 * s, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(summary.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(row.displayLabel)
                            .font(InterfaceFont.swiftUIFont(size: 12 * s))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text("\(row.percent)%")
                            .font(InterfaceFont.swiftUIFont(size: 15 * s, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(UsageRowView.color(row.percent))
                            .fixedSize()
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule()
                                .fill(UsageRowView.color(row.percent))
                                .frame(width: g.size.width * CGFloat(max(0, min(100, row.percent))) / 100)
                        }
                    }
                    .frame(height: 5)
                    if let footnote = row.footnoteText(now: now) {
                        Text(footnote)
                            .font(InterfaceFont.swiftUIFont(size: 10.5 * s))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func agySwapAccountSection(_ account: AgySwapAccountDisplay) -> some View {
        _ = agyCollapseRevision
        let collapsed = AgyAccountSectionPresentation.isCollapsed(accountKey: account.name)
        let summary = AgyAccountSectionPresentation.collapsedSummaryPercents(for: account)
        let geminiRows = account.buckets
            .filter { !$0.label.hasPrefix("Claude") }
            .map { UsageRow(pool: .gemini, label: $0.label.replacingOccurrences(of: "Gemini ", with: ""), bucket: $0) }
        let claudeAgyRows = account.buckets
            .filter { $0.label.hasPrefix("Claude") }
            .map { UsageRow(pool: .claudeAgy, label: $0.label.replacingOccurrences(of: "Claude ", with: "") + " (agy)", bucket: $0) }

        return VStack(alignment: .leading, spacing: 7 * s) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9 * s, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10 * s)
                Text(account.name)
                    .font(InterfaceFont.swiftUIFont(size: 12 * s, weight: .semibold))
                    .lineLimit(1)
                if account.isActive {
                    Text(L("使用中"))
                        .font(InterfaceFont.swiftUIFont(size: 9.5 * s, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5 * s).padding(.vertical, 2 * s)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .fixedSize()
                }
                Spacer(minLength: 4)
                if collapsed {
                    HStack(spacing: 6 * s) {
                        if let five = summary.fiveHour {
                            Text(L("5h \(five)%"))
                                .font(InterfaceFont.swiftUIFont(size: 11 * s, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(UsageRowView.color(five))
                                .fixedSize()
                        }
                        if let week = summary.weekly {
                            Text(L("週 \(week)%"))
                                .font(InterfaceFont.swiftUIFont(size: 11 * s, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(UsageRowView.color(week))
                                .fixedSize()
                        }
                    }
                } else if account.state == .cached {
                    Text(account.ageText)
                        .font(InterfaceFont.swiftUIFont(size: 10 * s))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                AgyAccountSectionPresentation.setCollapsed(!collapsed, accountKey: account.name)
                agyCollapseRevision &+= 1
            }

            if !collapsed {
                if let sourceLabel = AgyContainerUsage.sourceDisplayLabel(account.source) {
                    Text(sourceLabel)
                        .font(InterfaceFont.swiftUIFont(size: 10 * s))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(geminiRows) { row in
                    UsageRowView(row: row)
                }
                if !claudeAgyRows.isEmpty {
                    ClaudeAgyUsageSection(rows: claudeAgyRows, topPadding: 2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 保留給既有 `--agy-usage-card-probe`（Magpie 測試輸入）相容；日常與換帳號模式不走這裡。
    private func legacyMagpieAgyAccountsCard() -> some View {
        let summaryRows = m.rows(.gemini)
        let accountCount = m.magpieAccounts.filter { !agyAccountRows($0, summaryRows: summaryRows).isEmpty }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let gl = UsagePool.gemini.glyph {
                    Image(nsImage: gl.image).resizable().renderingMode(gl.template ? .template : .original)
                        .aspectRatio(contentMode: .fit).frame(width: 15 * s, height: 15 * s)
                }
                Text(UsagePool.gemini.title).font(InterfaceFont.swiftUIFont(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(summaryRows) { row in UsageRowView(row: row) }
            VStack(alignment: .leading, spacing: 7 * s) {
                Text(L("帳號明細（\(accountCount) 個帳號）"))
                    .font(InterfaceFont.swiftUIFont(size: 11.5 * s, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(m.magpieAccounts) { account in
                    let rows = agyAccountRows(account, summaryRows: summaryRows)
                    if !rows.isEmpty {
                        agyAccountRow(account, rows: rows)
                    }
                }
            }
            let claudeAgyRows = m.rows(.claudeAgy)
            if !claudeAgyRows.isEmpty {
                ClaudeAgyUsageSection(rows: claudeAgyRows, topPadding: 2)
            }
            if let agy2Status = m.agy2Status {
                agy2Section(agy2Status)
            }
        }
        .padding(12 * s)
        .frame(width: Self.cardWidth * s, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private func loginExpiryColor(_ level: ClaudeLoginExpiry.Level) -> Color {
        switch level {
        case .normal: return .secondary
        case .warning: return .yellow
        case .expired: return .red
        }
    }

    @ViewBuilder
    private func agy2Section(_ status: Agy2QuotaStatus) -> some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            Divider().opacity(0.25)
            Text(L("agy2（第二個帳號）"))
                .font(InterfaceFont.swiftUIFont(size: 11.5 * s, weight: .semibold))
                .foregroundStyle(.secondary)
            switch status {
            case .down:
                Text(L("agy2 未啟動"))
                    .font(InterfaceFont.swiftUIFont(size: 11 * s))
                    .foregroundStyle(.tertiary)
            case .unreadable:
                Text(L("agy2 讀不到"))
                    .font(InterfaceFont.swiftUIFont(size: 11 * s))
                    .foregroundStyle(.secondary)
            case .available(let buckets):
                ForEach(buckets) { bucket in
                    UsageRowView(row: UsageRow(pool: .gemini, label: bucket.label, bucket: bucket))
                }
            }
        }
        .padding(.top, 2 * s)
    }

    private func agyAccountRow(_ account: MagpieAccountQuota, rows: [UsageRow]) -> some View {
        let short = ["Gemini 5 小時": "5h", "Gemini 每週": "週", "Argon 每週": "Argon", "agy Claude 每週": "Claude"]
        let cells = ["Gemini 5 小時", "Gemini 每週", "Argon 每週", "agy Claude 每週"]
        let resets = rows.compactMap { row in
            row.bucket.resetAt.map { "\(row.label)：\(UsageMonitor.refillText($0))" }
        }.joined(separator: "\n")
        return HStack(spacing: 7 * s) {
            Text(account.maskedName).font(InterfaceFont.swiftUIFont(size: 9.5 * s, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 3)
            ForEach(cells, id: \.self) { label in
                let b = rows.first { $0.bucket.label == label }?.bucket
                VStack(spacing: 0) {
                    Text(b.map { "\($0.remaining)%" } ?? "—")
                        .font(InterfaceFont.swiftUIFont(size: 10 * s, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(b.map { UsageRowView.color($0.remaining) } ?? Color.secondary)
                    Text(short[label] ?? label).font(InterfaceFont.swiftUIFont(size: 8 * s)).foregroundStyle(.tertiary)
                }
                .frame(width: 36 * s)
            }
        }
        .frame(minHeight: 18 * s)
        .help(resets)
        .padding(.vertical, 2)
    }

    private func agyAccountRows(_ account: MagpieAccountQuota, summaryRows: [UsageRow]) -> [UsageRow] {
        summaryRows.compactMap { row in
            account.buckets[row.bucket.label].map {
                UsageRow(pool: .gemini, label: row.label, bucket: $0)
            }
        }
    }

    static func agyCardProbeLines(_ m: UsageMonitor) -> [String] {
        let summaryRows = m.rows(.gemini)
        let accounts = m.magpieAccounts.filter { account in
            summaryRows.contains { account.buckets[$0.bucket.label] != nil }
        }
        var lines = ["card=Gemini（agy）", "accounts=\(accounts.count)"]
        for row in summaryRows {
            lines.append("summary=\(row.bucket.label) remaining=\(row.bucket.remaining)% reset=\(row.bucket.resets)")
        }
        for account in accounts {
            let rows = summaryRows.compactMap { summary -> UsageRow? in
                account.buckets[summary.bucket.label].map {
                    UsageRow(pool: .gemini, label: summary.label, bucket: $0)
                }
            }
            guard !rows.isEmpty else { continue }
            lines.append("account=\(account.maskedName)")
            for row in rows {
                lines.append("window account=\(account.maskedName) name=\(row.bucket.label) remaining=\(row.bucket.remaining)% reset=\(row.bucket.resets)")
            }
        }
        return lines
    }

    private func codexAccountsCard() -> some View {
        let paidAccounts = m.codexAccounts.filter { !$0.plan.lowercased().contains("free") }
        let freeAccounts = UsageMonitor.codexFreeAccounts(m.codexAccounts)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let gl = UsagePool.codex.glyph {
                    Image(nsImage: gl.image).resizable().renderingMode(gl.template ? .template : .original)
                        .aspectRatio(contentMode: .fit).frame(width: 15 * s, height: 15 * s)
                }
                Text(UsagePool.codex.title).font(InterfaceFont.swiftUIFont(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 10 * s) {
                ForEach(paidAccounts) { account in codexPaidAccount(account) }
            }
            .background(cardFrame("codex:paid"))
            if !freeAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 5 * s) {
                    Text(L("免費額度池（\(freeAccounts.count) 個帳號）"))
                        .font(InterfaceFont.swiftUIFont(size: 11.5 * s, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(freeAccounts) { account in codexFreeAccount(account) }
                }
                .background(cardFrame("codex:free"))
            }
        }
        .padding(12 * s)
        .frame(width: Self.cardWidth * s, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private func codexPaidAccount(_ account: CodexUsageAccountQuota) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(account.displayPlan).font(InterfaceFont.swiftUIFont(size: 12 * s, weight: .semibold))
                if account.active {
                    Text(L("目前登入")).font(InterfaceFont.swiftUIFont(size: 9.5 * s, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5 * s).padding(.vertical, 2 * s)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                Spacer(minLength: 4)
                Text(account.maskedUser).font(InterfaceFont.swiftUIFont(size: 10 * s, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            ForEach(account.buckets) { bucket in
                UsageRowView(row: UsageRow(pool: .codex, label: bucket.label, bucket: bucket))
            }
            if account.resetCredits > 0 {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("另有 \(account.resetCredits) 次免費全部重置"))
                            .font(InterfaceFont.swiftUIFont(size: 10.5 * s)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        if !account.resetExpiries.isEmpty {
                            Text(L("過期：") + account.resetExpiries.map { UsageMonitor.when($0) }.joined(separator: L("、")))
                                .font(InterfaceFont.swiftUIFont(size: 9.5 * s)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        if account.active, let status = m.codexResetStatus {
                            Text(status).font(InterfaceFont.swiftUIFont(size: 10 * s)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 3)
                    if account.active {
                        Button(action: { m.requestCodexReset() }) {
                            Text(m.codexResetBusy ? L("重置中…") : L("重置")).font(InterfaceFont.swiftUIFont(size: 10.5 * s))
                                .padding(.horizontal, 8 * s).padding(.vertical, 2 * s)
                                .overlay(Capsule().stroke(Color.primary.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(m.codexResetBusy)
                        .help(L("用掉 1 次免費全部重置（會先問你）"))
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func codexFreeAccount(_ account: CodexUsageAccountQuota) -> some View {
        let quota = UsageMonitor.codexFreeQuotaBucket(account)
        let remaining = quota?.remaining ?? 0
        let resetText = UsageMonitor.codexFreeResetText(account)
        let expiringHint = UsageMonitor.codexFreeExpiringSoonHint(account)
        return VStack(alignment: .leading, spacing: 2 * s) {
            HStack(alignment: .top, spacing: 7 * s) {
                WrappingFlowLayout(spacing: 7 * s, lineSpacing: 2 * s) {
                    Text(UsageMonitor.codexFreeAccountLabel(account))
                        .font(InterfaceFont.swiftUIFont(size: 9.5 * s, weight: account.alias == nil ? .regular : .medium,
                                      design: account.alias == nil ? .monospaced : .default))
                        .foregroundStyle(account.alias == nil ? .secondary : .primary)
                    if account.alias != nil {
                        Text(account.maskedUser).font(InterfaceFont.swiftUIFont(size: 8.5 * s, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    if account.active {
                        Text(L("目前登入")).font(InterfaceFont.swiftUIFont(size: 8.5 * s, weight: .medium)).foregroundStyle(.tertiary)
                    }
                    if let resetText {
                        Text(resetText).font(InterfaceFont.swiftUIFont(size: 8.5 * s)).foregroundStyle(UsageHighlightColor.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7 * s) {
                    Text(quota.map { "\($0.remaining)%" } ?? "—")
                        .font(InterfaceFont.swiftUIFont(size: 10 * s, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(UsageRowView.color(remaining))
                        .fixedSize()
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(UsageRowView.color(remaining))
                                .frame(width: geometry.size.width * CGFloat(remaining) / 100)
                        }
                    }
                    .frame(width: 58 * s, height: 4 * s)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if let expiringHint {
                Text(expiringHint)
                    .font(InterfaceFont.swiftUIFont(size: 8.5 * s))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 18 * s)
        .help(quota?.resets.isEmpty == false ? L("30 天額度，\(quota!.resets) 重置") : L("30 天額度"))
        .background(cardFrame("codex:free-row:\(account.id)"))
    }

    private func extraCard(_ p: ExtraKeyPool) -> some View {
        ExtraKeyPoolCard(pool: p)
    }
}

/// 窄寬度或長名稱時自動換行的橫向流式排版，避免截斷名稱、遮罩信箱或重置日期。
private struct WrappingFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(maxWidth: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func layout(maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let limit = maxWidth.isFinite ? max(1, maxWidth) : CGFloat.greatestFiniteMagnitude
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let natural = subview.sizeThatFits(ProposedViewSize(width: nil, height: nil))
            let constrained = natural.width > limit
                ? subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                : natural
            let itemWidth = min(limit, constrained.width)
            let itemHeight = constrained.height

            if x > 0 && x + itemWidth > limit {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: itemHeight))
            usedWidth = max(usedWidth, x + itemWidth)
            lineHeight = max(lineHeight, itemHeight)
            x += itemWidth + spacing
        }
        let totalHeight = frames.isEmpty ? 0 : y + lineHeight
        return (frames, CGSize(width: usedWidth, height: totalHeight))
    }
}

/// 共用的免費池卡片，完整頁與右欄使用相同文字與按鈕。
struct ExtraKeyPoolCard: View {
    @Environment(\.uiScale) private var s
    let pool: ExtraKeyPool
    var compact = false
    var now: () -> Date = Date.init

    static func kaggleExpiringHints(for pool: ExtraKeyPool, now: Date) -> [String] {
        guard pool.name == "Kaggle", !pool.kaggleQuotas.isEmpty else { return [] }
        let multiple = pool.kaggleQuotas.count > 1
        return pool.kaggleQuotas.compactMap { row in
            guard row.total.isFinite, row.total > 0, row.remaining.isFinite, row.remaining >= 0 else { return nil }
            let rounded = row.remaining.rounded()
            let remValue: String
            if abs(row.remaining - rounded) < 0.005 {
                remValue = abs(rounded) < 1e15 ? "\(Int(rounded))" : String(format: "%.0f", rounded)
            } else {
                remValue = String(format: "%.2f", row.remaining)
            }
            return UsageMonitor.expiringSoonHint(
                poolName: multiple ? "Kaggle \(row.resource)" : "Kaggle",
                remainingFraction: row.remaining / row.total,
                resetAt: row.refreshAt,
                cycleDays: UsageMonitor.poolCycleDays["Kaggle"],
                now: now,
                remainingText: L("\(remValue) 小時")
            )
        }
    }

    /// 卡片標題之外所有實際顯示的文字行（供 `--usage-panel-dump` 與畫面一致）。
    static func displayLines(for pool: ExtraKeyPool, now: Date = Date()) -> [String] {
        var lines: [String] = []
        if let message = pool.message {
            lines.append(LV(message))
        } else if pool.buckets.isEmpty && pool.notes.isEmpty {
            lines.append(L("剩餘額度查不到；本機資料尚未提供。"))
        }
        for bucket in pool.buckets {
            lines.append("\(bucket.label) \(bucket.remaining)%")
            if !bucket.resets.isEmpty {
                if bucket.resets.hasSuffix("回補") {
                    lines.append(bucket.resets)
                } else {
                    lines.append(L("\(bucket.resets) 重置"))
                }
            }
        }
        for note in pool.notes {
            lines.append(LV(note))
        }
        lines.append(contentsOf: kaggleExpiringHints(for: pool, now: now))
        if let title = pool.actionTitle, let rawURL = pool.actionURL, URL(string: rawURL) != nil {
            lines.append(title)
        }
        lines.append(LV(pool.source))
        return lines
    }

    private func kaggleExpiringHints() -> [String] {
        Self.kaggleExpiringHints(for: pool, now: now())
    }

    var body: some View {
        let titleSize = (compact ? 11.0 : 13.0) * s
        let bodySize = (compact ? 9.5 : 10.5) * s
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(pool.name).font(InterfaceFont.swiftUIFont(size: titleSize, weight: .semibold)).foregroundStyle(.secondary)
            if let message = pool.message {
                Text(LV(message)).font(InterfaceFont.swiftUIFont(size: bodySize)).foregroundStyle(.orange)
            } else if pool.buckets.isEmpty && pool.notes.isEmpty {
                Text(L("剩餘額度查不到；本機資料尚未提供。"))
                    .font(InterfaceFont.swiftUIFont(size: bodySize)).foregroundStyle(.tertiary)
            }
            ForEach(Array(pool.buckets.enumerated()), id: \.offset) { _, bucket in
                UsageRowView(row: UsageRow(pool: .local, label: bucket.label, bucket: bucket))
            }
            ForEach(pool.notes, id: \.self) {
                Text(UsageNoteStyling.attributedText(for: LV($0)))
                    .font(InterfaceFont.swiftUIFont(size: bodySize))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(kaggleExpiringHints().enumerated()), id: \.offset) { _, hint in
                Text(hint).font(InterfaceFont.swiftUIFont(size: bodySize)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let title = pool.actionTitle, let rawURL = pool.actionURL, let url = URL(string: rawURL) {
                Button(title) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link).font(InterfaceFont.swiftUIFont(size: bodySize))
            }
            Text(LV(pool.source)).font(InterfaceFont.swiftUIFont(size: bodySize)).foregroundStyle(.tertiary)
        }
        .padding((compact ? 0 : 12) * s)
        .frame(width: compact ? nil : UsageFullPage.cardWidth * s, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(compact ? 0 : 0.05)))
    }
}

/// C142 測試畫面：以完整卡片元件渲染免費池，供原生 probe 截圖與 OCR 驗收。
struct UsagePoolCardsProbeView: View {
    let pools: [ExtraKeyPool]
    let columns: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("免費池用量卡").font(InterfaceFont.swiftUIFont(size: 16, weight: .semibold))
            UsageMasonryLayout(cardWidth: UsageFullPage.cardWidth, gap: UsageFullPage.gap) {
                ForEach(pools) { pool in ExtraKeyPoolCard(pool: pool) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(UsageFullPage.pad)
        .frame(width: UsageFullPage.width(columns: columns, scale: 1), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
        .environment(\.colorScheme, .dark)
    }
}

/// 非 key 浮動面板也能在首次點擊直接接收拖曳與點擊，不需先點一下取得焦點。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 僅屬於 F12 用量面板的 `uiScale` 狀態，避免改動全域 `UIScale.shared`。
private final class UsagePanelScaleState: ObservableObject {
    @Published var scale: CGFloat
    init(scale: CGFloat) { self.scale = scale }
}

private struct UsagePanelScaledRoot: View {
    @ObservedObject var scaleState: UsagePanelScaleState
    @ObservedObject var dragState: UsageCardDragState
    let onLayout: (CGSize, [String: CGRect]) -> Void

    var body: some View {
        UsageFullPage(
            m: .shared,
            cardOrderStore: .shared,
            dragState: dragState,
            onLayout: onLayout
        )
        .environment(\.uiScale, scaleState.scale)
    }
}

/// 完整用量頁的浮動視窗：置中在主視窗上，點外面或按 Esc 關掉；再點一次「用量剩餘」也會關
enum UsageSheet {
    struct GeometrySnapshot: Equatable {
        let columns: Int
        let panelScale: CGFloat
        let panelWidth: CGFloat
        let originX: CGFloat
        let originY: CGFloat
        let visibleFrame: CGRect

        var layout: UsagePanelGeometry.Layout {
            UsagePanelGeometry.Layout(
                columns: columns,
                panelScale: panelScale,
                panelWidth: panelWidth,
                originX: originX,
                originY: originY
            )
        }
    }

    private static weak var panel: FloatingPanel?
    private static weak var parentWindow: NSWindow?
    private static var closedAt = Date.distantPast
    private static weak var focusWindow: NSWindow?
    private static weak var focusResponder: NSResponder?
    private static var focusApp: NSRunningApplication?
    private static var shouldRestoreExternalApp = false
    private static var actionSequence: UInt64 = 0
    private static var isClosing = false
    private static var parentWindowObservers: [NSObjectProtocol] = []
    private static var escCancelMonitor: Any?
    private static var scaleState: UsagePanelScaleState?
    private static var dragState: UsageCardDragState?
    private static var currentGeometry: GeometrySnapshot?
    private static var lastMeasuredGridSize: CGSize = .zero
    private static var hasMeasuredCurrentLayout = false
    private static var pendingTestMoves: [UsagePanelMoveSpec] = []
    private static var pendingTestMovesCompleted = false
    private static var dumpWorkItem: DispatchWorkItem?
    static var layoutObserver: ((CGSize, [String: CGRect]) -> Void)?

    /// 測試與正式共用：解析父視窗的實際可見區（測試實例帶 `--usage-panel-screen` 時吃模擬可見區）。
    static func resolveVisibleFrame(for window: NSWindow, config: UsagePanelDumpConfig = .current()) -> CGRect {
        let override: CGRect?
        if config.isTestInstance, let spec = config.screenSpec {
            let baseOrigin = TestScreen.screen?.frame.origin ?? .zero
            override = spec.visibleFrame(baseOrigin: baseOrigin)
        } else {
            override = nil
        }
        return UsagePanelGeometry.visibleFrame(for: window, override: override)
    }

    /// 測試與正式共用：計算本面板採用的基準 `uiScale`（測試實例帶 `--usage-panel-ui-scale` 時覆寫）。
    static func effectiveUIScale(config: UsagePanelDumpConfig = .current(), fallback: CGFloat = UIScale.shared.f) -> CGFloat {
        if config.isTestInstance, let override = config.uiScaleOverride {
            return override
        }
        return fallback
    }

    /// 判斷是否已滿足寫出 `--usage-panel-dump` 的全部條件（版面尚未量測完成或移動未完成時絕不寫檔，不得猜值）。
    static func isDumpReady(
        config: UsagePanelDumpConfig,
        panelVisible: Bool,
        extraLoaded: Bool,
        extraRefreshInFlight: Bool,
        geometry: GeometrySnapshot?,
        hasMeasuredLayout: Bool,
        measuredGridSize: CGSize,
        pendingMovesCount: Int,
        pendingMovesCompleted: Bool
    ) -> Bool {
        guard config.isTestInstance, config.dumpURL != nil else { return false }
        guard panelVisible, extraLoaded, !extraRefreshInFlight else { return false }
        guard pendingMovesCount == 0 || pendingMovesCompleted else { return false }
        guard geometry != nil, hasMeasuredLayout, measuredGridSize.width > 0 else { return false }
        return true
    }

    static func toggle(preservingFocus: Bool = false, in sourceWindow: NSWindow? = nil,
                       allowImmediateReopen: Bool = false, triggerExtraRefreshIfStale: Bool = true) {
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

        UsageCardOrderStore.shared.reload()
        let config = UsagePanelDumpConfig.current()
        let visibleFrame = resolveVisibleFrame(for: win, config: config)
        let uiScale = effectiveUIScale(config: config)
        var initialParentFrame = win.frame
        if config.isTestInstance, let forcedSize = config.parentSize {
            initialParentFrame.size = forcedSize
        }
        let provisional = UsagePanelGeometry.layout(
            parentFrame: initialParentFrame,
            visibleFrame: visibleFrame,
            uiScale: uiScale
        )
        let height = measurePanelHeight(
            columns: provisional.columns,
            panelScale: provisional.panelScale,
            parentFrame: initialParentFrame,
            visibleFrame: visibleFrame
        )
        let layout = UsagePanelGeometry.layout(
            parentFrame: initialParentFrame,
            visibleFrame: visibleFrame,
            uiScale: uiScale,
            panelHeight: height
        )

        let nextScaleState = UsagePanelScaleState(scale: layout.panelScale)
        let nextDragState = UsageCardDragState()
        scaleState = nextScaleState
        dragState = nextDragState
        currentGeometry = GeometrySnapshot(
            columns: layout.columns,
            panelScale: layout.panelScale,
            panelWidth: layout.panelWidth,
            originX: layout.originX,
            originY: layout.originY,
            visibleFrame: visibleFrame
        )
        lastMeasuredGridSize = .zero
        hasMeasuredCurrentLayout = false
        pendingTestMoves = config.isTestInstance ? config.moves : []
        pendingTestMovesCompleted = pendingTestMoves.isEmpty
        parentWindow = win

        let host = FirstMouseHostingView(rootView: UsagePanelScaledRoot(
            scaleState: nextScaleState,
            dragState: nextDragState,
            onLayout: { size, frames in
                if size.width > 0 {
                    lastMeasuredGridSize = size
                    hasMeasuredCurrentLayout = true
                }
                layoutObserver?(size, frames)
                schedulePanelDumpIfNeeded()
            }
        ))
        host.sizingOptions = []

        // 拖曳進行中按 Esc 優先取消拖曳並吃掉按鍵；未拖曳時放行給 FloatingPanel 正常關閉。
        if let escCancelMonitor { NSEvent.removeMonitor(escCancelMonitor) }
        escCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak nextDragState] event in
            if event.keyCode == 53, let nextDragState, nextDragState.isDragging {
                nextDragState.cancelCurrentDrag()
                return nil
            }
            return event
        }

        let p = FloatingPanel(content: host, resizable: true)
        p.becomesKeyOnlyIfNeeded = true
        if config.isTestInstance && TestScreen.screen == nil && TestScreen.hiddenRequested {
            p.alphaValue = 0
            p.ignoresMouseEvents = true
        }
        p.minSize = NSSize(
            width: UsagePanelGeometry.panelWidth(columns: 1, scale: layout.panelScale),
            height: 180 * layout.panelScale
        )
        p.maxSize = NSSize(
            width: UsagePanelGeometry.panelWidth(columns: 4, scale: layout.panelScale),
            height: max(height, visibleFrame.height)
        )
        p.onClose = { [weak p] in
            guard actionSequence == sequence, panel === p else { return }
            dragState?.cancelCurrentDrag()
            dragState = nil
            scaleState = nil
            panel = nil
            parentWindow = nil
            currentGeometry = nil
            lastMeasuredGridSize = .zero
            hasMeasuredCurrentLayout = false
            pendingTestMoves = []
            pendingTestMovesCompleted = false
            dumpWorkItem?.cancel()
            dumpWorkItem = nil
            for observer in parentWindowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            parentWindowObservers = []
            if let escCancelMonitor {
                NSEvent.removeMonitor(escCancelMonitor)
                self.escCancelMonitor = nil
            }
            isClosing = false
            closedAt = Date()
            if preservingFocus { restoreFocus(panelWasKey: p?.wasKeyBeforeClose == true) }
            clearFocusTarget()
        }
        p.setFrame(
            NSRect(x: layout.originX, y: layout.originY, width: layout.panelWidth, height: height),
            display: true
        )
        win.addChildWindow(p, ordered: .above)

        let geometryEvents: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didChangeScreenNotification,
        ]
        parentWindowObservers = geometryEvents.map { name in
            NotificationCenter.default.addObserver(forName: name, object: win, queue: .main) { [weak p, weak win, weak nextScaleState] _ in
                guard let p, let win, let nextScaleState, p.isVisible else { return }
                recalculatePanelGeometry(panel: p, parent: win, scaleState: nextScaleState, config: config)
            }
        }

        if preservingFocus { p.orderFront(nil) }
        else { p.makeKeyAndOrderFront(nil) }
        panel = p
        isClosing = false
        if triggerExtraRefreshIfStale {
            UsageMonitor.shared.refreshExtraPoolsIfStale()
        }
        schedulePanelDumpIfNeeded()
    }

    /// 用「實際欄數的寬度」與 `panelScale` 量測內容高度，避免 4 欄時底部多出空白。
    private static func measurePanelHeight(
        columns: Int,
        panelScale: CGFloat,
        parentFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGFloat {
        let measureWidth = UsageFullPage.width(columns: columns, scale: panelScale)
        let natural = NSHostingView(
            rootView: UsageFullPage(
                m: .shared,
                cardOrderStore: .shared,
                dragState: .inactive,
                scroll: false,
                isDragEnabled: false,
                fixedWidth: measureWidth
            )
            .environment(\.uiScale, panelScale)
        ).fittingSize
        let minHeight = 180 * panelScale
        let capHeight = min(visibleFrame.height, max(minHeight, parentFrame.height * 0.85))
        return min(max(natural.height, minHeight), capHeight)
    }

    /// 父視窗 `didResize`、`didMove`、`didChangeScreen` 共用的單一幾何重算函式。
    private static func recalculatePanelGeometry(
        panel p: FloatingPanel,
        parent win: NSWindow,
        scaleState: UsagePanelScaleState,
        config: UsagePanelDumpConfig
    ) {
        guard p.isVisible else { return }
        let visibleFrame = resolveVisibleFrame(for: win, config: config)
        let uiScale = effectiveUIScale(config: config)
        let parentFrame = win.frame
        let previous = currentGeometry
        let provisional = UsagePanelGeometry.layout(
            parentFrame: parentFrame,
            visibleFrame: visibleFrame,
            uiScale: uiScale,
            panelHeight: p.frame.height
        )
        let columnsOrScaleChanged = previous == nil
            || previous?.columns != provisional.columns
            || abs((previous?.panelScale ?? 0) - provisional.panelScale) > UsagePanelGeometry.remeasureScaleTolerance
        let nextHeight: CGFloat
        if columnsOrScaleChanged {
            nextHeight = measurePanelHeight(
                columns: provisional.columns,
                panelScale: provisional.panelScale,
                parentFrame: parentFrame,
                visibleFrame: visibleFrame
            )
        } else {
            let minHeight = 180 * provisional.panelScale
            nextHeight = min(max(p.frame.height, minHeight), visibleFrame.height)
        }
        let nextLayout = UsagePanelGeometry.layout(
            parentFrame: parentFrame,
            visibleFrame: visibleFrame,
            uiScale: uiScale,
            panelHeight: nextHeight
        )
        let needsRemeasure = UsagePanelGeometry.needsRemeasure(
            previous: previous?.layout,
            next: nextLayout
        )
        if abs(scaleState.scale - nextLayout.panelScale) > UsagePanelGeometry.remeasureScaleTolerance {
            scaleState.scale = nextLayout.panelScale
        }
        p.minSize = NSSize(
            width: UsagePanelGeometry.panelWidth(columns: 1, scale: nextLayout.panelScale),
            height: 180 * nextLayout.panelScale
        )
        p.maxSize = NSSize(
            width: UsagePanelGeometry.panelWidth(columns: 4, scale: nextLayout.panelScale),
            height: max(nextHeight, visibleFrame.height)
        )
        currentGeometry = GeometrySnapshot(
            columns: nextLayout.columns,
            panelScale: scaleState.scale,
            panelWidth: nextLayout.panelWidth,
            originX: nextLayout.originX,
            originY: nextLayout.originY,
            visibleFrame: visibleFrame
        )
        if needsRemeasure {
            hasMeasuredCurrentLayout = false
        }
        p.setFrame(
            NSRect(x: nextLayout.originX, y: nextLayout.originY, width: nextLayout.panelWidth, height: nextHeight),
            display: true
        )
        schedulePanelDumpIfNeeded()
    }

    /// 與拖曳手勢共用同一個 `UsageCardOrderStore.moveCard` 入口，供 `--usage-panel-move` 依序移動並存檔。
    @discardableResult
    static func moveCard(
        sourceKey: String,
        target: UsageCardOrder.DropTarget,
        monitor: UsageMonitor = .shared,
        orderStore: UsageCardOrderStore = .shared
    ) -> Bool {
        let visibleKeys = UsageFullPage.orderedItems(
            for: monitor,
            onlyPool: nil,
            savedOrder: orderStore.savedOrder
        ).map(\.key)
        return orderStore.moveCard(sourceKey: sourceKey, target: target, visibleKeys: visibleKeys)
    }

    @discardableResult
    static func moveCard(
        from sourceKey: String,
        to targetKey: String,
        after: Bool = false,
        monitor: UsageMonitor = .shared,
        orderStore: UsageCardOrderStore = .shared
    ) -> Bool {
        let target: UsageCardOrder.DropTarget = targetKey.isEmpty ? .end : (after ? .after(targetKey) : .before(targetKey))
        return moveCard(sourceKey: sourceKey, target: target, monitor: monitor, orderStore: orderStore)
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
        toggle(preservingFocus: true, in: window, allowImmediateReopen: true, triggerExtraRefreshIfStale: false)
        if !wasOpen, panel?.isVisible == true {
            if !UsageMonitor.shared.loading {
                UsageMonitor.shared.refresh(includeExtraKeys: false)
            }
            UsageMonitor.shared.refreshExtraPoolsIfStale()
            schedulePanelDumpIfNeeded()
        }
    }

    /// 測試實例帶 `--usage-panel-dump <檔>` 或 `--usage-panel-move` 時，合併於下一個主佇列週期檢查並處理。
    static func schedulePanelDumpIfNeeded(config: UsagePanelDumpConfig = UsagePanelDumpConfig.current()) {
        guard config.isTestInstance,
              config.dumpURL != nil || (!pendingTestMoves.isEmpty && !pendingTestMovesCompleted) else { return }
        guard let p = panel, p.isVisible else { return }
        let monitor = UsageMonitor.shared
        guard monitor.extraLoadedAt != nil, !monitor.isExtraRefreshInFlight else { return }
        dumpWorkItem?.cancel()
        let work = DispatchWorkItem {
            dumpWorkItem = nil
            writePanelDumpIfReady(config: config)
        }
        dumpWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private static func runPendingTestMovesIfReady(config: UsagePanelDumpConfig) -> Bool {
        guard config.isTestInstance, !pendingTestMoves.isEmpty, !pendingTestMovesCompleted else { return false }
        guard let p = panel, p.isVisible else { return false }
        let monitor = UsageMonitor.shared
        guard monitor.extraLoadedAt != nil, !monitor.isExtraRefreshInFlight else { return false }
        guard hasMeasuredCurrentLayout, lastMeasuredGridSize.width > 0 else { return false }

        let visibleKeys = UsageFullPage.orderedItems(
            for: monitor,
            onlyPool: nil,
            savedOrder: UsageCardOrderStore.shared.savedOrder
        ).map(\.key)
        let allTargetsVisible = pendingTestMoves.allSatisfy {
            visibleKeys.contains($0.sourceKey) && ($0.targetKey.isEmpty || visibleKeys.contains($0.targetKey))
        }
        // 等所有要移的卡都出現，或主查詢已結束（避免不存在的 key 卡死）
        guard allTargetsVisible || !monitor.loading else { return false }

        let orderBefore = visibleKeys
        for spec in pendingTestMoves {
            _ = moveCard(sourceKey: spec.sourceKey, target: spec.dropTarget, monitor: monitor, orderStore: .shared)
        }
        pendingTestMovesCompleted = true
        let orderAfter = UsageFullPage.orderedItems(
            for: monitor,
            onlyPool: nil,
            savedOrder: UsageCardOrderStore.shared.savedOrder
        ).map(\.key)
        if orderAfter != orderBefore {
            hasMeasuredCurrentLayout = false
            p.contentView?.layoutSubtreeIfNeeded()
            return true
        }
        return false
    }

    static func writePanelDumpIfReady(config: UsagePanelDumpConfig = UsagePanelDumpConfig.current()) {
        guard config.isTestInstance else { return }
        guard let p = panel, p.isVisible else { return }
        let monitor = UsageMonitor.shared
        guard monitor.extraLoadedAt != nil, !monitor.isExtraRefreshInFlight else { return }

        p.contentView?.layoutSubtreeIfNeeded()

        // 若有待執行的 `--usage-panel-move`：先執行移動；若順序有變，等下一輪 `onLayout` 回來再寫 dump。
        if runPendingTestMovesIfReady(config: config) {
            return
        }

        guard let dumpURL = config.dumpURL,
              isDumpReady(
                config: config,
                panelVisible: p.isVisible,
                extraLoaded: monitor.extraLoadedAt != nil,
                extraRefreshInFlight: monitor.isExtraRefreshInFlight,
                geometry: currentGeometry,
                hasMeasuredLayout: hasMeasuredCurrentLayout,
                measuredGridSize: lastMeasuredGridSize,
                pendingMovesCount: pendingTestMoves.count,
                pendingMovesCompleted: pendingTestMovesCompleted
              ),
              let geometry = currentGeometry else {
            return
        }

        let scale = geometry.panelScale
        let columns = UsageMasonryLayout.columnCount(
            width: lastMeasuredGridSize.width,
            cardWidth: UsageFullPage.cardWidth * scale,
            gap: UsageFullPage.gap * scale
        )
        let payload = monitor.buildUsagePanelDumpPayload(
            panelFrame: p.frame,
            screenVisibleFrame: geometry.visibleFrame,
            columns: columns,
            panelScale: scale,
            savedOrder: UsageCardOrderStore.shared.savedOrder
        )
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: dumpURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: dumpURL, options: .atomic)
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
    var short: String? = nil  // 輸入框下面那條上行的小字（week／5h／argon）
}

struct UsageGlanceGroup {
    let key: String
    let name: String
    let symbol: String        // SF Symbols（不用各家商標圖檔）
    let items: [UsageGlanceItem]
    var footer: String? = nil
    var accountLabel: String? = nil
    var statusText: String? = nil
    var othersText: String? = nil

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

    /// 單一來源的底列摘要文字（`UsageMonitor.glance` 與 `--usage-card-dump` 的 `glanceText` 共用）。
    var summaryText: String {
        let body: String
        if let accountLabel {
            if let statusText {
                body = "\(accountLabel)：\(statusText)"
            } else {
                body = "\(accountLabel)：\(plain)"
            }
        } else {
            body = statusText ?? plain
        }
        if let othersText {
            return "\(body)｜\(othersText)"
        }
        return body
    }

    /// 滑過的說明：每個數字是什麼、多久後重置
    var tip: String {
        let lines = items.map { it in
            guard let b = it.bucket else { return it.what + L("：查不到") }
            var t = it.what + L("：剩 \(b.remaining)%")
            if let c = SidebarFooter.countdown(b.resets) { t += L("，\(c) 後重置（\(b.resets)）") }
            else if !b.resets.isEmpty { t += L("，\(b.resets) 重置") }
            if let detail = it.detail { t += "\n" + detail }
            return t
        }.joined(separator: "\n")
        if let footer, !footer.isEmpty {
            return lines + "\n" + footer
        }
        return lines
    }
}

extension UsageMonitor {
    /// Claude 一定列；Codex、agy 有裝（或已經有資料）才列。
    /// 輸入框下面那條（UsageGlanceStrip）每組都是「每週、5 小時」，agy 再多 Argon；agy 的 Claude 總池只留在用量大卡片，不放這裡（11/10）。
    var glance: [UsageGlanceGroup] {
        let five = L("5 小時"), week = L("每週")
        var out = [UsageGlanceGroup(key: "cc", name: "Claude", symbol: "asterisk",
                                    items: Self.standardGlanceItems("Claude", buckets: buckets, week: week, five: five))]
        if CodexBridge.installed || !codexBuckets.isEmpty || !codexAccounts.isEmpty {
            out.append(UsageGlanceGroup(key: "codex", name: "Codex", symbol: "hexagon",
                                        items: Self.codexGlanceItems(accounts: codexAccounts, fallback: codexBuckets)))
        }
        if AgyBridge.enabled || !agyBuckets.isEmpty || usesSwapAccountDisplay {
            out.append(agyGlanceGroup())
        }
        return out
    }
}
