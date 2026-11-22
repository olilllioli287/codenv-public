import AppKit
import QuartzCore

/// 自己繪製的標題拖曳區，回報主視窗 contentView 座標。
private final class FloatingTerminalDragHandle: NSView {
    var onStart: ((NSPoint) -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?

    private func point(_ event: NSEvent) -> NSPoint? {
        guard let window, let contentView = window.contentView else { return nil }
        return contentView.convert(event.locationInWindow, from: nil)
    }
    override func mouseDown(with event: NSEvent) { if let p = point(event) { onStart?(p) } }
    override func mouseDragged(with event: NSEvent) { if let p = point(event) { onMove?(p) } }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

/// 右下角的原生 view resize handle。
private final class FloatingTerminalResizeHandle: NSView {
    var onStart: ((NSPoint) -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?

    private func point(_ event: NSEvent) -> NSPoint? {
        guard let window, let contentView = window.contentView else { return nil }
        return contentView.convert(event.locationInWindow, from: nil)
    }
    override func mouseDown(with event: NSEvent) { if let p = point(event) { onStart?(p) } }
    override func mouseDragged(with event: NSEvent) { if let p = point(event) { onMove?(p) } }
    override func mouseUp(with event: NSEvent) { onEnd?() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for inset in [CGFloat(5), 9, 13] {
            path.move(to: NSPoint(x: bounds.maxX - inset, y: 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: inset))
        }
        path.stroke()
    }
}

/// 主視窗內的浮動終端機容器，不會建立第二個 NSWindow。
private final class FloatingTerminalContent: NSView {
    let tabScroll = NSScrollView()
    let tabStrip = NSView()
    let addButton = NSButton()
    let terminals = NSView()
    let maximizeButton = NSButton()
    let hideButton = NSButton()
    let titleLabel = NSTextField(labelWithString: L("浮動終端機"))
    let dragHandle = FloatingTerminalDragHandle()
    let resizeHandle = FloatingTerminalResizeHandle()
    private let surface = NSView()
    var onDragStart: ((NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onResizeStart: ((NSPoint) -> Void)?
    var onResizeMove: ((NSPoint) -> Void)?
    var onResizeEnd: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -5)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        surface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(surface)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.isSelectable = false
        surface.addSubview(titleLabel)
        surface.addSubview(dragHandle)
        for button in [maximizeButton, hideButton] { surface.addSubview(button) }
        tabScroll.documentView = tabStrip
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.scrollerStyle = .overlay
        surface.addSubview(tabScroll)
        surface.addSubview(addButton)
        surface.addSubview(terminals)
        surface.addSubview(resizeHandle)
        dragHandle.onStart = { [weak self] in self?.onDragStart?($0) }
        dragHandle.onMove = { [weak self] in self?.onDragMove?($0) }
        dragHandle.onEnd = { [weak self] in self?.onDragEnd?() }
        resizeHandle.onStart = { [weak self] in self?.onResizeStart?($0) }
        resizeHandle.onMove = { [weak self] in self?.onResizeMove?($0) }
        resizeHandle.onEnd = { [weak self] in self?.onResizeEnd?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let titleHeight: CGFloat = 34
        let tabsHeight: CGFloat = 36
        let width = bounds.width
        let height = bounds.height
        titleLabel.frame = NSRect(x: 13, y: height - titleHeight, width: max(0, width - 110), height: titleHeight)
        dragHandle.frame = NSRect(x: 0, y: height - titleHeight, width: max(0, width - 74), height: titleHeight)
        maximizeButton.frame = NSRect(x: width - 68, y: height - 29, width: 26, height: 24)
        hideButton.frame = NSRect(x: width - 36, y: height - 29, width: 26, height: 24)
        tabScroll.frame = NSRect(x: 4, y: height - titleHeight - tabsHeight, width: max(0, width - 40), height: tabsHeight)
        addButton.frame = NSRect(x: width - 32, y: height - titleHeight - 32, width: 28, height: 28)
        tabStrip.frame = NSRect(x: 0, y: 0, width: max(tabScroll.contentSize.width, CGFloat(tabStrip.subviews.count) * 170), height: tabsHeight)
        for (i, tab) in tabStrip.subviews.enumerated() {
            tab.frame = NSRect(x: CGFloat(i) * 170, y: 6, width: 166, height: 24)
        }
        terminals.frame = NSRect(x: 1, y: 1, width: max(0, width - 2), height: max(0, height - titleHeight - tabsHeight - 1))
        resizeHandle.frame = NSRect(x: max(0, width - 18), y: 0, width: min(18, width), height: 18)
    }
}

/// 收起只改顯示狀態；分頁與 PTY 的生命週期由這個控制器持有，到關分頁或 App 結束才終止。
final class FloatingTerminalController: NSObject {
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
    private let content = FloatingTerminalContent()
    private var tabs: [Tab] = []
    private var selected: UUID?
    private var nextNumber = 1
    private weak var returnChat: ChatPane?
    private weak var returnResponder: NSResponder?
    private var observers: [NSObjectProtocol] = []
    /// 座標相對於主視窗 contentView；視窗搬到其他螢幕後仍能還原原本的位置。
    private var normalFrame: NSRect?
    private(set) var isMaximized = false
    private var settingGeometry = false
    private var shuttingDown = false
    private var dragStartPoint: NSPoint?
    private var dragStartFrame: NSRect?
    private var resizeStartPoint: NSPoint?
    private var resizeStartFrame: NSRect?
    private var dragFrameMilliseconds: [Double] = []
    private var positionSaveCount = 0
    private var interactionWatchdog: Timer?
    /// 目前顯示的位置大小是主視窗太小時暫時夾回的結果：不能存成 normalFrame，主視窗變大後要回到原本的。
    private var displayClamped = false
    var onVisibilityChange: ((Bool) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    /// 中間聊天欄在螢幕上的範圍（預設位置照它的比例算，視窗變大小跟著走）
    var chatRect: () -> NSRect? = { nil }
    var isVisible: Bool { content.superview != nil && !content.isHidden }
    func owns(_ window: NSWindow?) -> Bool { window === parent }

    init(parent: NSWindow, store: Store, workspace: Workspace) {
        self.parent = parent
        self.store = store
        self.workspace = workspace
        super.init()
        content.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        configureButton(content.maximizeButton, symbol: "arrow.up.left.and.arrow.down.right", label: L("放到最大"), action: #selector(toggleMaximized))
        configureButton(content.hideButton, symbol: "chevron.down", label: L("收起浮動終端機"), action: #selector(hideFromButton))
        configureButton(content.addButton, symbol: "plus", label: L("新增終端機分頁"), action: #selector(addFromButton))
        content.onDragStart = { [weak self] in self?.beginDrag(at: $0) }
        content.onDragMove = { [weak self] in self?.moveDrag(to: $0) }
        content.onDragEnd = { [weak self] in self?.endDrag() }
        content.onResizeStart = { [weak self] in self?.beginResize(at: $0) }
        content.onResizeMove = { [weak self] in self?.moveResize(to: $0) }
        content.onResizeEnd = { [weak self] in self?.endResize() }

        loadSavedFrame()
        isMaximized = appDefaults.bool(forKey: "floatingTerminal.maximized")
        updateMaximizeButton()
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
            guard let self, self.isVisible else { return }
            if self.isMaximized { self.applyGeometry() }
            else { self.clampVisibleForDisplay() }
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
        guard let parent, let contentView = parent.contentView, !shuttingDown else { return }
        if isVisible { parent.makeKeyAndOrderFront(nil); focusTerminal(); return }
        store.scoped(nil) {
            returnChat = store.currentWindow?.focused.flatMap { workspace.panes[$0] as? ChatPane }
        }
        returnResponder = parent.firstResponder
        applyGeometry()
        if tabs.isEmpty { createTab() }
        content.isHidden = false
        contentView.addSubview(content, positioned: .above, relativeTo: nil)
        parent.makeKeyAndOrderFront(nil)
        focusTerminal()
        onVisibilityChange?(true)
    }

    func hide(restoreFocus: Bool = true) {
        cancelInteraction()
        guard isVisible else { return }
        saveGeometry()
        content.removeFromSuperview()
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
            store.currentWindow?.focused.flatMap { store.conversation($0) }.map { store.workingDirectory(for: $0) } ?? NSHomeDirectory()
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
        let hadFocus = (parent?.firstResponder as? NSView).map { $0.isDescendant(of: content) } ?? false
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
        guard let parent, let tab = tabs.first(where: { $0.id == selected }) else { return }
        parent.makeFirstResponder(tab.pane.terminal)
    }

    func applyTheme(_ theme: Theme) {
        for tab in tabs { tab.pane.applyTheme(theme) }
    }

    var hasRunningProcess: Bool { tabs.contains { $0.pane.hasRunningProcess } }

    func terminate() {
        cancelInteraction()
        saveGeometry()
        shuttingDown = true
        for tab in tabs {
            tab.pane.onExit = nil
            tab.pane.onTitle = nil
            tab.pane.terminate()
        }
        tabs.removeAll()
        content.removeFromSuperview()
    }

    private func applyGeometry() {
        guard let parent, let contentView = parent.contentView else { return }
        let bounds = contentView.bounds
        var frame: NSRect
        if isMaximized {
            frame = bounds.insetBy(dx: 8, dy: 8)
        } else if let normalFrame {
            frame = normalFrame
        } else {
            let c = chatRect().map { contentView.convert(parent.convertFromScreen($0), from: nil) }
            if let c, c.width > 200, c.height > 260 {
                // 指定：左右對齊聊天欄（留一點邊）、上緣在聊天欄高度 20% 處、下緣停在輸入框附件列上方（不蓋輸入框文字列）
                let side: CGFloat = 12, bottomKeep: CGFloat = 150
                let top = c.maxY - c.height * 0.20
                let bottom = c.minY + bottomKeep
                frame = NSRect(x: c.minX + side, y: bottom, width: c.width - side * 2, height: max(200, top - bottom))
            } else {
                frame = NSRect(x: bounds.minX + bounds.width * 0.15, y: bounds.minY + bounds.height * 0.12,
                               width: bounds.width * 0.7, height: bounds.height * 0.45)
            }
        }
        frame = clamped(frame, in: bounds)
        displayClamped = !isMaximized && normalFrame.map { frame != $0 } == true
        settingGeometry = true
        content.frame = frame
        settingGeometry = false
        content.layoutSubtreeIfNeeded()
    }

    private func loadSavedFrame() {
        guard let parent, let contentView = parent.contentView else { return }
        let frame: NSRect?
        if let saved = appDefaults.string(forKey: "floatingTerminal.viewFrame") {
            frame = NSRectFromString(saved)
        } else if let legacy = appDefaults.string(forKey: "floatingTerminal.normalFrame") {
            // 舊值以主視窗座標保存；轉成 contentView 座標後繼續沿用。
            frame = contentView.convert(NSRectFromString(legacy), from: nil)
        } else {
            frame = nil
        }
        guard let frame,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              frame.width >= 320, frame.height >= 200 else { return }
        normalFrame = clamped(frame, in: contentView.bounds)
    }

    private func clamped(_ input: NSRect, in bounds: NSRect) -> NSRect {
        let maxWidth = max(0, bounds.width - 16)
        let maxHeight = max(0, bounds.height - 16)
        var frame = input
        frame.size.width = min(max(min(320, maxWidth), frame.width), maxWidth)
        frame.size.height = min(max(min(200, maxHeight), frame.height), maxHeight)
        frame.origin.x = min(max(frame.minX, bounds.minX + 8), bounds.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, bounds.minY + 8), bounds.maxY - frame.height - 8)
        return frame
    }

    /// 主視窗大小改變：只改顯示、不存。有存過的位置大小就依新大小重算（放大後會回到原本的），縮放中不動。
    private func clampVisibleForDisplay() {
        guard let contentView = parent?.contentView, isVisible, !interacting else { return }
        if normalFrame != nil { applyGeometry(); return }
        let frame = clamped(content.frame, in: contentView.bounds)
        guard frame != content.frame else { return }
        settingGeometry = true
        content.frame = frame
        settingGeometry = false
    }

    private func beginDrag(at point: NSPoint) {
        guard isVisible else { return }
        restoreFromMaximized(anchoredAt: point)
        displayClamped = false
        dragStartPoint = point
        dragStartFrame = content.frame
        dragFrameMilliseconds.removeAll(keepingCapacity: true)
        notifyDragState(true)
        armInteractionWatchdog()
    }

    private func moveDrag(to point: NSPoint) {
        guard let startPoint = dragStartPoint, let startFrame = dragStartFrame,
              let bounds = parent?.contentView?.bounds else { return }
        let started = CACurrentMediaTime()
        var frame = startFrame.offsetBy(dx: point.x - startPoint.x, dy: point.y - startPoint.y)
        frame = clamped(frame, in: bounds)
        content.frame = frame
        content.layoutSubtreeIfNeeded()
        dragFrameMilliseconds.append((CACurrentMediaTime() - started) * 1000)
    }

    private func endDrag() {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        dragStartFrame = nil
        saveGeometry()
        finishInteractionIfIdle()
    }

    private func beginResize(at point: NSPoint) {
        guard isVisible else { return }
        if isMaximized {
            isMaximized = false
            updateMaximizeButton()
            applyGeometry()
        }
        displayClamped = false
        resizeStartPoint = point
        resizeStartFrame = content.frame
        dragFrameMilliseconds.removeAll(keepingCapacity: true)
        notifyDragState(true)
        armInteractionWatchdog()
    }

    private func moveResize(to point: NSPoint) {
        guard let startPoint = resizeStartPoint, let startFrame = resizeStartFrame,
              let bounds = parent?.contentView?.bounds else { return }
        let started = CACurrentMediaTime()
        let maxWidth = max(320, bounds.maxX - startFrame.minX - 8)
        let maxHeight = max(200, bounds.maxY - startFrame.minY - 8)
        let width = min(max(320, startFrame.width + point.x - startPoint.x), maxWidth)
        let height = min(max(200, startFrame.height - point.y + startPoint.y), maxHeight)
        let frame = clamped(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), in: bounds)
        content.frame = frame
        content.layoutSubtreeIfNeeded()
        dragFrameMilliseconds.append((CACurrentMediaTime() - started) * 1000)
    }

    private func endResize() {
        guard resizeStartPoint != nil else { return }
        resizeStartPoint = nil
        resizeStartFrame = nil
        saveGeometry()
        finishInteractionIfIdle()
    }

    /// 最後一次通知關聯圖的拖曳狀態（測試探針讀）：true＝動畫被暫停中
    private(set) var reportedDragging = false
    private func notifyDragState(_ dragging: Bool) {
        reportedDragging = dragging
        onDragStateChange?(dragging)
    }
    /// 測試：模擬開始拖曳／縮放（不經滑鼠），用來驗證收起、結束與逾時保險會恢復。
    func testBeginInteraction(resize: Bool) {
        guard isVisible else { return }
        let point = NSPoint(x: content.frame.midX, y: content.frame.maxY - 10)
        if resize { beginResize(at: point) } else { beginDrag(at: point) }
    }

    private var interacting: Bool { dragStartPoint != nil || resizeStartPoint != nil }

    private func finishInteractionIfIdle() {
        guard !interacting else { return }
        interactionWatchdog?.invalidate(); interactionWatchdog = nil
        notifyDragState(false)
    }

    /// 拖曳／縮放被中斷（收起、shell 結束、視窗失焦吃掉 mouseUp）時，重設狀態並通知關聯圖恢復動畫。
    private func cancelInteraction() {
        let was = interacting
        dragStartPoint = nil; dragStartFrame = nil
        resizeStartPoint = nil; resizeStartFrame = nil
        interactionWatchdog?.invalidate(); interactionWatchdog = nil
        if was { notifyDragState(false) }
    }

    /// 逾時保險：拖曳狀態超過 2 秒、而且滑鼠左鍵其實已放開，就自動結束（按住不動的不算）。
    private func armInteractionWatchdog() {
        interactionWatchdog?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.interacting else { self.interactionWatchdog?.invalidate(); self.interactionWatchdog = nil; return }
            if NSEvent.pressedMouseButtons & 1 == 0 { self.saveGeometry(); self.cancelInteraction() }
        }
        RunLoop.main.add(t, forMode: .common)
        interactionWatchdog = t
    }

    /// 最大化時開始拖曳，先還原並把游標留在標題列的相近位置。
    private func restoreFromMaximized(anchoredAt point: NSPoint) {
        guard isMaximized, let bounds = parent?.contentView?.bounds else { return }
        let maximizedFrame = content.frame
        isMaximized = false
        updateMaximizeButton()
        var frame = normalFrame ?? clamped(NSRect(x: bounds.minX + bounds.width * 0.15,
                                                  y: bounds.minY + bounds.height * 0.12,
                                                  width: bounds.width * 0.7, height: bounds.height * 0.45), in: bounds)
        let horizontalRatio = maximizedFrame.width > 0 ? (point.x - maximizedFrame.minX) / maximizedFrame.width : 0.5
        let fromTop = maximizedFrame.maxY - point.y
        frame.origin.x = point.x - horizontalRatio * frame.width
        frame.origin.y = point.y - frame.height + min(max(fromTop, 0), 34)
        frame = clamped(frame, in: bounds)
        content.frame = frame
    }

    /// 回到預設位置大小（選單「顯示方式 → 浮動終端機：回到預設位置」）
    func resetGeometry() {
        normalFrame = nil
        isMaximized = false
        appDefaults.removeObject(forKey: "floatingTerminal.viewFrame")
        appDefaults.removeObject(forKey: "floatingTerminal.normalFrame")
        appDefaults.set(false, forKey: "floatingTerminal.maximized")
        updateMaximizeButton()
        if isVisible { applyGeometry(); saveGeometry() }
    }

    private func saveGeometry() {
        guard !settingGeometry else { return }
        if !isMaximized, isVisible, !displayClamped {
            normalFrame = content.frame
        }
        if let normalFrame {
            appDefaults.set(NSStringFromRect(normalFrame), forKey: "floatingTerminal.viewFrame")
            positionSaveCount += 1
        }
        appDefaults.set(isMaximized, forKey: "floatingTerminal.maximized")
    }

    private func isContained(_ frame: NSRect, in bounds: NSRect) -> Bool {
        bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame)
    }

    /// 原生探針：檢查開啟不增加 NSWindow、位置存讀、最大化還原與主視窗縮小夾回。
    func runViewProbe(to path: String) {
        guard let parent, let contentView = parent.contentView else { return }
        let initialWindowCount = NSApp.windows.count
        let originalParentFrame = parent.frame
        let originalMaximized = isMaximized
        let originalNormal = normalFrame
        isMaximized = false
        let target = clamped(NSRect(x: contentView.bounds.minX + 28, y: contentView.bounds.minY + 42,
                                    width: min(430, max(320, contentView.bounds.width - 56)),
                                    height: min(290, max(200, contentView.bounds.height - 84))), in: contentView.bounds)
        normalFrame = target
        content.frame = target
        show()
        let anchor = NSPoint(x: target.minX + 22, y: target.maxY - 16)
        let positionSavesBeforeDrag = positionSaveCount
        beginDrag(at: anchor)
        for step in 0..<120 {
            let phase = CGFloat(step % 24)
            moveDrag(to: NSPoint(x: anchor.x + phase, y: anchor.y + phase * 0.3))
        }
        let positionSavesDuringDrag = positionSaveCount - positionSavesBeforeDrag
        let positionFrameAtMouseUp = content.frame
        let positionSavesBeforeMouseUp = positionSaveCount
        endDrag()
        let positionSavesAfterRelease = positionSaveCount - positionSavesBeforeMouseUp
        normalFrame = nil
        loadSavedFrame()
        let positionFrameReadBackAfterRelease = normalFrame
        let positionSavedFrameMatchesAfterRelease = positionFrameReadBackAfterRelease.map {
            abs($0.minX - positionFrameAtMouseUp.minX) < 0.5 &&
            abs($0.minY - positionFrameAtMouseUp.minY) < 0.5 &&
            abs($0.width - positionFrameAtMouseUp.width) < 0.5 &&
            abs($0.height - positionFrameAtMouseUp.height) < 0.5
        } ?? false
        let positionFrameReadBackAfterReleaseJSON: Any = positionFrameReadBackAfterRelease.map { Self.probeFrame($0) as Any } ?? NSNull()
        content.frame = target
        normalFrame = target
        saveGeometry()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak parent] in
            guard let self, let parent, let contentView = parent.contentView else { return }
            let windowCountUnchanged = NSApp.windows.count == initialWindowCount
            let attached = self.content.superview === contentView
            self.saveGeometry()
            self.normalFrame = nil
            self.loadSavedFrame()
            let positionRoundTrips = self.normalFrame.map {
                abs($0.minX - target.minX) < 0.5 && abs($0.minY - target.minY) < 0.5 &&
                abs($0.width - target.width) < 0.5 && abs($0.height - target.height) < 0.5
            } ?? false
            self.isMaximized = false
            self.content.frame = self.normalFrame ?? target
            self.toggleMaximized()
            let expectedMax = contentView.bounds.insetBy(dx: 8, dy: 8)
            let maximizedCorrectly = abs(self.content.frame.minX - expectedMax.minX) < 0.5 &&
                abs(self.content.frame.minY - expectedMax.minY) < 0.5 &&
                abs(self.content.frame.width - expectedMax.width) < 0.5 &&
                abs(self.content.frame.height - expectedMax.height) < 0.5
            self.toggleMaximized()
            let restoredCorrectly = abs(self.content.frame.minX - target.minX) < 0.5 &&
                abs(self.content.frame.minY - target.minY) < 0.5 &&
                abs(self.content.frame.width - target.width) < 0.5 &&
                abs(self.content.frame.height - target.height) < 0.5

            var smallFrame = originalParentFrame
            smallFrame.size = NSSize(width: max(parent.minSize.width, 540), height: max(parent.minSize.height, 430))
            parent.setFrame(smallFrame, display: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak parent] in
                guard let self, let parent, let contentView = parent.contentView else { return }
                let remainsVisible = self.isContained(self.content.frame, in: contentView.bounds)
                parent.setFrame(originalParentFrame, display: false)
                self.isMaximized = originalMaximized
                if originalMaximized { self.applyGeometry() }
                else { self.normalFrame = originalNormal ?? target; self.content.frame = self.clamped(self.content.frame, in: contentView.bounds) }
                self.terminate()
                let result: [String: Any] = [
                    "appWindowsBefore": initialWindowCount,
                    "appWindowsAfterOpen": NSApp.windows.count,
                    "windowCountUnchanged": windowCountUnchanged,
                    "attachedToMainContentView": attached,
                    "positionReadBack": positionRoundTrips,
                    "positionSavesDuringDrag": positionSavesDuringDrag,
                    "positionSavesAfterRelease": positionSavesAfterRelease,
                    "positionFrameAtMouseUp": Self.probeFrame(positionFrameAtMouseUp),
                    "positionFrameReadBackAfterRelease": positionFrameReadBackAfterReleaseJSON,
                    "positionSavedFrameMatchesAfterRelease": positionSavedFrameMatchesAfterRelease,
                    "positionSavedOnlyAfterMouseUp": positionSavesDuringDrag == 0 && positionSavesAfterRelease == 1 && positionSavedFrameMatchesAfterRelease,
                    "maximizedFrameCorrect": maximizedCorrectly,
                    "restoredFrameCorrect": restoredCorrectly,
                    "visibleAfterMainWindowShrink": remainsVisible,
                    "probeDidNotChangeWindowCount": initialWindowCount == NSApp.windows.count,
                    "syntheticDragFrameSamples": self.dragFrameMilliseconds.count,
                    "syntheticDragFrameMaxMs": self.dragFrameMilliseconds.max() ?? 0,
                    "syntheticDragFrameP95Ms": self.dragFrameMilliseconds.sorted().dropFirst(max(0, Int(Double(self.dragFrameMilliseconds.count) * 0.95))).first ?? 0,
                    "syntheticDragFrameHandlersUnder8Ms": (self.dragFrameMilliseconds.max() ?? 0) < 8,
                    "syntheticDragIsLogicOnly": true
                ]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        }
    }

    private static func probeFrame(_ frame: NSRect) -> [String: Double] {
        ["x": Double(frame.minX), "y": Double(frame.minY),
         "width": Double(frame.width), "height": Double(frame.height)]
    }

    private func updateMaximizeButton() {
        configureButton(content.maximizeButton, symbol: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
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

    /// 測試掛鉤讀取初始工作資料夾與全域面板座標；不送按鍵、不改 shell 狀態。
    func dumpState(to path: String) {
        let f = content.frame
        let durations = dragFrameMilliseconds.sorted()
        let p95 = durations.isEmpty ? 0 : durations[min(durations.count - 1, Int(Double(durations.count - 1) * 0.95))]
        let state: [String: Any] = [
            "visible": isVisible, "maximized": isMaximized, "tabCount": tabs.count,
            "keyWindow": parent?.isKeyWindow ?? false,
            "attachedToMainWindow": content.superview === parent?.contentView,
            "appWindowCount": NSApp.windows.count,
            "tabs": tabs.map { ["workingDirectory": $0.directory, "shellPID": Int($0.pane.terminal.process.shellPid),
                                "running": $0.pane.terminal.process.running, "selected": $0.id == selected,
                                "focused": parent?.firstResponder === $0.pane.terminal] as [String: Any] },
            "frame": ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height],
            "chatRect": chatRect().map { [$0.minX, $0.minY, $0.width, $0.height] } as Any,
            "parentFrame": parent.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } as Any,
            "interacting": interacting, "reportedDragging": reportedDragging,
            "watchdogArmed": interactionWatchdog != nil,
            "dragFrameSamples": durations.count,
            "dragFrameMaxMs": durations.last ?? 0,
            "dragFrameP95Ms": p95
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
