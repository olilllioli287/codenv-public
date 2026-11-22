import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps

// 「闔蓋做完這一段」：闔上螢幕時若有聊天室正在做事，讓 Mac 先不睡（Battery 的 root 小幫手 v6 的 nosleep
// 連線一斷就自動改回正常），請它們做完目前這一段就停；全部停下、撐滿 1 小時、電量低於 30%、溫度過高就解除。
// 邏輯和硬體分開：LidEnv 可以換成假的（測試用 --lid-sim），不會真的闔蓋或動 pmset。

enum NoSleepResult: Equatable { case ok, unsupported, failed(String) }

/// 系統最近一次睡眠／醒來的內核時間證據；用來分辨真的睡過還是主執行緒卡頓。
struct LidSleepEvidence: Equatable {
    var wakeTime: TimeInterval
    var sleepTime: TimeInterval
}

struct LidInterruptPendingMessages {
    var messages: [LidQueuedMessage] = []
    var outboxReadFailed = false
}

struct LidInterruptWork {
    let id: UUID
    let title: String
    let engine: String
    /// 本版會終止 Claude／Codex／Copilot／agy 的聊天室模型程序。
    let supportsTermination: Bool
    /// 聊天室自己執行的 ! shell 也要停止；本機模型仍不會因此 terminate。
    let hasBangCommand: Bool
    let details: [String]
    var foreground: Bool = true

    var requiresTermination: Bool { supportsTermination || hasBangCommand }
}

struct LidInterruption: Codable, Equatable {
    let id: UUID
    let title: String
    let engine: String
    let supportsTermination: Bool
    var details: [String]
    var queuedMessages: [LidQueuedMessage]
    var terminated: Bool
    var forceKilled: Bool
    var stillRunning: Bool
    var outboxReadFailed: Bool
    var foreground: Bool = true
    /// 救援檔寫入失敗，僅留在記憶體與原寄件匣，尚未持久化落盤。
    var unpersisted: Bool = false

    static func mergeQueuedMessages(_ existing: [LidQueuedMessage], _ incoming: [LidQueuedMessage]) -> [LidQueuedMessage] {
        var result: [LidQueuedMessage] = []
        var indexByID: [String: Int] = [:]
        func append(_ message: LidQueuedMessage) {
            guard !message.text.isEmpty else { return }
            let key = message.id.lowercased()
            if !key.isEmpty {
                if let index = indexByID[key] {
                    if result[index].text.isEmpty { result[index].text = message.text }
                    return
                }
                indexByID[key] = result.count
            }
            result.append(LidQueuedMessage(id: key.isEmpty ? message.id : key, text: message.text))
        }
        existing.forEach(append)
        incoming.forEach(append)
        return result
    }

    func merged(with next: LidInterruption, keepStillRunningOr: Bool = false) -> LidInterruption {
        var copy = self
        copy.details += next.details.filter { !copy.details.contains($0) }
        copy.queuedMessages = Self.mergeQueuedMessages(copy.queuedMessages, next.queuedMessages)
        copy.terminated = copy.terminated || next.terminated
        copy.forceKilled = copy.forceKilled || next.forceKilled
        copy.stillRunning = keepStillRunningOr ? (copy.stillRunning || next.stillRunning) : next.stillRunning
        copy.outboxReadFailed = copy.outboxReadFailed || next.outboxReadFailed
        copy.foreground = copy.foreground || next.foreground
        copy.unpersisted = copy.unpersisted || next.unpersisted
        return copy
    }
}

struct LidInterruptionNoticeRoute {
    let recipient: UUID
    let rows: [LidInterruption]
    let isSummary: Bool
}

enum LidInterruptionNoticeRouter {
    static func routes(_ records: [LidInterruption], commanderFor: (UUID) -> UUID?, recipientAvailable: (UUID) -> Bool) -> [LidInterruptionNoticeRoute] {
        var summaries: [UUID: [LidInterruption]] = [:]
        var individual: [LidInterruptionNoticeRoute] = []
        for record in records {
            let chief = commanderFor(record.id)
            if let chief, chief != record.id, recipientAvailable(chief) {
                summaries[chief, default: []].append(record)
            } else if recipientAvailable(record.id) {
                individual.append(LidInterruptionNoticeRoute(recipient: record.id, rows: [record], isSummary: false))
            }
        }
        individual += summaries.map { LidInterruptionNoticeRoute(recipient: $0.key, rows: $0.value, isSummary: true) }
        return individual.sorted { $0.recipient.uuidString < $1.recipient.uuidString }
    }
}

extension LidInterruption {
    static func noticeText(_ rows: [LidInterruption], late: Bool) -> String {
        let intro = late
            ? "闔蓋時來不及完成中斷，工作可能被睡眠凍結。以下是當時的聊天室狀態："
            : "使用者闔蓋時，codenv 已結束以下聊天室的模型程序："
        var lines = [intro]
        for row in rows {
            let action: String
            if late && !row.supportsTermination { action = "這版不會主動停止，工作可能被睡眠凍結" }
            else if row.forceKilled && row.stillRunning { action = "已送 SIGKILL，但程序群組仍未確認結束" }
            else if row.forceKilled { action = "已用 SIGKILL 結束程序群組" }
            else if late && row.stillRunning { action = "程序未能確認結束，工作可能被睡眠凍結" }
            else if !row.supportsTermination { action = "這版不會主動停止" }
            else if row.stillRunning { action = "仍有程序未能結束" }
            else if late && row.terminated { action = "已送出程序終止訊號" }
            else if row.terminated { action = "已送出程序結束訊號" }
            else { action = "聊天室程序不可用，未能主動停止" }
            lines.append("• \(row.title)（\(row.engine)）：\(action)")
            for detail in row.details { lines.append("  執行項目：\(detail)") }
            if row.outboxReadFailed { lines.append("  寄件匣讀取失敗，未列出可能未送出的訊息") }
            if !row.queuedMessages.isEmpty {
                lines.append("  沒送出的排隊訊息原文：")
                lines += row.queuedMessages.map { "  \($0.text)" }
            }
        }
        lines.append("這版不會主動停止本機模型、看板 agy-runs 與脫離聊天室程序群組的背景程序；它們可能在闔蓋期間被睡眠凍結。")
        lines.append("請先確認做到哪裡、有沒有改到一半的檔案或殘留的鎖（例如 .git/index.lock），再決定要不要繼續；會寫入正式資料、commit、出版的步驟不要直接重跑，先回報。")
        return lines.joined(separator: "\n")
    }

    static let continuePrompt = "使用者打開螢幕回來了。請先確認你剛才做到哪裡再繼續；commit、出版、寫入正式資料的步驟，先回報給我、不要直接重跑。"
    static let commanderSummaryHeader = "使用者開蓋回來了，下列成員聊天室在闔蓋時被中斷；由你決定要不要重派、commit／出版／寫正式資料的步驟先回報不要直接重跑："

    private static func appendQueuedDetails(for row: LidInterruption, indent: String, to lines: inout [String]) {
        if row.outboxReadFailed {
            lines.append("\(indent)寄件匣讀取失敗，可能有沒送出的訊息。")
        }
        if !row.queuedMessages.isEmpty {
            lines.append("\(indent)沒送出的排隊訊息原文：")
            lines += row.queuedMessages.map { "\(indent)\($0.text)" }
            if row.queuedMessages.contains(where: { $0.text.contains("（含圖片附件）") }) {
                lines.append("\(indent)（註：排隊訊息包含圖片附件，請確認是否需要重新附上圖片）")
            }
        }
    }

    static func continueMessage(for row: LidInterruption) -> String {
        var lines = [continuePrompt]
        appendQueuedDetails(for: row, indent: "", to: &lines)
        return lines.joined(separator: "\n")
    }

