import AppKit
import Combine
import SwiftUI

// 右邊主畫面：最上面一排是 Session 名稱和 Window 分頁（像 tmux 的狀態列，但在上面、可以點），
// 下面照目前 Window 的分割樹擺 Pane。按鍵照使用者 ~/.tmux.conf 的 Ctrl+A 那一套（PrefixKeys）。

/// 一格 Pane 的外框：好幾格時上面有一條小標題、每格一圈框（目前那格是強調色的粗框）。
/// 框畫在最上層的 RingView（不吃滑鼠），不然會被聊天畫面、輸入框蓋住，只剩標題那段看得到。
/// 標題可以按住拖：拖到上面的分頁列放開＝這格變成一個新的 Window 分頁
final class PaneFrame: NSView {
    let conversation: UUID
    let content: NSView
    private let header = NSTextField(labelWithString: "")
    private let grip = HeaderGrip()
    private let closeButton = NSButton()
    private let ring = RingView()
    let pathBar = PathBar()      // 最下面的資料夾路徑列（像 Finder 底部）
    private var accent: NSColor = .controlAccentColor
    var onClose: (() -> Void)?
    /// 拖標題：.began／.moved／.ended（點位置是視窗座標）；只點一下＝onHeaderClick
    var onHeaderDrag: ((HeaderGrip.Phase, NSPoint) -> Void)?
    var onHeaderClick: (() -> Void)?
    var showsHeader = false { didSet { header.isHidden = !showsHeader; closeButton.isHidden = !showsHeader; grip.isHidden = !showsHeader; updateRing(); needsLayout = true } }
    var isFocused = false { didSet { updateRing() } }
    static let headerHeight: CGFloat = 36

    init(conversation: UUID, content: NSView) {
        self.conversation = conversation
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "關掉這格")?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "關掉這格（Ctrl+A x）；對話會留在側欄"
        grip.toolTip = "按住標題拖到上面的分頁列：變成新的分頁"
        grip.onDrag = { [weak self] ph, p in self?.onHeaderDrag?(ph, p) }
        grip.onClick = { [weak self] in self?.onHeaderClick?() }
        addSubview(content)
        addSubview(header)
        addSubview(grip)
        addSubview(closeButton)
        addSubview(pathBar)
        addSubview(ring)
        showsHeader = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ t: String) { header.stringValue = t; header.font = .systemFont(ofSize: 13 * UIScale.shared.f, weight: .medium) }
    func setAccent(_ c: NSColor) { accent = c; updateRing() }
    var title: String { header.stringValue }

    private func updateRing() {
        // 只有一格時不畫框（也沒有標題）；好幾格時每格都有框，目前那格用強調色
        ring.isHidden = !showsHeader
        ring.color = isFocused ? accent : NSColor.separatorColor
        ring.width = isFocused ? 2 : 1
        header.textColor = isFocused ? .labelColor : .secondaryLabelColor
    }

    @objc private func close() { onClose?() }

    override func layout() {
        super.layout()
        let h = showsHeader ? Self.headerHeight : 0
        let ph = pathBar.path == nil ? 0 : PathBar.height
        content.frame = NSRect(x: 0, y: ph, width: bounds.width, height: bounds.height - h - ph)
        pathBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: ph)
        pathBar.isHidden = ph == 0
        header.frame = NSRect(x: 14, y: bounds.height - h + (h - 18) / 2, width: bounds.width - 48, height: 18)
        grip.frame = NSRect(x: 0, y: bounds.height - h, width: max(0, bounds.width - 30), height: h)
        closeButton.frame = NSRect(x: bounds.width - 28, y: bounds.height - h + (h - 18) / 2, width: 18, height: 18)
        ring.frame = bounds
        ring.headerHeight = h
        // 框永遠在最上面（拖放接收區除外：那是之後才加的，會在它上面）
        if subviews.last !== ring, !subviews.contains(where: { $0 is DropOverlay }) { addSubview(ring, positioned: .above, relativeTo: nil) }
    }
}

/// Pane 外框的那一圈：不吃滑鼠。有標題時，標題下面畫一條白線，把標題那一條單獨隔出來
final class RingView: NSView {
    var color: NSColor = .separatorColor { didSet { needsDisplay = true } }
    var width: CGFloat = 1 { didSet { needsDisplay = true } }
    var headerHeight: CGFloat = 0 { didSet { if headerHeight != oldValue { needsDisplay = true } } }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: width / 2 + 0.5, dy: width / 2 + 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        p.lineWidth = width
        color.setStroke()
        p.stroke()
        if headerHeight > 0 {
            let y = bounds.height - headerHeight
            NSColor.labelColor.withAlphaComponent(0.55).setFill()   // 深色模式是白線
            NSRect(x: r.minX, y: y - 0.5, width: r.width, height: 1).fill()
        }
    }
}

/// Pane 標題那一條：按住拖（超過 4 點才算拖），放開前一直回報位置
final class HeaderGrip: NSView {
    enum Phase { case began, moved, ended }
    var onDrag: ((Phase, NSPoint) -> Void)?
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with e: NSEvent) {
        guard let w = window else { return }
        let start = e.locationInWindow
        var dragging = false
        var last = start
        while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            last = ev.locationInWindow
            if ev.type == .leftMouseUp { break }
            if !dragging && abs(last.x - start.x) < 4 && abs(last.y - start.y) < 4 { continue }
            if !dragging { dragging = true; NSCursor.closedHand.push(); onDrag?(.began, last) }
            onDrag?(.moved, last)
        }
        if dragging { NSCursor.pop(); onDrag?(.ended, last) } else { onClick?() }
    }
}

/// 從側欄拖對話進來時蓋在每一格上面：拖到哪一邊就亮哪一邊，放開從那邊切開；正中間＝換掉這格的對話
/// 測試用：設了 WB_PULL_DEBUG＝檔案路徑，就把分頁拉下的過程寫進去
func pullDebug(_ s: String) {
    guard let f = ProcessInfo.processInfo.environment["WB_PULL_DEBUG"] else { return }
    let old = (try? String(contentsOfFile: f, encoding: .utf8)) ?? ""
    try? (old + s + "\n").write(toFile: f, atomically: true, encoding: .utf8)
}

final class DropOverlay: NSView {
    static let type = NSPasteboard.PasteboardType.string
    static let prefix = "wbconv:"
    static let began = Notification.Name("AIWorkbenchConversationDragBegan")
    let target: UUID
    var onDrop: ((UUID, Edge?) -> Void)?
    enum Edge { case left, right, top, bottom }
    private var zone: Edge?? = nil { didSet { needsDisplay = true } }   // nil＝沒在上面；.some(nil)＝中間
    /// true：只有左右上下四半，沒有「換掉中間」（從分頁列拉下來的時候用）
    var halvesOnly = false

    init(target: UUID) {
        self.target = target
        super.init(frame: .zero)
        registerForDraggedTypes([Self.type])
    }
    required init?(coder: NSCoder) { fatalError() }

