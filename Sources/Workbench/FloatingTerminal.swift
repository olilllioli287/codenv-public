import AppKit

/// 掛在主視窗上的工具面板：可以拿鍵盤焦點，但不成為主視窗，也不加入視窗循環。
private final class FloatingTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FloatingTerminalContent: NSView {
    let tabScroll = NSScrollView()
    let tabStrip = NSView()
    let addButton = NSButton()
    let terminals = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        tabScroll.documentView = tabStrip
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.scrollerStyle = .overlay
        addSubview(tabScroll)
        addSubview(addButton)
        addSubview(terminals)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h: CGFloat = 36
        tabScroll.frame = NSRect(x: 4, y: bounds.height - h, width: max(0, bounds.width - 40), height: h)
        addButton.frame = NSRect(x: bounds.width - 32, y: bounds.height - 32, width: 28, height: 28)
        tabStrip.frame = NSRect(x: 0, y: 0, width: max(tabScroll.contentSize.width, CGFloat(tabStrip.subviews.count) * 170), height: h)
        for (i, tab) in tabStrip.subviews.enumerated() {
            tab.frame = NSRect(x: CGFloat(i) * 170, y: 6, width: 166, height: 24)
        }
        terminals.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - h))
    }
}

/// 收起只改顯示狀態；分頁與 PTY 的生命週期由這個控制器持有，到關分頁或 App 結束才終止。
final class FloatingTerminalController: NSObject, NSWindowDelegate {
    private final class Tab {
        let id = UUID()
        let directory: String
        let pane: TerminalPane
        var title: String
        init(directory: String, pane: TerminalPane, title: String) {
            self.directory = directory
            self.pane = pane
            self.title = title
        }
    }

    private weak var parent: NSWindow?
    private let store: Store
    private let workspace: Workspace
    private let panel: FloatingTerminalPanel
    private let content = FloatingTerminalContent()
    private let maximizeButton = NSButton()
    private var tabs: [Tab] = []
    private var selected: UUID?
    private var nextNumber = 1
    private weak var returnChat: ChatPane?
    private weak var returnResponder: NSResponder?
    private var observers: [NSObjectProtocol] = []
    /// 座標相對於主視窗左下角，主視窗搬到其他螢幕後仍能還原原本的位置。
    private var normalFrame: NSRect?
    private(set) var isMaximized = false
    private var settingGeometry = false
    private var shuttingDown = false
    var onVisibilityChange: ((Bool) -> Void)?
    /// 中間聊天欄在螢幕上的範圍（預設位置照它的比例算，視窗變大小跟著走）
    var chatRect: () -> NSRect? = { nil }
    var isVisible: Bool { panel.isVisible }
    func owns(_ window: NSWindow?) -> Bool { window === panel }

