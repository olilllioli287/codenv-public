import AppKit
import Combine
import SwiftUI

// 右欄「視窗」分頁的關聯圖（Obsidian 式）：中心＝總指揮聊天室、中型節點＝區、小節點＝聊天室。
// 全部用 AppKit 自畫（NSView.draw）＋自己的力導向佈局，沒有引進套件。
// 省電：佈局穩定後不再計算；只有「在畫面上、App 在前景、有工作中的聊天室（呼吸）或佈局還在動」才有計時器。

struct GraphNodeInfo {
    enum Kind { case center, area, chat }
    let id: UUID
    let kind: Kind
    let title: String
    let parent: UUID?
    let state: RPState
    let context: Int?
    let placed: Bool
    let hue: CGFloat
}

struct GraphSnapshot {
    var sessionID: UUID?
    var name: String
    var nodes: [GraphNodeInfo]
    /// 結構（誰連誰）的指紋：沒變就只更新顏色大小，不重跑佈局
    var signature: Int
}

extension RPData {
    static func graph(_ store: Store, workspace: Workspace) -> GraphSnapshot? {
        guard let s = store.currentSessionLayout, s.groups != nil else { return nil }
        let ctx = ContextMonitor.shared.tokens
        let centerID = s.chief ?? s.id
        let nodes = store.areaNodes(s)
        let live = store.conversations(inCommander: s).filter { Store.isChat($0) && !$0.isBrowser && !$0.isGadget && $0.draft != true && !store.isArchived($0) }
        var out: [GraphNodeInfo] = []
        let chief = s.chief.flatMap { store.conversation($0) }
        out.append(GraphNodeInfo(id: centerID, kind: .center, title: chief?.title ?? s.name,
                                 parent: nil, state: s.chief.map { state($0, store: store, workspace: workspace) } ?? .asleep,
                                 context: s.chief.flatMap { ctx[$0] }, placed: true, hue: 0))
        // 區：第一層的區各一種色相，底下的區沿用
        var hueOf: [UUID: CGFloat] = [:]
        var first = 0
        for n in nodes {
            let h: CGFloat
            if let p = n.parent, let ph = hueOf[p] { h = ph } else { h = (0.08 + CGFloat(first) * 0.137).truncatingRemainder(dividingBy: 1); first += 1 }
            hueOf[n.group.id] = h
            out.append(GraphNodeInfo(id: n.group.id, kind: .area, title: n.group.name, parent: n.parent ?? centerID,
                                     state: .idle, context: nil, placed: true, hue: h))
        }
        for c in live where c.id != s.chief {
            let a = store.areaID(of: c, in: nodes)
            out.append(GraphNodeInfo(id: c.id, kind: .chat, title: c.title, parent: a ?? centerID,
                                     state: state(c.id, store: store, workspace: workspace), context: ctx[c.id],
                                     placed: store.locate(c.id) != nil, hue: a.flatMap { hueOf[$0] } ?? 0))
        }
        var h = Hasher()
        for n in out { h.combine(n.id); h.combine(n.parent) }
        return GraphSnapshot(sessionID: s.id, name: s.name, nodes: out, signature: h.finalize())
    }
}

final class ChatGraphView: NSView {
    struct Node {
        var info: GraphNodeInfo
        var pos: CGPoint
        var vel = CGPoint.zero
        var pinned = false
        var r: CGFloat
        var lw: CGFloat = 40          // 標籤寬度（畫面點數，約值；置中貼合時把標籤也算進去）
        var id: UUID { info.id }
    }

    // 外面接的
    weak var store: Store?
    weak var workspace: Workspace?
    var onSummon: ((UUID) -> Void)?
    var onInfo: ((UUID) -> Void)?
    var onEscape: (() -> Void)?
    /// F6 大畫面版：字和節點大一點
    var big = false { didSet { needsDisplay = true } }
    /// F6 面板本身；右欄那份在 F6 開著時被蓋住，要停下來
    var isOverlay = false
    private(set) static var overlayOpen = false
    /// 測試用：右欄那份
    static weak var rightInstance: ChatGraphView?
    static let overlayChanged = Notification.Name("ChatGraphView.overlayChanged")
    static func setOverlayOpen(_ on: Bool) {
        overlayOpen = on
        NotificationCenter.default.post(name: overlayChanged, object: nil)
    }

