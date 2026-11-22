import Foundation
import CoreFoundation

// 用量面板的免費池卡片（OpenRouter、Groq、Kaggle、NVIDIA、AI Studio、OpenCode）。
// 金鑰只在讀到後直接送出請求，不寫進紀錄、畫面、狀態或測試輸出。
// 測試實例（KeyVault.isTestInstance）不連網、不查正式鑰匙圈：用 CODENV_EXTRA_KEY_FAKE=<JSON 檔> 的假資料。

/// 共用免費池計數檔；格式見 audit/2026-11-10/pool-usage格式.md。
struct PoolUsageSnapshot {
    let pools: [String: [String: Any]]

    init(data: Data?) {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPools = root["pools"] as? [String: Any] else {
            pools = [:]
            return
        }
        pools = rawPools.reduce(into: [:]) { result, pair in
            if let row = pair.value as? [String: Any] { result[pair.key] = row }
        }
    }

    init(pools: [String: [String: Any]]) { self.pools = pools }
    static let empty = PoolUsageSnapshot(pools: [:])

    static func fileURL(arguments: [String] = CommandLine.arguments,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment["CODENV_POOL_USAGE_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let index = arguments.firstIndex(of: "--state-dir"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).appendingPathComponent("pool-usage.json")
        }
        return Edition.support("pool-usage.json")
    }

    static func load(arguments: [String] = CommandLine.arguments,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> PoolUsageSnapshot {
        guard let url = fileURL(arguments: arguments, environment: environment) else { return .empty }
        return PoolUsageSnapshot(data: try? Data(contentsOf: url))
    }

    func row(_ pool: String) -> [String: Any]? { pools[pool] }
    func string(_ key: String, in row: [String: Any]?) -> String? {
        guard let value = row?[key] else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }
    func number(_ key: String, in row: [String: Any]?) -> Double? {
        guard let value = row?[key] else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
    func callsToday(_ pool: String, now: Date) -> Int? {
        guard let row = row(pool), let calls = number("calls_today", in: row), calls.isFinite, calls >= 0,
              let day = string("day", in: row) else { return nil }
        return day == Self.localDay(now) ? Int(calls) : 0
    }
    func date(_ key: String, in row: [String: Any]?) -> Date? {
        guard let raw = string(key, in: row) else { return nil }
        return Self.parseISODate(raw)
    }

    static func parseISODate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }()
    }
    static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    static func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

struct KaggleQuotaLine: Codable, Identifiable {
    let resource: String
    let remaining: Double
    let total: Double
    let refreshAt: Date?
    var id: String { resource }
}

/// Kaggle 週額度最多每 30 分鐘查一次；只把解析後的數字存入快取。
final class KaggleQuotaCache {
    static let ttl: TimeInterval = 30 * 60
    private struct Entry: Codable {
        let timestamp: Date
        let rows: [KaggleQuotaLine]
        let error: String?
    }
    struct Result {
        let rows: [KaggleQuotaLine]
        let error: String?
        let timestamp: Date?
        let cached: Bool
    }
    private let condition = NSCondition()
    private let fileURL: URL?
    private var entry: Entry?
    private var inFlight = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Entry.self, from: data) { entry = decoded }
    }

    static func defaultFileURL(arguments: [String] = CommandLine.arguments) -> URL? {
        if let index = arguments.firstIndex(of: "--state-dir"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).appendingPathComponent("kaggle-quota-cache.json")
        }
        return Edition.support("kaggle-quota-cache.json")
    }

    func getOrFetch(now: Date, fetch: () -> (Data?, String?)) -> Result {
        condition.lock()
        while inFlight { condition.wait() }
        if let entry, now.timeIntervalSince(entry.timestamp) >= 0, now.timeIntervalSince(entry.timestamp) < Self.ttl {
            let result = Result(rows: entry.rows, error: entry.error, timestamp: entry.timestamp, cached: true)
            condition.unlock()
            return result
        }
        inFlight = true
        condition.unlock()

        let fetched = fetch()
        let rows = fetched.0.flatMap(ExtraKeyPools.parseKaggleQuota) ?? []
        let error = rows.isEmpty ? (fetched.1 ?? (fetched.0 == nil ? "查詢失敗" : "quota 輸出格式錯誤")) : nil
        let next = Entry(timestamp: now, rows: rows, error: error)

        condition.lock()
        entry = next
        persist(next)
        inFlight = false
        condition.broadcast()
        condition.unlock()
        return Result(rows: rows, error: error, timestamp: now, cached: false)
    }

    private func persist(_ entry: Entry) {
        guard let fileURL, let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch { }
    }
}

/// Qwen 本機帳本讀取結果：區分「檔案不存在」「存在但讀不到」「讀到原始資料」。
enum QwenLedgerRead: Equatable {
    case missing
    case unreadable
    case data(Data)
}

/// DeepSeek `/user/balance` 回應解析結果。
enum DeepSeekBalanceParseResult: Equatable {
    case available(notes: [String])
    case unavailable
}

/// DeepSeek 查詢錯誤類別：只保留類別與狀態碼，絕不攜帶金鑰、原始網址、標頭或回應內文。
enum DeepSeekFetchError: Equatable {
    case timeout
    case cancelled
    case httpStatus(Int)
    case networkError
    case invalidResponse
    case disabled