    static func commanderContinueMessage(selfRecord: LidInterruption?, members: [LidInterruption]) -> String {
        var lines: [String] = []
        if let selfRecord {
            lines.append(continueMessage(for: selfRecord))
        }
        if !members.isEmpty {
            if selfRecord != nil {
                lines.append("")
                lines.append("下列成員聊天室在闔蓋時也被中斷；由你決定要不要重派、commit／出版／寫正式資料的步驟先回報不要直接重跑：")
            } else {
                lines.append(commanderSummaryHeader)
            }
            for member in members {
                lines.append("• \(member.title)（\(member.engine)）")
                for detail in member.details { lines.append("  執行項目：\(detail)") }
                appendQueuedDetails(for: member, indent: "  ", to: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension LidInterruption {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        engine = try c.decode(String.self, forKey: .engine)
        supportsTermination = try c.decode(Bool.self, forKey: .supportsTermination)
        details = try c.decodeIfPresent([String].self, forKey: .details) ?? []
        if c.contains(.queuedMessages) {
            if let typed = try? c.decode([LidQueuedMessage].self, forKey: .queuedMessages) {
                queuedMessages = typed
            } else if let legacy = try? c.decode([String].self, forKey: .queuedMessages) {
                queuedMessages = legacy.enumerated().map { LidQueuedMessage(id: "legacy-\($0.offset)", text: $0.element) }
            } else {
                throw DecodingError.dataCorruptedError(forKey: .queuedMessages, in: c, debugDescription: "Invalid queuedMessages")
            }
        } else {
            queuedMessages = []
        }
        terminated = try c.decodeIfPresent(Bool.self, forKey: .terminated) ?? false
        forceKilled = try c.decodeIfPresent(Bool.self, forKey: .forceKilled) ?? false
        stillRunning = try c.decodeIfPresent(Bool.self, forKey: .stillRunning) ?? false
        outboxReadFailed = try c.decodeIfPresent(Bool.self, forKey: .outboxReadFailed) ?? false
        foreground = try c.decodeIfPresent(Bool.self, forKey: .foreground) ?? true
        unpersisted = try c.decodeIfPresent(Bool.self, forKey: .unpersisted) ?? false
    }
}

struct LidRescueEntry: Codable, Equatable {
    var record: LidInterruption
    var late: Bool
    var updatedAt: Date
    var attempts: Int = 0
    var reminded: Bool?

    var isReminded: Bool { reminded == true }

    init(record: LidInterruption, late: Bool, updatedAt: Date, attempts: Int = 0, reminded: Bool? = nil) {
        self.record = record
        self.late = late
        self.updatedAt = updatedAt
        self.attempts = attempts
        self.reminded = reminded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        record = try c.decode(LidInterruption.self, forKey: .record)
        late = try c.decode(Bool.self, forKey: .late)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        attempts = max(0, try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0)
        reminded = try c.decodeIfPresent(Bool.self, forKey: .reminded)
    }
}

enum LidRescueLoadResult: Equatable {
    case empty
    case loaded([LidRescueEntry])
    case readFailed
}

/// 闔蓋中斷被移出寄件匣後的排隊訊息保全：在送出成功前落盤保存，避免 App 結束、設定關閉或送訊失敗時遺失。
final class LidInterruptRescuePersistence {
    enum QuarantineOutcome: Equatable {
        case moved(URL)
        case moveFailed(URL)
    }

    private struct Payload: Codable {
        var version: Int = 1
        var updatedAt: Date
        var entries: [LidRescueEntry]
    }

    let fileURL: URL
    private var quarantinedOutcomes: [QuarantineOutcome] = []
    private var upsertResetIDs: Set<UUID> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func consumeQuarantineOutcomes() -> [QuarantineOutcome] {
        let outcomes = quarantinedOutcomes
        quarantinedOutcomes.removeAll()
        return outcomes
    }

    fileprivate func consumeUpsertResetIDs() -> Set<UUID> {
        let ids = upsertResetIDs
        upsertResetIDs.removeAll()
        return ids
    }

    fileprivate static func hasNewQueuedMessages(from existing: [LidQueuedMessage], to merged: [LidQueuedMessage]) -> Bool {
        var existingIDs: Set<String> = []
        for message in existing where !message.text.isEmpty {
            let key = message.id.lowercased()
            if !key.isEmpty {
                existingIDs.insert(key)
            }
        }
        for message in merged where !message.text.isEmpty {
            let key = message.id.lowercased()
            if !key.isEmpty && !existingIDs.contains(key) {
                return true
            }
        }
        return false
    }

    func loadResult(log: ((String) -> Void)? = nil) -> LidRescueLoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        } catch {
            log?("讀取闔蓋中斷救援檔失敗，保留原檔：\(error.localizedDescription)")
            return .readFailed
        }
        guard !data.isEmpty else { return .empty }
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(Payload.self, from: data) {
            return payload.entries.isEmpty ? .empty : .loaded(payload.entries)
        }
        if let entries = try? decoder.decode([LidRescueEntry].self, from: data) {
            return entries.isEmpty ? .empty : .loaded(entries)
        }
        quarantine(log: log)
        return .empty
    }

    func loadSafe(log: ((String) -> Void)? = nil) -> [LidRescueEntry] {
        switch loadResult(log: log) {
        case .loaded(let entries): return entries
        case .empty, .readFailed: return []
        }
    }

    @discardableResult
    func upsert(_ records: [LidInterruption], late: Bool, now: Date = Date(), log: ((String) -> Void)? = nil) -> Bool {
        guard !records.isEmpty else { return true }
        var entries: [LidRescueEntry]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let readEntries = readExistingForMutation(log: log) else { return false }
            entries = readEntries
        } else {
            entries = []
        }
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.record.id, $0) })
        var newlyResetIDs: Set<UUID> = []
        for var record in records {
            record.unpersisted = false
            if var old = byID[record.id] {
                var merged = old.record.merged(with: record)
                merged.unpersisted = false
                let hasNewMessages = Self.hasNewQueuedMessages(from: old.record.queuedMessages, to: merged.queuedMessages)
                old.record = merged
                old.late = old.late || late
                old.updatedAt = now
                if hasNewMessages {
                    old.attempts = 0
                    old.reminded = false
                    newlyResetIDs.insert(record.id)
                }
                byID[record.id] = old
            } else {
                byID[record.id] = LidRescueEntry(record: record, late: late, updatedAt: now)
                newlyResetIDs.insert(record.id)
            }
        }
        let next = byID.values.sorted { $0.record.id.uuidString < $1.record.id.uuidString }
        let ok = write(next, now: now, log: log)
        if ok {
            upsertResetIDs.formUnion(newlyResetIDs)
        }
        return ok
    }

    fileprivate static func applyDelivered(_ deliveredRecords: [LidInterruption],
                                           to entry: inout LidRescueEntry,
                                           at now: Date) -> (changed: Bool, shouldRemove: Bool) {
        var deliveredNonEmptyIDs: Set<String> = []
        // mergeQueuedMessages 對空 id 不去重，單輪多次 upsert 會累積相同副本；以集合依文字全數扣除而非一對一消耗。
        var deliveredEmptyIDTexts: Set<String> = []
        var deliveredOutboxReadFailed = false
        for record in deliveredRecords {
            if record.outboxReadFailed { deliveredOutboxReadFailed = true }
            for message in record.queuedMessages {
                let key = message.id.lowercased()
                if !key.isEmpty {
                    deliveredNonEmptyIDs.insert(key)
                } else {
                    deliveredEmptyIDTexts.insert(message.text)
                }
            }
        }
        var remainingMessages: [LidQueuedMessage] = []
        var removedAnyMessage = false
        for message in entry.record.queuedMessages {
            let key = message.id.lowercased()
            if !key.isEmpty {
                if deliveredNonEmptyIDs.contains(key) {
                    removedAnyMessage = true
                    continue
                }
            } else if deliveredEmptyIDTexts.contains(message.text) {
                removedAnyMessage = true
                continue
            }
            remainingMessages.append(message)
        }
        let clearedOutboxReadFailed = entry.record.outboxReadFailed && deliveredOutboxReadFailed
        if removedAnyMessage {
            entry.record.queuedMessages = remainingMessages
        }
        if clearedOutboxReadFailed {
            entry.record.outboxReadFailed = false
        }
        let shouldRemove = entry.record.queuedMessages.isEmpty && !entry.record.outboxReadFailed
        let changed = removedAnyMessage || clearedOutboxReadFailed
        if changed && !shouldRemove {
            entry.updatedAt = now
        }
        return (changed, shouldRemove)
    }

    @discardableResult
    func remove(ids: Set<UUID>, deliveredRecords: [LidInterruption]? = nil, now: Date = Date(), log: ((String) -> Void)? = nil) -> Bool {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        guard let existing = readExistingForMutation(log: log) else { return false }
        let deliveredByID = deliveredRecords.map { Dictionary(grouping: $0, by: \.id) }
        var remaining: [LidRescueEntry] = []
        remaining.reserveCapacity(existing.count)
        var modified = false
        for var entry in existing {
            guard ids.contains(entry.record.id) else {
                remaining.append(entry)
                continue
            }
            guard let deliveredByID else {
                modified = true
                continue
            }
            let deliveredForEntry = deliveredByID[entry.record.id] ?? []
            let outcome = Self.applyDelivered(deliveredForEntry, to: &entry, at: now)
            if outcome.shouldRemove {
                modified = true
                continue
            }
            if outcome.changed {
                modified = true
            }
            remaining.append(entry)
        }
        guard modified else { return true }
        return write(remaining, now: now, log: log)
    }

    /// 啟動補送前先將對應記錄的嘗試次數 +1 持久化；若讀寫失敗（含損壞隔離）回傳 false，呼叫端不得自動送出。
    @discardableResult
    func incrementAttempts(for ids: Set<UUID>, now: Date = Date(), log: ((String) -> Void)? = nil) -> Bool {
        guard !ids.isEmpty else { return true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            log?("闔蓋中斷救援檔不存在，無法寫入嘗試次數")
            return false
        }
        guard var entries = readExistingForMutation(log: log) else { return false }
        var matched = false
        for i in entries.indices where ids.contains(entries[i].record.id) {
            entries[i].attempts += 1
            entries[i].updatedAt = now
            matched = true
        }
        guard matched else { return false }
        return write(entries, now: now, log: log)
    }

    /// 提醒實際排入顯示後，將對應記錄標記為已提醒並寫回救援檔；若讀寫失敗（含損壞隔離）回傳 false，呼叫端應保留記憶體去重。
    @discardableResult
    func markReminded(for ids: Set<UUID>, now: Date = Date(), log: ((String) -> Void)? = nil) -> Bool {
        guard !ids.isEmpty else { return true }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            log?("闔蓋中斷救援檔不存在，無法寫入已提醒狀態")
            return false
        }
        guard var entries = readExistingForMutation(log: log) else { return false }
        var matched = false
        var changed = false
        for i in entries.indices where ids.contains(entries[i].record.id) {
            matched = true
            if entries[i].reminded != true {
                entries[i].reminded = true
                entries[i].updatedAt = now
                changed = true
            }
        }
        guard matched else { return false }
        guard changed else { return true }
        return write(entries, now: now, log: log)
    }

    private func readExistingForMutation(log: ((String) -> Void)? = nil) -> [LidRescueEntry]? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            log?("讀取闔蓋中斷救援檔失敗，為保安全不覆蓋原檔：\(error.localizedDescription)")
            return nil
        }
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(Payload.self, from: data) {
            return payload.entries
        }
        if let entries = try? decoder.decode([LidRescueEntry].self, from: data) {
            return entries
        }
        quarantine(log: log)
        return []
    }

    private func quarantine(log: ((String) -> Void)? = nil) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let tag = f.string(from: Date()) + "-" + UUID().uuidString.prefix(6)
        let bad = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".bad-" + tag)
        do {
            try FileManager.default.moveItem(at: fileURL, to: bad)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bad.path)
            } catch {
                log?("設定隔離救援檔權限 0600 失敗（\(bad.lastPathComponent)）：\(error.localizedDescription)")
            }
            log?("闔蓋中斷救援檔損壞，已備份隔離至 \(bad.lastPathComponent)")
            quarantinedOutcomes.append(.moved(bad))
        } catch {
            log?("闔蓋中斷救援檔損壞且隔離失敗：\(error.localizedDescription)")
            quarantinedOutcomes.append(.moveFailed(fileURL))
        }
    }

    private func write(_ entries: [LidRescueEntry], now: Date, log: ((String) -> Void)? = nil) -> Bool {
        do {
            if entries.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return true
            }
            let data = try JSONEncoder().encode(Payload(version: 1, updatedAt: now, entries: entries))
            try Self.atomicWrite(data, to: fileURL)
            return true
        } catch {
            log?("寫入闔蓋中斷救援檔失敗：\(error.localizedDescription)")
            return false
        }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        let result = temporary.path.withCString { source in url.path.withCString { destination in rename(source, destination) } }
        if result != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

protocol LidEnv: AnyObject {
    func lidClosed() -> Bool
    /// 有沒有外接螢幕在線上（接著外接螢幕闔蓋是合蓋模式，Mac 本來就不睡，不算「闔蓋」：）
    func externalDisplayOnline() -> Bool
    func battery() -> (percent: Int, onAC: Bool)?
    func maxTemperature() -> Double?
    /// IOKit HIDIdleTime；取不到時回 nil，採 fail closed（不主動睡）
    func hidIdleTime() -> TimeInterval?
    func setNoSleep(_ on: Bool) -> NoSleepResult
    func setFanAuto() -> Bool
    /// 蓋子還闔著時解除後要主動讓 Mac 睡：闔蓋睡眠只在「闔上那一刻」觸發，事後把 disablesleep 改回 0 不會補睡（實測）
    func sleepNow()
    /// 小幫手那邊 nosleep 現在是不是開著：true／false；連不上、不支援回 nil
    func noSleepStatus() -> Bool?
    /// 系統睡過的證據（kern.waketime 與 kern.sleeptime）；讀不到回 nil
    func sleepEvidence() -> LidSleepEvidence?
    /// 不含系統睡眠時間的單調時鐘（秒，macOS 上對應 CLOCK_UPTIME_RAW）
    func systemUptime() -> TimeInterval
    /// 含系統睡眠時間的單調時鐘（秒，macOS 上對應 CLOCK_MONOTONIC_RAW）
    func continuousTime() -> TimeInterval
    /// 是否有遠端連線（SSH／螢幕共享／遠端管理）處於 ESTABLISHED；查詢失敗或逾時視為 false（fail-safe 照上限睡眠）
    func remoteSessionActive() -> Bool
}