    static func conversation(in pb: NSPasteboard) -> UUID? {
        guard let s = pb.string(forType: type), s.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(s.dropFirst(prefix.count)))
    }

    func edge(at p: NSPoint) -> Edge? {
        let x = p.x / max(1, bounds.width), y = p.y / max(1, bounds.height)
        let d = [(Edge.left, x), (.right, 1 - x), (.bottom, y), (.top, 1 - y)].min { $0.1 < $1.1 }!
        return halvesOnly || d.1 < 0.28 ? d.0 : nil
    }
    /// 不是系統拖放、自己追滑鼠的時候：游標在這格上（視窗座標）就亮起那一半；不在就收
    func hover(window p: NSPoint?) {
        guard let p else { zone = nil; return }
        let q = convert(p, from: nil)
        zone = bounds.contains(q) ? .some(edge(at: q)) : nil
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard Self.conversation(in: s.draggingPasteboard) != nil else { return [] }
        zone = .some(edge(at: convert(s.draggingLocation, from: nil)))
        return .move
    }
    override func draggingExited(_ s: NSDraggingInfo?) { zone = nil }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let id = Self.conversation(in: s.draggingPasteboard) else { return false }
        let e = edge(at: convert(s.draggingLocation, from: nil))
        zone = nil
        onDrop?(id, e)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let z = zone else { return }
        var r = bounds
        switch z {
        case .left?: r.size.width /= 2
        case .right?: r.origin.x += r.width / 2; r.size.width /= 2
        case .bottom?: r.size.height /= 2
        case .top?: r.origin.y += r.height / 2; r.size.height /= 2
        case nil: r = bounds.insetBy(dx: 8, dy: 8)
        }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8)
        p.lineWidth = 2
        p.stroke()
    }
}

/// 兩格之間的分隔線，可以拖
private final class Divider: NSView {
    let vertical: Bool       // true＝上下切（線是橫的）
    var onDrag: ((CGFloat) -> Void)?   // 傳出新的比例
    weak var container: NSView?
    init(vertical: Bool) { self.vertical = vertical; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight) }
    override func mouseDragged(with e: NSEvent) {
        guard let c = container else { return }
        let p = c.convert(e.locationInWindow, from: nil)
        // 容器不是翻轉座標：上下切時 a 在上面，比例從上往下算
        let r = vertical ? 1 - p.y / max(1, c.bounds.height) : p.x / max(1, c.bounds.width)
        onDrag?(r)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = vertical ? NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1) : NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        line.fill()
    }
}

/// 掛件格子從右邊彈進來／滑出去（使用者 10/25「叫出pane的動畫…從右邊蹦出來」）。
/// 動的是「這格露出多少」s（0＝全在右邊外面、1＝在版面上的位置）：外層切口的比例跟著 s 走，原本的格子同時讓出／長回空間；
/// 掛件格子本身維持最後的寬度、只往左右移（網頁不會跟著一直改寬度）。狀態放這裡，不放在 SplitBox：版面重建也接得上。
final class PaneSlide {
    static let shared = PaneSlide()
    enum Kind { case slideIn, slideOut }
    private struct Anim { var kind: Kind; var start: Date; var from: Double; var v0: Double; var done: (() -> Void)? }
    private var anims: [UUID: Anim] = [:]
    private var timer: Timer?
    /// 每一格畫面要重排時叫一次（WindowHost 設）
    var onTick: (() -> Void)?
    /// 測試用：所有動畫停在第幾秒（--pane-slide）
    var frozen: Double?

    // 彈進來：彈簧（response 0.35 秒、damping 0.75，帶一點點過衝）；滑出去：ease-in 0.2 秒、不過衝
    static let response = 0.35, damping = 0.75, outDuration = 0.2
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 正在滑出去的（版面上還在，但當作已經收起來）
    func isLeaving(_ id: UUID) -> Bool { anims[id]?.kind == .slideOut }

    /// 彈進來；正在滑出去的就從目前位置反轉
    func slideIn(_ id: UUID) {
        guard !Self.reduceMotion else { anims[id] = nil; onTick?(); return }
        let (s, v) = state(id) ?? (0, 0)
        anims[id] = Anim(kind: .slideIn, start: Date(), from: s, v0: v, done: nil)
        run()
    }

    /// 滑出去，滑完叫 done（真的從版面拿掉）；不播動畫的時候直接叫
    func slideOut(_ id: UUID, done: @escaping () -> Void) {
        guard !Self.reduceMotion else { anims[id] = nil; done(); return }
        let (s, _) = state(id) ?? (1, 0)
        anims[id] = Anim(kind: .slideOut, start: Date(), from: min(1, max(0, s)), v0: 0, done: done)
        run()
    }

    /// 這格現在露出多少、速度（每秒）；沒在動回傳 nil
    func state(_ id: UUID) -> (Double, Double)? {
        guard let a = anims[id] else { return nil }
        let t = frozen ?? Date().timeIntervalSince(a.start)
        return Self.value(a, at: t)
    }

    private static func value(_ a: Anim, at t: Double) -> (Double, Double) {
        switch a.kind {
        case .slideIn:
            // 欠阻尼彈簧：x＝s−1，從 x0、v0 出發
            let w = 2 * Double.pi / response, z = damping, wd = w * (1 - z * z).squareRoot()
            let x0 = a.from - 1, b = (a.v0 + z * w * x0) / wd, e = exp(-z * w * t)
            let x = e * (x0 * cos(wd * t) + b * sin(wd * t))
            let v = e * ((b * wd - z * w * x0) * cos(wd * t) - (x0 * wd + z * w * b) * sin(wd * t))
            return (1 + x, v)
        case .slideOut:
            let d = max(0.05, outDuration * a.from), u = min(1, t / d)
            return (a.from * (1 - u * u), -2 * a.from * u / d)
        }
    }

    private func finished(_ a: Anim, _ t: Double) -> Bool {
        switch a.kind {
        case .slideIn: let (s, v) = Self.value(a, at: t); return t > 0.15 && abs(s - 1) < 0.001 && abs(v) < 0.01 || t > 1.5
        case .slideOut: return t >= max(0.05, Self.outDuration * a.from)
        }
    }

    private func run() {
        onTick?()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if frozen == nil {
            for (id, a) in anims where finished(a, Date().timeIntervalSince(a.start)) {
                anims[id] = nil
                a.done?()
            }
        }
        onTick?()
        if anims.isEmpty { timer?.invalidate(); timer = nil }
    }
}