    var category: String {
        switch self {
        case .timeout: return "逾時"
        case .cancelled: return "已取消"
        case .httpStatus(let code): return "HTTP \(code)"
        case .networkError: return "連線失敗"
        case .invalidResponse: return "回應格式錯誤"
        case .disabled: return "測試實例未設定本機伺服器"
        }
    }
}

struct DeepSeekFetchResult: Equatable {
    let data: Data?
    let error: DeepSeekFetchError?
    var errorCategory: String? { error?.category }
}

/// 禁止 DeepSeek 餘額請求跟隨 HTTP 重導向，避免 Authorization 標頭外流或跳離 localhost。
private final class DeepSeekNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// 取得資料的來源。正式版連官方；測試版換成假的，解析與卡片邏輯走同一條路。
struct ExtraKeySources {
    var readKey: (String) -> KeyVault.Read          // 參數是服務 id（openrouter／groq／deepseek）
    var hasKey: (String) -> Bool                    // 只查鑰匙圈屬性，不讀金鑰本體
    var fetchOpenRouter: (String) -> Data?          // GET /api/v1/key 的回應本體
    var fetchGroq: (String) -> [String: String]?    // 最小 chat completion 的回應標頭（小寫）
    var fetchDeepSeek: (String) -> Data?            // GET /user/balance 的回應本體
    var fetchKaggleQuota: () -> (Data?, String?)    // stdout 與安全的錯誤類別；不保留 stderr
    var fetchQwenLedger: () -> QwenLedgerRead       // ~/.local/state/qwenapi/ledger.json 讀取結果
    var localEstimate: (String) -> [UsageBucket]
    var poolUsage: PoolUsageSnapshot
    var now: () -> Date

    static let denied = "沒權限讀金鑰（鑰匙圈）"

    /// 從假回應 JSON 組出來源：
    /// {"openrouter": {"key": "value|missing|denied", "response": {…}},
    ///  "groq": {"key": "…", "headers": {…}},
    ///  "deepseek": {"key": "value|missing|denied|failed|pending|<自訂假金鑰>", "response": <物件或字串>},
    ///  "qwen": {"ledger": <物件|字串>|"missing"|"unreadable"}}
    static func fake(_ root: [String: Any], poolUsage: PoolUsageSnapshot = .empty,
                     now: @escaping () -> Date = Date.init,
                     deepSeekBaseURL: URL? = nil) -> ExtraKeySources {
        func spec(_ id: String) -> [String: Any]? { root[id] as? [String: Any] }
        return ExtraKeySources(
            readKey: { id in
                guard let s = spec(id) else { return .missing }
                switch (s["key"] as? String) ?? "value" {
                case "missing": return .missing
                case "denied": return .denied(-128)
                case "failed": return .failed(-25291)
                case "pending": return .pending
                case "value", "": return .value("fake-\(id)-test-key")
                case let custom: return .value(custom)
                }
            },
            hasKey: { id in
                guard let key = spec(id)?["key"] as? String else { return false }
                return key != "missing" && key != "denied" && key != "failed" && key != "pending" && !key.isEmpty
            },
            fetchOpenRouter: { _ in
                (spec("openrouter")?["response"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            },
            fetchGroq: { _ in
                (spec("groq")?["headers"] as? [String: Any]).map { h in
                    Dictionary(uniqueKeysWithValues: h.map { ($0.key.lowercased(), "\($0.value)") })
                }
            },
            fetchDeepSeek: { token in
                if let deepSeekBaseURL {
                    return ExtraKeyPools.fetchDeepSeekBalance(key: token, baseURL: deepSeekBaseURL).data
                }
                guard let response = spec("deepseek")?["response"], !(response is NSNull) else { return nil }
                if let raw = response as? String { return Data(raw.utf8) }
                guard JSONSerialization.isValidJSONObject(response) else { return nil }
                return try? JSONSerialization.data(withJSONObject: response)
            },
            fetchKaggleQuota: {
                guard let quota = spec("kaggle")?["quota"] else { return (nil, "假 quota 缺失") }
                if let raw = quota as? String { return (Data(raw.utf8), nil) }
                guard JSONSerialization.isValidJSONObject(quota), let data = try? JSONSerialization.data(withJSONObject: quota) else {
                    return (nil, "假 quota 格式錯誤")
                }
                return (data, nil)
            },
            fetchQwenLedger: {
                guard let ledger = spec("qwen")?["ledger"], !(ledger is NSNull) else { return .missing }
                if let raw = ledger as? String {
                    switch raw {
                    case "missing": return .missing
                    case "unreadable": return .unreadable
                    default: return .data(Data(raw.utf8))
                    }
                }
                guard JSONSerialization.isValidJSONObject(ledger),
                      let data = try? JSONSerialization.data(withJSONObject: ledger) else {
                    return .unreadable
                }
                return .data(data)
            },
            localEstimate: { _ in [] },
            poolUsage: poolUsage,
            now: now)
    }

    /// 測試實例沒給假回應：不讀任何鑰匙圈、共用用量檔、本機帳本或網路。
    static func isolatedEmpty(poolUsage: PoolUsageSnapshot = .empty,
                              now: @escaping () -> Date = Date.init) -> ExtraKeySources {
        ExtraKeySources(readKey: { _ in .missing }, hasKey: { _ in false },
                        fetchOpenRouter: { _ in nil }, fetchGroq: { _ in nil },
                        fetchDeepSeek: { _ in nil },
                        fetchKaggleQuota: { (nil, "測試未提供假 quota") },
                        fetchQwenLedger: { .missing },
                        localEstimate: { _ in [] }, poolUsage: poolUsage, now: now)
    }
}

/// Groq 探測會吃每日請求次數：成功結果持久快取 30 分鐘、失敗 10 分鐘；併發刷新共用一次探測。
final class GroqProbeCache {
    static let ttl: TimeInterval = 30 * 60
    static let failureTTL: TimeInterval = 10 * 60
    private struct Entry: Codable {
        let timestamp: TimeInterval
        let succeeded: Bool
        let rateHeaders: [String: String]
    }
    private let condition = NSCondition()
    private let fileURL: URL?
    private var entry: Entry?
    private var inFlight = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Entry.self, from: data) {
            entry = decoded
        }
    }

