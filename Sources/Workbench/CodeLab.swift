import AppKit
import Combine
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
        guard !appDefaults.bool(forKey: key) else { return }
        appDefaults.set(true, forKey: key)
        guard !groups.isEmpty, !groups.contains(where: { $0.name == Store.codeLabGroupName }) else { return }
        addGroup(named: Store.codeLabGroupName)
    }
}

extension MainWindowController {
    /// 練習的程式固定放這裡（使用者 10/24 要的：不用每次選資料夾）
    static let codeLabFolder = Edition.practiceFolder.path

    /// 「新的練習」：在程式碼學習專區開新聊天室，程式放 codeLabFolder（草稿：一句都沒聊就自動刪）
    func newCodeLabConversation() {
        if !store.groups.contains(where: { $0.name == Store.codeLabGroupName }) { store.addGroup(named: Store.codeLabGroupName) }
        guard let g = store.groups.first(where: { $0.name == Store.codeLabGroupName }) else { return }
        let path = Self.codeLabFolder
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let pid = store.projects.first(where: { $0.path == path })?.id ?? store.addProject(path: path).id
        let c = store.createConversation(in: pid, draft: true)
        store.move(c.id, toGroup: g.id)
        store.rename(c.id, to: "練習", byUser: false)
        store.show(c.id)
    }
}

private final class CodeLabHandler: NSObject, WKScriptMessageHandler {
    weak var target: CodeLabView?
    init(_ t: CodeLabView) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.received(m) }
}

