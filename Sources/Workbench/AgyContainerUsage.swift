import Foundation

// MARK: - agy 多帳號容器額度讀取、節流與合計計算（規格第 8 節）
// 原始碼與預設值不含任何真實帳號名；帳號與容器對應由使用者狀態資料夾的 agy-container-map.json 提供。

enum AgyContainerAccountStatus: String, Equatable {
    case fresh
    case throttled
    case down
    case unreadable
    case skipped
}

/// `<狀態資料夾>/agy-container-map.json` 解析結果（`{"<帳號名>":"<容器名>"}`）。
/// 檔案不存在、讀不到、非字典或無合法項目時為停用狀態（`isEnabled == false`）。
struct AgyContainerMap: Equatable {
    let entries: [String: String]

    var isEnabled: Bool { !entries.isEmpty }

    subscript(account: String) -> String? {
        entries[account]
    }

    static let disabled = AgyContainerMap(entries: [:])

    /// 容器名須符合 `^[a-z0-9][a-z0-9_-]{0,31}$`（不得以 `-` 開頭，防止被 docker 當成旗標）。
    static func isValidContainerName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard (1...32).contains(scalars.count), let first = scalars.first else { return false }
        let fv = first.value
        let firstOK = (fv >= 0x61 && fv <= 0x7A) || (fv >= 0x30 && fv <= 0x39)
        guard firstOK else { return false }
        for scalar in scalars.dropFirst() {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)
                || (v >= 0x30 && v <= 0x39)
                || v == 0x5F
                || v == 0x2D
            if !ok { return false }
        }
        return true
    }

    static func parse(data: Data) -> AgyContainerMap {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .disabled
        }
        var valid: [String: String] = [:]
        for (rawAccount, rawValue) in root {
            guard AgySwapUsageCache.isValidAccountName(rawAccount),
                  let rawContainer = rawValue as? String,
                  isValidContainerName(rawContainer) else {
                continue
            }
            valid[rawAccount] = rawContainer
        }
        return AgyContainerMap(entries: valid)
    }

    static func load(from url: URL?) -> AgyContainerMap {
        guard let url, let data = try? Data(contentsOf: url) else {
            return .disabled
        }
        return parse(data: data)
    }
}

struct AgyContainerTarget: Equatable {
    let account: String
    let container: String
}

/// 每個容器的「上次嘗試時間」節流器（不快取額度數字，僅記錄嘗試時間與成敗）。
/// 成功後預設 10 分鐘內不重讀、失敗後預設 5 分鐘內不重讀；重開 App 歸零。
final class AgyContainerAttemptTracker {
    struct AttemptRecord: Equatable {
        let at: Date
        let succeeded: Bool
    }

    private let lock = NSLock()
    private var records: [String: AttemptRecord] = [:]
    private var inFlight: Set<String> = []

    /// 檢查此容器是否允許開始新一輪嘗試；若允許則標為進行中並回傳 `true`，節流中或進行中回傳 `false`。
    func beginAttemptIfAllowed(
        container: String,
        now: Date = Date(),
        successTTL: TimeInterval,
        failureTTL: TimeInterval
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight.contains(container) {
            return false
        }
        if let last = records[container] {
            let ttl = last.succeeded ? successTTL : failureTTL
            let elapsed = now.timeIntervalSince(last.at)
            if ttl > 0, elapsed >= 0, elapsed < ttl {
                return false
            }
        }
        inFlight.insert(container)
        return true
    }

    /// 結束一次容器嘗試並記錄時間與成敗。
    func recordAttempt(container: String, succeeded: Bool, at: Date = Date()) {
        lock.lock()
        inFlight.remove(container)
        records[container] = AttemptRecord(at: at, succeeded: succeeded)
        lock.unlock()
    }

    /// 僅取消進行中標記而不寫入嘗試紀錄（供未真正發出呼叫的極端路徑使用）。
    func cancelInFlight(container: String) {
        lock.lock()
        inFlight.remove(container)
        lock.unlock()
    }

    func lastRecord(for container: String) -> AttemptRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[container]
    }

    func reset() {
        lock.lock()
        records.removeAll()
        inFlight.removeAll()
        lock.unlock()
    }
}

struct AgyTotalRow: Identifiable, Equatable {
    var id: String { label }
    /// `parseAgy` 原始標籤（dump 與規格對齊用）。
    let label: String
    /// 畫面顯示標題（「Claude 每週」可顯示為「Claude／GPT 每週」）。
    let displayLabel: String
    let percent: Int
    let covered: Int
    let total: Int
    /// 納入本列平均的帳號中，非即時（磁碟快取）資料最舊的 `read_at`；全為即時時為 `nil`。
    let oldestReadAt: Date?

