import SwiftUI
import AppKit

// ⌘ , 設定視窗：「視窗」頁（Session → Window → Pane 的樹，可拖曳整理、改名、預覽分割）、「外觀」頁（字型、大小、行距）。
// 之後：「按鍵」頁。

final class AppearanceSettings: ObservableObject {
    @Published var fontName: String { didSet { save() } }
    @Published var fontSize: Double { didSet { save() } }
    @Published var lineSpacing: Double { didSet { save() } }
    var onChange: (() -> Void)?
    private let d = appDefaults

    init() {
        let it = Theme.fromITerm()
        fontName = d.string(forKey: "fontName") ?? it.font.fontName
        fontSize = d.object(forKey: "fontSize") as? Double ?? Double(it.font.pointSize)
        lineSpacing = d.object(forKey: "lineSpacing") as? Double ?? Double(it.lineSpacing)
    }

    private func save() {
        d.set(fontName, forKey: "fontName")
        d.set(fontSize, forKey: "fontSize")
        d.set(lineSpacing, forKey: "lineSpacing")
        onChange?()
    }

    /// iTerm 的配色＋這裡設的字型
    var theme: Theme {
        var t = Theme.fromITerm()
        if let f = NSFont(name: fontName, size: CGFloat(fontSize)) {
            t.font = f
            t.boldFont = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
        }
        t.lineSpacing = CGFloat(lineSpacing)
        return t
    }

    func resetToITerm() {
        let it = Theme.fromITerm()
        fontName = it.font.fontName
        fontSize = Double(it.font.pointSize)
        lineSpacing = Double(it.lineSpacing)
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var appearance: AppearanceSettings

    /// 記住上次看的分頁
    @State private var tab = appDefaults.string(forKey: "settingsTab") ?? "windows"

    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { tab = $0; appDefaults.set($0, forKey: "settingsTab") })) {
            WindowsPage(store: store).tabItem { Label(L("視窗"), systemImage: "rectangle.3.group") }.tag("windows")
            ChatPrefsPage().tabItem { Label(L("對話"), systemImage: "bubble.left.and.bubble.right") }.tag("chat")
            AppearancePage(appearance: appearance).tabItem { Label(L("外觀"), systemImage: "textformat") }.tag("appearance")
            PetPrefsPage().tabItem { Label(L("桌寵與用量"), systemImage: "pawprint") }.tag("pet")
            KeysPage().tabItem { Label(L("按鍵"), systemImage: "keyboard") }.tag("keys")
            LocalModelsPage().tabItem { Label(L("本機模型"), systemImage: "cpu") }.tag("local")
            SchedulesPage(store: store).tabItem { Label(L("排程"), systemImage: "clock") }.tag("schedules")
            DataPage(store: store).tabItem { Label(L("資料"), systemImage: "folder") }.tag("data")
        }
        .frame(width: 860, height: 580)
        .padding()
    }
}

// MARK: 「視窗」頁：Session → Window → Pane 的樹，可以拖曳整理

/// 樹裡的一列（也是拖曳的東西）
enum TreeItem: Hashable {
    case session(UUID), window(UUID), pane(UUID), conv(UUID)
    case unplaced            // 「沒擺在任何 Window 的對話」那一區（只當放下的目標）
}

/// 正在拖什麼、停在哪一列上（同一個 App 裡拖，直接記在這裡，不用解析剪貼簿）
final class TreeDrag: ObservableObject {
    @Published var dragging: TreeItem?
    @Published var hover: TreeItem?
    @Published var hoverAfter = false
}