final class CodeLabView: NSView, WKNavigationDelegate, NSSplitViewDelegate, NSWindowDelegate {
    enum Mode: Int, CaseIterable {
        case below = 1, swap, popup, noAI
        var title: String { ["上下分", "F10 換畫面", "F10 開視窗", "不用 AI"][rawValue - 1] }
        var detail: String {
            ["左邊 AI，右上程式碼、右下執行結果",
             "左邊 AI，右邊程式碼；F10 整塊換成執行畫面，跑完按任意鍵回來",
             "左邊 AI，右邊程式碼；F10 跳出執行視窗，跑完按任意鍵關掉",
             "不用 AI：左邊程式碼、右邊執行結果"][rawValue - 1]
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
    private let modePopup = NSPopUpButton()
    private let status = NSTextField(labelWithString: "")
    private(set) var file: String?
    private var ready = false
    private var cursorLine = 1
    private var selection = ""
    private var dirty = false
    /// 關掉格子時：程式還在跑就不收（收掉會殺程式）；有沒存的修改先存再收（saveForClose）
    var isProgramRunning: Bool { runPanel.isRunning }
    var hasUnsaved: Bool { dirty }

    /// 關掉格子、要收掉之前：改過的先存。done(true)＝沒改過或存好了，可以收；done(false)＝存不了（唯讀檔、編輯器還沒好），留著
    func saveForClose(_ done: @escaping (Bool) -> Void) {
        guard dirty else { return done(true) }
        guard ready else { return done(false) }
        web.evaluateJavaScript("cl.text()") { [weak self] r, _ in
            guard let self, let t = r as? String else { return done(false) }
            done(self.save(t))
        }
    }
    private var splitPlaced = false
    private var theme: Theme
    private(set) var mode: Mode
    /// 版面換了（不用 AI 的版面要 ChatPane 把聊天收起來）
    var onModeChange: (() -> Void)?
    private var showingRun = false      // F10 換畫面：執行畫面正蓋在程式碼上
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

        // 工具列：檔案、新檔案、檢查、執行、狀態
        filePopup.bezelStyle = .inline
        filePopup.controlSize = .small
        filePopup.target = self
        filePopup.action = #selector(pickFile)
        for (b, title, sym, sel, tip) in [(newButton, "新檔案", "doc.badge.plus", #selector(newFile), "在這個資料夾開一個新檔案"),
                                          (checkButton, "檢查", "checkmark.circle", #selector(check), "存檔並檢查有沒有打錯（F9）"),
                                          (runButton, "執行", "play.fill", #selector(run), "存檔、編譯並執行，結果在下面（F10）")] {
            b.title = title
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            b.bezelStyle = .inline
            b.controlSize = .small
            b.target = self
            b.action = sel
            b.toolTip = tip
            bar.addSubview(b)
        }
        bar.addSubview(filePopup)
        modePopup.bezelStyle = .inline
        modePopup.controlSize = .small
        for m in Mode.allCases { modePopup.addItem(withTitle: m.title); modePopup.lastItem?.toolTip = m.detail }
        modePopup.target = self
        modePopup.action = #selector(pickMode)
        modePopup.toolTip = "版面（預設在 ⌘ , 的「對話」頁改）"
        bar.addSubview(modePopup)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        bar.addSubview(status)
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
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        runWindow?.orderOut(nil)
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
        w.title = "執行：" + ((file as NSString?)?.lastPathComponent ?? "")
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
        if runPanel.isRunning { runPanel.stop() }
        dismissRun(rerun: false)
        return false
    }

    // MARK: 執行完等任意鍵

    private func finished(_ code: Int32) {
        setStatus(code == 0 ? "執行完（代碼 0）" : "執行結束（代碼 \(code)）")
        if code != 0 { markCompileErrors() }
        if mode == .swap || mode == .popup {
            runPanel.terminal.feed(text: "\r\n\u{1b}[2m按任意鍵回到程式碼（⌘ C 可以先複製）\u{1b}[0m")
        }
        runPanel.terminal.needsDisplay = true   // 搬過家的終端機（換畫面、開視窗）不一定自己重畫
        waitForKey()
        onRunFinished?(code)
    }

    /// 編譯失敗（或 Python 語法錯）：跟 F9 一樣在程式碼上畫紅線
    private func markCompileErrors() {
        guard let file else { return }
        CodeRunner.check(file: file) { [weak self] diags, msg in
            guard let self, self.file == file, !diags.isEmpty else { return }
            let list = diags.map { ["line": $0.line, "column": $0.column, "severity": $0.severity, "message": $0.message] as [String: Any] }
            if let d = try? JSONSerialization.data(withJSONObject: list), let s = String(data: d, encoding: .utf8) { self.js("cl.markers(\(s))") }
            let errors = diags.filter { $0.severity == "error" }.count
            if errors > 0 { self.setStatus("編譯失敗：\(errors) 個錯誤（程式碼上畫了紅線）" + (msg.split(separator: "\n").first.map { "：" + $0 } ?? "")) }
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

    /// 收起執行畫面（換畫面、開視窗的版面），游標回到程式碼
    private func dismissRun(rerun: Bool) {
        stopWaiting()
        if showingRun { showingRun = false; runPanel.removeFromSuperview() }
        closeRunWindow(focus: true)
        window?.makeFirstResponder(web)
        js("cl.focus()")
        if rerun { run() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h: CGFloat = 30
        bar.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        var x: CGFloat = 8
        let fw = min(220, max(120, bounds.width * 0.3))
        filePopup.frame = NSRect(x: x, y: 4, width: fw, height: 22); x += fw + 6
        for b in [newButton, checkButton, runButton, modePopup] {
            let w = b.intrinsicContentSize.width + 8
            b.frame = NSRect(x: x, y: 4, width: w, height: 22); x += w + 4
        }
        status.frame = NSRect(x: x + 6, y: 7, width: max(0, bounds.width - x - 14), height: 16)
        split.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - h))
        if showingRun { runPanel.frame = split.frame }
        // 第一次有夠大的空間才放分隔線（上下分：上 62% 程式碼；不用 AI：左右各半）；之後照使用者拖的
        let total = split.isVertical ? split.frame.width : split.frame.height
        if !splitPlaced, split.arrangedSubviews.count == 2, total > 200 {
            splitPlaced = true
            split.adjustSubviews()
            split.setPosition((total * (split.isVertical ? 0.5 : 0.62)).rounded(), ofDividerAt: 0)
        }
    }

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

    private func reloadFiles() {
        filePopup.removeAllItems()
        let files = sourceFiles()
        if files.isEmpty { filePopup.addItem(withTitle: "（還沒有程式檔，按「新檔案」）"); filePopup.lastItem?.isEnabled = false }
        for f in files { filePopup.addItem(withTitle: f) }
        let dirPrefix = (directory as NSString).standardizingPath + "/"
        if let cur = file.map({ ($0 as NSString).standardizingPath }).map({ $0.hasPrefix(dirPrefix) ? String($0.dropFirst(dirPrefix.count)) : ($0 as NSString).lastPathComponent }),
           files.contains(cur) { filePopup.selectItem(withTitle: cur) }
    }

    @objc private func pickFile() {
        guard let name = filePopup.titleOfSelectedItem, sourceFiles().contains(name) else { return }
        saveIfDirty { [weak self] in self?.open((self?.directory as NSString?)?.appendingPathComponent(name) ?? name) }
    }

    @objc private func newFile() {
        let a = NSAlert()
        a.messageText = "新檔案"
        a.informativeText = "檔名（例如 hw1.cpp、test.py、c++/hw2.cpp；沒寫副檔名就是 .cpp）"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = tf
        a.addButton(withTitle: "建立")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var name = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), name.split(separator: "/").count <= 2 else { return }
        if (name as NSString).pathExtension.isEmpty { name += ".cpp" }
        let path = (directory as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            let starter = name.hasSuffix(".py") ? "" : "#include <bits/stdc++.h>\nusing namespace std;\n\nint main() {\n    \n    return 0;\n}\n"
            try? starter.write(toFile: path, atomically: true, encoding: .utf8)
        }
        saveIfDirty { [weak self] in self?.open(path); self?.reloadFiles() }
    }

    /// 打開檔案：UTF-8 讀不懂就當 Big5（老師給的 Windows 檔），存檔時轉成 UTF-8
    func open(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { setStatus("打不開 \(path)"); return }
        var text = String(data: data, encoding: .utf8)
        var note = ""
        if text == nil {
            let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue)))
            text = String(data: data, encoding: big5)
            if text != nil { note = "這個檔案的中文是 Windows 的 Big5 編碼，存檔時會轉成 UTF-8"; dirty = true }
        }
        file = path
        appDefaults.set(path, forKey: fileKey)
        if note.isEmpty { dirty = false }
        let ext = (path as NSString).pathExtension.lowercased()
        let lang = ext == "py" ? "python" : (["cpp", "cc", "cxx", "c", "h", "hpp"].contains(ext) ? "cpp" : "plaintext")
        js("cl.open(\(Self.jsString(path)), \(Self.jsString(text ?? "")), \(Self.jsString(lang)))")
        cursorLine = 1; selection = ""
        reloadFiles()
        setStatus(note.isEmpty ? (path as NSString).lastPathComponent : note)
    }