/// 一個切口：兩邊各一棵子樹，中間分隔線
private final class SplitBox: NSView {
    let vertical: Bool
    var ratio: CGFloat
    let a: NSView, b: NSView
    let divider: Divider
    static let gap: CGFloat = 6
    init(vertical: Bool, ratio: CGFloat, a: NSView, b: NSView, onRatio: @escaping (CGFloat) -> Void) {
        self.vertical = vertical; self.ratio = ratio; self.a = a; self.b = b
        divider = Divider(vertical: vertical)
        super.init(frame: .zero)
        addSubview(a); addSubview(b); addSubview(divider)
        divider.container = self
        divider.onDrag = { [weak self] r in
            guard let self else { return }
            self.ratio = min(0.92, max(0.08, r))
            self.needsLayout = true
            onRatio(self.ratio)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// b 是哪一格（掛件格子滑進／滑出時用）
    var bPane: UUID? { (b as? PaneFrame)?.conversation }

    override func layout() {
        super.layout()
        let g = Self.gap
        // 掛件格子在動：比例照「露出多少」算；掛件維持最後的寬度、只往右移（超出右邊的切掉）
        if !vertical, let id = bPane, let (s, _) = PaneSlide.shared.state(id) {
            let full = bounds.width - g
            let finalB = full - (full * ratio).rounded()
            let wa = max(0, (full - finalB * CGFloat(s)).rounded())
            a.frame = NSRect(x: 0, y: 0, width: wa, height: bounds.height)
            divider.frame = NSRect(x: wa, y: 0, width: g, height: bounds.height)
            b.frame = NSRect(x: wa + g, y: 0, width: max(finalB, bounds.width - wa - g), height: bounds.height)
            wantsLayer = true
            layer?.masksToBounds = true
            return
        }
        layer?.masksToBounds = false
        if vertical {
            let ha = ((bounds.height - g) * ratio).rounded()
            a.frame = NSRect(x: 0, y: bounds.height - ha, width: bounds.width, height: ha)
            divider.frame = NSRect(x: 0, y: bounds.height - ha - g, width: bounds.width, height: g)
            b.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - ha - g)
        } else {
            let wa = ((bounds.width - g) * ratio).rounded()
            a.frame = NSRect(x: 0, y: 0, width: wa, height: bounds.height)
            divider.frame = NSRect(x: wa, y: 0, width: g, height: bounds.height)
            b.frame = NSRect(x: wa + g, y: 0, width: bounds.width - wa - g, height: bounds.height)
        }
    }
}

/// 上面那排：Session 名稱（點了換 Session）＋ Window 分頁＋「＋」
/// 分頁列左邊（側欄按鈕和 Session 中間）那塊空白、側欄最上面那條：按住拖整個視窗、點兩下放大。
/// 視窗本身設成不能拖（isMovable = false），所以自己追滑鼠搬視窗
final class DragHandle: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { Self.moveWindow(e, window) }
    /// 分頁列的空白處（＋ 右邊、分頁之間）也叫這個
    static func moveWindow(_ e: NSEvent, _ w: NSWindow?) {
        guard let w else { return }
        if e.clickCount == 2 { w.zoom(nil); return }
        let start = NSEvent.mouseLocation
        let origin = w.frame.origin
        while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            let p = NSEvent.mouseLocation
            w.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

final class TabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    /// 拖曳換順序：(原本第幾個, 放到第幾個)
    var onMove: ((Int, Int) -> Void)?
    /// 往下拉進畫面（只有一格的 Window 才行）：能不能拉、拉的途中（視窗座標）、放開（nil＝放在分頁列上，取消）
    var canPull: ((Int) -> Bool)?
    var onPull: ((Int, NSPoint) -> Void)?
    var onPullEnd: ((Int, NSPoint?) -> Void)?
    var onNew: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var sessionMenu: (() -> NSMenu)?
    /// 按了 Session：開浮動面板（給 Session 按鈕當定位用）
    var onSessions: ((NSView) -> Void)?
    private var buttons: [NSView] = []
    private var slotX: [CGFloat] = []   // 每個分頁平常的位置（拖曳時其他分頁滑到哪裡用）
    private var slotW: CGFloat = 0
    private var dragTarget: Int?
    private var dragging: NSView?       // 正在拖的分頁：拖曳中 layout 不要把大家排回原位（不然滑開的動畫會被蓋掉）
    private let sessionButton = NSButton()
    private let plus = NSButton()
    /// 拖 Pane 標題到分頁列上時，最後面先出現的「＋ 名字」虛線分頁（放開就變成真的分頁）
    private let tearGhost = TearGhost()
    private let sideButton = NSButton()
    private let dragHandle = DragHandle()
    private var splitObserver: Any?
    override var mouseDownCanMoveWindow: Bool { false }
    // 沒有按鈕、分頁的空白處：按住拖整個視窗、點兩下放大（使用者 10/24：＋ 右邊那一大塊也要能拖）
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { DragHandle.moveWindow(e, window) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 用 layer：拖曳時滑鼠事件迴圈還在跑，分頁滑開／放下的動畫交給 Core Animation 才會一格一格動
        wantsLayer = true
        // 收起／打開左邊的側欄（⌃ ⌘ S）：聊天區太擠的時候整條收到最左邊
        sideButton.isBordered = false
        sideButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "側欄")?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        sideButton.contentTintColor = .secondaryLabelColor
        sideButton.target = self
        sideButton.action = #selector(toggleSidebar)
        sideButton.toolTip = "收起／打開側欄（⌃ ⌘ S）"
        addSubview(sideButton)
        dragHandle.toolTip = "按住拖動視窗，點兩下放大"
        addSubview(dragHandle)
        sessionButton.bezelStyle = .inline
        sessionButton.isBordered = false
        sessionButton.target = self
        sessionButton.action = #selector(showSessions)
        sessionButton.toolTip = "換 Session（Ctrl+A s）"
        addSubview(sessionButton)
        plus.isBordered = false
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新 Window")?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        plus.contentTintColor = .secondaryLabelColor
        plus.target = self
        plus.action = #selector(newTab)
        plus.toolTip = "新 Window（Ctrl+A c）"
        addSubview(plus)
        tearGhost.isHidden = true
        addSubview(tearGhost)
        registerForDraggedTypes(ChatTextView.dropTypes)   // 拖檔案停在分頁上切 Window（見 springHover）
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 拖檔案停在分頁上：1.5 秒後切到那個 Window（像 Finder 的彈簧資料夾），再自己決定放進哪一格

    private var currentTab = 0
    private var springTab: Int?
    private var springTimer: Timer?

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard ChatTextView.isFileDrag(s.draggingPasteboard) else { return [] }
        springHover(at: convert(s.draggingLocation, from: nil))
        return []   // 分頁上不收檔案：放開等於取消
    }
    override func draggingExited(_ s: NSDraggingInfo?) { springHover(at: nil) }
    override func draggingEnded(_ s: NSDraggingInfo) { springHover(at: nil) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { springHover(at: nil); return false }

    /// 游標在哪個分頁上（nil＝離開了）：換了分頁就重新計時；目前這個 Window 的分頁不用切
    func springHover(at p: NSPoint?) {
        let i = p.flatMap { p in buttons.firstIndex { $0.frame.contains(p) } }.flatMap { $0 == currentTab ? nil : $0 }
        guard i != springTab else { return }
        springTimer?.invalidate(); springTimer = nil
        if let old = springTab, old < buttons.count { (buttons[old] as? TabButton)?.springing = false }
        springTab = i
        guard let i else { return }
        (buttons[i] as? TabButton)?.springing = true
        let t = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.springTab == i else { return }
            self.springTab = nil; self.springTimer = nil
            self.onSelect?(i)
        }
        RunLoop.main.add(t, forMode: .common)   // 拖曳中的事件迴圈不跑一般模式的計時器
        springTimer = t
    }

