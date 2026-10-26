import SwiftUI

// 左側欄，照 Codex 的樣子：最左邊一條圖示列；旁邊是標題、新對話、專案（資料夾底下列對話）、最近項目

struct SidebarActions {
    var newConversation: () -> Void
    var addProject: () -> Void
    var openSettings: () -> Void
    var deleteConversation: (UUID) -> Void
    var removeProject: (UUID) -> Void
    var switchMode: (UUID, Bool) -> Void
    var compact: (UUID) -> Void
    var handoff: (UUID) -> Void = { _ in }
    var toggleSidebar: () -> Void = {}
    /// 程式碼學習專區的「新的練習」：選資料夾、在這一組開新聊天室
    var newCodeLab: () -> Void = {}
    var newBrowser: () -> Void = {}
    /// 對話右鍵「換工作資料夾…」（MoveFolder.swift）
    var changeFolder: (UUID) -> Void = { _ in }
    /// 最左邊的「協作」圖示：開關右邊的協作看板（CollabBoard.swift）
    var toggleCollab: () -> Void = {}
    /// 對話右鍵「排程…」（Schedule.swift）
    var schedule: (UUID) -> Void = { _ in }
}

struct SidebarView: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    let actions: SidebarActions
    @ObservedObject private var schedules = ScheduleStore.shared
    @ObservedObject private var update = UpdateCheck.shared
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var renamingGroup: ConvGroup?
    @State private var addingGroup = false
    @State private var addingParent: UUID?      // 新增子組：加在哪一組底下（nil＝最上層）
    @State private var topTargeted = false      // 把組拖到「分類」標題上＝移到最上層
    @State private var groupRenameText = ""
    /// 上面那顆封存按鈕：開著才在各組最下面列出封存的對話（記在 appDefaults）
    @State private var showArchived = appDefaults.bool(forKey: "sidebarShowArchived")
    @State private var dropGroup: UUID?     // 正被拖到上面的那一組（標題亮起來）
    /// 右鍵「掛網頁…」：要掛在哪段聊天室、網址
    @State private var addingWebFor: UUID?
    @State private var webURLText = ""
    /// 最左邊圖示列選的是哪一區：home＝首頁（各組）、codelab＝程式碼學習專區
    /// （跟著 store.area：兩區各有自己的 Session／Window，換區由 Store.switchArea 做）
    private var mode: String { store.area }

    var body: some View {
        HStack(spacing: 0) {
            IconRail(mode: Binding(get: { store.area }, set: { store.switchArea($0) }), openSettings: actions.openSettings, toggleCollab: actions.toggleCollab)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    // 兩區標題同一種寫法：短英文、同字級（codelab＝程式碼學習專區；組名本身照舊是「程式碼學習專區」）
                    Text(mode == "codelab" ? "codelab" : "codenv").font(.system(size: 20 * s, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Button(action: actions.toggleSidebar) {
                        Image(systemName: "sidebar.left").font(.system(size: 15 * s))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("收起側欄（⌃ ⌘ S）：聊天區變寬；上面分頁列最左邊的同一顆按鈕可以再打開")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                if let r = update.available {
                    Button(action: { update.showPopup(r) }) {
                        Label("有新版 \(r.version)", systemImage: "arrow.down.circle.fill").font(.system(size: 12 * s))
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .help("看這版的說明、下載或略過")
                }

                if mode == "codelab" {
                    SidebarButton(icon: "chevron.left.forwardslash.chevron.right", title: "新的練習", action: actions.newCodeLab)
                        .padding(.horizontal, 8)
                        .help("開一個新的練習聊天室（程式放 \(Edition.display(Edition.practiceFolder))）：左邊 AI、右邊寫程式和執行")
                    codeLabList
                } else {
                SidebarButton(icon: "square.and.pencil", title: "新對話", action: actions.newConversation)
                    .padding(.horizontal, 8)
                    .help("新對話（⌘ N）")

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader(store.groups.isEmpty ? "專案" : "分類", trailing: AnyView(HStack(spacing: 10) {
                            if !store.groups.isEmpty {
                                let folded = store.allGroupsCollapsed
                                Button(action: { store.setAllGroups(expanded: folded) }) {
                                    Image(systemName: folded ? "chevron.down.2" : "chevron.up.2")
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help(folded ? "全部展開" : "全部收起（也可以 ⌥ 點任一組的名字）")
                            }
                            Button(action: { showArchived.toggle(); appDefaults.set(showArchived, forKey: "sidebarShowArchived") }) {
                                Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                            }
                            .buttonStyle(.plain).foregroundStyle(showArchived ? Color.accentColor : Color.secondary)
                            .help(showArchived ? "收起封存的對話" : "顯示封存的對話（一個禮拜沒碰的，灰字列在各組最下面）")
                            Button(action: { NSApp.sendAction(#selector(AppDelegate.showOrganizer), to: nil, from: nil) }) { Image(systemName: "list.bullet.rectangle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("整理對話（⌘ ⇧ L）：一張表看全部，多選一次改組、封存、刪除")
                            Button(action: { NSApp.sendAction(#selector(AppDelegate.showImporter), to: nil, from: nil) }) { Image(systemName: "square.and.arrow.down") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("從 Claude Code 匯入對話（⌘ ⇧ I）：在 iTerm／tmux 開過的")
                            Button(action: actions.addProject) { Image(systemName: "plus") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("新增專案（選一個資料夾）")
                        }))
                        .background(RoundedRectangle(cornerRadius: 7).fill(topTargeted ? Color.accentColor.opacity(0.25) : .clear))
                        .onDrop(of: [.text], isTargeted: $topTargeted) { items in
                            // 把組拖到「分類」這一行＝移到最上層
                            Self.loadGroupDrop(items) { id in store.setGroupParent(id, to: nil) }
                        }
                        if store.projects.isEmpty {
                            Text("按 ＋ 選一個資料夾當專案").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 4)
                        }
                        if store.groups.isEmpty {
                            ForEach(store.projects) { p in projectBlock(p) }
                        } else {
                            // 程式碼學習專區放在最左邊的圖示列，首頁不列
                            ForEach(store.topGroups.filter { $0.name != Store.codeLabGroupName }) { g in groupBlock(g, depth: 0) }
                        }

                        if !store.recent.isEmpty {
                            sectionHeader("最近項目").padding(.top, 14)
                            ForEach(store.recent) { c in
                                ConversationRow(title: c.title, selected: store.selected == c.id, indent: false,
                                                status: store.status[c.id], unread: store.unread.contains(c.id), scheduled: schedules.has(c.id)) { store.open(c.id) }
                                    .onDrag { Self.dragItem(c.id) }
                                    .contextMenu { conversationMenu(c) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 16)
                }
                }
            }
        }
        .frame(minWidth: 250)
        // 打開的聊天室在哪一區，側欄就切到哪一區：改由 Store 做（目前的 Session 屬於哪區就是哪區，followSessionArea），
        // 不看選到的對話在哪一組——不然 codelab 那套裡擺了首頁的對話，點它會整套跳走
        .alert(addingGroup ? (addingParent.map { "新增子組（在「\(store.groupPath($0))」底下）" } ?? "新增一組") : "重新命名這一組", isPresented: Binding(get: { renamingGroup != nil || addingGroup }, set: { if !$0 { renamingGroup = nil; addingGroup = false } })) {
            TextField("名稱", text: $groupRenameText)
            Button("好") {
                if addingGroup { if !groupRenameText.trimmingCharacters(in: .whitespaces).isEmpty { store.addGroup(named: groupRenameText, parent: addingParent) } }
                else if let g = renamingGroup { store.renameGroup(g.id, to: groupRenameText) }
                renamingGroup = nil; addingGroup = false
            }
            Button("取消", role: .cancel) { renamingGroup = nil; addingGroup = false }
        }
        .alert("掛一個網頁", isPresented: Binding(get: { addingWebFor != nil }, set: { if !$0 { addingWebFor = nil } })) {
            TextField("網址（https://…）", text: $webURLText)
            Button("掛上去") {
                var u = webURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !u.isEmpty, !u.contains("://") { u = "https://" + u }
                if let c = addingWebFor, !u.isEmpty, let g = store.addGadget(GadgetKind.of(u), url: u, to: c) { store.openGadget(g.id) }
                addingWebFor = nil
            }
            Button("取消", role: .cancel) { addingWebFor = nil }
        }
        .alert("重新命名對話", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名稱", text: $renameText)
            Button("好") { if let r = renaming { store.rename(r.id, to: renameText, byUser: true) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    /// 程式碼學習專區：只列這一組的聊天室（草稿也列，這裡就是它的家）
    @ViewBuilder
    private var codeLabList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let g = store.groups.first(where: { $0.name == Store.codeLabGroupName }) {
                    let all = store.conversations(inGroup: g.id)
                    let active = all.filter { !store.isArchived($0) }
                    let archived = showArchived ? all.filter { store.isArchived($0) } : []
                    sectionHeader("練習", trailing: AnyView(
                        Button(action: { showArchived.toggle(); appDefaults.set(showArchived, forKey: "sidebarShowArchived") }) {
                            Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                        }
                        .buttonStyle(.plain).foregroundStyle(showArchived ? Color.accentColor : Color.secondary)
                        .help(showArchived ? "收起封存的練習" : "顯示封存的練習")))
                    if active.isEmpty && archived.isEmpty {
                        Text("還沒有練習。按上面的「新的練習」開一個。")
                            .font(.system(size: 13 * s)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    ForEach(active) { c in
                        ConversationRow(title: c.title, selected: store.selected == c.id, indent: false,
                                        status: store.status[c.id], unread: store.unread.contains(c.id), scheduled: schedules.has(c.id)) { store.open(c.id) }
                            .help(folderHint(c))
                            .onDrag { Self.dragItem(c.id) }
                            .modifier(ReorderDrop(target: c.id, store: store))
                            .contextMenu { conversationMenu(c) }
                    }
                    ForEach(archived) { c in
                        ConversationRow(title: c.title, selected: store.selected == c.id, indent: false, dimmed: true) { store.open(c.id) }
                            .help(folderHint(c))
                            .onDrag { Self.dragItem(c.id) }
                            .contextMenu { conversationMenu(c) }
                    }
                } else {
                    Button("建立程式碼學習專區") { store.addGroup(named: Store.codeLabGroupName) }
                        .padding(12)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func projectBlock(_ p: Project) -> some View {
        let all = store.conversations(in: p.id).filter { $0.draft != true }   // 草稿只列在「最近項目」
        let convs = all.filter { !store.isArchived($0) }
        let archived = all.filter { store.isArchived($0) }
        ProjectRow(name: p.name, expanded: p.expanded, selected: store.selectedProject == p.id && store.selected == nil) {
            if let i = store.projects.firstIndex(where: { $0.id == p.id }) { store.projects[i].expanded.toggle() }
            store.selectedProject = p.id
        }
        .contextMenu {
            Button("在這個專案開新對話") { store.newConversation(in: p.id) }
            Button("在 Finder 中顯示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.path) }
            Divider()
            Button("從側欄和 claude 選單清單移除（不會刪資料夾）", role: .destructive) { actions.removeProject(p.id) }
        }
        if p.expanded {
            if convs.isEmpty && archived.isEmpty {
                Text("沒有對話").font(.system(size: 14 * s)).foregroundStyle(.tertiary).padding(.leading, 40).padding(.vertical, 5)
            }
            ForEach(Self.sideItems(convs)) { item in sideItem(item, depth: 0) }
            // 一個禮拜沒碰的：按上面的封存按鈕才列出來，灰色字
            if showArchived {
                ForEach(archived) { c in
                    ConversationRow(title: c.title, selected: store.selected == c.id, indent: true, dimmed: true) { store.open(c.id) }
                        .onDrag { Self.dragItem(c.id) }
                        .contextMenu { conversationMenu(c) }
                }
            }
        }
    }

    /// 拖對話到右邊的畫面：拖到某格的邊緣就從那邊切開
    static func dragItem(_ id: UUID) -> NSItemProvider {
        ReorderDrop.dragging = (id, Date())
        GroupDrop.dragging = nil   // 上一次拖組沒放到側欄上（取消）：不要被當成還在拖組
        ChatTextView.dropLog("側欄開始拖：\(id.uuidString.prefix(8))", nil)
        NotificationCenter.default.post(name: DropOverlay.began, object: nil)
        return NSItemProvider(object: (DropOverlay.prefix + id.uuidString) as NSString)
    }

    @ViewBuilder
    private func conversationMenu(_ c: Conversation) -> some View {
        Button("重新命名…") { renameText = c.title; renaming = c }
        if c.isBrowser {
            // 瀏覽器格子：沒有聊天介面／終端機／壓縮／交接／排程
        } else if c.terminal == true {
            Button("回到聊天介面") { actions.switchMode(c.id, false) }
        } else {
            Button("用終端機打開（聊天介面還沒做的功能）") { actions.switchMode(c.id, true) }
        }
        if c.terminal != true && !c.isBrowser {
            Button("壓縮這段對話（/compact）…") { actions.compact(c.id) }
            Button("交接") { actions.handoff(c.id) }
        }
        if c.isBrowser {
            // 原本列在側欄的瀏覽器格子：改成掛在同一串的某段聊天室上，就不再佔聊天室清單的位置
            let chats = store.siblings(of: c).filter { !$0.isBrowser }
            if !chats.isEmpty {
                Menu("改成掛件，掛在…") {
                    ForEach(chats) { t in Button(t.title) { store.attachBrowser(c.id, to: t.id) } }
                }
            }
        } else {
            Menu("掛件") {
                Button("掛 Gemini") { if let g = store.addGadget(.gemini, to: c.id) { store.openGadget(g.id) } }
                Button("掛 NotebookLM") { if let g = store.addGadget(.notebooklm, to: c.id) { store.openGadget(g.id) } }
                Button("掛網頁…") { webURLText = ""; addingWebFor = c.id }
                if c.bundle != nil {
                    Divider()
                    Button("離開掛件框") { store.setBundle(c.id, nil) }
                }
            }
        }
        Button(store.isArchived(c) ? "取消封存" : "封存") { store.setArchived(c.id, !store.isArchived(c)) }
        Button("移到最上面") { store.shift(c.id, by: -10_000) }
        Button("上移") { store.shift(c.id, by: -1) }
        Button("下移") { store.shift(c.id, by: 1) }
        Button("換工作資料夾…") { actions.changeFolder(c.id) }
        if c.terminal != true && !c.isBrowser { Button(schedules.has(c.id) ? "排程…（有）" : "排程…") { actions.schedule(c.id) } }
        if !store.groups.isEmpty {
            Menu("移到…") {
                ForEach(store.groupTree(), id: \.group.id) { t in
                    Button((store.groupOf(c) == t.group.id ? "✓ " : "") + String(repeating: "　", count: t.depth) + t.group.name) { store.move(c.id, toGroup: t.group.id) }
                }
            }
        }
        Divider()
        Button("刪除對話（Claude 的紀錄還在）", role: .destructive) { actions.deleteConversation(c.id) }
    }

    // MARK: 分組（學業、RTS…）：組 → 資料夾 → 對話；一個禮拜沒碰的收在組最下面的「封存」

    /// 組的標題拖曳：內容是「codenv-group:<id>」
    static let groupDragPrefix = "codenv-group:"
    /// 放下的東西如果是組，把 id 交給 f
    static func loadGroupDrop(_ items: [NSItemProvider], _ f: @escaping (UUID) -> Void) -> Bool {
        guard let item = items.first else { return false }
        _ = item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, s.hasPrefix(groupDragPrefix), let id = UUID(uuidString: String(s.dropFirst(groupDragPrefix.count))) else { return }
            DispatchQueue.main.async { f(id) }
        }
        return true
    }

    @ViewBuilder
    private func groupBlock(_ g: ConvGroup, depth: Int) -> some View {
        let children = store.childGroups(of: g.id).filter { $0.name != Store.codeLabGroupName }
        let all = store.conversations(inGroup: g.id).filter { $0.draft != true }   // 草稿只列在「最近項目」
        let active = all.filter { !store.isArchived($0) }
        let allArchived = all.filter { store.isArchived($0) }
        // 上面的封存按鈕＝各組都列；組標題左邊的封存圖示＝只列這一組的（使用者 10/24）
        let archived = showArchived || g.archiveOpen ? allArchived : []
        GroupHeader(name: g.name, count: active.count, expanded: g.expanded, targeted: dropGroup == g.id, depth: depth,
                    archivedCount: allArchived.count, archiveOpen: showArchived || g.archiveOpen,
                    onArchive: {
                        store.toggleGroupArchive(g.id)
                        if store.group(g.id)?.archiveOpen == true, !g.expanded { store.toggleGroup(g.id) }   // 收著的組順便打開，才看得到
                    }) {
            // ⌥ 點：全部一起收起／展開（跟 Finder 一樣）
            if NSEvent.modifierFlags.contains(.option) { store.setAllGroups(expanded: !g.expanded) } else { store.toggleGroup(g.id) }
        }
            .onDrag {
                ChatTextView.dropLog("側欄開始拖組：\(g.name)", nil)
                GroupDrop.dragging = (g.id, Date())
                ReorderDrop.dragging = nil
                return NSItemProvider(object: (Self.groupDragPrefix + g.id.uuidString) as NSString)
            }
            // 拖組到標題上緣／下緣＝排到前面／後面（藍線）；中間＝放進這一組（整個亮起來）。展開又有子組的，下緣也算放進去（線會夾在標題和子組中間，看不出是哪個）
            .modifier(GroupDrop(target: g.id, depth: depth, edgeAfter: !g.expanded || children.isEmpty, store: store,
                                targeted: groupTargeted(g), nest: { dropOnGroup(g, $0) }))
            .contextMenu {
                Button("在這一組開新對話") { store.newConversation(inGroup: g.id) }
                Divider()
                Button("全部收起") { store.setAllGroups(expanded: false) }
                Button("全部展開") { store.setAllGroups(expanded: true) }
                Divider()
                Button("整理對話…") { NSApp.sendAction(#selector(AppDelegate.showOrganizer), to: nil, from: nil) }
                Divider()
                Button("重新命名這一組…") { groupRenameText = g.name; renamingGroup = g }
                Button("新增一組…") { groupRenameText = ""; addingParent = nil; addingGroup = true }
                Button("在這一組底下新增子組…") { groupRenameText = ""; addingParent = g.id; addingGroup = true }
                Menu("放進…") {
                    ForEach(store.groupTree().filter { !store.isGroup($0.group.id, within: g.id) && $0.group.name != Store.codeLabGroupName }, id: \.group.id) { t in
                        Button((g.parentID == t.group.id ? "✓ " : "") + String(repeating: "　", count: t.depth) + t.group.name) { store.setGroupParent(g.id, to: t.group.id) }
                    }
                }
                if g.parentID != nil { Button("移到最上層") { store.setGroupParent(g.id, to: nil) } }
                Divider()
                Button(g.parentID == nil ? "刪除這一組（對話會回到「其他」，子組往上提，不會刪）" : "刪除這一組（對話和子組回到上一層，不會刪）", role: .destructive) { store.removeGroup(g.id) }
            }
        if g.expanded {
            // 子組先列（像 Finder 資料夾在前），再列這一組自己的對話
            ForEach(children) { c in AnyView(groupBlock(c, depth: depth + 1)) }
            if active.isEmpty && archived.isEmpty && children.isEmpty {
                Text("沒有對話").font(.system(size: 14 * s)).foregroundStyle(.tertiary).padding(.leading, 36 + CGFloat(depth) * 16 * s).padding(.vertical, 4)
                    // 使用者 10/24：空資料夾拖到「沒有對話」這行也要放得進去（以前只有標題收）
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onDrop(of: [.text], isTargeted: groupTargeted(g)) { dropOnGroup(g, $0) }
            }
            // 使用者 10/22：資料夾那一行、封存那一行都太佔位置。組底下直接列對話（在哪個資料夾滑鼠停著看），
            // 封存的平常不列，按上面的封存按鈕才在各組最下面用灰字列出來
            ForEach(Self.sideItems(active)) { item in sideItem(item, depth: depth) }
            ForEach(archived) { c in
                ConversationRow(title: c.title, selected: store.selected == c.id, indent: true, dimmed: true) { store.open(c.id) }
                    .padding(.leading, CGFloat(depth) * 16 * s)
                    .help(folderHint(c) + "\n（封存：一個禮拜沒碰。打開就會回到上面）")
                    .onDrag { Self.dragItem(c.id) }
                    .contextMenu { conversationMenu(c) }
            }
        }
    }

    /// 組的標題亮起來：拖到標題上，或拖到空組的「沒有對話」上
    private func groupTargeted(_ g: ConvGroup) -> Binding<Bool> {
        Binding(get: { dropGroup == g.id }, set: { dropGroup = $0 ? g.id : (dropGroup == g.id ? nil : dropGroup) })
    }

    /// 拖到組上放開：側欄的對話＝移到這一組；另一組＝變成這一組的子組
    private func dropOnGroup(_ g: ConvGroup, _ items: [NSItemProvider]) -> Bool {
        guard let item = items.first else { return false }
        _ = item.loadObject(ofClass: NSString.self) { obj, _ in
            if let s = obj as? String, s.hasPrefix(Self.groupDragPrefix), let gid = UUID(uuidString: String(s.dropFirst(Self.groupDragPrefix.count))) {
                DispatchQueue.main.async {
                    ChatTextView.dropLog("側欄組套組：\(store.group(gid)?.name ?? "?") → \(g.name)", nil)
                    if gid != g.id { store.setGroupParent(gid, to: g.id) }
                }
                return
            }
            if let s = obj as? String, s.hasPrefix(Self.bundleDragPrefix), let b = UUID(uuidString: String(s.dropFirst(Self.bundleDragPrefix.count))) {
                DispatchQueue.main.async {
                    ChatTextView.dropLog("側欄搬掛件框 → \(g.name)", nil)
                    store.moveBundle(b, toGroup: g.id)
                }
                return
            }
            guard let s = obj as? String, s.hasPrefix(DropOverlay.prefix), let id = UUID(uuidString: String(s.dropFirst(DropOverlay.prefix.count))) else { return }
            DispatchQueue.main.async {
                ChatTextView.dropLog("側欄移組：\(store.conversation(id)?.title ?? "?") → \(g.name)", nil)
                store.move(id, toGroup: g.id)
                ReorderDrop.dragging = nil
            }
        }
        return true
    }

    // MARK: 掛件框（Bundles.swift）

    /// 側欄一串對話裡的一項：單獨一段，或一個掛件框（框裡的照順序排在第一段出現的位置）
    enum SideItem: Identifiable {
        case conv(Conversation)
        case bundle(UUID, [Conversation])
        var id: UUID { switch self { case .conv(let c): return c.id; case .bundle(let b, _): return b } }
    }
    static func sideItems(_ list: [Conversation]) -> [SideItem] {
        var seen = Set<UUID>(), out: [SideItem] = []
        for c in list {
            if let b = c.bundle {
                if seen.insert(b).inserted { out.append(.bundle(b, list.filter { $0.bundle == b })) }
            } else { out.append(.conv(c)) }
        }
        return out
    }

    @ViewBuilder
    private func sideItem(_ item: SideItem, depth: Int) -> some View {
        switch item {
        case .conv(let c):
            activeRow(c, indent: true).padding(.leading, CGFloat(depth) * 16 * s)
        case .bundle(let b, let members):
            BundleBox(bundle: b, gadgets: store.gadgets(of: b),
                      shownGadgets: Set((store.currentWindow?.root?.leaves ?? []).filter { !PaneSlide.shared.isLeaving($0) }), depth: depth,
                      onOpen: { store.openGadget($0) },
                      onRemoveGadget: { store.removeConversation($0) },
                      onDissolve: { store.dissolveBundle(b) },
                      onDropConversation: { id in
                          if let last = store.bundleMembers(b).last, last.id != id { store.reorder(id, after: last.id) } else { store.setBundle(id, b) }
                      },
                      dragItem: {
                          GroupDrop.dragging = nil
                          ReorderDrop.dragging = nil
                          return NSItemProvider(object: (Self.bundleDragPrefix + b.uuidString) as NSString)
                      }) {
                ForEach(members) { c in activeRow(c, indent: false) }
            }
        }
    }

    /// 一段沒封存的對話（組、資料夾、掛件框裡共用）
    private func activeRow(_ c: Conversation, indent: Bool) -> some View {
        ConversationRow(title: c.title, selected: store.selected == c.id, indent: indent,
                        status: store.status[c.id], unread: store.unread.contains(c.id), scheduled: schedules.has(c.id)) { store.open(c.id) }
            .help(folderHint(c))
            .onDrag { Self.dragItem(c.id) }
            .modifier(ReorderDrop(target: c.id, store: store))
            .contextMenu { conversationMenu(c) }
    }

    /// 掛件列的拖曳內容：「codenv-bundle:<框>」
    static let bundleDragPrefix = "codenv-bundle:"

    private func folderHint(_ c: Conversation) -> String {
        guard let p = store.project(c.projectID) else { return c.title }
        return "\(c.title)\n資料夾：\(ClaudeEnvs.tilde(p.path))"
    }

    @ViewBuilder
    private func folderMenu(_ p: Project) -> some View {
        Button("在這個資料夾開新對話") { store.newConversation(in: p.id) }
        Button("在 Finder 中顯示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.path) }
        Menu("這個資料夾的新對話預設放在…") {
            ForEach(store.groupTree(), id: \.group.id) { t in Button((p.groupID == t.group.id ? "✓ " : "") + String(repeating: "　", count: t.depth) + t.group.name) { store.setDefaultGroup(p.id, to: t.group.id) } }
        }
        Divider()
        Button("從側欄和 claude 選單清單移除（不會刪資料夾）", role: .destructive) { actions.removeProject(p.id) }
    }

    private func sectionHeader(_ title: String, trailing: AnyView? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 13 * s, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// 最左邊的圖示列
struct IconRail: View {
    @Environment(\.uiScale) private var s
    @Binding var mode: String
    var openSettings: () -> Void
    var toggleCollab: () -> Void = {}
    @ObservedObject private var collab = CollabBoardModel.shared
    var body: some View {
        VStack(spacing: 14) {
            RailIcon(name: "house.fill", help: "首頁", active: mode != "codelab") { mode = "home" }
            RailIcon(name: "chevron.left.forwardslash.chevron.right", help: "程式碼學習專區：左邊 Claude、右邊寫程式和執行", active: mode == "codelab") { mode = "codelab" }
            Spacer()
            RailIcon(name: "bubble.left.and.bubble.right", help: "協作看板：目標、兩個 Claude 互傳的訊息", active: collab.open, action: toggleCollab)
                .overlay(alignment: .topTrailing) {
                    // 看板沒開時：有一對來回太多次亮橘點，有目標在等你（提議待同意、輪到你的步驟）亮藍點
                    if !collab.open && (!collab.warnings.isEmpty || collab.waitingOnYou > 0) {
                        Circle().fill(collab.warnings.isEmpty ? Color.accentColor : .orange).frame(width: 8, height: 8).offset(x: -4, y: 4)
                    }
                }
            RailIcon(name: "gearshape", help: "設定（⌘ ,）", active: false, action: openSettings)
        }
        .padding(.top, 44)
        .padding(.bottom, 14)
        .frame(width: 52)
    }
}

struct RailIcon: View {
    @Environment(\.uiScale) private var s
    let name: String
    let help: String
    let active: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 17 * s))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(active ? 0.12 : (hover ? 0.07 : 0))))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .secondary)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct SidebarButton: View {
    @Environment(\.uiScale) private var s
    let icon: String
    let title: String
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22 * s)   // 跟著字級放大：寬的圖示（</>）才不會擠出框、看起來沒對齊
                Text(title)
                Spacer()
            }
            .font(.system(size: 15 * s))
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ProjectRow: View {
    @Environment(\.uiScale) private var s
    let name: String
    let expanded: Bool
    let selected: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: expanded ? "folder" : "folder.fill").frame(width: 18).foregroundStyle(.secondary)
                Text(name).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 15 * s))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(selected ? 0.1 : (hover ? 0.06 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ConversationRow: View {
    @Environment(\.uiScale) private var s
    let title: String
    let selected: Bool
    let indent: Bool
    var status: ChatStatus? = nil
    var unread = false
    var scheduled = false       // 有開著的排程：標題旁一個小時鐘
    var dimmed = false          // 封存裡的：灰色字
    var action: () -> Void
    @State private var hover = false
    // 不用 Button：macOS 的 Button 按下就自己追滑鼠，外面掛的 onDrag 永遠開始不了（側欄拖不動的原因）。
    // 改成點一下＝onTapGesture、按住拖＝onDrag，兩個各管各的
    var body: some View {
            HStack {
                Text(title).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(dimmed ? Color.secondary.opacity(0.7) : Color.primary)
                if scheduled { Image(systemName: "clock").font(.system(size: 10 * s)).foregroundStyle(.secondary).help("有排程") }
                Spacer()
                // 狀態：工作中轉圈、等你回覆是藍色小標籤、做完沒看過是小藍點（跟 Codex 一樣一次只顯示一種）
                if status == .waiting {
                    Text("等你").font(.system(size: 11 * s, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue))
                } else if status == .working {
                    ProgressView().controlSize(.mini)
                } else if unread {
                    Circle().fill(Color.blue).frame(width: 7, height: 7)
                }
            }
            .font(.system(size: 15 * s))
            .padding(.leading, indent ? 28 : 8).padding(.trailing, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(selected ? 0.12 : (hover ? 0.06 : 0))))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .onHover { hover = $0 }
    }
}

/// 組的標題列
struct GroupHeader: View {
    @Environment(\.uiScale) private var s
    let name: String
    let count: Int
    let expanded: Bool
    var targeted = false        // 有對話拖到這一組上面：亮起來（放下＝移到這一組）
    var depth = 0               // 第幾層（子組往右縮）
    /// 最左邊的封存圖示：點了只展開／收起這一組封存的對話
    var archivedCount = 0
    var archiveOpen = false
    var onArchive: (() -> Void)? = nil
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        // 不用 Button：Button 會把滑鼠吃掉，組的標題就拖不動（跟對話那一列同樣的問題）
        Group {
            HStack(spacing: 8) {
                if let onArchive {
                    Image(systemName: archiveOpen ? "archivebox.fill" : "archivebox").font(.system(size: 11 * s))
                        .foregroundStyle(archiveOpen ? AnyShapeStyle(Color.accentColor) : archivedCount > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                        .frame(width: 16 * s, height: 16 * s).contentShape(Rectangle())
                        .onTapGesture { if archivedCount > 0 || archiveOpen { onArchive() } }
                        .help(archivedCount > 0 ? (archiveOpen ? "收起這一組封存的對話" : "展開這一組封存的對話（\(archivedCount) 段）") : "這一組沒有封存的對話")
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10 * s, weight: .bold)).foregroundStyle(.tertiary).frame(width: 12)
                Text(name).font(.system(size: 15 * s, weight: .semibold))
                if count > 0 { Text("\(count)").font(.system(size: 12 * s)).foregroundStyle(.tertiary) }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .padding(.leading, CGFloat(depth) * 16 * s)
            .background(RoundedRectangle(cornerRadius: 7).fill(targeted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(hover ? 0.06 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: targeted ? 1.5 : 0))
            .contentShape(Rectangle())
        }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .onHover { hover = $0 }
        .padding(.top, 6)
    }
}

/// 組裡的資料夾小標題
struct FolderSubRow: View {
    @Environment(\.uiScale) private var s
    let name: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 11 * s))
            Text(name).font(.system(size: 12 * s))
            Spacer()
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 28).padding(.top, 4).padding(.bottom, 1)
    }
}

/// 拖到組的標題上：拖的是另一組時，上緣／下緣排到前面／後面（出現一條提示線），中間放進這一組；拖的是對話一律放進這一組
struct GroupDrop: ViewModifier {
    /// 正在拖哪一組（拖曳內容要非同步讀，排序時直接用這個）
    static var dragging: (id: UUID, at: Date)?
    let target: UUID
    let depth: Int
    let edgeAfter: Bool         // 下緣能不能排到後面
    let store: Store
    @Binding var targeted: Bool
    let nest: ([NSItemProvider]) -> Bool
    @State private var edge: Bool? = nil   // nil＝沒有要排序；false＝上緣、true＝下緣
    @State private var height: CGFloat = 36
    @Environment(\.uiScale) private var s

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { _, h in height = h } })
            .overlay(alignment: edge == true ? .bottom : .top) {
                Rectangle().fill(Color.accentColor).frame(height: 2).padding(.leading, 8 + CGFloat(depth) * 16 * s).opacity(edge == nil ? 0 : 1)
            }
            .onDrop(of: [.text], delegate: Delegate(m: self, edge: $edge, targeted: $targeted))
    }

    private struct Delegate: DropDelegate {
        let m: GroupDrop
        @Binding var edge: Bool?
        @Binding var targeted: Bool
        /// 一分鐘內從側欄開始拖的組才算
        private var draggedGroup: UUID? {
            guard let d = GroupDrop.dragging, Date().timeIntervalSince(d.at) < 60, d.id != m.target else { return nil }
            return d.id
        }
        /// 上緣（標題上面 6 點的空隙也算）／下緣各三成；拖的不是組就沒有邊
        private func zone(_ info: DropInfo) -> Bool? {
            guard draggedGroup != nil else { return nil }
            let y = info.location.y
            if y < m.height * 0.35 { return false }
            if m.edgeAfter, y > m.height * 0.72 { return true }
            return nil
        }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            edge = zone(info)
            targeted = edge == nil
            return DropProposal(operation: .move)
        }
        func dropExited(info: DropInfo) { edge = nil; targeted = false }
        func performDrop(info: DropInfo) -> Bool {
            let z = zone(info)
            edge = nil; targeted = false
            guard let g = draggedGroup, let after = z else {
                GroupDrop.dragging = nil
                return m.nest(info.itemProviders(for: [.text]))
            }
            GroupDrop.dragging = nil
            ChatTextView.dropLog("側欄排組：\(m.store.group(g)?.name ?? "?") → \(after ? "排到後面" : "排到前面")：\(m.store.group(m.target)?.name ?? "?")", nil)
            if after { m.store.reorderGroup(g, after: m.target) } else { m.store.reorderGroup(g, before: m.target) }
            return true
        }
    }
}

/// 把別的對話拖到這一列上：放在上半排到它前面、下半排到它後面（上緣或下緣出現一條提示線）
struct ReorderDrop: ViewModifier {
    /// 正在拖哪一段（開始拖的時候記下來；拖曳內容要非同步讀，放下時直接用這個）
    static var dragging: (id: UUID, at: Date)?
    let target: UUID
    let store: Store
    @State private var below: Bool? = nil   // nil＝沒在上面
    @State private var height: CGFloat = 30

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { _, h in height = h } })
            .overlay(alignment: below == true ? .bottom : .top) {
                Rectangle().fill(Color.accentColor).frame(height: 2).padding(.leading, 36).opacity(below == nil ? 0 : 1)
            }
            .onDrop(of: [.text], delegate: Delegate(target: target, store: store, height: height, below: $below))
    }

    private struct Delegate: DropDelegate {
        let target: UUID
        let store: Store
        let height: CGFloat
        @Binding var below: Bool?
        /// 一分鐘內從側欄開始拖的才算（別的 App 拖文字進來不理）
        private var dragged: UUID? {
            guard let d = ReorderDrop.dragging, Date().timeIntervalSince(d.at) < 60, d.id != target else { return nil }
            return d.id
        }
        func validateDrop(info: DropInfo) -> Bool { dragged != nil }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard dragged != nil else { return nil }
            below = info.location.y > height / 2
            return DropProposal(operation: .move)
        }
        func dropExited(info: DropInfo) { below = nil }
        func performDrop(info: DropInfo) -> Bool {
            let after = info.location.y > height / 2
            below = nil
            guard let id = dragged else {
                ChatTextView.dropLog("側欄排序：沒有正在拖的對話（target \(target.uuidString.prefix(8))）", nil)
                return false
            }
            ReorderDrop.dragging = nil
            ChatTextView.dropLog("側欄排序：\(store.conversation(id)?.title ?? "?") → \(after ? "排到後面" : "排到前面")：\(store.conversation(target)?.title ?? "?")", nil)
            if after { store.reorder(id, after: target) } else { store.reorder(id, before: target) }
            return true
        }
    }
}
