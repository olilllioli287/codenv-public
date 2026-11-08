import AppKit
import SwiftUI

/// F6：大的關聯圖面板。從主視窗右邊緣往左滑出，左緣停在左欄右邊緣（蓋住聊天欄和右欄），再按 F6 或 Esc 滑回去。
/// 加在 contentView 上的子視圖（不是另一個視窗）：不搶焦點、開著時聊天格的程序照跑。
final class GraphPanelController {
    static let changed = Notification.Name("GraphPanelController.changed")
    private(set) static var isOpen = false

    private weak var window: NSWindow?
    private let store: Store
    private let workspace: Workspace
    /// 左欄右邊緣（視窗座標）；左欄收起時是 0
    var sidebarEdge: () -> CGFloat = { 0 }
    private var container: GraphPanelContainer?
    private var previousResponder: NSResponder?
    private var observers: [NSObjectProtocol] = []
    private let duration: TimeInterval

    init(window: NSWindow, store: Store, workspace: Workspace, duration: TimeInterval = 0.2) {
        self.window = window; self.store = store; self.workspace = workspace; self.duration = duration
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    var isOpen: Bool { container != nil }

    func toggle() { isOpen ? hide() : show() }

    private func openFrame(in cv: NSView) -> NSRect {
        let x = min(max(0, sidebarEdge()), max(0, cv.bounds.width - 200))
        return NSRect(x: x, y: 0, width: cv.bounds.width - x, height: cv.bounds.height)
    }

    func show() {
        guard container == nil, let window, let cv = window.contentView else { return }
        previousResponder = window.firstResponder
        ChatInfoCard.shared.cancel()
        let c = GraphPanelContainer(store: store, workspace: workspace, close: { [weak self] in self?.hide() })
        let end = openFrame(in: cv)
        c.frame = NSRect(x: cv.bounds.width, y: 0, width: end.width, height: end.height)
        c.autoresizingMask = [.height]
        cv.addSubview(c, positioned: .above, relativeTo: nil)
        container = c
        Self.isOpen = true
        ChatGraphView.setOverlayOpen(true)
        NotificationCenter.default.post(name: Self.changed, object: nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            c.animator().frame = end
        } completionHandler: { [weak self, weak c] in
            guard let c, self?.container === c else { return }
            c.focusGraph()
        }
        // 左欄開關、視窗縮放時跟著改左緣
        let nc = NotificationCenter.default
        observers = [NSSplitView.didResizeSubviewsNotification, NSWindow.didResizeNotification].map { name in
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self, self.container != nil, (n.object as? NSWindow) === self.window || n.object is NSSplitView else { return }
                self.reposition()
            }
        }
    }

    /// 不加動畫：貼著目前的左緣
    func reposition() {
        guard let c = container, let cv = window?.contentView else { return }
        let f = openFrame(in: cv)
        if c.frame != f { c.frame = f }
    }

    func hide() {
        guard let c = container, let window, let cv = window.contentView else { return }
        container = nil
        Self.isOpen = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        ChatInfoCard.shared.cancel()
        ChatGraphView.setOverlayOpen(false)
        NotificationCenter.default.post(name: Self.changed, object: nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            c.animator().frame = NSRect(x: cv.bounds.width, y: 0, width: c.frame.width, height: c.frame.height)
        } completionHandler: { c.removeFromSuperview() }
        if let r = previousResponder, window.firstResponder === c.graph || window.firstResponder is NSView && (window.firstResponder as! NSView).isDescendant(of: c) {
            window.makeFirstResponder(r)
        }
        previousResponder = nil
    }

    /// 測試用
    var graphView: ChatGraphView? { container?.graph }
}

/// 面板本體：左緣一條陰影、底色、上面一個標題列，其餘是關聯圖
final class GraphPanelContainer: NSView {
    private(set) var graph: ChatGraphView!
    private var host: NSHostingView<Scaled<GraphPanelRoot>>!

    init(store: Store, workspace: Workspace, close: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        let root = GraphPanelRoot(store: store, workspace: workspace, close: close, graphReady: { [weak self] v in self?.graph = v })
        host = NSHostingView(rootView: Scaled { root })
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        setAccessibilityIdentifier("graphPanel")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); host.frame = bounds }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }

    /// 讓圖拿到鍵盤焦點（i、Esc）
    func focusGraph() { if let g = graph { window?.makeFirstResponder(g) } }

    // 面板蓋住底下：滑鼠不要穿過去點到聊天欄
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) ?? (bounds.contains(convert(point, from: superview)) ? self : nil) }
    override func mouseDown(with event: NSEvent) {}
}

struct GraphPanelRoot: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    let workspace: Workspace
    let close: () -> Void
    let graphReady: (ChatGraphView) -> Void
    @State private var infoID: UUID?

    private struct InfoTarget: Identifiable { let id: UUID }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            ChatGraphRepresentable(store: store, workspace: workspace, big: true, isOverlay: true,
                                   onSummon: { id in
                                       if let sid = store.currentSessionLayout?.id { store.summonConversation(id, inSession: sid) }
                                       close()                       // 叫出來後自動收起
                                   },
                                   onInfo: { infoID = $0 },
                                   onEscape: close,
                                   onCreate: graphReady)
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Color(nsColor: Store.bundleAccent))
                Text(store.currentSessionLayout.map { $0.name + L(" · 關聯圖") } ?? L("關聯圖")).font(.system(size: 13 * s, weight: .semibold))
                Spacer()
                Text(L("單擊選取 · 雙擊叫出 · i 資訊 · 右鍵選單 · 拖曳或兩指捲動平移 · ⌘＋滾輪或捏合縮放 · 雙擊空白處置中")).font(.system(size: 10.5 * s)).foregroundStyle(.tertiary).lineLimit(1)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11 * s, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("收起（F6 或 Esc）"))
            }
            .padding(.leading, 14).padding(.trailing, 10).padding(.top, 8)
        }
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1) }
        .sheet(item: Binding(get: { infoID.map { InfoTarget(id: $0) } }, set: { if $0 == nil { infoID = nil } })) { t in
            ChatInfoForm(store: store, id: t.id) { infoID = nil }
        }
    }
}

/// 右欄桌寵框左上、浮動終端機按鈕正下方：開關 F6 關聯圖面板（同尺寸、只放圖示、開著時強調色）
final class GraphButton: NSButton {
    private var hovering = false { didSet { refresh() } }
    private var observer: NSObjectProtocol?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: L("關聯圖"))
        image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        toolTip = L("關聯圖（F6）")
        setAccessibilityLabel(L("關聯圖"))
        target = self
        action = #selector(toggle)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        observer = NotificationCenter.default.addObserver(forName: GraphPanelController.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    private func refresh() {
        let on = GraphPanelController.isOpen
        contentTintColor = on ? .controlAccentColor : .labelColor
        layer?.backgroundColor = (hovering ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).cgColor
        layer?.borderColor = (on ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    @objc private func toggle() { (NSApp.delegate as? AppDelegate)?.toggleGraphPanel() }
}
