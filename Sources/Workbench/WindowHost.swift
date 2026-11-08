import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let rightPanelToggleWillBegin = Notification.Name("AIWorkbenchRightPanelToggleWillBegin")
    static let rightPanelToggled = Notification.Name("AIWorkbenchRightPanelToggled")
}

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
    /// 滑鼠停在標題上 0.8 秒要顯示的資訊（標籤、內容）；nil＝不顯示
    var infoProvider: (() -> [(String, String)])?
    private let infoCard = InfoCard()
    private var hoverTimer: Timer?
    static let hoverDelay: TimeInterval = 0.8
    var showsHeader = false { didSet { header.isHidden = !showsHeader; closeButton.isHidden = !showsHeader; grip.isHidden = !showsHeader; if !showsHeader { hideInfo() }; updateRing(); needsLayout = true } }
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
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("關掉這格"))?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = L("關掉這格（Ctrl+A x）；對話會留在側欄")
        grip.toolTip = L("按住標題拖：拖到上面的分頁列＝變成新的分頁；拖到另一格的某一邊＝放在那一邊；按住 ⌘ 拖到另一格＝兩格互換")
        grip.onDrag = { [weak self] ph, p in self?.onHeaderDrag?(ph, p) }
        grip.onClick = { [weak self] in self?.onHeaderClick?(); self?.hideInfo() }
        grip.onHover = { [weak self] inside in inside ? self?.scheduleInfo() : self?.hideInfo() }
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

    // MARK: 停在標題上 0.8 秒：在標題下方淡入一張資訊小卡（0.15 秒、邊框閃一下），移開淡出
    private func scheduleInfo() {
        hoverTimer?.invalidate()
        guard infoProvider != nil, showsHeader else { return }
        let t = Timer(timeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in self?.showInfo() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }
    func showInfo() {
        hoverTimer?.invalidate(); hoverTimer = nil
        guard let rows = infoProvider?(), !rows.isEmpty, showsHeader else { return }
        infoCard.set(rows: rows, accent: accent)
        let w = min(max(160, bounds.width - 28), 380)
        infoCard.frame = NSRect(x: 14, y: bounds.height - Self.headerHeight - 6 - infoCard.height(for: w), width: w, height: infoCard.height(for: w))
        if infoCard.superview == nil { addSubview(infoCard) } else { addSubview(infoCard, positioned: .above, relativeTo: nil) }
        infoCard.fadeIn()
    }
    func hideInfo() {
        hoverTimer?.invalidate(); hoverTimer = nil
        infoCard.fadeOut()
    }
    /// 測試用：假裝滑鼠進來／離開標題
    func testHover(_ inside: Bool) { grip.onHover?(inside) }
    /// 測試用：卡片現在的狀態
    var infoState: String { "卡片 alpha=\(String(format: "%.2f", infoCard.layer?.presentation()?.opacity ?? Float(infoCard.alphaValue))) 在畫面=\(infoCard.superview != nil && !infoCard.isHidden) 列=\(infoCard.rowCount)" }

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
        // 框永遠在最上面（拖放接收區除外：那是之後才加的，會在它上面）；資訊小卡在框的上面
        if subviews.last !== ring, !subviews.contains(where: { $0 is DropOverlay }) { addSubview(ring, positioned: .above, relativeTo: nil) }
        if infoCard.superview != nil, subviews.last !== infoCard { addSubview(infoCard, positioned: .above, relativeTo: nil) }
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
    /// 滑鼠進來（true）／離開（false）：停留資訊小卡用
    var onHover: ((Bool) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { onHover?(true) }
    override func mouseExited(with e: NSEvent) { onHover?(false) }
    override func mouseDown(with e: NSEvent) {
        onHover?(false)      // 按下去（點、拖）就收掉小卡
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

/// 掛件格子從右邊彈進來／滑出去。
/// 動的是「這格露出多少」s（0＝全在右邊外面、1＝在版面上的位置）：外層切口的比例跟著 s 走，原本的格子同時讓出／長回空間；
/// 掛件格子本身維持最後的寬度、只往左右移（網頁不會跟著一直改寬度）。狀態放這裡，不放在 SplitBox：版面重建也接得上。
final class PaneSlide {
    static let shared = PaneSlide()
    enum Kind { case slideIn, slideOut }
    private struct Anim { var kind: Kind; var start: Date; var from: Double; var v0: Double; var done: (() -> Void)? }
    private var anims: [UUID: Anim] = [:]
    private var timer: Timer?
    /// 每一格畫面要重排時通知每個 WindowHost（主視窗和獨立視窗各自登記；以前只有一個 onTick，只綁第一個開的視窗，
    /// 獨立視窗裡的掛件滑進來會卡在右緣外面，第一個視窗關掉後就沒人接）
    private final class Listener { weak var owner: AnyObject?; let f: () -> Void; init(_ o: AnyObject, _ f: @escaping () -> Void) { owner = o; self.f = f } }
    private var listeners: [Listener] = []
    func listen(_ owner: AnyObject, _ f: @escaping () -> Void) {
        listeners.removeAll { $0.owner == nil || $0.owner === owner }
        listeners.append(Listener(owner, f))
    }
    func notify() {
        listeners.removeAll { $0.owner == nil }
        listeners.forEach { $0.f() }
    }
    /// 測試用：所有動畫停在第幾秒（--pane-slide）
    var frozen: Double?

    // 彈進來：彈簧（response 0.35 秒、damping 0.75，帶一點點過衝）；滑出去：ease-in 0.2 秒、不過衝
    static let response = 0.35, damping = 0.75, outDuration = 0.2
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 正在滑出去的（版面上還在，但當作已經收起來）
    func isLeaving(_ id: UUID) -> Bool { anims[id]?.kind == .slideOut }

    /// 彈進來；正在滑出去的就從目前位置反轉
    func slideIn(_ id: UUID) {
        guard !Self.reduceMotion else { anims[id] = nil; notify(); return }
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
        notify()
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
        notify()
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
    /// 拖到主視窗外面放開：(位置, 螢幕座標)
    var onDetach: ((Int, NSPoint) -> Void)?
    /// 拖著分頁在視窗外面／回到裡面：(位置, 螢幕座標, 現在在外面嗎)；放開時也會再叫一次（外面＝false 表示取消）
    var onOutside: ((Int, NSPoint, Bool) -> Void)?
    var onNew: (() -> Void)?
    /// 點總指揮方塊（總指揮沒在分頁列上時；在的話走 onSelect(0)）
    var onChief: (() -> Void)?
    /// 0＝一般；1＝第 0 個分頁是總指揮 Window（畫成最左邊的紫色方塊、不能關、不能換順序，只能拉出去）；2＝總指揮沒在分頁列上，方塊獨立放最左邊
    private(set) var chiefMode = 0
    private var chiefVirtual: TabButton?
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
    // 沒有按鈕、分頁的空白處：按住拖整個視窗、點兩下放大（＋ 右邊那一大塊也要能拖）
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { DragHandle.moveWindow(e, window) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 用 layer：拖曳時滑鼠事件迴圈還在跑，分頁滑開／放下的動畫交給 Core Animation 才會一格一格動
        wantsLayer = true
        // 收起／打開左邊的側欄（⌃ ⌘ S）：聊天區太擠的時候整條收到最左邊
        sideButton.isBordered = false
        sideButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L("側欄"))?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        sideButton.contentTintColor = .secondaryLabelColor
        sideButton.target = self
        sideButton.action = #selector(toggleSidebar)
        sideButton.toolTip = L("收起／打開側欄（⌃ ⌘ S）")
        // 分頁列最左邊的收起側欄按鈕拿掉了：收起／打開側欄只靠 F3（或選單的 ⌃ ⌘ S）；sideButton 只留著排版的位置，不加進畫面
        dragHandle.toolTip = L("按住拖動視窗，點兩下放大")
        addSubview(dragHandle)
        sessionButton.bezelStyle = .inline
        sessionButton.isBordered = false
        sessionButton.target = self
        sessionButton.action = #selector(showSessions)
        sessionButton.toolTip = L("換 Session（Ctrl+A s）")
        addSubview(sessionButton)
        plus.isBordered = false
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("新 Window"))?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        plus.contentTintColor = .secondaryLabelColor
        plus.target = self
        plus.action = #selector(newTab)
        plus.toolTip = L("新 Window（Ctrl+A c）")
        addSubview(plus)
        tearGhost.isHidden = true
        addSubview(tearGhost)
        registerForDraggedTypes(ChatTextView.dropTypes)   // 拖檔案停在分頁上切 Window（見 springHover）
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 拖檔案停在分頁上：停 0.8 秒、閃兩下（每下 0.15 秒、中間隔 0.15 秒），第二下閃完切到那個 Window，再自己決定放進哪一格

    private var currentTab = 0
    private var springTab: Int?
    private var springTimers: [Timer] = []
    private var springFlash = false          // 現在是不是閃亮的那一下
    static let springDwell: TimeInterval = 0.8, springFlashOn: TimeInterval = 0.15, springFlashGap: TimeInterval = 0.15

    private func cancelSpring() {
        springTimers.forEach { $0.invalidate() }; springTimers = []
        if springFlash { springFlash = false; if let old = springTab, old < buttons.count { (buttons[old] as? TabButton)?.flashing = false } }
    }
    private func after(_ t: TimeInterval, _ f: @escaping () -> Void) {
        let timer = Timer(timeInterval: t, repeats: false) { _ in f() }
        RunLoop.main.add(timer, forMode: .common)   // 拖曳中的事件迴圈不跑一般模式的計時器
        springTimers.append(timer)
    }

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
        cancelSpring()
        if let old = springTab, old < buttons.count { (buttons[old] as? TabButton)?.springing = false }
        springTab = i
        guard let i else { return }
        (buttons[i] as? TabButton)?.springing = true
        let d = Self.springDwell, on = Self.springFlashOn, gap = Self.springFlashGap
        func flash(_ v: Bool) { guard self.springTab == i else { return }; Self.springLog.append((v ? "亮" : "滅", CACurrentMediaTime())); self.springFlash = v; (self.buttons.indices.contains(i) ? self.buttons[i] as? TabButton : nil)?.flashing = v }
        Self.springLog = [("開始", CACurrentMediaTime())]
        after(d) { flash(true) }                         // 第一下
        after(d + on) { flash(false) }
        after(d + on + gap) { flash(true) }              // 第二下
        after(d + 2 * on + gap) { [weak self] in         // 第二下閃完：切過去
            guard let self, self.springTab == i else { return }
            flash(false)
            self.springTab = nil; self.springTimers = []
            (self.buttons.indices.contains(i) ? self.buttons[i] as? TabButton : nil)?.springing = false
            Self.springLog.append(("切換", CACurrentMediaTime()))
            self.onSelect?(i)
        }
    }
    /// 測試用：彈簧事件的時間記錄（亮、滅、切換）
    static var springLog: [(String, CFTimeInterval)] = []
    /// 測試用：分頁的目前狀態（springing＝在等、flashing＝閃亮的那一下）
    func springState() -> String { buttons.enumerated().map { i, b in (b as? TabButton).map { "\(i):\($0.springing ? "等" : "-")\($0.flashing ? "亮" : "")" } ?? "" }.joined(separator: " ") }

    /// 測試用：游標停在第 i 個分頁的中間（nil＝離開）
    func springHover(tab i: Int?) {
        springHover(at: i.flatMap { $0 < buttons.count ? NSPoint(x: buttons[$0].frame.midX, y: buttons[$0].frame.midY) : nil })
    }
    /// 測試用：每個分頁在螢幕上的位置
    func tabScreenRects() -> [NSRect] { buttons.compactMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } } }

    /// 分頁上不放「做完沒看」的小藍點：只看側欄（點側欄那段對話會跳到它在的分頁；分頁也亮的話，跳過去之後舊分頁亮著會以為標錯，要拿掉）
    /// 滑鼠按在分頁上（點、拖、拉進畫面）的期間：分頁按鈕不要重建。聊天串流時 store 一直變、render 一直叫 update，
    /// 重建會把手上正在拖的那顆換掉（放開時找不到它：換順序失效、拉進畫面的藍色遮罩收不掉），新按鈕拖曳中也不排版（整排看起來消失）
    fileprivate var held = false
    private var deferredUpdate: (() -> Void)?
    fileprivate func flushDeferred() {
        guard !held, dragging == nil, let f = deferredUpdate else { return }
        deferredUpdate = nil
        f()
    }

    func update(session: String, tabs: [String], current: Int, accent: NSColor, chiefMode: Int = 0) {
        if held || dragging != nil {
            deferredUpdate = { [weak self] in self?.update(session: session, tabs: tabs, current: current, accent: accent, chiefMode: chiefMode) }
            return
        }
        deferredUpdate = nil     // 這次是最新的：之前壓著的舊參數不要再套（不然換完順序又被舊的蓋回去）
        currentTab = current
        // 聊天進行中 store 一直變、這裡一直重建：分頁還是同一排就讓計時繼續跑，不然永遠等不到 1.5 秒
        if let i = springTab, tabs.count != buttons.count || i == current {
            cancelSpring(); springTab = nil
        }
        sessionButton.attributedTitle = NSAttributedString(string: " Session \(session) ", attributes: [
            .font: NSFont.systemFont(ofSize: 12 * UIScale.shared.f, weight: .semibold), .foregroundColor: NSColor.white,
            .backgroundColor: accent.withAlphaComponent(0.85)])
        self.chiefMode = chiefMode
        buttons.forEach { $0.removeFromSuperview() }
        chiefVirtual?.removeFromSuperview(); chiefVirtual = nil
        let num = chiefMode == 2 ? 2 : 1       // 總指揮方塊獨立在外面時，第一個分頁是 ⌘ 2
        buttons = tabs.enumerated().map { i, t in
            let isChief = chiefMode == 1 && i == 0
            let b = TabButton(index: i, title: t.isEmpty ? "[\(i + num)]" : "[\(i + num)] \(t)", selected: i == current, accent: accent, chief: isChief)
            b.toolTip = isChief ? L("總指揮（⌘ 1）") : L("點兩下改名（Ctrl+A ,）")
            b.onClick = { [weak self] in self?.onSelect?(i) }
            b.onDoubleClick = { [weak self] in self?.onRename?(i) }
            b.onClose = { [weak self] in self?.onClose?(i) }
            b.springing = i == springTab
            b.flashing = i == springTab && springFlash
            addSubview(b)
            return b
        }
        if chiefMode == 2 {
            let v = TabButton(index: -1, title: "", selected: false, accent: accent, chief: true)
            v.toolTip = L("總指揮（⌘ 1）")
            v.onClick = { [weak self] in self?.onChief?() }
            addSubview(v)
            chiefVirtual = v
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // 側欄收起來時這條貼到視窗最左邊：讓開左上角的紅黃綠按鈕
        let atLeftEdge = convert(NSPoint.zero, to: nil).x < 40
        var x: CGFloat = atLeftEdge ? 80 : 8
        // 收起側欄的按鈕拿掉了：這裡留一小塊空白，按住可以拖動整個視窗
        dragHandle.frame = NSRect(x: x, y: 0, width: 44, height: bounds.height)
        x += 44
        // 總指揮模式：左欄已經標出目前在哪個總指揮（＝Session），頂端不再放「Session ○○」
        sessionButton.isHidden = Prefs.shared.sidebarMode == "commander"
        if !sessionButton.isHidden {
            let s = sessionButton.intrinsicContentSize
            sessionButton.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            x += s.width + 10
        }
        // 先留 + 的位置（22 寬＋前後空隙），分頁再平分剩下的；太擠就一起變窄（最窄 56），不要壓到 +
        // 總指揮方塊：整條分頁列最左邊、約分頁高度的正方形（mode 1 它就是第 0 個分頁、mode 2 是獨立的一塊）
        let sq = bounds.height - 8
        if let v = chiefVirtual { v.frame = NSRect(x: x, y: 4, width: sq, height: sq); x += sq + 4 }
        let lead = chiefMode == 1 ? 1 : 0
        let room = bounds.width - x - 36 - (chiefMode == 1 ? sq + 4 : 0)
        let n = CGFloat(max(1, buttons.count - lead))
        let each = buttons.count <= lead ? 0 : min(220, max(56, (room - 4 * (n - 1)) / n))
        slotW = each
        slotX = []
        for (i, b) in buttons.enumerated() {
            slotX.append(x)
            let w = i < lead ? sq : each
            if dragging == nil { b.frame = NSRect(x: x, y: 4, width: w, height: bounds.height - 8) }
            x += w + 4
        }
        if !tearGhost.isHidden {
            let gw = min(220, max(120, each > 0 ? each : 160))
            tearGhost.frame = NSRect(x: x, y: 4, width: gw, height: bounds.height - 8)
            x += gw + 4
        }
        plus.frame = NSRect(x: min(x + 2, bounds.width - 28), y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    /// 拖 Pane 標題到分頁列上：顯示／收起最後面的「＋ 名字」預覽分頁
    /// 分頁被拉走：在原位留一張它的影像，縮小淡出（不要直接消失）
    func collapseGhost(of index: Int) {
        guard buttons.indices.contains(index) else { return }
        let b = buttons[index]
        guard let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return }
        b.cacheDisplay(in: b.bounds, to: rep)
        let img = NSImage(size: b.bounds.size); img.addRepresentation(rep)
        let ghost = NSImageView(frame: b.frame)
        ghost.image = img
        ghost.imageScaling = .scaleAxesIndependently
        addSubview(ghost)
        if Motion.reduced {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; ghost.animator().alphaValue = 0 }, completionHandler: { ghost.removeFromSuperview() })
        } else {
            var f = b.frame; f.size.width = 0
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.22; ghost.animator().frame = f; ghost.animator().alphaValue = 0 }, completionHandler: { ghost.removeFromSuperview() })
        }
    }
    /// 新回來的分頁（第 index 個）亮一下
    func flashTab(_ index: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.buttons.indices.contains(index) else { return }
            let b = self.buttons[index]
            let v = NSView(frame: b.frame)
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            v.layer?.cornerRadius = 6
            self.addSubview(v)
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.7; v.animator().alphaValue = 0 }, completionHandler: { v.removeFromSuperview() })
        }
    }
    /// 「＋」按鈕的中心（螢幕座標）：獨立視窗關掉時飛向新分頁的位置（新分頁排在最後，就在這附近）
    func plusScreenCenter() -> NSPoint? {
        guard let w = window else { return nil }
        return w.convertPoint(toScreen: convert(NSPoint(x: plus.frame.midX, y: plus.frame.midY), to: nil))
    }
    func isOutsideWindow(_ p: NSPoint, _ w: NSWindow) -> Bool {
        let r = NSRect(origin: .zero, size: w.frame.size).insetBy(dx: -4, dy: -4)
        return !r.contains(p)
    }
    func index(of b: NSView) -> Int? { buttons.firstIndex { $0 === b } }
    /// 拖曳被打斷（視窗失去焦點、換螢幕、放開的訊息沒送到）：分頁的半透明、陰影、位移都還原
    func cancelDrag() {
        dragTarget = nil
        dragging = nil
        for b in buttons { b.alphaValue = 1; b.layer?.shadowOpacity = 0 }
        DispatchQueue.main.async { [weak self] in self?.flushDeferred() }
        showTear(nil, accent: tearGhost.accent)
        needsLayout = true
    }
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
        let lo = chiefMode == 1 ? 1 : 0       // 總指揮方塊固定在最前面：別的分頁不能排到它前面
        guard buttons.count > lo else { return }
        let x = max(slotX[lo], min(slotX[slotX.count - 1], slotX[from] + dx))
        b.frame.origin.x = x
        let step = slotW + 4
        let to = max(lo, min(buttons.count - 1, from + Int(((x - slotX[from]) / step).rounded())))
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
        guard let from, let to, slotX.indices.contains(to) else { dragging = nil; needsLayout = true; flushDeferred(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            b.animator().frame.origin.x = slotX[to]
            b.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            b.layer?.shadowOpacity = 0
            self?.dragging = nil
            if to != from { self?.onMove?(from, to) } else { self?.needsLayout = true }
            self?.flushDeferred()
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
        if let f = onSessions { return f(sessionButton.isHidden ? self : sessionButton) }
        guard let m = sessionMenu?() else { return }
        let anchor: NSView = sessionButton.isHidden ? self : sessionButton    // 藏起來時（總指揮模式）從分頁列左邊彈出
        m.popUp(positioning: nil, at: NSPoint(x: sessionButton.isHidden ? 52 : 0, y: anchor.bounds.height + 2), in: anchor)
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
    private let label = NSTextField(labelWithString: L("放開＝互換位置"))
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
    private var hover = false { didSet { x.isHidden = chief || !(hover || selected); needsDisplay = true } }
    /// 總指揮方塊：整塊填滿主題色、沒有名字、沒有 ×
    let chief: Bool
    /// 拖著檔案停在這個分頁上、等著切過來：整個分頁亮主題色
    var springing = false { didSet { needsDisplay = true } }
    /// 閃亮的那一下（主題色重一點）
    var flashing = false { didSet { needsDisplay = true } }
    private let accent: NSColor
    init(index: Int, title: String, selected: Bool, accent: NSColor, chief: Bool = false) {
        self.selected = selected; self.accent = accent; self.chief = chief
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 12 * UIScale.shared.f, weight: selected ? .semibold : .regular)
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        x.isBordered = false
        x.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("關掉這個 Window"))?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        x.contentTintColor = .tertiaryLabelColor
        x.target = self
        x.action = #selector(closeTab)
        x.toolTip = L("關掉這個 Window（Ctrl+A &）")
        x.isHidden = chief || !selected
        addSubview(x)
        label.isHidden = chief
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
        if chief {
            let p = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            accent.withAlphaComponent(springing ? (flashing ? 0.75 : 0.5) : (selected || hover ? 1 : 0.8)).setFill()
            p.fill()
            if selected { p.lineWidth = 2; NSColor.white.withAlphaComponent(0.85).setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).stroke() }
            return
        }
        if springing {
            accent.withAlphaComponent(flashing ? 0.75 : 0.18).setFill()
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
        if e.clickCount == 2 && !chief { onDoubleClick?(); return }
        guard let bar = superview as? TabBar, let w = window, !(chief && bar.index(of: self) == nil) else { onClick?(); return }
        // 放開前沒拖超過 4 點：就是點一下（切到這個 Window）
        // 左右拖＝換順序；往下拖出分頁列＝把這個 Window（只有一格的）拉進目前畫面的左／右／上／下半
        bar.held = true
        defer { bar.held = false; bar.flushDeferred() }
        let start = e.locationInWindow
        var dragging = false, pulling = false
        var last = start
        while let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            last = ev.locationInWindow
            if ev.type == .leftMouseUp { break }
            let dx = last.x - start.x
            if !dragging && abs(dx) < 4 && abs(last.y - start.y) < 4 { continue }
            dragging = true
            if let i = bar.index(of: self) { bar.onOutside?(i, w.convertPoint(toScreen: last), bar.isOutsideWindow(last, w)) }
            let below = bar.convert(last, from: nil).y < -6
            pullDebug("move \(last) barY=\(bar.convert(last, from: nil).y) below=\(below) pulling=\(pulling)")
            // 一旦拉出去就一直是「拉進畫面」，直到放開（放回分頁列上＝取消）
            if (pulling || below), bar.pull(self, at: last) { pulling = true; continue }
            if !chief { bar.drag(self, dx: dx) }       // 總指揮方塊不能換順序，只能拉出去變獨立視窗
        }
        pullDebug("up \(last) pulling=\(pulling) dragging=\(dragging)")
        // 拖到視窗外面放開：這個 Window 變成獨立視窗（只有聊天格，沒有側欄和用量欄）
        if dragging, bar.isOutsideWindow(last, w), let i = bar.index(of: self) {
            bar.collapseGhost(of: i)
            bar.cancelDrag()
            bar.onDetach?(i, w.convertPoint(toScreen: last))
            return
        }
        if dragging, let i = bar.index(of: self) { bar.onOutside?(i, w.convertPoint(toScreen: last), false) }
        if pulling { bar.pullEnd(self, at: last) } else if dragging { if !chief { bar.drop(self) } } else { onClick?() }
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
    private let placeholder = NSTextField(labelWithString: L("左邊選一個對話，或按「新對話」（⌘ N）"))
    private var frames: [UUID: PaneFrame] = [:]
    private var shownKey = ""
    private var bag: Set<AnyCancellable> = []
    private var lastRenderedWindow: UUID?
    private var lastRenderedFocus: UUID?
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
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
    var petEmbed: PetEmbedView { petView.embed }
    var petColumnWidth: CGFloat { petColumnVisible ? petColumn.frame.width : 0 }
    /// 右欄有沒有在畫面上。收起來只是隱藏、不從視窗拿掉：SwiftUI 的看板／清單一進出視窗就同步重建整張圖（實測 250ms 一次停頓），按 F4 會卡頓
    private var petColumnVisible: Bool { petColumn.superview != nil && !petColumn.isHidden }
    private func mountPetColumn() {
        if petColumn.superview !== view { view.addSubview(petColumn) }
        petColumn.isHidden = false
    }
    private func retirePetColumn() { if petColumn.superview != nil { petColumn.isHidden = true } }
    /// 中間聊天欄在螢幕上的範圍
    var chatScreenRect: NSRect? { body.window.map { $0.convertToScreen(body.convert(body.bounds, to: nil)) } }
    private lazy var timersHost = PetTimersHost(rootView: PetTimersView())
    /// 右側欄位：上面放用量（token），最下面是桌寵格子；所有 Pane 都在它左邊
    private let petColumn = PetColumnView()
    private var petColumnProgress: CGFloat?
    private var petColumnAnimationTimer: Timer?
    private var petColumnTogglePending = false
    private struct PetColumnAnimation {
        let from: CGFloat
        let to: CGFloat
        let start: TimeInterval
        let width: CGFloat
        let boundsSize: CGSize
    }
    private var petColumnAnimation: PetColumnAnimation?
    private lazy var usageView: NSHostingView<Scaled<UsagePanel>> = {
        let v = NSHostingView(rootView: Scaled { UsagePanel(m: UsageMonitor.shared, store: self.store, compact: { [weak self] id in self?.onCompact?(id) }) })
        v.clipsToBounds = true      // macOS 14 起預設不裁切：內容比欄位高時不能畫到下面的桌寵格裡
        return v
    }()
    var onCompact: ((UUID) -> Void)?
    /// 總指揮模式的右欄（RightPanelView.swift）：取代上面的用量欄；協作看板的暫停動作由 MainWindowController 接
    var onCollabPause: ((CollabPair) -> Void)?
    private lazy var rightPanelView: NSHostingView<Scaled<RightPanelView>> = {
        let v = NSHostingView(rootView: Scaled { RightPanelView(store: self.store, workspace: self.workspace, pause: { [weak self] p in self?.onCollabPause?(p) }) })
        v.clipsToBounds = true
        return v
    }()
    private var commanderRight: Bool { Prefs.shared.sidebarMode == "commander" }
    /// 右欄上半：總指揮模式用 RightPanelView，原本的樹模式用用量欄
    private var topColumnView: NSView { commanderRight ? rightPanelView : usageView }
    private func attachTopColumn() {
        let on = topColumnView      // 沒用到的那個不去碰（lazy 不會白建一份）
        for v in petColumn.subviews where v !== on && v !== petView { v.removeFromSuperview() }
        if on.superview !== petColumn { petColumn.addSubview(on) }
    }
    /// 桌寵空位的高度：總指揮模式可以關掉（右欄分頁列右邊的小腳印）
    private func petSlotHeight(_ size: NSSize, _ h: CGFloat) -> CGFloat {
        commanderRight && !RightPanelModel.shared.petSlotOn ? 0 : min(size.height, h)
    }
    /// 右欄寬度：樹模式＝桌寵格的寬；總指揮模式至少是右欄自己記的寬度（可拖左緣調整）
    private func columnRoom(_ size: NSSize) -> CGFloat {
        // 總指揮的右欄寬度只由左緣分隔線決定；桌寵框的大小設定（把手）不能把右欄撐寬
        let want = commanderRight ? RightPanelModel.shared.width : size.width
        return min(want, max(0, view.bounds.width - 300))
    }

    /// 獨立視窗用：只畫這一個 Window 的格子（沒有分頁列、用量欄、桌寵格）；nil＝主視窗那個
    let boundWindow: UUID?
    /// 分頁拉到視窗外面放開（位置編號是主視窗分頁列上的、螢幕座標）：由 MainWindow 開獨立視窗
    var onDetach: ((Int, NSPoint) -> Void)?
    private var barH: CGFloat { boundWindow == nil ? Self.barHeight : 0 }

    init(store: Store, workspace: Workspace, boundWindow: UUID? = nil) {
        self.store = store
        self.workspace = workspace
        self.boundWindow = boundWindow
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
        tabBar.onSelect = { [weak self] i in self?.store.toggleWindowSelection(at: i) }   // 點分頁＝選取整個 Window，再點同一個＝回原本那格
        tabBar.onChief = { [weak self] in self?.store.summonChief() }
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
            if self.store.isChiefProtected(si, i) { return false }      // 總指揮 Window 不能拉進別的畫面（只能拉出成獨立視窗）
            return w.id != self.store.currentWindow?.id && w.root?.leaves.count == 1 && w.root.flatMap { $0.leaves.first }.flatMap { self.store.conversation($0) } != nil
        }
        tabBar.onPull = { [weak self] _, p in self?.pullHover(p) }
        tabBar.onPullEnd = { [weak self] i, p in self?.pullEnd(i, p) }
        tabBar.onOutside = { [weak self] i, p, out in self?.dragOutside(i, p, out) }
        tabBar.onDetach = { [weak self] i, p in self?.resetTransientDragState(); self?.onDetach?(i, p) }
        tabBar.onNew = { [weak self] in self?.onNewWindow?() }
        tabBar.sessionMenu = { [weak self] in self?.sessionMenu?() ?? NSMenu() }
        // 版面或對話標題變了就重畫（合併成一次）
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &bag)
        // 所有視窗（包含獨立視窗）都丟掉瀏覽器的外框快取，再依原樹、原比例換成網頁或占位。
        observers.append(NotificationCenter.default.addObserver(forName: Prefs.webFeaturesChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for id in self.frames.keys.filter({ self.store.conversation($0)?.isBrowser == true }) {
                self.frames.removeValue(forKey: id)?.removeFromSuperview()
            }
            self.shownKey = ""
            self.render()
        })
        // 桌寵空位：開關、調大小、換螢幕都重排
        petView.onResize = { [weak self] size in PetSlot.setSize(size, on: self?.view.window?.screen) }
        // 總指揮模式的右欄：左緣可以拖寬度；左欄模式切換時換掉右欄上半
        petColumn.onResizeWidth = { [weak self] w in
            guard let self, self.commanderRight else { return }
            RightPanelModel.shared.width = w
            self.layoutPetSlot()
        }
        petColumn.resizable = { [weak self] in self?.commanderRight == true }
        Prefs.shared.$sidebarMode.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.layoutPetSlot() }.store(in: &bag)
        observers.append(NotificationCenter.default.addObserver(forName: PetSlot.changed, object: nil, queue: .main) { [weak self] _ in self?.layoutPetSlot() })
        observers.append(NotificationCenter.default.addObserver(forName: .rightPanelToggleWillBegin, object: nil, queue: .main) { [weak self] _ in self?.petColumnTogglePending = true })
        observers.append(NotificationCenter.default.addObserver(forName: .rightPanelToggled, object: nil, queue: .main) { [weak self] _ in self?.animatePetSlotToggle() })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] n in
            if (n.object as? NSWindow) === self?.view.window { self?.cancelPetColumnAnimation(); self?.layoutPetSlot(); self?.resetTransientDragState() }
        })
        // 拖曳到一半被切走（例如 Rectangle 的 ⌃ ⌥ 方向鍵換視窗／螢幕）：放開的訊息可能沒送到這裡，接收區和半透明的分頁會一直留著、看起來整個視窗變半透明。
        // 失去焦點、App 不在前景、換螢幕時一律收掉
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            if (n.object as? NSWindow) === self?.view.window { self?.resetTransientDragState() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resetTransientDragState()
        })
        // 文字大小改了：分頁列、格子標題跟著重畫
        UIScale.shared.$factor.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &bag)
        // 側欄開始拖對話：每一格蓋上接收區，放開（或拖去別處）就收起來
        observers.append(NotificationCenter.default.addObserver(forName: DropOverlay.began, object: nil, queue: .main) { [weak self] _ in self?.showDropTargets() })
        // 點到哪一格，那格就變成目前那格
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, e.window === self.view.window else { return e }
            self.store.scope = self.boundWindow      // 點在哪個視窗，之後的操作就落在哪個視窗的 Window 上
            // 選取整個 Window 的狀態下點到任何一格：回到單格
            if self.store.windowSelected {
                let inAny = self.frames.values.contains { $0.superview != nil && $0.bounds.contains($0.convert(e.locationInWindow, from: nil)) }
                    || self.empties.values.contains { $0.superview != nil && $0.bounds.contains($0.convert(e.locationInWindow, from: nil)) }
                if inAny { self.store.windowSelected = false }
            }
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
                        // 這 0.05 秒內又點了別格（或關了這格）：游標不要被拉回這裡（Astra 11/5：延遲的焦點動作要確認還是同一格）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak c] in
                            guard let self, let c, self.store.currentWindow?.focused == id, c.window != nil else { return }
                            c.focusInput()
                        }
                    }
                }
            }
            return e
        }
        render()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    /// 拖著分頁在視窗外面：游標旁邊跟著那個 Window 版面的縮圖預覽；拖回裡面或放開取消就淡出
    let detachPreview = DetachPreview()
    func testPreview(_ index: Int, at p: NSPoint) { dragOutside(index, p, true) }
    private func dragOutside(_ index: Int, _ screenPoint: NSPoint, _ out: Bool) {
        guard boundWindow == nil else { return }
        guard out else { detachPreview.hide(); return }
        guard let si = store.sessionIndex else { return }
        let visible = store.sessions[si].windows.filter { !$0.detached }
        guard visible.indices.contains(index), visible[index].root != nil else { return }    // 只有一個也能拉出去（主視窗補空 Window）；空的不給預覽
        let w = visible[index]
        let panes = (w.root?.rects() ?? [:]).map { (store.conversation($0.key)?.title ?? "", $0.value) }
        let base = view.window?.frame.size ?? NSSize(width: 1000, height: 700)
        let size = NSSize(width: max(220, base.width / 4), height: max(150, base.height / 4))
        detachPreview.show(title: w.renamed ? w.name : (w.focused.flatMap { store.conversation($0)?.title } ?? w.name), panes: panes, size: size, accent: accent, at: screenPoint)
    }

    /// 視窗座標的點落在哪一格（沒有＝nil）：⌥ 八宮格用來決定「這一格」
    func conversation(atWindowPoint p: NSPoint) -> UUID? {
        frames.first { $0.value.superview != nil && !$0.value.isHiddenOrHasHiddenAncestor && $0.value.bounds.contains($0.value.convert(p, from: nil)) }?.key
    }

    /// 版面重建時目前那格的輸入框會被重新掛上，焦點會掉回視窗本身（或沒有）：這種要交回；焦點在別的格也交回；
    /// 只有焦點在這個 WindowHost 外面（側欄、搜尋欄）才不搶
    private static func shouldReclaimFocus(_ r: NSResponder?, host: NSView, frame: NSView) -> Bool {
        guard let v = r as? NSView else { return true }
        return v.isDescendant(of: host) && !v.isDescendant(of: frame)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        tabBar.frame = NSRect(x: 0, y: b.height - barH, width: b.width, height: barH)
        tabBar.isHidden = boundWindow != nil
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
        if petColumnTogglePending { return }
        if let animation = petColumnAnimation, let progress = petColumnProgress {
            // F4 動畫進行中視窗內容區變大小（例如剛按 F3 收左欄，系統動畫一路在改寬度）：
            // 不取消、照新寬度接著滑，不然右欄會瞬間跳到終點
            let w = petColumnRoom()
            petColumnAnimation = PetColumnAnimation(from: animation.from, to: animation.to, start: animation.start, width: w, boundsSize: view.bounds.size)
            layoutPetColumn(progress: progress, width: w)
            return
        }
        cancelPetColumnAnimation()
        petColumnProgress = nil
        let on = PetSlot.enabled && boundWindow == nil
        let size = PetSlot.size(on: view.window?.screen)
        let b = view.bounds
        let h = b.height - barH
        // 右邊用量欄至少要這麼寬才放得下字；視窗窄到擠不出來就整欄先不畫（設定不動，寬了會自己回來），不要讓字被切掉（用 Rectangle 把視窗縮窄）
        let room = columnRoom(size)
        let show = on && room >= 190
        let colW = show ? room : 0
        for f in frames.values { (f.content as? any ConversationPane)?.petReserve = .zero }
        body.frame = NSRect(x: 0, y: 0, width: b.width - colW, height: h)
        body.subviews.first { $0 !== placeholder && !($0 is DropOverlay) }?.frame = body.bounds
        if show {
            mountPetColumn()
            if petView.superview !== petColumn { petColumn.addSubview(petView) }
            attachTopColumn()
            petColumn.frame = NSRect(x: b.width - colW, y: 0, width: colW, height: h)
            let slotH = petSlotHeight(size, h)
            petView.isHidden = slotH == 0
            petView.frame = NSRect(x: 0, y: 0, width: colW, height: slotH)
            // 計時器：桌寵空位左半（桌寵在右邊，不去蓋它）
            if timersHost.superview !== petView { petView.addSubview(timersHost) }
            PetTimers.shared.start()
            timersHost.frame = NSRect(x: 0, y: 0, width: floor(colW / 2), height: max(0, slotH - 6 - (slotH >= PetSlotView.termSize * 2 + 6 + 14 ? PetSlotView.termSize * 2 + 16 : slotH >= PetSlotView.termSize + 14 ? PetSlotView.termSize + 10 : 0)))
            topColumnView.frame = NSRect(x: 0, y: slotH, width: colW, height: max(0, h - slotH))
            petView.needsDisplay = true
            petColumn.needsDisplay = true
        } else {
            retirePetColumn()
        }
    }

    /// 只有 F4 切換桌寵欄時滑動；其他版面更新仍由 layoutPetSlot 立即排版。
    private func animatePetSlotToggle() {
        cancelPetColumnAnimation()
        petColumnTogglePending = false
        guard isViewLoaded, boundWindow == nil else { return }
        let enabled = PetSlot.enabled
        let b = view.bounds
        let size = PetSlot.size(on: view.window?.screen)
        // 寬度跟 layoutPetSlot 同一條算式（columnRoom）：總指揮模式的右欄寬是自己記的，不是桌寵格的寬；
        // 以前這裡用桌寵格的寬，動畫第一幀把右欄擠窄再彈回來，看板整份重排兩次（實測停頓 150ms 以上）
        let room = columnRoom(size)
        let show = enabled && room >= 190
        guard show || petColumnVisible else { layoutPetSlot(); return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { layoutPetSlot(); return }

        let from = petColumnProgress ?? (petColumnVisible ? 1 : 0)
        let to: CGFloat = show ? 1 : 0
        let width = room
        let animation = PetColumnAnimation(from: from, to: to, start: ProcessInfo.processInfo.systemUptime,
                                           width: width, boundsSize: b.size)
        petColumnAnimation = animation
        petColumnProgress = from
        layoutPetColumn(progress: from)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard var animation = self.petColumnAnimation else { timer.invalidate(); return }
            if self.view.bounds.size != animation.boundsSize {
                // 大小變了（左欄正在收合／展開）：寬度跟著更新，動畫照樣跑完
                animation = PetColumnAnimation(from: animation.from, to: animation.to, start: animation.start, width: self.petColumnRoom(), boundsSize: self.view.bounds.size)
                self.petColumnAnimation = animation
            }
            let tickStart = ProcessInfo.processInfo.systemUptime
            let t = min(1, (tickStart - animation.start) / 0.25)
            let eased = t * t * (3 - 2 * t)
            let progress = animation.from + (animation.to - animation.from) * eased
            self.petColumnProgress = progress
            self.layoutPetColumn(progress: progress, width: animation.width)
            if t >= 1 {
                timer.invalidate()
                self.petColumnAnimationTimer = nil
                self.petColumnAnimation = nil
                self.petColumnProgress = nil
                if animation.to == 0 { self.retirePetColumn() }
                self.layoutPetSlot()
            }
        }
        petColumnAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 測試用（--trace-right）：右欄目前的左緣位置與寬度、主內容寬度
    func debugRightPanel() -> String {
        let col = petColumnVisible ? "\(Int(petColumn.frame.minX)) \(Int(petColumn.frame.width))" : "- -"
        return "\(Int(view.bounds.width)) \(Int(body.frame.width)) \(col) on=\(PetSlot.enabled) bound=\(boundWindow != nil) pending=\(petColumnTogglePending)"
    }

    /// 右欄現在能有多寬（跟 layoutPetSlot 同一條算式）
    private func petColumnRoom() -> CGFloat {
        return columnRoom(PetSlot.size(on: view.window?.screen))
    }

    private func cancelPetColumnAnimation() {
        petColumnAnimationTimer?.invalidate()
        petColumnAnimationTimer = nil
        petColumnAnimation = nil
    }

    /// 依露出比例同步調整主內容寬度與右欄位置；右欄固定寬度並從視窗外滑入。
    private func layoutPetColumn(progress: CGFloat, width animationWidth: CGFloat? = nil) {
        guard isViewLoaded else { return }
        let size = PetSlot.size(on: view.window?.screen)
        let b = view.bounds
        let h = b.height - barH
        let room = columnRoom(size)
        let width = animationWidth ?? petColumnAnimation?.width ?? (PetSlot.enabled && room >= 190 ? room : 0)
        let p = min(1, max(0, progress))
        for f in frames.values { (f.content as? any ConversationPane)?.petReserve = .zero }
        body.frame = NSRect(x: 0, y: 0, width: b.width - width * p, height: h)
        body.subviews.first { $0 !== placeholder && !($0 is DropOverlay) }?.frame = body.bounds
        guard width > 0 else { return }
        mountPetColumn()
        if petView.superview !== petColumn { petColumn.addSubview(petView) }
        attachTopColumn()
        petColumn.frame = NSRect(x: b.width - width * p, y: 0, width: width, height: h)
        let slotH = petSlotHeight(size, h)
        petView.isHidden = slotH == 0
        petView.frame = NSRect(x: 0, y: 0, width: width, height: slotH)
        topColumnView.frame = NSRect(x: 0, y: slotH, width: width, height: max(0, h - slotH))
        petView.needsDisplay = true
        petColumn.needsDisplay = true
    }

    private var accent: NSColor {
        let pal = workspace.theme.palette(for: view.effectiveAppearance)
        return pal.ansi.count > 12 ? pal.ansi[12] : .controlAccentColor
    }

    /// 掛件格子滑進／滑出時：所有掛件所在的切口重排（PaneSlide 每一格叫一次）
    private var slideListening = false
    private func slideTick() {
        func walk(_ v: NSView) { if let b = v as? SplitBox, b.bPane != nil { b.needsLayout = true }; v.subviews.forEach(walk) }
        walk(body)
    }

    func render() {
        guard isViewLoaded else { return }
        // 主視窗（boundWindow＝nil）一定看不到獨立視窗的 Window；獨立視窗只看自己那個：重繪時明確指定範圍，不管現在是誰拿著焦點
        store.scoped(boundWindow) { renderInner() }
    }

    private func renderInner() {
        // 獨立視窗的 Window 不在了（最後一格被拖回主視窗、Window 被刪、Session 被關）：關掉這個視窗，不要留一個空殼或去畫別人的格子
        if let b = boundWindow, store.windowPosition(b) == nil {
            DispatchQueue.main.async { [weak self] in self?.view.window?.close() }
            return
        }
        if !slideListening { slideListening = true; PaneSlide.shared.listen(self) { [weak self] in self?.slideTick() } }
        let pal = workspace.theme.palette(for: view.effectiveAppearance)
        view.layer?.backgroundColor = pal.bg.cgColor
        let s = store.currentSessionLayout
        let windows = (s?.windows ?? []).filter { !$0.detached }      // 拉出去的獨立視窗不在分頁列上
        let wi = store.windowIndex ?? 0
        // 分頁上：取過名字的顯示「[1] 名字」，沒取過只顯示「[1]」
        let cm = store.sessionIndex.map { store.chiefTabMode($0) } ?? 0
        tabBar.update(session: s?.name ?? "", tabs: windows.map { $0.renamed ? $0.name : "" }, current: wi, accent: accent, chiefMode: cm)

        guard let w = store.currentWindow else { return }
        // 這次重繪是不是換了 Window 或換了目前那格（上一次畫的記在 lastRendered*）：只有這時、或焦點本來就在某個聊天格裡，才把鍵盤焦點交給目前那格；
        // 背景更新（Store 變了）觸發的重繪，不能把使用者正在用的側欄、搜尋欄的焦點搶走
        let switchedPane = lastRenderedWindow != w.id || lastRenderedFocus != w.focused
        lastRenderedWindow = w.id; lastRenderedFocus = w.focused
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
            e.isFocused = (id == w.focused && (root?.leaves.count ?? 0) > 1) || store.windowSelected
            e.closable = (root?.leaves.count ?? 0) > 1
            e.accent = accent
        }
        layoutPetSlot()
        let many = (root?.leaves.count ?? 0) > 1
        for (id, f) in frames {
            f.showsHeader = many && !(f.content is DisabledWebPane)
            f.isFocused = id == w.focused || store.windowSelected     // 選取整個 Window：每一格都加紫框
            f.setAccent(accent)
            f.setTitle(store.conversation(id)?.title ?? "")
            // 路徑列（PathBar）固定隱藏：位置改看側欄右鍵「關於…」（AboutChat.swift）；path 一直是 nil，版面不留那一條
        }
        if let f = w.focused, let frame = frames[f], let pane = frame.content as? any ConversationPane,
           let win = view.window,
           switchedPane || Self.shouldReclaimFocus(win.firstResponder, host: view, frame: frame) {
            win.makeFirstResponder(pane.focusTarget)
        }
    }

    private var overlays: [DropOverlay] = []
    private var overlayTimer: Timer?

    /// 拖放接收區：跟 render 一樣明確指定範圍。從主視窗側欄拖進獨立視窗時，主視窗的 scope 是 nil，不指定就會對著主視窗的版面找格子
    private func showDropTargets() {
        store.scoped(boundWindow) { showDropTargetsInner() }
    }

    private func showDropTargetsInner() {
        hideDropTargets()
        guard let w = store.currentWindow else { return }
        if w.root == nil {
            // 空的 Window：整塊都是接收區
            let o = DropOverlay(target: UUID())
            o.frame = body.bounds
            // 拖進空的 Window：搬過來（原本擺在別處也一樣），不是跳回原本的位置
            let wid = w.id
            o.onDrop = { [weak self] id, _ in self?.hideDropTargets(); if let self { self.store.scoped(self.boundWindow) { self.store.movePane(id, toWindow: wid) } } }
            body.addSubview(o)
            overlays.append(o)
        }
        for (id, f) in frames where f.superview != nil {
            let o = DropOverlay(target: id)
            o.frame = f.bounds
            o.autoresizingMask = [.width, .height]
            o.onDrop = { [weak self] conv, edge in
                self?.hideDropTargets()
                if let self { self.store.scoped(self.boundWindow) { self.store.place(conv, near: id, edge: edge) } }
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
                if let self, self.store.scoped(self.boundWindow, { self.store.replacePane(id, with: conv) }) { Store.emptySlots.remove(id) }
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
        else if store.isEmptySlot(target) {   // 拉到空格子上＝放進去；放不進去就不要刪來源 Window（對話會從版面消失）
            guard store.replacePane(target, with: conv) else { return }
            Store.emptySlots.remove(target)
        }
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
    /// 拖格子要不要當成「互換」（⌘＋左鍵拖）：判斷集中在這一個地方，之後要跟「按住 ⌘＋左鍵叫環狀選單」區分，只改這裡。
    /// 測試用 forceSwapDrag 可以蓋掉（合成的滑鼠事件讀不到真實的 ⌘ 狀態）
    static var forceSwapDrag: Bool?
    static var isSwapDrag: Bool { forceSwapDrag ?? NSEvent.modifierFlags.contains(.command) }

    /// 拖標題時蓋在目標格上的接收區（不按 ⌘：游標在目標格的哪一邊，就亮那一半，放開＝放到那一邊）
    private var dragOverlay: DropOverlay?
    private func paneHeaderDrag(_ id: UUID, _ ph: HeaderGrip.Phase, _ p: NSPoint) {
        let title = store.conversation(id)?.title ?? ""
        let over = tabBar.containsWindowPoint(p)
        let target = over ? nil : swapTarget(id, at: p)
        // 只按左鍵拖＝放到那格的左、右、上、下；按住 ⌘ 拖＝兩格互換
        let cmd = Self.isSwapDrag
        let swapWith = cmd ? target : nil
        let placeNear = cmd ? nil : target
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
            // 放開的位置在哪一邊：要在拿掉接收區之前算
            let drop = dragOverlay.map { ($0.target, $0.edge(at: $0.convert(p, from: nil))) }
            dragOverlay?.removeFromSuperview(); dragOverlay = nil
            tearLabel?.removeFromSuperview()
            tearLabel = nil
            swapMark?.removeFromSuperview()
            swapMark = nil
            tabBar.showTear(nil, accent: accent)
            if over { tearOff(id) }
            else if let swapWith { swapPanes(id, swapWith) }
            else if !cmd, let (t, edge) = drop, placeNear == t {
                if store.isEmptySlot(t) {
                    if store.replacePane(t, with: id) { Store.emptySlots.remove(t) }
                } else { store.place(id, near: t, edge: edge ?? .right) }
            }
            return
        }
        if let l = tearLabel {
            let q = view.convert(p, from: nil)
            l.frame.origin = NSPoint(x: q.x + 14, y: q.y - l.frame.height - 6)
        }
        tabBar.showTear(over ? title : nil, accent: accent)
        // ⌘ 拖到另一格上：那格蓋一層「放開＝互換位置」
        let tv: NSView? = swapWith.flatMap { frames[$0] ?? empties[$0] }
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
        // 沒按 ⌘：目標格蓋四半接收區，游標在哪一邊就亮哪一邊（空格子是整塊＝放進去）
        if let t = placeNear, let host = frames[t] ?? empties[t] {
            if dragOverlay?.target != t {
                dragOverlay?.removeFromSuperview()
                let o = DropOverlay(target: t)
                o.halvesOnly = !store.isEmptySlot(t)
                o.frame = host.bounds
                o.autoresizingMask = [.width, .height]
                host.addSubview(o)
                dragOverlay = o
            }
            dragOverlay?.hover(window: p)
        } else {
            dragOverlay?.removeFromSuperview()
            dragOverlay = nil
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

    /// 拖曳中的暫時狀態全部收掉：接收區（側欄拖進來、分頁拉進畫面兩種）、拖標題的名牌和互換標記、分頁的半透明和陰影
    func resetTransientDragState() {
        hideDropTargets()
        detachPreview.hide()
        pullOverlays.forEach { $0.removeFromSuperview() }
        pullOverlays = []
        tearLabel?.removeFromSuperview(); tearLabel = nil
        swapMark?.removeFromSuperview(); swapMark = nil
        dragOverlay?.removeFromSuperview(); dragOverlay = nil
        tabBar.cancelDrag()
        if let w = view.window, w.alphaValue != 1 { w.alphaValue = 1 }
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
            f.infoProvider = { [weak self] in self?.paneInfo(id) ?? [] }
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
        var source: (Int, UUID)?
        if let (si, wi) = locate(conv) {
            sessions[si].windows[wi].root = sessions[si].windows[wi].root?.removing(conv)
            if sessions[si].windows[wi].focused == conv { sessions[si].windows[wi].focused = sessions[si].windows[wi].root?.leaves.first }
            source = (si, sessions[si].windows[wi].id)
        }
        editWindow { w in
            guard let root = w.root else { w.root = .leaf(conv); w.focused = conv; return }
            // target 不在這個 Window 的版面裡（不該發生）：不要把整棵版面換成一格、弄丟其他格；改接在最後一格的右邊
            let anchorTarget = root.contains(target) ? target : (w.focused.flatMap { root.contains($0) ? $0 : nil } ?? root.leaves.last!)
            let edge: DropOverlay.Edge? = root.contains(target) ? edge : .right
            let target = anchorTarget
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
        // 搬空的來源 Window 刪掉：走 deleteWindow（主視窗分頁列空了會補一個、current 不會指到獨立視窗）；是獨立視窗的話，它下次重繪發現自己不在了會自己關
        if let (si, id) = source, sessions.indices.contains(si), let wi = sessions[si].windows.firstIndex(where: { $0.id == id }), sessions[si].windows[wi].root == nil, sessions[si].windows.count > 1 {
            deleteWindow(id)
        }
    }
}

/// 右側欄位的底：左邊一條細線跟 Pane 隔開
final class PetColumnView: NSView {
    /// 總指揮模式：左緣 5 點可以拖來調右欄寬度
    var onResizeWidth: ((CGFloat) -> Void)?
    var resizable: () -> Bool = { false }
    private let grab: CGFloat = 5
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if resizable(), convert(point, from: superview).x < grab, bounds.contains(convert(point, from: superview)) { return self }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        if resizable() { addCursorRect(NSRect(x: 0, y: 0, width: grab, height: bounds.height), cursor: .resizeLeftRight) }
    }
    /// 只有「左緣 5 點」按下去才算調寬度。以前沒記這件事：桌寵等沒人接手的地方按下去也落到這裡，
    /// 一拖右欄寬度就跟著滑鼠走（三指拖移桌寵，右欄被擠窄又變得很寬）
    private var resizing = false
    override func mouseDragged(with e: NSEvent) {
        guard resizing, resizable(), let host = superview else { return }
        onResizeWidth?(host.bounds.width - host.convert(e.locationInWindow, from: nil).x)
    }
    override func mouseDown(with e: NSEvent) { resizing = resizable() && convert(e.locationInWindow, from: nil).x < grab }
    override func mouseUp(with e: NSEvent) { resizing = false }
}


/// 停在格子標題上顯示的資訊小卡：半透明深色底、圓角，每列「標籤  內容」，內容太長省略中間
final class InfoCard: NSView {
    private var labels: [(NSTextField, NSTextField)] = []
    var rowCount: Int { labels.count }
    private let rowH: CGFloat = 20, pad: CGFloat = 10
    private var accent: NSColor = .controlAccentColor
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        alphaValue = 0
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    func height(for w: CGFloat) -> CGFloat { CGFloat(labels.count) * rowH + pad * 2 }
    func set(rows: [(String, String)], accent: NSColor) {
        self.accent = accent
        labels.forEach { $0.0.removeFromSuperview(); $0.1.removeFromSuperview() }
        labels = rows.map { k, v in
            let a = NSTextField(labelWithString: k); a.font = .systemFont(ofSize: 11); a.textColor = NSColor.white.withAlphaComponent(0.55)
            let b = NSTextField(labelWithString: v); b.font = .systemFont(ofSize: 12); b.textColor = NSColor.white.withAlphaComponent(0.92)
            b.lineBreakMode = .byTruncatingMiddle; b.toolTip = v
            addSubview(a); addSubview(b)
            return (a, b)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let labelW: CGFloat = 70
        for (i, r) in labels.enumerated() {
            let y = bounds.height - pad - CGFloat(i + 1) * rowH + 1
            r.0.frame = NSRect(x: pad, y: y, width: labelW, height: 18)
            r.1.frame = NSRect(x: pad + labelW, y: y, width: max(0, bounds.width - pad * 2 - labelW), height: 18)
        }
    }
    /// 淡入 0.15 秒，邊框用主題色閃一下（跟拖到分頁上的閃法同一個風格）
    func fadeIn() {
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; animator().alphaValue = 1 }
        if !Motion.reduced {
            let a = CABasicAnimation(keyPath: "borderColor")
            a.fromValue = accent.cgColor; a.toValue = NSColor.white.withAlphaComponent(0.2).cgColor
            a.duration = 0.3
            layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            layer?.add(a, forKey: "flash")
        }
    }
    func fadeOut() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.15; animator().alphaValue = 0 }, completionHandler: { [weak self] in
            if self?.alphaValue == 0 { self?.isHidden = true }
        })
    }
}

