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
        return c
    }()

    let conversationID: UUID
    let webView: WKWebView
    var petReserve: NSSize = .zero { didSet { if petReserve != oldValue { needsLayout = true } } }
    /// 空白頁：游標放網址列，直接打字（使用者 10/25）；其他：網頁本身
    var focusTarget: NSView { isBlank ? address : webView }
    private var isBlank: Bool { (webView.url?.absoluteString ?? startURL) == Self.home }
    var onTitle: ((String) -> Void)?
    var onURL: ((String) -> Void)?
    /// 縮放比例照網站記：zoomFor 問記過的比例，onZoom 在 ⌘ +/−/0 之後存起來（Workspace 接到 Store）
    var zoomFor: ((String) -> CGFloat?)?
    var onZoom: ((String, CGFloat) -> Void)?
    private var zoomHost: String?
    private(set) var lastActive = Date()

    private let bar = NSView()
    private let back = NSButton(), forward = NSButton(), reload = NSButton(), gemini = NSButton()
    private let address = NSTextField()
    private let progress = NSView()
    private var observers: [NSKeyValueObservation] = []
    private var theme: Theme

    static let barHeight: CGFloat = 34
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

        bar.wantsLayer = true
        addSubview(bar)
        for (b, sym, tip, act) in [(back, "chevron.left", L("上一頁（⌘ [）"), #selector(goBack)), (forward, "chevron.right", L("下一頁（⌘ ]）"), #selector(goForward)),
                                   (reload, "arrow.clockwise", L("重新載入（⌘ R）"), #selector(doReload)), (gemini, "sparkle", L("開 Gemini"), #selector(openGemini))] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            b.toolTip = tip
            b.target = self
            b.action = act
            bar.addSubview(b)
        }
        address.placeholderString = L("輸入網址或要搜尋的字")
        address.font = .systemFont(ofSize: 12)
        address.bezelStyle = .roundedBezel
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingTail
        address.cell?.usesSingleLineMode = true
        address.delegate = self
        bar.addSubview(address)
        progress.wantsLayer = true
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.addSubview(progress)

        observers = [
            webView.observe(\.title) { [weak self] w, _ in if let t = w.title, !t.isEmpty { self?.onTitle?(t) } },
            webView.observe(\.url) { [weak self] w, _ in self?.urlChanged(w.url) },
            webView.observe(\.canGoBack) { [weak self] w, _ in self?.back.isEnabled = w.canGoBack },
            webView.observe(\.canGoForward) { [weak self] w, _ in self?.forward.isEnabled = w.canGoForward },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.needsLayout = true },
            webView.observe(\.isLoading) { [weak self] w, _ in
                self?.reload.image = NSImage(systemSymbolName: w.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
                self?.needsLayout = true
            },
        ]
        back.isEnabled = false; forward.isEnabled = false
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
        if let u = URL(string: t), let s = u.scheme?.lowercased(), ["http", "https", "file", "about"].contains(s) { return u }
        if !t.contains(" "), t.contains(".") || t.hasPrefix("localhost"), let u = URL(string: (t.hasPrefix("localhost") ? "http://" : "https://") + t) { return u }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url
    }

    func load(_ text: String) {
        guard let u = Self.resolve(text) else { return }
        if u.isFileURL { webView.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) }
        else { webView.load(URLRequest(url: u)) }
    }

    private func urlChanged(_ u: URL?) {
        let s = u?.absoluteString ?? ""
        if address.currentEditor() == nil { address.stringValue = s }   // 正在打網址時不要蓋掉
        if !s.isEmpty, s != "about:blank" { onURL?(s) }
        if u?.host != zoomHost { applySavedZoom() }
    }
    /// 換到別的網站（或剛建好）：套用那個網站記過的比例，沒記過就 100%
    func applySavedZoom() {
        zoomHost = webView.url?.host
        webView.pageZoom = zoomHost.flatMap { zoomFor?($0) } ?? 1
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            load(address.stringValue)
            window?.makeFirstResponder(webView)
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            address.stringValue = webView.url?.absoluteString ?? ""
            window?.makeFirstResponder(webView)
            return true
        }
        return false
    }

    /// ⌘ L：跳到網址列
    func focusAddress() { window?.makeFirstResponder(address); address.currentEditor()?.selectAll(nil) }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func doReload() { if webView.isLoading { webView.stopLoading() } else { webView.reload() } }
    @objc private func openGemini() { load(Self.gemini) }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder is NSView, let r = window?.firstResponder as? NSView, r.isDescendant(of: self) else { return super.performKeyEquivalent(with: e) }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
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
        let b = bounds, h = Self.barHeight
        bar.frame = NSRect(x: 0, y: b.height - h, width: b.width, height: h)
        var x: CGFloat = 8
        for btn in [back, forward, reload] { btn.frame = NSRect(x: x, y: (h - 22) / 2, width: 24, height: 22); x += 26 }
        gemini.frame = NSRect(x: b.width - 32, y: (h - 22) / 2, width: 24, height: 22)
        address.frame = NSRect(x: x + 4, y: (h - 22) / 2, width: max(40, gemini.frame.minX - x - 10), height: 22)
        let p = webView.isLoading ? webView.estimatedProgress : 0
        progress.isHidden = p <= 0 || p >= 1
        progress.frame = NSRect(x: 0, y: 0, width: b.width * p, height: 2)
        webView.frame = NSRect(x: 0, y: petReserve.height, width: b.width, height: max(0, b.height - h - petReserve.height))
    }

    func applyTheme(_ t: Theme) {
        theme = t
        let pal = t.palette(for: effectiveAppearance)
        layer?.backgroundColor = pal.bg.cgColor
        bar.layer?.backgroundColor = pal.bg.cgColor
        for b in [back, forward, reload, gemini] { b.contentTintColor = pal.fg.withAlphaComponent(0.7) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if (webView.value(forKey: "drawsBackground") as? Bool) == false { webView.setValue(true, forKey: "drawsBackground") }
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
