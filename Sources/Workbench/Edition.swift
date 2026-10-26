import Foundation

/// 公版和私人版的差異，全部由 Info.plist 的 Codenv* 鍵決定（不開兩份程式碼，docs/public-spec.md）。
/// 私人版的 Info.plist 帶原本的值，行為跟以前一模一樣；公版是匯出腳本（scripts/export-public.sh）把這些鍵改掉或刪掉：
///   CodenvEdition       "public"＝公版；沒有這個鍵＝私人版
///   CodenvDataFolder    Application Support 底下放資料的資料夾名字（公版 codenv；沒有鍵＝AI 工作台）
///   CodenvAgyDefault    agy 功能預設開還是關（公版 false；沒有鍵＝true）
///   CodenvUpdateRepo    更新提醒要查的 GitHub repo（owner/name）；沒有這個鍵＝完全不檢查更新
///   CodenvFeedbackEmail 「回報問題」寄到哪個信箱（要跟 CodenvUpdateRepo 兩個都有才顯示回報入口；沒有＝沒有這個入口）
///   CodenvProjectsFolder／CodenvPracticeFolder／CodenvLocalPython／CodenvImageShelf  家目錄底下的個人資料夾（公版沒有，對應功能就用通用的位置或不啟用）
/// 測試 App（有 --state-dir）可以加 --edition-plist <檔案>，用那份 plist 的鍵蓋過去，在除錯版裡模擬公版。
enum Edition {
    static let info: [String: Any] = {
        var d = Bundle.main.infoDictionary ?? [:]
        let a = CommandLine.arguments
        if a.contains("--state-dir"), let i = a.firstIndex(of: "--edition-plist"), i + 1 < a.count,
           let extra = NSDictionary(contentsOfFile: a[i + 1]) as? [String: Any] {
            for (k, v) in extra where k.hasPrefix("Codenv") || k == "CFBundleIdentifier" || k == "CFBundleShortVersionString" { d[k] = v }
            for k in ["CodenvEdition", "CodenvUpdateRepo", "CodenvFeedbackEmail", "CodenvProjectsFolder", "CodenvPracticeFolder", "CodenvLocalPython", "CodenvImageShelf"] where extra[k] == nil { d[k] = nil }
        }
        return d
    }()
    private static func string(_ k: String) -> String? { (info[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }

    static var isPublic: Bool { string("CodenvEdition") == "public" }
    static var bundleID: String { string("CFBundleIdentifier") ?? "com.local.aiworkbench" }
    static var version: String { string("CFBundleShortVersionString") ?? "" }
    static var updateRepo: String? { string("CodenvUpdateRepo") }
    static var feedbackEmail: String? { string("CodenvFeedbackEmail") }
    static var agyDefault: Bool { info["CodenvAgyDefault"] as? Bool ?? true }

    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// ~/Library/Application Support/<資料夾>：state.json、各家紀錄、看板、排程都放這
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(string("CodenvDataFolder") ?? "AI 工作台", isDirectory: true)
    }
    static func support(_ sub: String) -> URL { supportDir.appendingPathComponent(sub) }

    /// 家目錄底下放專案的資料夾（新對話選資料夾時的起點）；沒有設就從家目錄開始
    static var projectsRoot: URL { string("CodenvProjectsFolder").map { home.appendingPathComponent($0) } ?? home }
    /// 程式碼學習專區放練習的資料夾
    static var practiceFolder: URL { home.appendingPathComponent(string("CodenvPracticeFolder") ?? "Documents/codenv-practice") }
    /// 本機模型（MLX）的 Python；沒有設＝不提供本機模型
    static var localPython: String? { string("CodenvLocalPython").map { home.appendingPathComponent($0).path } }
    /// 圖片標註編輯器（image-shelf）原始碼的位置；沒有設就只找 Claude 外掛快取
    static var imageShelfSource: String? { string("CodenvImageShelf").map { home.appendingPathComponent($0).path } }
    /// 畫面上顯示用的「~/…」
    static func display(_ u: URL) -> String { u.path.hasPrefix(home.path) ? "~" + u.path.dropFirst(home.path.count) : u.path }
}