    init(parent: NSWindow, store: Store, workspace: Workspace) {
        self.parent = parent
        self.store = store
        self.workspace = workspace
        panel = FloatingTerminalPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.isRestorable = false
        panel.title = L("浮動終端機")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.minSize = NSSize(width: 320, height: 200)
        panel.delegate = self
        panel.contentView = content
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 68, height: 28))
        configureButton(maximizeButton, symbol: "arrow.up.left.and.arrow.down.right", label: L("放到最大"), action: #selector(toggleMaximized))
        maximizeButton.frame = NSRect(x: 0, y: 2, width: 28, height: 24)
        accessory.view.addSubview(maximizeButton)
        let hideButton = NSButton()
        configureButton(hideButton, symbol: "chevron.down", label: L("收起浮動終端機"), action: #selector(hideFromButton))
        hideButton.frame = NSRect(x: 32, y: 2, width: 28, height: 24)
        accessory.view.addSubview(hideButton)
        panel.addTitlebarAccessoryViewController(accessory)
        configureButton(content.addButton, symbol: "plus", label: L("新增終端機分頁"), action: #selector(addFromButton))

        if let saved = appDefaults.string(forKey: "floatingTerminal.normalFrame") {
            let r = NSRectFromString(saved)
            if [r.minX, r.minY, r.width, r.height].allSatisfy({ $0.isFinite }), r.width >= 320, r.height >= 200 {
                normalFrame = r
            }
        }
        isMaximized = appDefaults.bool(forKey: "floatingTerminal.maximized")
        updateMaximizeButton()
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.isVisible && self.isMaximized { self.applyGeometry() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // 獨立聊天視窗曾經拿過焦點時，也要回到主視窗的專案範圍。
            self?.store.scope = nil
            self?.focusTerminal()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func configureButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let parent, !shuttingDown else { return }
        if isVisible { panel.makeKeyAndOrderFront(nil); focusTerminal(); return }
        store.scoped(nil) {
            returnChat = store.currentWindow?.focused.flatMap { workspace.panes[$0] as? ChatPane }
        }
        returnResponder = parent.firstResponder
        applyGeometry()
        parent.addChildWindow(panel, ordered: .above)
        if tabs.isEmpty { createTab() }
        panel.makeKeyAndOrderFront(nil)
        focusTerminal()
        onVisibilityChange?(true)
    }

    func hide(restoreFocus: Bool = true) {
        guard isVisible else { return }
        saveGeometry()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onVisibilityChange?(false)
        guard restoreFocus, let parent else { return }
        if NSApp.isActive { parent.makeKeyAndOrderFront(nil) }
        if let chat = returnChat, chat.window === parent, !chat.isHiddenOrHasHiddenAncestor, chat.focusInput() { return }
        if let view = returnResponder as? NSView, view.window === parent, !view.isHiddenOrHasHiddenAncestor {
            parent.makeFirstResponder(view)
        } else {
            store.scoped(nil) {
                if let id = store.currentWindow?.focused, let chat = workspace.panes[id] as? ChatPane { chat.focusInput() }
            }
        }
    }

    /// 收起後按新增也只建立一個分頁，不額外補一個空白 shell。
    func newTab() {
        if isVisible { createTab(); focusTerminal() }
        else if tabs.isEmpty { show() }
        else { createTab(); show() }
    }

    private func createTab() {
        let directory = store.scoped(nil) {
            store.currentWindow?.focused.flatMap { store.conversation($0) }.flatMap { store.project($0.projectID)?.path } ?? NSHomeDirectory()
        }
        let pane = TerminalPane(theme: workspace.theme)
        let tab = Tab(directory: directory, pane: pane, title: L("終端機 \(nextNumber)"))
        nextNumber += 1
        tabs.append(tab)
        selected = tab.id
        pane.frame = content.terminals.bounds
        pane.autoresizingMask = [.width, .height]
        content.terminals.addSubview(pane)
        let id = tab.id
        pane.onTitle = { [weak self] title in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            tab.title = String(title.prefix(80))
            self.rebuildTabs()
        }
        pane.onExit = { [weak self] _ in
            // 先離開 SwiftTerm 的 delegate 回呼，再釋放終端機視圖。
            DispatchQueue.main.async { self?.closeTab(id, terminate: false) }
        }
        rebuildTabs()
        content.layoutSubtreeIfNeeded()
        pane.start(executable: "/bin/zsh", args: ["-l", "-i"], directory: directory, environment: Workspace.environment())
    }

    private func rebuildTabs() {
        content.tabStrip.subviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            tab.pane.isHidden = tab.id != selected
            let row = NSView()
            let button = NSButton(title: tab.title, target: self, action: #selector(selectFromButton(_:)))
            button.frame = NSRect(x: 0, y: 0, width: 140, height: 24)
            button.setButtonType(.toggle)
            button.bezelStyle = .roundRect
            button.font = .systemFont(ofSize: 12)
            button.lineBreakMode = .byTruncatingTail
            button.state = tab.id == selected ? .on : .off
            button.toolTip = tab.directory
            button.tag = index
            row.addSubview(button)
            let close = NSButton()
            configureButton(close, symbol: "xmark", label: L("關閉終端機分頁"), action: #selector(closeFromButton(_:)))
            close.frame = NSRect(x: 142, y: 0, width: 24, height: 24)
            close.tag = index
            row.addSubview(close)
            content.tabStrip.addSubview(row)
        }
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        if let index = tabs.firstIndex(where: { $0.id == selected }) {
            content.tabStrip.scrollToVisible(NSRect(x: CGFloat(index) * 170, y: 0, width: 166, height: 36))
        }
    }

    private func closeTab(_ id: UUID, terminate: Bool) {
        guard !shuttingDown, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let hadFocus = panel.isKeyWindow
        let tab = tabs.remove(at: index)
        tab.pane.onExit = nil
        tab.pane.onTitle = nil
        if terminate { tab.pane.terminate() }
        tab.pane.removeFromSuperview()
        if selected == id { selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        rebuildTabs()
        if tabs.isEmpty { hide(restoreFocus: hadFocus) }
        else if hadFocus { focusTerminal() }
    }

    private func focusTerminal() {
        guard let tab = tabs.first(where: { $0.id == selected }) else { return }
        panel.makeFirstResponder(tab.pane.terminal)
    }

    func applyTheme(_ theme: Theme) {
        for tab in tabs { tab.pane.applyTheme(theme) }
    }

    var hasRunningProcess: Bool { tabs.contains { $0.pane.hasRunningProcess } }

    func terminate() {
        saveGeometry()
        shuttingDown = true
        for tab in tabs {
            tab.pane.onExit = nil
            tab.pane.onTitle = nil
            tab.pane.terminate()
        }
        tabs.removeAll()
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func applyGeometry() {
        guard let parent else { return }
        var frame: NSRect
        if isMaximized {
            frame = parent.convertToScreen(parent.contentLayoutRect).insetBy(dx: 8, dy: 8)
        } else if let normalFrame {
            frame = normalFrame.offsetBy(dx: parent.frame.minX, dy: parent.frame.minY)
        } else {
            let p = parent.frame
            if let c = chatRect(), c.width > 200, c.height > 260 {
                // 指定：左右對齊聊天欄（留一點邊）、上緣在聊天欄高度 20% 處、下緣停在輸入框附件列上方（不蓋輸入框文字列）
                let side: CGFloat = 12, bottomKeep: CGFloat = 150
                let top = c.maxY - c.height * 0.20
                let bottom = c.minY + bottomKeep
                frame = NSRect(x: c.minX + side, y: bottom, width: c.width - side * 2, height: max(200, top - bottom))
            } else {
                frame = NSRect(x: p.minX + p.width * 0.15, y: p.minY + p.height * 0.12, width: p.width * 0.7, height: p.height * 0.45)
            }
        }
        // 拔掉螢幕、主視窗縮小後，至少讓標題列與邊緣留在目前螢幕內。
        if let screen = parent.screen?.visibleFrame {
            frame.size.width = min(max(panel.minSize.width, frame.width), screen.width)
            frame.size.height = min(max(panel.minSize.height, frame.height), screen.height)
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        settingGeometry = true
        panel.setFrame(frame, display: true)
        settingGeometry = false
        content.layoutSubtreeIfNeeded()
    }

    /// 回到預設位置大小（選單「顯示方式 → 浮動終端機：回到預設位置」）
    func resetGeometry() {
        normalFrame = nil
        isMaximized = false
        appDefaults.removeObject(forKey: "floatingTerminal.normalFrame")
        appDefaults.set(false, forKey: "floatingTerminal.maximized")
        updateMaximizeButton()
        if isVisible { applyGeometry(); saveGeometry() }
    }

    private func saveGeometry() {
        guard !settingGeometry, let parent else { return }
        if !isMaximized, isVisible {
            normalFrame = panel.frame.offsetBy(dx: -parent.frame.minX, dy: -parent.frame.minY)
        }
        if let normalFrame { appDefaults.set(NSStringFromRect(normalFrame), forKey: "floatingTerminal.normalFrame") }
        appDefaults.set(isMaximized, forKey: "floatingTerminal.maximized")
    }

    private func updateMaximizeButton() {
        configureButton(maximizeButton, symbol: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        label: isMaximized ? L("還原") : L("放到最大"), action: #selector(toggleMaximized))
    }

    @objc private func toggleMaximized() {
        saveGeometry()
        isMaximized.toggle()
        applyGeometry()
        saveGeometry()
        updateMaximizeButton()
        focusTerminal()
    }
    @objc private func hideFromButton() { hide() }
    @objc private func addFromButton() { newTab() }
    @objc private func selectFromButton(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        selected = tabs[sender.tag].id
        rebuildTabs()
        focusTerminal()
    }
    @objc private func closeFromButton(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        closeTab(tabs[sender.tag].id, terminate: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidMove(_ notification: Notification) { saveGeometry() }
    func windowDidResize(_ notification: Notification) { saveGeometry() }
    func windowWillMove(_ notification: Notification) { leaveMaximized() }
    func windowWillStartLiveResize(_ notification: Notification) { leaveMaximized() }
    private func leaveMaximized() {
        guard isMaximized, !settingGeometry else { return }
        isMaximized = false
        updateMaximizeButton()
        saveGeometry()
    }

    /// 測試掛鉤讀取初始工作資料夾與全域面板座標；不送按鍵、不改 shell 狀態。
    func dumpState(to path: String) {
        let f = panel.frame
        let state: [String: Any] = [
            "visible": isVisible, "maximized": isMaximized, "tabCount": tabs.count,
            "keyWindow": panel.isKeyWindow, "attachedToMainWindow": panel.parent === parent,
            "tabs": tabs.map { ["workingDirectory": $0.directory, "shellPID": Int($0.pane.terminal.process.shellPid),
                                "running": $0.pane.terminal.process.running, "selected": $0.id == selected,
                                "focused": panel.firstResponder === $0.pane.terminal] as [String: Any] },
            "frame": ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height],
            "chatRect": chatRect().map { [$0.minX, $0.minY, $0.width, $0.height] } as Any,
            "parentFrame": parent.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } as Any
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
