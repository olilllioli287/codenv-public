import Foundation
import Darwin

// MARK: - agy-swap 多帳號額度快取與顯示組裝
// 快取檔格式（規格 3 A）：
//   {"account":"A","read_at":"<ISO8601 UTC>","pools":[{"name":"…","remaining_percent":N,"reset_at":"<ISO8601 UTC 或 null>"}]}
// 正式路徑：~/.local/state/agy-swap/usage-<A>.json
// 測試路徑：<state-dir>/agy-swap/state/usage-<A>.json
// 權限 0600、原子寫入（暫存檔 + rename）；絕不存憑證、不存已格式化的重置時間字串。

struct AgySwapAnFileInfo: Equatable {
    let account: String
    let gen: Int
}

struct AgySwapCachedPool: Equatable {
    let name: String
    let remainingPercent: Int
    let resetAt: Date?
}

struct AgySwapUsageCacheEntry: Equatable {
    let account: String
    let readAt: Date
    let pools: [AgySwapCachedPool]
    let source: String?

    init(account: String, readAt: Date, pools: [AgySwapCachedPool], source: String? = nil) {
        self.account = account
        self.readAt = readAt
        self.pools = pools
        self.source = source
    }

    func toUsageBuckets() -> [UsageBucket] {
        pools.map { pool in
            let clamped = max(0, min(100, pool.remainingPercent))
            let resets = pool.resetAt.map(UsageMonitor.when) ?? ""
            return UsageBucket(
                label: pool.name,
                used: 100 - clamped,
                resets: resets,
                resetAt: pool.resetAt
            )
        }
    }
}

enum AgySwapAccountState: String, Equatable {
    case live
    case cached
    case never
    case invalid
}

struct AgySwapAccountDisplay: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let isActive: Bool
    let state: AgySwapAccountState
    let readAt: Date?
    let ageText: String
    let buckets: [UsageBucket]
    let source: String?
    let containerStatus: AgyContainerAccountStatus?

    init(
        name: String,
        isActive: Bool,
        state: AgySwapAccountState,
        readAt: Date?,
        ageText: String,
        buckets: [UsageBucket],
        source: String? = nil,
        containerStatus: AgyContainerAccountStatus? = nil
    ) {
        self.name = name
        self.isActive = isActive
        self.state = state
        self.readAt = readAt
        self.ageText = ageText
        self.buckets = buckets
        self.source = source
        self.containerStatus = containerStatus
    }
}