    private func save(_ text: String) -> Bool {
        guard let file else { setStatus("先選一個檔案或按「新檔案」"); return false }
        do {
            try text.write(toFile: file, atomically: true, encoding: .utf8)
            dirty = false
            return true
        } catch {
            setStatus("存檔失敗：\(error.localizedDescription)")
            return false
        }
    }

    /// 換檔案前：改過的先存
    private func saveIfDirty(_ then: @escaping () -> Void) {
        guard dirty, ready else { return then() }
        web.evaluateJavaScript("cl.text()") { [weak self] r, _ in
            if let t = r as? String { _ = self?.save(t) }
            then()
        }
    }

    // MARK: 檢查、執行

    @objc private func check() { withText { [weak self] t in self?.doCheck(t) } }
    @objc private func run() { withText { [weak self] t in self?.doRun(t) } }
    private func withText(_ f: @escaping (String) -> Void) {
        guard ready else { return }
        web.evaluateJavaScript("cl.text()") { r, _ in if let t = r as? String { f(t) } }
    }

    private func doCheck(_ text: String) {
        guard save(text), let file else { return }
        setStatus("檢查中…")
        CodeRunner.check(file: file) { [weak self] diags, msg in
            guard let self, self.file == file else { return }
            let list = diags.map { ["line": $0.line, "column": $0.column, "severity": $0.severity, "message": $0.message] as [String: Any] }
            if let d = try? JSONSerialization.data(withJSONObject: list), let s = String(data: d, encoding: .utf8) { self.js("cl.markers(\(s))") }
            let errors = diags.filter { $0.severity == "error" }.count
            let firstLine = msg.split(separator: "\n").first.map(String.init) ?? ""
            self.setStatus(diags.isEmpty ? "檢查完：沒有發現錯誤" : (errors > 0 ? "\(errors) 個錯誤：" : "警告：") + firstLine)
        }
    }