    /// 測試用：游標停在第 i 個分頁的中間（nil＝離開）
    func springHover(tab i: Int?) {
        springHover(at: i.flatMap { $0 < buttons.count ? NSPoint(x: buttons[$0].frame.midX, y: buttons[$0].frame.midY) : nil })
    }
    /// 測試用：每個分頁在螢幕上的位置
    func tabScreenRects() -> [NSRect] { buttons.compactMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } } }

    /// 分頁上不放「做完沒看」的小藍點：只看側欄（點側欄那段對話會跳到它在的分頁；分頁也亮的話，跳過去之後舊分頁亮著會以為標錯，使用者 10/24 要拿掉）
    func update(session: String, tabs: [String], current: Int, accent: NSColor) {
        currentTab = current
        // 聊天進行中 store 一直變、這裡一直重建：分頁還是同一排就讓計時繼續跑，不然永遠等不到 1.5 秒
        if let i = springTab, tabs.count != buttons.count || i == current {
            springTab = nil; springTimer?.invalidate(); springTimer = nil
        }
        sessionButton.attributedTitle = NSAttributedString(string: " Session \(session) ", attributes: [
            .font: NSFont.systemFont(ofSize: 12 * UIScale.shared.f, weight: .semibold), .foregroundColor: NSColor.white,
            .backgroundColor: accent.withAlphaComponent(0.85)])
        buttons.forEach { $0.removeFromSuperview() }
        buttons = tabs.enumerated().map { i, t in
            let b = TabButton(index: i, title: t.isEmpty ? "[\(i + 1)]" : "[\(i + 1)] \(t)", selected: i == current, accent: accent)
            b.toolTip = "點兩下改名（Ctrl+A ,）"
            b.onClick = { [weak self] in self?.onSelect?(i) }
            b.onDoubleClick = { [weak self] in self?.onRename?(i) }
            b.onClose = { [weak self] in self?.onClose?(i) }
            b.springing = i == springTab
            addSubview(b)
            return b
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // 側欄收起來時這條貼到視窗最左邊：讓開左上角的紅黃綠按鈕
        let atLeftEdge = convert(NSPoint.zero, to: nil).x < 40
        var x: CGFloat = atLeftEdge ? 80 : 8
        sideButton.frame = NSRect(x: x, y: (bounds.height - 22) / 2, width: 24, height: 22)
        // 側欄按鈕和 Session 中間留空：按住這塊可以拖動整個視窗
        dragHandle.frame = NSRect(x: x + 28, y: 0, width: 44, height: bounds.height)
        x += 30 + 44
        let s = sessionButton.intrinsicContentSize
        sessionButton.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        x += s.width + 10
        // 先留 + 的位置（22 寬＋前後空隙），分頁再平分剩下的；太擠就一起變窄（最窄 56），不要壓到 +
        let room = bounds.width - x - 36
        let n = CGFloat(buttons.count)
        let each = buttons.isEmpty ? 0 : min(220, max(56, (room - 4 * (n - 1)) / n))
        slotW = each
        slotX = []
        for b in buttons {
            slotX.append(x)
            if dragging == nil { b.frame = NSRect(x: x, y: 4, width: each, height: bounds.height - 8) }
            x += each + 4
        }
        if !tearGhost.isHidden {
            let gw = min(220, max(120, each > 0 ? each : 160))
            tearGhost.frame = NSRect(x: x, y: 4, width: gw, height: bounds.height - 8)
            x += gw + 4
        }
        plus.frame = NSRect(x: min(x + 2, bounds.width - 28), y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    /// 拖 Pane 標題到分頁列上：顯示／收起最後面的「＋ 名字」預覽分頁
    func showTear(_ title: String?, accent: NSColor) {
        let show = title != nil
        tearGhost.title = title ?? ""
        tearGhost.accent = accent
        if tearGhost.isHidden == show { tearGhost.isHidden = !show; needsLayout = true }
    }
    /// 視窗座標的點在不在分頁列上
    func containsWindowPoint(_ p: NSPoint) -> Bool { bounds.contains(convert(p, from: nil)) }
    /// 分頁列上的空白處（視窗座標；測試用）：最後一個分頁和 + 中間
    func emptyPoint() -> NSPoint { convert(NSPoint(x: min(bounds.width - 40, plus.frame.maxX + 40), y: bounds.midY), to: nil) }

    /// 第 i 個分頁的中心（視窗座標；測試用）
    func tabCenter(_ i: Int) -> NSPoint? {
        guard buttons.indices.contains(i) else { return nil }
        let b = buttons[i]
        return b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
    }

    /// 拖著分頁走：被拖的那個跟著滑鼠，其他的滑開讓出位置
    fileprivate func drag(_ b: NSView, dx: CGFloat) {
        guard let from = buttons.firstIndex(where: { $0 === b }), slotX.count == buttons.count else { return }
        if dragging !== b {
            // 剛開始拖：浮到最上層、加陰影，看起來是被拿起來
            dragging = b
            addSubview(b, positioned: .above, relativeTo: nil)
            b.layer?.shadowColor = NSColor.black.cgColor
            b.layer?.shadowOpacity = 0.45
            b.layer?.shadowRadius = 6
            b.layer?.shadowOffset = CGSize(width: 0, height: -2)
            b.alphaValue = 0.92
        }
        let x = max(slotX[0], min(slotX[slotX.count - 1], slotX[from] + dx))
        b.frame.origin.x = x
        let step = slotW + 4
        let to = max(0, min(buttons.count - 1, from + Int(((x - slotX[from]) / step).rounded())))
        guard to != dragTarget else { return }
        dragTarget = to
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            for (i, o) in buttons.enumerated() where o !== b {
                var slot = i
                if from < to, i > from, i <= to { slot = i - 1 }
                if from > to, i >= to, i < from { slot = i + 1 }
                o.animator().frame.origin.x = slotX[slot]
            }
        }
    }
    /// 放開：被拖的分頁先滑進它的新位置，動畫做完才真的換順序（換完整排重畫，位置剛好對上，不會跳）
    fileprivate func drop(_ b: NSView) {
        let from = buttons.firstIndex(where: { $0 === b })
        let to = dragTarget ?? from
        dragTarget = nil
        guard let from, let to, slotX.indices.contains(to) else { dragging = nil; needsLayout = true; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            b.animator().frame.origin.x = slotX[to]
            b.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            b.layer?.shadowOpacity = 0
            self?.dragging = nil
            if to != from { self?.onMove?(from, to) } else { self?.needsLayout = true }
        })
    }

    /// 拖著的分頁往下離開分頁列：不再換順序（大家回原位），改成拉進畫面
    fileprivate func pull(_ b: NSView, at p: NSPoint) -> Bool {
        guard let i = buttons.firstIndex(where: { $0 === b }), canPull?(i) == true else { return false }
        if dragging != nil || dragTarget != nil {
            dragTarget = nil
            dragging = nil
            b.layer?.shadowOpacity = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                for (j, o) in buttons.enumerated() where slotX.indices.contains(j) { o.animator().frame.origin.x = slotX[j] }
            }
        }
        b.alphaValue = 0.45
        onPull?(i, p)
        return true
    }
    fileprivate func pullEnd(_ b: NSView, at p: NSPoint) {
        b.alphaValue = 1
        guard let i = buttons.firstIndex(where: { $0 === b }) else { return }
        onPullEnd?(i, convert(p, from: nil).y < 0 ? p : nil)
    }

    /// 第 i 個分頁畫面上現在的 x（動畫中途的位置；測試用）
    func tabShownX(_ i: Int) -> CGFloat? {
        guard buttons.indices.contains(i) else { return nil }
        let b = buttons[i]
        return b.layer?.presentation()?.frame.origin.x ?? b.frame.origin.x
    }

    @objc private func showSessions() {
        if let f = onSessions { return f(sessionButton) }
        guard let m = sessionMenu?() else { return }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sessionButton.bounds.height + 2), in: sessionButton)
    }
    @objc private func newTab() { onNew?() }
    @objc private func toggleSidebar() { onToggleSidebar?() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 側欄收起／打開（分隔線移動）時重排，按鈕才會讓開紅黃綠
        if splitObserver == nil {
            splitObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] _ in self?.needsLayout = true }
        }
    }
}