extension WindowHost {
    /// 測試用：假裝滑鼠進來／離開第 id 格的標題；回傳卡片狀態
    func testHover(_ id: UUID, inside: Bool) { frames[id]?.testHover(inside) }
    func testInfoState(_ id: UUID) -> String { frames[id]?.infoState ?? "沒有這格" }

    /// 標題停留小卡的內容：聊天室＝工作資料夾、模型、上下文大小；瀏覽器格＝網址
    func paneInfo(_ id: UUID) -> [(String, String)] {
        guard let c = store.conversation(id) else { return [] }
        if c.isBrowser {
            let u = (workspace.panes[id] as? BrowserPane)?.currentURL ?? c.browser ?? ""
            return [(L("網址"), u.isEmpty ? "about:blank" : u)]
        }
        let folder = store.project(c.projectID)?.path ?? NSHomeDirectory()
        ContextMonitor.shared.load(c, path: folder)
        let ctx = ContextMonitor.shared.tokens[id].map { "\(ContextMonitor.text($0)) tokens" } ?? L("（還沒有紀錄）")
        return [(L("工作資料夾"), (folder as NSString).abbreviatingWithTildeInPath), (L("模型"), store.displayModel(id)), (L("上下文大小"), ctx)]
    }
}


/// 測試用（--frame-stats）：從開始起每 1/120 秒量一次主執行緒的空檔，空檔超過 20ms 就是一次掉幀；不看動畫自己的計時器（主執行緒卡住時它也一起卡）
enum RightPanelPerf {
    private static var gaps: [Double] = []
    private static var timer: Timer?
    private static var last = 0.0
    private static var t0 = 0.0
    private static var observing = false
    private static var marks: [String] = []
    static func reset() {
        gaps = []; marks = []; last = ProcessInfo.processInfo.systemUptime; t0 = last
        timer?.invalidate()
        for n in [Notification.Name.rightPanelToggleWillBegin, .rightPanelToggled] where !observing {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { note in marks.append(String(format: "[%@@%.0f]", note.name == .rightPanelToggled ? "end" : "begin", (ProcessInfo.processInfo.systemUptime - t0) * 1000)) }
        }
        observing = true
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append((now - last) * 1000); if (now - last) * 1000 > 20 { marks.append(String(format: "@%.0f:%.0f", (now - t0) * 1000, (now - last) * 1000)) }; last = now
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }
    static var maxGap: Double { gaps.max() ?? 0 }
    static func report(_ label: String) -> String {
        timer?.invalidate(); timer = nil
        guard !gaps.isEmpty else { return "\(label) 沒有資料\n" }
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        let over = gaps.filter { $0 > 20 }
        return "\(label) 最長停頓=\(f(gaps.max() ?? 0))ms >20ms的次數=\(over.count) 停頓總和=\(f(over.reduce(0, +)))ms [\(marks.joined(separator: " "))]\n"
    }
}
