import AppKit
import WebKit
import SwiftUI
import Combine

/// 對話內容的網頁元件：檔案、圖片拖進來不要讓網頁吃掉（會被當成「打開這個檔案」），交給輸入框
final class DropWebView: WKWebView {
    var onDrop: ((NSPasteboard) -> Bool)?
    private func wanted(_ pb: NSPasteboard) -> Bool {
        if DropOverlay.conversation(in: pb) != nil { return false }
        return pb.availableType(from: [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]) != nil
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { wanted(s.draggingPasteboard) ? .copy : super.draggingEntered(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { wanted(s.draggingPasteboard) ? .copy : super.draggingUpdated(s) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { wanted(s.draggingPasteboard) ? true : super.prepareForDragOperation(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        ChatTextView.dropLog("對話內容 收=\(wanted(s.draggingPasteboard))", s.draggingPasteboard)
        if wanted(s.draggingPasteboard) { return onDrop?(s.draggingPasteboard) ?? false }
        return super.performDragOperation(s)
    }
}

/// 右邊一格對話要有的東西：聊天或終端機都一樣
protocol ConversationPane: NSView {
    var focusTarget: NSView { get }
    /// 右下角讓給桌寵的空間（只有畫面最右下那一格會有）
    var petReserve: NSSize { get set }
    func terminate()
    func applyTheme(_ t: Theme)
}

extension TerminalPane: ConversationPane {
    var focusTarget: NSView { terminal }
    func applyTheme(_ t: Theme) { theme = t; applyTheme() }
}

/// WKWebView 會強留 message handler，中間隔一層 weak 才不會互相抓住
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: ChatPane?
    init(_ t: ChatPane) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.received(m) }
}

/// 聊天介面的一格：上面是對話內容（網頁畫面 Resources/chat），下面是原生輸入框
final class ChatPane: NSView, ConversationPane, WKNavigationDelegate {
    let session: ChatSession
    private let web: DropWebView
    let inputBar = ChatInputBar()
    /// 程式碼學習專區：右邊的程式碼區（CodeLab.swift）；其他組的對話沒有
    private(set) var codeLab: CodeLabView?
    private let codeDivider = CodeLabDivider()
    private var codeShare: CGFloat = CGFloat(appDefaults.object(forKey: "codeLabShare") as? Double ?? 0.55)
    private var theme: Theme
    private var ready = false
    private var queued: [String] = []
    /// 對話壓縮完（本機模型的自動壓縮在回答完之後才做完）：md 紀錄要再寫一次，摘要才會進去
    var onCompacted: (() -> Void)?
    /// 背景替這段對話跑的模型（nil＝沒有）：右側欄「使用中」用
    var onBackgroundModel: ((String?) -> Void)?
    var onStatus: ((ChatStatus) -> Void)?
    /// 第一次送出時給標題用
    var onFirstMessage: ((String) -> Void)?
    /// 要求變成目前這格（拖放進來時：之後切回 App 的游標也放在這格）
    var onWantFocus: (() -> Void)?
    /// 這格是哪段對話（給上下文大小用）
    var conversationID: UUID?
    /// 使用者換了模型（存到對話裡）
    var onModelChange: ((String?) -> Void)?
    /// Claude 回報實際在用的模型（右側欄顯示用）
    var onResolvedModel: ((String) -> Void)?
    var onEffortChange: ((String?) -> Void)?
    var onPermissionModeChange: ((String?) -> Void)?
    var openSettings: (() -> Void)?
    private var resolvedModel = ""
    private var sentAny = false
    /// 換模型前那個模型的紀錄檔：新的模型看不到前面的對話，下一則送出時附一行告訴它去哪裡讀
    private var carryFrom: URL?
    private var carryName: String?      // 換之前的模型叫什麼（輸入框右下角顯示的名字，交接時寫給新模型看）

    var focusTarget: NSView { inputBar.textView }
    var petReserve: NSSize = .zero { didSet { if petReserve != oldValue { needsLayout = true } } }
    private var lastPetInset = NSSize.zero

    static var chatFolder: URL {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("chat"), FileManager.default.fileExists(atPath: u.appendingPathComponent("index.html").path) { return u }
        // 直接跑 .build 裡的執行檔時：用原始碼旁邊的
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/chat")
    }

    init(session: ChatSession, theme: Theme) {
        self.session = session
        self.theme = theme
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Markdown 裡的本機圖片：走 codenv-img://（LocalImages.swift），網頁本身還是只能讀 chat 資料夾
        config.setURLSchemeHandler(LocalImageScheme.shared, forURLScheme: LocalImageScheme.scheme)
        web = DropWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        config.userContentController.add(WeakHandler(self), name: "wb")
        // 英文介面：對照表在 chat.js 開始跑之前就放好（畫面一建好的字，例如「正在處理」，也要是英文）
        if I18n.isEnglish { config.userContentController.addUserScript(WKUserScript(source: "window.__LOCALE=\(I18n.tableJSON);", injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
        addSubview(inputBar)
        let index = Self.chatFolder.appendingPathComponent("index.html")
        web.loadFileURL(index, allowingReadAccessTo: Self.chatFolder)

        inputBar.onSend = { [weak self] text, images, now in self?.send(text: text, images: images, now: now) }
        web.onDrop = { [weak self] pb in self?.inputBar.takeDrop(pb) ?? false }
        inputBar.onModelButton = { [weak self] v in self?.showModelPanel(from: v) }
        session.onModel = { [weak self] m in self?.resolvedModel = m; self?.refreshModelTitle(); self?.onResolvedModel?(m) }
        session.onModels = { [weak self] _ in self?.refreshModelTitle() }
        session.onCommands = { [weak self] l in self?.inputBar.commands = l }
        inputBar.onCycleMode = { [weak self] in self?.cycleMode() }
        session.onPermissionMode = { [weak self] m in self?.refreshMode(); self?.onPermissionModeChange?(m) }
        session.onPermissionModeError = { [weak self] err in
            guard let self else { return }
            self.refreshMode()
            self.onPermissionModeChange?(self.session.permissionMode)
            self.js("wb.notice(\(Self.jsString(L("沒辦法換權限模式：\(err)"))))")
        }
        inputBar.onStop = { [weak self] in
            guard let self else { return }
            ChatTextView.dropLog("按了停止（Esc、⌃ C 或停止鍵）\(self.conversationTitleForLog)", nil)
            self.session.interrupt()
        }
        inputBar.onSendQueuedNow = { [weak self] in self?.js("wb.sendQueuedNow()") }
        // 拖東西進來：工作台跳到最前面、游標進這格的輸入框，放完直接 ⌘ Enter 就能送
        inputBar.onDropped = { [weak self] in
            guard let self, !CommandLine.arguments.contains("--background") else { return }   // 背景測試不要搶走前景
            self.onWantFocus?()
            NSApp.activate()
            self.window?.makeKeyAndOrderFront(nil)
            self.focusInput()
        }
        inputBar.onBlur = { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self.web) }
        session.onLine = { [weak self] line, obj in
            guard let self else { return }
            let type = obj["type"] as? String
            self.markOwnActivity(final: type == "result")
            SessionActivity.shared.observe(obj, conversation: self.conversationID, directory: self.session.directory)
            // Gemini（agy）、ChatGPT（codex）、Copilot、本機模型自己不會猜下一句：每輪結束另外猜（NextGuess.swift；Flash 的聊天室用 Flash，其他用 Apple）
            let s = self.session
            if s.agyModel != nil || s.codexModel != nil || s.copilotModel != nil || s.mlxModel != nil || s.appleModel != nil {
                self.nextGuess.saw(obj, flash: s.agyModel?.hasPrefix("gemini-3.8-flash") == true) { [weak self] s in
                    guard let self, self.session.status == .idle, self.inputBar.textView.string.isEmpty else { return }
                    self.inputBar.suggestion = s
                }
            }
            // 回答完 Claude 猜的下一句：放進輸入框當灰字
            if type == "prompt_suggestion" {
                if let s = obj["suggestion"] as? String, self.session.status == .idle { self.inputBar.suggestion = s }
                return
            }
            // Claude 讀進了使用者的訊息（--replay-user-messages 回送的那份）：排隊中的泡泡移到對話裡
            if type == "user", obj["isReplay"] as? Bool == true {
                if let u = obj["uuid"] as? String { self.js("wb.userTaken(\(Self.jsString(u)))") }
                return
            }
            // 這一輪結束：紀錄檔到這裡都是自己寫的，同步顯示之後從這裡接（不然會把自己的訊息再貼一次）
            if type == "result", let url = self.session.transcriptURL,
               let n = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                self.followOffset = UInt64(n); self.followPartial = Data()
            }
            // Claude 收回權限詢問：畫面上那張卡也收掉，不要還能按
            if type == "control_cancel_request", let id = obj["request_id"] as? String {
            self.js("wb.permissionResolved(\(Self.jsString(id)), \(Self.jsString(L("Claude 收回了這個詢問"))))")
            }
            self.js("wb.event(\(line))")
            ContextMonitor.shared.observe(obj, conversation: self.conversationID)
            if obj["type"] as? String == "system", obj["subtype"] as? String == "status" {
                self.onBackgroundModel?(obj["status"] as? String == "compacting" ? L("Claude Haiku・背景整理摘要") : nil)
            }
            if obj["type"] as? String == "system", obj["subtype"] as? String == "compact_boundary",
               let m = obj["compact_metadata"] as? [String: Any] {
                let pre = (m["pre_tokens"] as? NSNumber)?.intValue ?? 0, post = (m["post_tokens"] as? NSNumber)?.intValue ?? 0
                self.js("wb.notice(\(Self.jsString(L("已壓縮對話：\(ContextMonitor.text(pre)) → \(ContextMonitor.text(post)) token（原本的紀錄檔還在）"))))")
                self.onCompacted?()
            }
        }
        session.onStatus = { [weak self] s in
            guard let self else { return }
            self.inputBar.busy = s != .idle
            self.js("wb.setBusy(\(s != .idle))")
            self.onStatus?(s)
        }
        session.onExit = { [weak self] code, err in
            guard let self else { return }
            let who = self.agentName
            self.js("wb.resolveAllPermissions(\(Self.jsString(L("\(who) 已經結束，這個詢問作廢了"))))")
            self.js("wb.flushQueued()")
            if let id = self.conversationID { SessionActivity.shared.clear(id) }   // 程序沒了，還沒回答的詢問也作廢
            guard code != 0 && code != 15 else { return }
            let tail = err.split(separator: "\n").suffix(3).joined(separator: " / ")
            self.js("wb.notice(\(Self.jsString(L("\(who) 結束了（\(code)）\(tail.isEmpty ? "" : "：" + tail)。再送一則訊息會重新接上。"))))")
        }
        wantsLayer = true
        applyTheme(theme)
        // 整體文字大小：對話內容用網頁縮放、輸入框換字級
        applyScale()
        scaleSink = UIScale.shared.$factor.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyScale() }
        // 設定頁換了程式碼顏色：馬上套用
        prefsSink = Prefs.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.applyTheme(self.theme) }
        }
    }

    private var scaleSink: AnyCancellable?
    private var prefsSink: AnyCancellable?
    private func applyScale() {
        web.pageZoom = UIScale.shared.f
        inputBar.setFontScale(UIScale.shared.f)
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 有桌寵空位：輸入框讓出右邊；對話區高度不變（空位疊在它右下角），只有內容最底下多留一段，最新的字停在桌寵上面
        let r = petReserve
        // 有程式碼區：左邊聊天、右邊程式碼（中間那條可以拖）
        var cw = bounds.width
        // 不用 AI 的版面：程式碼區佔滿整格，聊天先收起來（換回別的版面就回來）
        let noAI = codeLab?.mode == .noAI
        [web, inputBar, codeDivider].forEach { $0.isHidden = noAI }
        if noAI, let lab = codeLab { lab.frame = bounds; return }
        if let lab = codeLab {
            cw = (bounds.width * (1 - codeShare)).rounded()
            codeDivider.frame = NSRect(x: cw - 3, y: 0, width: 6, height: bounds.height)
            lab.frame = NSRect(x: cw + 3, y: 0, width: max(0, bounds.width - cw - 3), height: bounds.height)
            cw -= 3
        }
        let h = inputBar.fittingHeight(width: cw - (codeLab == nil ? r.width : 0))
        inputBar.frame = NSRect(x: 0, y: 0, width: cw - (codeLab == nil ? r.width : 0), height: h)
        web.frame = NSRect(x: 0, y: h, width: cw, height: max(0, bounds.height - h))
        let inset = r == .zero ? NSSize.zero : NSSize(width: r.width, height: max(0, r.height - h))
        if inset != lastPetInset {
            lastPetInset = inset
            js("wb.setPetInset(\(Int(inset.width)), \(Int(inset.height)))")
        }
    }

    /// 開右邊的程式碼區（程式放在 directory）
    func attachCodeLab(directory: String, key: String) {
        guard codeLab == nil else { return }
        let lab = CodeLabView(directory: directory, key: key, theme: theme)
        codeLab = lab
        addSubview(codeDivider)
        addSubview(lab)
        lab.onModeChange = { [weak self] in self?.needsLayout = true }
        codeDivider.onDrag = { [weak self] x in
            guard let self else { return }
            let local = self.convert(NSPoint(x: x, y: 0), from: nil).x
            self.codeShare = max(0.25, min(0.75, 1 - local / max(1, self.bounds.width)))
            appDefaults.set(Double(self.codeShare), forKey: "codeLabShare")
            self.needsLayout = true
        }
        needsLayout = true
    }

    func applyTheme(_ t: Theme) {
        codeLab?.applyTheme(t)
        theme = t
        let pal = t.palette(for: effectiveAppearance)
        layer?.backgroundColor = pal.bg.cgColor
        inputBar.applyTheme(pal, mono: t.font)
        refreshMode()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var obj: [String: Any] = ["fg": pal.fg.hex, "bg": pal.bg.hex, "ansi": pal.ansi.map(\.hex),
                                  "monoFont": t.font.fontName, "monoSize": t.font.pointSize, "dark": dark]
        // 對話文字跟終端機一樣：同一個字型、粗細；大小在預設的介面縮放下剛好等於終端機的點數
        let termText = Prefs.shared.chatFont == "terminal"
        if termText {
            obj["bodyFont"] = t.font.familyName ?? t.font.fontName
            obj["bodyWeight"] = Self.cssWeight(t.font)
            obj["bodySize"] = Double(t.font.pointSize) / UIScale.defaultFactor
        }
        inputBar.textFont = termText ? t.font : nil
        if I18n.isEnglish { js("wb.setLocale(\(I18n.tableJSON))") }     // 英文介面：chat.js 的 L() 用同一份對照表（要在 setTheme 之前，畫面才一開始就是英文）
        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { js("wb.setTheme(\(s))") }
        js(CodeColors.js(palette: pal, dark: dark))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(theme)
    }

    func terminate() { followTimer?.invalidate(); session.terminate() }

    // MARK: 模型

    /// 這格實際在跑的是誰（提示文字用）
    var agentName: String {
        session.agyModel != nil ? "Gemini" : session.codexModel != nil ? "ChatGPT" : session.copilotModel != nil ? "Copilot"
            : session.appleModel != nil ? L("Apple 模型")
            : session.mlxModel != nil || session.localEndpoint != nil ? L("本機模型") : "Claude"
    }

    func refreshModelTitle() {
        refreshModelName()
        // 沒自己選過強度就顯示預設的（跟模型面板拉桿停的位置一樣）
        guard session.localEndpoint == nil, let e = session.effort ?? defaultEffortNow else { return }
        // agy 只有低中高三段（換名字尾巴），從 Claude 帶來的 xhigh、max 不算數
        let few = session.agyModel != nil ? AgyBridge.levels : session.copilotModel != nil ? CopilotBridge.levels : session.mlxModel != nil ? LocalBridge.levels(session.mlxModel)
            : session.appleModel != nil ? [] : nil
        if few?.contains(e) ?? true { inputBar.modelTitle += " · " + Effort.name(e) }
    }

    /// 沒選過強度時實際用的那段：各家的預設，Claude 看 settings.json 裡這個模型的 effortLevel
    private var defaultEffortNow: String? {
        if let m = session.agyModel { return AgyBridge.level(m) }
        if session.codexModel != nil { return CodexBridge.defaultLevel }
        if session.copilotModel != nil { return CopilotBridge.defaultLevel }
        if session.appleModel != nil { return nil }
        if session.mlxModel != nil { return LocalBridge.defaultLevel(session.mlxModel) }
        let choice = currentChoice
        return ClaudeSettings.effort(for: choice?.resolved.isEmpty == false ? choice!.resolved : resolvedModel)
    }

    /// 目前選的模型（給思考強度選單看它支援哪幾段）
    private var currentChoice: ModelChoice? {
        let known = ModelChoice.known
        if let m = session.model { return known.first { $0.value == m } }
        if !resolvedModel.isEmpty { return known.first { $0.resolved == resolvedModel } }
        return known.first { $0.value == "default" }
    }

    private func refreshModelName() {
        if let local = session.localEndpoint { inputBar.modelTitle = local.name; return }
        if let m = session.agyModel { inputBar.modelTitle = AgyBridge.name(m); return }
        if let m = session.codexModel { inputBar.modelTitle = CodexBridge.name(m); return }
        if let m = session.copilotModel { inputBar.modelTitle = CopilotBridge.name(m); return }
        if let m = session.mlxModel { inputBar.modelTitle = LocalBridge.name(m); return }
        if let m = session.appleModel { inputBar.modelTitle = AppleBridge.name(m); return }
        let known = ModelChoice.known
        if let m = session.model, m != "default" {
            inputBar.modelTitle = known.first { $0.value == m }?.name ?? m
            return
        }
        // 沒選模型（預設）：Claude 實際回報的 → 上次預設實際跑出來的（還沒跑起來時）→ 清單上說預設是哪個
        // （清單說預設是 Sonnet，實際卻可能是 Opus，使用者 10/25）
        let d = known.first { $0.value == "default" }
        let live = [resolvedModel, appDefaults.string(forKey: "lastDefaultModel") ?? "", d?.resolved ?? ""].first { !$0.isEmpty } ?? ""
        inputBar.modelTitle = known.first { $0.resolved == live && $0.value != "default" }?.name ?? (live.isEmpty ? (d?.name ?? L("預設模型")) : live)
    }

    private var panel: FloatingPanel?
    private let panelModel = ModelPanelModel()
    private let nextGuess = NextGuess.Tracker()   // 不是 Claude 的聊天室：每輪結束猜下一句
    private var panelHost: NSHostingView<ModelPanel>?
    private var lastPanelClose = Date.distantPast

    /// 右下角按下去：思考強度拉桿＋模型清單（自己畫的浮動面板，右緣對齊輸入框，不會伸進桌寵的格子）
    private func showModelPanel(from v: NSView) {
        if let p = panel, p.isVisible { p.close(); return }
        // 點按鈕想關掉：面板在按下時已經自己關了，放開時別又打開
        if Date().timeIntervalSince(lastPanelClose) < 0.4 { return }
        refreshPanel()
        panelModel.showingModels = false
        panelModel.onEffort = { [weak self] e in
            guard let self else { return }
            self.applyEffort(e)
            self.onEffortChange?(e)
            self.refreshPanel()
        }
        panelModel.onPickModel = { [weak self] value in
            guard let self else { return }
            self.applyModel(value)
            self.onModelChange?(value == "default" ? nil : value)
            self.refreshPanel()
        }
        panelModel.onLocalSettings = { [weak self] in self?.panel?.close(); self?.openSettings?() }
        panelModel.onSetDefault = { [weak self] e in
            guard let self else { return }
            self.panelModel.defaultNote = L("存檔中…")
            self.session.saveDefaultEffort(e) { [weak self] ok in
                guard let self else { return }
                if ok { self.panelModel.defaultEffort = e }
                self.panelModel.defaultNote = ok ? L("已設為預設：") + Effort.name(e) : L("存不進去，再試一次")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.panelModel.defaultNote = nil }
            }
        }
        panelModel.onSizeChange = { [weak self] in DispatchQueue.main.async { self?.placePanel(animated: true) } }
        let host = NSHostingView(rootView: ModelPanel(m: panelModel))
        host.sizingOptions = []          // 不要讓它自己撐大視窗（它會固定上緣往下長）；大小由 placePanel 算
        panelHost = host
        let p = FloatingPanel(content: host)
        p.onClose = { [weak self] in self?.panel = nil; self?.lastPanelClose = Date() }
        panel = p
        placePanel()
        p.closeWhenMouseLeaves()
        window?.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
    }

