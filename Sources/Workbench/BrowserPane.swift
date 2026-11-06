import AppKit
import WebKit

// 瀏覽器格子（使用者 10/25：在 codenv 裡開網頁、Gemini 網頁版，跟 CLI 並排丟檔；AI 讀得到網頁內容）。
// 第一階段用系統的 WebKit（Safari 的核心，最省記憶體）；Chromium 是第二階段，⌘ , 對話頁可以選（還沒做好前選了也是 WebKit）。
// 在側欄是一段「對話」（Conversation.browser＝目前的網址），可以拖、切格子、封存，跟聊天室一樣。
// 登入資料（cookie）放 codenv 專用的 WebKit 資料庫，不碰 Safari、不碰聊天畫面那份；測試 App 用不存檔的。
// AI 只能讀（網址、標題、文字、截圖），透過 BrowserServer.swift 的 Unix socket＋codenv-browser 指令；不能點、不能打字。

extension Conversation {
    var isBrowser: Bool { browser != nil }
}

final class BrowserPane: NSView, ConversationPane, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSTextFieldDelegate {
    /// 所有開著的瀏覽器格子（BrowserServer 列出來給 AI 選）；最近按過的排第一
    static var all: [BrowserPane] { registry.allObjects.sorted { $0.lastActive > $1.lastActive } }
    private static let registry = NSHashTable<BrowserPane>.weakObjects()

    /// codenv 專用的登入資料庫（固定的 id：重開 App 還是同一份，Gemini 不用每次登入）；測試 App 不存檔
    static let dataStore: WKWebsiteDataStore = {
        if appDefaults !== UserDefaults.standard { return .nonPersistent() }
        return WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F0D2C1E-7A0B-4C55-9E0B-C0DE0B0E5E01")!)
    }()
    /// 一個 process pool 共用：多開幾格也不會每格各開一份
    private static let config: WKWebViewConfiguration = {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"   // 裝成 Safari：Google 登入才不會說「這個瀏覽器不安全」
        c.preferences.isElementFullscreenEnabled = true
        installScripts(into: c.userContentController)
        return c
    }()
    /// 注入的腳本（⌘ Enter、版面、換皮）：每次設定改了就整組重裝，新載入的頁用新的
    private static func installScripts(into u: WKUserContentController, keys: Bool? = nil, hide: Bool? = nil, skin: Bool? = nil, nlmSkin: Bool? = nil) {
        u.removeAllUserScripts()
        u.addUserScript(GeminiExport.keysScript(on: keys ?? GeminiExport.keysOn))
        u.addUserScript(GeminiExport.layoutScript(hide: hide ?? GeminiExport.hideHistory))
        u.addUserScript(GeminiSkin.script(on: skin ?? GeminiSkin.on))
        u.addUserScript(NotebookSkin.script(on: nlmSkin ?? NotebookSkin.on))
    }
    /// 設定頁「NotebookLM 換皮」開關：同上
    static func setNotebookSkin(_ on: Bool) {
        installScripts(into: config.userContentController, nlmSkin: on)
        for p in all { p.webView.evaluateJavaScript(NotebookSkin.applyJS(on: on), completionHandler: nil) }
    }
    /// 設定頁「Gemini 換皮」開關：新載入的頁用新的腳本，已經開著的頁直接重套
    static func setSkin(_ on: Bool) {
        installScripts(into: config.userContentController, skin: on)
        for p in all { p.webView.evaluateJavaScript(GeminiSkin.applyJS(on: on), completionHandler: nil) }
    }
    /// 設定頁的「Gemini ⌘ Enter 送出」開關改了：新載入的頁用新的腳本，已經開著的頁直接改變數
    static func setGeminiKeys(_ on: Bool) {
        installScripts(into: config.userContentController, keys: on)
        for p in all { p.webView.evaluateJavaScript("window.__codenvKeysOn = \(on)", completionHandler: nil) }
    }
    /// 圓形按鈕「歷史列表」開／關：新載入的頁用新的腳本，已經開著的頁直接改變數、重套
    static func setHideHistory(_ hide: Bool) {
        appDefaults.set(hide, forKey: "geminiHideHistory")
        installScripts(into: config.userContentController, hide: hide)
        for p in all {
            p.webView.evaluateJavaScript("window.__codenvHideHistory = \(hide); window.__codenvApplyLayout && window.__codenvApplyLayout()", completionHandler: nil)
            p.updateFloatButtons()
        }
    }

