import AppKit
import SwiftUI

// 掛件框（使用者 10/25）：側欄用紫框把幾段聊天室框在一起（左邊一個「{」），框底下一列掛件（Gemini、NotebookLM、任意網頁），
// 由右往左排，新加的在左邊。點掛件就在目前的 Window 開那一格。
// 資料：聊天室在哪個框＝Conversation.bundle；掛件是一格不列在側欄的瀏覽器（Conversation.gadgetOf＝哪個框），
// 網址照瀏覽器格子自己記（使用者換到別段 Gemini 對話，就記最後那個連結）。
// 進出框只看拖到哪裡：拖到框裡某一段的上下＝加入，拖到框外＝離開；移到別組、自己封存、刪掉也算離開。
// 框裡一段聊天室都不剩：掛件連同網址一起刪掉（使用者 10/25）。

enum GadgetKind: String, CaseIterable {
    case gemini, notebooklm, web

    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .notebooklm: return "NotebookLM"
        case .web: return "網頁"
        }
    }
    var icon: String {
        switch self {
        case .gemini: return "sparkle"
        case .notebooklm: return "book.closed"
        case .web: return "globe"
        }
    }
    var home: String {
        switch self {
        case .gemini: return BrowserPane.gemini   // 不跟著 BrowserPane.home（一般格子是空白頁）
        case .notebooklm: return "https://notebooklm.google.com/"
        case .web: return "about:blank"
        }
    }
    /// 看網址認種類（NotebookLM 新舊網域都認：notebooklm.google.com、notebook.google.com）
    static func of(_ url: String?) -> GadgetKind {
        let host = url.flatMap { URL(string: $0)?.host?.lowercased() } ?? ""
        if host.hasSuffix("gemini.google.com") { return .gemini }
        if host.hasPrefix("notebooklm.") || host.hasPrefix("notebook.google.") { return .notebooklm }
        return .web
    }
}

extension Conversation {
    /// 掛件（藏起來的瀏覽器格子），不列在側欄
    var isGadget: Bool { gadgetOf != nil }
}

extension Store {
    /// 框的紫色：跟選中格子的紫框同一色（iTerm 配色第 13 色，跟著深淺色切）
    static let bundleAccent: NSColor = {
        let t = Theme.fromITerm()
        return NSColor(name: nil) { a in
            let pal = t.palette(for: a)
            return pal.ansi.count > 12 ? pal.ansi[12] : .controlAccentColor
        }
    }()

    /// 框裡的聊天室（照側欄順序）
    func bundleMembers(_ b: UUID) -> [Conversation] {
        conversations.filter { $0.bundle == b && !$0.isGadget }.sorted(by: orderedBefore)
    }