    func testShowModelList() { panelModel.showingModels = true; placePanel() }

    /// 面板的位置：右緣對齊輸入框右緣、貼在輸入框上面；換頁（大小變了）也照這個重擺
    private func placePanel(animated: Bool = false) {
        guard let p = panel, let host = panelHost, let win = window else { return }
        // 顯示用的那個關掉了自動撐大，量不到大小：另外用一個不顯示的副本量
        let size = NSHostingView(rootView: ModelPanel(m: panelModel)).fittingSize
        _ = host
        let box = win.convertToScreen(inputBar.boxRectInWindow)
        var x = box.maxX - size.width, y = box.maxY + 8
        // 輸入框實際在哪個螢幕就用哪個螢幕的範圍，左右上都不超出去（太靠上就往下擠）
        let mid = NSPoint(x: box.midX, y: box.midY)
        if let vf = (NSScreen.screens.first { $0.frame.contains(mid) } ?? win.screen)?.visibleFrame {
            x = min(max(vf.minX + 8, x), vf.maxX - size.width - 8)
            if y + size.height > vf.maxY - 8 { y = vf.maxY - 8 - size.height }
        }
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        // 換頁、換分頁：大小用動畫慢慢變（下緣貼著輸入框不動），裡面的內容跟著每一格重排，不會先跳一下再改大小
        if animated, p.isVisible, p.frame.size != frame.size {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                p.animator().setFrame(frame, display: true)
            }
        } else {
            p.setFrame(frame, display: true)
        }
    }

    private func refreshPanel() {
        refreshModelName()
        panelModel.canSetDefault = false   // 只有 Claude 那段會打開
        panelModel.modelName = inputBar.modelTitle
        panelModel.isLocal = session.localEndpoint != nil
        if let m = session.agyModel {
            // agy：強度在模型名字尾巴，拉桿換的是尾巴（下一則訊息生效）
            panelModel.levels = AgyBridge.level(m) != nil ? AgyBridge.levels : []
            panelModel.effort = session.effort.flatMap { AgyBridge.levels.contains($0) ? $0 : nil }
            panelModel.defaultEffort = AgyBridge.level(m)
            panelModel.sections = modelSections(currentResolved: "")
        } else if session.codexModel != nil {
            panelModel.levels = CodexBridge.levels
            panelModel.effort = session.effort
            panelModel.defaultEffort = CodexBridge.defaultLevel
            panelModel.sections = modelSections(currentResolved: "")
        } else if session.copilotModel != nil {
            // Copilot Auto：拉桿是 Auto 的偏好（省／平衡／聰明），下一則訊息生效
            panelModel.levels = CopilotBridge.levels
            panelModel.effort = session.effort.flatMap { CopilotBridge.levels.contains($0) ? $0 : nil }
            panelModel.defaultEffort = CopilotBridge.defaultLevel
            panelModel.sections = modelSections(currentResolved: "")
        } else if session.appleModel != nil {
            // Apple 模型：沒有強度可調
            panelModel.isLocal = true
            panelModel.levels = []
            panelModel.effort = nil
            panelModel.defaultEffort = nil
            panelModel.sections = modelSections(currentResolved: "")
        } else if session.mlxModel != nil {
            // 本機 MLX：拉桿是要不要先想（低＝直接答、高＝先想再答），下一則訊息生效；不會思考的模型沒有拉桿
            let levels = LocalBridge.levels(session.mlxModel)
            panelModel.isLocal = levels.isEmpty
            panelModel.levels = levels
            panelModel.effort = session.effort.flatMap { levels.contains($0) ? $0 : nil }
            panelModel.defaultEffort = LocalBridge.defaultLevel(session.mlxModel)
            panelModel.sections = modelSections(currentResolved: "")
        } else {
            let choice = currentChoice
            panelModel.levels = Effort.order.filter { (choice?.efforts ?? Effort.order).contains($0) }
            panelModel.effort = session.effort
            let resolved = choice?.resolved.isEmpty == false ? choice!.resolved : resolvedModel
            panelModel.defaultEffort = ClaudeSettings.effort(for: resolved)
            panelModel.canSetDefault = true
            panelModel.sections = modelSections(currentResolved: resolved)
        }
        refreshModelTitle()
    }

    /// 模型清單：同一系列一組（新的在前），系列照 Claude 給的順序；最後一組是本機模型
    private func modelSections(currentResolved: String) -> [[ModelRow]] {
        let known = ModelChoice.known.filter { $0.value != "default" }
        var families: [String] = []
        var byFamily: [String: [ModelChoice]] = [:]
        for c in known {
            let fam = String(c.name.split(separator: " ").first ?? Substring(c.name))
            if byFamily[fam] == nil { families.append(fam) }
            byFamily[fam, default: []].append(c)
        }
        func version(_ c: ModelChoice) -> Double { Double(c.name.split(separator: " ").dropFirst().first ?? "0") ?? 0 }
        var checkedDone = session.localEndpoint != nil || session.agyModel != nil || session.codexModel != nil || session.copilotModel != nil || session.mlxModel != nil || session.appleModel != nil
        // 精簡清單（設定沒勾「列出全部」）：只留 Opus／Sonnet／Haiku 5.5 (cc)、Gemini 3.8 Flash、本機模型全部；這格正在用的照列
        let all = Prefs.shared.allModels
        func keep(_ rows: [ModelRow], _ common: (ModelRow) -> Bool = { _ in false }) -> [ModelRow] {
            all ? rows : rows.filter { $0.checked || common($0) }
        }
        var out: [[ModelRow]] = families.map { fam in
            byFamily[fam]!.sorted { version($0) > version($1) }.map { c in
                let on = !checkedDone && (session.model.map { $0 == c.value } ?? (c.resolved == currentResolved))
                if on { checkedDone = true }
                return ModelRow(id: c.value, title: c.name, tip: c.detail, checked: on)
            }
        }.map { keep($0) { ["opus", "sonnet", "haiku"].contains($0.id) } }.filter { !$0.isEmpty }
        // 本機：自己開 mlx_lm 伺服器的（快取裡有模型才列），再來是設定頁加的 Anthropic 格式伺服器
        let mlx = LocalBridge.available.map { m in
            ModelRow(id: "local:mlx:" + m.id, title: m.name, tip: L("本機 MLX · 約 \(m.gb) GB 記憶體 · 不花額度") + (m.gb >= 15 ? L(" · 跑的時候先關掉其他本機模型") : ""), checked: session.mlxModel == m.id)
        }
        // Apple 內建的模型：系統夠新、Apple Intelligence 開著才列
        let apple = AppleBridge.available
            ? [ModelRow(id: "local:apple:" + AppleBridge.model, title: AppleBridge.name(AppleBridge.model), tip: L("macOS 內建 · 不佔額外記憶體 · 上下文約 8K"), checked: session.appleModel != nil)]
            : []
        let locals = apple + mlx + LocalModel.all.map { l in   // 本機的不花額度，精簡清單也全列
            ModelRow(id: "local:" + l.id.uuidString, title: l.name, tip: "\(l.baseURL) · \(l.model)", checked: session.localEndpoint?.id == l.id)
        }
        if !locals.isEmpty { out.append(locals) }
        // Gemini：有裝 agy（Google 的 Antigravity 命令列工具）才列
        if AgyBridge.enabled, AgyBridge.executable != "agy" {
            let rows = keep(AgyBridge.models.map { m in
                ModelRow(id: "agy:" + m.id, title: m.name, tip: L("經 agy（Antigravity）· 用你的 Google AI 訂閱"), checked: session.agyModel.map(AgyBridge.base) == AgyBridge.base(m.id))
            }) { AgyBridge.base($0.id) == "agy:gemini-3.8-flash" }
            if !rows.isEmpty { out.append(rows) }
        }
        // ChatGPT：有裝 codex（OpenAI 的命令列工具，用 ChatGPT 帳號登入）才列
        if CodexBridge.installed {
            let rows = keep(CodexBridge.models.map { m in
                ModelRow(id: "codex:" + m.id, title: m.name, tip: L("經 Codex · 用你的 ChatGPT 帳號"), checked: session.codexModel == m.id)
            })
            if !rows.isEmpty { out.append(rows) }
        }
        // GitHub Copilot：有裝 copilot（GitHub 的命令列工具，用 GitHub 帳號登入）才列
        if CopilotBridge.installed {
            let rows = keep(CopilotBridge.models.map { m in
                ModelRow(id: "copilot:" + m.id, title: m.name, tip: L("經 Copilot CLI · 用你的 GitHub Copilot 額度"), checked: session.copilotModel == m.id)
            })
            if !rows.isEmpty { out.append(rows) }
        }
        return out
    }

    @objc private func openLocalSettings() { openSettings?() }

    // MARK: 權限模式

    func applyPermissionMode(_ m: String?) {
        session.permissionMode = m
        refreshMode()
    }
    private var currentMode: String { session.permissionMode ?? Prefs.shared.permissionMode ?? "default" }
    private func refreshMode() { inputBar.permissionMode = currentMode }
    /// ⇧ Tab 或按輸入框上的模式按鈕：換到下一個模式
    func cycleMode() {
        let next = PermissionMode.next(after: currentMode)
        session.setPermissionMode(next)
        refreshMode()
        onPermissionModeChange?(next)
    }

    func applyEffort(_ v: String?) {
        session.setEffort(v)
        refreshModelTitle()
    }

    /// 套用對話存的模型；本機和 Claude 之間切換要重開程序（下次送出時用 --resume 接回）
    func applyModel(_ value: String?) {
        let wasLocal = session.localEndpoint != nil
        let before = session.transcriptURL
        let beforeName = inputBar.modelTitle.components(separatedBy: " · ").first
        defer {
            // 換到另一套（紀錄檔不同）而且前面真的聊過：記下來，送下一則時附上
            if let before, before != session.transcriptURL,
               ((try? before.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 { carryFrom = before; carryName = beforeName }
        }
        if let v = value, v.hasPrefix("codex:") {
            // ChatGPT（codex）：同一個程序裡換模型就好；從別的換過來要重開
            let m = String(v.dropFirst(6))
            if session.codexModel == nil { session.terminate() }
            session.agyModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.localEndpoint = nil
            session.model = nil
            session.setCodexModel(m)
        } else if let v = value, v.hasPrefix("copilot:") {
            // GitHub Copilot：模型只能開的時候指定
            let m = String(v.dropFirst(8))
            if session.copilotModel != m { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.copilotModel = m
            session.localEndpoint = nil
            session.model = nil
        } else if let v = value, v.hasPrefix("agy:") {
            // Gemini（agy）：換成另一個程式，模型也只能開的時候指定
            let m = String(v.dropFirst(4))
            if session.agyModel != m || session.codexModel != nil || session.copilotModel != nil || session.mlxModel != nil || session.appleModel != nil { session.terminate() }
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.agyModel = m
            session.localEndpoint = nil
            session.model = nil
        } else if value?.hasPrefix("local:apple:") == true {
            // Apple 模型：從別的換過來要重開（不是同一套）
            if session.appleModel == nil { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = AppleBridge.model
            session.localEndpoint = nil
            session.model = nil
        } else if let v = value, v.hasPrefix("local:mlx:") {
            // 本機 MLX：從別的換過來要重開（不是同一套）
            let m = String(v.dropFirst(10))
            if session.mlxModel != m || session.appleModel != nil { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = m
            session.appleModel = nil
            session.localEndpoint = nil
            session.model = nil
        } else if let v = value, v.hasPrefix("local:"), let l = LocalModel.all.first(where: { "local:" + $0.id.uuidString == v }) {
            if session.localEndpoint?.id != l.id || session.agyModel != nil || session.codexModel != nil || session.copilotModel != nil || session.mlxModel != nil || session.appleModel != nil { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.localEndpoint = l
            session.model = nil
        } else {
            if wasLocal || session.agyModel != nil || session.codexModel != nil || session.copilotModel != nil || session.mlxModel != nil || session.appleModel != nil { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.localEndpoint = nil
            session.setModel(value == "default" ? nil : value)
        }
        refreshModelTitle()
    }

    private func send(text: String, images: [(data: Data, mediaType: String)], now: Bool = false) {
        // 送出前再確認一次：這段對話如果正在別處進行，不要兩邊同時寫同一份紀錄
        if !session.isRunning, session.forkFrom == nil, liveElsewhere() != nil {
            js("wb.notice(\(Self.jsString(L("這段對話剛好在別處進行中，這則沒有送出（避免兩邊同時寫同一份紀錄）。可以等那邊結束，或按「在這裡接手」複製一份。"))))")
            checkLive()
            return
        }
        // Gemini（agy）還沒開、系統說沒網路：不送，字放回輸入框（斷網時開 agy 會一直跳瀏覽器登入頁，AgyNet.swift）
        if session.agyModel != nil, !session.isRunning, !AgyNet.quickOK {
            js("wb.notice(\(Self.jsString(AgyNet.offlineMessage)))")
            DispatchQueue.main.async { [weak self] in self?.inputBar.restoreLastSent() }   // 輸入框送出後才清空，等它清完再放回
            return
        }
        let dataURLs = images.map { "data:\($0.mediaType);base64,\($0.data.base64EncodedString())" }
        let uuid = UUID().uuidString.lowercased()
        // Claude 還在做：先排在下面，等它真的讀進去（回送）再移進對話
        let queued = session.isRunning && session.status != .idle
        if let d = try? JSONSerialization.data(withJSONObject: ["text": text, "images": dataURLs, "uuid": uuid, "queued": queued, "now": now] as [String: Any]), let s = String(data: d, encoding: .utf8) {
            js("wb.localUser(\(s))")
        }
        if !sentAny { sentAny = true; onFirstMessage?(text) }
        nextGuess.sent(text)
        // 程式碼區開著：附一行告訴 Claude 你在看哪個檔案哪一行（畫面上的泡泡只顯示你打的字）
        var full = codeLab?.contextLine().map { text + "\n\n" + $0 } ?? text
        // 剛換到另一家的模型：附上交接（最近的對話＋精簡全文檔，ModelCarry.swift）。又換回原本那個就不用附。
        // 換到 Apple 模型不附（使用者 10/25：它做不了事，不用交接）
        if let from = carryFrom {
            carryFrom = nil
            if from != session.transcriptURL, session.appleModel == nil,
               let note = ModelCarry.note(from: from, session: session.claudeSession, model: carryName, limit: 6000, canRead: true) {
                full += note
            }
        }
        session.send(text: full, images: images, uuid: uuid, now: now)
        NotificationCenter.default.post(name: ChatPane.didSend, object: session.claudeSession)   // 草稿聊過了，留下來（Drafts.swift）
    }

    /// 送出一則訊息（object：Claude 的對話編號）
    static let didSend = Notification.Name("ChatPaneDidSend")

    /// 畫面上一行系統提示（交接進度之類）
    func notice(_ s: String) { js("wb.notice(\(Self.jsString(s)))") }
    /// 程式幫忙送一則訊息（交接的第一則）
    func sendText(_ text: String) { send(text: text, images: []) }

    // MARK: 網頁

    private func js(_ code: String) {
        guard ready else { queued.append(code); return }
        web.evaluateJavaScript(code) { _, err in
            if let err { NSLog("AI 工作台 JS 錯誤：\(err.localizedDescription) 於 \(code.prefix(120))") }
        }
    }

    fileprivate func received(_ m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let type = o["type"] as? String else { return }
        switch type {
        case "ready":
            // 先把舊紀錄畫上去，再放行排隊中的東西（不然 wb.history 會把剛送出的訊息、權限卡片清掉）
            loadHistory { [weak self] in
                guard let self else { return }
                self.ready = true
                let q = self.queued; self.queued = []
                q.forEach(self.js)
                self.checkLive()
            }
        case "scrollLog":
            // chat.js：跟到底被關掉／需要補貼的原因（查「沒有貼底」用，寫進 drop.log）
            if let t = o["text"] as? String { ChatTextView.dropLog("捲動 " + t, nil) }
        case "permission", "answer":
            guard let id = o["request_id"] as? String else { return }
            let behavior = type == "answer" ? "allow" : (o["behavior"] as? String ?? "deny")
            // 查「明明沒按卻被拒絕」用：每次回覆權限詢問都記一筆
            ChatTextView.dropLog("權限回覆：\(behavior)（\(type)）\(conversationTitleForLog)", nil)
            session.answerPermission(requestID: id, behavior: behavior, updatedInput: o["updatedInput"],
                                     updatedPermissions: o["updatedPermissions"], message: o["message"] as? String)
            window?.makeFirstResponder(inputBar.textView)
        case "open":
            if var p = o["path"] as? String {
                // chat.js 已經拿掉行號；這裡再保險一次（file.swift:42、:42:7、#L42）
                p = p.replacingOccurrences(of: #"(:\d+(:\d+)?|#L\d+(-L?\d+)?)$"#, with: "", options: .regularExpression)
                let ex = (p as NSString).expandingTildeInPath
                let full = ex.hasPrefix("/") ? ex : (session.directory as NSString).appendingPathComponent(ex)
                Self.revealInFinder(URL(fileURLWithPath: full))
            }
        case "pathCheck":
            // chat.js 問「這些路徑在不在」：只有檔名、相對路徑、沒包反引號的路徑，要真的存在才做成連結
            guard let items = o["items"] as? [[String: Any]] else { return }
            let dir = session.directory
            let out: [[String: Any]] = items.compactMap { it in
                guard let key = it["key"] as? String, let p = it["path"] as? String else { return nil }
                let hit = (it["prefix"] as? Bool ?? false) ? Self.existingPrefix(p, in: dir) : (Self.pathExists(p, in: dir) ? p : nil)
                return ["key": key, "hit": hit ?? NSNull()]
            }
            if let d = try? JSONSerialization.data(withJSONObject: out), let s = String(data: d, encoding: .utf8) { js("wb.pathsChecked(\(s))") }
        case "editing":
            webEditing = o["on"] as? Bool ?? false
        case "sendNow":
            if let u = o["uuid"] as? String { session.sendNow(u) }
        case "loadOlder":
            loadOlder()
        case "openURL":
            if let s = o["url"] as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        default: break
        }
    }

    /// 一次最多載入幾則（長對話的紀錄檔可能有上百 MB）
    static var historyLimit: Int { Prefs.shared.historyLimit }
    private var followOffset: UInt64 = 0
    private var followTimer: Timer?
    private var followPartial = Data()

    /// 這行是使用者／Claude 的訊息嗎（先用字串粗篩，不用每行都解析）
    private static func isMessage(_ raw: Data.SubSequence) -> Bool {
        guard raw.count > 20, let s = String(data: raw, encoding: .utf8) else { return false }
        return s.contains("\"type\":\"user\"") || s.contains("\"type\":\"assistant\"")
    }

    private static let userKey = Data("\"type\":\"user\"".utf8)
    private static let assistantKey = Data("\"type\":\"assistant\"".utf8)
    private static func isMessageBytes(_ raw: Data.SubSequence) -> Bool {
        raw.count > 20 && (raw.range(of: userKey) != nil || raw.range(of: assistantKey) != nil)
    }

    /// 從紀錄檔尾巴往前讀：第一次讀最後 400 則，往上捲再接著往前讀 300 則（長對話幾百 MB，不整份掃）
    private var older: ChainReader?
    private let olderQueue = DispatchQueue(label: "AI 工作台 載入紀錄")

    private func loadHistory(_ done: @escaping () -> Void) {
        let reader = ChainReader(session.allTranscripts)
        guard reader.hasMore else { done(); return }
        older = reader
        let debug = ProcessInfo.processInfo.environment["AI_WORKBENCH_DEBUG"] != nil
        olderQueue.async { [weak self] in
            let t0 = Date()
            let lines = reader.take(Self.historyLimit, where: Self.isMessageBytes)
            let code = lines.isEmpty ? nil : "wb.history([" + lines.joined(separator: ",") + "])"
            let more = reader.hasMore
            let tPick = Date()
            DispatchQueue.main.async {
                guard let self else { return }
                self.followOffset = reader.size
                if let code {
                    self.sentAny = true
                    self.web.evaluateJavaScript(code) { [weak self] _, err in
                        if let err { NSLog("AI 工作台 載入紀錄失敗：\(err.localizedDescription)") }
                        if more { self?.js("wb.moreAbove()") }
                        if debug { FileHandle.standardError.write(Data(String(format: "載入紀錄 %.0f MB：挑訊息 %.2fs、畫面 %.2fs\n", Double(reader.size) / 1e6, tPick.timeIntervalSince(t0), Date().timeIntervalSince(tPick)).utf8)) }
                        done()
                    }
                } else {
                    done()
                }
            }
        }
    }

    /// 畫面捲到頂端附近要更早的
    private func loadOlder() {
        guard let reader = older else { js("wb.noMoreAbove()"); return }
        olderQueue.async { [weak self] in
            let lines = reader.take(300, where: Self.isMessageBytes)
            let more = reader.hasMore
            let code = lines.isEmpty ? "wb.noMoreAbove()" : "wb.historyPrepend([" + lines.joined(separator: ",") + "], \(more))"
            DispatchQueue.main.async { self?.js(code) }
        }
    }

    // MARK: 同步顯示：這段對話還開在 iTerm／tmux 裡

    /// 最後一次收到自己（工作台這邊的 Claude）的東西：紀錄檔在這之後被改，才算別人改的
    /// 也存起來：重開 App、關掉再開這格時，自己剛寫的紀錄檔不要被當成別人在用
    private lazy var lastOwnActivity: Date = Self.ownActivity(session.claudeSession)
    private var lastOwnSaved = Date.distantPast
    private func markOwnActivity(final: Bool = false) {
        lastOwnActivity = Date()
        guard final || Date().timeIntervalSince(lastOwnSaved) > 5 else { return }
        lastOwnSaved = Date()
        var all = appDefaults.dictionary(forKey: "ownActivity") as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        all = all.filter { now - $0.value < 3600 }   // 只留一小時內的
        all[session.claudeSession.uuidString] = now
        appDefaults.set(all, forKey: "ownActivity")
    }
    private static func ownActivity(_ id: UUID) -> Date {
        guard let t = (appDefaults.dictionary(forKey: "ownActivity") as? [String: Double])?[id.uuidString] else { return .distantPast }
        return Date(timeIntervalSince1970: t)
    }

    /// 紀錄裡用的「這是哪一格」
    var conversationTitleForLog: String { conversationID.map { "［\($0.uuidString.prefix(8))］" } ?? "" }

    func liveElsewhere() -> LiveSession? {
        if let l = ClaudeSessions.live()[session.claudeSession], l.pid != session.pid { return l }
        // 登記檔查不到，但紀錄檔最近 3 分鐘被別的程式改過（例如那邊正在重新啟動）：保守一點，也當成還在別處進行
        // 只看「訊息」的時間：claude 結束時會在尾巴補寫幾行記帳資料，那不算有人在用
        if let url = session.transcriptURL,
           let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(m) < 180,
           let last = Self.lastMessageDate(url), Date().timeIntervalSince(last) < 180, last.timeIntervalSince(lastOwnActivity) > 5 {
            return LiveSession(pid: 0, tmux: "", kind: "recent")
        }
        return nil
    }

    /// 紀錄檔最後一則使用者／Claude 訊息的時間（只讀尾巴 512 KB）
    private static func lastMessageDate(_ url: URL) -> Date? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let tail = try? h.readToEnd() else { return nil }
        let key = Data("\"timestamp\":\"".utf8)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for raw in tail.split(separator: 0x0a).reversed() where isMessageBytes(raw) {
            guard let r = raw.range(of: key) else { continue }
            let rest = raw[r.upperBound...]
            guard let q = rest.firstIndex(of: 0x22), let s = String(data: rest[..<q], encoding: .utf8) else { continue }
            if let d = iso.date(from: s) { return d }
        }
        return nil
    }

    private func checkLive() {
        // 這格自己的 claude 已經在跑（例如打開 App 時自動接回）：紀錄檔剛被寫過是自己寫的，不算在別處
        guard !session.isRunning, let l = liveElsewhere() else { return }
        let whereText = l.kind == "recent" ? L("別處（紀錄檔剛剛還在更新）") : (l.tmux.isEmpty ? L("另一個終端機") : L("tmux（\(l.tmux)）"))
        inputBar.setLocked(L("這段對話正在\(whereText)裡進行，這裡同步顯示。在那邊結束後就能在這裡接著聊；也可以複製一份在這裡繼續（那邊不受影響）。"),
                           button: L("在這裡接手（複製一份）")) { [weak self] in self?.takeOver() }
        followTimer?.invalidate()
        var tick = 0
        followTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.session.isRunning { self.stopFollowing(); return }   // 這格自己接上了
            self.pullNewLines()
            tick += 1
            // 別處停下來（登記檔查不到、紀錄檔 2 分鐘沒動）才解鎖
            if tick % 3 == 0, self.liveElsewhere() == nil, self.quietFor(120) {
                self.stopFollowing()
                self.js("wb.notice(\(Self.jsString(L("那邊的對話已經結束，可以在這裡接著聊了。"))))")
            }
        }
    }

    private func quietFor(_ seconds: TimeInterval) -> Bool {
        guard let url = session.transcriptURL,
              let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return true }
        return Date().timeIntervalSince(m) >= seconds
    }

    /// 紀錄檔新長出來的部分接到畫面後面
    private func pullNewLines() {
        guard let url = session.transcriptURL, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        guard end > followOffset else { return }
        try? h.seek(toOffset: followOffset)
        let chunk = followPartial + ((try? h.readToEnd()) ?? Data())
        followOffset = end
        // 最後一行可能還沒寫完：留到下次
        if let last = chunk.lastIndex(of: 0x0a) {
            followPartial = chunk[(last + 1)...]
            let lines = chunk[..<last].split(separator: 0x0a).filter(Self.isMessage)
                .filter { (try? JSONSerialization.jsonObject(with: $0)) != nil }   // 壞掉的一行不要拖垮整批
                .compactMap { String(data: $0, encoding: .utf8) }
            if !lines.isEmpty { js("wb.historyAppend([" + lines.joined(separator: ",") + "])") }
        } else {
            followPartial = chunk
        }
    }

    /// 網頁裡正在打字（選擇題的「其他」欄位之類）：這時候按 / 不要搶走
    private(set) var webEditing = false

    /// 在這格裡點了輸入框以外（對話內容）：輸入框失效。點在輸入框、縮圖、按鈕、/ 選單上不算
    func clickedInside(_ e: NSEvent) {
        let inBar = inputBar.bounds.contains(inputBar.convert(e.locationInWindow, from: nil))
        let inMenu = !inputBar.slash.isHidden && inputBar.slash.bounds.contains(inputBar.slash.convert(e.locationInWindow, from: nil))
        guard !inBar, !inMenu else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let w = self.window, w.firstResponder === self.inputBar.textView else { return }
            w.makeFirstResponder(self.web)
        }
    }

    /// 游標放進輸入框（鎖住時不動）
    @discardableResult
    func focusInput() -> Bool {
        guard !inputBar.isLocked, let w = window else { return false }
        if w.firstResponder !== inputBar.textView { w.makeFirstResponder(inputBar.textView) }
        return true
    }

    /// 自己的 claude 開起來了：如果先前以為「在別處進行」而鎖住輸入框，解開
    func ownSessionStarted() {
        guard followTimer != nil, session.isRunning else { return }
        stopFollowing()
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        inputBar.setLocked(nil)
        window?.makeFirstResponder(inputBar.textView)
    }

    /// 複製一份在這裡繼續：下一則訊息用 --fork-session 開新的對話編號
    private func takeOver() {
        pullNewLines()
        session.forkFrom = session.claudeSession
        stopFollowing()
        js("wb.notice(\(Self.jsString(L("已經準備好在這裡接手：送出下一則訊息時會複製一份新的對話，原本那段在那邊照常進行。"))))")
    }

    /// 對話裡點檔案路徑：一律在 Finder 裡把那個檔案選起來，不用預設 App 打開（使用者 10/25：「不要用 vscode 打開，請直接用 finder 的那個檔案位置」）。
    /// 資料夾直接在 Finder 打開（看裡面有什麼）；檔案不存在就打開最近一層存在的資料夾
    static func revealInFinder(_ url: URL) {
        let t = finderTarget(url)
        if t.select { NSWorkspace.shared.activateFileViewerSelecting([t.url]) } else { NSWorkspace.shared.open(t.url) }
    }
    /// 路徑在不在（去掉 :行號、#L行號；~ 換成家目錄；相對路徑接在工作目錄後面）
    static func pathExists(_ p: String, in dir: String) -> Bool {
        var p = p.replacingOccurrences(of: #"(:\d+(:\d+)?|#L\d+(-L?\d+)?)$"#, with: "", options: .regularExpression)
        if p.hasPrefix("./") { p.removeFirst(2) }
        let ex = (p as NSString).expandingTildeInPath
        guard !ex.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: ex.hasPrefix("/") ? ex : (dir as NSString).appendingPathComponent(ex))
    }
    /// 一般文字裡的路徑候選（後面可能黏著中文或標點）：從尾巴一個字一個字縮，回傳最長的存在前綴。
    /// 剩下的字要是「斷得乾淨」的地方（中文、標點），不然 ~/Desktop/打錯.md 會變成只連到 ~/Desktop
    static func existingPrefix(_ cand: String, in dir: String) -> String? {
        let cand = String(cand.prefix(400))
        var t = cand
        while t.count > 2 {
            let rest = cand.dropFirst(t.count)
            // 剩下的字開頭是英數、_-/，或「. 後面接英數」（~/foo 存在但 ~/foo.md 不存在）都算沒斷乾淨
            let pathy = { (c: Character?) in c.map { $0.isASCII && ($0.isLetter || $0.isNumber || "_-/".contains($0)) } ?? false }
            let clean = rest.isEmpty || (!t.hasSuffix("/") && !pathy(rest.first) && !(rest.first == "." && pathy(rest.dropFirst().first)))
            if clean, pathExists(t, in: dir) { return t }
            t.removeLast()
        }
        return nil
    }
    /// Finder 要怎麼顯示：(要打開或選起來的位置, true＝選起來 / false＝打開資料夾)
    static func finderTarget(_ url: URL) -> (url: URL, select: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            // .app 這類套件也是資料夾，但要選起來，不要打開（打開 Finder 會直接執行 App）
            return isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path) ? (url, false) : (url, true)
        }
        var dir = url.deletingLastPathComponent()
        while dir.path != "/", !fm.fileExists(atPath: dir.path) { dir = dir.deletingLastPathComponent() }
        return (dir, false)
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 頁面裡點到外面的連結：交給瀏覽器，不在這格裡打開
        if a.navigationType == .linkActivated, let u = a.request.url {
            if u.isFileURL { Self.revealInFinder(u) } else { NSWorkspace.shared.open(u) }   // 網址用預設瀏覽器
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    /// 右鍵「壓縮這段對話」：送 /compact（Claude 把前面的內容濃縮成摘要；原本的紀錄檔還在）
    func compact() {
        send(text: "/compact", images: [])
    }

    /// 測試用：把聊天網頁拍成 PNG（背景視窗 screencapture 拍不到網頁內容，WebKit 自己的快照拍得到）
    func snapshotWeb(to path: String) {
        web.takeSnapshot(with: nil) { img, _ in
            guard let img, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 測試用：在畫面裡跑一段 JS，結果當字串回來
    func evaluate(_ code: String, _ done: @escaping (String) -> Void) {
        web.evaluateJavaScript(code) { r, e in done(r.map { "\($0)" } ?? L("錯誤：\(e?.localizedDescription ?? "?")")) }
    }

    /// NSFont 的粗細換成 CSS 的 font-weight（更紗黑體 SemiBold → 600）
    static func cssWeight(_ f: NSFont) -> Int {
        let w = (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        switch w {
        case ..<(-0.5): return 200
        case ..<(-0.2): return 300
        case ..<0.1: return 400
        case ..<0.25: return 500
        case ..<0.45: return 600
        case ..<0.6: return 700
        default: return 800
        }
    }

    static func jsString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
}

extension NSColor {
    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// 從檔案尾巴往前一段一段讀行，可以接著讀（記住讀到哪）
/// 換過模型的對話：各家的紀錄檔接起來往前讀（目前這家在最後面），兩份中間插一則「以下換成 …」的分隔線（wbDivider）
/// 各家紀錄沒有共同的時間，只能整份接：來回換過好幾次的，同一家的幾段會併在一起
final class ChainReader {
    private var parts: [(reader: BackwardReader, name: String)]
    /// 目前這家紀錄檔讀到哪（同步顯示從這裡接著讀）
    let size: UInt64

    init(_ files: [(url: URL, name: String)]) {
        // 目前這家的檔可能還沒有（剛換模型、還沒聊）
        let current = files.first.flatMap { BackwardReader(url: $0.url) }
        parts = (current.map { [($0, files[0].name)] } ?? []) + files.dropFirst().compactMap { f in BackwardReader(url: f.url).map { ($0, f.name) } }
        size = current?.size ?? 0
    }

    var hasMore: Bool { parts.contains { $0.reader.hasMore } }

    /// 往前再拿 n 行，回傳時是舊到新
    func take(_ n: Int, where ok: (Data.SubSequence) -> Bool) -> [String] {
        var out: [String] = []
        while out.count < n, let p = parts.first {
            out = p.reader.take(n - out.count, where: ok) + out
            guard !p.reader.hasMore else { break }
            parts.removeFirst()
            if !parts.isEmpty, let d = try? JSONSerialization.data(withJSONObject: ["type": "wbDivider", "text": "以下換成 \(p.name)"]),
               let s = String(data: d, encoding: .utf8) { out.insert(s, at: 0) }
        }
        return out
    }
}

final class BackwardReader {
    let size: UInt64
    private let handle: FileHandle
    private var pos: UInt64
    private var tail = Data()           // 上一塊開頭那行還沒讀完整的部分
    private var pending: [Data] = []    // 已經切好、還沒交出去的行（新到舊）
    private let chunk: UInt64 = 8 * 1024 * 1024

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        handle = h
        var end = (try? h.seekToEnd()) ?? 0
        // 最後一行可能還在寫（別處正在進行）：只讀到最後一個換行，剩下的交給同步顯示接著讀
        if end > 0 {
            let look = min(end, 4 * 1024 * 1024)
            try? h.seek(toOffset: end - look)
            if let tail = try? h.read(upToCount: Int(look)), let nl = tail.lastIndex(of: 0x0a) {
                end = end - look + UInt64(tail.distance(from: tail.startIndex, to: nl)) + 1
            }
        }
        size = end
        pos = end
    }
    deinit { try? handle.close() }

    var hasMore: Bool { pos > 0 || !tail.isEmpty || !pending.isEmpty }

    /// 往前再拿 n 行符合條件的，回傳時是舊到新
    func take(_ n: Int, where ok: (Data.SubSequence) -> Bool) -> [String] {
        var out: [Data] = []
        while out.count < n {
            if pending.isEmpty {
                if pos == 0 {
                    if !tail.isEmpty { pending = [tail]; tail = Data() } else { break }
                } else {
                    let len = min(chunk, pos)
                    pos -= len
                    try? handle.seek(toOffset: pos)
                    var buf = (try? handle.read(upToCount: Int(len))) ?? Data()
                    buf.append(tail)
                    var start = buf.startIndex
                    if pos > 0, let nl = buf.firstIndex(of: 0x0a) { tail = Data(buf[buf.startIndex..<nl]); start = buf.index(after: nl) } else { tail = Data() }
                    pending = buf[start...].split(separator: 0x0a).reversed().map { Data($0) }
                    continue
                }
            }
            let line = pending.removeFirst()
            if ok(line[...]) { out.append(line) }
        }
        return out.reversed().compactMap { String(data: $0, encoding: .utf8) }
    }
}