    /// NotebookLM 圓鈕「來源欄」「筆記欄」開／關
    static func setNotebook(sources: Bool? = nil, studio: Bool? = nil) {
        if let sources { appDefaults.set(sources, forKey: "notebookShowSources") }
        if let studio { appDefaults.set(studio, forKey: "notebookShowStudio") }
        installScripts(into: config.userContentController)
        for p in all {
            p.webView.evaluateJavaScript("window.__codenvShowSources = \(GeminiExport.showSources); window.__codenvShowStudio = \(GeminiExport.showStudio); window.__codenvApplyLayout && window.__codenvApplyLayout()", completionHandler: nil)
            p.updateFloatButtons()
        }
    }

    let conversationID: UUID
    let webView: WKWebView
    var petReserve: NSSize = .zero { didSet { if petReserve != oldValue { needsLayout = true } } }
    /// 空白頁：游標放網址列，直接打字（使用者 10/25）；其他：網頁本身
    var focusTarget: NSView { if isBlank { showAddress(); return address }; return webView }
    private var isBlank: Bool { (webView.url?.absoluteString ?? startURL) == Self.home }
    var onTitle: ((String) -> Void)?
    var onURL: ((String) -> Void)?
    /// 縮放比例照網站記：zoomFor 問記過的比例，onZoom 在 ⌘ +/−/0 之後存起來（Workspace 接到 Store）
    var zoomFor: ((String) -> CGFloat?)?
    var onZoom: ((String, CGFloat) -> Void)?
    private var zoomHost: String?
    private(set) var lastActive = Date()

    /// 整條網址列拿掉了（使用者 10/29：「這個都拿掉」）：⌘ L 才在格子頂端浮出一個網址輸入框；空白頁自動浮出
    private let addressBox = NSView()
    private let address = NSTextField()
    /// 匯出進行中（浮動匯出鈕的忙碌狀態）
    private var exporting = false
    /// Gemini 頁面右上角浮在網頁上的圓形功能鍵（原生 NSView，不注入網頁，Gemini 改版也壞不了）：匯出對話、歷史列表開／關
    private let floatExport = FloatButton(), floatHistory = FloatButton(), floatGemini = FloatButton(), floatSources = FloatButton(), floatStudio = FloatButton()
    private let progress = NSView()
    private var observers: [NSKeyValueObservation] = []
    private var theme: Theme

    /// 一般瀏覽器格子的首頁：空白頁，游標停在網址列（使用者 10/25：瀏覽器不該預設開 Gemini）
    static let home = "about:blank"
    /// 網址列旁邊那顆 ✦ 和 Gemini 掛件開的
    static let gemini = "https://gemini.google.com/app"

