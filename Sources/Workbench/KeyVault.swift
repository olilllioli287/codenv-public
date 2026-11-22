import Foundation
import Security
import CryptoKit

// 金鑰管理核心（只靠 Foundation＋Security，scripts/exam/keyvault 會單獨編起來測）。
// 一、鑰匙圈：一律登入鑰匙圈的一般密碼項目，正式 service＝codenv-<服務>、測試 service＝codenv-test-<亂數>-<服務>，account＝api-key。
//    用 Security.framework（SecItemAdd／Update），金鑰不經過命令列參數（ps 看得到）。
//    列表與狀態只讀「屬性」不讀金鑰本體（不會跳授權視窗）；末四碼在寫入時存進項目的註解欄。
// 二、偵測：KeyScan 每行各自找出文字裡長得像 API 金鑰的片段（常見前綴＋高熵長字串），給輸入框送出前攔截、紀錄寫入前遮罩共用。已知限制：金鑰若被折行，不保證攔截；可用輸入框的「金鑰」按鈕安全存入。

// MARK: 服務清單

struct KeyService: Equatable {
    let id: String            // nvidia、openrouter…（service＝前綴＋id）
    let name: String
    let signup: String        // 去申請的網址
    let modelsURL: String?    // 「測試」打的端點（GET，Bearer）；nil＝沒有可打的
    let note: String

    static let known: [KeyService] = [
        KeyService(id: "nvidia", name: "NVIDIA", signup: "https://build.nvidia.com/settings/api-keys", modelsURL: "https://integrate.api.nvidia.com/v1/models", note: "OpenCode 的 NVIDIA 免費模型"),
        KeyService(id: "openrouter", name: "OpenRouter", signup: "https://openrouter.ai/keys", modelsURL: "https://openrouter.ai/api/v1/models", note: "OpenCode 的 OpenRouter 免費模型"),
        KeyService(id: "google", name: "Google AI Studio", signup: "https://aistudio.google.com/apikey", modelsURL: "https://generativelanguage.googleapis.com/v1beta/models", note: "Gemini API"),
        KeyService(id: "groq", name: "Groq", signup: "https://console.groq.com/keys", modelsURL: "https://api.groq.com/openai/v1/models", note: ""),
        KeyService(id: "cloudflare", name: "Cloudflare", signup: "https://dash.cloudflare.com/profile/api-tokens", modelsURL: "https://api.cloudflare.com/client/v4/user/tokens/verify", note: "Workers AI 的 API Token"),
        KeyService(id: "ollama", name: "Ollama", signup: "https://ollama.com/settings/keys", modelsURL: "https://ollama.com/api/tags", note: "Ollama 雲端"),
    ]
    /// 偵測到但沒有專屬欄位的服務（只能存起來，不能測試）：存成 codenv-<id>
    static let extra: [KeyService] = [
        KeyService(id: "anthropic", name: "Anthropic", signup: "https://console.anthropic.com/settings/keys", modelsURL: nil, note: ""),
        KeyService(id: "openai", name: "OpenAI", signup: "https://platform.openai.com/api-keys", modelsURL: nil, note: ""),
        KeyService(id: "github", name: "GitHub", signup: "https://github.com/settings/tokens", modelsURL: nil, note: ""),
        KeyService(id: "huggingface", name: "Hugging Face", signup: "https://huggingface.co/settings/tokens", modelsURL: nil, note: ""),
        KeyService(id: "slack", name: "Slack", signup: "https://api.slack.com/apps", modelsURL: nil, note: ""),
        KeyService(id: "aws", name: "AWS", signup: "https://console.aws.amazon.com/iam/home#/security_credentials", modelsURL: nil, note: ""),
        KeyService(id: "stripe", name: "Stripe", signup: "https://dashboard.stripe.com/apikeys", modelsURL: nil, note: ""),
        KeyService(id: "sendgrid", name: "SendGrid", signup: "https://app.sendgrid.com/settings/api_keys", modelsURL: nil, note: ""),
        KeyService(id: "npm", name: "npm", signup: "https://www.npmjs.com/settings/~/tokens", modelsURL: nil, note: ""),
        KeyService(id: "pypi", name: "PyPI", signup: "https://pypi.org/manage/account/token/", modelsURL: nil, note: ""),
        KeyService(id: "supabase", name: "Supabase", signup: "https://supabase.com/dashboard/account/tokens", modelsURL: nil, note: ""),
        KeyService(id: "other", name: "其他", signup: "", modelsURL: nil, note: ""),
    ]
    static var everything: [KeyService] { known + extra }
    static func find(_ id: String) -> KeyService? { everything.first { $0.id == id } }
    /// 依照偵測器已知前綴猜服務；沒有對應前綴時回「其他」。
    static func guess(_ key: String) -> KeyService {
        let hit = KeyScan.scan(key).first { $0.strong && $0.service != nil }
        return find(hit?.service ?? "other") ?? extra.last!
    }
}