/// 分頁上的字：不能算「按住可以拖視窗」的地方（標題列那條的拖曳範圍是每個子元件各自算的）
/// 分頁列最後面的「＋ 名字」虛線預覽
/// 標題拖到另一格上面時蓋在那格的提示：淡淡的底色＋框＋「放開＝互換位置」
private final class SwapMark: NSView {
    private let label = NSTextField(labelWithString: "放開＝互換位置")
    init(accent: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = accent.withAlphaComponent(0.14).cgColor
        layer?.borderColor = accent.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 15 * UIScale.shared.f, weight: .semibold)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = accent.withAlphaComponent(0.85)
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.masksToBounds = true
        label.alignment = .center
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let s = label.intrinsicContentSize
        let w = s.width + 24, h = s.height + 12
        label.frame = NSRect(x: (bounds.width - w) / 2, y: bounds.height * 0.62 - h / 2, width: w, height: h)   // 偏上：跟著滑鼠的名牌不會壓到
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TearGhost: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        accent.withAlphaComponent(0.12).setFill(); p.fill()
        p.lineWidth = 1.5; p.setLineDash([5, 3], count: 2, phase: 0)
        accent.setStroke(); p.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12 * UIScale.shared.f, weight: .medium), .foregroundColor: NSColor.labelColor]
        let t = NSAttributedString(string: "＋ " + title, attributes: a)
        let sz = t.size()
        t.draw(with: NSRect(x: 10, y: (bounds.height - sz.height) / 2, width: bounds.width - 20, height: sz.height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

private final class NoDragLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class TabButton: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClose: (() -> Void)?
    private let label: NSTextField = { let l = NoDragLabel(); l.isEditable = false; l.isSelectable = false; l.isBordered = false; l.drawsBackground = false; return l }()
    private let x = NSButton()
    private let selected: Bool
    private var hover = false { didSet { x.isHidden = !(hover || selected); needsDisplay = true } }
    /// 拖著檔案停在這個分頁上、等著切過來：整個分頁亮主題色
    var springing = false { didSet { needsDisplay = true } }
    private let accent: NSColor
    init(index: Int, title: String, selected: Bool, accent: NSColor) {
        self.selected = selected; self.accent = accent
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 12 * UIScale.shared.f, weight: selected ? .semibold : .regular)
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        x.isBordered = false
        x.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "關掉這個 Window")?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        x.contentTintColor = .tertiaryLabelColor
        x.target = self
        x.action = #selector(closeTab)
        x.toolTip = "關掉這個 Window（Ctrl+A &）"
        x.isHidden = !selected
        addSubview(x)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let lx: CGFloat = 10
        label.frame = NSRect(x: lx, y: (bounds.height - 16) / 2, width: bounds.width - lx - 22, height: 16)
        x.frame = NSRect(x: bounds.width - 20, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }
    override func draw(_ dirtyRect: NSRect) {
        if springing {
            accent.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            return
        }
        guard selected || hover else { return }
        let p = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(selected ? 0.1 : 0.05).setFill()
        p.fill()
        if selected {
            accent.setFill()
            NSRect(x: 8, y: 0, width: bounds.width - 16, height: 2).fill()
        }
    }
    // 分頁列可以拖著移動視窗，但分頁本身拖的是分頁（換順序）。
    // 裡面的文字標籤也要算在分頁上：不然系統看到標籤「可以拖視窗」，按下去就被拿去拖整個視窗
    override var mouseDownCanMoveWindow: Bool { false }
    // 從別的 App 切回來，第一下點分頁就算數（不用先點一下讓視窗變成作用中）
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v === x ? v : (v == nil ? nil : self)
    }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onDoubleClick?(); return }
        guard let bar = superview as? TabBar, let w = window else { onClick?(); return }
        // 放開前沒拖超過 4 點：就是點一下（切到這個 Window）
        // 左右拖＝換順序；往下拖出分頁列＝把這個 Window（只有一格的）拉進目前畫面的左／右／上／下半
        let start = e.locationInWindow
        var dragging = false, pulling = false
        var last = start
        while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            last = ev.locationInWindow
            if ev.type == .leftMouseUp { break }
            let dx = last.x - start.x
            if !dragging && abs(dx) < 4 && abs(last.y - start.y) < 4 { continue }
            dragging = true
            let below = bar.convert(last, from: nil).y < -6
            pullDebug("move \(last) barY=\(bar.convert(last, from: nil).y) below=\(below) pulling=\(pulling)")
            // 一旦拉出去就一直是「拉進畫面」，直到放開（放回分頁列上＝取消）
            if (pulling || below), bar.pull(self, at: last) { pulling = true; continue }
            bar.drag(self, dx: dx)
        }
        pullDebug("up \(last) pulling=\(pulling) dragging=\(dragging)")
        if pulling { bar.pullEnd(self, at: last) } else if dragging { bar.drop(self) } else { onClick?() }
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    @objc private func closeTab() { onClose?() }
}

final class WindowHost: NSViewController {
    let store: Store
    let workspace: Workspace
    let tabBar = TabBar()
    private let body = NSView()
    private let placeholder = NSTextField(labelWithString: "左邊選一個對話，或按「新對話」（⌘ N）")
    private var frames: [UUID: PaneFrame] = [:]
    private var shownKey = ""
    private var bag: Set<AnyCancellable> = []
    var onCloseWindowRequest: ((Int) -> Void)?
    var onRenameWindowRequest: ((Int) -> Void)?
    var onNewWindow: (() -> Void)?
    /// 空格子按了「新增聊天室」：(哪個空格子；nil＝整個 Window 是空的, 按鈕)
    var onEmptyAdd: ((UUID?, NSView) -> Void)?
    private var empties: [UUID: EmptyPaneView] = [:]
    private var emptyWindowView: EmptyPaneView?
    var sessionMenu: (() -> NSMenu)?
    static let barHeight: CGFloat = 36
    private let petView = PetSlotView()
    /// 右側欄位：上面放用量（token），最下面是桌寵格子；所有 Pane 都在它左邊
    private let petColumn = PetColumnView()
    private lazy var usageView = NSHostingView(rootView: Scaled { UsagePanel(m: UsageMonitor.shared, store: self.store, compact: { [weak self] id in self?.onCompact?(id) }) })
    var onCompact: ((UUID) -> Void)?

