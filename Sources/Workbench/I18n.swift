import Foundation

/// 介面語言（docs/public-spec.md 第 5 節）：程式裡的中文字串用 L("中文原文") 包起來，查 Resources/i18n/en.json 回傳英文；
/// 查不到就原樣回傳中文（漏翻的地方不會壞，只是顯示中文）。語言在啟動時決定一次，改設定要重開 codenv 才生效。
///   設定值（appDefaults "language"）：system（預設：系統偏好語言是中文就用繁中，其他用英文）／zh／en
///   測試參數：--lang zh|en（要同時有 --state-dir）、--i18n-dump <檔案>（幾秒後把查過但沒翻的字串寫進去）
/// 字串插值照原本的寫法就行：L("共 \(n) 筆") 的 key 是「共 %@ 筆」，en.json 裡寫 "共 %@ 筆": "%@ items"，要換順序用 %2$@ 這種。
/// 不要用 L() 包的：送給模型的提示詞、內部標記（〔codenv 換模型〕、HANDOFF: 之類）、會存進 state.json 或拿來比對的字串、使用者自己的資料。
enum I18n {
    /// 決定結果：zh 或 en
    static let lang: String = {
        let a = CommandLine.arguments
        if a.contains("--state-dir"), let i = a.firstIndex(of: "--lang"), i + 1 < a.count, ["zh", "en", "pseudo"].contains(a[i + 1]) { return a[i + 1] == "zh" ? "zh" : "en" }
        return resolve(appDefaults.string(forKey: "language"))
    }()
    /// 設定值 → zh／en（system 或沒設：系統偏好語言是中文就 zh，其他 en）
    static func resolve(_ setting: String?) -> String {
        switch setting {
        case "zh": return "zh"
        case "en": return "en"
        default: return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? "zh" : "en"
        }
    }
    static var isEnglish: Bool { lang == "en" }
    /// 測試用：--lang pseudo ＝英文介面，但每個 L() 的結果都包成「⟪原文⟫」，截圖一看就知道哪些字有包、哪些沒包（沒有 ⟪ ⟫ 的中文就是漏的）
    static let pseudo: Bool = {
        let a = CommandLine.arguments
        guard a.contains("--state-dir"), let i = a.firstIndex(of: "--lang"), i + 1 < a.count else { return false }
        return a[i + 1] == "pseudo"
    }()

    /// 中文原文 → 英文（英文介面才載入）
    static let table: [String: String] = {
        guard lang == "en" else { return [:] }
        var urls: [URL] = []
        if let u = Bundle.main.resourceURL?.appendingPathComponent("i18n/en.json") { urls.append(u) }
        // 直接跑 .build 裡的執行檔時：用原始碼旁邊的
        urls.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/i18n/en.json"))
        for u in urls {
            if let d = try? Data(contentsOf: u), let t = try? JSONSerialization.jsonObject(with: d) as? [String: String] { return t }
        }
        return [:]
    }()

    /// 給 chat.js 的 wb.setLocale(…)：整份對照表的 JSON（中文介面是 {}）
    static let tableJSON: String = {
        if pseudo { return "{\"__pseudo\":\"1\"}" }
        guard let d = try? JSONSerialization.data(withJSONObject: table), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }()

    private static var missing = Set<String>()
    private static let lock = NSLock()

    static func translate(_ key: String, _ args: [String]) -> String {
        var s = key
        if isEnglish {
            if pseudo { s = "⟪" + key + "⟫" }
            else if let t = table[key], !t.isEmpty { s = t }      // 值是空字串＝還沒翻，顯示中文原文
            else if !args.isEmpty || key.contains(where: { $0.unicodeScalars.contains { $0.value >= 0x2E80 } }) {
                lock.lock(); missing.insert(key); lock.unlock()
            }
        }
        guard !args.isEmpty else { return s }
        // %1$@ 這種有編號的先換，再依序換 %@
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        var out = "", rest = Substring(s), n = 0
        while let r = rest.range(of: "%@") {
            out += rest[..<r.lowerBound]
            out += n < args.count ? args[n] : "%@"
            n += 1
            rest = rest[r.upperBound...]
        }
        return out + rest
    }

    /// 查過、英文表裡沒有的字串（測試與盤點用）
    static var untranslated: [String] { lock.lock(); defer { lock.unlock() }; return missing.sorted() }

    /// 測試：幾秒後把還沒翻的字串寫進檔案
    static func startDumpIfAsked() {
        let a = CommandLine.arguments
        guard a.contains("--state-dir"), let i = a.firstIndex(of: "--i18n-dump"), i + 1 < a.count else { return }
        let path = a[i + 1]
        let sec = a.firstIndex(of: "--i18n-dump-after").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil } ?? 8
        DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
            let body = "lang=\(lang)\ntable=\(table.count)\nuntranslated=\(untranslated.count)\n" + untranslated.joined(separator: "\n") + "\n"
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// L("…") 的參數型別：字串插值會被收成「key（插值位置換成 %@）＋參數」
struct LString: ExpressibleByStringInterpolation {
    var key: String
    var args: [String]
    init(stringLiteral value: String) { key = value; args = [] }
    init(stringInterpolation si: Interpolation) { key = si.key; args = si.args }
    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ s: String) { key += s }
        mutating func appendInterpolation<T>(_ v: T) { key += "%@"; args.append("\(v)") }
    }
}

func L(_ s: LString) -> String { I18n.translate(s.key, s.args) }
/// 執行時才知道內容的字串（變數、表格裡的名稱）：查表，查不到原樣回傳。能直接寫成字面字串的地方用 L("…")，這樣盤點腳本才找得到
func LV(_ s: String) -> String { I18n.translate(s, []) }
