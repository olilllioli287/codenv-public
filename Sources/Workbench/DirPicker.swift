import SwiftUI
import AppKit

// 「新對話」的資料夾選單：跟使用者在 iTerm 打 claude 時跳出來的那個一樣（~/.zshrc 的 claude 函式），
// 清單共用同一個檔案 ~/.claude/envs（一行一個資料夾），這裡新增／移除，iTerm 那邊也跟著變。
// 用法也一樣：數字鍵選、n 新增、d 從清單移除、. 用目前目錄、q 或 Esc 取消；也可以直接點。

enum ClaudeEnvs {
    /// 使用者的清單；用 --state-dir 開的測試 App 改用測試資料夾裡的副本（第一次從真的複製一份），不會改到真的
    static let file: URL = {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/envs")
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count else { return real }
        let test = URL(fileURLWithPath: a[i + 1]).appendingPathComponent("envs")
        if !FileManager.default.fileExists(atPath: test.path) { try? FileManager.default.copyItem(at: real, to: test) }
        return test
    }()

    static func load() -> [String] {
        guard let s = try? String(contentsOf: file, encoding: .utf8) else {
            let home = NSHomeDirectory()
            let root = Edition.projectsRoot.path
            return root == home ? [home] : [home, root]     // 私人版跟 zsh 那邊第一次的預設一樣；公版只有家目錄
        }
        return s.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func save(_ list: [String]) {
        try? (list.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func tilde(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p == home ? "~" : (p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p)
    }
}

final class DirPickerModel: ObservableObject {
    @Published var dirs: [String] = ClaudeEnvs.load()
    @Published var removing = false
    var current: String?                       // 「用目前目錄」：目前那格的資料夾
    var onPick: ((String) -> Void)?
    var onAdd: (() -> Void)?
    var onCancel: (() -> Void)?
    var onChanged: (() -> Void)?
    var onListChanged: (() -> Void)?      // 清單改了（新增／移除）：側欄跟著同步

    /// 照側欄最上層的組分段（使用者 10/24：新對話照最大的分類選比較清楚）；沒給就不分段
    var topGroups: [(id: UUID, name: String)] = []
    var groupOfPath: ((String) -> UUID?)?
    var setGroup: ((String, UUID) -> Void)?

    /// 畫面上的分段：組名＋這組的資料夾在 dirs 裡的位置；編號照畫面順序（order）
    var sections: [(name: String, items: [Int])] {
        guard !topGroups.isEmpty, let groupOfPath else { return [("", Array(dirs.indices))] }
        var out = topGroups.map { (name: $0.name, items: [Int]()) }
        for (i, p) in dirs.enumerated() {
            let g = groupOfPath(p)
            let k = topGroups.firstIndex { $0.id == g } ?? (out.count - 1)
            out[k].items.append(i)
        }
        return out.filter { !$0.items.isEmpty }
    }
    var order: [Int] { sections.flatMap(\.items) }

    func reload() { dirs = ClaudeEnvs.load() }
    func exists(_ p: String) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue }

    /// n＝畫面上的編號
    func choose(_ n: Int) {
        let o = order
        guard o.indices.contains(n) else { return }
        let i = o[n]
        if removing {
            var l = dirs; l.remove(at: i)
            ClaudeEnvs.save(l)
            dirs = l
            removing = false
            onChanged?()
            onListChanged?()
        } else if exists(dirs[i]) {
            onPick?(dirs[i])
        }
    }
}

struct DirPickerView: View {
    @ObservedObject var m: DirPickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(m.removing ? "要從清單移除哪一個？（資料夾本身不會刪）" : "選擇 Claude Code 的工作目錄")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let order = m.order
                    ForEach(Array(m.sections.enumerated()), id: \.offset) { _, sec in
                    if !sec.name.isEmpty {
                        Text(sec.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 2)
                    }
                    ForEach(sec.items, id: \.self) { i in
                        let p = m.dirs[i], n = order.firstIndex(of: i) ?? i
                        let ok = m.exists(p)
                        Button(action: { m.choose(n) }) {
                            HStack(spacing: 10) {
                                Text("\(n))").font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                                Text(ClaudeEnvs.tilde(p)).font(.system(size: 15)).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(ok ? .primary : .tertiary)
                                if !ok { Text("（不存在）").font(.system(size: 12)).foregroundStyle(.tertiary) }
                                Spacer()
                                if m.removing { Image(systemName: "minus.circle").foregroundStyle(.red.opacity(0.8)) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverPlain())
                        .disabled(!ok && !m.removing)
                        .contextMenu {
                            if let set = m.setGroup {
                                Menu("這個資料夾的新對話放在…") {
                                    ForEach(m.topGroups, id: \.id) { g in
                                        Button((m.groupOfPath?(p) == g.id ? "✓ " : "") + g.name) { set(p, g.id); m.objectWillChange.send() }
                                    }
                                }
                            }
                        }
                    }
                    }
                }
            }
            .frame(height: min(420, CGFloat(m.dirs.count) * 32 + CGFloat(m.sections.filter { !$0.name.isEmpty }.count) * 24 + 4))
            Divider().opacity(0.4).padding(.horizontal, 12).padding(.vertical, 6)
            HStack(spacing: 4) {
                key("n", "新增") { m.onAdd?() }
                key("d", m.removing ? "不移除了" : "從清單移除") { m.removing.toggle() }
                if let c = m.current { key(".", "用目前目錄 " + ClaudeEnvs.tilde(c)) { m.onPick?(c) } }
                Spacer(minLength: 0)
                key("q", "取消") { m.onCancel?() }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private func key(_ k: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(k + ")").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverPlain())
    }
}

/// 開關這個選單、處理按鍵（用實體按鍵位置判斷，唯音開著中文也能按數字和字母）
final class DirPicker {
    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    let model = DirPickerModel()
    private var lastPick: ((String) -> Void)?
    private var closedAt = Date.distantPast

    /// 側欄「新對話」、⌘ N：開著就收起來。點按鈕時，按下去那一下已經先把選單當成「點外面」收掉了，
    /// 放開才叫到這裡，所以剛收掉（0.5 秒內）的也算「再按一次＝關掉」，不要又打開
    func toggle(in window: NSWindow, current: String?, pick: @escaping (String) -> Void) {
        if panel != nil { close(); return }
        if Date().timeIntervalSince(closedAt) < 0.5 { return }
        show(in: window, current: current, pick: pick)
    }

    func show(in window: NSWindow, current: String?, pick: @escaping (String) -> Void) {
        close()
        lastPick = pick
        model.onChanged = { [weak self] in DispatchQueue.main.async { self?.resize() } }
        model.reload()
        model.removing = false
        model.current = current
        model.onPick = { [weak self] p in self?.close(); pick(p) }
        model.onCancel = { [weak self] in self?.close() }
        model.onAdd = { [weak self] in self?.add(in: window) }
        let host = NSHostingView(rootView: DirPickerView(m: model))
        let size = NSHostingView(rootView: DirPickerView(m: model)).fittingSize
        host.sizingOptions = []
        let p = FloatingPanel(content: host)
        p.onClose = { [weak self] in self?.panel = nil; self?.closedAt = Date(); self?.removeKeys() }
        // 擺在側欄「新對話」按鈕的右下方
        let f = window.frame
        p.setFrame(NSRect(x: f.minX + 70, y: f.maxY - 170 - size.height, width: size.width, height: size.height), display: true)
        window.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
        panel = p
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel != nil else { return e }
            return self.key(e) ? nil : e
        }
    }

    private func resize() {
        guard let p = panel else { return }
        let size = NSHostingView(rootView: DirPickerView(m: model)).fittingSize
        var f = p.frame
        f.origin.y += f.height - size.height
        f.size = size
        p.setFrame(f, display: true)
    }

    private func key(_ e: NSEvent) -> Bool {
        // ⌘ Q、⌘ N 這類帶修飾鍵的照常交給 App
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        // 編號從 0 開始（使用者 10/24：0＝家目錄，1～9 照清單）
        let digits: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if let n = digits[e.keyCode] { model.choose(n); resize(); return true }
        switch e.keyCode {
        case 45: model.onAdd?()                                   // n
        case 2: model.removing.toggle()                           // d
        case 47: if let c = model.current { model.onPick?(c) }    // .
        case 12, 53: close()                                       // q、Esc
        default: return false
        }
        return true
    }

    /// n) 新增：選一個資料夾（可以在裡面建新的），加到清單最後
    private func add(in window: NSWindow) {
        let o = NSOpenPanel()
        o.canChooseDirectories = true
        o.canChooseFiles = false
        o.canCreateDirectories = true
        o.prompt = "加到清單"
        o.message = "選一個資料夾加到清單（跟 iTerm 打 claude 的清單是同一份）"
        o.directoryURL = Edition.projectsRoot
        // 先收起選單（不然點選資料夾視窗會被當成「點外面」），選完再打開
        let current = model.current, pick = lastPick
        close()
        o.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            if r == .OK, let u = o.url {
                var l = ClaudeEnvs.load()
                if !l.contains(u.path) { l.append(u.path); ClaudeEnvs.save(l) }
                self.model.onListChanged?()
            }
            if let pick { self.show(in: window, current: current, pick: pick) }
        }
    }