    private(set) var nodes: [Node] = []
    private var index: [UUID: Int] = [:]
    private var signature = 0
    private var alpha: CGFloat = 0
    private var offset = CGPoint.zero          // 世界原點在視圖中心偏移多少（畫面座標）
    private var scale: CGFloat = 1
    private var userMoved = false
    private var fitting = false
    private var timer: Timer?
    private var hover: UUID?
    private var bag = Set<AnyCancellable>()
    private var menuActions: [MenuAction] = []

    // 滑鼠
    private var downNode: UUID?
    private var downPoint = CGPoint.zero
    private var dragged = false
    private var lastDrag = CGPoint.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// 視窗不是目前的視窗時，第一下點擊也要直接算（不然第一下只拿來啟用視窗，選取要點第二次）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        RightPanelModel.shared.$selectedChat.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        let nc = NotificationCenter.default
        for n in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            nc.publisher(for: n).sink { [weak self] _ in self?.updateTimer() }.store(in: &bag)
        }
        nc.publisher(for: Self.overlayChanged).sink { [weak self] _ in self?.updateTimer() }.store(in: &bag)
        nc.publisher(for: NSWindow.didChangeOcclusionStateNotification).sink { [weak self] _ in self?.updateTimer() }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    // MARK: 資料

    func apply(_ snap: GraphSnapshot?) {
        guard let snap else { nodes = []; index = [:]; signature = 0; needsDisplay = true; updateTimer(); return }
        let first = nodes.isEmpty
        var pos: [UUID: CGPoint] = [:]
        var old: [UUID: Node] = [:]
        for n in nodes { old[n.id] = n }
        var out: [Node] = []
        for info in snap.nodes {
            let r = Self.radius(info)
            let lw = (info.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: info.kind == .center ? 12 : info.kind == .area ? 11 : 10, weight: info.kind == .chat ? .regular : .semibold)]).width
            if var n = old[info.id] {
                n.info = info; n.r = r; n.lw = lw
                out.append(n); pos[info.id] = n.pos
            } else {
                var p = CGPoint.zero
                if info.kind != .center {
                    let base = info.parent.flatMap { pos[$0] } ?? .zero
                    let u = info.id.uuid
                    let a = Double(Int(u.0) * 256 + Int(u.1)) / 65536 * 2 * .pi
                    let d: CGFloat = info.kind == .area ? 90 : 50
                    p = CGPoint(x: base.x + CGFloat(cos(a)) * d, y: base.y + CGFloat(sin(a)) * d)
                }
                var n = Node(info: info, pos: p, r: r)
                n.lw = lw
                n.pinned = info.kind == .center
                out.append(n); pos[info.id] = p
            }
        }
        nodes = out
        index = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.id, $0) })
        if let h = hover, index[h] == nil { hover = nil }
        let changed = snap.signature != signature
        signature = snap.signature
        if first {
            alpha = 1
            for _ in 0..<220 { step() }
            alpha = 0
            userMoved = false
            fit(animated: false)
        } else if changed {
            alpha = max(alpha, 0.6)
            if !canAnimate {                       // 沒在畫面上／App 在背景：不開計時器，一次算到穩定，回來時就是排好的
                while alpha > 0.02 { step(); alpha *= 0.975 }
                alpha = 0
                if !userMoved { fit(animated: false) }
            }
        }
        needsDisplay = true
        updateTimer()
    }

    static func radius(_ i: GraphNodeInfo) -> CGFloat {
        switch i.kind {
        case .center: return 16
        case .area: return 10
        case .chat: return 5 + min(5, CGFloat(i.context ?? 0) / 100_000)     // 上下文愈大節點愈大（500K 以上封頂）
        }
    }

    // MARK: 力導向

    private func restLength(_ n: Node, parent p: Node) -> CGFloat {
        switch (p.info.kind, n.info.kind) {
        case (.center, .area): return 100
        case (.area, .area): return 80
        case (_, .area): return 80
        case (.center, _): return 85
        default: return 55
        }
    }

    private func step() {
        let n = nodes.count
        guard n > 0 else { return }
        var fx = [CGFloat](repeating: 0, count: n), fy = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            for j in (i + 1)..<n where j < n {
                var dx = nodes[j].pos.x - nodes[i].pos.x, dy = nodes[j].pos.y - nodes[i].pos.y
                var d2 = dx * dx + dy * dy
                if d2 < 0.01 { dx = CGFloat(i - j) * 0.3 + 0.1; dy = 0.1; d2 = dx * dx + dy * dy }
                if d2 > 160_000 { continue }
                let d = sqrt(d2)
                let k = 1700 / d2 * (1 + (nodes[i].r + nodes[j].r) / 30)
                var f = k
                let minD = nodes[i].r + nodes[j].r + 16
                if d < minD { f += (minD - d) * 0.6 }
                let ux = dx / d, uy = dy / d
                fx[i] -= ux * f; fy[i] -= uy * f
                fx[j] += ux * f; fy[j] += uy * f
            }
        }
        for i in 0..<n {
            guard let p = nodes[i].info.parent, let pi = index[p] else { continue }
            let dx = nodes[pi].pos.x - nodes[i].pos.x, dy = nodes[pi].pos.y - nodes[i].pos.y
            let d = max(0.01, sqrt(dx * dx + dy * dy))
            let f = (d - restLength(nodes[i], parent: nodes[pi])) * 0.09
            let ux = dx / d, uy = dy / d
            fx[i] += ux * f; fy[i] += uy * f
            fx[pi] -= ux * f; fy[pi] -= uy * f
        }
        for i in 0..<n {
            fx[i] -= nodes[i].pos.x * 0.004; fy[i] -= nodes[i].pos.y * 0.004
            if nodes[i].pinned { nodes[i].vel = .zero; continue }
            var vx = (nodes[i].vel.x + fx[i] * alpha) * 0.6, vy = (nodes[i].vel.y + fy[i] * alpha) * 0.6
            let sp = sqrt(vx * vx + vy * vy)
            if sp > 30 { vx *= 30 / sp; vy *= 30 / sp }
            nodes[i].vel = CGPoint(x: vx, y: vy)
            nodes[i].pos.x += vx; nodes[i].pos.y += vy
        }
    }

    // MARK: 計時器（只在需要時跑）

    private var anyWorking: Bool { nodes.contains { $0.info.state == .working } }
    private var canAnimate: Bool {
        guard let w = window, w.isVisible, !isHiddenOrHasHiddenAncestor, NSApp.isActive, w.occlusionState.contains(.visible) else { return false }
        return isOverlay || !Self.overlayOpen
    }
    private var shouldRun: Bool { canAnimate && (alpha > 0.02 || fitting || anyWorking) }

    func updateTimer() {
        if shouldRun {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if let t = timer { t.invalidate(); timer = nil }
    }

    private func tick() {
        if alpha > 0.02 { step(); alpha *= 0.975; if alpha <= 0.02 { alpha = 0 } }
        if fitting && !userMoved { fit(animated: true) }
        needsDisplay = true
        if !shouldRun { updateTimer() }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil, !userMoved, !nodes.isEmpty { fit(animated: false) }; updateTimer() }
    override func viewDidHide() { super.viewDidHide(); updateTimer() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateTimer() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !userMoved, !nodes.isEmpty { fit(animated: false) }
    }

    /// 縮放平移到剛好看到所有節點
    func fit(animated: Bool) {
        guard !nodes.isEmpty, bounds.width > 10, bounds.height > 10 else { return }
        let padX: CGFloat = big ? 60 : 24, padY: CGFloat = big ? 56 : 20
        let top: CGFloat = big ? 40 : 0          // F6 面板上方有標題列
        let cap: CGFloat = big ? 2.4 : 1.6
        var s = cap
        var cx: CGFloat = 0, cy: CGFloat = 0
        // 外框要把標籤也算進去（標籤寬度是畫面點數，要除以縮放才是世界座標）；縮放跟外框互相影響，疊代三次
        for _ in 0..<3 {
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
            for n in nodes {
                let half = max(n.r, n.lw * (big ? 1.25 : 1) / 2 / s)
                minX = min(minX, n.pos.x - half); maxX = max(maxX, n.pos.x + half)
                minY = min(minY, n.pos.y - n.r); maxY = max(maxY, n.pos.y + n.r + 18 / s)
            }
            let w = max(60, maxX - minX), h = max(60, maxY - minY)
            s = min((bounds.width - padX * 2) / w, (bounds.height - padY * 2 - top) / h, cap)
            cx = (minX + maxX) / 2; cy = (minY + maxY) / 2
        }
        let target = CGPoint(x: -cx * s, y: -cy * s + top / 2)
        if animated {
            scale += (s - scale) * 0.18
            offset = CGPoint(x: offset.x + (target.x - offset.x) * 0.18, y: offset.y + (target.y - offset.y) * 0.18)
            fitting = abs(s - scale) > 0.002 || abs(target.x - offset.x) > 0.3 || abs(target.y - offset.y) > 0.3
        } else { scale = s; offset = target; fitting = false }
    }

    /// 佈局穩定前一直貼合；使用者動過視角就不再自動貼合（雙擊空白處重新貼合）
    private func refit() { userMoved = false; fitting = true; updateTimer() }

    // MARK: 座標

    private func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: bounds.midX + offset.x + p.x * scale, y: bounds.midY + offset.y + p.y * scale) }
    private func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - bounds.midX - offset.x) / scale, y: (p.y - bounds.midY - offset.y) / scale) }

    private var nodeScale: CGFloat { big ? 1.25 : 1 }

    private func hit(_ p: CGPoint) -> Int? {
        for i in nodes.indices.reversed() {
            let s = toScreen(nodes[i].pos)
            let r = max(7, nodes[i].r * scale * nodeScale + 3)
            if (s.x - p.x) * (s.x - p.x) + (s.y - p.y) * (s.y - p.y) <= r * r { return i }
        }
        return nil
    }

    // MARK: 畫

    private static func stateColor(_ s: RPState) -> NSColor {
        switch s {
        case .working: return .systemGreen
        case .waiting: return .systemOrange
        case .idle: return NSColor.systemBlue.withAlphaComponent(0.75)
        case .asleep: return NSColor.systemGray.withAlphaComponent(0.5)
        }
    }

    private func color(_ n: Node) -> NSColor {
        switch n.info.kind {
        case .center: return Store.bundleAccent
        case .area: return NSColor(hue: n.info.hue, saturation: 0.45, brightness: 0.85, alpha: 1)
        case .chat: return Self.stateColor(n.info.state)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        if nodes.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
            NSString(string: L("這一區沒有總指揮")).draw(at: CGPoint(x: 12, y: 10), withAttributes: a)
            return
        }
        let phase = CACurrentMediaTime()
        let sel = RightPanelModel.shared.selectedChat
        // 滑過去的節點：它自己、相連的亮，其他淡一點
        var near = Set<UUID>()
        if let h = hover, let hi = index[h] {
            near.insert(h)
            if let p = nodes[hi].info.parent { near.insert(p) }
            for n in nodes where n.info.parent == h { near.insert(n.id) }
        }
        let dim = hover != nil
        // 連線
        g.setLineWidth(max(0.8, 1.2 * scale))
        for n in nodes {
            guard let p = n.info.parent, let pi = index[p] else { continue }
            let a = toScreen(nodes[pi].pos), b = toScreen(n.pos)
            let lit = !dim || (near.contains(n.id) && near.contains(p) && (hover == n.id || hover == p))
            let base = nodes[pi].info.kind == .center ? NSColor.secondaryLabelColor : NSColor(hue: n.info.hue, saturation: 0.5, brightness: 0.85, alpha: 1)
            g.setStrokeColor(base.withAlphaComponent(lit ? 0.45 : 0.12).cgColor)
            g.move(to: a); g.addLine(to: b); g.strokePath()
        }
        // 節點
        let showAll = nodes.count <= 45 || scale >= 0.9
        let ns = nodeScale
        for n in nodes {
            let c = toScreen(n.pos)
            var r = n.r * scale * ns
            r = max(r, n.info.kind == .chat ? 3 : 5)
            let faded = dim && !near.contains(n.id)
            let col = color(n).withAlphaComponent(faded ? 0.25 : 1)
            if n.info.state == .working && n.info.kind != .area {
                let k = (sin(phase * 3.2 + Double(abs(n.id.hashValue % 100)) * 0.1) + 1) / 2      // 0…1 呼吸
                g.setFillColor(color(n).withAlphaComponent(0.18 + 0.22 * CGFloat(k)).cgColor)
                let hr = r * (1.5 + 0.5 * CGFloat(k))
                g.fillEllipse(in: CGRect(x: c.x - hr, y: c.y - hr, width: hr * 2, height: hr * 2))
            }
            g.setFillColor(col.cgColor)
            g.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            if !n.info.placed && n.info.kind == .chat {          // 沒擺在版面上的：空心一點
                g.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor)
                g.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.9, height: r * 0.9))
            }
            if n.id == sel || (n.info.kind == .center && sel == n.id) {
                g.setStrokeColor(Store.bundleAccent.cgColor); g.setLineWidth(2)
                g.strokeEllipse(in: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: (r + 3) * 2, height: (r + 3) * 2))
            } else if n.id == hover {
                g.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.6).cgColor); g.setLineWidth(1)
                g.strokeEllipse(in: CGRect(x: c.x - r - 2, y: c.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2))
            }
        }
        // 標籤：依重要程度排隊（中心、區、滑過／選取、工作中、其他），每個試「下、上、右、左」四個位置，
        // 都會跟已畫的標籤或節點重疊就不畫（滑過／選取的一定畫）
        func rank(_ n: Node) -> Int {
            if n.id == hover || n.id == sel { return 0 }
            switch n.info.kind { case .center: return 1; case .area: return 2; case .chat: break }
            return n.info.state == .working || n.info.state == .waiting ? 3 : 4
        }
        var placed: [CGRect] = nodes.map { n in
            let c = toScreen(n.pos), r = max(n.r * scale * ns, n.info.kind == .chat ? 3 : 5) + 1
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        }
        for n in nodes.sorted(by: { rank($0) < rank($1) }) {
            let hot = n.id == hover || n.id == sel
            let faded = dim && !near.contains(n.id)
            guard n.info.kind != .chat || showAll || hot else { continue }
            let size: CGFloat = (n.info.kind == .center ? 12 : n.info.kind == .area ? 11 : 10) * (big ? 1.25 : 1)
            let weight: NSFont.Weight = n.info.kind == .chat ? .regular : .semibold
            let col: NSColor = n.info.kind == .chat ? .secondaryLabelColor : .labelColor
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: hot ? size + 1 : size, weight: hot ? .semibold : weight),
                                                    .foregroundColor: (hot ? NSColor.labelColor : col).withAlphaComponent(faded ? 0.3 : 1)]
            let str = NSString(string: n.info.title)
            let sz = str.size(withAttributes: a)
            let c = toScreen(n.pos)
            let r = max(n.r * scale * ns, n.info.kind == .chat ? 3 : 5)
            let spots = [CGPoint(x: c.x - sz.width / 2, y: c.y + r + 2), CGPoint(x: c.x - sz.width / 2, y: c.y - r - 2 - sz.height),
                         CGPoint(x: c.x + r + 3, y: c.y - sz.height / 2), CGPoint(x: c.x - r - 3 - sz.width, y: c.y - sz.height / 2)]
            var chosen: CGPoint?
            for p in spots {
                let rect = CGRect(origin: p, size: sz).insetBy(dx: -2, dy: -1)
                // 自己的節點圓不算（它的圓一定在 placed 裡，標籤本來就貼著它）
                if !placed.contains(where: { $0.intersects(rect) && !($0.width <= (r + 2) * 2 + 2 && abs($0.midX - c.x) < 0.5 && abs($0.midY - c.y) < 0.5) }) { chosen = p; break }
            }
            if chosen == nil && hot { chosen = spots[0] }
            guard let p = chosen else { continue }
            str.draw(at: p, withAttributes: a)
            placed.append(CGRect(origin: p, size: sz).insetBy(dx: -2, dy: -1))
        }
    }

    // MARK: 滑鼠

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func updateHover(_ p: CGPoint) {
        setHover(hit(p).map { nodes[$0].id })
    }

    private func setHover(_ id: UUID?) {
        guard id != hover else { return }
        if let old = hover { ChatInfoCard.shared.hoverEnded(old) }
        hover = id
        if let id, let store, let workspace, store.conversation(id) != nil {
            ChatInfoCard.shared.hoverBegan(id, store: store, workspace: workspace, window: window)
        }
        needsDisplay = true
    }

    private(set) var dbgDowns = 0, dbgHit = ""
    override func mouseDown(with event: NSEvent) {
        dbgDowns += 1
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p; lastDrag = p; dragged = false
        downNode = hit(p).map { nodes[$0].id }
        dbgHit = "\(p) → \(hit(p).map { nodes[$0].info.title } ?? "nil")"
        ChatInfoCard.shared.cancel()
        if let id = downNode, store?.conversation(id) != nil { RightPanelModel.shared.selectedChat = id }
        if event.clickCount == 2 {
            if let id = downNode { if store?.conversation(id) != nil { onSummon?(id) } }
            else { refit() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !dragged, hypot(p.x - downPoint.x, p.y - downPoint.y) < 3 { return }
        dragged = true
        if let id = downNode, let i = index[id] {
            nodes[i].pos = toWorld(p); nodes[i].pinned = true; nodes[i].vel = .zero
            alpha = max(alpha, 0.3)
        } else {
            offset.x += p.x - lastDrag.x; offset.y += p.y - lastDrag.y
            userMoved = true; fitting = false
        }
        lastDrag = p
        needsDisplay = true
        updateTimer()
    }

    override func mouseUp(with event: NSEvent) { downNode = nil; dragged = false }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            offset.x += event.scrollingDeltaX; offset.y += event.scrollingDeltaY      // 觸控板兩指＝平移
            userMoved = true; fitting = false
            needsDisplay = true
        } else {
            zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.06)), at: convert(event.locationInWindow, from: nil))
        }
    }

    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil)) }

    private func zoom(by f: CGFloat, at p: CGPoint) {
        let w = toWorld(p)
        scale = min(5, max(0.15, scale * f))
        // 縮放後讓游標底下的點不動
        offset.x = p.x - bounds.midX - w.x * scale; offset.y = p.y - bounds.midY - w.y * scale
        userMoved = true; fitting = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, event.charactersIgnoringModifiers?.lowercased() == "i", let id = RightPanelModel.shared.selectedChat, store?.conversation(id) != nil {
            ChatInfoCard.shared.cancel(); onInfo?(id); return
        }
        if event.keyCode == 53, let onEscape { onEscape(); return }
        super.keyDown(with: event)
    }

    // MARK: 右鍵選單（跟列表同一套）

    private final class MenuAction: NSObject {
        let fn: () -> Void
        init(_ fn: @escaping () -> Void) { self.fn = fn }
        @objc func run() { fn() }
    }

    private func item(_ title: String, checked: Bool = false, _ fn: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(fn); menuActions.append(a)
        let it = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        it.target = a; it.state = checked ? .on : .off
        return it
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuActions = []
        let p = convert(event.locationInWindow, from: nil)
        guard let hi = hit(p), let store else { return nil }
        let n = nodes[hi]
        ChatInfoCard.shared.cancel()
        guard let c = store.conversation(n.id) else { return nil }       // 區節點沒有選單
        RightPanelModel.shared.selectedChat = c.id
        let id = c.id
        let chief = n.info.kind == .center
        let m = NSMenu()
        m.addItem(item(L("叫出來")) { [weak self] in self?.onSummon?(id) })
        m.addItem(item(L("聊天室資訊…")) { [weak self] in self?.onInfo?(id) })
        m.addItem(item(L("重新命名…")) { [weak self] in self?.promptRename(id) })
        if !store.groups.isEmpty {
            if !chief, let s = store.currentSessionLayout {
                let areas = NSMenu()
                let nodes = store.areaNodes(s)
                if let root = store.areaRoot(s) {
                    areas.addItem(item(L("（總指揮本身）"), checked: store.areaID(of: c, in: nodes) == nil) { store.move(id, toGroup: root) })
                }
                for a in nodes {
                    areas.addItem(item(String(repeating: "　", count: a.depth - 1) + a.group.name, checked: store.groupOf(c) == a.group.id) { store.move(id, toGroup: a.group.id) })
                }
                let top = NSMenuItem(title: L("移到區…"), action: nil, keyEquivalent: ""); top.submenu = areas
                m.addItem(top)
            }
            let move = NSMenu()
            for t in store.groupTree() {
                move.addItem(item(String(repeating: "　", count: t.depth) + t.group.name, checked: store.groupOf(c) == t.group.id) { store.move(id, toGroup: t.group.id) })
            }
            let top = NSMenuItem(title: L("移到…"), action: nil, keyEquivalent: ""); top.submenu = move
            m.addItem(top)
            let arch = store.isArchived(c)
            m.addItem(item(arch ? L("取消封存") : L("封存")) { store.setArchived(id, !arch) })
        }
        if Store.isChat(c) {
            let mcp = NSMenu()
            for mode in McpMode.allCases { mcp.addItem(item(mode.label, checked: McpMode.from(c.mcp) == mode) { store.setMcp(id, mode) }) }
            let top = NSMenuItem(title: L("MCP（下次啟動生效）"), action: nil, keyEquivalent: ""); top.submenu = mcp
            m.addItem(top)
        }
        if !chief {
            m.addItem(item(L("讓總指揮改名"), checked: c.commanderMayRename == true) { store.setCommanderMayRename(id, c.commanderMayRename != true) })
        }
        return m
    }

    private func promptRename(_ id: UUID) {
        guard let store, let c = store.conversation(id) else { return }
        let a = NSAlert()
        a.messageText = L("重新命名對話")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = c.title
        a.accessoryView = f
        a.addButton(withTitle: L("好")); a.addButton(withTitle: L("取消"))
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { store.rename(id, to: f.stringValue, byUser: true) }
    }

    // MARK: 測試用

    /// 測試：節點（標題）中心的視窗座標（左下原點）
    func windowPoint(title: String) -> CGPoint? {
        guard let n = nodes.first(where: { $0.info.title == title }) else { return nil }
        return convert(toScreen(n.pos), to: nil)
    }

    /// --dump-graph：節點與位置
    func dump() -> [String: Any] {
        let saved = alpha; alpha = 0
        let t0 = CACurrentMediaTime()
        for _ in 0..<20 { step() }
        let stepMs = (CACurrentMediaTime() - t0) / 20 * 1000
        alpha = saved
        let d0 = CACurrentMediaTime()
        let rep = bitmapImageRepForCachingDisplay(in: bounds)
        if let rep { cacheDisplay(in: bounds, to: rep) }
        let drawMs = (CACurrentMediaTime() - d0) * 1000
        let out: [String: Any] = ["nodes": nodes.map { ["title": $0.info.title, "kind": "\($0.info.kind)", "state": $0.info.state.rawValue,
                               "x": Int($0.pos.x), "y": Int($0.pos.y), "r": Int($0.r),
                               "parent": $0.info.parent.flatMap { p in self.index[p].map { self.nodes[$0].info.title } } ?? ""] as [String: Any] },
         "downs": dbgDowns, "lastHit": dbgHit, "stepMs": stepMs, "drawMs": drawMs, "scale": scale, "alpha": alpha, "timerRunning": timer != nil, "anyWorking": anyWorking]
        return out
    }
}

/// 把 ChatGraphView 放進 SwiftUI：每次 store 有變就把最新快照丟進去
struct ChatGraphRepresentable: NSViewRepresentable {
    @ObservedObject var store: Store
    let workspace: Workspace
    var big = false
    var isOverlay = false
    var onSummon: (UUID) -> Void
    var onInfo: (UUID) -> Void
    var onEscape: (() -> Void)?
    var onCreate: ((ChatGraphView) -> Void)?

    func makeNSView(context: Context) -> ChatGraphView {
        let v = ChatGraphView(frame: .zero)
        onCreate?(v)
        v.big = big; v.isOverlay = isOverlay
        if !isOverlay { ChatGraphView.rightInstance = v }
        configure(v)
        v.apply(RPData.graph(store, workspace: workspace))
        return v
    }

    func updateNSView(_ v: ChatGraphView, context: Context) {
        configure(v)
        v.apply(RPData.graph(store, workspace: workspace))
    }

    private func configure(_ v: ChatGraphView) {
        v.store = store; v.workspace = workspace
        v.onSummon = onSummon; v.onInfo = onInfo; v.onEscape = onEscape
    }

    static func dismantleNSView(_ v: ChatGraphView, coordinator: ()) { v.updateTimer() }
}
