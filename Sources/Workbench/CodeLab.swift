import AppKit
import Combine
import CryptoKit
import WebKit

// 程式碼學習專區：聊天格右邊的「程式碼區」。上面 Monaco 寫程式（Resources/codelab/editor.html），下面執行結果（RunPanel，可以輸入）。
// 沿用舊 codenv 的習慣：⌘ S 存檔、F9 存檔＋檢查（錯的地方畫紅線、訊息寫「第 N 行」）、F10 存檔＋編譯執行，執行檔放 bin/。
// 左邊的 Claude 看得到這裡：送出訊息時附一行「正在看哪個檔案第幾行、選了什麼、最後一次執行結果在哪」（contextLine）。
// 四種版面（Mode，⌘ , 設預設、工具列臨時換）：執行結果放下面、F10 整塊換成執行畫面、F10 跳出執行視窗、不用 AI（左程式碼右結果）。
// 執行完按任意鍵回到程式碼（換畫面、視窗的版面會收起來）；按著 ⌘ ⌥ ⌃ 的不算，才能先複製結果。

extension Store {
    static let codeLabGroupName = "程式碼學習專區"
    /// 這段對話要不要開程式碼區：在「程式碼學習專區」這一組
    func wantsCodeLab(_ c: Conversation) -> Bool {
        guard let g = groupOf(c) else { return false }
        return group(g)?.name == Store.codeLabGroupName
    }
    /// 側欄最下面放「程式碼學習專區」這一組（只建一次；使用者自己刪掉就不再建）
    func ensureCodeLabGroup() {
        let key = "codeLabGroupCreated"
        guard !appDefaults.bool(forKey: key), !groups.isEmpty else { return }
        appDefaults.set(true, forKey: key)
        guard !groups.contains(where: { $0.name == Store.codeLabGroupName }) else { return }
        addGroup(named: Store.codeLabGroupName)
    }
}

extension MainWindowController {
    /// 練習的程式放這裡（另選過資料夾就用選的，否則用 Edition.practiceFolder）
    static var codeLabFolder: String { CodeLabSetup.practiceFolder.path }

    /// 「新的練習」：準備好資料夾與範例檔、在程式碼學習專區開新聊天室（草稿：一句都沒聊就自動刪），第一次進來順便在背景檢查開發工具
    func newCodeLabConversation() {
        CodeLabSetup.preparePracticeFolder(from: window) { [weak self] folder in
            guard let self, let path = folder else { return }
            if !self.store.groups.contains(where: { $0.name == Store.codeLabGroupName }) { self.store.addGroup(named: Store.codeLabGroupName) }
            guard let g = self.store.groups.first(where: { $0.name == Store.codeLabGroupName }) else { return }
            CodeLabSetup.seedExamplesIfEmpty(in: path)
            let pid = self.store.projects.first(where: { $0.path == path })?.id ?? self.store.addProject(path: path).id
            let c = self.store.createConversation(in: pid, draft: true)
            self.store.move(c.id, toGroup: g.id)
            self.store.rename(c.id, to: "練習", byUser: false)
            self.store.show(c.id)
            CodeLabSetup.checkToolchainOnFirstEntry(from: self.window)
        }
    }
}

private final class CodeLabHandler: NSObject, WKScriptMessageHandler {
    weak var target: CodeLabView?
    init(_ t: CodeLabView) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.received(m) }
}

final class CodeLabView: NSView, WKNavigationDelegate, NSSplitViewDelegate, NSWindowDelegate, NSMenuDelegate {
    enum Mode: Int, CaseIterable {
        case below = 1, swap, popup, noAI
        var title: String { [L("上下分"), L("F10 換畫面"), L("F10 開視窗"), L("不用 AI")][rawValue - 1] }
        var detail: String {
            [L("左邊 AI，右上程式碼、右下執行結果"),
             L("左邊 AI，右邊程式碼；F10 整塊換成執行畫面，跑完按任意鍵回來"),
             L("左邊 AI，右邊程式碼；F10 跳出執行視窗，跑完按任意鍵關掉"),
             L("不用 AI：左邊程式碼、右邊執行結果")][rawValue - 1]
        }
    }
    let directory: String
    private let fileKey: String
    private let web: WKWebView
    let runPanel: RunPanel
    private let split = NSSplitView()
    private let bar = NSView()
    private let filePopup = NSPopUpButton()
    private let newButton = NSButton()
    private let checkButton = NSButton()
    private let runButton = NSButton()
    private let backButton = NSButton()     // F10 換畫面：執行畫面蓋著時，提供可見的按鈕切回程式碼
    private let modePopup = NSPopUpButton()
    private let inputPopup = NSPopUpButton(frame: .zero, pullsDown: true)   // 下拉式：按鈕上顯示短標題，選單裡是完整說明
    private let moreButton = NSButton()    // 「⋯」：視窗太窄時收不下的放這裡
    private var moreMenu = NSMenu()
    private var scaleSink: AnyCancellable?
    private var moreKey = ""
    /// 測試：snap= 動作把圖寫到這裡（--codelab-snap-path 給）
    var snapPath: String { CommandLine.arguments.firstIndex(of: "--codelab-snap-path").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? "/tmp/codelab-snap.png" }
    /// 工具列目前收到第幾級（測試用）：0 全部、1 只剩圖示、2 版面進 ⋯、3 輸入也進 ⋯、4 新檔案也進 ⋯
    private(set) var barLevel = 0
    private let askButton = NSButton()
    /// 「問 AI」按下去：把整理好的訊息交給旁邊的聊天室放進輸入框；回傳 false＝沒有聊天室可放
    var onAskAI: ((String) -> Bool)?
    /// 最近一次失敗（執行不是 0、或檢查有錯誤）
    private var problem: (what: String, text: String)? {
        didSet { updateAskButton() }
    }
    /// 目前開啟的檔案是否剛以代碼 0 執行完（讓答案算錯時也能按「問 AI」）
    private var hasCleanRun = false {
        didSet { if hasCleanRun != oldValue { updateAskButton() } }
    }
    /// 最近一次執行拿來當 stdin 的檔（nil＝自己打字）；問 AI 的訊息會寫進去
    private(set) var lastInput: String?
    private let status = NSTextField(labelWithString: "")
    private(set) var file: String? {
        didSet { if file != oldValue { updateAskButton() } }
    }
    private var ready = false
    private var cursorLine = 1
    private var selection = "" {
        didSet { if selection != oldValue { updateAskButton() } }
    }
    private var dirty = false {
        didSet { if dirty != oldValue { updateDirtyIndicator() } }
    }
    private var diskBaseline: String?
    private var editorToken = UUID().uuidString
    private struct RecoveryCopy: Codable {
        let path: String
        let text: String
        let savedAt: Date
        let diskModificationDate: Date?
        let diskSize: UInt64?
        // 保留原本的比對基準：還原後也要能偵測旁邊 AI 在當掉前後改過檔案。
        let baseline: String?
    }
    private var pendingRecovery: RecoveryCopy?
    private var reloadingWebProcess = false
    private var reloadedExternalChange = false
    static var conflictAnswer: String? = {
        let args = CommandLine.arguments
        guard args.contains("--state-dir"), let i = args.firstIndex(of: "--codelab-conflict-answer"),
              i + 1 < args.count, ["load", "keep", "cancel"].contains(args[i + 1]) else { return nil }
        return args[i + 1]
    }()
    private var isSwitchingFile = false
    /// 換檔存檔途中（isSwitchingFile）要求關閉的：等換檔做完再照新的狀態跑一次 saveForClose
    private var afterSwitch: [() -> Void] = []
    /// 關掉格子時：程式還在跑就不收（收掉會殺程式）；有沒存的修改先存再收（saveForClose）
    var isProgramRunning: Bool { runPanel.isRunning }
    /// 換檔途中也算：舊檔還在存，dirty 可能已經被新檔的 open 清掉，不能當成「沒東西要存」
    var hasUnsaved: Bool { dirty || isSwitchingFile }