/// 「金鑰」面板的無 UI 流程：便於用假儲存考卷驗證，正式 UI 只把結果佔位字插入輸入框。
enum KeyVaultPaste {
    static func clean(_ raw: String) -> String { raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined() }
    static func save(_ raw: String, service: String, writer: (String, String) -> String? = KeyVault.set) -> (placeholder: String?, error: String?) {
        let key = clean(raw)
        guard !key.isEmpty else { return (nil, "金鑰是空的") }
        if let error = writer(service, key) { return (nil, error) }
        let name = KeyService.find(service)?.name ?? service
        return ("〔金鑰：\(name)，已存〕", nil)
    }
}

// MARK: 鑰匙圈

enum KeyVault {
    static let account = "api-key"
    /// Only isolated probes may substitute the write sink so synthetic credentials never touch Keychain.
    static var testSetOverride: ((String, String) -> String?)?
    /// state-dir 與其他測試旗標一律使用測試 service；沒有指定安全前綴時每個程序自動產生唯一值。
    static var prefix: String = prefix(arguments: CommandLine.arguments)
    static var isTestInstance: Bool { isTestInstance(CommandLine.arguments) }

    static func isTestInstance(_ arguments: [String]) -> Bool {
        if arguments.contains("--state-dir") { return true }
        // 未附 state-dir 的長選項只會用於測試掛鉤／測試啟動；遇到未知旗標也採安全隔離。
        return arguments.dropFirst().contains { $0.hasPrefix("--") }
    }

    static func prefix(arguments: [String], generatedSuffix: String = UUID().uuidString.lowercased()) -> String {
        guard isTestInstance(arguments) else { return "codenv-" }
        if let i = arguments.firstIndex(of: "--keyvault-prefix"), i + 1 < arguments.count,
           arguments[i + 1].hasPrefix("codenv-test-"), arguments[i + 1].count > "codenv-test-".count {
            return arguments[i + 1]
        }
        return "codenv-test-\(generatedSuffix)-"
    }

    static func service(_ id: String) -> String { prefix + id }

    private static func base(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// 寫入（沒有就新增、有就更新）。金鑰前後空白與換行會去掉。成功回 nil，失敗回說明。
    @discardableResult
    static func set(service: String, key raw: String) -> String? {
        forget(service)                    // 使寫入前已啟動的讀取失效
        defer { forget(service) }      // 先改鑰匙圈、再清快取（反過來的話，中間插進來的讀取會把舊值放回快取）
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "金鑰是空的" }
        if isTestInstance, let testSetOverride { return testSetOverride(service, key) }
        let data = Data(key.utf8)
        let last4 = String(key.suffix(4))
        var st = SecItemUpdate(base(service) as CFDictionary, [kSecValueData as String: data, kSecAttrComment as String: last4] as CFDictionary)
        if st == errSecItemNotFound {
            var add = base(service)
            add[kSecValueData as String] = data
            add[kSecAttrComment as String] = last4
            add[kSecAttrLabel as String] = "codenv API 金鑰（\(service)）"
            st = SecItemAdd(add as CFDictionary, nil)
        }
        return st == errSecSuccess ? nil : "鑰匙圈寫入失敗（\(st)）"
    }