    /// 框的掛件，先加的在前（畫的時候最右邊）
    func gadgets(of b: UUID) -> [Conversation] {
        conversations.filter { $0.gadgetOf == b }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 在這段聊天室的框掛一個掛件（還沒有框就開一個只框它的）；回傳掛件
    @discardableResult
    func addGadget(_ kind: GadgetKind, url: String? = nil, to conv: UUID) -> Conversation? {
        guard let i = conversations.firstIndex(where: { $0.id == conv }), !conversations[i].isGadget else { return nil }
        let b = conversations[i].bundle ?? BundleAnim.shared.fresh(UUID())
        conversations[i].bundle = b
        var g = Conversation(projectID: conversations[i].projectID, title: kind.title)
        g.browser = url ?? kind.home
        g.gadgetOf = b
        conversations.append(g)
        return g
    }

    /// 側欄原本的瀏覽器格子改成掛在某段聊天室的框上（右鍵「改成掛件，掛在…」）
    func attachBrowser(_ browser: UUID, to conv: UUID) {
        guard let bi = conversations.firstIndex(where: { $0.id == browser }), conversations[bi].isBrowser, !conversations[bi].isGadget,
              let ci = conversations.firstIndex(where: { $0.id == conv }), !conversations[ci].isBrowser else { return }
        let b = conversations[ci].bundle ?? BundleAnim.shared.fresh(UUID())
        conversations[ci].bundle = b
        conversations[bi].bundle = nil
        conversations[bi].gadgetOf = b
    }

    /// 打開掛件：已經在目前 Window 就跳過去；不然（沒開、或開在別的 Window）搬到目前 Window 的最右邊（加一欄）
    func openGadget(_ id: UUID) {
        guard conversation(id)?.isGadget == true else { return }
        if currentWindow?.root?.contains(id) == true {
            if PaneSlide.shared.isLeaving(id) { PaneSlide.shared.slideIn(id) }   // 正在滑出去：從目前位置彈回來
            show(id)
        } else { appendRight(id, animated: true) }
        selected = id
    }

    /// 一般的聊天室格子（不是瀏覽器、終端機、草稿、掛件）
    static func isChat(_ c: Conversation) -> Bool { !c.isBrowser && c.terminal != true && c.draft != true && !c.isGadget }

    /// ⌘ ⇧ B（使用者 10/25）：選中聊天室時切換它那個框的掛件——
    /// 先把目前 Window 裡同一組、還沒在別的框的聊天室都框進來（別的框裡的不搶，免得那個框變空、掛件被刪）；
    /// 框的掛件在版面上 → 收起來（只是不顯示，掛件和網址都留著）；都沒顯示 → 打開最近用過的那個；還沒有掛件 → 掛一個 Gemini。都放最右邊
    func toggleBundle(from conv: UUID) {
        guard let c = conversation(conv), Store.isChat(c) else { return }
        let b = c.bundle ?? BundleAnim.shared.fresh(UUID())
        let g = groupOf(c)
        for id in [conv] + (currentWindow?.root?.leaves ?? []) {
            guard let i = conversations.firstIndex(where: { $0.id == id }), Store.isChat(conversations[i]),
                  conversations[i].bundle == nil || conversations[i].bundle == b, groupOf(conversations[i]) == g else { continue }
            conversations[i].bundle = b
        }
        let all = gadgets(of: b)
        // 只看目前 Window：掛件開在別的 Window 時當作沒開（openGadget 會把它搬過來），不要去收別的 Window 的
        let here = Set(currentWindow?.root?.leaves ?? [])
        let shown = all.filter { here.contains($0.id) && !PaneSlide.shared.isLeaving($0.id) }   // 正在滑出去的算已經收起來
        if !shown.isEmpty { hideGadgets(of: b); return }
        BundleAnim.shared.host[b] = conv   // 收起來時焦點回到打開它的這段
        if let last = all.max(by: { $0.lastOpened < $1.lastOpened }) { openGadget(last.id); return }
        if let n = addGadget(.gemini, to: conv) { openGadget(n.id) }
    }

    /// 收起目前 Window 裡這個框的掛件（不刪）；紫框原本在掛件上的話，回到打開它的那段聊天室（不在這個 Window 就找框裡別段，都沒有才是第一格）
    func hideGadgets(of b: UUID) {
        let here = Set(currentWindow?.root?.leaves ?? [])
        let onGadget = currentWindow?.focused.flatMap { conversation($0) }?.gadgetOf == b
        let going = gadgets(of: b).filter { here.contains($0.id) && !PaneSlide.shared.isLeaving($0.id) }.map(\.id)
        // 往右滑出去，滑完才真的從版面拿掉（中途再按 ⌘ ⇧ B 會從目前位置彈回來）
        for id in going {
            PaneSlide.shared.slideOut(id) { [weak self] in
                guard let self, PaneSlide.shared.isLeaving(id) == false, self.currentWindow?.root?.contains(id) == true else { return }
                let keep = self.currentWindow?.focused
                self.unplace(id)
                if let keep, keep != id, self.currentWindow?.root?.contains(keep) == true { self.editWindow { $0.focused = keep } }
            }
        }
        guard onGadget else { return }
        let left = Set(currentWindow?.root?.leaves ?? []).subtracting(going)
        let back = BundleAnim.shared.host[b].flatMap { left.contains($0) ? $0 : nil } ?? bundleMembers(b).first { left.contains($0.id) }?.id
        if let back { editWindow { $0.focused = back } }
    }

    /// 改聊天室在哪個框（nil＝離開）；框空了就收掉掛件
    func setBundle(_ conv: UUID, _ b: UUID?) {
        guard let i = conversations.firstIndex(where: { $0.id == conv }), !conversations[i].isGadget, conversations[i].bundle != b else { return }
        conversations[i].bundle = b
        pruneBundles()
    }

    /// 右鍵「解散」：聊天室留在原地，掛件刪掉
    func dissolveBundle(_ b: UUID) {
        for i in conversations.indices where conversations[i].bundle == b { conversations[i].bundle = nil }
        pruneBundles()
    }

    /// 整個框搬到另一組（拖掛件列到組標題上）
    func moveBundle(_ b: UUID, toGroup g: UUID) {
        // 不走 move(_:toGroup:)：一段一段搬的時候，先搬的會因為「跟框裡其他段不同組」被踢出框
        for i in conversations.indices where conversations[i].bundle == b && !conversations[i].isGadget {
            conversations[i].groupID = project(conversations[i].projectID)?.groupID == g ? nil : g
        }
    }

    /// 自己封存的聊天室離開框；一段聊天室都不剩的框，掛件（和記著的網址）刪掉
    func pruneBundles() {
        for i in conversations.indices where conversations[i].bundle != nil && conversations[i].manualArchive == true {
            conversations[i].bundle = nil
        }
        let live = Set(conversations.filter { !$0.isGadget }.compactMap(\.bundle))
        let orphans = Set(conversations.filter { $0.gadgetOf.map { !live.contains($0) } ?? false }.map(\.id))
        guard !orphans.isEmpty else { return }
        conversations.removeAll { orphans.contains($0.id) }
        ensureLayout()
    }
}

/// 側欄的掛件框：紫框包住「{＋聊天室」和底下的掛件列，中間一條兩端不碰框的紫線
struct BundleBox<Rows: View>: View {
    @Environment(\.uiScale) private var s
    let bundle: UUID
    let gadgets: [Conversation]
    /// 目前 Window 顯示中的掛件（沒在裡面的圖示半暗）
    var shownGadgets: Set<UUID> = []
    var depth = 0
    var onOpen: (UUID) -> Void
    var onRemoveGadget: (UUID) -> Void
    var onDissolve: () -> Void
    /// 拖聊天室到掛件列上放開＝加入這個框（排在最後）
    var onDropConversation: (UUID) -> Void
    /// 掛件列的拖曳內容（拖到組標題上＝整個框搬過去）
    var dragItem: () -> NSItemProvider
    @ViewBuilder var rows: () -> Rows
    @State private var confirmDissolve = false
    @State private var barTargeted = false
    /// 描邊動畫開始的時間（框剛建立、第一次出現時）；nil＝畫好的樣子
    @State private var animStart: Date?
    @ObservedObject private var anim = BundleAnim.shared