    private var canAskAI: Bool {
        guard file != nil else { return false }
        if problem != nil || hasCleanRun { return true }
        return !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func updateAskButton() {
        let hide = !canAskAI
        if askButton.isHidden != hide {
            askButton.isHidden = hide
            needsLayout = true
        }
    }

    /// 解析 cl.text() 回傳的 { path, text }
    private static func unpackText(_ r: Any?) -> (path: String, text: String)? {
        guard let d = r as? [String: Any], let p = d["path"] as? String, let t = d["text"] as? String else { return nil }
        return (p, t)
    }

    /// 關掉格子、要收掉之前：改過的先存。done(true)＝沒改過、還沒開檔、或存好了，可以收；done(false)＝存不了（唯讀檔、編輯器還沒好），留著
    /// interactive：false＝背景自動收（沒人在看），遇到檔案被別處改過的衝突不跳視窗，直接不存、格子留著
    func saveForClose(interactive: Bool = true, _ done: @escaping (Bool) -> Void) {
        // 正在換檔（saveIfDirty 還在等 cl.text()）：這時讀編輯器可能讀到新檔，dirty 也可能已被新檔的 open 清成 false，
        // 照當下狀態判斷會讓舊檔沒存的修改跟著格子一起丟掉。排到換檔之後：換檔存好了就照新檔的狀態判斷，換檔失敗就留在舊檔再存一次
        if isSwitchingFile {
            afterSwitch.append { [weak self] in
                guard let self else { return done(true) }
                self.saveForClose(interactive: interactive, done)
            }
            return
        }
        // 還在問要不要還原：編輯器是唯讀、內容就是磁碟檔，不用存；副本留著下次開檔再問。
        // 不放行的話 Big5 檔（開檔就算改過）會因 save() 擋住而關不掉格子（agy Flash 11/6 審查）
        if pendingRecovery != nil { return done(true) }
        guard dirty, let target = file else { return done(true) }
        guard ready else { return done(false) }
        let token = editorToken
        web.evaluateJavaScript("cl.text()") { [weak self] r, _ in
            guard let self, let u = Self.unpackText(r) else { return done(false) }
            if self.editorToken != token { return self.saveForClose(interactive: interactive, done) }
            if u.path != target {
                // 等回呼的期間換了檔（file 變了）：照現在開著的檔和 dirty 重來一次。
                // file 沒變卻對不上＝編輯器狀態不明，寧可先不關，也不要憑 dirty 放行而丟掉修改
                if self.file != target { return self.saveForClose(interactive: interactive, done) }
                self.setStatus(L("讀不到編輯器裡的內容，先不關掉（修改還沒存）"))
                return done(false)
            }
            let previous = self.interactiveSave
            self.interactiveSave = interactive
            defer { self.interactiveSave = previous }
            done(self.save(u.text, from: u.path, to: target))
        }
    }
    /// 目前這次存檔能不能跳衝突視窗（saveForClose(interactive: false) 時為 false）
    private var interactiveSave = true
    private var showingConflict = false
    private var splitPlaced = false
    private var theme: Theme
    private(set) var mode: Mode
    /// 版面換了（不用 AI 的版面要 ChatPane 把聊天收起來）
    var onModeChange: (() -> Void)?
    private var showingRun = false {    // F10 換畫面：執行畫面正蓋在程式碼上
        didSet { if showingRun != oldValue { needsLayout = true } }
    }
    private var runWindow: NSWindow?    // F10 開視窗
    private var keyMonitor: Any?        // 執行完等「任意鍵」
    private var prefsSink: AnyCancellable?
    /// 測試用：執行完（finished 做完）通知
    var onRunFinished: ((Int32) -> Void)?

    static var folder: URL {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("codelab"), FileManager.default.fileExists(atPath: u.appendingPathComponent("editor.html").path) { return u }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/codelab")
    }

    /// directory：程式放哪（這段對話的資料夾）；key：記住上次打開哪個檔（每段對話一個）
    init(directory: String, key: String, theme: Theme) {
        self.directory = directory
        self.fileKey = "codelab.file." + key
        self.theme = theme
        mode = Mode(rawValue: Prefs.shared.codeLabLayout) ?? .below
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        web = WKWebView(frame: .zero, configuration: config)
        runPanel = RunPanel(theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        config.userContentController.add(CodeLabHandler(self), name: "codelab")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.loadFileURL(Self.folder.appendingPathComponent("editor.html"), allowingReadAccessTo: Self.folder)

        // 工具列：檔案、新檔案、檢查、執行（執行中變停止）、返回程式碼、狀態
        filePopup.bezelStyle = .inline
        filePopup.target = self
        filePopup.action = #selector(pickFile)
        filePopup.menu?.delegate = self
        for (b, title, sym, sel, tip) in [(newButton, L("新檔案"), "doc.badge.plus", #selector(newFile), L("在這個資料夾開一個新檔案")),
                                          (checkButton, L("檢查"), "checkmark.circle", #selector(check), L("存檔並檢查有沒有打錯（F9）")),
                                          (runButton, L("執行"), "play.fill", #selector(run), L("存檔、編譯並執行，結果在下面（F10）")),
                                          (backButton, L("返回程式碼"), "chevron.backward", #selector(backToCode), L("收起執行畫面，回到程式碼編輯器"))] {
            b.title = title
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            b.bezelStyle = .inline
            b.target = self
            b.action = sel
            b.toolTip = tip
            bar.addSubview(b)
        }
        backButton.isHidden = true
        bar.addSubview(filePopup)
        modePopup.bezelStyle = .inline
        for m in Mode.allCases { modePopup.addItem(withTitle: m.title); modePopup.lastItem?.toolTip = m.detail }
        modePopup.target = self
        modePopup.action = #selector(pickMode)
        modePopup.toolTip = L("版面（預設在 ⌘ , 的「對話」頁改）")
        bar.addSubview(modePopup)
        inputPopup.bezelStyle = .inline
        inputPopup.toolTip = L("執行時的輸入：用檔案當輸入（<檔名>.in 或 input.txt，在程式旁邊），或自己在執行結果裡打字")
        inputPopup.menu?.delegate = self
        bar.addSubview(inputPopup)
        askButton.title = L("問 AI")
        askButton.image = NSImage(systemSymbolName: "questionmark.bubble", accessibilityDescription: L("問 AI"))
        askButton.imagePosition = .imageLeading
        askButton.bezelStyle = .inline
        askButton.target = self
        askButton.action = #selector(askAI)
        askButton.toolTip = L("把目前的錯誤、執行結果或選取的程式碼整理進聊天框（看過、改過再送出）")
        askButton.isHidden = true
        bar.addSubview(askButton)
        moreButton.bezelStyle = .inline
        moreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L("更多"))
        moreButton.imagePosition = .imageOnly
        moreButton.target = self
        moreButton.action = #selector(showMore)
        moreButton.isHidden = true
        moreButton.toolTip = L("更多")
        bar.addSubview(moreButton)
        // 狀態文字自己一行（在工具列下面），完整顯示；太長時滑鼠停上去看全文
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)
        applyBarFonts()
        scaleSink = UIScale.shared.$factor.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.applyBarFonts(); self?.needsLayout = true
        }
        addSubview(bar)

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        addSubview(split)
        arrange()
        runPanel.onFinish = { [weak self] code in self?.finished(code) }
        // ⌘ , 改了預設版面：每個練習跟著換
        prefsSink = Prefs.shared.$codeLabLayout.dropFirst().receive(on: RunLoop.main).sink { [weak self] v in
            if let m = Mode(rawValue: v) { self?.setMode(m) }
        }
        reloadFiles()
        refreshInput()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if runPanel.isRunning { runPanel.stop() }
        // 解除主視窗對子視窗的強引用，避免刪除對話後 RunPanel 與背景程式留在記憶體裡殺不掉
        if let w = runWindow {
            w.delegate = nil
            w.parent?.removeChildWindow(w)
            w.orderOut(nil)
        }
        runPanel.removeFromSuperview()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            // 切到別的對話分頁或收起格子時，把浮在主視窗上的執行視窗一起收起來
            stopWaiting()
            closeRunWindow(focus: false)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(theme)
    }

    // MARK: 版面

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        arrange()
        onModeChange?()
        window?.makeFirstResponder(web)
        js("cl.focus()")
    }

    @objc private func pickMode() {
        if let m = Mode(rawValue: modePopup.indexOfSelectedItem + 1) { setMode(m) }
    }

    /// 照版面把程式碼、執行結果排進分隔視圖：上下分＝上下、不用 AI＝左右、另外兩種只有程式碼（執行時才拿出來）
    private func arrange() {
        modePopup.selectItem(at: mode.rawValue - 1)
        for v in split.arrangedSubviews { split.removeArrangedSubview(v); v.removeFromSuperview() }
        runPanel.removeFromSuperview()
        closeRunWindow(focus: false)
        showingRun = false
        stopWaiting()
        split.isVertical = mode == .noAI
        split.addArrangedSubview(web)
        if mode == .below || mode == .noAI {
            split.addArrangedSubview(runPanel)
            // 視窗變大變小：多出來的空間給程式碼，執行結果那塊盡量維持
            split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
        }
        splitPlaced = false
        needsLayout = true
    }

    /// 執行畫面拿出來：換畫面＝蓋在程式碼上、開視窗＝跳出一個 codenv 的視窗
    private func showRun() {
        switch mode {
        case .swap:
            showingRun = true
            addSubview(runPanel)
            runPanel.frame = split.frame
        case .popup:
            openRunWindow()
        default:
            break
        }
    }

    private func openRunWindow() {
        let w = runWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.minSize = NSSize(width: 320, height: 200)
            w.contentView = NSView()
            runWindow = w
            return w
        }()
        w.title = L("執行：") + ((file as NSString?)?.lastPathComponent ?? "")
        runPanel.frame = w.contentView!.bounds
        runPanel.autoresizingMask = [.width, .height]
        w.contentView!.addSubview(runPanel)
        if let parent = window, w.parent == nil {
            // 擺在主視窗正中間；當子視窗跟著主視窗（不會跑到後面去）
            let f = parent.frame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
            parent.addChildWindow(w, ordered: .above)
        }
        w.makeKeyAndOrderFront(nil)
    }

    private func closeRunWindow(focus: Bool) {
        guard let w = runWindow, w.isVisible || w.parent != nil else { return }
        w.parent?.removeChildWindow(w)
        w.orderOut(nil)
        runPanel.removeFromSuperview()
        runPanel.autoresizingMask = []
        if focus { window?.makeKeyAndOrderFront(nil) }
    }

    /// 按執行視窗的紅色叉叉：還在跑就停掉
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if runPanel.isRunning { runPanel.stop(); updateRunButton() }
        dismissRun(rerun: false)
        return false
    }