    func footnoteText(now: Date = Date()) -> String? {
        var parts: [String] = []
        if covered < total {
            parts.append(L("\(covered)／\(total) 個帳號"))
        }
        if let oldestReadAt {
            parts.append(L("最舊 \(AgySwapUsageCache.formatAgeText(readAt: oldestReadAt, now: now))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct AgyTotalSummary: Equatable {
    let title: String
    let accountCount: Int
    let rows: [AgyTotalRow]

    func dumpPayload() -> [String: Any] {
        [
            "title": title,
            "accountCount": accountCount,
            "rows": rows.map { row -> [String: Any] in
                [
                    "label": row.label,
                    "percent": row.percent,
                    "covered": row.covered,
                    "total": row.total,
                    "oldestReadAt": row.oldestReadAt.map(AgySwapUsageCache.formatISO8601UTC) ?? NSNull(),
                ]
            },
        ]
    }
}

enum AgyContainerUsage {
    /// 固定額度種類與順序（依 `parseAgy` 實際產出標籤）。
    static var fixedOrderLabels: [String] {
        let five = L("5 小時")
        let week = L("每週")
        return [
            "Gemini \(five)",
            "Gemini \(week)",
            "Argon \(week)",
            "Claude \(week)",
            "Claude \(five)",
        ]
    }

    static func displayLabel(for canonicalLabel: String) -> String {
        let week = L("每週")
        let five = L("5 小時")
        if canonicalLabel == "Claude \(week)" {
            return "Claude／GPT \(week)"
        }
        if canonicalLabel == "Claude \(five)" {
            return "Claude／GPT \(five)"
        }
        return canonicalLabel
    }

    static func title(forAccountCount count: Int) -> String {
        if count == 3 {
            return L("三帳號合計")
        }
        return L("\(count) 帳號合計")
    }

    /// 驗證快取檔與顯示用的 `source` 字串：只接受 `"mac"` 或 `"container:<合法容器名>"`。
    static func validatedCacheSource(_ raw: String) -> String? {
        if raw == "mac" {
            return "mac"
        }
        if raw.hasPrefix("container:") {
            let name = String(raw.dropFirst("container:".count))
            return AgyContainerMap.isValidContainerName(name) ? raw : nil
        }
        return nil
    }

    /// 帳號明細旁顯示的來源文字；無來源時回傳 `nil`。
    static func sourceDisplayLabel(_ source: String?) -> String? {
        guard let source, let valid = validatedCacheSource(source) else { return nil }
        if valid == "mac" {
            return L("來源：Mac")
        }
        let containerName = String(valid.dropFirst("container:".count))
        return L("來源：容器 \(containerName)")
    }

    /// 算術平均並採「0.5 進位（遠離零）」（`.toNearestOrAwayFromZero`）。
    static func roundedAveragePercent(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(0, +)
        let average = Double(sum) / Double(values.count)
        return Int(average.rounded(.toNearestOrAwayFromZero))
    }

    /// 由 `agySwapAccounts` 計算多帳號合計區塊；無任何列時回傳 `nil`（不顯示合計區塊）。
    static func computeTotalSummary(accounts: [AgySwapAccountDisplay]) -> AgyTotalSummary? {
        let totalCount = accounts.count
        guard totalCount > 0 else { return nil }
        let eligible = accounts.filter { $0.state == .live || $0.state == .cached }
        guard !eligible.isEmpty else { return nil }

        var rows: [AgyTotalRow] = []
        for label in fixedOrderLabels {
            var percents: [Int] = []
            var cachedReadAts: [Date] = []
            for account in eligible {
                // 同帳號重複標籤只取第一個，避免納入數超過帳號總數。
                guard let bucket = account.buckets.first(where: { $0.label == label }) else { continue }
                let clamped = max(0, min(100, bucket.remaining))
                percents.append(clamped)
                if account.state == .cached, let readAt = account.readAt {
                    cachedReadAts.append(readAt)
                }
            }
            guard !percents.isEmpty else { continue }
            rows.append(AgyTotalRow(
                label: label,
                displayLabel: displayLabel(for: label),
                percent: roundedAveragePercent(percents),
                covered: percents.count,
                total: totalCount,
                oldestReadAt: cachedReadAts.min()
            ))
        }
        guard !rows.isEmpty else { return nil }
        return AgyTotalSummary(
            title: title(forAccountCount: totalCount),
            accountCount: totalCount,
            rows: rows
        )
    }

    /// 決定本輪換帳號模式可從容器讀取的目標清單（依帳號名排序）。
    /// 僅在：設定檔啟用、已注入 `dockerPath`、非 `accounts_error`、帳號數 ≥ 2、
    /// `switching == false`、`recoveryPending == false`、`canCallAgy == true`、
    /// 且現用帳號已知（`active` 非空且 `live_matches == active`）時，回傳非現用且未失效且在設定檔內的帳號。
    static func eligibleTargets(
        status: AgySwapStatus,
        containerMap: AgyContainerMap,
        dockerPath: String?,
        canCallAgy: Bool
    ) -> [AgyContainerTarget] {
        guard containerMap.isEnabled,
              let dockerPath, !dockerPath.isEmpty,
              !status.accountsError,
              status.accounts.count >= 2,
              !status.switching,
              !status.recoveryPending,
              canCallAgy,
              let active = status.active, !active.isEmpty,
              status.liveMatches == active else {
            return []
        }
        return status.accounts
            .sorted { $0.name < $1.name }
            .compactMap { account -> AgyContainerTarget? in
                guard account.name != active,
                      !account.invalid,
                      AgySwapUsageCache.isValidAccountName(account.name),
                      let container = containerMap[account.name] else {
                    return nil
                }
                return AgyContainerTarget(account: account.name, container: container)
            }
    }

    /// 容器額度寫入磁碟快取前的全條件檢查（規格 8.2）。
    static func shouldWriteContainerCache(
        account: String,
        container: String,
        fetchResult: Agy2QuotaStatus,
        preGen: Int,
        postStatus: AgySwapStatus?,
        readAt: Date,
        existingCache: AgySwapUsageCacheEntry?
    ) -> Bool {
        guard case .available(let buckets) = fetchResult,
              !buckets.isEmpty,
              AgySwapUsageCache.isValidAccountName(account),
              account.lowercased() != "unknown",
              AgyContainerMap.isValidContainerName(container),
              let postStatus,
              !postStatus.accountsError,
              !postStatus.switching,
              !postStatus.recoveryPending,
              postStatus.gen == preGen,
              postStatus.active != account,
              postStatus.liveMatches != account,
              let statusAccount = postStatus.accounts.first(where: { $0.name == account }),
              !statusAccount.invalid else {
            return false
        }
        if let existingCache, existingCache.readAt > readAt {
            return false
        }
        return true
    }
}