    static func defaultFileURL(arguments: [String] = CommandLine.arguments) -> URL? {
        if let i = arguments.firstIndex(of: "--state-dir"), i + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[i + 1], isDirectory: true).appendingPathComponent("groq-probe-cache.json")
        }
        return Edition.support("groq-probe-cache.json")
    }

    /// 快取檢查、single-flight 佔位、探測結果寫入都受同一個 condition 保護。
    func getOrFetch(now: Date, fetch: () -> [String: String]?) -> (headers: [String: String]?, cached: Bool, timestamp: Date?) {
        condition.lock()
        while inFlight { condition.wait() }
        if let entry, now.timeIntervalSince1970 >= entry.timestamp {
            let age = now.timeIntervalSince1970 - entry.timestamp
            let ttl = entry.succeeded ? Self.ttl : Self.failureTTL
            if age < ttl {
                let result = entry.succeeded ? entry.rateHeaders : nil
                condition.unlock()
                return (result, true, Date(timeIntervalSince1970: entry.timestamp))
            }
        }
        inFlight = true
        condition.unlock()

        let fetched = fetch().map(Self.rateHeadersOnly)
        let succeeded = fetched?.isEmpty == false
        let next = Entry(timestamp: now.timeIntervalSince1970, succeeded: succeeded, rateHeaders: succeeded ? fetched! : [:])

        condition.lock()
        entry = next
        persist(next)
        inFlight = false
        condition.broadcast()
        condition.unlock()
        return (succeeded ? next.rateHeaders : nil, false, Date(timeIntervalSince1970: next.timestamp))
    }

    static func rateHeadersOnly(_ headers: [String: String]) -> [String: String] {
        let allowed: Set<String> = [
            "x-ratelimit-remaining-requests", "x-ratelimit-limit-requests", "x-ratelimit-reset-requests",
            "x-ratelimit-remaining-tokens", "x-ratelimit-limit-tokens", "x-ratelimit-reset-tokens",
        ]
        return headers.reduce(into: [:]) { result, pair in
            let key = pair.key.lowercased()
            if allowed.contains(key) { result[key] = pair.value }
        }
    }

    private func persist(_ entry: Entry) {
        guard let fileURL, let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch { }
    }
}

enum ExtraKeyPools {
    static let groqCache = GroqProbeCache(fileURL: GroqProbeCache.defaultFileURL())
    static let kaggleCache = KaggleQuotaCache(fileURL: KaggleQuotaCache.defaultFileURL())

    /// 組出遠端／鑰匙圈卡片。OpenRouter／Groq／DeepSeek 需讀 key；其他服務只查鑰匙圈屬性。
    /// 純本機帳本（Qwen）走獨立的 `localPools(_:)`，不等網路逾時。
    static func pools(_ src: ExtraKeySources, groqCache: GroqProbeCache? = ExtraKeyPools.groqCache,
                      kaggleCache: KaggleQuotaCache? = ExtraKeyPools.kaggleCache) -> [ExtraKeyPool] {
        var out: [ExtraKeyPool] = []
        if let p = pool(name: "OpenRouter", id: "openrouter", src, { key in openRouterPool(key: key, src) }) { out.append(p) }
        if let p = pool(name: "Groq", id: "groq", src, { key in groqPool(key: key, src, cache: groqCache) }) { out.append(p) }
        if let p = pool(name: "DeepSeek", id: "deepseek", src, { key in deepSeekPool(key: key, src) }) { out.append(p) }
        if src.hasKey("nvidia") { out.append(nvidiaPool(src)) }
        if src.hasKey("ai_studio") { out.append(aiStudioPool(src)) }
        if src.hasKey("kaggle") { out.append(kagglePool(src, cache: kaggleCache)) }
        out.append(opencodePool(src))
        return out
    }

    /// 純本機讀取的額外卡（目前為 Qwen 帳本），在背景獨立快速執行，不阻塞也不等網路額外卡。
    static func localPools(_ src: ExtraKeySources) -> [ExtraKeyPool] {
        var out: [ExtraKeyPool] = []
        if let qwen = qwenPool(src) { out.append(qwen) }
        return out
    }