enum AgySwapUsageCache {
    /// 帳號名必須符合 [A-Za-z0-9_-]{1,32}（防止路徑穿越與非法字元）。
    static func isValidAccountName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard (1...32).contains(scalars.count) else { return false }
        for scalar in scalars {
            let v = scalar.value
            let ok = (v >= 0x30 && v <= 0x39)      // 0-9
                || (v >= 0x41 && v <= 0x5A)        // A-Z
                || (v >= 0x61 && v <= 0x7A)        // a-z
                || v == 0x5F                       // _
                || v == 0x2D                       // -
            if !ok { return false }
        }
        return true
    }

    static func formatISO8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseISO8601(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    // MARK: - an-file 暫存檔（0600 + UUID）

    /// 在系統暫存目錄建立權限 0600、檔名含 UUID 的 an-file；呼叫端必須以 defer 刪除。
    static func createAnFile(in directory: URL = FileManager.default.temporaryDirectory) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("codenv-agyswap-an-\(UUID().uuidString).txt")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        _ = Darwin.close(fd)
        return url
    }

    /// 解析 an-file 內容：一行 `<帳號> <gen>\n`。
    static func parseAnFile(content: String) -> AgySwapAnFileInfo? {
        guard let firstLine = content
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, let gen = Int(parts[1]) else { return nil }
        return AgySwapAnFileInfo(account: parts[0], gen: gen)
    }

    static func parseAnFile(at url: URL) -> AgySwapAnFileInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseAnFile(content: text)
    }

    // MARK: - 快取寫入條件判定（規格 3 A）

    /// 檢查全部寫快取條件；全部成立時回傳可寫入的帳號名 A，否則回傳 nil（不寫、不覆蓋舊快取）。
    static func shouldWriteCache(
        execResult: AgySwapExecResult,
        parsedBuckets: [UsageBucket],
        anInfo: AgySwapAnFileInfo?,
        postStatus: AgySwapStatus?
    ) -> String? {
        guard execResult.launched,
              !execResult.weTerminated,
              !execResult.outputTruncated,
              execResult.exitCode == 0,
              !parsedBuckets.isEmpty,
              let anInfo,
              anInfo.account.lowercased() != "unknown",
              isValidAccountName(anInfo.account),
              let postStatus,
              !postStatus.accountsError,
              !postStatus.switching,
              !postStatus.recoveryPending,
              postStatus.gen == anInfo.gen,
              postStatus.liveMatches == anInfo.account,
              postStatus.accounts.contains(where: { $0.name == anInfo.account }) else {
            return nil
        }
        return anInfo.account
    }

    // MARK: - 快取檔讀寫（0600 原子寫入）

    static func cacheFileURL(account: String, stateDir: URL) -> URL? {
        guard isValidAccountName(account) else { return nil }
        return stateDir.appendingPathComponent("usage-\(account).json")
    }

    static func serialize(account: String, readAt: Date, buckets: [UsageBucket], source: String? = nil) -> Data? {
        guard isValidAccountName(account), !buckets.isEmpty else { return nil }
        let pools: [[String: Any]] = buckets.map { bucket in
            [
                "name": bucket.label,
                "remaining_percent": max(0, min(100, bucket.remaining)),
                "reset_at": bucket.resetAt.map(formatISO8601UTC) ?? NSNull(),
            ]
        }
        var payload: [String: Any] = [
            "account": account,
            "read_at": formatISO8601UTC(readAt),
            "pools": pools,
        ]
        if let source, let validSource = AgyContainerUsage.validatedCacheSource(source) {
            payload["source"] = validSource
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func parse(data: Data, expectedAccount: String? = nil) -> AgySwapUsageCacheEntry? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["account"] as? String,
              isValidAccountName(account),
              let readAtRaw = root["read_at"] as? String,
              let readAt = parseISO8601(readAtRaw),
              let rawPools = root["pools"] as? [[String: Any]],
              !rawPools.isEmpty else {
            return nil
        }
        if let expectedAccount, account != expectedAccount {
            return nil
        }
        // source 為選填：缺少、型別錯誤或格式不認識一律忽略為 nil，絕不丟掉整個快取檔。
        let parsedSource: String?
        if let rawSource = root["source"] as? String {
            parsedSource = AgyContainerUsage.validatedCacheSource(rawSource)
        } else {
            parsedSource = nil
        }
        var pools: [AgySwapCachedPool] = []
        for item in rawPools {
            guard let name = item["name"] as? String, !name.isEmpty,
                  let num = item["remaining_percent"] as? NSNumber,
                  CFGetTypeID(num) != CFBooleanGetTypeID() else {
                return nil
            }
            let doubleVal = num.doubleValue
            guard doubleVal.isFinite, doubleVal == floor(doubleVal) else { return nil }
            let pct = num.intValue
            guard (0...100).contains(pct) else { return nil }

            let resetAt: Date?
            if let rawReset = item["reset_at"] {
                if rawReset is NSNull {
                    resetAt = nil
                } else if let str = rawReset as? String {
                    guard let parsedDate = parseISO8601(str) else { return nil }
                    resetAt = parsedDate
                } else {
                    return nil
                }
            } else {
                resetAt = nil
            }
            pools.append(AgySwapCachedPool(name: name, remainingPercent: pct, resetAt: resetAt))
        }
        guard !pools.isEmpty else { return nil }
        return AgySwapUsageCacheEntry(account: account, readAt: readAt, pools: pools, source: parsedSource)
    }

    /// 將整段 bytes 寫入寫入函式；回傳 `< 0`（非 EINTR）或 `0`（避免空轉）皆視為失敗。
    static func writeAllBytes(
        _ data: Data,
        writer: (UnsafeRawPointer, Int) -> Int
    ) -> Bool {
        var writeOK = true
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let n = writer(base.advanced(by: written), rawBuffer.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    writeOK = false
                    break
                }
                if n == 0 {
                    writeOK = false
                    break
                }
                written += n
            }
        }
        return writeOK
    }

    /// 以權限 0600 寫入暫存檔後原子 rename 至目標路徑。
    @discardableResult
    static func write(account: String, readAt: Date, buckets: [UsageBucket], stateDir: URL, source: String? = nil) -> Bool {
        guard let targetURL = cacheFileURL(account: account, stateDir: stateDir),
              let data = serialize(account: account, readAt: readAt, buckets: buckets, source: source) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let tempURL = stateDir.appendingPathComponent(".usage-\(account).\(UUID().uuidString).tmp")
        let fd = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }

        let writeOK = writeAllBytes(data) { ptr, count in
            Darwin.write(fd, ptr, count)
        }
        if writeOK {
            _ = Darwin.fsync(fd)
        }
        _ = Darwin.close(fd)

        guard writeOK else {
            _ = Darwin.unlink(tempURL.path)
            return false
        }
        if Darwin.rename(tempURL.path, targetURL.path) != 0 {
            _ = Darwin.unlink(tempURL.path)
            return false
        }
        return true
    }

    static func read(account: String, stateDir: URL) -> AgySwapUsageCacheEntry? {
        guard let url = cacheFileURL(account: account, stateDir: stateDir),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data: data, expectedAccount: account)
    }

    /// 掃描快取目錄中合法且可解析的 `usage-<account>.json`（帳號名須符合 `[A-Za-z0-9_-]{1,32}`），依帳號名排序。
    static func scanDiskCache(stateDir: URL) -> [AgySwapUsageCacheEntry] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir.path) else {
            return []
        }
        var entries: [AgySwapUsageCacheEntry] = []
        for file in files {
            guard file.hasPrefix("usage-"), file.hasSuffix(".json") else { continue }
            let start = file.index(file.startIndex, offsetBy: "usage-".count)
            let end = file.index(file.endIndex, offsetBy: -".json".count)
            guard start < end else { continue }
            let accountName = String(file[start..<end])
            guard isValidAccountName(accountName) else { continue }
            if let entry = read(account: accountName, stateDir: stateDir) {
                entries.append(entry)
            }
        }
        return entries.sorted { $0.account < $1.account }
    }

    /// 由磁碟快取掃描結果組出顯示清單（現用帳號未知時全部標為 `.cached`、`isActive = false`，`ageText` 用 `read_at`）。
    static func buildDisplayAccountsFromCacheScan(
        entries: [AgySwapUsageCacheEntry],
        containerStatuses: [String: AgyContainerAccountStatus] = [:],
        now: Date = Date()
    ) -> [AgySwapAccountDisplay] {
        entries
            .sorted { $0.account < $1.account }
            .compactMap { entry in
                let buckets = entry.toUsageBuckets()
                guard !buckets.isEmpty else { return nil }
                return AgySwapAccountDisplay(
                    name: entry.account,
                    isActive: false,
                    state: .cached,
                    readAt: entry.readAt,
                    ageText: formatAgeText(readAt: entry.readAt, now: now),
                    buckets: buckets,
                    source: entry.source,
                    containerStatus: containerStatuses[entry.account]
                )
            }
    }

    // MARK: - 顯示資料組裝（規格 3 B）

    /// 依快取 JSON 的 `read_at` 計算相對時間文字（不使用檔案 mtime）：
    /// <1 分鐘或未來時間 → 「剛剛」；1～60 分鐘 → 「N 分鐘前」；>60 分鐘 → 「N 小時前」。
    static func formatAgeText(readAt: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(readAt)
        if delta < 60 { return L("剛剛") }
        if delta > 3600 {
            let hours = max(1, Int(delta / 3600))
            return L("\(hours) 小時前")
        }
        let minutes = max(1, Int(delta / 60))
        return L("\(minutes) 分鐘前")
    }

    /// 依 status、本輪即時讀取結果（若有）、與磁碟快取組裝多帳號顯示清單（依帳號名排序）。
    /// - 失效（`invalid == true`）：只顯示「登入失效」，不混舊百分比（即使磁碟有舊快取）。
    /// - `verify_failures == 1` 且 `invalid == false`：不標失效。
    /// - 切換後新現用沒有即時資料時，只看新現用自己的磁碟快取（沒有即「還沒讀過」），絕不拿前一帳號數字。
    /// - 容器本輪即時讀到且已寫入磁碟快取的帳號（`containerLive`）：數字仍自 `cacheLoader`（磁碟快取）讀取，狀態標 `.live`。
    static func buildDisplayAccounts(
        status: AgySwapStatus,
        liveAccount: String?,
        liveBuckets: [UsageBucket]?,
        liveReadAt: Date?,
        containerLive: [String: (readAt: Date, container: String)] = [:],
        containerStatuses: [String: AgyContainerAccountStatus] = [:],
        cacheLoader: (String) -> AgySwapUsageCacheEntry?,
        now: Date = Date()
    ) -> [AgySwapAccountDisplay] {
        let sorted = status.accounts.sorted { $0.name < $1.name }
        let knownNames = Set(sorted.map(\.name))
        let activeName: String?
        if let lm = status.liveMatches, knownNames.contains(lm) {
            activeName = lm
        } else if let act = status.active, knownNames.contains(act) {
            activeName = act
        } else {
            activeName = nil
        }

        return sorted.map { account in
            let isActive = (account.name == activeName)
            let cStatus = containerStatuses[account.name]
            if account.invalid {
                return AgySwapAccountDisplay(
                    name: account.name,
                    isActive: isActive,
                    state: .invalid,
                    readAt: nil,
                    ageText: L("登入失效"),
                    buckets: [],
                    source: nil,
                    containerStatus: cStatus
                )
            }
            if let liveAccount, liveAccount == account.name,
               let liveBuckets, !liveBuckets.isEmpty {
                let readAt = liveReadAt ?? now
                return AgySwapAccountDisplay(
                    name: account.name,
                    isActive: isActive,
                    state: .live,
                    readAt: readAt,
                    ageText: formatAgeText(readAt: readAt, now: now),
                    buckets: liveBuckets,
                    source: "mac",
                    containerStatus: cStatus
                )
            }
            if let freshContainer = containerLive[account.name],
               let cached = cacheLoader(account.name) {
                let buckets = cached.toUsageBuckets()
                if !buckets.isEmpty {
                    return AgySwapAccountDisplay(
                        name: account.name,
                        isActive: isActive,
                        state: .live,
                        readAt: cached.readAt,
                        ageText: formatAgeText(readAt: cached.readAt, now: now),
                        buckets: buckets,
                        source: cached.source ?? "container:\(freshContainer.container)",
                        containerStatus: cStatus
                    )
                }
            }
            if let cached = cacheLoader(account.name) {
                let buckets = cached.toUsageBuckets()
                if !buckets.isEmpty {
                    return AgySwapAccountDisplay(
                        name: account.name,
                        isActive: isActive,
                        state: .cached,
                        readAt: cached.readAt,
                        ageText: formatAgeText(readAt: cached.readAt, now: now),
                        buckets: buckets,
                        source: cached.source,
                        containerStatus: cStatus
                    )
                }
            }
            return AgySwapAccountDisplay(
                name: account.name,
                isActive: isActive,
                state: .never,
                readAt: nil,
                ageText: L("還沒讀過"),
                buckets: [],
                source: nil,
                containerStatus: cStatus
            )
        }
    }
}