    private func updateRunButton() {
        let running = runPanel.isRunning
        let title = running ? L("停止") : L("執行")
        let sym = running ? "stop.fill" : "play.fill"
        runButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: title)
        runButton.action = running ? #selector(stopRun) : #selector(run)
        runButton.toolTip = running ? L("停掉正在執行的程式") : L("存檔、編譯並執行，結果在下面（F10）")
        runButton.contentTintColor = running ? .systemRed : nil
        needsLayout = true
    }

    @objc private func stopRun() {
        runPanel.stop()
        updateRunButton()
    }

    @objc private func backToCode() {
        dismissRun(rerun: false)
    }

    // MARK: 執行完等任意鍵

    private func sendMarkers(_ diags: [CodeDiagnostic]) {
        let list = diags.map { ["line": $0.line, "column": $0.column, "severity": $0.severity, "message": $0.message] as [String: Any] }
        if let d = try? JSONSerialization.data(withJSONObject: list), let s = String(data: d, encoding: .utf8) {
            js("cl.markers(\(s))")
        }
    }

    private func finished(_ code: Int32) {
        updateRunButton()
        // 用 RunPanel 記住的目標檔案讀紀錄；只有在它仍是目前開著的檔時才畫紅線與更新問 AI 狀態，避免切檔後污染新檔
        let ranFile = runPanel.currentFile
        let isCurrent = (ranFile != nil && ranFile == self.file)
        if runPanel.stoppedForOutputLimit {
            if isCurrent { hasCleanRun = false }
            // 10 MB 是保護硬碟的上限，不代表程式一定寫錯：可能是無限迴圈，也可能本來就要印很多，所以不下「無限迴圈」的結論
            runPanel.terminal.feed(text: "\r\n\u{1b}[31m" + L("—— 輸出超過 10 MB，為了避免塞爆硬碟先停下來 ——") + "\u{1b}[0m\r\n")
            setStatus(L("已停止：輸出超過 10 MB，為了避免塞爆硬碟先停下來；如果是正常的大量輸出，請改成寫檔或減少輸出"))
            if let ranFile {
                let tail = Self.logTail(CodeRunner.lastRunLog(for: ranFile))
                if isCurrent {
                    problem = (L("執行時輸出超過 10 MB，被自動停下來（可能是無限迴圈，也可能只是輸出太多）"), tail)
                }
            }
        } else if runPanel.stoppedByUser {
            if isCurrent {
                hasCleanRun = false
                problem = nil
            }
            setStatus(L("已停止"))
        } else if code == 0 {
            if isCurrent {
                hasCleanRun = true
                problem = nil
            }
            setStatus(L("執行完（代碼 0）"))
        } else {
            if isCurrent { hasCleanRun = false }
            let logText = ranFile.map { Self.readLogTail(CodeRunner.lastRunLog(for: $0)) ?? "" } ?? ""
            if let explain = CodeRunner.describeExit(code: code, log: logText) {
                var statusLine = explain
                if code == 86, let ranFile {
                    // 代碼 86 有兩種：「檔名:行:字: runtime error:」（除以 0、越界）和 sanitizer 抓到的 SEGV（例如寫進空指標），紅線的來源不同
                    let fault = CodeRunner.isSanitizerMemoryFault(logText)
                    let rts = fault ? CodeRunner.parseMemoryFault(logText, file: ranFile) : CodeRunner.parseRuntimeErrors(logText, file: ranFile)
                    if !rts.isEmpty {
                        if isCurrent { sendMarkers(rts) }
                        statusLine = explain + " — " + rts[0].message
                    } else if fault {
                        statusLine = explain + CodeRunner.memoryFaultHint(logText)   // 找不到行號（stack 沒有「檔名:行」）：不畫紅線，至少把空指標的提示講出來
                    }
                }
                setStatus(statusLine)
                if isCurrent, ranFile != nil { problem = (L("執行時失敗了（\(explain)）"), Self.tail(logText)) }
            } else {
                setStatus(L("執行結束（代碼 \(code)）"))
                if isCurrent, let ranFile { markCompileErrors(for: ranFile) }
                if isCurrent, ranFile != nil { problem = (L("執行時失敗了（結束代碼 \(code)）"), Self.tail(logText)) }
            }
        }
        let runVisible = mode == .below || mode == .noAI || (mode == .swap && showingRun) || (mode == .popup && runWindow?.isVisible == true)
        if runVisible {
            runPanel.terminal.feed(text: "\r\n\u{1b}[2m" + L("按任意鍵回到程式碼（⌘ C 可以先複製）") + "\u{1b}[0m")
        }
        runPanel.terminal.needsDisplay = true   // 搬過家的終端機（換畫面、開視窗）不一定自己重畫
        // 執行區仍顯示時才提示並等待按鍵；上下分、不用 AI 返回時保留結果。
        // waitForKey 只攔執行區的按鍵，焦點已在編輯器或聊天時不吃鍵、不搶焦點
        if runVisible { waitForKey() }
        onRunFinished?(code)
    }

    /// 編譯失敗（或 Python 語法錯）：跟 F9 一樣在程式碼上畫紅線；若語法檢查通過（只是程式自己 return 非 0），就不蓋掉狀態列
    private func markCompileErrors(for targetFile: String) {
        CodeRunner.check(file: targetFile) { [weak self] status, diags, msg in
            guard let self, self.file == targetFile, status == .failed else { return }
            if !diags.isEmpty { self.sendMarkers(diags) }
            let errors = diags.filter { $0.severity == "error" }.count
            let first = msg.split(separator: "\n").map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if errors > 0 {
                self.setStatus(L("編譯失敗：\(errors) 個錯誤（程式碼上畫了紅線）") + (first.map { "：" + $0 } ?? ""))
            } else if let first {
                self.setStatus(L("編譯失敗：") + first)
            }
        }
    }

    /// 游標在執行結果裡時，下一個沒按著 ⌘ ⌥ ⌃ 的鍵＝回到程式碼（F10＝回去再跑一次）
    private func waitForKey() {
        stopWaiting()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = e.window else { return e }
            let inRun = w === self.runWindow || (w === self.window && w.firstResponder === self.runPanel.terminal)
            guard inRun, e.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return e }
            self.dismissRun(rerun: e.keyCode == 109)   // 109＝F10
            return nil
        }
    }

    private func stopWaiting() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// ⌃ A 方向鍵在聊天和程式碼區之間移動（使用者 11/5）：聊天往右進編輯器；編輯器和執行結果之間照版面（上下分是上下、不用 AI 是左右）；
    /// 程式碼區往左回聊天輸入框。回傳 false＝這個方向出了這一格，交給外面切到隔壁格
    func moveFocus(dx: Int, dy: Int, chat: ChatPane) -> Bool {
        guard let w = window, let v = w.firstResponder as? NSView else { return false }
        let runShown = runPanel.superview === split        // 上下分、不用 AI 才有固定的執行結果區
        let chatShown = mode != .noAI
        if !v.isDescendant(of: self) {
            guard chatShown, dx > 0, v.isDescendant(of: chat) else { return false }
            focusEditor(); return true
        }
        let inRun = v.isDescendant(of: runPanel)
        if runShown, !inRun, split.isVertical ? dx > 0 : dy > 0 { w.makeFirstResponder(runPanel.terminal); return true }
        if runShown, inRun, split.isVertical ? dx < 0 : dy < 0 { focusEditor(); return true }
        if chatShown, dx < 0 { return chat.focusInput() }
        return false
    }

    func focusEditor() {
        window?.makeFirstResponder(web)
        js("cl.focus()")
    }

    /// 游標回到程式碼；換畫面、開視窗收起執行畫面，上下分、不用 AI 保留結果
    private func dismissRun(rerun: Bool) {
        stopWaiting()
        if mode == .swap || mode == .popup {
            if showingRun { showingRun = false; runPanel.removeFromSuperview() }
            closeRunWindow(focus: true)
        }
        focusEditor()
        if rerun { run() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 工具列和狀態列的字級：跟整體文字大小（UIScale）一起放大，大約等於聊天輸入框的字
    private var sc: CGFloat { UIScale.shared.f }
    private func applyBarFonts() {
        let f = NSFont.systemFont(ofSize: 13 * sc)
        for c in [filePopup, modePopup, inputPopup] { c.font = f }
        for b in [newButton, checkButton, runButton, backButton, askButton] { b.font = f }
        status.font = .systemFont(ofSize: 12.5 * sc)
        inputPopup.menu?.font = f
        refreshInput()
    }

    override func layout() {
        super.layout()
        let barH = (34 * sc).rounded(), statusH = (22 * sc).rounded(), ctl = (26 * sc).rounded()
        bar.frame = NSRect(x: 0, y: bounds.height - barH, width: bounds.width, height: barH)
        status.frame = NSRect(x: 12, y: bounds.height - barH - statusH + (3 * sc).rounded(), width: max(0, bounds.width - 24), height: (18 * sc).rounded())
        layoutBar(controlHeight: ctl, barHeight: barH)
        split.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barH - statusH))
        if showingRun { runPanel.frame = split.frame }
        // 第一次有夠大的空間才放分隔線（上下分：上 62% 程式碼；不用 AI：左右各半）；之後照使用者拖的
        let total = split.isVertical ? split.frame.width : split.frame.height
        if !splitPlaced, split.arrangedSubviews.count == 2, total > 200 {
            splitPlaced = true
            split.adjustSubviews()
            split.setPosition((total * (split.isVertical ? 0.5 : 0.62)).rounded(), ofDividerAt: 0)
        }
    }

    /// 工具列排版：寬度夠就全放；不夠就一級一級收——先把按鈕縮成圖示，再把版面、輸入、新檔案收進「⋯」，字不會被截斷
    private func layoutBar(controlHeight ctl: CGFloat, barHeight: CGFloat) {
        let margin: CGFloat = 8, gap: CGFloat = 6
        let avail = bounds.width - margin * 2
        let iconW = (30 * sc).rounded()
        let fileIdeal = min(260 * sc, max(130 * sc, bounds.width * 0.28)), fileMin = 110 * sc
        let askShown = canAskAI
        let backShown = showingRun
        let runTitle = runPanel.isRunning ? L("停止") : L("執行")
        // 寬度一律照完整標題算（縮成圖示時 title 是空的，不能拿來量）
        let fullTitles: [NSButton: String] = [newButton: L("新檔案"), checkButton: L("檢查"), runButton: runTitle, backButton: L("返回程式碼"), askButton: L("問 AI")]
        let font = NSFont.systemFont(ofSize: 13 * sc)
        func textW(_ b: NSButton) -> CGFloat { NSAttributedString(string: fullTitles[b] ?? "", attributes: [.font: font]).size().width + (b.image?.size.width ?? 16) + 24 }
        var level = 0
        var fileW = fileIdeal
        var items: [(NSView, CGFloat)] = []
        while true {
            let icons = level >= 1
            items = []
            if level < 4 { items.append((newButton, icons ? iconW : textW(newButton))) }
            items.append((checkButton, icons ? iconW : textW(checkButton)))
            items.append((runButton, icons ? iconW : textW(runButton)))
            if backShown { items.append((backButton, icons ? iconW : textW(backButton))) }
            if level < 3 { items.append((inputPopup, inputPopup.intrinsicContentSize.width + 6)) }
            if askShown { items.append((askButton, icons ? iconW : textW(askButton))) }
            if level < 2 { items.append((modePopup, modePopup.intrinsicContentSize.width + 6)) }
            if level >= 2 { items.append((moreButton, (46 * sc).rounded())) }
            let fixed = items.reduce(0) { $0 + $1.1 + gap }
            fileW = min(fileIdeal, avail - fixed - gap)    // 檔名選單後面也要留一個間距
            if fileW >= fileMin || level == 4 { fileW = max(60, fileW); break }
            level += 1
        }
        barLevel = level
        for v in [newButton, checkButton, runButton, backButton, inputPopup, askButton, modePopup, moreButton] as [NSView] { v.isHidden = true }
        askButton.isHidden = !askShown
        for b in [newButton, checkButton, runButton, backButton, askButton] {
            let icons = level >= 1
            b.imagePosition = icons ? .imageOnly : .imageLeading
            b.title = icons ? "" : (fullTitles[b] ?? "")     // 圖示模式：名字在 tooltip 和「⋯」裡
        }
        let y = ((barHeight - ctl) / 2).rounded()
        var x = margin
        filePopup.frame = NSRect(x: x, y: y, width: fileW, height: ctl); x += fileW + gap
        for (v, w) in items {
            v.isHidden = false
            v.frame = NSRect(x: x, y: y, width: w, height: ctl); x += w + gap
        }
        if level >= 2 { rebuildMore(level: level) }
    }

    /// 「⋯」選單：收進來的新檔案、輸入、版面（有選項的做成子選單，目前的打勾）
    private func rebuildMore(level: Int) {
        let key = "\(level)|\(mode.rawValue)|\(showingRun)|\(file ?? "")|\(inputPopup.title)|\(UIScale.shared.factor)"
        guard key != moreKey else { return }
        moreKey = key
        let m = NSMenu()
        m.font = NSFont.systemFont(ofSize: 13 * sc)
        if showingRun {
            let b = NSMenuItem(title: L("返回程式碼"), action: #selector(backToCode), keyEquivalent: "")
            b.target = self; m.addItem(b)
            m.addItem(.separator())
        }
        if level >= 4 {
            let n = NSMenuItem(title: L("新檔案"), action: #selector(newFile), keyEquivalent: ""); n.target = self; m.addItem(n)
        }
        if level >= 3 {
            let it = NSMenuItem(title: L("輸入"), action: nil, keyEquivalent: "")
            let sub = NSMenu(); for i in inputMenuItems() { sub.addItem(i) }
            it.submenu = sub; m.addItem(it)
        }
        let layout = NSMenuItem(title: L("版面"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for md in Mode.allCases {
            let i = NSMenuItem(title: md.title, action: #selector(pickModeItem(_:)), keyEquivalent: "")
            i.target = self; i.tag = md.rawValue; i.toolTip = md.detail; i.state = md == mode ? .on : .off
            sub.addItem(i)
        }
        layout.submenu = sub; m.addItem(layout)
        moreMenu = m
    }

    @objc private func showMore() {
        refreshInput()
        moreKey = ""; rebuildMore(level: barLevel)      // 彈出前重建：打勾的版面、輸入選項一定是現在的
        moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 2), in: moreButton)
    }

    @objc private func pickModeItem(_ i: NSMenuItem) { if let md = Mode(rawValue: i.tag) { setMode(md) } }

    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 80 }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { (s.isVertical ? s.frame.width : s.frame.height) - 60 }

    func applyTheme(_ t: Theme) {
        theme = t
        runPanel.theme = t
        guard ready else { return }
        let pal = t.palette(for: effectiveAppearance)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        js("cl.theme(\(dark), \(Self.jsString(pal.bg.hex)), \(Self.jsString(pal.fg.hex)), \(Self.jsString(t.font.fontName + ", Menlo, monospace")), \(Int(t.font.pointSize)))")
    }

    // MARK: 檔案

    private static let exts = ["cpp", "cc", "cxx", "c", "h", "hpp", "py", "txt", "in"]
    /// 編輯器可開啟的檔案上限（2 MB）：避免幾十 MB 的競賽測資 .in／輸出 .txt 塞進 Monaco 卡死主執行緒
    private static let maxOpenBytes: UInt64 = 2 * 1024 * 1024

    private static func canAutoOpen(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let sz = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else { return false }
        return sz <= maxOpenBytes
    }

    private func preferredInitialFile() -> String? {
        let candidates = sourceFiles().filter { Self.canAutoOpen((directory as NSString).appendingPathComponent($0)) }
        return candidates.first(where: { CodeRunner.isRunnable($0) }) ?? candidates.first
    }

    /// 資料夾裡的程式檔（相對路徑）：最上層加往下一層子資料夾（programming_language 是 c++／python 分開放；bin 是執行檔不算）
    private func sourceFiles() -> [String] {
        let fm = FileManager.default
        let top = ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).filter { !$0.hasPrefix(".") && $0 != "bin" }
        var names = top
        for d in top {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: (directory as NSString).appendingPathComponent(d), isDirectory: &isDir), isDir.boolValue else { continue }
            names += ((try? fm.contentsOfDirectory(atPath: (directory as NSString).appendingPathComponent(d))) ?? []).filter { !$0.hasPrefix(".") }.map { d + "/" + $0 }
        }
        return names.filter { Self.exts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { a, b in
                let da = (try? fm.attributesOfItem(atPath: (directory as NSString).appendingPathComponent(a))[.modificationDate] as? Date) ?? .distantPast
                let db = (try? fm.attributesOfItem(atPath: (directory as NSString).appendingPathComponent(b))[.modificationDate] as? Date) ?? .distantPast
                return da > db
            }
    }

    private func relativePath(of path: String) -> String {
        let dirPrefix = (directory as NSString).standardizingPath + "/"
        let std = (path as NSString).standardizingPath
        return std.hasPrefix(dirPrefix) ? String(std.dropFirst(dirPrefix.count)) : (std as NSString).lastPathComponent
    }

    private func reloadFiles() {
        filePopup.removeAllItems()
        let files = sourceFiles()
        if files.isEmpty {
            filePopup.addItem(withTitle: L("（還沒有程式檔，按「新檔案」）"))
            filePopup.lastItem?.isEnabled = false
            return
        }
        let cur = file.map(relativePath(of:))
        for f in files {
            let isCur = (f == cur)
            filePopup.addItem(withTitle: (isCur && dirty) ? "● " + f : f)
            filePopup.lastItem?.representedObject = f
            if isCur, let item = filePopup.lastItem { filePopup.select(item) }
        }
    }

    /// 未存檔標記：在檔案選單目前那一項前面加「● 」，存好就拿掉（只改選單標題，不每次打字都重掃磁碟）
    private func updateDirtyIndicator() {
        let cur = file.map(relativePath(of:))
        for item in filePopup.itemArray {
            guard let rel = item.representedObject as? String else { continue }
            item.title = (rel == cur && dirty) ? "● " + rel : rel
        }
        filePopup.needsDisplay = true
    }

    /// 點開檔案／輸入下拉選單時重新掃一次資料夾，外面剛下載或放進來的範例檔、.in 測資馬上找得到
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === filePopup.menu { reloadFiles() }
        else if menu === inputPopup.menu { refreshInput() }
    }

    // MARK: 問 AI

    static let askLines = 40
    /// 去掉終端機的顏色碼和 \r，只留最後 askLines 行（太長再截尾巴）
    static func tail(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression).replacingOccurrences(of: "\r", with: "")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = t.components(separatedBy: "\n")
        t = lines.suffix(askLines).joined(separator: "\n")
        return t.count > 4000 ? "…" + t.suffix(4000) : t
    }
    /// 只讀紀錄檔尾巴（最多 64 KB），避免死迴圈幾百 MB 輸出卡死主執行緒；寬容 UTF-8 解碼避免 C 亂碼 byte 讓整份輸出變空
    static func readLogTail(_ path: String, maxBytes: UInt64 = 65_536) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let end = fh.seekToEndOfFile()
        fh.seek(toFileOffset: end > maxBytes ? end - maxBytes : 0)
        let data = fh.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
    static func logTail(_ path: String) -> String { tail(readLogTail(path) ?? "") }

    /// 問 AI 的訊息：有錯誤問錯誤；沒錯誤但選取了程式碼就問那段；剛跑完代碼 0（例如答案跟預期不同）就附輸出請 AI 引導
    func askMessage() -> String? {
        guard let file else { return nil }
        let name = (file as NSString).lastPathComponent
        let input = lastInput.map { L("用 \(($0 as NSString).lastPathComponent) 當輸入") } ?? L("沒有用輸入檔（自己在執行畫面打字，或不需要輸入）")
        if let p = problem {
            return L("我在寫作業，\(name) \(p.what)。\n輸入：\(input)\n\n錯誤輸出（最後 \(Self.askLines) 行以內）：\n```\n\(p.text)\n```\n\n請不要直接給我完整答案或改好的程式碼。先用白話告訴我這個錯誤大概代表什麼，再用一兩個問題引導我自己找出原因，我想自己想出怎麼改。")
        }
        if !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("我在看 \(name)（游標在第 \(cursorLine) 行附近），想請教我選取的這段程式碼：\n```\n\(selection)\n```\n\n請用白話和引導的方式解釋這段在做什麼（如果是作業的一部分，請不要直接幫我寫出完整答案）。")
        }
        if hasCleanRun {
            let out = Self.logTail(CodeRunner.lastRunLog(for: file))
            return L("我在寫作業，\(name) 編譯和執行都沒報錯（代碼 0），但跑出來的結果跟預期的不一樣。\n輸入：\(input)\n\n最後一次輸出（最後 \(Self.askLines) 行以內）：\n```\n\(out)\n```\n\n我的預期結果／題目要求是：（請在這裡補上）\n\n請不要直接給我完整答案或改好的程式碼。先幫我看看目前的輸出可能哪裡邏輯有落差，再用一兩個問題引導我自己找出原因。")
        }
        return nil
    }

    @objc private func askAI() {
        guard let msg = askMessage() else { return }
        if mode == .noAI { setStatus(L("「不用 AI」版面沒有聊天室，先換成其他版面再問")); return }
        if onAskAI?(msg) == true {
            setStatus(problem != nil ? L("已把錯誤放進聊天框，看過、改過再送出") : L("已把問題放進聊天框，補上說明或看過後再送出"))
        } else {
            setStatus(L("旁邊沒有聊天室，先開一個再問"))
        }
    }

    // MARK: 輸入檔（stdin）

    /// 工具列的「輸入：…」選單：自己打字／自動找到的檔（<檔名>.in、input.txt）／使用者指定的檔／選擇輸入檔…。選擇照檔案記
    private func refreshInput() {
        moreKey = ""     // ⋯ 選單裡的輸入子選單跟著重建
        inputPopup.removeAllItems()
        let f = NSFont.systemFont(ofSize: 13 * sc)
        guard let file else {
            inputPopup.addItem(withTitle: L("輸入：打字")); inputPopup.isEnabled = false; needsLayout = true; return
        }
        inputPopup.isEnabled = true
        let choice = appDefaults.string(forKey: CodeRunner.inputChoiceKey(file))
        let auto = CodeRunner.autoInput(for: file)
        func name(_ p: String) -> String { (p as NSString).lastPathComponent }
        // 按鈕上的短標題：目前這個檔案的輸入是什麼
        var shortTitle = L("輸入：打字")
        if choice != "typing" {
            if let c = choice, c != "auto", !c.isEmpty, FileManager.default.fileExists(atPath: c) { shortTitle = L("輸入：\(name(c))") }
            else if let a = auto { shortTitle = L("輸入：\(name(a))") }
        }
        inputPopup.addItem(withTitle: shortTitle)      // 下拉式按鈕的第一項＝按鈕上的字
        for i in inputMenuItems() { inputPopup.menu?.addItem(i) }
        inputPopup.menu?.font = f
        inputPopup.toolTip = L("執行時的輸入：用檔案當輸入（<檔名>.in 或 input.txt，在程式旁邊），或自己在執行結果裡打字") + "\n" + shortTitle
        needsLayout = true
    }

    /// 輸入選單的選項（完整說明；目前的打勾）。工具列的下拉和「⋯」裡的子選單共用
    private func inputMenuItems() -> [NSMenuItem] {
        guard let file else { return [] }
        let choice = appDefaults.string(forKey: CodeRunner.inputChoiceKey(file))
        let auto = CodeRunner.autoInput(for: file)
        func name(_ p: String) -> String { (p as NSString).lastPathComponent }
        var out: [NSMenuItem] = []
        func add(_ title: String, tag: Int, on: Bool, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: #selector(pickInputItem(_:)), keyEquivalent: "")
            i.target = self; i.tag = tag; i.state = on ? .on : .off; i.isEnabled = enabled
            out.append(i)
        }
        var customShown = false
        var custom: String?
        if let c = choice, c != "typing", c != "auto", !c.isEmpty, FileManager.default.fileExists(atPath: c) { customShown = true; custom = c }
        add(L("自己打字（在執行結果裡輸入）"), tag: 0, on: choice == "typing" || (!customShown && auto == nil))   // 沒有可用的輸入檔時實際上就是自己打字
        add(auto.map { L("用 \(name($0)) 當輸入") } ?? L("沒有 input.txt 或 <檔名>.in 可用"), tag: 1, on: choice != "typing" && !customShown && auto != nil, enabled: auto != nil)
        if let c = custom { add(L("用 \(name(c)) 當輸入（你選的）"), tag: 2, on: true) }
        out.append(.separator())
        add(L("選擇輸入檔…"), tag: 3, on: false)
        return out
    }

    private func setInputChoice(_ v: String?) {
        guard let file else { return }
        if let v { appDefaults.set(v, forKey: CodeRunner.inputChoiceKey(file)) } else { appDefaults.removeObject(forKey: CodeRunner.inputChoiceKey(file)) }
        refreshInput()
    }

    @objc private func pickInputItem(_ item: NSMenuItem) {
        guard let file else { return }
        switch item.tag {
        case 0: setInputChoice("typing")
        case 1: setInputChoice(nil)
        case 3:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: (file as NSString).deletingLastPathComponent)
            panel.message = L("選一個文字檔當程式的輸入（stdin）")
            if panel.runModal() == .OK, let u = panel.url { setInputChoice(u.path) } else { refreshInput() }
        default: break
        }
    }

    @objc private func pickFile() {
        let raw = (filePopup.selectedItem?.representedObject as? String) ?? filePopup.titleOfSelectedItem
        guard let name = raw, sourceFiles().contains(name) else { return }
        let target = (directory as NSString).appendingPathComponent(name)
        if target == file { return }
        saveIfDirty(failed: { [weak self] in self?.reloadFiles() }) { [weak self] in self?.open(target) }
    }

    private static func starterTemplate(for ext: String) -> String {
        switch ext {
        case "cpp", "cc", "cxx":
            return "#include <iostream>\nusing namespace std;\n\nint main() {\n    \n    return 0;\n}\n"
        case "c":
            return "#include <stdio.h>\n\nint main(void) {\n    \n    return 0;\n}\n"
        default:
            return ""
        }
    }

    @objc private func newFile() {
        let a = NSAlert()
        a.messageText = L("新檔案")
        a.informativeText = L("檔名（例如 hw1.cpp、test.py、c++/hw2.cpp；沒寫副檔名就是 .cpp）")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = tf
        a.addButton(withTitle: L("建立"))
        a.addButton(withTitle: L("取消"))
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var name = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let rawParts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !name.hasPrefix("/"), !rawParts.contains(""), !rawParts.contains("."), !rawParts.contains(".."), rawParts.count <= 2 else {
            setStatus(L("檔名格式不對：請輸入檔名（或「子資料夾/檔名」，最多一層子資料夾）"))
            return
        }
        guard !rawParts.contains(where: { $0.hasPrefix(".") }), rawParts.first != "bin" else {
            setStatus(L("不能建立「.」開頭的隱藏檔，也不能放在 bin 資料夾（bin 是放執行檔的）"))
            return
        }
        if (name as NSString).pathExtension.isEmpty { name += ".cpp" }
        let ext = (name as NSString).pathExtension.lowercased()
        guard Self.exts.contains(ext) else {
            setStatus(L("這裡只支援 C／C++（.cpp、.c、.h）、Python（.py）與輸入檔（.in、.txt）"))
            return
        }
        let path = (directory as NSString).appendingPathComponent(name)
        // 子資料夾可能是指到工作區外的 symlink：解析真正的位置，不在工作區裡就不建
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path + "/"
        var probe = URL(fileURLWithPath: path).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: probe.path), probe.path.count > 1 { probe.deleteLastPathComponent() }
        guard (probe.resolvingSymlinksInPath().path + "/").hasPrefix(root) else { setStatus(L("這個位置在工作資料夾外面，沒有建立")); return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            let starter = Self.starterTemplate(for: ext)
            try? starter.write(toFile: path, atomically: true, encoding: .utf8)
        }
        saveIfDirty { [weak self] in self?.open(path); self?.reloadFiles() }
    }

    /// 打開檔案：UTF-8 讀不懂就當 Big5（老師給的 Windows 檔），存檔時轉成 UTF-8
    func open(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            setStatus(L("打不開 \(path)"))
            reloadFiles()
            return
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if size > Self.maxOpenBytes {
            let name = (path as NSString).lastPathComponent
            let mb = String(format: "%.1f MB", Double(size) / 1_048_576)
            setStatus(L("檔案太大（\(mb)），不載入編輯器：\(name)（仍可選為輸入檔）"))
            reloadFiles()
            return
        }
        guard let data = FileManager.default.contents(atPath: path) else { setStatus(L("打不開 \(path)")); reloadFiles(); return }
        let decoded = Self.decodeFile(data)
        let text = decoded?.text
        var note = ""
        if decoded?.big5 == true { note = L("這個檔案的中文是 Windows 的 Big5 編碼，存檔時會轉成 UTF-8") }
        // UTF-8 和 Big5 都讀不出來（二進位檔、別的編碼、壞掉的檔）：不開，也不換掉現在開著的檔——
        // 開成空白再讓人存檔，會把原檔蓋成空的。這裡 return 之後這個檔完全沒被碰過
        guard let text else {
            let name = (path as NSString).lastPathComponent
            setStatus(L("這個檔案的編碼讀不出來，不開啟：\(name)"))
            reloadFiles()       // 下拉選單選回現在開著的檔
            if appDefaults === UserDefaults.standard {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = L("這個檔案的編碼讀不出來，不開啟")
                a.informativeText = L("\(name) 不是 UTF-8，也不是 Big5，可能是二進位檔或壞掉的檔案。為了不蓋掉原檔，這裡不會打開它。")
                a.runModal()
            }
            return
        }
        // 換檔前解除執行結束後的按鍵監聽；換畫面也收起舊終端機，避免擋住新開的程式碼
        if !runPanel.isRunning {
            stopWaiting()
            if showingRun {
                if reloadingWebProcess {
                    showingRun = false
                    runPanel.removeFromSuperview()
                    closeRunWindow(focus: false)
                } else { dismissRun(rerun: false) }
            }
        }
        file = path
        pendingRecovery = nil
        diskBaseline = text
        hasCleanRun = false
        problem = nil
        appDefaults.set(path, forKey: fileKey)
        dirty = !note.isEmpty
        loadEditor(text, path: path)
        cursorLine = 1; selection = ""
        reloadFiles()
        refreshInput()
        setStatus(note.isEmpty ? (path as NSString).lastPathComponent : note)
        offerRecovery(path: path, diskText: text, diskDate: attrs[.modificationDate] as? Date)
    }

    /// 檔案內容解碼：UTF-8，不行再當 Big5（老師給的 Windows 檔）。都不行回 nil（二進位檔、別的編碼）。開檔和存檔前比對磁碟共用，兩邊對「讀得懂」的定義才一致
    static func decodeFile(_ data: Data) -> (text: String, big5: Bool)? {
        if let t = String(data: data, encoding: .utf8) { return (t, false) }
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue)))
        if let t = String(data: data, encoding: big5) { return (t, true) }
        return nil
    }

    /// 比較時忽略換行格式與結尾多餘的換行。
    private static func comparableText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        while value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    private func loadDiskVersion(_ text: String, path: String) {
        pendingRecovery = nil
        loadEditor(text, path: path)
        diskBaseline = text
        dirty = false
        removeRecovery(for: path)
    }

    private func loadEditor(_ text: String, path: String) {
        editorToken = UUID().uuidString
        let ext = (path as NSString).pathExtension.lowercased()
        let lang = ext == "py" ? "python" : (["cpp", "cc", "cxx", "c", "h", "hpp"].contains(ext) ? "cpp" : "plaintext")
        js("cl.open(\(Self.jsString(path)), \(Self.jsString(text)), \(Self.jsString(lang)), \(Self.jsString(editorToken)))")
    }

    private static var recoveryDirectory: URL {
        let args = CommandLine.arguments
        let root = args.firstIndex(of: "--state-dir").flatMap {
            $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil
        } ?? Edition.supportDir
        return root.appendingPathComponent("codelab/recovery", isDirectory: true)
    }

    private static func recoveryURL(for path: String) -> URL {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return recoveryDirectory.appendingPathComponent(hash + ".json")
    }

    @discardableResult private func removeRecovery(for path: String) -> Bool {
        let url = Self.recoveryURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do { try FileManager.default.removeItem(at: url); return true }
        catch { setStatus(L("復原副本刪除失敗：\(error.localizedDescription)")); return false }
    }

    private func writeRecovery(_ text: String, path: String) {
        guard path == file, dirty, pendingRecovery == nil,
              text.utf8.count <= Int(Self.maxOpenBytes) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let copy = RecoveryCopy(path: path, text: text, savedAt: Date(),
                                diskModificationDate: attrs?[.modificationDate] as? Date,
                                diskSize: (attrs?[.size] as? NSNumber)?.uint64Value,
                                baseline: diskBaseline)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try FileManager.default.createDirectory(at: Self.recoveryDirectory, withIntermediateDirectories: true)
            try encoder.encode(copy).write(to: Self.recoveryURL(for: path), options: .atomic)
        } catch { setStatus(L("復原副本寫入失敗：\(error.localizedDescription)")) }
    }

    private func offerRecovery(path: String, diskText: String, diskDate: Date?) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = try? Data(contentsOf: Self.recoveryURL(for: path)),
              let copy = try? decoder.decode(RecoveryCopy.self, from: data), copy.path == path,
              copy.text.utf8.count <= Int(Self.maxOpenBytes) else { return }
        // 原檔已存成相同內容（例如寫完原檔、還沒刪副本就當掉），不用再問。
        if copy.text == diskText { removeRecovery(for: path); return }
        // 副本比磁碟檔舊（之後別人或 AI 又改過這個檔）也要問：不問的話一打字就把唯一的副本蓋掉（agy Sonnet 11/6 審查）。
        // 還原後存檔時照樣走外部修改的衝突比對（baseline 是當時的磁碟內容）
        let diskNewer = copy.savedAt <= (diskDate ?? .distantPast)
        pendingRecovery = copy
        let msg = diskNewer ? L("上次有沒存的修改，但這個檔之後又被改過。要還原嗎？（存檔時會再比對兩邊）") : L("上次有沒存的修改，要還原嗎？")
        js("cl.offerRecovery(\(Self.jsString(msg)), \(Self.jsString(L("還原"))), \(Self.jsString(L("丟掉"))))")
    }

    private func chooseRecovery(restore: Bool) {
        guard let copy = pendingRecovery, copy.path == file else { return }
        if restore {
            pendingRecovery = nil
            diskBaseline = copy.baseline ?? diskBaseline
            loadEditor(copy.text, path: copy.path)
            dirty = true
            setStatus(L("已還原上次沒存的修改（尚未存檔）"))
        } else {
            // 只丟復原副本；原始磁碟檔案與開檔時的編碼提示維持原狀。
            guard removeRecovery(for: copy.path) else { return }
            pendingRecovery = nil
            loadEditor(diskBaseline ?? "", path: copy.path)
            setStatus(L("已丟掉復原副本"))
        }
    }

    /// 明確選擇「不存，直接結束」才刪；一般關閉／背景收格失敗仍保留副本。
    func discardRecoveryForQuit() {
        guard let file else { return }
        removeRecovery(for: file)
        dirty = false
        editorToken = UUID().uuidString // 拒收已排進橋接佇列的舊備份
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        reloadingWebProcess = true
        // 最近一次已收到的內容在副本裡；重載後走同一個還原提示，不叫出視窗或設焦點。
        webView.reload()
    }

    /// 存進指定的 targetFile；核對路徑，避免非同步切檔把 A 檔寫進 B 檔。
    private func save(_ text: String, from sourcePath: String, to targetFile: String) -> Bool {
        reloadedExternalChange = false
        guard !targetFile.isEmpty else { setStatus(L("先選一個檔案或按「新檔案」")); return false }
        guard sourcePath == targetFile else { return false }
        guard pendingRecovery == nil else { setStatus(L("上次有沒存的修改，要還原嗎？")); return false }
        do {
            // 磁碟上的檔案已經不是我們上次讀／寫的樣子（旁邊的 AI 改過）。檔案被刪掉就照舊寫回去；讀不出來（不是 UTF-8 也不是 Big5）算有衝突，不能無聲蓋掉
            var diskText: String?
            var diskChanged = false
            if file == targetFile, let baseline = diskBaseline, let raw = FileManager.default.contents(atPath: targetFile) {
                if let d = Self.decodeFile(raw) { diskText = d.text; diskChanged = Self.comparableText(d.text) != Self.comparableText(baseline) }
                else { diskChanged = true }
            }
            if diskChanged, let baseline = diskBaseline {
                // 只看內容有沒有跟基準不同（dirty 旗標來自另一條非同步路徑，可能還沒更新，不能靠它）
                if let disk = diskText, Self.comparableText(text) == Self.comparableText(baseline) {
                    loadDiskVersion(disk, path: targetFile)
                    reloadedExternalChange = true
                    setStatus(L("檔案被別處改過，已載入新版"))
                    return false
                }
                let answer: String
                if !interactiveSave {
                    setStatus(L("\((targetFile as NSString).lastPathComponent) 被別處改過，你也有修改：先不自動收，請回來處理"))
                    return false
                }
                if showingConflict { return false }
                if let automatic = Self.conflictAnswer, CommandLine.arguments.contains("--state-dir") {
                    answer = automatic
                } else {
                    showingConflict = true
                    defer { showingConflict = false }
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = L("「\((targetFile as NSString).lastPathComponent)」被別處改過，你也有修改")
                    alert.informativeText = L("請選擇要保留的版本。載入新版前會先另存你的修改。")
                    alert.addButton(withTitle: diskText == nil ? L("我的修改另存一份（編輯器不動）") : L("載入新版（我的修改另存一份）"))
                    alert.addButton(withTitle: L("用我的覆蓋"))
                    alert.addButton(withTitle: L("取消"))
                    let response = alert.runModal()
                    answer = response == .alertFirstButtonReturn ? "load" : (response == .alertSecondButtonReturn ? "keep" : "cancel")
                }
                if answer == "load" {
                    let path = targetFile as NSString
                    let ext = path.pathExtension
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyyMMdd-HHmmss"
                    let stem = (path.lastPathComponent as NSString).deletingPathExtension
                    let name = "\(stem).我的修改-\(formatter.string(from: Date()))" + (ext.isEmpty ? "" : ".\(ext)")
                    let backup = (path.deletingLastPathComponent as NSString).appendingPathComponent(name)
                    try text.write(toFile: backup, atomically: true, encoding: .utf8)
                    if let disk = diskText {
                        loadDiskVersion(disk, path: targetFile)
                        setStatus(L("已載入新版，你的修改存在 \(backup)"))
                    } else {
                        setStatus(L("磁碟上的版本讀不出來，編輯器沒動；你的修改另存在 \(backup)"))
                    }
                    return false
                }
                guard answer == "keep" else { return false }
            }
            try text.write(toFile: targetFile, atomically: true, encoding: .utf8)
            removeRecovery(for: targetFile)
            if file == targetFile {
                diskBaseline = text; dirty = false
                js("cl.saved(\(Self.jsString(editorToken)), \(Self.jsString(text)))")
            }
            return true
        } catch {
            setStatus(L("存檔失敗：\(error.localizedDescription)"))
            return false
        }
    }

    /// 換檔案前：改過的先存（明確鎖定當下的檔案路徑，並用 isSwitchingFile 防止連續換檔重入）
    /// 讀不到編輯器的字、或存檔失敗（save 已經在狀態列寫原因）就不繼續：換檔會丟掉沒存的修改。failed＝不換時要還原什麼（例如檔案選單）
    private func saveIfDirty(failed: (() -> Void)? = nil, _ then: @escaping () -> Void) {
        guard !isSwitchingFile else { failed?(); return }
        // 還在問要不要還原時換檔：同上，編輯器唯讀＝磁碟內容，直接換；副本留著
        guard dirty, pendingRecovery == nil, let target = file else { dirty = false; return then() }
        guard ready else {
            setStatus(L("讀不到編輯器裡的內容，沒有換檔案"))
            failed?()
            return
        }
        isSwitchingFile = true
        let token = editorToken
        web.evaluateJavaScript("cl.text()") { [weak self] r, _ in
            guard let self else { return }
            self.isSwitchingFile = false
            // then()／failed() 做完（新檔已開、或留在舊檔）才放行排著的關閉，它們才看得到換檔後的 file 和 dirty
            defer { self.runAfterSwitch() }
            if self.editorToken == token, let u = Self.unpackText(r), u.path == target {
                if self.save(u.text, from: u.path, to: target) { then() } else { failed?() }
                return
            }
            self.setStatus(L("讀不到編輯器裡的內容，沒有換檔案"))
            failed?()
        }
    }

    private func runAfterSwitch() {
        let q = afterSwitch
        afterSwitch = []
        q.forEach { $0() }
    }

    // MARK: 檢查、執行

    @objc private func check() { startCheck(retrying: false) }
    private func startCheck(retrying: Bool) {
        if !runPanel.isRunning { stopWaiting() }
        withText { [weak self] text, target in self?.doCheck(text, targetFile: target, retrying: retrying) }
    }
    @objc private func run() { startRun(retrying: false) }
    private func startRun(retrying: Bool) {
        withText { [weak self] text, target in self?.doRun(text, targetFile: target, retrying: retrying) }
    }
    private func withText(_ f: @escaping (String, String) -> Void) {
        guard let expected = file, !expected.isEmpty else {
            setStatus(L("先選一個檔案或按「新檔案」"))
            return
        }
        guard ready else { return }
        let token = editorToken
        web.evaluateJavaScript("cl.text()") { [weak self] r, _ in
            guard let self, self.editorToken == token,
                  let u = Self.unpackText(r), u.path == expected, self.file == expected else { return }
            f(u.text, expected)
        }
    }

    /// 偵測是否用到 Windows 專屬相容寫法（conio.h、system("pause")／system("cls")），交作業前提醒留意學校環境
    private static func usesWindowsCompat(_ code: String, file: String) -> Bool {
        guard CodeRunner.isCpp(file) else { return false }
        if code.range(of: #"#\s*include\s*[<"]conio\.h[>"]"#, options: .regularExpression) != nil { return true }
        return code.range(of: #"system\s*\(\s*"(pause|cls)""#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 等工具偵測／引導的時候使用者可能還在打字：存檔前重新拿編輯器現在的字，不然會把按鍵當下的舊字寫回去、還把「沒存」的記號清掉
    private func freshText(_ old: String, targetFile: String, _ then: @escaping (String) -> Void) {
        guard ready else { then(old); return }
        let token = editorToken
        web.evaluateJavaScript("cl.text()") { [weak self] r, _ in
            guard let self, self.editorToken == token else { return }
            if let u = Self.unpackText(r), u.path == targetFile { then(u.text) } else { then(old) }      // performCheck／performRun 自己會擋已經換檔的
        }
    }

    private func doCheck(_ text: String, targetFile: String, retrying: Bool = false) {
        // 該檔案要用的工具還沒就緒（沒裝 Xcode 命令列工具之類）：跳引導、不往下跑
        CodeLabSetup.ensureReady(for: targetFile, from: window) { [weak self] ok in
            guard ok, let self else { return }
            self.freshText(text, targetFile: targetFile) { self.performCheck($0, targetFile: targetFile, retrying: retrying) }
        }
    }

    private func performCheck(_ text: String, targetFile: String, retrying: Bool) {
        // 等待期間使用者切到別的檔：不存檔也不檢查，避免狀態列誤報
        guard self.file == targetFile else {
            setStatus(L("已切換檔案，這次檢查取消"))
            return
        }
        guard save(text, from: targetFile, to: targetFile) else {
            if reloadedExternalChange && !retrying { startCheck(retrying: true) }
            return
        }
        if !runPanel.isRunning {
            stopWaiting()
            if showingRun { dismissRun(rerun: false) }
        }
        setStatus(L("檢查中…"))
        let compatUsed = Self.usesWindowsCompat(text, file: targetFile)
        CodeRunner.check(file: targetFile) { [weak self] status, diags, msg in
            guard let self, self.file == targetFile else { return }
            switch status {
            case .unsupported:
                self.js("cl.markers([])")
                self.problem = nil
                self.setStatus(msg)
            case .failed:
                self.sendMarkers(diags)
                self.lastInput = nil     // 檢查沒有用到輸入檔，問 AI 的訊息不要殘留上一次執行的
                let errors = diags.filter { $0.severity == "error" }.count
                let firstLine = msg.split(separator: "\n").map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? L("檢查失敗")
                if errors > 0 {
                    self.problem = (L("檢查時發現 \(errors) 個錯誤"), Self.tail(msg))
                    self.setStatus(L("\(errors) 個錯誤：") + firstLine)
                } else {
                    self.problem = (L("檢查時發現錯誤"), Self.tail(msg))
                    self.setStatus(L("檢查失敗：") + firstLine)
                }
            case .ok:
                self.sendMarkers(diags)
                self.problem = nil
                if diags.isEmpty {
                    self.setStatus(compatUsed
                        ? L("檢查完：沒有發現錯誤（提醒：程式用到了 Windows 專用寫法，交作業前請確認學校環境是否支援）")
                        : L("檢查完：沒有發現錯誤"))
                } else {
                    let firstLine = msg.split(separator: "\n").first.map(String.init) ?? ""
                    self.setStatus(L("警告：") + firstLine)
                }
            }
        }
    }

    private func doRun(_ text: String, targetFile: String, retrying: Bool = false) {
        CodeLabSetup.ensureReady(for: targetFile, from: window) { [weak self] ok in
            guard ok, let self else { return }
            self.freshText(text, targetFile: targetFile) { self.performRun($0, targetFile: targetFile, retrying: retrying) }
        }
    }

    private func performRun(_ text: String, targetFile: String, retrying: Bool) {
        // 等待期間使用者切到別的檔：不存檔也不執行，避免清掉新檔紅線或跑舊檔
        guard self.file == targetFile else {
            setStatus(L("已切換檔案，這次執行取消"))
            return
        }
        guard save(text, from: targetFile, to: targetFile) else {
            if reloadedExternalChange && !retrying { startRun(retrying: true) }
            return
        }
        if CodeRunner.isHeader(targetFile) {
            setStatus(L("這是標頭檔（.h／.hpp），不能單獨執行；請切到 .c 或 .cpp 主程式檔再按執行"))
            return
        }
        if !CodeRunner.isRunnable(targetFile) {
            setStatus(L("這是文字／輸入檔，不能執行；請切到程式檔（.cpp、.c、.py）再按執行"))
            return
        }
        js("cl.markers([])")
        problem = nil
        hasCleanRun = false
        stopWaiting()
        let input = CodeRunner.effectiveInput(for: targetFile, choice: appDefaults.string(forKey: CodeRunner.inputChoiceKey(targetFile)))
        lastInput = input
        if let input { setStatus(L("執行中…（輸入：\((input as NSString).lastPathComponent)）")) }
        else { setStatus(mode == .below ? L("執行中…（下面可以輸入）") : L("執行中…（執行畫面可以輸入）")) }
        refreshInput()
        showRun()
        runPanel.layoutSubtreeIfNeeded()   // 剛放進去還沒排版：終端機大小是 0，程式開起來的輸出會畫不出來
        runPanel.run(file: targetFile, input: input)
        updateRunButton()
        runPanel.window?.makeFirstResponder(runPanel.terminal)
    }

    // MARK: 給 AI 的上下文

    /// 送出訊息時附給 Claude 的一行；沒打開檔案就 nil
    func contextLine() -> String? {
        guard let file else { return nil }
        var s = ModelCarry.codeLabMarker + "我正在看 \(file) 第 \(cursorLine) 行"
        if !selection.isEmpty { s += "，選取了：\n```\n\(selection)\n```\n" } else { s += "。" }
        let logPath = CodeRunner.lastRunLog(for: file)
        if FileManager.default.fileExists(atPath: logPath) {
            s += "最後一次執行的畫面紀錄在 \(logPath)（需要時自己讀）。"
        }
        if dirty { s += L("（檔案還有沒存的修改）") }
        return s
    }

    // MARK: 網頁傳來的

    fileprivate func received(_ m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let type = o["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            defer { reloadingWebProcess = false }
            applyTheme(theme)
            // 上次打開的檔：還在、在這段對話的資料夾裡、且不超過編輯器大小上限才開；否則優先挑可執行的程式檔
            let dirPrefix = (directory as NSString).standardizingPath + "/"
            if let last = appDefaults.string(forKey: fileKey),
               (last as NSString).standardizingPath.hasPrefix(dirPrefix),
               Self.canAutoOpen(last) {
                open(last)
            } else if let pick = preferredInitialFile() {
                open((directory as NSString).appendingPathComponent(pick))
            } else {
                setStatus(L("按「新檔案」開始寫程式（資料夾：\(ClaudeEnvs.tilde(directory))）"))
            }
        case "changed":
            guard o["path"] as? String == file, o["token"] as? String == editorToken,
                  pendingRecovery == nil else { break }
            dirty = true
        case "recovery":
            guard o["path"] as? String == file, o["token"] as? String == editorToken,
                  let path = file, let text = o["text"] as? String else { break }
            writeRecovery(text, path: path)
        case "recoveryTooLarge":
            guard o["path"] as? String == file, o["token"] as? String == editorToken else { break }
            setStatus(L("內容超過 2 MB，暫停復原備份；請手動存檔"))
        case "recoveryChoice":
            guard o["path"] as? String == file, o["token"] as? String == editorToken,
                  let restore = o["restore"] as? Bool else { break }
            chooseRecovery(restore: restore)
        case "cursor":
            cursorLine = o["line"] as? Int ?? cursorLine
            selection = o["selection"] as? String ?? ""
        case "save":
            // 訊息帶著發出它的檔案：切檔之後才送到的舊訊息，不能存進現在選的檔
            guard let sent = o["path"] as? String, !sent.isEmpty else { setStatus(L("先選一個檔案或按「新檔案」")); break }
            guard sent == file, o["token"] as? String == editorToken else { break }
            if let t = o["text"] as? String, save(t, from: sent, to: sent) { setStatus(L("已存檔")) }
        case "check":
            guard let sent = o["path"] as? String, !sent.isEmpty else { setStatus(L("先選一個檔案或按「新檔案」")); break }
            guard sent == file, o["token"] as? String == editorToken else { break }
            if let t = o["text"] as? String { doCheck(t, targetFile: sent) }
        case "run":
            guard let sent = o["path"] as? String, !sent.isEmpty else { setStatus(L("先選一個檔案或按「新檔案」")); break }
            guard sent == file, o["token"] as? String == editorToken else { break }
            if let t = o["text"] as? String { doRun(t, targetFile: sent) }
        case "log": NSLog("codelab: \(o["text"] ?? "")")
        default: break
        }
    }

    private func setStatus(_ s: String) { status.stringValue = s; status.toolTip = s; onStatus?(s) }
    var onStatus: ((String) -> Void)?

    /// main.swift 的隔離測試：不需要聊天室／視窗，也不設焦點。edit 走真正的 Monaco change＋2 秒防抖。
    func recoveryProbe(path: String, action: String, attempt: Int = 0, done: @escaping (String) -> Void) {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        guard ready else {
            guard attempt < 100 else { done("error=editor not ready\n"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.recoveryProbe(path: path, action: action, attempt: attempt + 1, done: done)
            }
            return
        }
        open(path)
        js("cl.text()") { [weak self] value in
            guard let self else { return }
            guard self.file == path, Self.unpackText(value)?.path == path else {
                done("error=open failed\n"); return
            }
            switch action {
            case "edit":
                guard self.pendingRecovery == nil else {
                    self.dumpRecoveryProbe(path: path, done: done); return
                }
                let text = (Self.unpackText(value)?.text ?? "") + "\n// CodeLab recovery probe：未存的修改\n"
                self.js("monaco.editor.getEditors()[0].getModel().setValue(\(Self.jsString(text)))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.dumpRecoveryProbe(path: path, done: done)
                }
            case "restore", "discard":
                self.chooseRecovery(restore: action == "restore")
                self.dumpRecoveryProbe(path: path, done: done)
            case "save":
                // 模擬先還原再正常存檔；外部修改仍走原來的衝突檢查。
                self.chooseRecovery(restore: true)
                self.withText { [weak self] text, target in
                    guard let self else { return }
                    let previous = self.interactiveSave
                    self.interactiveSave = false // 無視窗測試遇到衝突只回報，不能跳出 modal 搶焦點
                    defer { self.interactiveSave = previous }
                    _ = self.save(text, from: target, to: target)
                    self.dumpRecoveryProbe(path: path, done: done)
                }
            case "close":
                // 模擬關格子（非互動）：回報能不能關，副本要留著
                self.saveForClose(interactive: false) { [weak self] ok in
                    self?.dumpRecoveryProbe(path: path) { done("closeAllowed=\(ok)\n" + $0) }
                }
            default:
                self.dumpRecoveryProbe(path: path, done: done)
            }
        }
    }

    private func dumpRecoveryProbe(path: String, done: @escaping (String) -> Void) {
        js("cl.text()") { [weak self] value in
            guard let self else { return }
            let url = Self.recoveryURL(for: path)
            let copy = (try? String(contentsOf: url, encoding: .utf8)) ?? "(no recovery copy)"
            let editor = Self.unpackText(value)?.text ?? "(unavailable)"
            done("path=\(url.path)\ndirty=\(self.dirty) pendingRecovery=\(self.pendingRecovery != nil)\nstatus=\(self.status.stringValue)\n--recovery--\n\(copy)\n--editor--\n\(editor)\n")
        }
    }

    /// 測試用（main.swift 的 --codelab）：按檢查／執行，等狀態列有結果再回報；context＝給 Claude 的那行
    func testAction(_ act: String, _ done: @escaping (String) -> Void) {
        switch act {
        case "dirty": dirty = true; done("dirty")
        case "edit":   // 改編輯器內容（跟打字一樣會回報「改過了」）
            js("monaco.editor.getEditors()[0].getModel().setValue('int main(){ return 7; }\\n')")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in done("dirty=\(self?.dirty == true)") }
        case _ where act.hasPrefix("open="):   // 測試：直接開某個檔（open=/絕對路徑），回報開完後的 file 和狀態列
            open(String(act.dropFirst(5)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in done("file=\(self?.file ?? "nil") dirty=\(self?.dirty == true) status=\(self?.status.stringValue ?? "")") }
        case _ where act.hasPrefix("input="):   // 測試：選輸入檔（input=typing／auto／絕對路徑）
            setInputChoice(act.dropFirst(6) == "auto" ? nil : String(act.dropFirst(6)))
            done("choice=\(file.flatMap { appDefaults.string(forKey: CodeRunner.inputChoiceKey($0)) } ?? "nil") menu=\(inputPopup.itemTitles) button=\(inputPopup.title)")
        case "ask":     // 測試：按「問 AI」，回報組出來的訊息和按鈕狀態
            let m = askMessage()
            askAI()
            let draft = ((superview as? ChatPane)?.inputBar.textView.string) ?? "（沒有 ChatPane）"
            done("button=\(askButton.isHidden ? "隱藏" : "顯示") status=\(status.stringValue)\n--msg--\n\(m ?? "nil")\n--draft-same=\(draft == m)")
        case _ where act.hasPrefix("snap="):   // 測試：把學習區暫時調成某個寬度拍成圖（snap=寬度|圖檔），回報工具列收到第幾級
            let arg = act.dropFirst(5).split(separator: "|", maxSplits: 1).map(String.init)
            let w = CGFloat(Double(arg.first ?? "") ?? 800)
            let snapOut = arg.count > 1 ? arg[1] : snapPath
            let saved = frame
            frame.size.width = w
            layoutSubtreeIfNeeded()
            let level = barLevel
            // 等一下讓畫面真的重畫（不然離螢幕渲染會拿到沒更新的按鈕圖）。背景是透明的：墊深色背景，用 layer 渲染
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.wantsLayer = true
                let oldBG = self.layer?.backgroundColor
                self.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
                for v in self.bar.subviews { v.needsDisplay = true }
                self.needsDisplay = true
                self.displayIfNeeded()
                CATransaction.flush()
                let sc2 = 2
                if let ctx = CGContext(data: nil, width: Int(self.bounds.width) * sc2, height: Int(self.bounds.height) * sc2, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let l = self.layer {
                    ctx.scaleBy(x: CGFloat(sc2), y: CGFloat(sc2))
                    l.render(in: ctx)
                    if let img = ctx.makeImage() {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapOut))
                    }
                }
                self.layer?.backgroundColor = oldBG
                self.frame = saved
                self.needsLayout = true
                done("titles=\([self.newButton, self.checkButton, self.runButton, self.askButton].map { $0.title }) width=\(Int(w)) level=\(level) status=\(self.status.stringValue) askShown=\(!self.askButton.isHidden)")
            }
        // ── 測試專用（codenv_2 加的）：編輯器內容、紅線、按鈕狀態、停止、起手式模板 ──
        case _ where act.hasPrefix("js="):     // 在編輯器網頁跑一段 JS，回報結果（例如 js=JSON.stringify(monaco.editor.getModelMarkers({}).map(m=>[m.startLineNumber,m.message])) ）
            js(String(act.dropFirst(3))) { r in done("js→ \(r.map { "\($0)" } ?? "nil")") }
        case _ where act.hasPrefix("settext="):   // 把編輯器內容換成某個文字檔的內容（跟打字一樣會回報「改過了」）；檔案路徑給絕對路徑
            let t = (try? String(contentsOfFile: String(act.dropFirst(8)), encoding: .utf8)) ?? ""
            js("monaco.editor.getEditors()[0].getModel().setValue(\(Self.jsString(t)))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in done("dirty=\(self?.dirty == true)") }
        case "ui":
            done("執行鈕=\(runButton.title)/\(runPanel.isRunning ? "跑中" : "沒在跑") 問AI=\(askButton.isHidden ? "隱藏" : "顯示") 返回程式碼=\(backButton.isHidden ? "隱藏" : "顯示") dirty=\(dirty) 檔案選單=\(filePopup.titleOfSelectedItem ?? "nil") file=\(file ?? "nil") status=\(status.stringValue)")
        case "stop": stopRun(); done("已按停止 running=\(runPanel.isRunning)")
        case "menu":   // 假裝點開檔案選單（觸發重新掃描），回報選單項目
            if let m = filePopup.menu { menuNeedsUpdate(m) }
            done("檔案選單項目=\(filePopup.itemTitles)")
        case _ where act.hasPrefix("starter="): done("模板(\(act.dropFirst(8)))：\(Self.starterTemplate(for: String(act.dropFirst(8))).prefix(60).replacingOccurrences(of: "\n", with: "⏎"))")
        case "context": done("file=\(file ?? "nil") ready=\(ready)\n" + (contextLine() ?? "nil"))
        case "check":
            onStatus = { s in if !s.hasSuffix("…") { done(L("狀態：") + s) } }
            check()
        case "run":
            onRunFinished = { [weak self] code in
                self?.onRunFinished = nil
                let ran = self?.runPanel.currentFile ?? self?.file
                let log = ran.flatMap { Self.readLogTail(CodeRunner.lastRunLog(for: $0)) } ?? L("（沒有紀錄）")
                done(L("代碼 \(code)\n") + log)
            }
            run()
        case "mode1", "mode2", "mode3", "mode4":
            setMode(Mode(rawValue: Int(act.dropFirst(4))!)!)
            done("mode=\(mode.rawValue)")
        case _ where act.hasPrefix("edkey="):   // 測試：聊天室有灰字建議、游標在編輯器時按 Tab 或 /，回報焦點和輸入框有沒有被搶
            guard let w = window, let c = sequence(first: superview, next: { $0?.superview }).compactMap({ $0 as? ChatPane }).first else { done("找不到聊天室"); return }
            c.inputBar.textView.string = ""
            c.inputBar.suggestion = "灰字建議"
            if act == "edkey=chat" {   // 對照組：焦點在聊天內容上，Tab 仍要採用建議
                func webs(_ v: NSView) -> [WKWebView] { v === self ? [] : (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(webs) }
                if let chat = webs(c).first { w.makeFirstResponder(chat) }
            } else {
                w.makeFirstResponder(web)
                js("cl.focus()")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                let tab = act != "edkey=slash"
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                            context: nil, characters: tab ? "\t" : "/", charactersIgnoringModifiers: tab ? "\t" : "/", isARepeat: false, keyCode: tab ? 48 : 44) { NSApp.sendEvent(e) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let inEditor = (w.firstResponder as? NSView).map { $0 === self?.web || $0.isDescendant(of: self?.web ?? $0) && self?.web != nil } ?? false
                    let head = "焦點在編輯器=\(inEditor) 焦點=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") 輸入框=[\(c.inputBar.textView.string)]"
                    self?.js("monaco.editor.getEditors()[0].getValue().length") { r in done(head + " 編輯器字數=\(r.map { "\($0)" } ?? "nil")") }
                }
            }
        case "key", "cmdc":
            // 在執行結果上按一個鍵（a，或 ⌘ C），走跟真的按鍵一樣的 sendEvent（監聽器看得到）
            let w = runWindow?.isVisible == true ? runWindow : window
            let cmd = act == "cmdc"
            if let w, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: cmd ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: cmd ? "c" : "a", charactersIgnoringModifiers: cmd ? "c" : "a", isARepeat: false, keyCode: cmd ? 8 : 0) {
                NSApp.sendEvent(e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.testAction("state", done) }
        case "state":
            let fr = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            js("monaco.editor.getModelMarkers({}).length") { [weak self] r in
                guard let self else { return }
                done("mode=\(self.mode.rawValue) split=\(self.split.isVertical ? "左右" : "上下")×\(self.split.arrangedSubviews.count) showingRun=\(self.showingRun) runWindow=\(self.runWindow?.isVisible == true) waiting=\(self.keyMonitor != nil) focus=\(fr) markers=\(r ?? "?") lab=\(Int(self.frame.width))x\(Int(self.frame.height)) term=\(Int(self.runPanel.terminal.frame.width))x\(Int(self.runPanel.terminal.frame.height)) text=\(self.runPanel.terminal.withTerminalPublic { t in (0..<min(t.rows, 5)).map { r in (0..<min(t.cols, 40)).compactMap { t.getText(col: $0, row: r) }.joined().trimmingCharacters(in: .whitespaces) }.joined(separator: "⏎") }) chatHidden=\(self.superview?.subviews.first { $0 is WKWebView }?.isHidden ?? false) status=\(self.status.stringValue)")
            }
        default: done(L("不認得 \(act)"))
        }
    }
    private func js(_ s: String) { web.evaluateJavaScript(s, completionHandler: nil) }
    private func js(_ s: String, _ done: @escaping (Any?) -> Void) { web.evaluateJavaScript(s) { r, _ in done(r) } }
    private static func jsString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }
}

/// 聊天跟程式碼區中間那條：可以左右拖
final class CodeLabDivider: NSView {
    var onDrag: ((CGFloat) -> Void)?   // 視窗座標的 x
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
    override func mouseDragged(with e: NSEvent) { onDrag?(e.locationInWindow.x) }
}