    private static func pool(name: String, id: String, _ src: ExtraKeySources, _ build: (String) -> ExtraKeyPool) -> ExtraKeyPool? {
        switch src.readKey(id) {
        case .value(let key): return build(key)
        case .missing: return nil
        case .denied: return ExtraKeyPool(name: name, source: "鑰匙圈", buckets: [], message: ExtraKeySources.denied)
        case .failed(let code): return ExtraKeyPool(name: name, source: "鑰匙圈", buckets: [], message: "讀金鑰失敗（鑰匙圈 \(code)）")
        case .pending: return ExtraKeyPool(name: name, source: "鑰匙圈", buckets: [], message: "等鑰匙圈授權中")
        }
    }

    // MARK: OpenRouter

    private static func openRouterPool(key: String, _ src: ExtraKeySources) -> ExtraKeyPool {
        if let data = src.fetchOpenRouter(key), let r = parseOpenRouter(data, now: src.now()) {
            let calls = src.poolUsage.callsToday("openrouter", now: src.now()).map { ["今天呼叫 \($0) 次（dsfree）"] } ?? []
            return ExtraKeyPool(name: "OpenRouter", source: "官方即時", buckets: r.buckets, notes: r.notes + calls)
        }
        let calls = src.poolUsage.callsToday("openrouter", now: src.now()).map { ["今天呼叫 \($0) 次（dsfree）"] } ?? []
        return ExtraKeyPool(name: "OpenRouter", source: "本機估計", buckets: src.localEstimate("openrouter"), notes: calls)
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private static func percentUsed(remaining: Double, total: Double) -> Int {
        100 - max(0, min(100, Int((remaining / total * 100).rounded())))
    }

    /// 下一個 UTC 0 點（OpenRouter 免費模型每日次數的重置時間）。
    static func nextUTCMidnight(after now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400)
    }