    func close() {
        panel?.close()
        panel = nil
        removeKeys()
    }
    private func removeKeys() { if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil } }
}

extension Store {
    /// 側欄的專案跟 ~/.claude/envs 同步：清單裡的資料夾都放進側欄（照清單順序排在前面），其他專案排後面
    func syncEnvs() {
        let envs = ClaudeEnvs.load()
        let fm = FileManager.default
        for p in envs where !projects.contains(where: { $0.path == p }) {
            var d: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &d), d.boolValue else { continue }
            let name = p == NSHomeDirectory() ? "~" : (p as NSString).lastPathComponent
            projects.append(Project(name: name, path: p))
        }
        let order = Dictionary(envs.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = projects.enumerated().sorted { a, b in
            let ia = order[a.element.path] ?? Int.max, ib = order[b.element.path] ?? Int.max
            return ia != ib ? ia < ib : a.offset < b.offset
        }.map(\.element)
        if sorted.map(\.id) != projects.map(\.id) { projects = sorted }
    }

    /// 側欄加專案時也加進清單（iTerm 打 claude 的選單就看得到）
    func addToEnvs(_ path: String) {
        var l = ClaudeEnvs.load()
        if !l.contains(path) { l.append(path); ClaudeEnvs.save(l) }
    }

    /// 側欄移除專案時也從清單移除（資料夾本身不刪）
    func removeFromEnvs(_ path: String) {
        let l = ClaudeEnvs.load()
        if l.contains(path) { ClaudeEnvs.save(l.filter { $0 != path }) }
    }
}