    /// 讀金鑰本體（鑰匙圈鎖住或要授權時可能跳視窗；項目不在回 nil）
    static func read(service: String) -> String? {
        var q = base(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        noteCopyMatchingCall()
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: 不卡主執行緒的讀法（授權框是模態的，在主執行緒讀會卡住整個畫面）

    enum Read: Equatable {
        case value(String)
        case missing                     // 鑰匙圈裡沒有這一筆
        case denied(Int32)               // 使用者按了拒絕／取消，或系統不讓互動
        case failed(Int32)
        case pending                     // 還在等（授權框還開著）
    }
    private static let copyMatchingLock = NSLock()
    private static var copyMatchingCalls = 0
    static var copyMatchingCallCount: Int {
        copyMatchingLock.lock(); defer { copyMatchingLock.unlock() }
        return copyMatchingCalls
    }
    private static func noteCopyMatchingCall() {
        copyMatchingLock.lock(); copyMatchingCalls += 1; copyMatchingLock.unlock()
    }
    /// 讀金鑰的實作（測試可以換成假的，模擬拒絕、卡住，不用真的跳授權框）
    static var reader: (String) -> (status: Int32, value: String?) = { service in
        var q = base(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        noteCopyMatchingCall()
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return (st, (out as? Data).flatMap { String(data: $0, encoding: .utf8) })
    }
    static func classify(_ r: (status: Int32, value: String?)) -> Read {
        switch r.status {
        case errSecSuccess: return r.value.map { .value($0) } ?? .failed(r.status)
        case errSecItemNotFound: return .missing
        case -128, -25293, -25308, -60005, -60008: return .denied(r.status)      // userCanceled、authFailed、interactionNotAllowed、authorization denied
        default: return .failed(r.status)
        }
    }
    private static let cacheLock = NSLock()
    private static var cache: [String: Read] = [:]
    private static var inflight = Set<String>()
    private static var generation: [String: Int] = [:]      // forget 一次加一：forget 之前開始的讀取，讀完不准填快取（刪掉的金鑰不能被舊讀取放回來）
    private static let queue = DispatchQueue(label: "codenv.keyvault.read", qos: .userInitiated, attributes: .concurrent)

    static func cached(_ service: String) -> Read? { cacheLock.lock(); defer { cacheLock.unlock() }; return cache[service] }
    static func forget(_ service: String) { cacheLock.lock(); cache[service] = nil; inflight.remove(service); generation[service, default: 0] += 1; cacheLock.unlock() }

    /// 在背景讀，結果放進快取（成功的也放；denied 也放，下一次送訊息才能明確報錯）
    static func prefetch(_ service: String, completion: ((Read) -> Void)? = nil) {
        cacheLock.lock()
        if inflight.contains(service) { cacheLock.unlock(); return }
        inflight.insert(service); let gen = generation[service, default: 0]; cacheLock.unlock()
        queue.async {
            let r = classify(reader(service))
            cacheLock.lock()
            if generation[service, default: 0] == gen { cache[service] = r }
            inflight.remove(service); cacheLock.unlock()
            completion?(r)
        }
    }
    /// 給同步呼叫的地方（組環境變數）：先看快取；沒有就背景讀並最多等 wait 秒。逾時回 .pending（授權框還開著），背景讀完會填快取。
    /// 成功的快取只用在這個 App 執行期間；denied／pending 的不留，下次會重新問。
    static func readBounded(_ service: String, wait: TimeInterval = 2) -> Read {
        if let c = cached(service), case .value = c { return c }
        // 不是成功的舊結果（拒絕、失敗、沒有）不留：每次都重問一次，不然拒絕過一次就永遠秒失敗。這裡不加世代（不能打斷正在等授權框的那次讀取）
        cacheLock.lock(); cache[service] = nil; cacheLock.unlock()
        let done = DispatchSemaphore(value: 0)
        var result: Read = .pending
        prefetch(service) { result = $0; done.signal() }
        // 已經有人在讀（inflight）時 completion 不會被呼叫：輪流看快取
        let end = Date().addingTimeInterval(wait)
        while Date() < end {
            if done.wait(timeout: .now() + 0.05) == .success { return result }
            if let c = cached(service) { return c }
        }
        return .pending
    }

    @discardableResult
    static func delete(service: String) -> Bool {
        forget(service)                    // 使刪除前已啟動的讀取失效
        defer { forget(service) }
        let st = SecItemDelete(base(service) as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    /// 只讀屬性、不讀本體（不會跳授權視窗）：有沒有這個項目、末四碼（註解欄；不是 codenv 寫的項目沒有）
    static func status(service: String) -> (exists: Bool, last4: String?) {
        var q = base(service)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        noteCopyMatchingCall()
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let a = out as? [String: Any] else { return (false, nil) }
        let c = (a[kSecAttrComment as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (true, c)
    }

    /// 列出所有 <前綴>… 的 api-key 項目的 service（只讀屬性）
    static func allServices() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        noteCopyMatchingCall()
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let arr = out as? [[String: Any]] else { return [] }
        return arr.compactMap { $0[kSecAttrService as String] as? String }.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// 自訂名稱（「其他」）存成的 service：<前綴>other-<小寫英數>
    static func customService(named name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return prefix + "other-" + (slug.isEmpty ? "key" : String(slug.prefix(24)))
    }

    // MARK: 測試（打該服務的 models 端點）

    /// 只回 HTTP 狀態與模型數，不回傳內文。key 空白＝讀鑰匙圈。
    static func test(_ svc: KeyService, key: String? = nil, urlOverride: String? = nil, completion: @escaping (String) -> Void) {
        guard let endpoint = urlOverride ?? svc.modelsURL, let url = URL(string: endpoint) else { return completion("這個服務沒有可以測試的端點") }
        guard let k = key ?? read(service: service(svc.id)), !k.isEmpty else { return completion("還沒有設定金鑰") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer " + k, forHTTPHeaderField: "Authorization")
        if svc.id == "google" { req.setValue(k, forHTTPHeaderField: "x-goog-api-key") }
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, resp, err in
            if let err { return completion("連不上：\((err as NSError).localizedDescription)") }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var count: Int?
            if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let a = o["data"] as? [Any] { count = a.count }
                else if let a = o["models"] as? [Any] { count = a.count }
            }
            completion("HTTP \(code)" + (count.map { "，\($0) 個模型" } ?? (code == 200 ? "（金鑰有效）" : "")))
        }.resume()
    }

    /// 項目是 codenv 建的才有末四碼（註解欄）；用 security 指令建的沒有，codenv 第一次讀會跳授權框
    static func isCodenvOwned(service: String) -> Bool { status(service: service).last4 != nil }

    /// 「重新存成 codenv 擁有」：讀出來（可能跳一次授權框，是使用者自己按的）→ 先備份一份給 codenv 擁有的臨時項目 → 刪掉原項目 → 寫回 → 刪備份。
    /// 任何一步失敗，備份都留著（service 名稱會在錯誤說明裡），不會弄丟金鑰。成功回 nil。
    static func adopt(service: String) -> String? {
        guard case .value(let key) = classify(reader(service)) else { return "讀不到這把金鑰（可能按了拒絕）" }
        let backup = service + "-backup-" + String(UUID().uuidString.prefix(6)).lowercased()
        if let e = set(service: backup, key: key) { return "備份失敗，沒有動原本的項目：" + e }
        guard delete(service: service) else { return "原項目刪不掉（需要授權）。備份在 \(backup)" }
        if let e = set(service: service, key: key) { return "寫回失敗：\(e)。金鑰還在備份 \(backup)" }
        delete(service: backup)
        return nil
    }
}

// MARK: 偵測

struct KeyHit: Equatable {
    let range: NSRange        // 在原文裡的位置（正規化、拿掉零寬字元後比對，位置會對回原文）
    let text: String          // 原文裡那一段
    let kind: String          // 例如 nvapi-、sk-or-、高熵
    let service: String?      // KeyService.id 的猜測
    var strong = true         // 有明確前綴／PEM 標頭＝true；高熵、十六進位、JWT＝false（寫紀錄時 strongOnly 只遮 strong 的）
    var low = false           // 低信心（JWT）：卡片的「仍要送出」不用再確認第二次
    var clean = ""            // 正規化後的金鑰本體（全形變半形、拿掉零寬字元）；要存進鑰匙圈的是這個，不是原文
    var key: String { clean.isEmpty ? text : clean }
    /// JWT 雖不是 strongOnly 要遮罩的明確前綴，仍屬永遠警告的強規則。
    var isForceWarn: Bool { strong || low }
    var isLearnableWeak: Bool { !isForceWarn && (kind == "十六進位金鑰" || kind == "高熵長字串") }
}

struct KeyScanFinding: Equatable {
    let hit: KeyHit
    let excluded: Bool
    let allowlisted: Bool
    let learnedSuppressed: Bool
    let feature: String?
    let learnedCount: Int
    var shouldWarn: Bool { !excluded && !allowlisted && !learnedSuppressed }
}

enum KeyScan {
    /// 使用者按過「這段不是金鑰，以後別再攔」的內容雜湊（只記雜湊不記原文）。App 啟動後由 KeyGuard 接上設定檔
    private static let stateLock = NSLock()
    private static var storedAllowHashes: Set<String> = []
    /// 前文特徵的弱規則誤報次數，由 KeyGuard 從本機 JSONL 載入。
    private static var storedLearnedFeatureCounts: [String: Int] = [:]
    /// 已學特徵命中時的紀錄回呼，由 KeyGuard.wire() 接線；保持掃描器可獨立編譯。
    private static var storedOnLearnedSuppression: ((String, String, Int) -> Void)?

    struct StateSnapshot {
        let allowHashes: Set<String>
        let learnedFeatureCounts: [String: Int]
        let onLearnedSuppression: ((String, String, Int) -> Void)?
    }

    private static func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    static var allowHashes: Set<String> {
        get { snapshot().allowHashes }
        set { withStateLock { storedAllowHashes = newValue } }
    }
    static var learnedFeatureCounts: [String: Int] {
        get { snapshot().learnedFeatureCounts }
        set { withStateLock { storedLearnedFeatureCounts = newValue } }
    }
    static var onLearnedSuppression: ((String, String, Int) -> Void)? {
        get { snapshot().onLearnedSuppression }
        set { withStateLock { storedOnLearnedSuppression = newValue } }
    }

    static func snapshot() -> StateSnapshot {
        withStateLock {
            StateSnapshot(allowHashes: storedAllowHashes,
                         learnedFeatureCounts: storedLearnedFeatureCounts,
                         onLearnedSuppression: storedOnLearnedSuppression)
        }
    }

    static func replaceState(allowHashes: Set<String>, learnedFeatureCounts: [String: Int],
                             onLearnedSuppression: ((String, String, Int) -> Void)?) {
        withStateLock {
            storedAllowHashes = allowHashes
            storedLearnedFeatureCounts = learnedFeatureCounts
            storedOnLearnedSuppression = onLearnedSuppression
        }
    }

    static func updateAllowAndLearned(allowHashes: Set<String>, learnedFeatureCounts: [String: Int]) {
        withStateLock {
            storedAllowHashes = allowHashes
            storedLearnedFeatureCounts = learnedFeatureCounts
        }
    }

    static func insertAllowHash(_ hash: String) {
        withStateLock { storedAllowHashes.insert(hash) }
    }

    static func subtractAllowHashes(_ hashes: Set<String>) {
        withStateLock { storedAllowHashes.subtract(hashes) }
    }

    static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// 有明確前綴的樣式（前面不能緊接字母數字或 _ -，免得誤抓長字串中間）
    private static let patterns: [(kind: String, service: String?, strong: Bool, low: Bool, regex: NSRegularExpression)] = {
        func r(_ p: String, lookbehind: Bool = true, opts: NSRegularExpression.Options = []) -> NSRegularExpression {
            try! NSRegularExpression(pattern: (lookbehind ? "(?<![A-Za-z0-9_-])" : "") + p, options: opts)
        }
        return [
            ("nvapi-", "nvidia", true, false, r("nvapi-[A-Za-z0-9_-]{20,}")),
            ("sk-or-v1-", "openrouter", true, false, r("sk-or-v1-[A-Za-z0-9]{20,}")),
            ("sk-ant-", "anthropic", true, false, r("sk-ant-[A-Za-z0-9_-]{20,}")),
            ("sk-proj-", "openai", true, false, r("sk-proj-[A-Za-z0-9_-]{20,}")),
            ("sk-", "openai", true, false, r("sk-(?!or-v1-|ant-|proj-)[A-Za-z0-9_-]{32,}")),
            ("sk_live_", "stripe", true, false, r("(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}")),
            ("SG.", "sendgrid", true, false, r("SG\\.[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}")),
            ("npm_", "npm", true, false, r("npm_[A-Za-z0-9]{30,}")),
            ("pypi-", "pypi", true, false, r("pypi-[A-Za-z0-9_-]{50,}")),
            ("sbp_", "supabase", true, false, r("sbp_[a-f0-9]{40}")),
            ("AIza", "google", true, false, r("AIza[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])")),
            ("ghp_", "github", true, false, r("gh[pousr]_[A-Za-z0-9]{30,}")),
            ("github_pat_", "github", true, false, r("github_pat_[A-Za-z0-9_]{30,}")),
            ("gsk_", "groq", true, false, r("gsk_[A-Za-z0-9]{40,}")),
            ("hf_", "huggingface", true, false, r("hf_[A-Za-z0-9]{30,}")),
            ("xoxb-", "slack", true, false, r("xox[abprs]-[A-Za-z0-9-]{10,}")),
            ("AKIA", "aws", true, false, r("AKIA[0-9A-Z]{16}(?![A-Za-z0-9])")),
            ("私鑰", nil, true, false, r("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?:[\\s\\S]{0,8000}?-----END [A-Z0-9 ]*PRIVATE KEY-----|(?:\\r?\\n[ \\t]*[A-Za-z0-9-]+:[ \\t]*[^\\r\\n]+)*(?:\\r?\\n[ \\t]*)?(?:\\r?\\n[ \\t]*[A-Za-z0-9+/=]{1,}[ \\t]*)+)", lookbehind: false)),
            ("JWT", nil, false, true, r("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]*")),
        ]
    }()
    private static let run = try! NSRegularExpression(pattern: "[A-Za-z0-9_+/.-]{32,}={0,2}")
    private static let hexRun = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z_-])[0-9a-fA-F]{7,128}(?![0-9A-Za-z_-])")
    private static let keyWords = try! NSRegularExpression(pattern: "(?i)(api|key|token|secret|passw|credential|bearer|auth)")
    private static let gitWords = try! NSRegularExpression(pattern: "(?i)\\b(commit|sha\\d*|hash|head|rev|checksum|digest|blob|tree|parent|merge|cherry-pick|revert|md5|git)\\b")
    private static let shaDigestWords = try! NSRegularExpression(pattern: #"(?i)\bsha(1|256|384|512)\b"#)

    private struct Candidate {
        let hit: KeyHit
        let excluded: Bool
    }

    static func shannon(_ s: String) -> Double {
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return -freq.values.reduce(0.0) { $0 + (Double($1) / n) * log2(Double($1) / n) }
    }

    private static func has(_ t: String, _ pat: String) -> Bool { t.range(of: pat, options: .regularExpression) != nil }

    /// 高熵長字串：32～200 字、有數字加至少一種字母（全小寫＋數字也算）、熵 ≥ 4.0；
    /// 路徑（/、~/、./ 開頭，或帶副檔名的相對路徑）、npm 的 sha512- integrity、純十六進位（另外處理）不算
    static func looksRandom(_ t: String) -> Bool {
        guard t.count >= 32, t.count <= 200 else { return false }
        if t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") || t.hasPrefix("../") { return false }
        if t.contains("/"), has(t, "\\.[A-Za-z0-9]{1,5}$") { return false }
        if has(t, "^sha(1|256|384|512)-[A-Za-z0-9+/]+=*$") { return false }
        if has(t, "^[0-9a-fA-F-]+$") { return false }
        guard has(t, "[0-9]"), has(t, "[a-zA-Z]") else { return false }
        return shannon(t) >= 4.0
    }

    // MARK: 把文字整理成「容易比對」的樣子，同時記住每個字對回原文的位置

    private static let invisible: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x2060, 0xFEFF, 0x00AD, 0x180E, 0x034F]
    private struct View {
        var units: [UInt16] = []
        var start: [Int] = []       // 每個字在原文的起點（UTF-16）
        var end: [Int] = []         // 在原文的終點
        var string: String { String(decoding: units, as: UTF16.self) }
    }
    /// NFKC（全形變半形）＋拿掉零寬字元；每行各自檢查，不合併折行。
    private static func makeView(_ text: String) -> View {
        var base = View()
        var off = 0
        for s in text.unicodeScalars {
            let len = s.value > 0xFFFF ? 2 : 1
            defer { off += len }
            if invisible.contains(s.value) { continue }
            if s.value < 0x80 {
                let unit = UInt16(s.value)
                base.units.append(unit); base.start.append(off); base.end.append(off + len)
            } else {
                for u in String(s).precomposedStringWithCompatibilityMapping.utf16 {
                    base.units.append(u); base.start.append(off); base.end.append(off + len)
                }
            }
        }
        return base
    }

    private struct HexLineContext {
        let range: NSRange
        let line: String
        let previous: String
        let trimmed: String
        let lineHasGitWord: Bool
        let previousHasGitWord: Bool
        let lineHasKeyWord: Bool
        let previousHasKeyWord: Bool
        let gitLogLine: Bool
        let shaDigestEnds: [Int]
    }

    private static func hexLineContext(_ ns: NSString, _ range: NSRange, previous: String) -> HexLineContext {
        let line = ns.substring(with: range)
        let lineNS = line as NSString
        let whole = NSRange(location: 0, length: lineNS.length)
        let previousNS = previous as NSString
        let previousWhole = NSRange(location: 0, length: previousNS.length)
        let lineHasGit = gitWords.firstMatch(in: line, range: whole) != nil
        let previousHasGit = gitWords.firstMatch(in: previous, range: previousWhole) != nil
        let lineHasKey = keyWords.firstMatch(in: line, range: whole) != nil
        let previousHasKey = keyWords.firstMatch(in: previous, range: previousWhole) != nil
        let isGitLogLine = line.range(of: #"^\s*[0-9a-f]{7,40}\s+\S"#, options: .regularExpression) != nil
            || line.range(of: #"^\s*commit\s+[0-9a-f]{7,40}\b"#, options: .regularExpression) != nil
        let shaEnds = shaDigestWords.matches(in: line, range: whole).map { $0.range.upperBound }
        return HexLineContext(range: range, line: line, previous: previous,
                              trimmed: line.trimmingCharacters(in: .whitespacesAndNewlines),
                              lineHasGitWord: lineHasGit, previousHasGitWord: previousHasGit,
                              lineHasKeyWord: lineHasKey, previousHasKeyWord: previousHasKey,
                              gitLogLine: isGitLogLine, shaDigestEnds: shaEnds)
    }

    private static func scanString(_ text: String) -> [Candidate] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hits: [Candidate] = []
        let meta = metaTable(for: text)
        for p in patterns {
            for m in p.regex.matches(in: text, range: full) {
                hits.append(Candidate(hit: KeyHit(range: m.range, text: ns.substring(with: m.range), kind: p.kind, service: p.service, strong: p.strong, low: p.low), excluded: false))
            }
        }
        // 十六進位：UUID 與 git 雜湊放行；其他 32～128 位的，前後文有 key／token／secret／api 才攔（Datadog、Mailgun 這類金鑰就是純十六進位）
        var lineCache: HexLineContext?
        var shaDigestIndex = 0
        for m in hexRun.matches(in: text, range: full) {
            if lineCache == nil {
                let range = ns.lineRange(for: m.range)
                let previous: String = range.location > 0
                    ? ns.substring(with: ns.lineRange(for: NSRange(location: range.location - 1, length: 0)))
                    : ""
                lineCache = hexLineContext(ns, range, previous: previous)
            } else if let cached = lineCache, m.range.location >= cached.range.upperBound {
                var range = cached.range
                var previous = cached.line
                while m.range.location >= range.upperBound && range.upperBound < ns.length {
                    let nextRange = ns.lineRange(for: NSRange(location: range.upperBound, length: 0))
                    guard nextRange.length > 0, nextRange.upperBound > range.upperBound else { break }
                    range = nextRange
                    lineCache = hexLineContext(ns, range, previous: previous)
                    previous = lineCache?.line ?? ""
                }
                shaDigestIndex = 0
            }
            guard let ctx = lineCache else { continue }
            let tok = ns.substring(with: m.range)
            if meta.name(containing: m.range) != nil {
                // 讓 probe 能指出這個弱規則候選是由 meta 標籤排除；強規則不經過這段。
                hits.append(Candidate(hit: KeyHit(range: m.range, text: tok, kind: "十六進位金鑰", service: nil, strong: false), excluded: true))
                continue
            }
            let isLowerHexHash = tok.count >= 7 && tok.count <= 40 && tok == tok.lowercased()
            let gitContext = ctx.lineHasGitWord || ctx.previousHasGitWord
            let prefixLength = m.range.location - ctx.range.location
            while shaDigestIndex < ctx.shaDigestEnds.count && ctx.shaDigestEnds[shaDigestIndex] <= prefixLength {
                shaDigestIndex += 1
            }
            let shaDigest = shaDigestIndex > 0
            let alone = ctx.trimmed == tok
            if shaDigest { continue } // sha256／sha512 摘要本身可能超過 40 位，沿用舊版的摘要放行
            if isLowerHexHash && (gitContext || ctx.gitLogLine) { continue }
            if tok.count >= 32 && (ctx.lineHasKeyWord || (alone && ctx.previousHasKeyWord)) {
                hits.append(Candidate(hit: KeyHit(range: m.range, text: tok, kind: "十六進位金鑰", service: nil, strong: false), excluded: false))
            }
        }
        for m in run.matches(in: text, range: full) {
            let t = ns.substring(with: m.range)
            guard looksRandom(t) else { continue }
            if m.range.location >= 7, ns.substring(with: NSRange(location: m.range.location - 7, length: 7)) == "base64," { continue }
            hits.append(Candidate(hit: KeyHit(range: m.range, text: t, kind: "高熵長字串", service: nil, strong: false), excluded: meta.name(containing: m.range) != nil))
        }
        return hits
    }

    private static let metaTagRegex = try! NSRegularExpression(pattern: #"(?is)<meta\b[^>]*>"#)
    private static let metaNameRegex = try! NSRegularExpression(pattern: #"(?i)\bname\s*=\s*["']?([A-Za-z0-9_-]+)"#)
    private static let metaContentRegex = try! NSRegularExpression(pattern: #"(?i)\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    // 僅排除已知非祕密 meta 值；未列出的驗證碼照常掃描。
    private static let nonSecretMetaNames: Set<String> = ["darkreader", "theme-color", "generator", "google-site-verification"]

    /// 一次掃完整份文字的 <meta>，只留已知非祕密 meta 的 content 範圍，之後每個候選查表即可。
    struct MetaTable {
        fileprivate var entries: [(range: NSRange, name: String, known: Bool)] = []
        private func entry(containing r: NSRange, knownOnly: Bool) -> (range: NSRange, name: String, known: Bool)? {
            var lower = 0
            var upper = entries.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if entries[middle].range.location <= r.location { lower = middle + 1 }
                else { upper = middle }
            }
            guard lower > 0 else { return nil }
            let candidate = entries[lower - 1]
            guard (!knownOnly || candidate.known), r.location >= candidate.range.location,
                  r.upperBound <= candidate.range.upperBound else { return nil }
            return candidate
        }
        /// 已知非祕密 meta（darkreader 等）的 content 內：用來排除弱規則命中
        func name(containing r: NSRange) -> String? {
            entry(containing: r, knownOnly: true)?.name
        }
        /// 任何有 name 的 meta 的 content 內：只用來算學習特徵（使用者按兩次「不是金鑰」才會抑制，不直接排除）
        func anyName(containing r: NSRange) -> String? {
            entry(containing: r, knownOnly: false)?.name
        }
    }

    static func metaTable(for text: String) -> MetaTable {
        var table = MetaTable()
        let ns = text as NSString
        // 沒有 "<meta" 的大檔直接略過，避免白跑正規式
        guard ns.range(of: "<meta", options: .caseInsensitive).location != NSNotFound else { return table }
        for tag in metaTagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: tag.range)
            let valueNS = value as NSString
            let whole = NSRange(location: 0, length: valueNS.length)
            guard let nameMatch = metaNameRegex.firstMatch(in: value, range: whole), nameMatch.numberOfRanges > 1 else { continue }
            let name = valueNS.substring(with: nameMatch.range(at: 1)).lowercased()
            guard let contentMatch = metaContentRegex.firstMatch(in: value, range: whole) else { continue }
            let cr = (1..<contentMatch.numberOfRanges).map { contentMatch.range(at: $0) }
                .first { $0.location != NSNotFound && $0.length > 0 }
            guard let cr else { continue }
            table.entries.append((NSRange(location: tag.range.location + cr.location, length: cr.length), name, nonSecretMetaNames.contains(name)))
        }
        return table
    }

    /// 只學明顯非祕密的特徵：meta name／integrity／data-hash。key／token／secret 與任意屬性名不收。
    private static let safeFeatureRegex = try! NSRegularExpression(pattern: #"^(?:meta name=[a-z0-9_-]+|integrity=|data-hash=)$"#)
    static func isSafeLearnedFeature(_ feature: String) -> Bool {
        safeFeatureRegex.firstMatch(in: feature, range: NSRange(location: 0, length: (feature as NSString).length)) != nil
    }
    private static let integrityRegex = try! NSRegularExpression(pattern: #"(?i)\b(integrity|data-hash)\s*=\s*["'][^"']*$"#)

    /// 從命中前 40 個 UTF-16 字元抽出穩定的標籤／屬性特徵，不保存金鑰本體。
    static func feature(for hit: KeyHit, in source: String, meta: MetaTable? = nil) -> String? {
        guard hit.isLearnableWeak else { return nil }
        let ns = source as NSString
        guard hit.range.location <= ns.length else { return nil }
        if let name = (meta ?? metaTable(for: source)).anyName(containing: hit.range) { return "meta name=\(name)" }
        let prefixRange = NSRange(location: max(0, hit.range.location - 40), length: min(40, hit.range.location))
        let prefix = ns.substring(with: prefixRange)
        if let match = integrityRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)), match.numberOfRanges > 1 {
            return "\((prefix as NSString).substring(with: match.range(at: 1)).lowercased())="
        }
        return nil
    }

    static func learningKey(rule: String, feature: String) -> String { rule + "\u{1f}" + feature }

    static func findings(_ text: String, using suppliedSnapshot: StateSnapshot? = nil,
                         learnedSuppressionCollector: ((String, String, Int) -> Void)? = nil) -> [KeyScanFinding] {
        guard text.utf16.count >= 16 else { return [] }
        let state = suppliedSnapshot ?? snapshot()
        let ns = text as NSString
        let view = makeView(text)
        var all: [(hit: KeyHit, excluded: Bool)] = []
        let meta = metaTable(for: text)
        for candidate in scanString(view.string) {
            let h = candidate.hit
            guard h.range.length > 0, h.range.upperBound <= view.units.count else { continue }
            let original = NSRange(location: view.start[h.range.location], length: view.end[h.range.upperBound - 1] - view.start[h.range.location])
            let hit = KeyHit(range: original, text: ns.substring(with: original), kind: h.kind, service: h.service, strong: h.strong, low: h.low, clean: h.text)
            let excluded = candidate.excluded || (hit.isLearnableWeak && meta.name(containing: original) != nil)
            all.append((hit, excluded))
        }
        // 彼此重疊的只留先到的、最長的；強規則（含 JWT）先判，弱規則不得吃掉強規則命中，
        // 且與強規則重疊的弱規則直接丟掉（強規則任何情況都要警告）。
        let order: ((hit: KeyHit, excluded: Bool), (hit: KeyHit, excluded: Bool)) -> Bool = {
            $0.hit.range.location != $1.hit.range.location ? $0.hit.range.location < $1.hit.range.location : $0.hit.range.length > $1.hit.range.length
        }
        func overlaps(_ a: NSRange, _ b: NSRange) -> Bool { NSIntersectionRange(a, b).length > 0 }
        let forceWarn = all.filter({ $0.hit.isForceWarn }).sorted(by: order)
        let weak = all.filter({ !$0.hit.isForceWarn }).sorted(by: order)
        var uniqueForceWarn: [(hit: KeyHit, excluded: Bool)] = []
        for item in forceWarn {
            if let last = uniqueForceWarn.last, overlaps(last.hit.range, item.hit.range) { continue }
            uniqueForceWarn.append(item)
        }
        // 強規則與弱規則分兩組掃描，避免先把所有強規則 append 後再從較早的弱規則
        // 開始比較，導致只檢查最後一筆而漏掉同起點重疊。兩組都已按位置排序。
        var uniqueWeak: [(hit: KeyHit, excluded: Bool)] = []
        var forceIndex = 0
        for item in weak {
            while forceIndex < uniqueForceWarn.count,
                  uniqueForceWarn[forceIndex].hit.range.location + uniqueForceWarn[forceIndex].hit.range.length <= item.hit.range.location {
                forceIndex += 1
            }
            let overlapsForce = forceIndex < uniqueForceWarn.count
                && overlaps(uniqueForceWarn[forceIndex].hit.range, item.hit.range)
            let overlapsPreviousWeak = uniqueWeak.last.map { overlaps($0.hit.range, item.hit.range) } ?? false
            if !overlapsForce && !overlapsPreviousWeak { uniqueWeak.append(item) }
        }
        var unique = uniqueForceWarn + uniqueWeak
        unique.sort(by: order)
        return unique.map { item in
            let hit = item.hit
            let excluded = item.excluded && hit.isLearnableWeak
            let allowlisted = hit.isLearnableWeak && (allow(hit.text, hashes: state.allowHashes) || allow(hit.key, hashes: state.allowHashes))
            let feature = KeyScan.feature(for: hit, in: text, meta: meta)
            let count = feature.map { state.learnedFeatureCounts[learningKey(rule: hit.kind, feature: $0)] ?? 0 } ?? 0
            let learned = hit.isLearnableWeak && feature != nil && count >= 2
            if learned, let feature {
                if let learnedSuppressionCollector { learnedSuppressionCollector(hit.kind, feature, count) }
                else { state.onLearnedSuppression?(hit.kind, feature, count) }
            }
            return KeyScanFinding(hit: hit, excluded: excluded, allowlisted: allowlisted, learnedSuppressed: learned, feature: feature, learnedCount: count)
        }
    }

    static func scan(_ text: String, using snapshot: StateSnapshot? = nil,
                     learnedSuppressionCollector: ((String, String, Int) -> Void)? = nil) -> [KeyHit] {
        findings(text, using: snapshot, learnedSuppressionCollector: learnedSuppressionCollector).filter(\.shouldWarn).map(\.hit)
    }
    private static func allow(_ s: String, hashes: Set<String>) -> Bool { !hashes.isEmpty && hashes.contains(hash(s)) }

    /// 把命中的片段換成「〔金鑰…abcd〕」（只留末四碼）。
    /// strongOnly＝只遮有明確前綴的（草稿、各家 jsonl、寄件匣、標題用：高熵長字串可能是使用者自己的東西，誤遮會弄丟他的字）
    static func redact(_ text: String, strongOnly: Bool = false) -> String {
        guard text.utf16.count >= 16 else { return text }
        let hits = scan(text).filter { !strongOnly || $0.strong }
        guard !hits.isEmpty else { return text }
        let ns = NSMutableString(string: text)
        for h in hits.reversed() { ns.replaceCharacters(in: h.range, with: "〔金鑰…" + String(h.key.suffix(4)) + "〕") }
        return ns as String
    }
}