    /// GET /api/v1/key：免費帳號 limit=0、有 free_model_daily_requests；有花錢額度（limit>0）才列美元那行。
    static func parseOpenRouter(_ body: Data, now: Date) -> (buckets: [UsageBucket], notes: [String])? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return nil }
        var rows: [UsageBucket] = []
        var notes: [String] = []
        if let free = data["free_model_daily_requests"] as? [String: Any], let limit = num(free["limit"]), limit > 0 {
            let remaining = max(0, num(free["remaining"]) ?? (limit - (num(free["used"]) ?? 0)))
            let reset = nextUTCMidnight(after: now)
            rows.append(UsageBucket(label: "免費模型每日 剩 \(Int(remaining))／\(Int(limit)) 次",
                                    used: percentUsed(remaining: remaining, total: limit),
                                    resets: UsageMonitor.when(reset), resetAt: reset))
        }
        let paid = (num(data["limit"]) ?? 0) > 0
        if paid, let limit = num(data["limit"]) {
            let usage = num(data["usage"]) ?? 0
            rows.append(UsageBucket(label: String(format: "用量 $%.2f／$%.2f", usage, limit),
                                    used: percentUsed(remaining: limit - usage, total: limit), resets: ""))
            let dailyUsage = num(data["usage_daily"] ?? data["daily_usage"])
            let dailyLimit = num(data["limit_daily"] ?? data["daily_limit"])
            if let dailyUsage, let dailyLimit, dailyLimit > 0 {
                rows.append(UsageBucket(label: String(format: "今日 $%.2f／$%.2f", dailyUsage, dailyLimit),
                                        used: percentUsed(remaining: dailyLimit - dailyUsage, total: dailyLimit), resets: ""))
            }
        }
        // 花費摘要：付費帳號才列（免費帳號的美元數字沒意義）
        if paid || (data["is_free_tier"] as? Bool) == false {
            let spent = [("今日", "usage_daily"), ("本週", "usage_weekly"), ("本月", "usage_monthly")].compactMap { label, k in
                num(data[k]).map { String(format: "%@ $%.2f", label, $0) }
            }
            if !spent.isEmpty { notes.append("已花 " + spent.joined(separator: "　")) }
        }
        return rows.isEmpty && notes.isEmpty ? nil : (rows, notes)
    }

    // MARK: Groq

    private static func groqPool(key: String, _ src: ExtraKeySources, cache: GroqProbeCache?) -> ExtraKeyPool {
        let now = src.now()
        if let row = src.poolUsage.row("groq"), let updated = src.poolUsage.date("updated_at", in: row) {
            let age = now.timeIntervalSince(updated)
            if age >= 0 && age < GroqProbeCache.ttl {
                let headers = groqHeaders(from: row)
                let rows = parseGroq(headers, now: updated) ?? []
                let notes = src.poolUsage.callsToday("groq", now: now).map { ["今天呼叫 \($0) 次"] } ?? []
                return ExtraKeyPool(name: "Groq", source: "官方數字（\(PoolUsageSnapshot.clock(updated)) 使用時）", buckets: rows, notes: notes)
            }
        }
        let result = cache?.getOrFetch(now: now, fetch: { src.fetchGroq(key) })
        let headers = result?.headers ?? (cache == nil ? src.fetchGroq(key).map(GroqProbeCache.rateHeadersOnly) : nil)
        let probedAt = result?.timestamp ?? now
        if let headers, let rows = parseGroq(headers, now: probedAt) {
            return ExtraKeyPool(name: "Groq", source: "官方數字（\(PoolUsageSnapshot.clock(probedAt)) 探測）", buckets: rows)
        }
        return ExtraKeyPool(name: "Groq", source: "本機估計", buckets: src.localEstimate("groq"))
    }

    private static func groqHeaders(from row: [String: Any]) -> [String: String] {
        let names = [
            "remaining_requests": "x-ratelimit-remaining-requests", "limit_requests": "x-ratelimit-limit-requests",
            "reset_requests": "x-ratelimit-reset-requests", "remaining_tokens": "x-ratelimit-remaining-tokens",
            "limit_tokens": "x-ratelimit-limit-tokens", "reset_tokens": "x-ratelimit-reset-tokens",
        ]
        return names.reduce(into: [:]) { result, pair in
            if let value = row[pair.key] { result[pair.value] = String(describing: value) }
        }
    }

    private static func nvidiaPool(_ src: ExtraKeySources) -> ExtraKeyPool {
        var notes = ["無法自動查詢剩餘點數"]
        if let calls = src.poolUsage.callsToday("nvidia", now: src.now()) { notes.append("今天呼叫 \(calls) 次") }
        if let date = src.poolUsage.date("last_429_at", in: src.poolUsage.row("nvidia")) {
            notes.append("最近一次 429：\(PoolUsageSnapshot.shortDateTime(date))")
        }
        return ExtraKeyPool(name: "NVIDIA", source: "本機計數", buckets: [], notes: notes,
                            actionTitle: "開 build.nvidia.com", actionURL: "https://build.nvidia.com")
    }

    private static func aiStudioPool(_ src: ExtraKeySources) -> ExtraKeyPool {
        var notes: [String] = []
        if let calls = src.poolUsage.callsToday("gemini_free", now: src.now()) { notes.append("今天呼叫 \(calls) 次") }
        if let row = src.poolUsage.row("gemini_free"), let raw = src.poolUsage.string("last_429_at", in: row),
           let date = PoolUsageSnapshot.parseISODate(raw) {
            notes.append("最近一次 429：\(PoolUsageSnapshot.shortDateTime(date))")
            if let metric = src.poolUsage.string("last_429_metric", in: row), ["RPM", "TPM", "RPD"].contains(metric.uppercased()) {
                notes.append("超額項目：\(metric.uppercased())")
            }
        }
        if notes.isEmpty { notes.append("尚無本機呼叫紀錄") }
        return ExtraKeyPool(name: "AI Studio", source: "本機計數", buckets: [], notes: notes,
                            actionTitle: "開 AI Studio", actionURL: "https://aistudio.google.com")
    }

    private static func kagglePool(_ src: ExtraKeySources, cache: KaggleQuotaCache?) -> ExtraKeyPool {
        let result: KaggleQuotaCache.Result
        if let cache {
            result = cache.getOrFetch(now: src.now(), fetch: src.fetchKaggleQuota)
        } else {
            let fetched = src.fetchKaggleQuota()
            let rows = fetched.0.flatMap(parseKaggleQuota) ?? []
            result = KaggleQuotaCache.Result(rows: rows,
                                             error: rows.isEmpty ? (fetched.1 ?? (fetched.0 == nil ? "查詢失敗" : "quota 輸出格式錯誤")) : nil,
                                             timestamp: src.now(), cached: false)
        }
        let notes: [String]
        if !result.rows.isEmpty {
            notes = result.rows.map { row in
                let remaining = String(format: "%.2f", row.remaining)
                let total = String(format: "%.2f", row.total)
                let refresh = row.refreshAt.map { "，下次重置 \(PoolUsageSnapshot.shortDateTime($0))" } ?? ""
                return "每週 \(row.resource) 剩 \(remaining)／\(total) 小時\(refresh)"
            }
        } else {
            notes = ["查不到（\(result.error ?? "無額度資料")）"]
        }
        let at = result.timestamp.map(PoolUsageSnapshot.clock) ?? PoolUsageSnapshot.clock(src.now())
        let source = result.cached ? "官方數字（\(at) 快取）" : "官方數字（\(at) 探測）"
        return ExtraKeyPool(name: "Kaggle", source: source, buckets: [], notes: notes, kaggleQuotas: result.rows)
    }

    private static func opencodePool(_ src: ExtraKeySources) -> ExtraKeyPool {
        let row = src.poolUsage.row("opencode")
        var notes = ["官方動態上限，查不到"]
        let calls = src.poolUsage.callsToday("opencode", now: src.now()) ?? 0
        notes.append("今天呼叫 \(calls) 次")
        if let status = src.poolUsage.number("last_status", in: row), status != 0,
           let date = src.poolUsage.date("updated_at", in: row) {
            notes.append("最近失敗：\(PoolUsageSnapshot.shortDateTime(date))")
        }
        return ExtraKeyPool(name: "OpenCode 免費模型", source: "本機計數", buckets: [], notes: notes)
    }

    static func parseKaggleQuota(_ body: Data) -> [KaggleQuotaLine]? {
        guard let json = try? JSONSerialization.jsonObject(with: body) else { return nil }
        let rows = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["quotas"] as? [[String: Any]])
        guard let rows else { return nil }
        let parsed = rows.compactMap { row -> KaggleQuotaLine? in
            guard let resource = row["resource"] as? String,
                  let remaining = quotaHours(row["remaining"]),
                  let total = quotaHours(row["total"]), remaining.isFinite, total.isFinite, total > 0 else { return nil }
            let refresh = (row["refreshAt"] as? String).flatMap(PoolUsageSnapshot.parseISODate)
            return KaggleQuotaLine(resource: resource, remaining: max(0, remaining), total: total, refreshAt: refresh)
        }
        return parsed.isEmpty ? nil : parsed
    }

    private static func quotaHours(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let raw = value as? String else { return nil }
        return Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: "hH ")))
    }

    /// 只執行本機 kgl wrapper；wrapper 自己從鑰匙圈取 token，本程序不讀、不記錄 token 或 stderr。
    static func fetchKaggleQuota() -> (Data?, String?) {
        guard !KeyVault.isTestInstance else { return (nil, "測試實例未提供假 quota") }
        let executable = Edition.home.appendingPathComponent(".local/bin/kgl").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return (nil, "找不到 kgl 指令") }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["quota", "--format", "json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { return (nil, "無法執行 kgl") }
        if finished.wait(timeout: .now() + 20) != .success {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return (nil, "查詢逾時")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return (nil, "quota 指令失敗") }
        return (data, nil)
    }

    /// 標頭值（"2m59.56s"、"7.66s"、"1h2m3s"、"120ms"）轉秒數。
    static func parseDuration(_ s: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(pattern: "^(?:(?:\\d+(?:\\.\\d+)?)(?:ms|h|m|s))+$") else { return nil }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty, matches[0].range.location == 0, matches[0].range.length == ns.length,
              let parts = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)(ms|h|m|s)") else { return nil }
        let tokens = parts.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !tokens.isEmpty else { return nil }
        var total = 0.0
        for m in tokens {
            guard let v = Double(ns.substring(with: m.range(at: 1))) else { return nil }
            guard v.isFinite, v >= 0, v <= 1_000_000_000_000 else { return nil }
            switch ns.substring(with: m.range(at: 2)) {
            case "h": total += v * 3600
            case "m": total += v * 60
            case "s": total += v
            default: total += v / 1000
            }
            guard total.isFinite, total <= 10 * 365 * 86400 else { return nil }
        }
        return total
    }

    /// x-ratelimit-* 標頭（key 已轉小寫）→ 每日請求、每分鐘 token 兩列；兩組都讀不到回 nil。
    static func parseGroq(_ h: [String: String], now: Date) -> [UsageBucket]? {
        var rows: [UsageBucket] = []
        let specs: [(String, String, String, String?)] = [("每日請求", "x-ratelimit-remaining-requests", "x-ratelimit-limit-requests", "x-ratelimit-reset-requests"),
                                          ("每分鐘 token", "x-ratelimit-remaining-tokens", "x-ratelimit-limit-tokens", "x-ratelimit-reset-tokens")]
        for (title, left, cap, reset) in specs {
            guard let l = h[left].flatMap(Double.init), let c = h[cap].flatMap(Double.init),
                  l.isFinite, c.isFinite, l >= 0, c > 0, l <= 1_000_000_000_000, c <= 1_000_000_000_000 else { continue }
            let resetAt = reset.flatMap { h[$0] }.flatMap(parseDuration).map { now.addingTimeInterval($0) }
            let resetText: String
            if title == "每日請求" {
                resetText = resetAt.map { "下一次回補 \(PoolUsageSnapshot.clock($0))" } ?? ""
            } else {
                resetText = resetAt.map(UsageMonitor.when) ?? ""
            }
            rows.append(UsageBucket(label: "\(title) 剩 \(Int(max(0, l)))／\(Int(c))",
                                    used: percentUsed(remaining: max(0, l), total: c),
                                    resets: resetText, resetAt: resetAt))
        }
        return rows.isEmpty ? nil : rows
    }

    /// 探測用的最便宜模型（第一個被官方下架就換下一個）。
    static let groqProbeModels = ["openai/gpt-oss-20b", "qwen/qwen3.8-27b"]

    /// 送一次最小的 chat completion（max_tokens 1、內容 "hi"）只為了讀 x-ratelimit-* 標頭；回應內文丟掉。
    static func groqProbe(key: String) -> [String: String]? {
        guard !KeyVault.isTestInstance else { return nil }
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else { return nil }
        for model in groqProbeModels {
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "max_tokens": 1, "messages": [["role": "user", "content": "hi"]]])
            let semaphore = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var status = 0
            var headers: [String: String] = [:]
            let task = URLSession.shared.dataTask(with: request) { _, response, _ in
                var responseStatus = 0
                var responseHeaders: [String: String] = [:]
                if let http = response as? HTTPURLResponse {
                    responseStatus = http.statusCode
                    responseHeaders = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { k, v in
                        guard let k = k as? String, let v = v as? String else { return nil }; return (k.lowercased(), v)
                    })
                }
                resultLock.lock()
                status = responseStatus
                headers = responseHeaders
                resultLock.unlock()
                semaphore.signal()
            }
            task.resume()
            guard semaphore.wait(timeout: .now() + 13) == .success else {
                task.cancel()
                return nil
            }
            resultLock.lock()
            let responseStatus = status
            let responseHeaders = headers
            resultLock.unlock()
            if responseHeaders["x-ratelimit-remaining-requests"] != nil { return responseHeaders } // 200 或 429 都帶標頭
            if responseStatus == 400 || responseStatus == 404 { continue }              // 模型不存在：換下一個
            return nil
        }
        return nil
    }

    // MARK: DeepSeek

    static let officialDeepSeekBaseURL = URL(string: "https://api.deepseek.com")!
    static let deepSeekTimeout: TimeInterval = 8
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// 解析測試實例的 `--deepseek-base-url`：只在帶 `--state-dir` 時啟用，且僅接受 `127.0.0.1` 或 `localhost`。
    static func deepSeekTestBaseURL(arguments: [String] = CommandLine.arguments) -> URL? {
        guard let stateIndex = arguments.firstIndex(of: "--state-dir"),
              stateIndex + 1 < arguments.count,
              !arguments[stateIndex + 1].isEmpty,
              !arguments[stateIndex + 1].hasPrefix("--") else {
            return nil
        }
        guard let flagIndex = arguments.firstIndex(of: "--deepseek-base-url"),
              flagIndex + 1 < arguments.count else {
            return nil
        }
        let raw = arguments[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        if let port = components.port, !(1...65535).contains(port) {
            return nil
        }
        var sanitized = URLComponents()
        sanitized.scheme = scheme
        sanitized.host = host
        sanitized.port = components.port
        return sanitized.url
    }

    /// 決定 DeepSeek base URL：正式版固定官方網址（忽略旗標）；測試實例預設 nil（不連網），只認本機 `--deepseek-base-url`。
    static func deepSeekBaseURL(arguments: [String] = CommandLine.arguments) -> URL? {
        if arguments.contains("--state-dir") {
            return deepSeekTestBaseURL(arguments: arguments)
        }
        return officialDeepSeekBaseURL
    }

    /// 組合固定路徑 `/user/balance` 的完整端點 URL。
    static func deepSeekEndpointURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.path = "/user/balance"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// DeepSeek 獨立餘額查詢：8 秒逾時、可取消、鎖保護結果、金鑰只放 Authorization header、不重試、不快取、不記 log。
    static func fetchDeepSeekBalance(
        key token: String,
        baseURL: URL?,
        timeout: TimeInterval = deepSeekTimeout,
        sessionConfiguration: URLSessionConfiguration? = nil,
        onTask: ((URLSessionDataTask) -> Void)? = nil
    ) -> DeepSeekFetchResult {
        guard !token.isEmpty else { return DeepSeekFetchResult(data: nil, error: .invalidResponse) }
        guard let baseURL, let endpoint = deepSeekEndpointURL(baseURL: baseURL) else {
            return DeepSeekFetchResult(data: nil, error: .disabled)
        }
        let config: URLSessionConfiguration
        if let sessionConfiguration {
            config = sessionConfiguration
        } else {
            config = .ephemeral
            config.urlCache = nil
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.waitsForConnectivity = false
        }
        let effectiveTimeout = max(0.05, timeout)
        config.timeoutIntervalForRequest = effectiveTimeout
        config.timeoutIntervalForResource = effectiveTimeout

        let delegate = DeepSeekNoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: endpoint, timeoutInterval: effectiveTimeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var receivedData: Data?
        var fetchError: DeepSeekFetchError?

        let task = session.dataTask(with: request) { data, response, error in
            var localData: Data?
            var localError: DeepSeekFetchError?
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    localError = .timeout
                case .cancelled:
                    localError = .cancelled
                default:
                    localError = .networkError
                }
            } else if error != nil {
                localError = .networkError
            } else if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    if let data, !data.isEmpty {
                        localData = data
                    } else {
                        localError = .invalidResponse
                    }
                } else {
                    localError = .httpStatus(http.statusCode)
                }
            } else {
                localError = .invalidResponse
            }
            resultLock.lock()
            receivedData = localData
            fetchError = localError
            resultLock.unlock()
            semaphore.signal()
        }
        onTask?(task)
        task.resume()

        if semaphore.wait(timeout: .now() + effectiveTimeout) != .success {
            task.cancel()
            session.invalidateAndCancel()
            return DeepSeekFetchResult(data: nil, error: .timeout)
        }
        session.finishTasksAndInvalidate()
        resultLock.lock()
        let finalData = receivedData
        let finalError = fetchError
        resultLock.unlock()
        return DeepSeekFetchResult(data: finalData, error: finalError)
    }

    static func deepSeekFetch(
        key token: String,
        arguments: [String] = CommandLine.arguments,
        timeout: TimeInterval = deepSeekTimeout,
        sessionConfiguration: URLSessionConfiguration? = nil,
        onTask: ((URLSessionDataTask) -> Void)? = nil
    ) -> Data? {
        guard let baseURL = deepSeekBaseURL(arguments: arguments) else { return nil }
        return fetchDeepSeekBalance(
            key: token,
            baseURL: baseURL,
            timeout: timeout,
            sessionConfiguration: sessionConfiguration,
            onTask: onTask
        ).data
    }

    private static func jsonBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func jsonFiniteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        return d.isFinite ? d : nil
    }

    private static func deepSeekAmount(_ value: Any?) -> String? {
        let numeric: Double
        if let d = jsonFiniteNumber(value) {
            numeric = d
        } else if let raw = value as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let d = Double(trimmed), d.isFinite else { return nil }
            numeric = d
        } else {
            return nil
        }
        let normalized = abs(numeric) < 0.0005 ? 0.0 : numeric
        return String(format: "%.2f", locale: posixLocale, normalized)
    }

    /// 解析 DeepSeek `GET /user/balance` 回應：金額欄位同時接受字串或數字。
    static func parseDeepSeek(_ body: Data) -> DeepSeekBalanceParseResult? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let isAvailable = jsonBool(root["is_available"]) else {
            return nil
        }
        if !isAvailable {
            return .unavailable
        }
        guard let infos = root["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
            return nil
        }
        var notes: [String] = []
        for info in infos {
            guard let rawCurrency = info["currency"] as? String else { return nil }
            let currency = rawCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !currency.isEmpty,
                  let total = deepSeekAmount(info["total_balance"]),
                  let toppedUp = deepSeekAmount(info["topped_up_balance"]),
                  let granted = deepSeekAmount(info["granted_balance"]) else {
                return nil
            }
            notes.append("餘額 \(total) \(currency)（儲值 \(toppedUp)＋贈送 \(granted)）")
        }
        return notes.isEmpty ? nil : .available(notes: notes)
    }

    static func deepSeekPool(key token: String, _ src: ExtraKeySources) -> ExtraKeyPool {
        guard let data = src.fetchDeepSeek(token), let parsed = parseDeepSeek(data) else {
            return ExtraKeyPool(name: "DeepSeek", source: "DeepSeek 官方 API", buckets: [], message: "查不到餘額")
        }
        switch parsed {
        case .available(let notes):
            return ExtraKeyPool(name: "DeepSeek", source: "DeepSeek 官方 API", buckets: [], notes: notes)
        case .unavailable:
            return ExtraKeyPool(name: "DeepSeek", source: "DeepSeek 官方 API", buckets: [], message: "帳戶餘額不足，無法呼叫")
        }
    }

    // MARK: Qwen（本機帳本）

    static func defaultQwenLedgerURL(home: URL = Edition.home) -> URL {
        home.appendingPathComponent(".local/state/qwenapi/ledger.json")
    }

    /// 讀取指定路徑的 Qwen 帳本檔，區分「不存在」與「存在但讀不到」。
    static func readQwenLedgerFile(at url: URL) -> QwenLedgerRead {
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return .missing
            }
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
                return .missing
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT) {
                return .missing
            }
            return .unreadable
        }
    }

    /// 正式版讀固定路徑 `~/.local/state/qwenapi/ledger.json`；測試實例沒給假資料一律 `.missing`。
    static func fetchQwenLedger(
        arguments: [String] = CommandLine.arguments,
        url: URL = defaultQwenLedgerURL()
    ) -> QwenLedgerRead {
        guard !KeyVault.isTestInstance(arguments) else { return .missing }
        return readQwenLedgerFile(at: url)
    }

    /// 驗證並格式化 Qwen 帳本數值：只接受有限數、`cap_usd > 0`、`spent_usd >= 0`、`callCount >= 0`；允許 `spent > cap`。
    static func formatQwenNotes(spentUSD: Double, capUSD: Double, callCount: Int) -> [String]? {
        guard spentUSD.isFinite, capUSD.isFinite, spentUSD >= 0, capUSD > 0, callCount >= 0 else {
            return nil
        }
        let spentText = String(format: "%.2f", locale: posixLocale, spentUSD == 0 ? 0 : spentUSD)
        let capText = String(format: "%.2f", locale: posixLocale, capUSD)
        return [
            "已花 \(spentText)／\(capText) USD（本機上限，非帳戶餘額）",
            "\(callCount) 次呼叫",
        ]
    }

    /// 只解析 `spent_usd`、`cap_usd`、`calls` 筆數三個欄位，不讀、不保留每筆呼叫內容。
    static func parseQwenLedger(_ body: Data) -> (spentUSD: Double, capUSD: Double, callCount: Int)? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let spent = jsonFiniteNumber(root["spent_usd"]),
              let cap = jsonFiniteNumber(root["cap_usd"]),
              let calls = root["calls"] as? [Any],
              spent >= 0, cap > 0 else {
            return nil
        }
        return (spent, cap, calls.count)
    }

    static func qwenPool(_ src: ExtraKeySources) -> ExtraKeyPool? {
        switch src.fetchQwenLedger() {
        case .missing:
            return nil
        case .unreadable:
            return ExtraKeyPool(name: "Qwen", source: "本機帳本", buckets: [], message: "查不到帳本")
        case .data(let data):
            guard let parsed = parseQwenLedger(data),
                  let notes = formatQwenNotes(spentUSD: parsed.spentUSD, capUSD: parsed.capUSD, callCount: parsed.callCount) else {
                return ExtraKeyPool(name: "Qwen", source: "本機帳本", buckets: [], message: "查不到帳本")
            }
            return ExtraKeyPool(name: "Qwen", source: "本機帳本", buckets: [], notes: notes)
        }
    }
}
