import AppKit
import SwiftTerm

/// 一格終端機：SwiftTerm 負責跑程式、輸入、輸入法；往上捲時改用平滑捲動閱讀層
final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    let terminal: LocalProcessTerminalView
    let scrollback: SmoothScrollback
    var theme: Theme
    private var monitors: [Any] = []
    private var refreshTimer: Timer?
    private var ignoreMomentumUntil: TimeInterval = 0
    var onExit: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?
    private var shelf: ImageShelfOverlay?
    /// 右下角讓給桌寵的空間：終端機整塊往上讓（字不會被蓋住）
    var petReserve: NSSize = .zero { didSet { if petReserve != oldValue { layoutContent() } } }
    private var shelfTimer: Timer?

    init(theme: Theme) {
        self.theme = theme
        terminal = LocalProcessTerminalView(frame: .zero)
        let pal = theme.dark
        scrollback = SmoothScrollback(palette: pal, font: theme.font, boldFont: theme.boldFont)
        super.init(frame: .zero)
        terminal.processDelegate = self
        terminal.optionAsMetaKey = false   // 跟 iTerm 設定一樣（Option 打特殊字元，不當 Meta）
        scrollback.isHidden = true
        addSubview(terminal)
        addSubview(scrollback)
        scrollback.onReachBottom = { [weak self] in self?.hideScrollback() }
        registerForDraggedTypes(Self.dropTypes)
        applyTheme()

        // 滾輪事件先經過這裡：往上捲（看舊的）就交給平滑捲動層，SwiftTerm 本身那種一行一行的捲動不用
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self else { return e }
            return self.handleScroll(e) ? nil : e
        } as Any)
        // 打字就回到終端機
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if let self, self.window?.firstResponder === self.terminal, !self.scrollback.isHidden { self.hideScrollback() }
            return e
        } as Any)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        monitors.forEach { NSEvent.removeMonitor($0) }
        shelfTimer?.invalidate()
        refreshTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    /// 這格跑的是哪段 Claude 對話：用來找 image-shelf 的圖片架
    func attachImageShelf(claudeSession: UUID) {
        let o = ImageShelfOverlay(claudeSession: claudeSession)
        o.background = theme.palette(for: effectiveAppearance).bg
        addSubview(o, positioned: .below, relativeTo: scrollback)
        shelf = o
        shelfTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let o = self.shelf, self.window != nil else { return }
            o.update(terminal: self.terminal, hidden: !self.scrollback.isHidden)
        }
    }

    /// 留一點邊，字不要貼著視窗邊緣
    private func layoutContent() {
        let bottom = 4 + petReserve.height
        let r = NSRect(x: 10, y: bottom, width: max(0, bounds.width - 16), height: max(0, bounds.height - bottom - 4))
        if terminal.frame != r { terminal.frame = r }
        if scrollback.frame != r { scrollback.frame = r }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let pal = theme.palette(for: effectiveAppearance)
        terminal.font = theme.font
        terminal.lineSpacing = theme.lineSpacing
        terminal.nativeForegroundColor = pal.fg
        terminal.nativeBackgroundColor = pal.bg
        terminal.caretColor = pal.cursor
        terminal.selectedTextBackgroundColor = pal.selection
        terminal.installColors(pal.ansi.map(\.terminalColor))
        scrollback.document.palette = pal
        scrollback.document.font = theme.font
        scrollback.document.boldFont = theme.boldFont
        scrollback.backgroundColor = pal.bg
        wantsLayer = true
        layer?.backgroundColor = pal.bg.cgColor
        scrollback.document.needsDisplay = true
        shelf?.background = pal.bg
    }

    func start(executable: String, args: [String], directory: String?, environment: [String]? = nil) {
        var env = environment ?? Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("COLORTERM=truecolor")
        terminal.startProcess(executable: executable, args: args, environment: env, execName: nil, currentDirectory: directory)
    }

    /// 關掉這格：結束裡面的程式
    func terminate() {
        shelfTimer?.invalidate()
        refreshTimer?.invalidate()
        terminal.terminate()
    }

    // MARK: 捲動

    private func handleScroll(_ e: NSEvent) -> Bool {
        guard let window, e.window === window, !isHidden else { return false }
        let p = convert(e.locationInWindow, from: nil)
        guard bounds.contains(p) else { return false }
        // 閱讀層開著：交給它自己（原生捲動）
        if !scrollback.isHidden { return false }
        // 剛捲回最底下收起閱讀層：剩下的慣性不要讓終端機再捲
        if !e.momentumPhase.isEmpty && Date().timeIntervalSince1970 < ignoreMomentumUntil { return true }
        guard e.scrollingDeltaY > 0 else { return false }   // 往下捲：已經在最底下，交給終端機（沒事）
        var local = false, hasHistory = false
        terminal.withTerminalPublic { t in
            local = t.mouseMode == .off && !t.isCurrentBufferAlternate
            hasHistory = t.buffer.yDisp > 0
        }
        // 程式自己要滑鼠（例如開了滑鼠回報），或在全螢幕程式裡（vim 之類）：照 SwiftTerm 原本的做法
        guard local, hasHistory else { return false }
        showScrollback()
        scrollback.scrollWheel(with: e)
        return true
    }

    func showScrollback() {
        scrollback.begin(from: terminal, palette: theme.palette(for: effectiveAppearance))
        scrollback.isHidden = false
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.scrollback.refresh() }
    }

    func hideScrollback() {
        guard !scrollback.isHidden else { return }
        scrollback.isHidden = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        ignoreMomentumUntil = Date().timeIntervalSince1970 + 0.4
        window?.makeFirstResponder(terminal)
    }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { onTitle?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        shelfTimer?.invalidate()
        refreshTimer?.invalidate()
        onExit?(exitCode)
    }
}