extension LidEnv {
    func systemUptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func continuousTime() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }
    func remoteSessionActive() -> Bool { false }
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
        var uptimeSleepGap: TimeInterval = 1      // 兩個單調時鐘的差超過這麼多秒＝期間系統睡過；兩個時鐘本來就只在睡眠時分開，門檻只用來吸收量測抖動
        var externalDropDelay: TimeInterval = 4   // 外接螢幕斷線要持續這麼久才算斷（HDMI 重新協商、換輸入源會掉 1～2 秒）
        var externalIdleSleepSeconds: TimeInterval = 600
        var awakeClosedMax: TimeInterval = 1800   // 闔蓋中斷後保持醒著最久 30 分鐘（單調時鐘）
        var awakeClosedMinBattery = 20            // awakeClosed 期間沒插電且低於 20% 立刻睡
        var sleepRetryInterval: TimeInterval = 20 // sleepNow 發出後若蓋子仍闔著且系統仍醒著，隔多久重發一次
        var sleepRetryMaxAttempts = 3             // sleepNow 最多重發次數（含外接螢幕 clamshell 保底停止）
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
    /// 主動中斷模式的聊天室工作；本機模型也回傳，但 supportsTermination=false。
    var interruptWork: () -> [LidInterruptWork] = { [] }
    var pendingMessagesForInterrupt: (UUID) -> LidInterruptPendingMessages = { _ in LidInterruptPendingMessages() }
    var terminateForInterrupt: (UUID, Set<String>) -> Bool = { _, _ in false }
    var isDraining: (UUID) -> Bool = { _ in false }
    var forceKillDraining: (UUID) -> Bool = { _ in false }
    var didForceKillForInterrupt: (UUID) -> Bool = { _ in false }
    var sendInterruptNotices: ([LidInterruption], Bool) -> Void = { _, _ in }
    var sendInterruptResume: ([LidInterruption]) -> Void = { _ in }
    var interruptOnCloseEnabled: () -> Bool = { false }
    /// 正在撐住睡眠的回合與背景子程序（只用於紀錄）。
    var workDescriptions: () -> [String] = { [] }
    var sendStop: (UUID) -> Bool = { _ in false }
    /// 螢幕打開後恢復先前實際收到 stop 的聊天室。
    var resumeEnabled: () -> Bool = { true }
    var externalIdleSleepEnabled: () -> Bool = { true }
    var sendResume: (UUID) -> Void = { _ in }
    var sessionIsAvailable: (UUID) -> Bool = { _ in false }
    var sessionIsArchived: (UUID) -> Bool = { _ in true }
    var resumeDelay: TimeInterval = 3
    /// 規格 07-24：同一聊天室 5 秒內不重複送「回到螢幕」通知（接線層另有同文字去重；這裡是 keeper 自己的保險）
    var resumeDedupeWindow: TimeInterval = 5
    private var lastResumeSentAt: [UUID: Date] = [:]
    private var lastStopSentAt: [UUID: Date] = [:]
    /// 超過去重視窗的紀錄沒有用了（聊天室銷毀也不會留著）；每次要送通知前清一次
    private func pruneNoticeTimes(_ t: Date) {
        lastResumeSentAt = lastResumeSentAt.filter { t.timeIntervalSince($0.value) < resumeDedupeWindow }
        lastStopSentAt = lastStopSentAt.filter { t.timeIntervalSince($0.value) < resumeDedupeWindow }
    }
    /// 打開螢幕後只有出事才提醒：標題、內文
    var notify: (String, String) -> Void = { _, _ in }
    var canPresentNotify: () -> Bool = { true }
    let logURL: URL
    let markerURL: URL
    let rescueURL: URL?
    private lazy var rescuePersistence: LidInterruptRescuePersistence? = rescueURL.map { LidInterruptRescuePersistence(fileURL: $0) }
    static let maxRescueStartupAttempts = 3
    var rescueRetryInterval: TimeInterval = 15
    var rescueMaxRetries = 5
    var onRescueRetryTick: (([LidRescueEntry]) -> Void)?
    private var pendingRescueRetryAt: Date?
    private var rescueRetryCount = 0
    private var inRescueRetryTick = false
    private var retryScheduledInCurrentTick = false
    private enum RescueNotificationReason: Hashable {
        case exhausted
        case writeFailed
        case corrupted
    }

    private enum RescueNotificationKey: Hashable {
        case record(UUID, RescueNotificationReason)
        case file(String, RescueNotificationReason)
    }

    private struct PendingRescueNotification {
        let title: String
        let detail: String
        var rescueEntryIDs: Set<UUID>
    }
    private var deliveredInProcessIDs: Set<UUID> = []
    private var deliveredInProcessRecords: [UUID: [LidInterruption]] = [:]
    private var remindedInProcessIDs: Set<UUID> = []
    private var unpersistedRescueEntries: [UUID: LidRescueEntry] = [:]
    private var deliveryReportedInCurrentResolution = false
    private var pendingRescueNotifications: [PendingRescueNotification] = []
    private var queuedRescueNotificationKeys: Set<RescueNotificationKey> = []
    var hasPendingRescueRetry: Bool { pendingRescueRetryAt != nil }
    var hasPendingRescueNotifications: Bool { !pendingRescueNotifications.isEmpty }
    private var sleepRetryLastIssuedAt: TimeInterval?
    private var sleepRetryAttempts = 0
    private var sleepRetryGaveUp = false

    private(set) var holdingSince: Date?
    private var lastLog = Date.distantPast
    private var hotSince: Date?
    private var maxTempSeen: Double?
    private var windowMaxTemp: Double?      // 自上一行每分鐘紀錄以來的最高溫（每次檢查都取樣，尖峰才看得到）
    // 只代表實體蓋子感測器。外接螢幕上線會切換處理模式，但不能偽裝成使用者打開蓋子。
    private var wasLidShut = false
    private var handledThisClosure = false     // 這次闔蓋已經處理過（撐過、或 helper 不支援）：不重複，也不再撐第二輪
    private var pending: (reason: String, detail: String)?
    var isHolding: Bool { holdingSince != nil }

    init(env: LidEnv, logURL: URL, markerURL: URL, rescueURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.env = env
        self.logURL = logURL
        self.markerURL = markerURL
        self.rescueURL = rescueURL
        self.now = now
        // 一建立就取啟動基準，避免首次 tick 前睡過沒有前值可比。
        self.lastContinuousTime = env.continuousTime()
        self.lastUptime = env.systemUptime()
        self.lastSleepEvidence = env.sleepEvidence()
        if let real = env as? RealLidEnv {
            real.onRemoteError = { [weak self] message in
                if Thread.isMainThread { self?.log(message) }
                else { DispatchQueue.main.async { self?.log(message) } }
            }
        }
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
        cancelInterruptNotice()
        if !interruptRecords.isEmpty && !interruptNotified {
            let records = Array(interruptRecords.values)
            let late = awakeClosedEndedBySleep || sleptDuringClosure
            if !persistRescueWithMemoryFallback(records, late: late, at: now()) {
                log("codenv 結束前救援檔寫入失敗，保留記憶體中斷記錄（未持久化）")
            }
        }
        resetSleepRetry()
        awakeClosedSince = nil
        awakeClosedHotSince = nil
        remoteSessionPaused = false
        suspendedAwakeClosedSince = nil
        if isHolding { endHold(reason: "codenv 結束", problem: false, keepNoSleep: false) }
        if noSleepOn { turnOff(); log("結束預擋：codenv 結束") }
    }

    private func shouldPersistForRescue(_ record: LidInterruption) -> Bool {
        record.supportsTermination || record.terminated || !record.queuedMessages.isEmpty || record.outboxReadFailed
    }

    private func enqueueRecordRescueNotification(
        title: String,
        detail: String,
        reason: RescueNotificationReason,
        rescueEntryIDs: Set<UUID>
    ) {
        guard !rescueEntryIDs.isEmpty else { return }
        let newIDs = rescueEntryIDs.filter { queuedRescueNotificationKeys.insert(.record($0, reason)).inserted }
        guard !newIDs.isEmpty else { return }
        if let index = pendingRescueNotifications.firstIndex(where: { $0.title == title && $0.detail == detail }) {
            pendingRescueNotifications[index].rescueEntryIDs.formUnion(newIDs)
            return
        }
        pendingRescueNotifications.append(
            PendingRescueNotification(title: title, detail: detail, rescueEntryIDs: newIDs)
        )
    }

    private func enqueueFileRescueNotification(
        title: String,
        detail: String,
        fileName: String,
        reason: RescueNotificationReason
    ) {
        let key = RescueNotificationKey.file(fileName, reason)
        guard queuedRescueNotificationKeys.insert(key).inserted else { return }
        if let index = pendingRescueNotifications.firstIndex(where: { $0.title == title && $0.detail == detail }) {
            return
        }
        pendingRescueNotifications.append(
            PendingRescueNotification(title: title, detail: detail, rescueEntryIDs: [])
        )
    }

    private func clearInProcessReminderState(for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        remindedInProcessIDs.subtract(ids)
        for id in ids {
            queuedRescueNotificationKeys.remove(.record(id, .exhausted))
            queuedRescueNotificationKeys.remove(.record(id, .writeFailed))
            queuedRescueNotificationKeys.remove(.record(id, .corrupted))
        }
        for index in pendingRescueNotifications.indices.reversed() {
            guard !pendingRescueNotifications[index].rescueEntryIDs.isEmpty else { continue }
            pendingRescueNotifications[index].rescueEntryIDs.subtract(ids)
            if pendingRescueNotifications[index].rescueEntryIDs.isEmpty {
                pendingRescueNotifications.remove(at: index)
            }
        }
    }

    private func markRescueEntriesReminded(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        remindedInProcessIDs.formUnion(ids)
        for id in ids {
            if var entry = unpersistedRescueEntries[id] {
                entry.reminded = true
                unpersistedRescueEntries[id] = entry
            }
        }
        guard let rescuePersistence else { return }
        let ok = rescuePersistence.markReminded(for: ids, now: now(), log: { [weak self] in self?.log($0) })
        let quarantined = collectQuarantineNotifications()
        if !ok && !quarantined {
            log("寫入闔蓋中斷救援檔已提醒狀態失敗，同進程內不再重複提醒（\(ids.count) 筆）")
        }
    }

    @discardableResult
    private func collectQuarantineNotifications() -> Bool {
        guard let rescuePersistence else { return false }
        let outcomes = rescuePersistence.consumeQuarantineOutcomes()
        guard !outcomes.isEmpty else { return false }
        for outcome in outcomes {
            switch outcome {
            case .moved(let badURL):
                let fileName = rescuePersistence.fileURL.lastPathComponent
                enqueueFileRescueNotification(
                    title: "闔蓋中斷訊息暫存檔損壞",
                    detail: "被中斷時沒送出的訊息暫存檔損壞，已另存為 \(badURL.path)，請手動檢查",
                    fileName: fileName,
                    reason: .corrupted
                )
            case .moveFailed(let originalURL):
                enqueueFileRescueNotification(
                    title: "闔蓋中斷訊息暫存檔損壞",
                    detail: "被中斷時沒送出的訊息暫存檔損壞（\(originalURL.path)），且自動隔離失敗，請手動檢查",
                    fileName: originalURL.lastPathComponent,
                    reason: .corrupted
                )
            }
        }
        return true
    }

    @discardableResult
    private func persistRescue(_ records: [LidInterruption], late: Bool, at date: Date) -> Bool {
        let filtered = records.filter(shouldPersistForRescue)
        guard !filtered.isEmpty else { return true }
        let filteredIDs = filtered.map(\.id)
        deliveredInProcessIDs.subtract(filteredIDs)
        for id in filteredIDs {
            deliveredInProcessRecords.removeValue(forKey: id)
        }
        guard let rescuePersistence else { return true }
        let ok = rescuePersistence.upsert(filtered, late: late, now: date, log: { [weak self] in self?.log($0) })
        if ok {
            clearInProcessReminderState(for: rescuePersistence.consumeUpsertResetIDs())
        }
        collectQuarantineNotifications()
        return ok
    }

    @discardableResult
    private func persistRescueWithMemoryFallback(_ records: [LidInterruption], late: Bool, at date: Date) -> Bool {
        let filtered = records.filter(shouldPersistForRescue)
        guard !filtered.isEmpty else { return true }
        if persistRescue(filtered, late: late, at: date) {
            for record in filtered {
                unpersistedRescueEntries.removeValue(forKey: record.id)
                if var existing = interruptRecords[record.id] {
                    existing.unpersisted = false
                    interruptRecords[record.id] = existing
                }
            }
            return true
        }
        for var record in filtered {
            record.unpersisted = true
            if var existing = interruptRecords[record.id] {
                existing.unpersisted = true
                interruptRecords[record.id] = existing
            }
            if var old = unpersistedRescueEntries[record.id] {
                let merged = old.record.merged(with: record)
                let hasNewMessages = LidInterruptRescuePersistence.hasNewQueuedMessages(
                    from: old.record.queuedMessages,
                    to: merged.queuedMessages
                )
                old.record = merged
                old.record.unpersisted = true
                old.late = old.late || late
                old.updatedAt = date
                if hasNewMessages {
                    old.attempts = 0
                    old.reminded = false
                    clearInProcessReminderState(for: [record.id])
                }
                unpersistedRescueEntries[record.id] = old
            } else {
                unpersistedRescueEntries[record.id] = LidRescueEntry(record: record, late: late, updatedAt: date)
            }
        }
        log("闔蓋中斷救援檔寫入失敗，已標記為未持久化並保留於記憶體（\(filtered.count) 筆）")
        return false
    }

    private func flushUnpersistedRescueEntries(at date: Date) {
        guard !unpersistedRescueEntries.isEmpty else { return }
        let entries = Array(unpersistedRescueEntries.values)
        for isLate in [false, true] {
            let group = entries.filter { $0.late == isLate }.map(\.record)
            guard !group.isEmpty else { continue }
            if persistRescue(group, late: isLate, at: date) {
                for row in group {
                    unpersistedRescueEntries.removeValue(forKey: row.id)
                }
            }
        }
    }

    func pendingRescueStatus() -> (entries: [LidRescueEntry], readFailed: Bool) {
        let loadResult = rescuePersistence?.loadResult(log: { [weak self] in self?.log($0) }) ?? .empty
        collectQuarantineNotifications()
        let diskEntries: [LidRescueEntry]
        let readFailed: Bool
        switch loadResult {
        case .empty:
            diskEntries = []
            readFailed = false
        case .loaded(let entries):
            diskEntries = entries
            readFailed = false
        case .readFailed:
            diskEntries = []
            readFailed = true
        }
        var byID: [UUID: LidRescueEntry] = [:]
        var excludedDiskIDs: Set<UUID> = []
        var unremindedExhaustedIDs: Set<UUID> = []
        for var entry in diskEntries where !deliveredInProcessIDs.contains(entry.record.id) {
            if let inProcessDelivered = deliveredInProcessRecords[entry.record.id] {
                let outcome = LidInterruptRescuePersistence.applyDelivered(inProcessDelivered, to: &entry, at: entry.updatedAt)
                if outcome.shouldRemove {
                    continue
                }
            }
            if entry.isReminded || remindedInProcessIDs.contains(entry.record.id) {
                excludedDiskIDs.insert(entry.record.id)
                continue
            }
            if entry.attempts >= Self.maxRescueStartupAttempts {
                excludedDiskIDs.insert(entry.record.id)
                unremindedExhaustedIDs.insert(entry.record.id)
                continue
            }
            byID[entry.record.id] = entry
        }
        if !unremindedExhaustedIDs.isEmpty, let path = rescuePersistence?.fileURL.path {
            let detail = "有被中斷時沒送出的訊息暫存在 \(path)，已多次嘗試送達失敗，請手動檢查"
            let newIDs = unremindedExhaustedIDs.filter { !queuedRescueNotificationKeys.contains(.record($0, .exhausted)) }
            if !newIDs.isEmpty {
                log("闔蓋中斷救援檔中有 \(newIDs.count) 筆記錄已嘗試送達達上限（\(Self.maxRescueStartupAttempts) 次），不再自動補送：\(path)")
            }
            enqueueRecordRescueNotification(
                title: "闔蓋中斷訊息尚未送達",
                detail: detail,
                reason: .exhausted,
                rescueEntryIDs: unremindedExhaustedIDs
            )
        }
        for (id, entry) in unpersistedRescueEntries
        where !deliveredInProcessIDs.contains(id)
            && !excludedDiskIDs.contains(id)
            && !remindedInProcessIDs.contains(id)
            && !entry.isReminded {
            if var existing = byID[id] {
                existing.record = existing.record.merged(with: entry.record)
                existing.late = existing.late || entry.late
                existing.updatedAt = max(existing.updatedAt, entry.updatedAt)
                byID[id] = existing
            } else if entry.attempts < Self.maxRescueStartupAttempts {
                byID[id] = entry
            }
        }
        let sorted = byID.values.sorted { $0.record.id.uuidString < $1.record.id.uuidString }
        return (sorted, readFailed)
    }

    @discardableResult
    func prepareStartupRescueDelivery(for entries: [LidRescueEntry]) -> Bool {
        let eligible = entries.filter {
            $0.attempts < Self.maxRescueStartupAttempts && !$0.isReminded && !remindedInProcessIDs.contains($0.record.id)
        }
        guard !eligible.isEmpty else { return false }
        guard let rescuePersistence else { return true }
        let ids = Set(eligible.map(\.record.id))
        let ok = rescuePersistence.incrementAttempts(for: ids, now: now(), log: { [weak self] in self?.log($0) })
        let quarantined = collectQuarantineNotifications()
        if !ok {
            if quarantined {
                log("寫入闔蓋中斷救援檔嘗試次數前發現救援檔損壞並已隔離，停止本次自動補送")
            } else {
                let path = rescuePersistence.fileURL.path
                let detail = "有被中斷時沒送出的訊息暫存在 \(path)，已多次嘗試送達失敗，請手動檢查"
                let newIDs = ids.filter { !queuedRescueNotificationKeys.contains(.record($0, .writeFailed)) }
                if !newIDs.isEmpty {
                    log("寫入闔蓋中斷救援檔嘗試次數失敗，停止本次自動補送以避免重複送出：\(path)")
                }
                enqueueRecordRescueNotification(
                    title: "闔蓋中斷訊息尚未送達",
                    detail: detail,
                    reason: .writeFailed,
                    rescueEntryIDs: ids
                )
            }
            return false
        }
        return true
    }

    func pendingRescueEntries() -> [LidRescueEntry] {
        pendingRescueStatus().entries
    }

    func scheduleStartupReadFailureRetry() {
        guard pendingRescueRetryAt == nil, rescueRetryCount == 0 else { return }
        scheduleRescueRetry(at: now(), fromRetryTick: false, reason: "啟動讀取救援檔失敗")
    }

    private func rescueDelay(forAttempt attempt: Int) -> TimeInterval {
        rescueRetryInterval * pow(2.0, Double(max(0, attempt - 1)))
    }

    private func scheduleRescueRetry(at t: Date, fromRetryTick: Bool, reason: String, immediate: Bool = false) {
        if fromRetryTick {
            guard !retryScheduledInCurrentTick else { return }
            retryScheduledInCurrentTick = true
            if rescueRetryCount >= rescueMaxRetries {
                pendingRescueRetryAt = nil
                log("闔蓋中斷救援重試已達上限（\(rescueMaxRetries) 次），停止本次重試並保留救援檔，待下次啟動再補送（原因：\(reason)）")
                return
            }
            rescueRetryCount += 1
        } else {
            rescueRetryCount = 1
        }
        let delay: TimeInterval = immediate ? 0 : rescueDelay(forAttempt: rescueRetryCount)
        pendingRescueRetryAt = t.addingTimeInterval(delay)
        log("排程闔蓋中斷救援第 \(rescueRetryCount)/\(rescueMaxRetries) 次重試（\(Int(delay)) 秒後；原因：\(reason)）")
    }

    private func runRescueRetryDelivery(_ entries: [LidRescueEntry], at t: Date) {
        flushUnpersistedRescueEntries(at: t)
        inRescueRetryTick = true
        retryScheduledInCurrentTick = false
        defer {
            inRescueRetryTick = false
            retryScheduledInCurrentTick = false
        }
        onRescueRetryTick?(entries)
    }

    private func markRecordsDelivered(_ deliveredRecords: [LidInterruption]?,
                                      handledIDs: Set<UUID>,
                                      at date: Date,
                                      logOnRemoveFailure: Bool) {
        guard !handledIDs.isEmpty else { return }
        let deliveredByID = deliveredRecords.map { Dictionary(grouping: $0, by: \.id) }
        for id in handledIDs {
            guard let deliveredByID else {
                unpersistedRescueEntries.removeValue(forKey: id)
                continue
            }
            guard var entry = unpersistedRescueEntries[id] else { continue }
            let deliveredForID = deliveredByID[id] ?? []
            let outcome = LidInterruptRescuePersistence.applyDelivered(deliveredForID, to: &entry, at: date)
            if outcome.shouldRemove {
                unpersistedRescueEntries.removeValue(forKey: id)
            } else {
                unpersistedRescueEntries[id] = entry
            }
        }
        let removed = rescuePersistence?.remove(
            ids: handledIDs,
            deliveredRecords: deliveredRecords,
            now: date,
            log: { [weak self] in self?.log($0) }
        ) ?? true
        collectQuarantineNotifications()
        if !removed {
            if let deliveredByID {
                for id in handledIDs {
                    let deliveredForID = deliveredByID[id] ?? []
                    deliveredInProcessRecords[id, default: []].append(contentsOf: deliveredForID)
                }
            } else {
                deliveredInProcessIDs.formUnion(handledIDs)
            }
            if logOnRemoveFailure {
                log("闔蓋中斷通知已送達，但移除救援檔項目失敗；同進程內不再重複送出（\(handledIDs.count) 筆）")
            }
        }
    }

    func recordInterruptDelivery(handledIDs: Set<UUID>,
                                 failedRecords: [LidInterruption],
                                 late: Bool,
                                 handledRecords: [LidInterruption]? = nil) {
        deliveryReportedInCurrentResolution = true
        let t = now()
        let failedIDs = Set(failedRecords.map(\.id))
        let actuallyHandled = handledIDs.subtracting(failedIDs)
        if !actuallyHandled.isEmpty {
            let effectiveHandledRecords = handledRecords.map { records in
                records.filter { actuallyHandled.contains($0.id) }
            }
            markRecordsDelivered(effectiveHandledRecords, handledIDs: actuallyHandled, at: t, logOnRemoveFailure: true)
        }
        let persistFailed = failedRecords.filter(shouldPersistForRescue)
        if !persistFailed.isEmpty {
            _ = persistRescueWithMemoryFallback(persistFailed, late: late, at: t)
        }
        let status = pendingRescueStatus()
        if !status.entries.isEmpty || status.readFailed || (rescuePersistence == nil && !persistFailed.isEmpty) {
            let reason = status.readFailed ? "救援檔讀取失敗" : "救援通知仍有待送項目"
            scheduleRescueRetry(at: t, fromRetryTick: inRescueRetryTick, reason: reason)
        } else {
            pendingRescueRetryAt = nil
            rescueRetryCount = 0
        }
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
    private var lastContinuousTime: TimeInterval?
    private var lastUptime: TimeInterval?
    private var lastSleepEvidence: LidSleepEvidence?
    private var sleepEvidenceUnavailableLogged = false
    private var suppressedWakeGapLogged = false
    private var lastSuppressedWakeGapLog = Date.distantPast
    private var lastRetry = Date.distantPast
    private var retryFailLogged = false
    private(set) var stoppedSessionIDs: Set<UUID> = []
    private var resumeGeneration = 0
    private var externalIdleSleepPending = false
    private var externalIdleSleepTriggered = false
    private var interruptStartedAt: Date?
    private var interruptingIDs: Set<UUID> = []
    private var interruptRecords: [UUID: LidInterruption] = [:]
    private var interruptNotified = false
    private var interruptNoticeGeneration = 0
    private var interruptSleepIssued = false
    /// 開蓋通知建立時判斷本次是否完成中斷並睡眠；通知送出後清除，供下一個週期重新判斷。
    private var interruptCompletedAndSleepIssued = false
    private var interruptDeadlineHandled = false
    private var interruptCloseGeneration = 0
    private var activeInterruptCycleID = 0
    private var interruptRecordCycleID = 0
    private(set) var awakeClosedSince: TimeInterval?
    private var awakeClosedHotSince: TimeInterval?
    private var awakeClosedEndedBySleep = false
    private var sleptDuringClosure = false
    private var remoteSessionPaused = false
    private var pendingResumeAfterInterrupt = false
    private var pendingWakeGapOnDrain = false
    private var interruptOpenScheduled = false
    private var suspendedAwakeClosedSince: TimeInterval?
    private var suspendedAwakeClosedEndedBySleep = false
    private var suspendedSleptDuringClosure = false
    private var suspendedRemotePaused = false
    private var awakeClosedRetrying = false
    private var awakeClosedLastRetry = Date.distantPast
    private var awakeClosedRetryFailLogged = false
    var isInterrupting: Bool { interruptStartedAt != nil }
    var isAwakeClosed: Bool { awakeClosedSince != nil }
    var hasPendingInterruptNotice: Bool { !interruptRecords.isEmpty && !interruptNotified }

    private func turnOn(_ t: Date) -> NoSleepResult {
        if noSleepOn { return .ok }
        let r = env.setNoSleep(true)
        if r == .ok {
            noSleepOn = true; noSleepGen += 1; lastStatusCheck = t
            try? "{\"since\":\(Int(t.timeIntervalSince1970))}".write(to: markerURL, atomically: true, encoding: .utf8)
        }
        return r
    }

    /// --lid-sim 專用：透過正式 turnOn 路徑預先取得模擬預擋，供無工作情境驗證。
    func acquireSimulatedPreholdForProbe() {
        guard env is SimLidEnv else { return }
        _ = turnOn(now())
    }

    private func turnOff() {
        guard noSleepOn else { return }
        noSleepOn = false; noSleepGen += 1
        if case .failed(let why) = env.setNoSleep(false) { log("改回正常睡眠失敗：\(why)（小幫手會在連線中斷時自己改回）") }
        try? FileManager.default.removeItem(at: markerURL)
    }

    func tick() {
        let t = now()
        let currentContinuous = env.continuousTime()
        let currentUptime = env.systemUptime()
        let lidShut = env.lidClosed()
        let activeInterruptMode = enabled() && interruptOnCloseEnabled()
        let tickGap: TimeInterval?
        if let lastContinuousTime, currentContinuous.isFinite, lastContinuousTime.isFinite {
            tickGap = max(0, currentContinuous - lastContinuousTime)
        } else {
            tickGap = nil
        }
        let gapExceeded = tickGap.map { $0 > limits.wakeGap } ?? false
        let currentEvidence = env.sleepEvidence()
        let kernShowsSleep: Bool
        if let currentEvidence {
            kernShowsSleep = lastSleepEvidence.map { currentEvidence != $0 } ?? false
            lastSleepEvidence = currentEvidence
        } else {
            kernShowsSleep = false
            if !sleepEvidenceUnavailableLogged {
                sleepEvidenceUnavailableLogged = true
                log("無法讀取系統睡眠證據（kern.waketime／kern.sleeptime），改依含睡眠與不含睡眠單調時鐘差判斷是否睡過")
            }
        }
        let uptimeDelta: TimeInterval?
        if let lastUptime, currentUptime.isFinite, lastUptime.isFinite {
            uptimeDelta = max(0, currentUptime - lastUptime)
        } else {
            uptimeDelta = nil
        }
        let sleepSeconds: TimeInterval?
        if let tickGap, let uptimeDelta {
            sleepSeconds = max(0, tickGap - uptimeDelta)
        } else {
            sleepSeconds = nil
        }
        let uptimeShowsSleep = sleepSeconds.map { $0 > limits.uptimeSleepGap } ?? false
        let didSleep = kernShowsSleep || uptimeShowsSleep
        if !lidShut || didSleep {
            resetSleepRetry()
        }
        let wakeGap = gapExceeded && didSleep
        if didSleep, wasLidShut || lidShut || awakeClosedSince != nil || isInterrupting || suspendedAwakeClosedSince != nil {
            sleptDuringClosure = true
            if awakeClosedSince != nil {
                awakeClosedSince = nil
                awakeClosedHotSince = nil
                remoteSessionPaused = false
                if noSleepOn { turnOff() }
                log("awakeClosed 期間偵測到系統已睡眠（DarkWake／睡眠證據），結束 awakeClosed")
            }
        }
        if gapExceeded, !didSleep {
            if !suppressedWakeGapLogged {
                suppressedWakeGapLogged = true
                lastSuppressedWakeGapLog = t
                log("輪詢間隔 \(Int((tickGap ?? 0).rounded())) 秒但系統沒睡過（睡眠證據與單調時鐘皆未顯示睡眠），不當成醒來")
            }
        } else if wakeGap || (!gapExceeded && t.timeIntervalSince(lastSuppressedWakeGapLog) >= limits.logEvery) {
            suppressedWakeGapLogged = false
        }
        // 外接螢幕每次都取樣；消失要持續 externalDropDelay 秒才算斷（閃斷不能把聊天室叫停）
        // 睡眠期間不會取樣：醒來第一次檢查若外接螢幕還沒回來，不能立刻當成「闔蓋且無外接」叫停聊天室。
        // 睡之前是外接闔蓋狀態，就把「最後看到外接」更新成現在，等 externalDropDelay 再判
        if wakeGap, externalNoted, lidShut {
            lastExternalSeen = t
            log("剛從睡眠醒來，外接螢幕給 \(Int(limits.externalDropDelay)) 秒寬限")
        }
        if currentContinuous.isFinite { lastContinuousTime = currentContinuous }
        if currentUptime.isFinite { lastUptime = currentUptime }
        if env.externalDisplayOnline() { lastExternalSeen = t }
        let external = lidShut && (lastExternalSeen.map { t.timeIntervalSince($0) < limits.externalDropDelay } ?? false)
        if external != externalNoted {
            externalNoted = external
            hotSince = nil      // 外接模式和撐著共用溫度計時：換模式時清掉，不然殘留的過熱計時會讓下一次一開始就判過熱
            if external {
                externalSince = t; externalCapped = false
                // 外接螢幕切到 clamshell 處理模式，結束這次正式撐住；若顯示器稍後掉線且蓋子仍闔著，重新判斷是否要撐住。
                if isHolding, !activeInterruptMode { endHold(reason: "外接螢幕上線，改用外接螢幕模式", problem: false, keepNoSleep: true) }
                if !activeInterruptMode {
                    handledThisClosure = false
                    log("蓋子闔著但有外接螢幕在線上，當作沒闔蓋（不通知停止、不主動睡；撐著的上限、電量、溫度照樣管）")
                } else {
                    log("外接螢幕在線上；主動中斷模式仍依實體蓋子狀態處理闔蓋")
                }
            }
            else { externalSince = nil; externalCapped = false }
        }
        let closed = lidShut && !external
        let on = enabled()
        let working = workingCount()
        let batt = env.battery()
        let lowBattery = batt.map { !$0.onAC && $0.percent < limits.minBattery } ?? false

        // 小幫手可能被別人（別的 codenv 實例、手動 pmset）改回 0：擋著時定期確認，被解除就重新擋。
        // 確認和重擋都要連 socket（最多等 2 秒），放到背景做，結果回主執行緒套用
        if noSleepOn, !statusChecking, !awakeClosedRetrying, awakeClosedSince == nil, t.timeIntervalSince(lastStatusCheck) >= limits.statusEvery {
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
                            if self.env.lidClosed(), !self.externalNoted, !self.isHolding,
                               !self.interruptOnCloseEnabled(), !self.interruptSleepIssued {
                                self.log("蓋子還闔著，補送主動睡"); self.issueSleepNow()
                            }
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
        if lidShut {
            cancelPendingResume()
        }
        if !lidShut, wasLidShut {
            wasLidShut = false; handledThisClosure = false
            if isHolding { endHold(reason: "螢幕打開了", problem: false, keepNoSleep: true) }
            scheduleResume()
            let hadAwakeClosed = awakeClosedSince != nil
            if hadAwakeClosed || remoteSessionPaused {
                suspendedAwakeClosedSince = awakeClosedSince
                suspendedRemotePaused = remoteSessionPaused
                suspendedAwakeClosedEndedBySleep = awakeClosedEndedBySleep
                suspendedSleptDuringClosure = sleptDuringClosure
                awakeClosedSince = nil
                awakeClosedHotSince = nil
                remoteSessionPaused = false
                if noSleepOn {
                    turnOff()
                    log("螢幕打開，結束 awakeClosed 並解除 nosleep")
                }
            }
            if isInterrupting {
                pendingResumeAfterInterrupt = true
                pendingWakeGapOnDrain = wakeGap || sleptDuringClosure
                log("開蓋時仍在等待被中斷程序收尾，延後到收尾完成後再決定繼續或通知")
            } else if !interruptRecords.isEmpty {
                let late = (wakeGap || sleptDuringClosure) && !interruptCompletedAndSleepIssued
                scheduleInterruptOpenResolution(late: late)
            } else {
                awakeClosedEndedBySleep = false
                sleptDuringClosure = false
                interruptSleepIssued = false
                interruptCompletedAndSleepIssued = false
            }
        }
        // 闔蓋可能在兩次輪詢間令 App 直接睡；醒來時蓋子已打開，沒有觀察到 close/open 邊緣。
        // 若輪詢間隔符合 wakeGap、工作仍在，且本次闔蓋未完成中斷並呼叫 sleepNow，補一則「來不及中斷」通知。
        if activeInterruptMode, !lidShut, wakeGap, !interruptCompletedAndSleepIssued, !pendingResumeAfterInterrupt, interruptRecords.isEmpty {
            let work = interruptWork()
            if !work.isEmpty {
                // 這是新的、未觀察到闔蓋邊緣的週期；不能沿用前一週期的 sleepNow 狀態。
                activeInterruptCycleID += 1
                interruptRecordCycleID = activeInterruptCycleID
                let cycleID = activeInterruptCycleID
                interruptSleepIssued = false
                interruptNotified = false
                sleptDuringClosure = true
                awakeClosedEndedBySleep = false
                for item in work {
                    deliveredInProcessIDs.remove(item.id)
                    deliveredInProcessRecords.removeValue(forKey: item.id)
                    let pendingSnapshot = item.supportsTermination ? pendingMessagesForInterrupt(item.id) : LidInterruptPendingMessages()
                    let pending = pendingSnapshot.messages
                    mergeInterruptRecord(LidInterruption(id: item.id, title: item.title, engine: item.engine,
                        supportsTermination: item.supportsTermination, details: item.details,
                        queuedMessages: pending.filter { !$0.text.isEmpty }, terminated: false,
                        forceKilled: false, stillRunning: item.requiresTermination,
                        outboxReadFailed: pendingSnapshot.outboxReadFailed,
                        foreground: item.foreground), cycleID: cycleID)
                }
                log("醒來時發現輪詢間隔符合 wakeGap，且仍有 \(work.count) 個工作項目；補送來不及中斷的通知")
                _ = persistRescueWithMemoryFallback(Array(interruptRecords.values), late: true, at: t)
                scheduleInterruptOpenResolution(late: true)
            }
        }
        if lidShut {
            if !wasLidShut {
                let existingIDs = Set(interruptRecords.keys)
                let newWorkDuringBounce = activeInterruptMode && interruptWork().contains { item in
                    !existingIDs.contains(item.id) || item.requiresTermination
                }
                if let suspended = suspendedAwakeClosedSince, activeInterruptMode,
                   !suspendedAwakeClosedEndedBySleep, !suspendedSleptDuringClosure,
                   !interruptRecords.isEmpty, !interruptNotified, !isInterrupting,
                   !newWorkDuringBounce {
                    cancelInterruptNotice()
                    awakeClosedSince = suspended
                    remoteSessionPaused = suspendedRemotePaused
                    awakeClosedHotSince = nil
                    awakeClosedEndedBySleep = false
                    sleptDuringClosure = false
                    suspendedAwakeClosedSince = nil
                    suspendedRemotePaused = false
                    suspendedAwakeClosedEndedBySleep = false
                    suspendedSleptDuringClosure = false
                    handledThisClosure = true
                    if !noSleepOn { _ = turnOn(t) }
                    log("開蓋後 \(Int(resumeDelay)) 秒內重新闔蓋且無新增工作，繼續原 awakeClosed")
                } else if interruptOpenScheduled, activeInterruptMode,
                          !awakeClosedEndedBySleep, !sleptDuringClosure,
                          !interruptSleepIssued, !interruptRecords.isEmpty,
                          !interruptNotified, !isInterrupting, !newWorkDuringBounce {
                    cancelInterruptNotice()
                    enterAwakeClosed(at: t)
                    handledThisClosure = true
                    pendingResumeAfterInterrupt = false
                    pendingWakeGapOnDrain = false
                    suspendedAwakeClosedSince = nil
                    suspendedRemotePaused = false
                    suspendedAwakeClosedEndedBySleep = false
                    suspendedSleptDuringClosure = false
                    log("中斷收尾完成開蓋後 \(Int(resumeDelay)) 秒內重新闔蓋且無新增工作，取消待送動作並進入 awakeClosed")
                } else {
                    if !isInterrupting {
                        cancelInterruptNotice()
                        let hasPendingSleepNotice = !interruptRecords.isEmpty && !interruptNotified
                            && (awakeClosedEndedBySleep || sleptDuringClosure || interruptSleepIssued)
                        if hasPendingSleepNotice {
                            if !newWorkDuringBounce {
                                handledThisClosure = true
                            }
                            log("睡過開蓋於通知延遲內重新闔蓋，保留只送通知記錄與睡過狀態")
                        } else {
                            if !interruptRecords.isEmpty && !interruptNotified {
                                let toRescue = Array(interruptRecords.values)
                                _ = persistRescueWithMemoryFallback(toRescue, late: awakeClosedEndedBySleep || sleptDuringClosure, at: t)
                                if newWorkDuringBounce, toRescue.contains(where: shouldPersistForRescue) {
                                    scheduleRescueRetry(at: t, fromRetryTick: false, reason: "短時間重闔前保留待送記錄")
                                }
                            }
                            interruptRecords.removeAll()
                            interruptSleepIssued = false
                            interruptCompletedAndSleepIssued = false
                            interruptDeadlineHandled = false
                            awakeClosedEndedBySleep = false
                            sleptDuringClosure = false
                        }
                    }
                    pendingResumeAfterInterrupt = false
                    pendingWakeGapOnDrain = false
                    suspendedAwakeClosedSince = nil
                    suspendedRemotePaused = false
                    suspendedAwakeClosedEndedBySleep = false
                    suspendedSleptDuringClosure = false
                }
            }
            wasLidShut = true
        }

        if !lidShut, !isInterrupting, awakeClosedSince == nil, !interruptOpenScheduled,
           let retryAt = pendingRescueRetryAt, t >= retryAt {
            pendingRescueRetryAt = nil
            let status = pendingRescueStatus()
            if status.readFailed {
                log("讀取闔蓋中斷救援檔失敗，保留原檔並依重試上限排程")
                if !status.entries.isEmpty {
                    runRescueRetryDelivery(status.entries, at: t)
                } else {
                    scheduleRescueRetry(at: t, fromRetryTick: true, reason: "救援檔讀取失敗")
                }
            } else if !status.entries.isEmpty {
                runRescueRetryDelivery(status.entries, at: t)
            } else {
                rescueRetryCount = 0
            }
        }

        if !on {
            cancelPendingResume()
            stoppedSessionIDs.removeAll()
            resetInterruptStateForConfigDisable(reason: "設定關閉了闔蓋功能，清除 awakeClosed 狀態並交回系統管理睡眠")
            resetSleepRetry()
            if isHolding { endHold(reason: "設定關閉了這個功能", problem: false, keepNoSleep: false) }
            if noSleepOn { turnOff(); log("結束預擋：設定關閉了這個功能") }
            flushPending(closed: closed)
            return
        }
        if !activeInterruptMode {
            resetInterruptStateForConfigDisable(reason: "主動中斷設定關閉，清除 awakeClosed 狀態並交回系統管理睡眠")
        }

        tickSleepRetryIfNeeded(currentContinuous: currentContinuous, lidShut: lidShut)

        if activeInterruptMode, lidShut {
            tickInterruptClose(at: t, currentContinuous: currentContinuous, batt: batt)
            flushPending(closed: true)
            return
        }
        if isInterrupting {
            advanceInterruptClose(at: t)
            if isInterrupting {
                flushPending(closed: lidShut)
                return
            }
        }

        if !closed {
            if !activeInterruptMode { maybeSleepAfterExternalIdle(external: external, lidShut: lidShut, enabled: on, working: working) }
            // 外接螢幕闔蓋（Mac 本來就不睡）：不叫停、不主動睡，但「撐著不睡」的 1 小時上限、電量、溫度照樣管，
            // 不然 Sidecar／遠端桌面等被誤當外接，或螢幕其實關了，放在包包裡會一直悶著
            if !activeInterruptMode, external, let since = externalSince, !externalCapped {
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
            let preholdWork = activeInterruptMode ? interruptWork().filter(\.requiresTermination).count : working
            if preholdWork > 0 && (activeInterruptMode || !lowBattery) && (activeInterruptMode || !externalCapped) {
                idleSince = nil
                if !noSleepOn, !preholdTrying, t >= preholdNextTry {
                    if !preholdFailedBefore {
                        // 第一次：照舊同步試（小幫手正常時很快，行為跟以前一樣）
                        switch turnOn(t) {
                        case .ok: unsupportedLogged = false; log("預擋：有 \(preholdWork) 段工作中，先讓 Mac 不睡（螢幕開著，不影響平常使用）")
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
                                let preholdCount = self.interruptOnCloseEnabled()
                                    ? self.interruptWork().filter(\.requiresTermination).count : self.workingCount()
                                if preholdCount > 0, !self.env.lidClosed(), (self.interruptOnCloseEnabled() || !lowNow),
                                   (self.interruptOnCloseEnabled() || !self.externalCapped) {
                                    self.noSleepOn = true; self.noSleepGen += 1; self.lastStatusCheck = t2
                                    try? "{\"since\":\(Int(t2.timeIntervalSince1970))}".write(to: self.markerURL, atomically: true, encoding: .utf8)
                                    self.preholdFailedBefore = false; self.unsupportedLogged = false
                                    self.log("預擋：有 \(preholdCount) 段工作中，先讓 Mac 不睡（重試成功）")
                                } else { _ = self.env.setNoSleep(false) }
                            }
                        }
                    }
                }
            } else if noSleepOn {
                if !activeInterruptMode && lowBattery && working > 0 {
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
                            if self.env.lidClosed(), !self.externalNoted { self.log("蓋子還闔著，補送主動睡"); self.issueSleepNow() }
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
                log("撐著 電量 \(batt.map { "\($0.percent)%\($0.onAC ? "（插電）" : "")" } ?? "?") 這一分鐘最高溫 \(peak.map { String(format: "%.1f°C", $0) } ?? "?")（現在 \(temp.map { String(format: "%.1f°C", $0) } ?? "?")） 工作中 \(working) 段\(workDetail())")
            }
        } else if !handledThisClosure, working > 0 {
            handledThisClosure = true
            switch turnOn(t) {       // 預擋中就已經開著，這裡不會再切
            case .ok:
                holdingSince = t; lastLog = t; hotSince = nil; maxTempSeen = env.maxTemperature(); windowMaxTemp = maxTempSeen; idleSince = nil
                let ids = workingIDs()
                var notified = 0
                pruneNoticeTimes(t)
                for id in ids {
                    // 同聊天室 5 秒內不重複送闔蓋停止通知（與開蓋同機制）
                    if let last = lastStopSentAt[id], t.timeIntervalSince(last) < resumeDedupeWindow { continue }
                    if sendStop(id) { lastStopSentAt[id] = t; stoppedSessionIDs.insert(id); notified += 1 }
                }
                log("闔蓋，撐著讓它做完這一段：工作中 \(working) 段，已通知 \(notified) 個聊天室；最久 \(Int(limits.maxHold / 60)) 分鐘\(workDetail())")
            case .unsupported:
                log("闔蓋時有 \(working) 段工作中，但 Battery 的小幫手還沒支援 nosleep（要 v6），照常睡眠")
            case .failed(let why):
                log("闔蓋時想撐著但失敗（\(why)），照常睡眠")
            }
        } else if noSleepOn, working == 0 {
            // 預擋中闔蓋、但聊天室剛好都做完了：不用撐，讓系統睡
            turnOff(); log("闔蓋時聊天室都已做完，結束預擋，蓋子闔著，主動讓 Mac 睡"); issueSleepNow(atContinuous: currentContinuous)
        }
        flushPending(closed: true)
    }

    private func issueSleepNow(atContinuous continuousNow: TimeInterval? = nil) {
        sleepRetryLastIssuedAt = continuousNow ?? env.continuousTime()
        sleepRetryAttempts = 0
        sleepRetryGaveUp = false
        env.sleepNow()
    }

    private func resetSleepRetry() {
        sleepRetryLastIssuedAt = nil
        sleepRetryAttempts = 0
        sleepRetryGaveUp = false
    }

    private func tickSleepRetryIfNeeded(currentContinuous: TimeInterval, lidShut: Bool) {
        guard lidShut, !sleepRetryGaveUp, let lastIssued = sleepRetryLastIssuedAt else { return }
        guard !noSleepOn, !isHolding, !isInterrupting, awakeClosedSince == nil else { return }
        guard currentContinuous - lastIssued >= limits.sleepRetryInterval else { return }
        if sleepRetryAttempts < limits.sleepRetryMaxAttempts {
            sleepRetryAttempts += 1
            sleepRetryLastIssuedAt = currentContinuous
            log("蓋子仍闔著且系統仍醒著（已過 \(Int(limits.sleepRetryInterval)) 秒），重發 pmset sleepnow（第 \(sleepRetryAttempts)/\(limits.sleepRetryMaxAttempts) 次）")
            env.sleepNow()
        } else {
            sleepRetryGaveUp = true
            sleepRetryLastIssuedAt = nil
            log("蓋子仍闔著但已重發 sleepNow 達 \(limits.sleepRetryMaxAttempts) 次仍未睡眠，停止重試")
        }
    }

    private func workDetail() -> String {
        let items = workDescriptions()
        return items.isEmpty ? "" : "；在撐：" + items.joined(separator: "、")
    }

    private func resetInterruptStateForConfigDisable(reason: String) {
        let hadInterruptState = awakeClosedSince != nil || isInterrupting || !interruptRecords.isEmpty
            || suspendedAwakeClosedSince != nil || pendingResumeAfterInterrupt
        guard hadInterruptState else { return }
        cancelInterruptNotice()
        resetSleepRetry()
        if !interruptRecords.isEmpty && !interruptNotified {
            let t = now()
            let toRescue = Array(interruptRecords.values)
            _ = persistRescueWithMemoryFallback(toRescue, late: awakeClosedEndedBySleep || sleptDuringClosure, at: t)
            if toRescue.contains(where: shouldPersistForRescue) {
                scheduleRescueRetry(at: t, fromRetryTick: false, reason: "設定關閉時保留待送救援記錄", immediate: true)
            }
        }
        awakeClosedSince = nil
        awakeClosedHotSince = nil
        remoteSessionPaused = false
        awakeClosedEndedBySleep = false
        sleptDuringClosure = false
        suspendedAwakeClosedSince = nil
        suspendedRemotePaused = false
        suspendedAwakeClosedEndedBySleep = false
        suspendedSleptDuringClosure = false
        pendingResumeAfterInterrupt = false
        pendingWakeGapOnDrain = false
        interruptStartedAt = nil
        interruptingIDs.removeAll()
        interruptRecords.removeAll()
        interruptNotified = false
        interruptSleepIssued = false
        interruptCompletedAndSleepIssued = false
        interruptDeadlineHandled = false
        handledThisClosure = false
        if noSleepOn { turnOff() }
        else {
            _ = env.setNoSleep(false)
            try? FileManager.default.removeItem(at: markerURL)
        }
        log(reason)
    }

    private func tickInterruptClose(at t: Date, currentContinuous: TimeInterval, batt: (percent: Int, onAC: Bool)?) {
        // §9.3：awakeClosed 檢查必須在 handledThisClosure guard 之前
        if awakeClosedSince != nil {
            tickAwakeClosed(at: t, currentContinuous: currentContinuous, batt: batt)
            return
        }
        if isInterrupting {
            pendingResumeAfterInterrupt = false
            pendingWakeGapOnDrain = false
            advanceInterruptClose(at: t)
            return
        }
        guard !handledThisClosure else { return }
        let work = interruptWork()
        guard !work.isEmpty else {
            guard env.lidClosed(), !interruptSleepIssued else { return }
            // 只有本次確實預擋住系統睡眠，才需要主動放鎖並補送睡眠請求。
            // 否則交給系統原本的闔蓋行為，避免影響 clamshell 或啟動時已闔蓋的情況。
            guard noSleepOn else { return }
            turnOff()
            interruptSleepIssued = true
            log("闔蓋時沒有需要中斷的工作，解除預擋後主動睡眠")
            issueSleepNow(atContinuous: currentContinuous)
            return
        }

        handledThisClosure = true
        resetSleepRetry()
        cancelInterruptNotice()
        if !interruptRecords.isEmpty && !interruptNotified {
            let toRescue = Array(interruptRecords.values)
            _ = persistRescueWithMemoryFallback(toRescue, late: awakeClosedEndedBySleep || sleptDuringClosure, at: t)
            if toRescue.contains(where: shouldPersistForRescue) {
                scheduleRescueRetry(at: t, fromRetryTick: false, reason: "新一輪闔蓋前保留未送出記錄")
            }
        }
        activeInterruptCycleID += 1
        interruptRecordCycleID = activeInterruptCycleID
        interruptRecords.removeAll()
        awakeClosedEndedBySleep = false
        sleptDuringClosure = false
        interruptSleepIssued = false
        interruptCompletedAndSleepIssued = false
        let cycleID = activeInterruptCycleID
        interruptStartedAt = t
        interruptCloseGeneration += 1
        scheduleInterruptDeadline(started: t, generation: interruptCloseGeneration)
        interruptDeadlineHandled = false
        interruptNotified = false
        interruptingIDs.removeAll()
        log("闔蓋主動中斷開始：\(work.count) 個聊天室／工作項目\(workDetail())")

        for item in work {
            deliveredInProcessIDs.remove(item.id)
            deliveredInProcessRecords.removeValue(forKey: item.id)
            let pendingSnapshot = item.supportsTermination ? pendingMessagesForInterrupt(item.id) : LidInterruptPendingMessages()
            let pending = pendingSnapshot.messages
            var record = LidInterruption(id: item.id, title: item.title, engine: item.engine,
                                         supportsTermination: item.supportsTermination, details: item.details,
                                         queuedMessages: pending.filter { !$0.text.isEmpty },
                                         terminated: false, forceKilled: false, stillRunning: false,
                                         outboxReadFailed: pendingSnapshot.outboxReadFailed,
                                         foreground: item.foreground)
            // 在 terminateForInterrupt 移除寄件匣之前，先將含排隊訊息的中斷記錄落盤保全；失敗時不得清除寄件匣。
            let rescuePersistedBeforeTerminate: Bool
            if shouldPersistForRescue(record) {
                rescuePersistedBeforeTerminate = persistRescue([record], late: false, at: t)
                if !rescuePersistedBeforeTerminate {
                    record.unpersisted = true
                    log("闔蓋主動中斷：\(item.title)（\(item.engine)）救援檔寫入失敗，標記為未持久化並保留寄件匣訊息")
                }
            } else {
                rescuePersistedBeforeTerminate = true
            }
            if item.requiresTermination {
                let ids: Set<String> = rescuePersistedBeforeTerminate ? Set(pending.map { $0.id.lowercased() }) : []
                let terminated = terminateForInterrupt(item.id, ids)
                record.terminated = terminated
                record.stillRunning = !terminated
                if terminated { interruptingIDs.insert(item.id) }
                log("闔蓋主動中斷：\(item.title)（\(item.engine)）\(terminated ? "已呼叫程序終止" : "沒有可用的聊天室程序")；待送 \(pending.count) 則\(rescuePersistedBeforeTerminate ? "" : "（救援寫入失敗，已保留寄件匣）")")
            } else {
                log("闔蓋主動中斷：\(item.title)（\(item.engine)）屬於本版不主動停止的工作")
            }
            mergeInterruptRecord(record, cycleID: cycleID)
            if let merged = interruptRecords[record.id], shouldPersistForRescue(merged) {
                _ = persistRescueWithMemoryFallback([merged], late: false, at: t)
            }
        }

        if !noSleepOn {
            switch turnOn(t) {
            case .ok: log("闔蓋中斷期間保持醒著，等待模型程序結束")
            case .unsupported: log("闔蓋中斷期間小幫手不支援 nosleep；系統可能先睡，開蓋時檢查 wakeGap")
            case .failed(let why): log("闔蓋中斷期間無法預擋睡眠（\(why)）；開蓋時檢查 wakeGap")
            }
        }
        advanceInterruptClose(at: t)
    }

    private func mergeInterruptRecord(_ next: LidInterruption, cycleID: Int) {
        guard cycleID == activeInterruptCycleID else { return }
        if interruptRecordCycleID != cycleID {
            interruptRecords.removeAll()
            interruptRecordCycleID = cycleID
        }
        guard let old = interruptRecords[next.id] else { interruptRecords[next.id] = next; return }
        interruptRecords[next.id] = old.merged(with: next, keepStillRunningOr: true)
    }

    private func scheduleInterruptDeadline(started: Date, generation: Int) {
        let remaining = max(0, 10 - now().timeIntervalSince(started))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.interruptCloseGeneration == generation,
                  self.interruptStartedAt == started else { return }
            let elapsed = self.now().timeIntervalSince(started)
            if elapsed < 10 {
                self.scheduleInterruptDeadline(started: started, generation: generation)
                return
            }
            self.advanceInterruptClose(at: self.now())
        }
    }

    private func advanceInterruptClose(at t: Date) {
        guard let started = interruptStartedAt else { return }
        for id in interruptingIDs where didForceKillForInterrupt(id) {
            guard var row = interruptRecords[id], !row.forceKilled else { continue }
            row.forceKilled = true
            interruptRecords[id] = row
            _ = persistRescueWithMemoryFallback([row], late: false, at: t)
            log("闔蓋中斷：聊天室 \(row.title)（\(row.engine)）已送 SIGKILL")
        }
        let alive = interruptingIDs.filter(isDraining)
        if !alive.isEmpty, t.timeIntervalSince(started) < 10 { return }
        if !alive.isEmpty, !interruptDeadlineHandled {
            interruptDeadlineHandled = true
            for id in alive {
                let killed = forceKillDraining(id)
                if var row = interruptRecords[id] {
                    // 這裡只記 SIGKILL 是否成功送出；程序是否已回收延到開蓋通知建立時再取樣。
                    row.forceKilled = row.forceKilled || didForceKillForInterrupt(id)
                    interruptRecords[id] = row
                    _ = persistRescueWithMemoryFallback([row], late: false, at: t)
                }
                log("闔蓋中斷滿 10 秒：聊天室 \(id.uuidString.lowercased())\(killed ? "已送 SIGKILL" : "仍有程序群組存活")")
            }
        }
        interruptStartedAt = nil
        interruptingIDs.removeAll()
        let activeMode = enabled() && interruptOnCloseEnabled()
        if env.lidClosed(), activeMode {
            enterAwakeClosed(at: t)
        } else {
            if noSleepOn { turnOff() }
            else {
                _ = env.setNoSleep(false)
                try? FileManager.default.removeItem(at: markerURL)
            }
            log("闔蓋中斷流程解除 nosleep")
            if pendingResumeAfterInterrupt {
                pendingResumeAfterInterrupt = false
                let lateFlag = pendingWakeGapOnDrain
                pendingWakeGapOnDrain = false
                if !env.lidClosed(), activeMode, !interruptRecords.isEmpty {
                    scheduleInterruptOpenResolution(late: lateFlag)
                } else if !activeMode {
                    resetInterruptStateForConfigDisable(reason: "主動中斷設定關閉，清除 awakeClosed 狀態")
                }
            } else if !env.lidClosed() {
                log("聊天室程序已完成中斷；螢幕已開，沒有呼叫 sleepNow")
            }
        }
    }

    private func enterAwakeClosed(at t: Date) {
        resetSleepRetry()
        if !noSleepOn {
            switch turnOn(t) {
            case .ok: break
            case .unsupported: log("awakeClosed：小幫手不支援 nosleep；系統可能自行睡眠")
            case .failed(let why): log("awakeClosed：無法維持 nosleep（\(why)）")
            }
        }
        awakeClosedSince = env.continuousTime()
        awakeClosedHotSince = nil
        remoteSessionPaused = false
        awakeClosedLastRetry = t
        awakeClosedRetryFailLogged = false
        _ = env.remoteSessionActive()
        log("闔蓋中斷收尾完成，進入 awakeClosed（保持醒著最長 \(Int(limits.awakeClosedMax / 60)) 分鐘）")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ok = self.env.setFanAuto()
            DispatchQueue.main.async {
                self.log(ok ? "awakeClosed：已請小幫手交還風扇給系統控制" : "awakeClosed：請小幫手交還風扇失敗（需小幫手 v9，不阻擋保持醒著）")
            }
        }
    }

    private func tickAwakeClosed(at t: Date, currentContinuous: TimeInterval, batt: (percent: Int, onAC: Bool)?) {
        guard let since = awakeClosedSince else { return }
        if let batt, !batt.onAC, batt.percent < limits.awakeClosedMinBattery {
            endAwakeClosedForSleep(reason: "awakeClosed：電量低於 \(limits.awakeClosedMinBattery)%（目前 \(batt.percent)%）且未插電，解除 nosleep 並睡眠")
            return
        }
        if let temp = env.maxTemperature(), temp >= limits.hotCelsius {
            if awakeClosedHotSince == nil { awakeClosedHotSince = currentContinuous }
        } else {
            awakeClosedHotSince = nil
        }
        if let hotStart = awakeClosedHotSince, currentContinuous - hotStart >= limits.hotSeconds {
            endAwakeClosedForSleep(reason: "awakeClosed：溫度過高（連續 \(Int(limits.hotSeconds)) 秒 ≥ \(Int(limits.hotCelsius))°C），解除 nosleep 並睡眠")
            return
        }
        let remoteActive = env.remoteSessionActive()
        if remoteActive {
            if !remoteSessionPaused {
                remoteSessionPaused = true
                log("awakeClosed：偵測到遠端連線（SSH／螢幕共享／遠端管理），暫停 \(Int(limits.awakeClosedMax / 60)) 分鐘睡眠計時")
            }
        } else if remoteSessionPaused {
            remoteSessionPaused = false
            awakeClosedSince = currentContinuous
            log("awakeClosed：遠端連線已全部中斷，重新計算 \(Int(limits.awakeClosedMax / 60)) 分鐘睡眠計時")
        }
        let effectiveSince = awakeClosedSince ?? since
        if !remoteSessionPaused, currentContinuous - effectiveSince >= limits.awakeClosedMax {
            endAwakeClosedForSleep(reason: "awakeClosed：已保持醒著滿 \(Int(limits.awakeClosedMax / 60)) 分鐘，解除 nosleep 並睡眠")
            return
        }
        if !awakeClosedRetrying, !statusChecking, t.timeIntervalSince(awakeClosedLastRetry) >= 5 {
            awakeClosedLastRetry = t
            awakeClosedRetrying = true
            let startedAt = effectiveSince
            let wasNoSleepOn = noSleepOn
            let gen = noSleepGen
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let status: Bool? = wasNoSleepOn ? self.env.noSleepStatus() : false
                let result: NoSleepResult? = status == true ? nil : self.env.setNoSleep(true)
                DispatchQueue.main.async {
                    self.awakeClosedRetrying = false
                    guard let r = result else {
                        if self.noSleepOn, self.noSleepGen == gen {
                            self.lastStatusCheck = self.now()
                        }
                        return
                    }
                    if r == .ok, self.awakeClosedSince == nil || self.awakeClosedSince != startedAt || self.noSleepGen != gen {
                        _ = self.env.setNoSleep(false)
                        self.log("awakeClosed 重新擋睡眠成功時狀態已變更，改回正常睡眠")
                        if self.env.lidClosed(), !self.externalNoted, self.awakeClosedEndedBySleep, !self.sleptDuringClosure {
                            self.log("蓋子還闔著且 awakeClosed 已結束，補送睡眠")
                            self.issueSleepNow()
                        }
                    } else if r == .ok {
                        let t2 = self.now()
                        self.noSleepOn = true; self.noSleepGen += 1; self.lastStatusCheck = t2
                        try? "{\"since\":\(Int(t2.timeIntervalSince1970))}".write(to: self.markerURL, atomically: true, encoding: .utf8)
                        self.awakeClosedRetryFailLogged = false
                        self.log(wasNoSleepOn ? "awakeClosed 期間小幫手斷線或被解除，重新擋睡眠成功" : "awakeClosed 期間重新擋睡眠成功")
                    } else {
                        if self.noSleepOn, self.noSleepGen == gen {
                            self.noSleepOn = false; self.noSleepGen += 1
                            _ = self.env.setNoSleep(false)
                            try? FileManager.default.removeItem(at: self.markerURL)
                        }
                        if !self.awakeClosedRetryFailLogged {
                            self.awakeClosedRetryFailLogged = true
                            self.log("awakeClosed 期間重新擋睡眠失敗，每 5 秒再試")
                        }
                    }
                }
            }
        }
    }

    private func endAwakeClosedForSleep(reason: String) {
        awakeClosedSince = nil
        awakeClosedHotSince = nil
        remoteSessionPaused = false
        awakeClosedEndedBySleep = true
        if noSleepOn { turnOff() }
        else {
            _ = env.setNoSleep(false)
            try? FileManager.default.removeItem(at: markerURL)
        }
        interruptSleepIssued = true
        log(reason)
        issueSleepNow()
    }

    private func cancelInterruptNotice() {
        interruptNoticeGeneration += 1
        interruptOpenScheduled = false
    }

    private func scheduleInterruptOpenResolution(late: Bool) {
        guard !interruptRecords.isEmpty, !interruptNotified else { return }
        interruptNoticeGeneration += 1
        interruptOpenScheduled = true
        let generation = interruptNoticeGeneration
        let sleptBeforeOpen = awakeClosedEndedBySleep || sleptDuringClosure || late
        DispatchQueue.main.asyncAfter(deadline: .now() + resumeDelay) { [weak self] in
            guard let self, self.interruptNoticeGeneration == generation, !self.env.lidClosed(), !self.interruptNotified else { return }
            self.interruptOpenScheduled = false
            self.interruptNotified = true
            self.suspendedAwakeClosedSince = nil
            self.suspendedRemotePaused = false
            self.suspendedAwakeClosedEndedBySleep = false
            self.suspendedSleptDuringClosure = false
            // 等開蓋處置確定執行時才查程序狀態，讓 SIGKILL 有時間完成回收，
            // 同時不把 10 秒硬上限拖過去。
            var records = Array(self.interruptRecords.values)
            for index in records.indices {
                let id = records[index].id
                records[index].forceKilled = records[index].forceKilled || self.didForceKillForInterrupt(id)
                if records[index].terminated {
                    records[index].stillRunning = self.isDraining(id)
                }
                self.interruptRecords[id] = records[index]
            }
            records.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            self.deliveryReportedInCurrentResolution = false
            self.rescueRetryCount = 0
            self.pendingRescueRetryAt = nil
            if sleptBeforeOpen {
                let completedAndSlept = self.interruptSleepIssued && records.allSatisfy { !$0.stillRunning }
                self.interruptCompletedAndSleepIssued = completedAndSlept
                let effectiveLate = late && !completedAndSlept
                _ = self.persistRescueWithMemoryFallback(records, late: effectiveLate, at: self.now())
                self.log("開蓋後送出闔蓋中斷通知：\(records.count) 段，來源「闔蓋中斷」\(effectiveLate ? "；來不及中斷／曾被睡眠凍結" : "")")
                self.sendInterruptNotices(records, effectiveLate)
            } else {
                self.interruptCompletedAndSleepIssued = false
                _ = self.persistRescueWithMemoryFallback(records, late: false, at: self.now())
                self.log("開蓋時仍在 awakeClosed（未睡過），執行開蓋自動繼續：\(records.count) 筆記錄")
                self.sendInterruptResume(records)
            }
            if !self.deliveryReportedInCurrentResolution {
                let t = self.now()
                self.markRecordsDelivered(records, handledIDs: Set(records.map(\.id)), at: t, logOnRemoveFailure: false)
                let status = self.pendingRescueStatus()
                if !status.entries.isEmpty || status.readFailed {
                    let reason = status.readFailed ? "救援檔讀取失敗" : "救援通知仍有待送項目"
                    self.scheduleRescueRetry(at: t, fromRetryTick: false, reason: reason)
                }
            }
            self.interruptRecords.removeAll()
            // 本次關閉週期的處置已送完；清掉週期旗標，下一次闔蓋重新判斷。
            self.interruptSleepIssued = false
            self.interruptCompletedAndSleepIssued = false
            self.awakeClosedEndedBySleep = false
            self.sleptDuringClosure = false
        }
    }

    /// 合蓋接實體外接螢幕時，完成工作且 HID 閒置滿門檻後，先交還風扇，再重新確認狀態才主動睡。
    private func maybeSleepAfterExternalIdle(external: Bool, lidShut: Bool, enabled: Bool, working: Int) {
        guard enabled, externalIdleSleepEnabled(), lidShut, external, working == 0 else {
            if !lidShut || !external || !enabled || !externalIdleSleepEnabled() || working > 0 { externalIdleSleepTriggered = false }
            return
        }
        guard let idle = env.hidIdleTime(), idle.isFinite else { return }
        guard idle >= limits.externalIdleSleepSeconds else { externalIdleSleepTriggered = false; return }
        guard !externalIdleSleepPending, !externalIdleSleepTriggered else { return }

        externalIdleSleepPending = true
        if noSleepOn { turnOff(); log("外接螢幕闔蓋工作完成，先解除不睡擋鎖") }
        log("外接螢幕闔蓋、聊天室已完成、HID 閒置 \(Int(idle)) 秒；請 Battery 小幫手交還風扇後睡眠")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let stillIdleBeforeFan = self.env.lidClosed() && self.env.externalDisplayOnline()
                && (self.env.hidIdleTime() ?? 0) >= self.limits.externalIdleSleepSeconds
            guard stillIdleBeforeFan else {
                DispatchQueue.main.async {
                    self.externalIdleSleepPending = false
                    self.externalIdleSleepTriggered = false
                    self.log("發出風扇自動前偵測到使用者活動或外接狀態改變，取消風扇切換與睡眠")
                }
                return
            }
            let fanAuto = self.env.setFanAuto()
            DispatchQueue.main.async {
                self.externalIdleSleepPending = false
                let stillSafe = self.enabled() && self.externalIdleSleepEnabled() && self.env.lidClosed()
                    && self.env.externalDisplayOnline() && self.workingCount() == 0
                    && (self.env.hidIdleTime() ?? 0) >= self.limits.externalIdleSleepSeconds
                guard stillSafe else {
                    self.log("風扇已要求自動；睡眠前重新檢查發現狀態改變，取消主動睡眠")
                    self.externalIdleSleepTriggered = false
                    return
                }
                self.externalIdleSleepTriggered = true
                self.log(fanAuto ? "Battery 小幫手已將風扇交還系統自動" : "Battery 小幫手未回應風扇自動指令；仍依睡眠通知交還風扇")
                self.log("外接螢幕闔蓋閒置滿 \(Int(self.limits.externalIdleSleepSeconds / 60)) 分鐘，主動讓 Mac 睡")
                self.issueSleepNow()
            }
        }
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
            let sentAt = self.now()
            self.pruneNoticeTimes(sentAt)
            for id in ids where self.sessionIsAvailable(id) && !self.sessionIsArchived(id) {
                if let last = self.lastResumeSentAt[id], sentAt.timeIntervalSince(last) < self.resumeDedupeWindow { continue }
                self.lastResumeSentAt[id] = sentAt
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
        if sleep { log("蓋子闔著，主動讓 Mac 睡"); issueSleepNow() }
        log("解除闔蓋不睡：\(reason)（撐了約 \(mins) 分鐘，最高溫 \(temp)）\(keepNoSleep && noSleepOn ? "；還在工作中，退回預擋" : "")")
        if problem { pending = ("闔蓋時沒能做完這一段", "\(reason)\n撐了約 \(mins) 分鐘，期間最高溫 \(temp)。聊天室可能停在做到一半的地方，可以接著問。") }
    }

    /// 出事的才提醒，而且等使用者打開螢幕之後
    private func flushPending(closed: Bool) {
        guard !closed else { return }
        if let p = pending, canPresentNotify() {
            pending = nil
            notify(p.reason, p.detail)
        }
        flushRescueNotifications(closed: closed)
    }

    func flushRescueNotifications(closed: Bool? = nil) {
        let isClosed = closed ?? (env.lidClosed() && !env.externalDisplayOnline())
        guard !isClosed else { return }
        while !pendingRescueNotifications.isEmpty, canPresentNotify() {
            let item = pendingRescueNotifications.removeFirst()
            notify(item.title, item.detail)
            if !item.rescueEntryIDs.isEmpty {
                markRescueEntriesReminded(item.rescueEntryIDs)
            }
        }
    }
}