    private var accent: Color { Color(nsColor: Store.bundleAccent) }

    var body: some View {
        TimelineView(.animation(paused: animStart == nil && anim.frozen == nil)) { ctx in
            box(elapsed: anim.frozen ?? animStart.map { ctx.date.timeIntervalSince($0) } ?? BundleAnim.duration)
        }
        .onAppear {
            guard anim.take(bundle), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            animStart = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + BundleAnim.duration + 0.1) { animStart = nil }
        }
    }

    @ViewBuilder
    private func box(elapsed t: Double) -> some View {
        let f = min(1, max(0, t / BundleAnim.duration))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 「{」由上往下描，跟分隔線一樣過一半開始放慢（使用者 10/25：「{由上至下，一樣0.8，快到慢」）
                BraceShape().trim(from: 0, to: BundleAnim.progress(t, slowFrom: 0.5))
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 9 * s).padding(.vertical, 6).padding(.leading, 8)
                VStack(alignment: .leading, spacing: 2) { rows() }
            }
            // 分隔線：由左往右，到中間開始放慢（p＝0.5）
            HLine().trim(from: 0, to: BundleAnim.progress(t, slowFrom: 0.5))
                .stroke(accent.opacity(0.7), lineWidth: 1).frame(height: 1).padding(.horizontal, 12)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                // 由右往左：先加的在最右邊
                ForEach(gadgets.reversed()) { g in
                    GadgetIcon(gadget: g, accent: accent, shown: shownGadgets.contains(g.id)) { onOpen(g.id) }
                        .transition(.opacity)
                        .contextMenu {
                            Button("打開") { onOpen(g.id) }
                            Button("拿掉這個掛件（記著的網址也刪掉）", role: .destructive) { onRemoveGadget(g.id) }
                        }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .opacity(max(0, min(1, (f - 0.4) / 0.6)))   // 掛件圖示在後半段淡入
            .animation(.easeOut(duration: 0.25), value: gadgets.map(\.id))   // 已經有框、再多掛一個：新圖示淡入
            .frame(maxWidth: .infinity)
            .background(barTargeted ? accent.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .onDrag(dragItem)
            .onDrop(of: [.text], isTargeted: $barTargeted) { _ in
                guard let d = ReorderDrop.dragging, Date().timeIntervalSince(d.at) < 60 else { return false }
                ReorderDrop.dragging = nil
                onDropConversation(d.id)
                return true
            }
            .contextMenu {
                Button("解散這個框…") { confirmDissolve = true }
            }
            .help("掛件：點了在旁邊開一格。拖這一列到組的標題上＝整個框搬過去；把聊天室拖到這裡＝加入這個框")
        }
        // 外框：從上緣正中間逆時針畫一圈，畫到右邊中間開始放慢、回到起點剛好停
        .overlay(GeometryReader { g in
            let p = BundleOutline.slowPoint(g.size, radius: 9)
            BundleOutline(radius: 9).trim(from: 0, to: BundleAnim.progress(t, slowFrom: p)).stroke(accent, lineWidth: 1.5)
        })
        .padding(.leading, CGFloat(depth) * 16 * s + 4)
        .padding(.vertical, 3)
        .alert("解散這個框？", isPresented: $confirmDissolve) {
            Button("解散", role: .destructive, action: onDissolve)
            Button("取消", role: .cancel) {}
        } message: {
            Text("聊天室留在原地；掛件和記著的網址會刪掉。")
        }
    }
}

/// 掛件框的描邊動畫（使用者 10/25）：外框從上緣正中間逆時針畫一圈、分隔線由左往右、「{」由上往下，同時開始、同時結束，0.8 秒。
/// 速度：前段等速，畫到減速點（外框＝右邊中間、分隔線和「{」＝正中間）之後二次方放慢，到終點時速度剛好是 0。
final class BundleAnim: ObservableObject {
    static let shared = BundleAnim()
    static let duration = 0.8
    /// 剛建立的框（只播一次；2 秒內沒出現就不播了，例如那一組收著）
    private var fresh: [UUID: Date] = [:]
    /// 每個框最後是哪段聊天室用 ⌘ ⇧ B 打開的（收起來時紫框回到它；不存檔）
    var host: [UUID: UUID] = [:]
    /// 測試用：把所有框停在動畫的第幾秒（--bundle-anim）
    @Published var frozen: Double?

