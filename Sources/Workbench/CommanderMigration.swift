import Foundation

extension Store {
    /// 首頁第一次使用總指揮側欄時，把舊資料一次轉成九個 Session。
    /// 所有 Session 一起存檔，因此任一首頁 Session 的 groups 已設（包含 []）就表示做過；
    /// 改名、改涵蓋組或關掉某個總指揮之後，都不會在重開時把使用者的配置重建回來。
    @discardableResult
    func migrateCommandersIfNeeded() -> Bool {
        guard !Edition.isPublic, !appDefaults.bool(forKey: Store.commanderMigrationDoneKey), area == "home", Prefs.shared.sidebarMode == "commander", !loadFailed, !isSaveProtected,
              !sessions.contains(where: { $0.area == nil && $0.groups != nil }),
              !projects.isEmpty else { return false }

        let definitions: [(name: String, groups: [String], existingChief: String?)] = [
            ("範例專案", ["範例專案"], nil)
        ]
        // 組名在任何一層都算（A 組在 B 組底下）；同名時最上層優先
        let tops = groups.sorted { ($0.parentID == nil ? 0 : 1) < ($1.parentID == nil ? 0 : 1) }
        // 先準備完整副本，檔案準備途中失敗時不留下半套 groups 標記或半套 Session。
        var nextProjects = projects
        var nextGroups = groups
        var nextConversations = conversations
        var commanders: [SessionLayout] = []
        let main = sessions.first { $0.area == nil && $0.name == "main" }

        // 跟正式歸屬一樣：最深的涵蓋組勝出（B 涵蓋 A，但另一個組涵蓋得更深）
        let allRoots: [(name: String, root: UUID)] = definitions.flatMap { d in d.groups.compactMap { n in tops.first { $0.name == n }.map { (d.name, $0.id) } } }
        func owner(_ c: Conversation) -> String? {
            guard !c.isGadget, let g = groupOf(c) else { return nil }
            func depth(_ id: UUID) -> Int { var n = 0, cur: UUID? = id; while let x = cur, n < 64 { cur = groups.first { $0.id == x }?.parentID; n += 1 }; return n }
            return allRoots.filter { isGroup(g, within: $0.root) }.max { depth($0.root) < depth($1.root) }?.name
        }
        func contains(_ c: Conversation, in roots: [UUID]) -> Bool {
            guard let o = owner(c) else { return false }
            return allRoots.contains { $0.name == o && roots.contains($0.root) }
        }
        func firstProject(in roots: [UUID]) -> UUID? {
            conversations.first { contains($0, in: roots) && project($0.projectID) != nil }?.projectID
        }
        let otherRoots = tops.filter { $0.name == Store.otherGroupName }.map(\.id)
        let fallbackProject = firstProject(in: otherRoots)
            ?? projects.first { p in p.groupID.map { g in otherRoots.contains { isGroup(g, within: $0) } } ?? false }?.id
            ?? projects[0].id

        do {
            // 備份只建一次，絕不覆蓋前次遷移保留的原檔；首次使用、尚無 state.json 時沒有原檔可備。
            let state = directory.appendingPathComponent("state.json")
            let backup = directory.appendingPathComponent("state.json.總指揮遷移前")
            if FileManager.default.fileExists(atPath: state.path), !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: state, to: backup)
            }
            // 只有既有的範例專案頂層組能建立語言區；其他缺少的頂層組一律略過。
            if let study = tops.first(where: { $0.name == "範例專案" }) {
                try prepareCommanderLanguages(under: study.id, projects: &nextProjects,
                                             groups: &nextGroups, conversations: &nextConversations)
            }
            // main 裡整窗都屬於同一個（codenv 以外的）總指揮的 Window，先記下要搬去哪
            var movedWindows: [String: [WindowLayout]] = [:]
            if let main {
                for w in main.windows where !w.detached {
                    let leaves = w.root?.leaves ?? []
                    guard !leaves.isEmpty else { continue }
                    let owners = Set(leaves.map { id -> String? in
                        guard let c = conversation(id) else { return nil }
                        return definitions.first { d in
                            contains(c, in: d.groups.compactMap { n in tops.first { $0.name == n }?.id })
                        }?.name
                    })
                    if owners.count == 1, let o = owners.first, let name = o, name != "codenv" {
                        movedWindows[name, default: []].append(w)
                    }
                }
            }
            for definition in definitions {
                let roots = definition.groups.compactMap { name in tops.first { $0.name == name }?.id }
                let existing = definition.existingChief.flatMap { title in
                    conversations.first { $0.title == title && Store.isChat($0) && !isArchived($0) && contains($0, in: roots) }
                }
                let chief: Conversation
                if let existing { chief = existing }
                else {
                    // 這裡只建立資料，不經過 show／newConversation／Workspace，不會啟動 Claude。
                    chief = makeCommanderConversation(project: firstProject(in: roots) ?? fallbackProject,
                        title: definition.existingChief ?? definition.name + "總指揮", group: roots.first,
                        order: (nextConversations.compactMap(\.order).min() ?? 0) - 1)
                    nextConversations.append(chief)
                }
                var session: SessionLayout
                if definition.name == "codenv", let main {
                    session = main       // 保留 id、current、所有 Window、Pane、比例及獨立視窗資料
                    session.name = definition.name
                    // 整個 Window 的聊天室都屬於別的總指揮：搬去那邊（阿公 11/7）；混排的留在 codenv
                    session.windows.removeAll { movedWindows.values.flatMap { $0 }.map(\.id).contains($0.id) }
                    if !session.windows.contains(where: { $0.id == session.current }) { session.current = session.windows.first?.id }
                } else {
                    var windows = movedWindows[definition.name] ?? []
                    // 總指揮聊天室已經在某個 Window 裡（含留在 codenv 的混排 Window）：不再放第二份，同一段不能同時擺兩處
                    let placedAnywhere = windows.contains { $0.root?.leaves.contains(chief.id) == true }
                        || (main?.windows.contains { $0.root?.leaves.contains(chief.id) == true } ?? false)
                        || sessions.contains { $0.id != main?.id && $0.windows.contains { $0.root?.leaves.contains(chief.id) == true } }
                    if !placedAnywhere {
                        windows.insert(WindowLayout(name: "1", root: .leaf(chief.id), focused: chief.id), at: 0)
                    } else if windows.isEmpty {
                        windows = [WindowLayout(name: "1", root: nil, focused: nil)]
                    }
                    session = SessionLayout(name: definition.name, windows: windows, current: windows.first?.id)
                }
                session.groups = roots
                session.chief = chief.id
                commanders.append(session)
            }
        } catch {
            startupTitle = L("總指揮遷移尚未完成")
            startupProblem = L("總指揮遷移沒有套用：備份或語言學習檔寫入失敗（\(error.localizedDescription)）。修復後切回首頁或重開即可重試。")
            EventLog.log(L("檔案"), startupProblem ?? "")
            return false
        }

        projects = nextProjects
        groups = nextGroups
        conversations = nextConversations
        // 原本其他的首頁 Session 保留為一般版面；codelab 的 Session 與區內順序完全保留。
        sessions = commanders + sessions.filter { $0.id != main?.id }
        // 不切目前的 Session、不改選取；一次存入全部標記，失敗則沿用 Store 的存檔重試。
        if saveNow() { EventLog.log(L("檔案"), L("已建立總指揮版面（原有 Window 保留）")) }
        return true
    }

    /// 遷移建立的名稱是使用者資料，必須固定為指定的中文，不隨介面語言翻譯。
    private func makeCommanderConversation(project: UUID, title: String, group: UUID?, order: Double) -> Conversation {
        var c = Conversation(projectID: project, title: title)
        c.renamed = true
        c.groupID = group
        c.order = order
        c.model = Prefs.shared.defaultModel
        c.effort = Prefs.shared.defaultEffort
        return c
    }

    /// 資料夾／檔案先建好再套用 state；重試時依組的 parentID、Project 路徑與聊天室名稱重用既有資料。
    private func prepareCommanderLanguages(under study: UUID, projects: inout [Project],
                                          groups: inout [ConvGroup], conversations: inout [Conversation]) throws {
        let languageGroup: UUID
        if let g = groups.first(where: { $0.name == "語言區" && $0.parentID == study }) { languageGroup = g.id }
        else {
            let g = ConvGroup(name: "語言區", parentID: study)
            groups.append(g)
            languageGroup = g.id
        }
        // 測試實例不在真正的家目錄寫學習檔，所有新增檔案留在 --state-dir 內。
        let home = CommandLine.arguments.contains("--state-dir") ? directory : FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(Edition.languageRoot ?? "語言區", isDirectory: true)   // 私人版的 Info.plist 指到專案資料夾底下
        for language in ["日文", "韓文", "英文"] {
            let folder = root.appendingPathComponent(language, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let state = folder.appendingPathComponent("learning-state.md")
            if !FileManager.default.fileExists(atPath: state.path) {
                let text = "# \(language)學習狀態\n\n目前程度：未開始\n教材：\n已學內容：\n常錯：\n下次從哪開始：\n"
                try Data(text.utf8).write(to: state, options: .withoutOverwriting)
            }
            let project: UUID
            if let p = projects.first(where: { URL(fileURLWithPath: ($0.path as NSString).expandingTildeInPath).standardizedFileURL.path == folder.standardizedFileURL.path }) {
                project = p.id
            } else {
                let p = Project(name: language, path: folder.path, groupID: languageGroup)
                projects.append(p)
                project = p.id
            }
            if let i = conversations.firstIndex(where: { $0.projectID == project && $0.title == language && Store.isChat($0) }) {
                conversations[i].groupID = languageGroup
            } else {
                let c = makeCommanderConversation(project: project, title: language, group: languageGroup,
                    order: (conversations.compactMap(\.order).min() ?? 0) - 1)
                conversations.append(c)       // 語言聊天室不放進任何 Window
            }
        }
    }
}