// MARK: - 真正的硬體

final class RealLidEnv: LidEnv {
    private var fd: Int32 = -1
    private let lock = NSLock()      // 重擋重試在背景執行緒、其他呼叫在主執行緒，fd 要排隊用
    private let socketPath = "/var/run/com.local.toolbox.fan.sock"
    private var smc: LidSMC? = LidSMC()
    private let remoteLock = NSLock()
    private let remoteQueue = DispatchQueue(label: "com.codenv.lid.remote", qos: .utility)
    private var remoteCachedActive = false
    private var remoteLastCheckedAt: TimeInterval = -.infinity
    private var remoteChecking = false
    private var remoteErrorLogged = false
    var onRemoteError: ((String) -> Void)?

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
        return ids.prefix(Int(n)).contains { displayID in
            let vendor = CGDisplayVendorNumber(displayID)
            let name = NSScreen.screens.first { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }?.localizedName ?? ""
            return Self.isRealExternal(builtin: CGDisplayIsBuiltin(displayID) != 0, vendor: vendor,
                                      model: CGDisplayModelNumber(displayID), asleep: CGDisplayIsAsleep(displayID) != 0,
                                      size: CGDisplayScreenSize(displayID), displayName: name)
        }
    }

    /// 實體外接螢幕：不是內建的、有真的廠商編號（虛擬螢幕沒有，或是 0xFFFFFFFF 未知）、沒在睡眠
    /// 限制：沒有公開的「是不是虛擬螢幕」API（CGDisplayIsVirtual 不存在）。這裡用「廠商編號不是 0／未知」加「回報了實體尺寸」兩個條件，
    /// 虛擬螢幕通常沒有實體尺寸；有自訂廠商又假報尺寸的假螢幕擋不住，靠外接闔蓋期間的 1 小時／電量／溫度上限兜底
    static func isOpenDisplay(vendor: UInt32, displayName: String) -> Bool {
        // OpenDisplay reports a physical size and vendor 0x5043, so EDID/size alone cannot distinguish it.
        displayName.localizedCaseInsensitiveContains("OpenDisplay")
    }

    static func isRealExternal(builtin: Bool, vendor: UInt32, model: UInt32, asleep: Bool, size: CGSize = CGSize(width: 1, height: 1), displayName: String = "") -> Bool {
        !builtin && !asleep && vendor != 0 && vendor != 0xFFFF_FFFF && size.width > 0 && size.height > 0
            && !isOpenDisplay(vendor: vendor, displayName: displayName)
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

    func hidIdleTime() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return nil }
        return TimeInterval(value.uint64Value) / 1_000_000_000
    }

    func setFanAuto() -> Bool {
        guard let s = connectHelper() else { return false }
        defer { close(s) }
        return request(s, "auto") == "ok"
    }

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

    private static func sysctlTimeval(_ name: String) -> TimeInterval? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &tv, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size else { return nil }
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }

    func sleepEvidence() -> LidSleepEvidence? {
        guard let wake = Self.sysctlTimeval("kern.waketime"),
              let sleep = Self.sysctlTimeval("kern.sleeptime") else { return nil }
        return LidSleepEvidence(wakeTime: wake, sleepTime: sleep)
    }

    func systemUptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func continuousTime() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }

    /// 檢查 SSH（22）、螢幕共享（5900）、遠端管理（3283）是否有 ESTABLISHED TCP 連線。
    /// 呼叫在背景佇列執行，結果快取至少 5 秒；查詢失敗或逾時採 fail-safe 視為 false（照上限睡眠）。
    func remoteSessionActive() -> Bool {
        let nowMono = continuousTime()
        remoteLock.lock()
        let cached = remoteCachedActive
        let shouldRefresh = !remoteChecking && (nowMono - remoteLastCheckedAt >= 5)
        if shouldRefresh { remoteChecking = true }
        remoteLock.unlock()
        if shouldRefresh {
            remoteQueue.async { [weak self] in
                guard let self else { return }
                let active = self.fetchRemoteSessionActive()
                let finishedMono = self.continuousTime()
                self.remoteLock.lock()
                self.remoteCachedActive = active
                self.remoteLastCheckedAt = finishedMono
                self.remoteChecking = false
                self.remoteLock.unlock()
            }
        }
        return cached
    }

    private func fetchRemoteSessionActive() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        p.arguments = ["-an", "-p", "tcp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            reportRemoteErrorOnce("遠端連線偵測失敗（無法啟動 netstat：\(error.localizedDescription)），視為沒有遠端連線")
            return false
        }
        let timeoutLock = NSLock()
        var timedOut = false
        let timeoutItem = DispatchWorkItem {
            timeoutLock.lock()
            timedOut = true
            timeoutLock.unlock()
            if p.isRunning { p.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: timeoutItem)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timeoutItem.cancel()
        timeoutLock.lock()
        let didTimeout = timedOut
        timeoutLock.unlock()
        if didTimeout || p.terminationStatus != 0 {
            reportRemoteErrorOnce(didTimeout
                ? "遠端連線偵測逾時（netstat 超過 2 秒），視為沒有遠端連線"
                : "遠端連線偵測失敗（netstat 結束碼 \(p.terminationStatus)），視為沒有遠端連線")
            return false
        }
        remoteLock.lock()
        remoteErrorLogged = false
        remoteLock.unlock()
        return Self.hasEstablishedRemotePort(inNetstatOutput: String(decoding: data, as: UTF8.self))
    }

    private func reportRemoteErrorOnce(_ message: String) {
        remoteLock.lock()
        let shouldLog = !remoteErrorLogged
        remoteErrorLogged = true
        remoteLock.unlock()
        if shouldLog { onRemoteError?(message) }
    }

    static func hasEstablishedRemotePort(inNetstatOutput output: String) -> Bool {
        let targetPorts: Set<Substring> = ["22", "5900", "3283"]
        for line in output.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 6, cols[0].hasPrefix("tcp"), cols[5] == "ESTABLISHED" else { continue }
            let local = cols[3]
            if let dot = local.lastIndex(of: ".") {
                let port = local[local.index(after: dot)...]
                if targetPorts.contains(port) { return true }
            }
        }
        return false
    }

    func sleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            guard proc.terminationStatus != 0 else { return }
            let message = "pmset sleepnow 結束碼異常（\(proc.terminationStatus)）"
            DispatchQueue.main.async { [weak self] in self?.onRemoteError?(message) }
        }
        do {
            try p.run()
        } catch {
            let message = "pmset sleepnow 失敗：\(error.localizedDescription)"
            if Thread.isMainThread {
                onRemoteError?(message)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onRemoteError?(message) }
            }
        }
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
    /// close-unobserved 模擬真機在兩次取樣間闔上又打開：期間 timer 可以 tick，但只讀到上次觀察值。
    var suppressLidObservation = false
    private var lastObservedLidClosed = false
    var screenOff = false
    var percent = 80
    var onAC = false
    var temp = 50.0
    var idleSeconds: TimeInterval = 0
    var helper = "ok"            // ok | unsupported | fail
    var remote = false
    var onCall: (String) -> Void = { _ in }
    var traceNow: () -> Date = Date.init
    private(set) var trace: [[String: Any]] = []
    var external = false
    func lidClosed() -> Bool {
        guard !suppressLidObservation else { return lastObservedLidClosed }
        lastObservedLidClosed = closed
        return closed
    }
    func externalDisplayOnline() -> Bool { external }
    func battery() -> (percent: Int, onAC: Bool)? { (percent, onAC) }
    func maxTemperature() -> Double? { temp }
    func hidIdleTime() -> TimeInterval? { idleSeconds }
    func remoteSessionActive() -> Bool { remote }
    var actualOn = false
    var connDead = false      // 假裝小幫手重啟、連線已斷
    var sleepEvidenceValue: LidSleepEvidence? = LidSleepEvidence(wakeTime: 0, sleepTime: 0)
    var uptimeOffset: TimeInterval = 0
    var continuousOffset: TimeInterval = 0
    func noSleepStatus() -> Bool? { helper == "ok" && !connDead ? actualOn : nil }
    func sleepEvidence() -> LidSleepEvidence? { sleepEvidenceValue }
    func systemUptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime + uptimeOffset }
    func continuousTime() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 + continuousOffset }
    func sleepNow() {
        trace.append(["event": "sleepNow", "time": traceNow().timeIntervalSince1970])
        onCall("[假] pmset sleepnow（蓋子闔著，主動睡）")
    }
    func setFanAuto() -> Bool {
        if Thread.isMainThread { onCall("[假小幫手] fan auto") }
        else { DispatchQueue.main.async { self.onCall("[假小幫手] fan auto") } }
        return helper == "ok"
    }
    func setNoSleep(_ on: Bool) -> NoSleepResult {
        let result: NoSleepResult
        if !on {
            actualOn = false
            result = .ok
        } else {
            connDead = false
            switch helper {
            case "unsupported": result = .unsupported
            case "fail": result = .failed("假的失敗")
            default: actualOn = true; result = .ok
            }
        }
        let resultName: String
        switch result {
        case .ok: resultName = "ok"
        case .unsupported: resultName = "unsupported"
        case .failed: resultName = "failed"
        }
        trace.append(["event": "setNoSleep", "enabled": on, "time": traceNow().timeIntervalSince1970, "result": resultName])
        onCall("[假小幫手] nosleep \(on ? "on" : "off")（\(helper)）")
        return result
    }
}