    func fresh(_ b: UUID) -> UUID { fresh[b] = Date(); return b }
    func take(_ b: UUID) -> Bool {
        guard let d = fresh.removeValue(forKey: b) else { return false }
        return Date().timeIntervalSince(d) < 2
    }

    /// 經過 t 秒畫到全長的多少（0…1）；p＝從哪裡開始放慢（佔全長的比例）
    /// 等速 v 走到 p，再用 2(1−p)/v 秒二次方減速到 0：p/v + 2(1−p)/v = 總時間 → v = (2−p)/總時間
    static func progress(_ t: Double, slowFrom p: Double) -> CGFloat {
        let T = duration
        guard t < T else { return 1 }
        guard t > 0 else { return 0 }
        let v = (2 - p) / T, t1 = p / v
        if t <= t1 { return CGFloat(v * t) }
        let d = 2 * (1 - p) / v, u = t - t1
        return CGFloat(min(1, p + v * u - v * u * u / (2 * d)))
    }
}

/// 掛件框的外框：圓角矩形，起點在上緣正中間，照畫面看逆時針（先往左、繞左邊下來、經過底邊、沿右邊往上回到起點）
struct BundleOutline: Shape {
    var radius: CGFloat
    func path(in r: CGRect) -> Path {
        let k = min(radius, r.width / 2, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + k, y: r.minY))
        p.addArc(center: CGPoint(x: r.minX + k, y: r.minY + k), radius: k, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - k))
        p.addArc(center: CGPoint(x: r.minX + k, y: r.maxY - k), radius: k, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY))
        p.addArc(center: CGPoint(x: r.maxX - k, y: r.maxY - k), radius: k, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + k))
        p.addArc(center: CGPoint(x: r.maxX - k, y: r.minY + k), radius: k, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        p.closeSubpath()
        return p
    }
    /// 右邊中間在整圈的哪個比例（從起點量）
    static func slowPoint(_ size: CGSize, radius: CGFloat) -> Double {
        let k = min(radius, size.width / 2, size.height / 2)
        let w = size.width, h = size.height, arc = Double.pi * k / 2
        let total = 2 * (w - 2 * k) + 2 * (h - 2 * k) + 4 * arc
        let toRightMid = (w / 2 - k) + arc + (h - 2 * k) + arc + (w - 2 * k) + arc + (h / 2 - k)
        return total > 0 ? Double(toRightMid / total) : 0.75
    }
}