    init(store: Store, workspace: Workspace) {
        self.store = store
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.centerXAnchor.constraint(equalTo: body.centerXAnchor),
                                     placeholder.centerYAnchor.constraint(equalTo: body.centerYAnchor)])
        v.addSubview(body)
        v.addSubview(tabBar)
        view = v
        tabBar.onSelect = { [weak self] i in self?.store.selectWindow(at: i) }
        tabBar.onClose = { [weak self] i in self?.onCloseWindowRequest?(i) }
        tabBar.onRename = { [weak self] i in self?.onRenameWindowRequest?(i) }
        tabBar.onMove = { [weak self] from, to in
            guard let self, let si = self.store.sessionIndex, self.store.sessions[si].windows.indices.contains(from) else { return }
            // moveWindow 的位置是「搬之前」的：往後搬要再加一
            self.store.moveWindow(self.store.sessions[si].windows[from].id, toSession: self.store.sessions[si].id, at: to > from ? to + 1 : to)
        }
        tabBar.canPull = { [weak self] i in
            guard let self, let si = self.store.sessionIndex, self.store.sessions[si].windows.indices.contains(i) else { return false }
            let w = self.store.sessions[si].windows[i]
            return w.id != self.store.currentWindow?.id && w.root?.leaves.count == 1 && w.root.flatMap { $0.leaves.first }.flatMap { self.store.conversation($0) } != nil
        }
        tabBar.onPull = { [weak self] _, p in self?.pullHover(p) }
        tabBar.onPullEnd = { [weak self] i, p in self?.pullEnd(i, p) }
        tabBar.onNew = { [weak self] in self?.onNewWindow?() }
        tabBar.sessionMenu = { [weak self] in self?.sessionMenu?() ?? NSMenu() }
        // 版面或對話標題變了就重畫（合併成一次）
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &bag)
        // 桌寵空位：開關、調大小、換螢幕都重排
        petView.onResize = { [weak self] size in PetSlot.setSize(size, on: self?.view.window?.screen) }
        NotificationCenter.default.addObserver(forName: PetSlot.changed, object: nil, queue: .main) { [weak self] _ in self?.layoutPetSlot() }
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] n in
            if (n.object as? NSWindow) === self?.view.window { self?.layoutPetSlot() }
        }
        // 文字大小改了：分頁列、格子標題跟著重畫
        UIScale.shared.$factor.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &bag)
        // 側欄開始拖對話：每一格蓋上接收區，放開（或拖去別處）就收起來
        NotificationCenter.default.addObserver(forName: DropOverlay.began, object: nil, queue: .main) { [weak self] _ in self?.showDropTargets() }
        // 點到哪一格，那格就變成目前那格
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, e.window === self.view.window else { return e }
            for (id, v) in self.empties where v.superview != nil && v.bounds.contains(v.convert(e.locationInWindow, from: nil)) {
                if self.store.currentWindow?.focused != id { self.store.setFocus(id) }
            }
            for (id, f) in self.frames where f.superview != nil {
                let inside = f.bounds.contains(f.convert(e.locationInWindow, from: nil))
                // 已經是目前這格：點輸入框以外就讓輸入框失效
                if inside, self.store.currentWindow?.focused == id, let c = self.workspace.panes[id] as? ChatPane { c.clickedInside(e) }
                if inside, self.store.currentWindow?.focused != id {
                    self.store.setFocus(id)
                    // 換到另一段聊天：游標直接進那格的輸入框（等這一下點擊處理完再放，不然會被網頁拿走）；
                    // 已經在這格裡，再點輸入框以外才會離開
                    if let c = self.workspace.panes[id] as? ChatPane {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak c] in c?.focusInput() }
                    }
                }
            }
            return e
        }
        render()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        tabBar.frame = NSRect(x: 0, y: b.height - Self.barHeight, width: b.width, height: Self.barHeight)
        layoutPetSlot()
    }

    /// 測試用：照畫面上的順序（外層先）找第 index 條分隔線，像滑鼠拖到 ratio 一樣（走同一個 onDrag）
    func testDragDivider(index: Int, ratio: CGFloat) {
        var boxes: [SplitBox] = []
        func walk(_ v: NSView) { if let b = v as? SplitBox { boxes.append(b) }; v.subviews.forEach(walk) }
        walk(view)
        guard index < boxes.count else { return }
        boxes[index].divider.onDrag?(ratio)
    }

    /// 桌寵位置：視窗最右邊一條固定欄位（寬＝桌寵格子的寬），最下面是格子、上面是用量；Pane 都排在它左邊，不會被蓋到
    func layoutPetSlot() {
        guard isViewLoaded else { return }
        let on = PetSlot.enabled
        let size = PetSlot.size(on: view.window?.screen)
        let b = view.bounds
        let h = b.height - Self.barHeight
        let colW = on ? min(size.width, max(0, b.width - 300)) : 0
        for f in frames.values { (f.content as? any ConversationPane)?.petReserve = .zero }
        body.frame = NSRect(x: 0, y: 0, width: b.width - colW, height: h)
        body.subviews.first { $0 !== placeholder && !($0 is DropOverlay) }?.frame = body.bounds
        if on {
            if petColumn.superview !== view { view.addSubview(petColumn) }
            if petView.superview !== petColumn { petColumn.addSubview(petView) }
            if usageView.superview !== petColumn { petColumn.addSubview(usageView) }
            petColumn.frame = NSRect(x: b.width - colW, y: 0, width: colW, height: h)
            let slotH = min(size.height, h)
            petView.frame = NSRect(x: 0, y: 0, width: colW, height: slotH)
            usageView.frame = NSRect(x: 0, y: slotH, width: colW, height: max(0, h - slotH))
            petView.needsDisplay = true
            petColumn.needsDisplay = true
        } else {
            petColumn.removeFromSuperview()
        }
    }

    private var accent: NSColor {
        let pal = workspace.theme.palette(for: view.effectiveAppearance)
        return pal.ansi.count > 12 ? pal.ansi[12] : .controlAccentColor
    }

    /// 掛件格子滑進／滑出時：所有掛件所在的切口重排（PaneSlide 每一格叫一次）
    private func slideTick() {
        func walk(_ v: NSView) { if let b = v as? SplitBox, b.bPane != nil { b.needsLayout = true }; v.subviews.forEach(walk) }
        walk(body)
    }

    func render() {
        guard isViewLoaded else { return }
        if PaneSlide.shared.onTick == nil { PaneSlide.shared.onTick = { [weak self] in self?.slideTick() } }
        let pal = workspace.theme.palette(for: view.effectiveAppearance)
        view.layer?.backgroundColor = pal.bg.cgColor
        let s = store.currentSessionLayout
        let windows = s?.windows ?? []
        let wi = store.windowIndex ?? 0
        // 分頁上：取過名字的顯示「[1] 名字」，沒取過只顯示「[1]」
        tabBar.update(session: s?.name ?? "", tabs: windows.map { $0.renamed ? $0.name : "" }, current: wi, accent: accent)

        guard let w = store.currentWindow else { return }
        let root: PaneNode? = w.zoomed ? w.focused.map { .leaf($0) } : w.root
        let key = "\(w.id)|\(String(describing: root))"
        if key != shownKey {
            shownKey = key
            body.subviews.filter { $0 !== placeholder }.forEach { $0.removeFromSuperview() }
            frames.values.forEach { $0.removeFromSuperview() }
            empties.values.forEach { $0.removeFromSuperview() }
            if let root {
                let tree = build(root, path: [], windowID: w.id)
                tree.frame = body.bounds
                tree.autoresizingMask = [.width, .height]
                body.addSubview(tree)
            } else {
                let e = emptyWindowView ?? EmptyPaneView(slot: nil)
                e.onAdd = { [weak self] v in self?.onEmptyAdd?(nil, v) }
                emptyWindowView = e
                e.frame = body.bounds
                e.autoresizingMask = [.width, .height]
                body.addSubview(e)
            }
            placeholder.isHidden = true
            // 不在畫面上的格子不留外框（對話本身留在 Workspace 裡繼續跑）
            let visible = Set(root?.leaves ?? [])
            frames = frames.filter { visible.contains($0.key) }
            empties = empties.filter { visible.contains($0.key) }
        }
        for (id, e) in empties {
            e.isFocused = id == w.focused && (root?.leaves.count ?? 0) > 1
            e.closable = (root?.leaves.count ?? 0) > 1
            e.accent = accent
        }
        layoutPetSlot()
        let many = (root?.leaves.count ?? 0) > 1
        for (id, f) in frames {
            f.showsHeader = many
            f.isFocused = id == w.focused
            f.setAccent(accent)
            f.setTitle(store.conversation(id)?.title ?? "")
            // 瀏覽器格子沒有工作資料夾的意思：不顯示路徑列
            let dir = store.conversation(id).flatMap { $0.isBrowser ? nil : store.project($0.projectID)?.path }
            if f.pathBar.path != dir { f.pathBar.setPath(dir); f.needsLayout = true }
        }
        if let f = w.focused, let frame = frames[f], let pane = frame.content as? any ConversationPane,
           let win = view.window, !(win.firstResponder as? NSView).map({ $0.isDescendant(of: frame) }).orFalse {
            win.makeFirstResponder(pane.focusTarget)
        }
    }

    private var overlays: [DropOverlay] = []
    private var overlayTimer: Timer?

    private func showDropTargets() {
        hideDropTargets()
        guard let w = store.currentWindow else { return }
        if w.root == nil {
            // 空的 Window：整塊都是接收區
            let o = DropOverlay(target: UUID())
            o.frame = body.bounds
            // 拖進空的 Window：搬過來（原本擺在別處也一樣），不是跳回原本的位置
            let wid = w.id
            o.onDrop = { [weak self] id, _ in self?.hideDropTargets(); self?.store.movePane(id, toWindow: wid) }
            body.addSubview(o)
            overlays.append(o)
        }
        for (id, f) in frames where f.superview != nil {
            let o = DropOverlay(target: id)
            o.frame = f.bounds
            o.autoresizingMask = [.width, .height]
            o.onDrop = { [weak self] conv, edge in
                self?.hideDropTargets()
                self?.store.place(conv, near: id, edge: edge)
            }
            f.addSubview(o)
            overlays.append(o)
        }
        for (id, v) in empties where v.superview != nil {
            let o = DropOverlay(target: id)
            o.frame = v.bounds
            o.autoresizingMask = [.width, .height]
            o.onDrop = { [weak self] conv, _ in
                self?.hideDropTargets()
                if self?.store.replacePane(id, with: conv) == true { Store.emptySlots.remove(id) }
            }
            v.addSubview(o)
            overlays.append(o)
        }
        // 放在別處或取消：滑鼠放開就收
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            if NSEvent.pressedMouseButtons & 1 == 0 { self?.hideDropTargets() }
        }
    }

    // MARK: 分頁往下拉進畫面

    private var pullOverlays: [DropOverlay] = []
    private func pullHover(_ p: NSPoint) {
        if pullOverlays.isEmpty {
            if store.currentWindow?.root == nil {
                let o = DropOverlay(target: UUID()); o.frame = body.bounds
                body.addSubview(o); pullOverlays.append(o)
            }
            let targets: [(UUID, NSView)] = frames.map { ($0.key, $0.value as NSView) } + empties.map { ($0.key, $0.value as NSView) }
            for (id, f) in targets where f.superview != nil {
                let o = DropOverlay(target: id); o.halvesOnly = true; o.frame = f.bounds; o.autoresizingMask = [.width, .height]
                f.addSubview(o); pullOverlays.append(o)
            }
        }
        pullOverlays.forEach { $0.hover(window: p) }
    }
    private func pullEnd(_ i: Int, _ p: NSPoint?) {
        // 放在哪一格、哪一半：要在拿掉接收區之前算（拿掉後座標換算就不對了）
        let hit = p.flatMap { p in pullOverlays.first { $0.bounds.contains($0.convert(p, from: nil)) }.map { ($0.target, $0.edge(at: $0.convert(p, from: nil))) } }
        pullOverlays.forEach { $0.removeFromSuperview() }
        pullOverlays = []
        guard let (target, edge) = hit, let si = store.sessionIndex, store.sessions[si].windows.indices.contains(i),
              let cw = store.currentWindow else { return }
        let src = store.sessions[si].windows[i]
        guard src.id != cw.id, let conv = src.root?.leaves.first, src.root?.leaves.count == 1 else { return }
        if cw.root == nil { store.movePane(conv, toWindow: cw.id) }
        else if store.isEmptySlot(target) { if store.replacePane(target, with: conv) { Store.emptySlots.remove(target) } }   // 拉到空格子上＝放進去
        else { store.place(conv, near: target, edge: edge ?? .right) }
        // 那個 Window 只有這一格，搬走就空了：關掉
        store.deleteWindow(src.id)
        pullDebug("pullEnd 完成：" + store.sessions[si].windows.map { $0.name }.joined(separator: " "))
    }

    // MARK: Pane 標題拉到分頁列＝變成新的分頁；拉到同一個分頁裡的另一格＝兩格互換位置

    private var tearLabel: NSTextField?
    private var swapMark: SwapMark?
    /// 標題拖到哪一格上面（不算自己；聊天格、空格子都可以）
    private func swapTarget(_ id: UUID, at p: NSPoint) -> UUID? {
        guard let root = store.currentWindow?.root, !(store.currentWindow?.zoomed ?? false) else { return nil }
        let views: [(UUID, NSView)] = frames.map { ($0.key, $0.value as NSView) } + empties.map { ($0.key, $0.value as NSView) }
        return views.first { k, v in
            k != id && root.contains(k) && v.window === view.window && !v.isHiddenOrHasHiddenAncestor && v.bounds.contains(v.convert(p, from: nil))
        }?.0
    }
    private func paneHeaderDrag(_ id: UUID, _ ph: HeaderGrip.Phase, _ p: NSPoint) {
        let title = store.conversation(id)?.title ?? ""
        let over = tabBar.containsWindowPoint(p)
        let target = over ? nil : swapTarget(id, at: p)
        if ph == .began {
            // 跟著滑鼠走的小名牌
            let l = NSTextField(labelWithString: "  \(title)  ")
            l.font = .systemFont(ofSize: 12 * UIScale.shared.f, weight: .medium)
            l.textColor = .white
            l.drawsBackground = true
            l.backgroundColor = accent.withAlphaComponent(0.9)
            l.wantsLayer = true
            l.layer?.cornerRadius = 5
            l.layer?.masksToBounds = true
            l.sizeToFit()
            view.addSubview(l, positioned: .above, relativeTo: nil)
            tearLabel = l
        }
        if ph == .ended {
            tearLabel?.removeFromSuperview()
            tearLabel = nil
            swapMark?.removeFromSuperview()
            swapMark = nil
            tabBar.showTear(nil, accent: accent)
            if over { tearOff(id) }
            else if let target { swapPanes(id, target) }
            return
        }
        if let l = tearLabel {
            let q = view.convert(p, from: nil)
            l.frame.origin = NSPoint(x: q.x + 14, y: q.y - l.frame.height - 6)
        }
        tabBar.showTear(over ? title : nil, accent: accent)
        // 停在另一格上：那格蓋一層「放開＝互換位置」
        let tv: NSView? = target.flatMap { frames[$0] ?? empties[$0] }
        if let tv {
            if swapMark?.superview !== tv {
                swapMark?.removeFromSuperview()
                let m = SwapMark(accent: accent)
                m.frame = tv.bounds
                m.autoresizingMask = [.width, .height]
                tv.addSubview(m, positioned: .above, relativeTo: nil)
                swapMark = m
            }
        } else {
            swapMark?.removeFromSuperview()
            swapMark = nil
        }
        if let l = tearLabel { l.superview?.addSubview(l, positioned: .above, relativeTo: nil) }   // 名牌永遠在最上面
    }

    /// 兩格互換位置；焦點跟著拖的那格
    private func swapPanes(_ a: UUID, _ b: UUID) {
        store.editWindow { w in
            w.root = w.root?.swapping(a, b)
            w.focused = a
        }
    }

    /// 這格搬到一個新的 Window 分頁（名字先跟這格的聊天室一樣，之後可以改）
    private func tearOff(_ id: UUID) {
        guard let w = store.currentWindow, (w.root?.leaves.count ?? 0) > 1 else { return }
        let title = store.conversation(id)?.title ?? ""
        store.newWindow(with: id)
        if let nw = store.currentWindow, !title.isEmpty { store.renameWindow(nw.id, to: title) }
    }

    private func hideDropTargets() {
        overlays.forEach { $0.removeFromSuperview() }
        overlays = []
        overlayTimer?.invalidate()
        overlayTimer = nil
    }

    /// 某段對話的畫面換掉了（聊天↔終端機）：下次重畫時重建那格
    func invalidate(_ id: UUID) {
        frames[id]?.removeFromSuperview()
        frames[id] = nil
        shownKey = ""
        render()
    }

    private func build(_ n: PaneNode, path: [Bool], windowID: UUID) -> NSView {
        switch n {
        case .leaf(let id):
            if let f = frames[id] { return f }
            guard let c = store.conversation(id) else {
                if let e = empties[id] { return e }
                let e = EmptyPaneView(slot: id)
                e.onAdd = { [weak self] v in self?.store.setFocus(id); self?.onEmptyAdd?(id, v) }
                e.onClose = { [weak self] in self?.store.setFocus(id); self?.store.closePane(); Store.emptySlots.remove(id) }
                empties[id] = e
                return e
            }
            let pane = workspace.pane(for: c)
            pane.removeFromSuperview()
            pane.autoresizingMask = [.width, .height]
            let f = PaneFrame(conversation: id, content: pane)
            f.onClose = { [weak self] in self?.store.setFocus(id); self?.store.closePane() }
            f.onHeaderClick = { [weak self] in self?.store.setFocus(id) }
            f.onHeaderDrag = { [weak self] ph, p in self?.paneHeaderDrag(id, ph, p) }
            frames[id] = f
            return f
        case .split(let v, let r, let a, let b):
            return SplitBox(vertical: v, ratio: r, a: build(a, path: path + [false], windowID: windowID),
                            b: build(b, path: path + [true], windowID: windowID)) { [weak self] ratio in
                guard let self else { return }
                // 拖的時候不重畫整棵樹：直接改存的比例，key 一起更新
                self.store.editWindowQuietly(windowID) { w in w.root = w.root?.settingRatio(path: path, Double(ratio)) }
                if let w = self.store.currentWindow {
                    self.shownKey = "\(w.id)|\(String(describing: w.zoomed ? w.focused.map { PaneNode.leaf($0) } : w.root))"
                }
            }
        }
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}