    private func doRun(_ text: String) {
        guard save(text), let file else { return }
        js("cl.markers([])")
        stopWaiting()
        setStatus(mode == .below ? "執行中…（下面可以輸入）" : "執行中…（執行畫面可以輸入）")
        showRun()
        runPanel.layoutSubtreeIfNeeded()   // 剛放進去還沒排版：終端機大小是 0，程式開起來的輸出會畫不出來
        runPanel.run(file: file)
        runPanel.window?.makeFirstResponder(runPanel.terminal)
    }

    // MARK: 給 AI 的上下文

    /// 送出訊息時附給 Claude 的一行；沒打開檔案就 nil
    func contextLine() -> String? {
        guard let file else { return nil }
        var s = ModelCarry.codeLabMarker + "我正在看 \(file) 第 \(cursorLine) 行"
        if !selection.isEmpty { s += "，選取了：\n```\n\(selection)\n```\n" } else { s += "。" }
        s += "最後一次執行的畫面紀錄在 \(CodeRunner.lastRunLog(for: file))（需要時自己讀）。"
        if dirty { s += "（檔案還有沒存的修改）" }
        return s
    }

    // MARK: 網頁傳來的

    fileprivate func received(_ m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let type = o["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            applyTheme(theme)
            // 上次打開的檔：還在、而且在這段對話的資料夾裡才開
            let dirPrefix = (directory as NSString).standardizingPath + "/"
            if let last = appDefaults.string(forKey: fileKey), FileManager.default.fileExists(atPath: last),
               (last as NSString).standardizingPath.hasPrefix(dirPrefix) { open(last) }
            else if let first = sourceFiles().first { open((directory as NSString).appendingPathComponent(first)) }
            else { setStatus("按「新檔案」開始寫程式（資料夾：\(ClaudeEnvs.tilde(directory))）") }
        case "changed": dirty = true
        case "cursor":
            cursorLine = o["line"] as? Int ?? cursorLine
            selection = o["selection"] as? String ?? ""
        case "save": if let t = o["text"] as? String, save(t) { setStatus("已存檔") }
        case "check": if let t = o["text"] as? String { doCheck(t) }
        case "run": if let t = o["text"] as? String { doRun(t) }
        case "log": NSLog("codelab: \(o["text"] ?? "")")
        default: break
        }
    }

    private func setStatus(_ s: String) { status.stringValue = s; status.toolTip = s; onStatus?(s) }
    var onStatus: ((String) -> Void)?

    /// 測試用（main.swift 的 --codelab）：按檢查／執行，等狀態列有結果再回報；context＝給 Claude 的那行
    func testAction(_ act: String, _ done: @escaping (String) -> Void) {
        switch act {
        case "dirty": dirty = true; done("dirty")
        case "edit":   // 改編輯器內容（跟打字一樣會回報「改過了」）
            js("monaco.editor.getEditors()[0].getModel().setValue('int main(){ return 7; }\\n')")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in done("dirty=\(self?.dirty == true)") }
        case "context": done("file=\(file ?? "nil") ready=\(ready)\n" + (contextLine() ?? "nil"))
        case "check":
            onStatus = { s in if !s.hasSuffix("…") { done("狀態：" + s) } }
            check()
        case "run":
            onRunFinished = { [weak self] code in
                self?.onRunFinished = nil
                let log = (try? String(contentsOfFile: CodeRunner.lastRunLog(for: self?.file ?? ""), encoding: .utf8)) ?? "（沒有紀錄）"
                done("代碼 \(code)\n" + log)
            }
            run()
        case "mode1", "mode2", "mode3", "mode4":
            setMode(Mode(rawValue: Int(act.dropFirst(4))!)!)
            done("mode=\(mode.rawValue)")
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
        default: done("不認得 \(act)")
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