    init(conversation: UUID, url: String, theme: Theme) {
        conversationID = conversation
        self.theme = theme
        webView = WKWebView(frame: .zero, configuration: Self.config)
        super.init(frame: .zero)
        Self.registry.add(self)
        wantsLayer = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = appDefaults !== UserDefaults.standard
        addSubview(webView)

        floatExport.symbol = "square.and.arrow.down"
        floatExport.toolTip = L("匯出這段 Gemini 對話（Markdown＋圖片，存到「下載項目」）")
        floatExport.target = self; floatExport.action = #selector(exportChat)
        floatHistory.symbol = "sidebar.left"
        floatHistory.target = self; floatHistory.action = #selector(toggleHistory)
        floatGemini.symbol = "sparkle"
        floatGemini.toolTip = L("開 Gemini")
        floatGemini.target = self; floatGemini.action = #selector(openGemini)
        floatSources.symbol = "books.vertical"
        floatSources.target = self; floatSources.action = #selector(toggleSources)
        floatStudio.symbol = "square.stack.3d.up"
        floatStudio.target = self; floatStudio.action = #selector(toggleStudio)
        for b in floatButtons { b.isHidden = true; addSubview(b, positioned: .above, relativeTo: webView) }
        addressBox.wantsLayer = true
        addressBox.layer?.cornerRadius = 8
        addressBox.layer?.borderWidth = 1
        addressBox.isHidden = true
        addSubview(addressBox, positioned: .above, relativeTo: webView)
        address.placeholderString = L("輸入網址或要搜尋的字")
        address.font = .systemFont(ofSize: 12)
        address.bezelStyle = .roundedBezel
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingTail
        address.cell?.usesSingleLineMode = true
        address.delegate = self
        addressBox.addSubview(address)
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        addSubview(progress, positioned: .above, relativeTo: webView)

        observers = [
            webView.observe(\.title) { [weak self] w, _ in if let t = w.title, !t.isEmpty { self?.onTitle?(t) } },
            webView.observe(\.url) { [weak self] w, _ in self?.urlChanged(w.url) },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.needsLayout = true },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.needsLayout = true },
        ]
        applyTheme(theme)
        startURL = url.isEmpty ? Self.home : url
        // 第一頁載完之前網頁不畫白底（透出底下的主題底色）：還沒載入的 WKWebView 是一整片白，從右邊滑進來時會閃白（使用者 10/25）。
        // 載完再畫回白底：沒自己設背景色的網頁照常是白的
        if startURL != Self.home { webView.setValue(false, forKey: "drawsBackground") }
        load(startURL)
    }
    /// 一開始要開的網址（還沒載入完時 webView.url 是 nil，用這個判斷是不是空白頁）
    private var startURL = ""
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 網址列

    /// 打的是網址就開網址，不像網址就用 Google 搜尋
    static func resolve(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let c = URLComponents(string: t), let s = c.scheme?.lowercased(), ["http", "https", "file", "about"].contains(s), let u = c.url { return canonicalNotebookURL(u) }
        if !t.contains(" "), t.contains(".") || t.hasPrefix("localhost"),
           let c = URLComponents(string: (t.hasPrefix("localhost") ? "http://" : "https://") + t), let u = c.url { return canonicalNotebookURL(u) }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url
    }

    static func canonicalNotebookURL(_ u: URL) -> URL {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false),
              let host = c.host?.lowercased(),
              host == "notebooklm.google.com" || host == "www.notebooklm.google.com" else { return u }
        c.host = "notebook.google.com"
        c.scheme = "https"
        return c.url ?? u
    }

    func load(_ text: String) {
        guard let u = Self.resolve(text) else { return }
        if u.isFileURL { webView.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) }
        else { webView.load(URLRequest(url: u)) }
    }

    private func urlChanged(_ u: URL?) {
        let s = u?.absoluteString ?? ""
        updateFloatButtons()
        if address.currentEditor() == nil { address.stringValue = s == Self.home ? "" : s }   // 正在打網址時不要蓋掉；空白頁留空，提示文字才看得到
        if !s.isEmpty, s != "about:blank" { onURL?(s); if !addressBox.isHidden, address.currentEditor() == nil { hideAddress() } }
        if u?.host != zoomHost { applySavedZoom() }
    }
    private var floatButtons: [FloatButton] { [floatGemini, floatExport, floatHistory, floatSources, floatStudio] }
    /// 右上角的圓鈕群：✦ 開 Gemini 每個網頁都有；匯出和歷史列表只在 Gemini；來源欄和筆記欄只在 NotebookLM。由上往下排，隱藏的不佔位置
    func updateFloatButtons() {
        let u = webView.url
        let g = GeminiExport.isGemini(u), nb = GeminiExport.isNotebook(u)
        floatGemini.isHidden = false
        if isBlank { showAddress() }
        floatExport.isHidden = !g; floatHistory.isHidden = !g
        floatSources.isHidden = !nb; floatStudio.isHidden = !nb
        floatExport.isEnabled = !exporting && GeminiExport.isConversation(u)
        let hidden = GeminiExport.hideHistory
        floatHistory.active = !hidden
        floatHistory.toolTip = hidden ? L("歷史列表：已隱藏（點一下顯示）") : L("歷史列表：顯示中（點一下隱藏）")
        floatSources.active = GeminiExport.showSources
        floatSources.toolTip = GeminiExport.showSources ? L("來源欄：顯示中（點一下隱藏）") : L("來源欄：已隱藏（點一下顯示）")
        floatStudio.active = GeminiExport.showStudio
        floatStudio.toolTip = GeminiExport.showStudio ? L("筆記欄：顯示中（點一下隱藏）") : L("筆記欄：已隱藏（點一下顯示）")
        needsLayout = true
    }
    @objc private func toggleHistory() { Self.setHideHistory(!GeminiExport.hideHistory) }
    @objc private func toggleSources() { Self.setNotebook(sources: !GeminiExport.showSources) }
    @objc private func toggleStudio() { Self.setNotebook(studio: !GeminiExport.showStudio) }

    /// 換到別的網站（或剛建好）：套用那個網站記過的比例，沒記過就 100%
    func applySavedZoom() {
        zoomHost = webView.url?.host
        webView.pageZoom = zoomHost.flatMap { zoomFor?($0) } ?? 1
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            load(address.stringValue)
            hideAddress()
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            let cur = webView.url?.absoluteString ?? ""
            address.stringValue = cur == Self.home ? "" : cur
            hideAddress()
            return true
        }
        return false
    }

    /// ⌘ L：跳到網址列
    func focusAddress() { showAddress(); window?.makeFirstResponder(address); address.currentEditor()?.selectAll(nil) }
    private func showAddress() { if addressBox.isHidden { addressBox.isHidden = false; needsLayout = true } }
    /// Enter／Esc／點到別處之後收起來；空白頁沒有網頁可看，網址框一直留著
    private func hideAddress() {
        if !isBlank { addressBox.isHidden = true; needsLayout = true }
        // 焦點還在網址框（正在打的 field editor 也掛在它底下）才交給網頁；網頁載入完、轉址時才呼叫到這裡的話，
        // 使用者可能已經點到別格在打字，不要搶走（Google 登入會跳好幾次）
        if let fr = window?.firstResponder as? NSView, fr.isDescendant(of: addressBox) { window?.makeFirstResponder(webView) }
    }
    func controlTextDidEndEditing(_ obj: Notification) { if !isBlank { addressBox.isHidden = true; needsLayout = true } }   // 這時 currentEditor 還沒收掉，不能拿它判斷

    /// F5：重新載入（載入中就停止）
    func reloadPage() { if webView.isLoading { webView.stopLoading() } else { webView.reload() } }
    @objc private func openGemini() { load(Self.gemini) }

    /// 網址列旁的「匯出對話」：存到 ~/Downloads/<標題>-<時間>/，完成後在 Finder 顯示；有圖抓不到時說一聲
    @objc func exportChat() {
        guard !exporting, GeminiExport.isConversation(webView.url) else { return }
        exporting = true
        floatExport.isEnabled = false
        floatExport.toolTip = L("匯出中…（舊的訊息要先捲上去載入，可能要幾十秒）")
        exportGemini { [weak self] r in
            guard let self else { return }
            self.exporting = false
            self.updateFloatButtons()
            self.floatExport.toolTip = L("匯出這段 Gemini 對話（Markdown＋圖片，存到「下載項目」）")
            switch r {
            case .success(let o):
                NSWorkspace.shared.activateFileViewerSelecting([o.folder])
                guard !o.failed.isEmpty || o.emptyUsers > 0, let w = self.window else { return }
                let a = NSAlert()
                if o.emptyUsers > 0 {
                    a.messageText = L("匯出完成，但有 \(o.emptyUsers) 輪你的訊息沒抓到")
                    a.informativeText = L("那幾輪的文字和圖片都是空的（可能是 Gemini 網頁的結構跟預期不同）。資料夾裡的 diag.json 記了網頁的標籤摘要（沒有對話內容），把它交給 Claude 就能查原因。")
                    if !o.failed.isEmpty { a.informativeText += "\n\n" + L("另外有 \(o.failed.count) 張圖沒抓到，chat.md 裡保留原網址。") }
                } else {
                    a.messageText = L("匯出完成，但有 \(o.failed.count) 張圖沒抓到")
                    a.informativeText = L("對話文字和其他圖片都存好了；沒抓到的圖在 chat.md 裡保留原網址（網址可能過一陣子就失效）。")
                }
                a.beginSheetModal(for: w, completionHandler: nil)
            case .failure(let e):
                guard let w = self.window else { return }
                let a = NSAlert(); a.messageText = L("匯出失敗"); a.informativeText = e.localizedDescription
                a.beginSheetModal(for: w, completionHandler: nil)
            }
        }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder is NSView, let r = window?.firstResponder as? NSView, r.isDescendant(of: self) else { return super.performKeyEquivalent(with: e) }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌘ +（鍵盤上是 ⌘ ⇧ =）帶著 shift：也要放大
        if mods == [.command, .shift], e.charactersIgnoringModifiers == "+" { zoom(+1); return true }
        guard mods == .command else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers {
        case "l": focusAddress(); return true
        case "r": webView.reload(); return true
        case "[": webView.goBack(); return true
        case "]": webView.goForward(); return true
        case "=", "+": zoom(+1); return true
        case "-": zoom(-1); return true
        case "0": webView.magnification = 1; setZoom(1); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    /// ⌘ + / ⌘ −：跟 Safari 一樣用 pageZoom（網頁照新字級重新排版，寬度跟著格子）；
    /// magnification 只是把畫面放大，網頁不重排，右邊會被切掉
    private static let zoomSteps: [CGFloat] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]
    func zoom(_ dir: Int) {
        let z = webView.pageZoom
        let next = dir > 0 ? Self.zoomSteps.first { $0 > z + 0.001 } : Self.zoomSteps.last { $0 < z - 0.001 }
        if let next { setZoom(next) }
    }
    /// 存起來，同一個網站的其他格子也一起換
    private func setZoom(_ z: CGFloat) {
        webView.pageZoom = z
        guard let h = webView.url?.host else { return }
        onZoom?(h, z)
        for p in Self.registry.allObjects where p !== self && p.webView.url?.host == h { p.webView.pageZoom = z }
    }

    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        if v != nil, NSApp.currentEvent?.type == .leftMouseDown { lastActive = Date() }
        return v
    }

    // MARK: 版面

    override func layout() {
        super.layout()
        let b = bounds
        webView.frame = NSRect(x: 0, y: petReserve.height, width: b.width, height: max(0, b.height - petReserve.height))
        let p = webView.isLoading ? webView.estimatedProgress : 0
        progress.isHidden = p <= 0 || p >= 1
        progress.frame = NSRect(x: 0, y: b.height - 2, width: b.width * p, height: 2)
        // 浮出的網址框：格子頂端置中，最寬 560
        let aw = min(560, max(120, b.width - 28))
        addressBox.frame = NSRect(x: (b.width - aw) / 2, y: b.height - 40, width: aw, height: 30)
        address.frame = NSRect(x: 6, y: 4, width: aw - 12, height: 22)
        // 圓形功能鍵：網頁內容右上角往下一點（不擋網頁自己右上的按鈕），由上往下排，隱藏的跳過
        let d = FloatButton.diameter
        var y = webView.frame.maxY - 70
        for btn in floatButtons where !btn.isHidden {
            btn.frame = NSRect(x: b.width - 14 - d, y: y - d, width: d, height: d)
            y -= d + 8
        }
    }

    func applyTheme(_ t: Theme) {
        theme = t
        let pal = t.palette(for: effectiveAppearance)
        layer?.backgroundColor = pal.bg.cgColor
        addressBox.layer?.backgroundColor = pal.bg.cgColor
        addressBox.layer?.borderColor = pal.fg.withAlphaComponent(0.25).cgColor
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if (webView.value(forKey: "drawsBackground") as? Bool) == false { webView.setValue(true, forKey: "drawsBackground") }
        if let host = Self.logHost(webView.url) { EventLog.log("瀏覽器", "載入完成：\(host)") }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { logLoadFailure(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { logLoadFailure(error) }

    private func logLoadFailure(_ error: Error) {
        let ns = error as NSError
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? webView.url
        let host = Self.logHost(failing) ?? "未知主機"
        EventLog.log("瀏覽器", "載入失敗：\(host)（\(ns.domain) \(ns.code)）")
    }

    /// 事件紀錄只記主機名稱（不記路徑與查詢參數；空白頁略過）
    private static func logHost(_ u: URL?) -> String? {
        guard let u, u.absoluteString != home else { return nil }
        if u.isFileURL { return "file" }
        return u.host.flatMap { $0.isEmpty ? nil : $0 }
    }

    func terminate() {
        observers = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        Self.registry.remove(self)
    }

    // MARK: 給 AI 讀（BrowserServer 叫）

    var currentURL: String { webView.url?.absoluteString ?? "" }
    var currentTitle: String { webView.title ?? "" }

    /// 網頁上看得到的文字（document.body.innerText），最多 max 個字
    func pageText(max: Int, done: @escaping (String) -> Void) {
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { r, _ in
            let s = (r as? String) ?? ""
            done(s.count > max ? String(s.prefix(max)) + "\n" + L("…（後面還有 \(s.count - max) 字，用 --max 調大）") : s)
        }
    }

    /// 目前看得到的範圍截成 PNG
    func snapshot(done: @escaping (Data?) -> Void) {
        webView.takeSnapshot(with: nil) { img, _ in
            guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return done(nil) }
            done(rep.representation(using: .png, properties: [:]))
        }
    }

    // MARK: WebKit

    /// target=_blank 的連結、window.open：在同一格打開（沒有分頁）
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let u = action.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    /// 網頁要你選檔案（Gemini 的「上傳檔案」）：跳系統的選檔視窗
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        guard let w = window else { return completionHandler(nil) }
        p.beginSheetModal(for: w) { r in completionHandler(r == .OK ? p.urls : nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let w = window else { return completionHandler() }
        let a = NSAlert(); a.messageText = frame.request.url?.host ?? L("網頁"); a.informativeText = message
        a.beginSheetModal(for: w) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let w = window else { return completionHandler(false) }
        let a = NSAlert(); a.messageText = frame.request.url?.host ?? L("網頁"); a.informativeText = message
        a.addButton(withTitle: L("好")); a.addButton(withTitle: L("取消"))
        a.beginSheetModal(for: w) { r in completionHandler(r == .alertFirstButtonReturn) }
    }

    /// 網頁要用麥克風／相機：問系統（macOS 會跳權限詢問）
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    /// 顯示不了的檔案（壓縮檔、pdf 以外的附件）就下載
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    /// 下載放「下載項目」，同名就加 (2)、(3)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? L("下載") : suggestedFilename.replacingOccurrences(of: "/", with: "_")
        var url = dir.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : "." + ext)); n += 1
        }
        completionHandler(url)
    }
    func downloadDidFinish(_ download: WKDownload) {}
}


/// 浮在網頁上的圓形按鈕：半透明深色底，滑鼠移上去變亮
final class FloatButton: NSButton {
    static let diameter: CGFloat = 34
    var symbol = "circle" { didSet { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)); contentTintColor = .white } }
    /// 開著的狀態：底色帶強調色
    var active = false { didSet { refresh() } }
    private var hover = false { didSet { refresh() } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4 } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    private func refresh() {
        let base: NSColor = active ? NSColor.controlAccentColor : NSColor.black
        layer?.backgroundColor = base.withAlphaComponent(hover ? 0.88 : (active ? 0.6 : 0.5)).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(hover ? 0.5 : 0.2).cgColor
    }
}