extension Store {
    /// 改某個 Window 但不觸發選取同步（拖分隔線時用）
    func editWindowQuietly(_ id: UUID, _ f: (inout WindowLayout) -> Void) {
        for si in sessions.indices {
            if let wi = sessions[si].windows.firstIndex(where: { $0.id == id }) { f(&sessions[si].windows[wi]); return }
        }
    }
}

extension Store {
    /// 把對話放到某格旁邊（edge＝nil：換掉那格的對話）
    func place(_ conv: UUID, near target: UUID, edge: DropOverlay.Edge?) {
        guard conv != target else { return }
        if let (si, wi) = locate(conv) {
            sessions[si].windows[wi].root = sessions[si].windows[wi].root?.removing(conv)
            if sessions[si].windows[wi].focused == conv { sessions[si].windows[wi].focused = sessions[si].windows[wi].root?.leaves.first }
        }
        editWindow { w in
            guard let root = w.root, root.contains(target) else { w.root = .leaf(conv); w.focused = conv; return }
            let node: PaneNode
            switch edge {
            case nil: node = .leaf(conv)
            case .left?: node = .split(vertical: false, ratio: 0.5, a: .leaf(conv), b: .leaf(target))
            case .right?: node = .split(vertical: false, ratio: 0.5, a: .leaf(target), b: .leaf(conv))
            case .top?: node = .split(vertical: true, ratio: 0.5, a: .leaf(conv), b: .leaf(target))
            case .bottom?: node = .split(vertical: true, ratio: 0.5, a: .leaf(target), b: .leaf(conv))
            }
            w.root = root.replacing(target, with: node)
            w.focused = conv
            w.zoomed = false
        }
    }
}

/// 右側欄位的底：左邊一條細線跟 Pane 隔開
final class PetColumnView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
}