/// 分隔線：由左往右
struct HLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

/// 框左邊的「{」
struct BraceShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let mid = r.midY, x0 = r.minX, x1 = r.maxX, xm = r.midX
        let k = min(r.width, r.height / 4)
        p.move(to: CGPoint(x: x1, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: xm, y: r.minY + k), control: CGPoint(x: xm, y: r.minY))
        p.addLine(to: CGPoint(x: xm, y: mid - k))
        p.addQuadCurve(to: CGPoint(x: x0, y: mid), control: CGPoint(x: xm, y: mid))
        p.addQuadCurve(to: CGPoint(x: xm, y: mid + k), control: CGPoint(x: xm, y: mid))
        p.addLine(to: CGPoint(x: xm, y: r.maxY - k))
        p.addQuadCurve(to: CGPoint(x: x1, y: r.maxY), control: CGPoint(x: xm, y: r.maxY))
        return p
    }
}

struct GadgetIcon: View {
    @Environment(\.uiScale) private var s
    let gadget: Conversation
    let accent: Color
    /// 目前 Window 有沒有顯示這個掛件：沒顯示就半暗、底色拿掉，像還沒觸發（使用者 10/26）；滑鼠移上去照舊會亮
    var shown = true
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        let kind = GadgetKind.of(gadget.browser)
        Image(systemName: kind.icon).font(.system(size: 13 * s, weight: .medium))
            .foregroundStyle(accent.opacity(shown || hover ? 1 : 0.4))
            .frame(width: 24 * s, height: 22 * s)
            .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(hover ? 0.2 : (shown ? 0.08 : 0))))
            .animation(.easeOut(duration: 0.15), value: shown)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hover = $0 }
            .help("\(kind.title)：\(gadget.title)\n\(gadget.browser ?? "")")
    }
}
