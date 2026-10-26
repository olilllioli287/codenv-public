import AppKit
import Combine

/// App 的各種偏好設定（⌘ , 的「對話」「桌寵與用量」「外觀」頁）。存在 appDefaults（測試 App 另一份）
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = appDefaults

    /// 新對話的預設模型（nil＝跟 Claude 的設定）
    @Published var defaultModel: String? { didSet { d.set(defaultModel, forKey: "defaultModel") } }
    /// 新對話的預設思考強度（nil＝跟 Claude 的設定）
    @Published var defaultEffort: String? { didSet { d.set(defaultEffort, forKey: "defaultEffort") } }
    /// 權限模式（沒設過＝auto，跟使用者在終端機用的一樣；nil＝跟 Claude 的設定；default、acceptEdits、auto、plan）
    @Published var permissionMode: String? { didSet { d.set(permissionMode ?? "", forKey: "permissionMode") } }
    /// true：Enter 送出、Shift+Enter 換行；false：Enter 換行、⌘ Enter 送出（使用者在 Claude Code 的習慣）
    @Published var sendWithEnter: Bool { didSet { d.set(sendWithEnter, forKey: "sendWithEnter") } }
    /// 回答完在輸入框用灰字猜你下一句（Tab 採用），跟 Claude Code 一樣
    @Published var promptSuggestions: Bool { didSet { d.set(promptSuggestions, forKey: "promptSuggestions") } }
    /// 帶 --chrome：Claude 能透過 Chrome 擴充功能（Claude in Chrome）操作你的 Chrome；-p 模式不會吃 iTerm 那邊的預設，要自己帶
    @Published var claudeInChrome: Bool { didSet { d.set(claudeInChrome, forKey: "claudeInChrome") } }
    @Published var artifacts: Bool { didSet { d.set(artifacts, forKey: "artifacts") } }
    @Published var reconnectOnLaunch: Bool { didSet { d.set(reconnectOnLaunch, forKey: "reconnectOnLaunch") } }
    @Published var claudeDebugLog: Bool { didSet { d.set(claudeDebugLog, forKey: "claudeDebugLog") } }
    /// 雲端（Claude）自動壓縮的上下文門檻，token：啟動 claude 時帶 CLAUDE_CODE_AUTO_COMPACT_WINDOW（Claude Code 接受 10 萬～100 萬；實際取它和模型上限的較小值）
    @Published var cloudCompactTokens: Int { didSet { d.set(cloudCompactTokens, forKey: "cloudCompactTokens") } }
    /// 本機模型自動壓縮的門檻，token：超過就先請 Claude 把前面整理成摘要（LocalCompact.swift；實際取它和模型上限 × 0.8 的較小值）
    @Published var localCompactTokens: Int { didSet { d.set(localCompactTokens, forKey: "localCompactTokens") } }
    /// 瀏覽器格子用哪個核心：webkit（系統內建、省記憶體）或 chromium（第二階段，還沒做好前照樣用 WebKit）
    @Published var browserEngine: String { didSet { d.set(browserEngine, forKey: "browserEngine") } }
    /// 幾天沒碰收進封存
    @Published var archiveDays: Int { didSet { d.set(archiveDays, forKey: "archiveDays") } }
    /// 打開對話先載入幾則（往上捲再載入更早的）
    @Published var historyLimit: Int { didSet { d.set(historyLimit, forKey: "historyLimit") } }
    /// 用量多久查一次（分鐘）
    @Published var usageMinutes: Int { didSet { d.set(usageMinutes, forKey: "usageMinutes") } }
    /// 顏色：跟系統、深色、淺色
    @Published var colorScheme: String { didSet { d.set(colorScheme, forKey: "colorScheme"); applyAppearance() } }
    /// 程式碼顏色的配色（CodeColors.schemes）和自訂的顏色
    @Published var codeScheme: String { didSet { d.set(codeScheme, forKey: "codeScheme") } }
    @Published var customCode: [String: String] { didSet { d.set(customCode, forKey: "customCode") } }
    /// 對話文字的字型：terminal＝跟終端機（iTerm）一樣的字型、粗細、大小（預設，使用者 10/22 要的）；system＝系統字型
    @Published var chatFont: String { didSet { d.set(chatFont, forKey: "chatFont") } }
    /// 自動加入正在 tmux／iTerm 裡進行的對話（跟匯入視窗裡的同一個開關）
    @Published var autoImportLive: Bool { didSet { d.set(autoImportLive, forKey: "autoImportLive") } }
    /// 模型清單列出全部；關著（預設）只列常用的：Opus／Sonnet／Haiku 5.5 (cc)、Gemini 3.8 Flash、本機模型（使用者 10/24 要的）
    @Published var allModels: Bool { didSet { d.set(allModels, forKey: "allModels") } }
    /// agy（Google Antigravity CLI）功能的總開關：Gemini 聊天室、灰字建議、用量、看板 @agy 自動做事都靠它。私人版預設開、公版預設關（Edition.agyDefault）；
    /// 從關到開要先看警告（Prefs.confirmEnableAgy），所以設定頁的開關不直接改這個值
    /// 公版：開 App 30 秒後、之後每 24 小時去 GitHub 看有沒有新版（UpdateCheck.swift）；沒有更新來源的私人版用不到
    @Published var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published var agyEnabled: Bool { didSet { d.set(agyEnabled, forKey: "agyEnabled"); Self.syncAgyMarker(agyEnabled) } }
    /// 程式碼學習專區的預設版面（CodeLabView.Mode）：1＝右上程式碼右下結果、2＝F10 整塊換成執行畫面、3＝F10 跳出執行視窗、4＝不用 AI
    @Published var codeLabLayout: Int { didSet { d.set(codeLabLayout, forKey: "codeLabLayout") } }

    private init() {
        defaultModel = d.string(forKey: "defaultModel")
        defaultEffort = d.string(forKey: "defaultEffort")
        permissionMode = d.object(forKey: "permissionMode") == nil ? "auto" : d.string(forKey: "permissionMode").flatMap { $0.isEmpty ? nil : $0 }
        sendWithEnter = d.bool(forKey: "sendWithEnter")
        promptSuggestions = d.object(forKey: "promptSuggestions") as? Bool ?? true
        claudeInChrome = d.object(forKey: "claudeInChrome") as? Bool ?? true
        artifacts = d.object(forKey: "artifacts") as? Bool ?? true
        reconnectOnLaunch = d.object(forKey: "reconnectOnLaunch") as? Bool ?? true
        claudeDebugLog = d.object(forKey: "claudeDebugLog") as? Bool ?? false
        cloudCompactTokens = d.object(forKey: "cloudCompactTokens") as? Int ?? 640_000   // 使用者 10/25 定的預設
        localCompactTokens = d.object(forKey: "localCompactTokens") as? Int ?? 400_000
        browserEngine = d.string(forKey: "browserEngine") ?? "webkit"
        archiveDays = d.object(forKey: "archiveDays") as? Int ?? 7
        historyLimit = d.object(forKey: "historyLimit") as? Int ?? 400
        usageMinutes = d.object(forKey: "usageMinutes") as? Int ?? 5
        colorScheme = d.string(forKey: "colorScheme") ?? "system"
        autoImportLive = d.bool(forKey: "autoImportLive")
        allModels = d.bool(forKey: "allModels")
        codeLabLayout = d.object(forKey: "codeLabLayout") as? Int ?? 1
        autoCheckUpdates = d.object(forKey: "autoCheckUpdates") as? Bool ?? true
        let agy = d.object(forKey: "agyEnabled") as? Bool ?? Edition.agyDefault
        agyEnabled = agy
        Self.syncAgyMarker(agy)
        chatFont = d.string(forKey: "chatFont") ?? "terminal"
        codeScheme = d.string(forKey: "codeScheme") ?? "claude"
        customCode = d.dictionary(forKey: "customCode") as? [String: String] ?? [:]
    }

    /// 看板的背景執行器（scripts/codenv-todo，Python）看不到 UserDefaults：關著時在看板資料夾放一個 agy-disabled 檔，它看到就不叫 agy
    static func syncAgyMarker(_ on: Bool) {
        let url = CollabBoardModel.todoFile.deletingLastPathComponent().appendingPathComponent("agy-disabled")
        if on { try? FileManager.default.removeItem(at: url) }
        else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("agy 功能在 codenv 的設定裡是關著的\n".utf8))
        }
    }

    /// 打開 agy 功能前的警告：引用 Google 官方 FAQ 原文。按「我了解風險，仍要打開」才回傳 true。
    /// 這只是把風險講清楚，不會讓用法變成合規；codenv 也沒有任何隱藏自己的處理
    static func confirmEnableAgy() -> Bool {
        while true {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "打開 agy 功能前，請先看這段"
            a.informativeText = """
            Google 的 Antigravity 官方 FAQ（https://antigravity.google/docs/faq/）寫著：

            "Antigravity CLI headless mode (`agy -p`) is intended for direct scripting and CI workflows. Wrapping `agy` inside third-party coding agents or applications, or automating account rotation, is not supported under consumer plans."

            "Using third-party software, tools, or services to access Antigravity is a violation of our Terms of Service … Such actions can result in suspension or termination of your account."

            codenv 的 Gemini 聊天室、灰字建議、用量查詢、看板 @agy 自動做事，都是用別的程式去呼叫 agy。打開之後，你的 Google 帳號可能被停權，風險由你自己承擔；這個開關不會讓這樣的用法變成合規。
            """
            a.addButton(withTitle: "取消")
            a.addButton(withTitle: "我了解風險，仍要打開")
            a.addButton(withTitle: "看 FAQ 原文")
            switch a.runModal() {
            case .alertSecondButtonReturn: return true
            case .alertThirdButtonReturn: if let u = URL(string: "https://antigravity.google/docs/faq/") { NSWorkspace.shared.open(u) }
            default: return false
            }
        }
    }

    func applyAppearance() {
        switch colorScheme {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
}