struct TreeDropDelegate: DropDelegate {
    let target: TreeItem
    let height: CGFloat
    @ObservedObject var drag: TreeDrag
    let accepts: (TreeItem, TreeItem) -> Bool
    let perform: (TreeItem, TreeItem, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { drag.dragging.map { accepts($0, target) } ?? false }
    func dropEntered(info: DropInfo) { mark(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { mark(info); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if drag.hover == target { drag.hover = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let d = drag.dragging, accepts(d, target) else { return false }
        let after = info.location.y > height / 2
        drag.hover = nil
        drag.dragging = nil
        perform(d, target, after)
        return true
    }
    private func mark(_ info: DropInfo) {
        if drag.hover != target { drag.hover = target }
        let after = info.location.y > height / 2
        if drag.hoverAfter != after { drag.hoverAfter = after }
    }
}

/// 小圖示：把 Window 的分割畫成縮圖，這格塗滿
struct MiniLayout: View {
    let root: PaneNode?
    let highlight: UUID?
    var body: some View {
        Canvas { ctx, size in
            let rects = root?.rects() ?? [:]
            for (id, r) in rects {
                let f = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height).insetBy(dx: 0.75, dy: 0.75)
                let path = Path(roundedRect: f, cornerRadius: 1.5)
                if id == highlight { ctx.fill(path, with: .color(.accentColor)) }
                ctx.stroke(path, with: .color(.secondary), lineWidth: 1)
            }
        }
        .frame(width: 20, height: 14)
    }
}

struct WindowsPage: View {
    @ObservedObject var store: Store
    @StateObject private var drag = TreeDrag()
    @State private var selection: TreeItem?
    @State private var editing: TreeItem?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var collapsed: Set<UUID> = []
    @State private var askDeleteSession: UUID?

    private let rowH: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("拖曳 Pane 到別的 Window；拖 Window、Session 調順序。拖到「沒擺的對話」就從版面拿掉（對話不會刪）。點一下切過去，點兩下改名。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { si, s in sessionBlock(si, s) }
                            unplacedBlock.padding(.top, 10)
                        }
                        .padding(.vertical, 6)
                    }
                    Divider()
                    toolbar
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .frame(maxWidth: .infinity)

                preview.frame(width: 320)
            }
        }
        .alert(deleteSessionTitle, isPresented: Binding(get: { askDeleteSession != nil }, set: { if !$0 { askDeleteSession = nil } })) {
            Button(L("刪除"), role: .destructive) { if let id = askDeleteSession { store.deleteSession(id) }; askDeleteSession = nil }
            Button(L("取消"), role: .cancel) { askDeleteSession = nil }
        } message: {
            Text(L("只刪版面，裡面的對話都會留在側欄和「沒擺的對話」。"))
        }
    }

    private var deleteSessionTitle: String {
        let name = askDeleteSession.flatMap { id in store.sessions.first { $0.id == id }?.name } ?? ""
        return L("刪除 Session「\(name)」？")
    }

    // MARK: 樹

    @ViewBuilder private func sessionBlock(_ si: Int, _ s: SessionLayout) -> some View {
        let open = !collapsed.contains(s.id)
        row(.session(s.id), indent: 0) {
            chevron(s.id)
            Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
            nameField(.session(s.id), s.name).font(.headline)
            if store.currentSession == s.id { badge(L("目前")) }
            Spacer(minLength: 4)
            Text(L("\(s.windows.count) 個 Window")).font(.caption).foregroundStyle(.tertiary)
        }
        if open {
            ForEach(Array(s.windows.enumerated()), id: \.element.id) { wi, w in windowBlock(s, wi, w) }
        }
    }

    @ViewBuilder private func windowBlock(_ s: SessionLayout, _ wi: Int, _ w: WindowLayout) -> some View {
        let isCurrent = (s.current ?? s.windows.first?.id) == w.id
        row(.window(w.id), indent: 18) {
            if w.root == nil { Color.clear.frame(width: 12) } else { chevron(w.id) }
            Text("[\(wi + 1)]").monospacedDigit().foregroundStyle(.secondary)
            nameField(.window(w.id), store.displayName(w))
            if isCurrent && store.currentSession == s.id { badge(L("目前")) }
            else if isCurrent { Circle().fill(Color.secondary).frame(width: 5, height: 5).help(L("這個 Session 目前的 Window")) }
            Spacer(minLength: 4)
            if w.zoomed { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(.secondary).help(L("放大中")) }
            if w.root == nil { Text(L("空的")).font(.caption).foregroundStyle(.tertiary) }
        }
        if !collapsed.contains(w.id), let root = w.root {
            ForEach(root.leaves, id: \.self) { c in paneRow(w, root, c) }
        }
    }

    @ViewBuilder private func paneRow(_ w: WindowLayout, _ root: PaneNode, _ c: UUID) -> some View {
        let path = store.panePath(c)
        row(.pane(c), indent: 36 + CGFloat(max(0, path.count - 1)) * 10) {
            MiniLayout(root: root, highlight: c).help(pathText(path))
            nameField(.pane(c), store.conversation(c)?.title ?? L("（對話不見了）"))
            if w.focused == c { Image(systemName: "keyboard").font(.caption).foregroundStyle(Color.accentColor).help(L("目前在打字的那格")) }
            Spacer(minLength: 4)
            if let last = path.last { Text(sideText(last)).font(.caption).foregroundStyle(.tertiary) }
        }
    }

    @ViewBuilder private var unplacedBlock: some View {
        let list = store.unplacedConversations
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "tray").foregroundStyle(.secondary)
                Text(L("沒擺在任何 Window 的對話")).font(.headline)
                Spacer()
                Text("\(list.count)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).frame(height: rowH)
            if list.isEmpty {
                Text(L("把 Pane 拖到這裡，就會從版面拿掉（對話留著）。"))
                    .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 26).frame(height: rowH)
            }
            ForEach(store.projects) { p in
                let convs = list.filter { $0.projectID == p.id }.sorted { $0.createdAt > $1.createdAt }
                if !convs.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(p.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 18).frame(height: rowH)
                    ForEach(convs) { c in
                        row(.conv(c.id), indent: 36) {
                            Image(systemName: c.isBrowser ? "globe" : c.terminal == true ? "terminal" : "bubble.left").foregroundStyle(.secondary).frame(width: 20)
                            nameField(.conv(c.id), c.title)
                            Spacer(minLength: 4)
                            Text(c.lastOpened, style: .relative).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(drag.hover == .unplaced ? Color.accentColor.opacity(0.12) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(drag.hover == .unplaced ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .padding(.horizontal, 4)
        .onDrop(of: [.text], delegate: TreeDropDelegate(target: .unplaced, height: .infinity, drag: drag, accepts: accepts, perform: perform))
    }

    /// 一列：選取底色、放下提示、點一下／兩下、拖曳、右鍵選單
    private func row<C: View>(_ item: TreeItem, indent: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        let hovered = drag.hover == item && drag.dragging.map { accepts($0, item) } == true
        let line = hovered && drag.dragging.map { isReorder($0, item) } == true
        return HStack(spacing: 6) { content() }
            .padding(.leading, 8 + indent).padding(.trailing, 8)
            .frame(height: rowH)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(
                    hovered && !line ? Color.accentColor.opacity(0.22)
                    : selection == item ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(alignment: drag.hoverAfter ? .bottom : .top) {
                if line { Rectangle().fill(Color.accentColor).frame(height: 2).padding(.leading, 8 + indent) }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginRename(item) }
            .onTapGesture { activate(item) }
            .onDrag {
                drag.dragging = item
                return NSItemProvider(object: String(describing: item) as NSString)
            }
            .onDrop(of: [.text], delegate: TreeDropDelegate(target: item, height: rowH, drag: drag, accepts: accepts, perform: perform))
            .contextMenu { menu(item) }
            .accessibilityElement(children: editing == item ? .contain : .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate(item) }
            .accessibilityAction(named: Text(L("改名"))) { beginRename(item) }
    }

    private func chevron(_ id: UUID) -> some View {
        Button {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        } label: {
            Image(systemName: collapsed.contains(id) ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed.contains(id) ? L("展開") : L("收合"))
    }

    private func badge(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
    }

    /// 名字：改名中就換成輸入框
    @ViewBuilder private func nameField(_ item: TreeItem, _ name: String) -> some View {
        if editing == item {
            TextField(L("名稱"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { editing = nil }
                .onChange(of: fieldFocused) { _, f in if !f && editing == item { commitRename() } }
                .frame(maxWidth: 260)
        } else {
            Text(name).lineLimit(1).truncationMode(.tail)
        }
    }

    private func pathText(_ path: [(vertical: Bool, second: Bool)]) -> String {
        if path.isEmpty { return L("唯一一格") }
        return path.map { step in step.vertical ? (step.second ? L("上下切的下面") : L("上下切的上面")) : (step.second ? L("左右切的右邊") : L("左右切的左邊")) }
            .joined(separator: " → ")
    }

    private func sideText(_ step: (vertical: Bool, second: Bool)) -> String {
        step.vertical ? (step.second ? L("下") : L("上")) : (step.second ? L("右") : L("左"))
    }

    // MARK: 動作

    private func activate(_ item: TreeItem) {
        if editing != nil && editing != item { commitRename() }
        selection = item
        switch item {
        case .session(let id): store.selectSession(id)
        case .window(let id): store.selectWindow(id: id)
        case .pane(let c): store.focusPane(c)
        case .conv, .unplaced: break
        }
    }

    private func currentName(_ item: TreeItem) -> String? {
        switch item {
        case .session(let id): return store.sessions.first { $0.id == id }?.name
        case .window(let id): return store.windowPosition(id).map { store.displayName(store.sessions[$0.0].windows[$0.1]) }
        case .pane(let c), .conv(let c): return store.conversation(c)?.title
        case .unplaced: return nil
        }
    }

    private func beginRename(_ item: TreeItem) {
        guard let name = currentName(item) else { return }
        selection = item
        draft = name
        editing = item
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitRename() {
        guard let item = editing else { return }
        editing = nil
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != currentName(item) else { return }
        switch item {
        case .session(let id): store.renameSession(id, to: t)
        case .window(let id): store.renameWindow(id, to: t)
        case .pane(let c), .conv(let c): store.rename(c, to: t, byUser: true)
        case .unplaced: break
        }
    }

    private func delete(_ item: TreeItem) {
        switch item {
        case .session(let id): askDeleteSession = id
        case .window(let id): store.deleteWindow(id); selection = nil
        case .pane(let c): store.unplace(c); selection = .conv(c)
        case .conv, .unplaced: break
        }
    }

    /// 新 Window 要加在哪個 Session：選中的那個（或選中的東西所在的），不然目前的
    private var targetSession: UUID? {
        switch selection {
        case .session(let id): return id
        case .window(let id): return store.windowPosition(id).map { store.sessions[$0.0].id }
        case .pane(let c): return store.locate(c).map { store.sessions[$0.0].id }
        default: return store.currentSessionLayout?.id
        }
    }

    @ViewBuilder private func menu(_ item: TreeItem) -> some View {
        switch item {
        case .session(let id):
            Button(L("切到這個 Session")) { activate(item) }
            Button(L("改名")) { beginRename(item) }
            Button(L("新增 Window")) { if let w = store.addWindow(toSession: id) { selection = .window(w) } }
            Divider()
            Button(L("刪除 Session…")) { delete(item) }
        case .window:
            Button(L("切到這個 Window")) { activate(item) }
            Button(L("改名")) { beginRename(item) }
            Divider()
            Button(L("刪除 Window（對話留著）")) { delete(item) }
        case .pane:
            Button(L("把焦點設到這格")) { activate(item) }
            Button(L("改對話名稱")) { beginRename(item) }
            Divider()
            Button(L("從版面拿掉（對話留著）")) { delete(item) }
        case .conv(let c):
            if let w = store.currentWindow {
                Button(L("放進目前的 Window「\(store.displayName(w))」")) { store.movePane(c, toWindow: w.id); selection = .pane(c) }
            }
            if let s = store.currentSessionLayout {
                Button(L("在新 Window 打開")) { store.movePaneToNewWindow(c, inSession: s.id); selection = .pane(c) }
            }
            Button(L("改名")) { beginRename(item) }
        case .unplaced:
            EmptyView()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { let id = store.addSession(); selection = .session(id); beginRename(.session(id)) } label: { Label(L("新增 Session"), systemImage: "plus") }
            Button {
                if let sid = targetSession, let w = store.addWindow(toSession: sid) { collapsed.remove(sid); selection = .window(w) }
            } label: { Label(L("新增 Window"), systemImage: "plus.rectangle") }
            Spacer()
            Button(L("改名")) { if let s = selection { beginRename(s) } }
                .disabled(selection == nil || selection == .unplaced)
            Button(role: .destructive) { if let s = selection { delete(s) } } label: { Text(deleteLabel) }
                .disabled(deleteLabel.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var deleteLabel: String {
        switch selection {
        case .session: return L("刪除 Session…")
        case .window: return L("刪除 Window")
        case .pane: return L("從版面拿掉")
        default: return ""
        }
    }

    // MARK: 拖曳規則

    private func isReorder(_ d: TreeItem, _ t: TreeItem) -> Bool {
        switch (d, t) {
        case (.window, .window), (.session, .session): return true
        default: return false
        }
    }

    private func accepts(_ d: TreeItem, _ t: TreeItem) -> Bool {
        switch (d, t) {
        case (.pane(let a), .pane(let b)): return a != b
        case (.conv, .pane), (.pane, .window), (.conv, .window), (.pane, .session), (.conv, .session): return true
        case (.pane, .unplaced), (.pane, .conv): return true
        case (.window(let a), .window(let b)): return a != b
        case (.window, .session): return true
        case (.session(let a), .session(let b)): return a != b
        default: return false
        }
    }

    private func perform(_ d: TreeItem, _ t: TreeItem, _ after: Bool) {
        switch (d, t) {
        case (.pane(let c), .window(let w)), (.conv(let c), .window(let w)):
            store.movePane(c, toWindow: w); selection = .pane(c)
        case (.pane(let c), .pane(let p)), (.conv(let c), .pane(let p)):
            if let (si, wi) = store.locate(p) { store.movePane(c, toWindow: store.sessions[si].windows[wi].id, beside: p); selection = .pane(c) }
        case (.pane(let c), .session(let s)), (.conv(let c), .session(let s)):
            store.movePaneToNewWindow(c, inSession: s); selection = .pane(c)
        case (.pane(let c), .unplaced), (.pane(let c), .conv):
            store.unplace(c); selection = .conv(c)
        case (.window(let w), .window(let o)):
            guard let (ti, oi) = store.windowPosition(o) else { return }
            store.moveWindow(w, toSession: store.sessions[ti].id, at: oi + (after ? 1 : 0))
            selection = .window(w)
        case (.window(let w), .session(let s)):
            guard let ti = store.sessionPosition(s) else { return }
            store.moveWindow(w, toSession: s, at: store.sessions[ti].windows.count)
            collapsed.remove(s)
            selection = .window(w)
        case (.session(let s), .session(let o)):
            guard let oi = store.sessionPosition(o) else { return }
            store.moveSession(s, to: oi + (after ? 1 : 0))
            selection = .session(s)
        default: break
        }
    }

    // MARK: 預覽

    /// 預覽哪個 Window：選中的 Window／Pane 所在的／Session 目前的，都沒有就主畫面目前的
    private var previewWindow: (SessionLayout, Int, WindowLayout)? {
        func at(_ si: Int, _ wi: Int) -> (SessionLayout, Int, WindowLayout) { (store.sessions[si], wi, store.sessions[si].windows[wi]) }
        switch selection {
        case .window(let id): if let (si, wi) = store.windowPosition(id) { return at(si, wi) }
        case .pane(let c): if let (si, wi) = store.locate(c) { return at(si, wi) }
        case .session(let id):
            if let si = store.sessionPosition(id), !store.sessions[si].windows.isEmpty {
                let s = store.sessions[si]
                return at(si, s.windows.firstIndex { $0.id == s.current } ?? 0)
            }
        default: break
        }
        guard let si = store.sessionIndex, let wi = store.windowIndex else { return nil }
        return at(si, wi)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let (s, wi, w) = previewWindow {
                Text("\(s.name) · [\(wi + 1)] \(store.displayName(w))").font(.headline).lineLimit(1)
                GeometryReader { geo in
                    let size = geo.size
                    if let root = w.root {
                        let rects = root.rects()
                        ZStack(alignment: .topLeading) {
                            ForEach(root.leaves, id: \.self) { c in
                                if let r = rects[c] { previewBox(w, c, CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)) }
                            }
                        }
                    } else {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(drag.hover == .window(w.id) ? Color.accentColor : Color.secondary)
                            .overlay(Text(L("空的 Window\n把對話拖進來")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center))
                            .onDrop(of: [.text], delegate: TreeDropDelegate(target: .window(w.id), height: size.height, drag: drag, accepts: accepts, perform: perform))
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                Text(L("點方框把焦點設到那格；把對話拖到方框上，會從那格往右切開。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("沒有 Window")).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func previewBox(_ w: WindowLayout, _ c: UUID, _ f: CGRect) -> some View {
        let focused = w.focused == c
        let hovered = drag.hover == .pane(c)
        let inner = f.insetBy(dx: 2, dy: 2)
        return RoundedRectangle(cornerRadius: 5)
            .fill(hovered ? Color.accentColor.opacity(0.3) : focused ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: focused ? 2 : 1))
            .overlay(
                Text(store.conversation(c)?.title ?? "").font(.caption).multilineTextAlignment(.center)
                    .lineLimit(3).padding(4)
            )
            .frame(width: max(0, inner.width), height: max(0, inner.height))
            .contentShape(Rectangle())
            .onTapGesture { store.focusPane(c); selection = .pane(c) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.focusPane(c); selection = .pane(c) }
            .onDrop(of: [.text], delegate: TreeDropDelegate(target: .pane(c), height: inner.height, drag: drag, accepts: accepts, perform: perform))
            .offset(x: inner.minX, y: inner.minY)
    }
}

struct AppearancePage: View {
    @ObservedObject var appearance: AppearanceSettings
    var body: some View {
        Form {
            InterfacePrefs()
            CodeColorsSection()
            Section(L("終端機")) {
            TextField(L("字型（PostScript 名稱）"), text: $appearance.fontName)
            Stepper(value: $appearance.fontSize, in: 9...40, step: 1) { Text(L("大小：\(Int(appearance.fontSize))")) }
            HStack {
                Text(L("行距"))
                Slider(value: $appearance.lineSpacing, in: 0.8...1.6)
                Text(String(format: "%.2f", appearance.lineSpacing)).monospacedDigit().frame(width: 44)
            }
            Text(L("顏色從 iTerm 的預設設定檔匯入，淺色、深色模式各一組，跟著系統外觀切換。"))
                .font(.callout).foregroundStyle(.secondary)
            Button(L("全部改回 iTerm 的設定")) { appearance.resetToITerm() }
            Text(L("範例：第 1 行 Claude Code 中文測試 ABCdef ●⎿✻"))
                .font(Font(NSFont(name: appearance.fontName, size: CGFloat(appearance.fontSize)) ?? .monospacedSystemFont(ofSize: 14, weight: .regular)))
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
    }
}

final class SettingsWindowController: NSWindowController {
    init(store: Store, appearance: AppearanceSettings) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("設定")
        w.contentViewController = NSHostingController(rootView: SettingsView(store: store, appearance: appearance))
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
}
