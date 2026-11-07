import AppKit
import SwiftUI

// 掛件框：側欄用紫框把幾段聊天室框在一起（左邊一個「{」），框底下一列掛件（Gemini、NotebookLM、任意網頁）
// 由右往左排，新加的在左邊。點掛件就在目前的 Window 開那一格。
// 資料：聊天室在哪個框＝Conversation.bundle；掛件是一格不列在側欄的瀏覽器（Conversation.gadgetOf＝哪個框），
// 網址照瀏覽器格子自己記（使用者換到別段 Gemini 對話，就記最後那個連結）。
// 進出框只看拖到哪裡：拖到框裡某一段的上下＝加入，拖到框外＝離開；移到別組、自己封存、刪掉也算離開。
// 框裡一段聊天室都不剩：掛件連同網址一起刪掉。

enum GadgetKind: String, CaseIterable {
    case gemini, notebooklm, web

    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .notebooklm: return "NotebookLM"
        case .web: return L("網頁")
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
        case .notebooklm: return "https://notebook.google.com/"
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
        guard Prefs.shared.webFeaturesEnabled else { return nil }
        guard let i = conversations.firstIndex(where: { $0.id == conv }), !conversations[i].isGadget else { return nil }
        let b = bundleForNewGadget(conv)
        conversations[i].bundle = b
        var g = Conversation(projectID: conversations[i].projectID, title: kind.title)
        g.browser = url ?? kind.home
        g.gadgetOf = b
        conversations.append(g)
        return g
    }

    /// 瀏覽器格換了網址：存成這格的網址，是 Gemini／NotebookLM 的話順便記成該網站的「最後網址」（其他網站不記）
    func noteBrowserURL(_ id: UUID, _ url: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if conversations[i].browser != url { conversations[i].browser = url }
        let k = GadgetKind.of(url)
        if k != .web, conversations[i].lastURLs?[k.rawValue] != url { conversations[i].lastURLs = (conversations[i].lastURLs ?? [:]).merging([k.rawValue: url]) { $1 } }
    }

    /// ⌥ 八宮格在瀏覽器格上選了 Gemini／NotebookLM：這一格原地換網站。回傳要載入的網址（先前這個網站的最後網址，沒有就首頁）；
    /// 這格已經在這個網站就回 nil（什麼都不做）。離開之前先把目前的網址記下來
    func switchBrowserSite(_ id: UUID, to kind: GadgetKind) -> String? {
        guard Prefs.shared.webFeaturesEnabled else { return nil }
        guard let i = conversations.firstIndex(where: { $0.id == id }), conversations[i].isBrowser else { return nil }
        let cur = conversations[i].browser ?? ""
        if GadgetKind.of(cur) == kind { return nil }
        if !cur.isEmpty, cur != BrowserPane.home { noteBrowserURL(id, cur) }
        let target = conversations[i].lastURLs?[kind.rawValue] ?? kind.home
        conversations[i].browser = target
        return target
    }

    /// 側欄原本的瀏覽器格子改成掛在某段聊天室的框上（右鍵「改成掛件，掛在…」）
    func attachBrowser(_ browser: UUID, to conv: UUID) {
        guard Prefs.shared.webFeaturesEnabled else { return }
        guard let bi = conversations.firstIndex(where: { $0.id == browser }), conversations[bi].isBrowser, !conversations[bi].isGadget,
              let ci = conversations.firstIndex(where: { $0.id == conv }), !conversations[ci].isBrowser else { return }
        let b = bundleForNewGadget(conv)
        conversations[ci].bundle = b
        conversations[bi].bundle = nil
        conversations[bi].gadgetOf = b
    }

    /// 打開掛件：已經在目前 Window 就跳過去；不然（沒開、或開在別的 Window）搬到目前 Window 的最右邊（加一欄）
    func openGadget(_ id: UUID) {
        guard Prefs.shared.webFeaturesEnabled else { return }
        guard conversation(id)?.isGadget == true else { return }
        if currentWindow?.root?.contains(id) == true {
            if PaneSlide.shared.isLeaving(id) { PaneSlide.shared.slideIn(id) }   // 正在滑出去：從目前位置彈回來
            show(id)
        } else { appendRight(id, animated: true) }
        selected = id
    }

    /// 預設的 Window 名字：「1」「2」或「Window 3」
    static func isDefaultWindowName(_ n: String) -> Bool {
        let t = n.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.allSatisfy(\.isNumber) || t.range(of: #"^Window \d+$"#, options: .regularExpression) != nil
    }

    /// 使用者取過名字的 Window 的聊天室框
    /// 聊天室 id → (Window 的 id, Window 名字)。每次現算，不存檔：聊天室放進／拿出 Window、Window 改名改回預設、關掉 Window，框都自己跟著變。
    /// 已經在掛件框裡的聊天室（Conversation.bundle）不搶：留在自己的框，掛件框不受影響
    var windowFrames: [UUID: (window: UUID, name: String)] {
        var out: [UUID: (UUID, String)] = [:]
        for s in sessions {
            for w in s.windows where w.renamed && !Store.isDefaultWindowName(w.name) {
                for id in w.root?.leaves ?? [] {
                    guard let c = conversation(id), Store.isChat(c), c.bundle == nil || c.bundle == w.id, out[id] == nil else { continue }
                    out[id] = (w.id, w.name)
                }
            }
        }
        // 關掉的 Window（Store.closed，會存進 state.json）：框和名字照留（⌃ ⌘ W 關掉後紫框和標題不該消失）。
        // 聊天室現在已經在別的 Window 裡的不算（那邊自己決定框）；Window 被 ⌘ ⇧ T 或側欄點聊天室找回來後，就變回上面開著的那一種
        for item in Store.closed.reversed() {
            guard case .window(_, _, let w, _) = item, w.renamed, !Store.isDefaultWindowName(w.name) else { continue }
            for id in w.root?.leaves ?? [] {
                guard out[id] == nil, locate(id) == nil, let c = conversation(id), Store.isChat(c), c.bundle == nil || c.bundle == w.id else { continue }
                out[id] = (w.id, w.name)
            }
        }
        return out
    }

    /// 這個框編號如果是取過名字的 Window，回傳 Window 名字（框上顯示）；掛件掛在這種框上＝掛在那個 Window 上
    func windowName(ofBundle b: UUID) -> String? {
        for s in sessions { for w in s.windows where w.id == b && w.renamed && !Store.isDefaultWindowName(w.name) { return w.name } }
        for case .window(_, _, let w, _) in Store.closed.reversed() where w.id == b && w.renamed && !Store.isDefaultWindowName(w.name) { return w.name }
        return nil
    }

    /// 聊天室要掛掛件時用哪個框：已經在框裡就那個；在取過名字的 Window 裡＝那個 Window 的框（掛件跟著 Window）；都不是就開新的
    func bundleForNewGadget(_ conv: UUID) -> UUID {
        if let b = conversation(conv)?.bundle { return b }
        if let f = windowFrames[conv] { return f.window }
        return BundleAnim.shared.fresh(UUID())
    }

    /// 聊天室被拿出取過名字的 Window、或那個 Window 改回預設名字：它原本掛在 Window 框上的 bundle 記號要處理掉。
    /// 框裡還有留在 Window 的成員：離開的聊天室單獨離開，框和掛件不動。
    /// 一個留下的成員都沒有（名字清空、改回預設、最後一個成員被移出）：框有掛件就把剩下的成員連同掛件一起搬到一個新的一般掛件框
    /// （掛件和記著的網址都留著，不能因為改個名字就丟掉）；沒有掛件才單純清掉記號
    func syncWindowBundles() {
        guard Prefs.shared.webFeaturesEnabled else { return }
        let wins = Dictionary(sessions.flatMap(\.windows).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        let bundles = Set(conversations.compactMap { $0.isGadget ? nil : $0.bundle })
            .union(conversations.compactMap { $0.isGadget ? $0.gadgetOf : nil })
        for b in bundles {
            guard let w = wins[b] else { continue }
            let named = w.renamed && !Store.isDefaultWindowName(w.name)
            func valid(_ c: Conversation) -> Bool { named && w.root?.contains(c.id) == true }
            let members = conversations.indices.filter { conversations[$0].bundle == b && !conversations[$0].isGadget }
            // 只靠版面歸屬的聊天室：具名時留下；名字清掉且有掛件時，一起接到新框
            let rooted = conversations.indices.filter { conversations[$0].bundle == nil && Store.isChat(conversations[$0]) && w.root?.contains(conversations[$0].id) == true }
            let hasGadgets = !gadgets(of: b).isEmpty
            let stay = members.filter { valid(conversations[$0]) } + (named ? rooted : [])
            let leave = members.filter { !valid(conversations[$0]) } + (!named && hasGadgets ? rooted : [])
            guard !leave.isEmpty else { continue }
            if stay.isEmpty, hasGadgets {
                let nb = BundleAnim.shared.fresh(UUID())
                for i in leave { conversations[i].bundle = nb }
                for i in conversations.indices where conversations[i].gadgetOf == b { conversations[i].gadgetOf = nb }
            } else {
                for i in leave { conversations[i].bundle = nil }
            }
            changed = true
        }
        if changed { pruneBundles() }
    }

    /// 一般的聊天室格子（不是瀏覽器、終端機、草稿、掛件）
    static func isChat(_ c: Conversation) -> Bool { !c.isBrowser && c.terminal != true && c.draft != true && !c.isGadget }

    /// ⌘ ⇧ B：選中聊天室時切換它那個框的掛件——
    /// 先把目前 Window 裡同一組、還沒在別的框的聊天室都框進來（別的框裡的不搶，免得那個框變空、掛件被刪）；
    /// 框的掛件在版面上 → 收起來（只是不顯示，掛件和網址都留著）；都沒顯示 → 打開最近用過的那個；還沒有掛件 → 掛一個 Gemini。都放最右邊
    func toggleBundle(from conv: UUID) {
        guard Prefs.shared.webFeaturesEnabled else { return }
        guard let c = conversation(conv), Store.isChat(c) else { return }
        let b = bundleForNewGadget(conv)
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
        guard Prefs.shared.webFeaturesEnabled else { return }
        let here = Set(currentWindow?.root?.leaves ?? [])
        let onGadget = currentWindow?.focused.flatMap { conversation($0) }?.gadgetOf == b
        let going = gadgets(of: b).filter { here.contains($0.id) && !PaneSlide.shared.isLeaving($0.id) }.map(\.id)
        // 往右滑出去，滑完才真的從版面拿掉（中途再按 ⌘ ⇧ B 會從目前位置彈回來）
        for id in going {
            PaneSlide.shared.slideOut(id) { [weak self] in
                // 滑出去的 0.2 秒裡使用者切到別的 Window：掛件還在原本那個 Window 的版面裡，照樣拿掉（不要只看目前的 Window）
                guard let self, Prefs.shared.webFeaturesEnabled, PaneSlide.shared.isLeaving(id) == false, self.locate(id) != nil else { return }
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
        let gadgets = Set(conversations.filter { $0.gadgetOf == b }.map(\.id))
        conversations.removeAll { gadgets.contains($0.id) }
        gadgets.forEach { onConversationRemoved?($0) }
        if !gadgets.isEmpty { ensureLayout() }
        pruneBundles()
    }

    /// 整個框搬到另一組（拖掛件列到組標題上）
    func moveBundle(_ b: UUID, toGroup g: UUID) {
        // 不走 move(_:toGroup:)：一段一段搬的時候，先搬的會因為「跟框裡其他段不同組」被踢出框
        let frames = windowFrames   // 取過名字的 Window 的框：成員的 bundle 是 nil，要靠這個才找得到
        for i in conversations.indices where !conversations[i].isGadget && (conversations[i].bundle == b || frames[conversations[i].id]?.window == b) {
            conversations[i].groupID = project(conversations[i].projectID)?.groupID == g ? nil : g
        }
    }

    /// 自己封存的聊天室離開框；一段聊天室都不剩的框，掛件（和記著的網址）刪掉
    func pruneBundles() {
        for i in conversations.indices where conversations[i].bundle != nil && conversations[i].manualArchive == true {
            conversations[i].bundle = nil
        }
        // 取過名字的 Window 的框，成員的 bundle 平常是 nil（現算出來的，見 windowFrames）：也要算「活著」，不然掛在那個框上的掛件會被當成孤兒刪掉
        let live = Set(conversations.filter { !$0.isGadget }.compactMap(\.bundle)).union(windowFrames.values.map(\.window))
        let orphans = Set(conversations.filter { $0.gadgetOf.map { !live.contains($0) } ?? false }.map(\.id))
        guard !orphans.isEmpty else { return }
        conversations.removeAll { orphans.contains($0.id) }
        orphans.forEach { onConversationRemoved?($0) }
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
    /// 取過名字的 Window 的框：外觀跟掛件框一樣，名字（小字、紫色）放在框裡上方；沒有掛件就不畫下面那排掛件區
    var windowTitle: String? = nil
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
            if let t = windowTitle {
                Text(t).font(.system(size: 10.5 * s, weight: .medium)).foregroundStyle(accent).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 5)
                    .help(L("Window「\(t)」裡的聊天室"))
            }
            // 一行一個：掛件圖示放在名字那一行的右邊，不再另起一排、不畫分隔線
            HStack(alignment: .center, spacing: 0) {
                // 「{」由上往下描，跟原本一樣過一半開始放慢
                BraceShape().trim(from: 0, to: BundleAnim.progress(t, slowFrom: 0.5))
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 8 * s).padding(.vertical, 4).padding(.leading, 7)
                VStack(alignment: .leading, spacing: 1) { rows() }
                gadgetBar(fade: f)
            }
        }
        // 外框：從上緣正中間逆時針畫一圈，畫到右邊中間開始放慢、回到起點剛好停
        .overlay(GeometryReader { g in
            let p = BundleOutline.slowPoint(g.size, radius: 9)
            BundleOutline(radius: 9).trim(from: 0, to: BundleAnim.progress(t, slowFrom: p)).stroke(accent, lineWidth: 1.5)
        })
        .padding(.leading, CGFloat(depth) * 16 * s + 4)
        .padding(.vertical, 2)
        .alert(L("解散這個框？"), isPresented: $confirmDissolve) {
            Button(L("解散"), role: .destructive, action: onDissolve)
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("聊天室留在原地；掛件和記著的網址會刪掉。"))
        }
    }

    /// 掛件圖示（右邊、由右往左）＋拖曳把手：拖這裡到組標題＝整個框搬過去；把聊天室拖到這裡＝加入這個框
    @ViewBuilder
    private func gadgetBar(fade f: Double) -> some View {
        HStack(spacing: 5) {
            if gadgets.isEmpty {
                // 沒有掛件也要有地方拖整個框、放聊天室進來
                Image(systemName: "line.3.horizontal").font(.system(size: 10 * s)).foregroundStyle(accent.opacity(0.55))
                    .frame(width: 22 * s, height: 20 * s)   // 拖曳把手要好瞄準
            }
            ForEach(gadgets.reversed()) { g in
                GadgetIcon(gadget: g, accent: accent, shown: shownGadgets.contains(g.id)) { onOpen(g.id) }
                    .transition(.opacity)
                    .contextMenu {
                        Button(L("打開")) { onOpen(g.id) }
                        Button(L("拿掉這個掛件（記著的網址也刪掉）"), role: .destructive) { onRemoveGadget(g.id) }
                    }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .opacity(max(0, min(1, (f - 0.4) / 0.6)))   // 掛件圖示在後半段淡入
        .animation(.easeOut(duration: 0.25), value: gadgets.map(\.id))
        .background(RoundedRectangle(cornerRadius: 5).fill(barTargeted ? accent.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onDrag(dragItem)
        .onDrop(of: [.text], isTargeted: $barTargeted) { _ in
            guard let d = ReorderDrop.dragging, Date().timeIntervalSince(d.at) < 60 else { return false }
            ReorderDrop.dragging = nil
            onDropConversation(d.id)
            return true
        }
        .contextMenu {
            Button(L("解散這個框…")) { confirmDissolve = true }
        }
        .help(L("掛件：點了在旁邊開一格。拖這裡到組的標題上＝整個框搬過去；把聊天室拖到這裡＝加入這個框"))
    }
}

/// 掛件框的描邊動畫：外框從上緣正中間逆時針畫一圈、分隔線由左往右、「{」由上往下，同時開始、同時結束，0.8 秒。
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
    /// 目前 Window 有沒有顯示這個掛件：沒顯示就半暗、底色拿掉，像還沒觸發；滑鼠移上去照舊會亮
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
