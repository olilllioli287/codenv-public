import AppKit
import Combine

/// App 的各種偏好設定（⌘ , 的「對話」「桌寵與用量」「外觀」頁）。存在 appDefaults（測試 App 另一份）
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = appDefaults

    /// 首頁側欄：commander＝總指揮 Session 清單、tree＝原本的分類樹
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
    /// 網頁外掛的總開關：只切換呈現與執行中的網頁，不改聊天室、掛件或版面資料。
    /// 闔蓋時讓正在做事的聊天室做完這一段（LidKeeper.swift），預設開
    @Published var lidKeepWorking: Bool { didSet { d.set(lidKeepWorking, forKey: "lidKeepWorking") } }
    @Published var webFeaturesEnabled: Bool {
        didSet {
            d.set(webFeaturesEnabled, forKey: "webFeaturesEnabled")
            if webFeaturesEnabled != oldValue { NotificationCenter.default.post(name: Self.webFeaturesChanged, object: nil) }
        }
    }
    static let webFeaturesChanged = Notification.Name("codenv.webFeaturesChanged")
    /// 左欄模式先記設定，畫面切換留到下一步。
    @Published var sidebarMode: String { didSet { d.set(sidebarMode, forKey: "sidebarMode") } }
    /// 瀏覽器格子用哪個核心：webkit（系統內建、省記憶體）或 chromium（第二階段，還沒做好前照樣用 WebKit）
    @Published var browserEngine: String { didSet { d.set(browserEngine, forKey: "browserEngine") } }
    /// Gemini 網頁換皮（GeminiSkin.swift）：預設關
    @Published var geminiSkin: Bool { didSet { d.set(geminiSkin, forKey: "geminiSkin"); BrowserPane.setSkin(geminiSkin) } }
    /// NotebookLM 網頁換皮（NotebookSkin.swift）：預設關
    @Published var notebookSkin: Bool { didSet { d.set(notebookSkin, forKey: "notebookSkin"); BrowserPane.setNotebookSkin(notebookSkin) } }
    @Published var geminiCmdEnter: Bool { didSet { d.set(geminiCmdEnter, forKey: "geminiCmdEnter"); BrowserPane.setGeminiKeys(geminiCmdEnter) } }
    /// 幾天沒碰收進封存
    @Published var archiveDays: Int { didSet { d.set(archiveDays, forKey: "archiveDays") } }
    /// 每日交接（DailyHandoff.swift）：開關、分界時間（時，本地）、一天最多幾件
    @Published var dailyHandoffEnabled: Bool { didSet { d.set(dailyHandoffEnabled, forKey: "dailyHandoffEnabled") } }
    @Published var dailyHandoffHour: Int { didSet { d.set(dailyHandoffHour, forKey: "dailyHandoffHour") } }
    @Published var dailyHandoffMax: Int { didSet { d.set(dailyHandoffMax, forKey: "dailyHandoffMax") } }
    /// 打開對話先載入幾則（往上捲再載入更早的）
    @Published var historyLimit: Int { didSet { d.set(historyLimit, forKey: "historyLimit") } }
    /// 用量多久查一次（分鐘）
    @Published var usageMinutes: Int { didSet { d.set(usageMinutes, forKey: "usageMinutes") } }
    /// 顏色：跟系統、深色、淺色
    @Published var colorScheme: String { didSet { d.set(colorScheme, forKey: "colorScheme"); applyAppearance() } }
    /// 程式碼顏色的配色（CodeColors.schemes）和自訂的顏色
    @Published var codeScheme: String { didSet { d.set(codeScheme, forKey: "codeScheme") } }
    @Published var customCode: [String: String] { didSet { d.set(customCode, forKey: "customCode") } }
    /// 對話文字的字型：terminal＝跟終端機（iTerm）一樣的字型、粗細、大小（預設）；system＝系統字型
    @Published var chatFont: String { didSet { d.set(chatFont, forKey: "chatFont") } }
    /// 自動加入正在 tmux／iTerm 裡進行的對話（跟匯入視窗裡的同一個開關）
    @Published var autoImportLive: Bool { didSet { d.set(autoImportLive, forKey: "autoImportLive") } }
    /// 模型清單列出全部；關著（預設）只列常用的：Opus／Sonnet／Haiku 5.5 (cc)、Gemini 3.8 Flash、本機模型
    @Published var allModels: Bool { didSet { d.set(allModels, forKey: "allModels") } }
    /// agy（Google Antigravity CLI）功能的總開關：Gemini 聊天室、灰字建議、用量、看板 @agy 自動做事都靠它。預設開（Edition.agyDefault）；公版第一次用前要先看過提醒（agyNoticeSeen）；
    /// 從關到開要先看警告（Prefs.confirmEnableAgy），所以設定頁的開關不直接改這個值
    /// 公版：開 App 30 秒後、之後每 24 小時去 GitHub 看有沒有新版（UpdateCheck.swift）；沒有更新來源的私人版用不到
    @Published var autoCheckUpdates: Bool { didSet { d.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    /// 介面語言：system（跟系統：中文就繁中、其他英文）／zh／en；改了要重開才生效（I18n.swift 啟動時決定一次）
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var agyEnabled: Bool { didSet { d.set(agyEnabled, forKey: "agyEnabled"); Self.syncAgyMarker(agyEnabled) } }
    /// 程式碼學習專區的預設版面（CodeLabView.Mode）：1＝右上程式碼右下結果、2＝F10 整塊換成執行畫面、3＝F10 跳出執行視窗、4＝不用 AI
    @Published var codeLabLayout: Int { didSet { d.set(codeLabLayout, forKey: "codeLabLayout") } }

    private init() {
        // 舊版用同一個鍵記 home／codelab；這些舊值視為尚未選過側欄模式
        // 公版沒有私人的九個總指揮：預設用一般的樹狀側欄（使用者自己切到總指揮模式才會有）
        let storedMode = d.string(forKey: "sidebarMode")
        sidebarMode = storedMode == "tree" ? "tree" : (storedMode == nil && Edition.isPublic ? "tree" : "commander")
        defaultModel = d.string(forKey: "defaultModel")
        defaultEffort = d.string(forKey: "defaultEffort")
        permissionMode = d.object(forKey: "permissionMode") == nil ? "auto" : d.string(forKey: "permissionMode").flatMap { $0.isEmpty ? nil : $0 }
        sendWithEnter = d.bool(forKey: "sendWithEnter")
        promptSuggestions = d.object(forKey: "promptSuggestions") as? Bool ?? true
        claudeInChrome = d.object(forKey: "claudeInChrome") as? Bool ?? true
        artifacts = d.object(forKey: "artifacts") as? Bool ?? true
        reconnectOnLaunch = d.object(forKey: "reconnectOnLaunch") as? Bool ?? true
        claudeDebugLog = d.object(forKey: "claudeDebugLog") as? Bool ?? false
        cloudCompactTokens = d.object(forKey: "cloudCompactTokens") as? Int ?? 640_000   // 定的預設
        localCompactTokens = d.object(forKey: "localCompactTokens") as? Int ?? 400_000
        lidKeepWorking = d.object(forKey: "lidKeepWorking") as? Bool ?? true
        webFeaturesEnabled = d.bool(forKey: "webFeaturesEnabled")
        browserEngine = d.string(forKey: "browserEngine") ?? "webkit"
        geminiCmdEnter = d.object(forKey: "geminiCmdEnter") as? Bool ?? true
        geminiSkin = d.object(forKey: "geminiSkin") as? Bool ?? false
        notebookSkin = d.object(forKey: "notebookSkin") as? Bool ?? false
        archiveDays = d.object(forKey: "archiveDays") as? Int ?? 7
        dailyHandoffEnabled = d.object(forKey: "dailyHandoffEnabled") as? Bool ?? true
        dailyHandoffHour = min(23, max(0, d.object(forKey: "dailyHandoffHour") as? Int ?? 6))
        dailyHandoffMax = max(1, d.object(forKey: "dailyHandoffMax") as? Int ?? 15)
        historyLimit = d.object(forKey: "historyLimit") as? Int ?? 400
        usageMinutes = d.object(forKey: "usageMinutes") as? Int ?? 5
        colorScheme = d.string(forKey: "colorScheme") ?? "system"
        autoImportLive = d.bool(forKey: "autoImportLive")
        allModels = d.bool(forKey: "allModels")
        codeLabLayout = d.object(forKey: "codeLabLayout") as? Int ?? 1
        language = d.string(forKey: "language") ?? "system"
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
        // 提醒只是告知、不擋功能（不再放 agy-notice-pending）；舊版留下的標記檔順手清掉
        let dir = CollabBoardModel.todoFile.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("agy-notice-pending"))
        let url = dir.appendingPathComponent("agy-disabled")
        if on { try? FileManager.default.removeItem(at: url) }
        else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("agy 功能在 codenv 的設定裡是關著的\n".utf8))
        }
    }

    /// 看過 agy 預設開啟的提醒了沒（私人版、公版都一樣：新版第一次、而且本機有 agy 時顯示一次）
    var agyNoticeSeen: Bool {
        get { appDefaults.object(forKey: "agyNoticeSeen") as? Bool ?? false }
        set { appDefaults.set(newValue, forKey: "agyNoticeSeen"); Self.syncAgyMarker(agyEnabled) }
    }

    /// 警告內文：兩件事分開講，附 FAQ 原文。不寫「合規」「安全」「官方允許」，也不保證帳號沒事
    private static let agyNoticeBody = L("""
    Google 的 Antigravity 官方 FAQ（https://antigravity.google/docs/faq/）講了兩件事：

    1. 拿 agy 的登入去開第三方軟體（例如 Claude Code、OpenCode）是違反服務條款，可能被停權。codenv 沒有這樣做：它不讀、不轉用你的登入，只是呼叫官方的 `agy -p`。

    2. `agy -p` 是給「直接寫腳本和 CI」用的；把 agy 包進第三方的 coding agent 或 App，個人方案「不支援」。codenv 的 Gemini 聊天室、灰字建議、用量查詢，以及看板讓 Claude 自動派工作給 agy，都屬於這一類。

    FAQ 原文：

    "Antigravity CLI headless mode (`agy -p`) is intended for direct scripting and CI workflows. Wrapping `agy` inside third-party coding agents or applications, or automating account rotation, is not supported under consumer plans."

    "Using third-party software, tools, or services to access Antigravity is a violation of our Terms of Service … Such actions can result in suspension or termination of your account."

    實際狀況請自己查證相關文章與 Google 的最新說明；codenv 不保證你的帳號不會出事，風險由你自己承擔。
    """)

    /// 從關到開時的警告：按「我了解，打開」才回傳 true（同時算看過提醒了）。codenv 沒有任何隱藏自己的處理
    static func confirmEnableAgy() -> Bool {
        while true {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = L("agy 功能：使用前請先知道這件事")
            a.informativeText = agyNoticeBody
            a.addButton(withTitle: L("取消"))
            a.addButton(withTitle: L("我了解，打開"))
            a.addButton(withTitle: L("看 FAQ 原文"))
            switch a.runModal() {
            case .alertSecondButtonReturn: Prefs.shared.agyNoticeSeen = true; return true
            case .alertThirdButtonReturn: if let u = URL(string: "https://antigravity.google/docs/faq/") { NSWorkspace.shared.open(u) }
            default: return false
            }
        }
    }

    /// 預設開著、本機有 agy、還沒看過提醒：App 開啟、回到前景時顯示一次浮動卡片（AgyNoticePanel，不搶焦點）；只告知，不擋功能。
    /// 測試 App（有 --state-dir）沒指定 --agy-notice-answer 知道了｜前往設定 就不顯示（不要出現在使用者的螢幕上）
    private var noticeShowing = false
    func checkAgyNotice() {
        guard agyEnabled, !agyNoticeSeen, AgyBridge.installed, !noticeShowing else { return }
        let a = CommandLine.arguments
        if a.contains("--state-dir") {
            guard let i = a.firstIndex(of: "--agy-notice-answer"), i + 1 < a.count else { return }
            agyNoticeSeen = true
            if a[i + 1] == "前往設定" { Self.openChatSettings() }
            return
        }
        noticeShowing = true
        AgyNoticePanel.show(
            onKnow: { [weak self] in self?.agyNoticeSeen = true; self?.noticeShowing = false },
            onSettings: { [weak self] in self?.agyNoticeSeen = true; self?.noticeShowing = false; Self.openChatSettings() })
    }

    /// 開設定視窗的「對話」頁（agy 開關在那裡）
    static func openChatSettings() {
        appDefaults.set("chat", forKey: "settingsTab")
        (NSApp.delegate as? AppDelegate)?.showChatSettings()
    }

    func applyAppearance() {
        switch colorScheme {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
}
