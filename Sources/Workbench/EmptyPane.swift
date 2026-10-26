import AppKit

// 空的格子：分頁列的 ＋、Ctrl+A c 開的 Window，Ctrl+A | - 切出來的那格，先不開聊天室。
// 中間一顆「新增聊天室」：按下去照側欄的組（學業、RTS…）列出來，在那組的資料夾開新聊天室，或打開那組現有的。
// 空格子在版面裡就是一個沒有對應對話的 leaf，id 記在 Store.emptySlots（跟著版面存檔，重開 App 還在）。

extension Store {
    static var emptySlots = Set<UUID>()
    static var layoutLoaded = false

    /// 開一個空格子的 id
    func newEmptySlot() -> UUID {
        let id = UUID()
        Store.emptySlots.insert(id)
        return id
    }

    func isEmptySlot(_ id: UUID) -> Bool { conversation(id) == nil && Store.emptySlots.contains(id) }
}

final class EmptyPaneView: NSView {
    /// 版面裡的空格子 id；nil＝整個 Window 都是空的（沒有任何格子）
    let slot: UUID?
    var onAdd: ((NSView) -> Void)?
    var onClose: (() -> Void)?
    var isFocused = false { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var closable = false { didSet { closeButton.isHidden = !closable } }
    private let label = NSTextField(labelWithString: L("空的格子"))
    private let addButton = NSButton(title: L("新增聊天室"), target: nil, action: nil)
    private let hint = NSTextField(labelWithString: L("也可以從左邊把聊天室拖進來"))
    private let closeButton = NSButton()

    init(slot: UUID?) {
        self.slot = slot
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.image = NSImage(systemSymbolName: "plus.bubble", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.target = self
        addButton.action = #selector(add)
        addSubview(addButton)
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        addSubview(hint)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("關掉這格"))?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeSlot)
        closeButton.toolTip = L("關掉這格")
        closeButton.isHidden = true
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let ls = label.intrinsicContentSize, bs = addButton.intrinsicContentSize, hs = hint.intrinsicContentSize
        let total = ls.height + 12 + bs.height + 10 + hs.height
        var y = b.midY + total / 2
        y -= ls.height; label.frame = NSRect(x: b.midX - ls.width / 2, y: y, width: ls.width, height: ls.height)
        y -= 12 + bs.height; addButton.frame = NSRect(x: b.midX - bs.width / 2 - 8, y: y, width: bs.width + 16, height: bs.height)
        y -= 10 + hs.height; hint.frame = NSRect(x: b.midX - hs.width / 2, y: y, width: hs.width, height: hs.height)
        closeButton.frame = NSRect(x: b.width - 26, y: b.height - 24, width: 20, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 6, dy: 6)
        let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        p.lineWidth = isFocused ? 2 : 1
        p.setLineDash([6, 4], count: 2, phase: 0)
        (isFocused ? accent.withAlphaComponent(0.8) : NSColor.separatorColor).setStroke()
        p.stroke()
    }

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    @objc private func add() { onAdd?(addButton) }
    @objc private func closeSlot() { onClose?() }
}

extension MainWindowController {
    /// 空格子「新增聊天室」的選單：每一組一個子選單（那組的資料夾開新的、那組現有的聊天室），最後是「其他資料夾…」
    func showEmptyMenu(slot: UUID?, from v: NSView) {
        let m = NSMenu()
        let groups = store.groups
        if groups.isEmpty {
            for p in store.projects { m.addItem(projectItem(p.id, group: nil, slot: slot)) }
        } else {
            for t in store.groupTree() {
                let g = t.group
                let item = NSMenuItem(title: String(repeating: "　", count: t.depth) + g.name, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let convs = store.conversations(inGroup: g.id).filter { !store.isArchived($0) && $0.terminal != true && $0.draft != true }   // 草稿跟側欄一樣不列
                // 這組有哪些資料夾：資料夾預設放這組的＋這組聊天室用到的
                var pids: [UUID] = store.projects.filter { $0.groupID == g.id }.map(\.id)
                for c in convs where !pids.contains(c.projectID) { pids.append(c.projectID) }
                for pid in pids {
                    guard let p = store.project(pid) else { continue }
                    let add = ActionItem(title: L("＋ 新聊天室（\(p.name)）")) { [weak self] in self?.fillEmpty(slot, newIn: pid, group: g.id) }
                    add.toolTip = ClaudeEnvs.tilde(p.path)
                    sub.addItem(add)
                }
                if pids.isEmpty {
                    sub.addItem(ActionItem(title: L("＋ 新聊天室（選資料夾…）")) { [weak self] in self?.pickFolderForEmpty(slot, group: g.id) })
                }
                if !convs.isEmpty {
                    sub.addItem(.separator())
                    let head = NSMenuItem(title: L("打開這組的聊天室"), action: nil, keyEquivalent: ""); head.isEnabled = false
                    sub.addItem(head)
                    for c in convs.prefix(30) {
                        let placed = store.locate(c.id) != nil
                        let it = ActionItem(title: c.title + (placed ? L("（已在別的格子，會搬過來）") : "")) { [weak self] in self?.fillEmpty(slot, with: c.id) }
                        sub.addItem(it)
                    }
                }
                item.submenu = sub
                m.addItem(item)
            }
        }
        m.addItem(.separator())
        m.addItem(ActionItem(title: L("瀏覽器（Gemini 網頁版）")) { [weak self] in
            guard let self, let pid = self.store.selectedProject ?? self.store.projects.first?.id else { return }
            self.fillEmpty(slot, with: self.store.createBrowser(in: pid).id)
        })
        m.addItem(ActionItem(title: L("其他資料夾…")) { [weak self] in self?.pickFolderForEmpty(slot, group: nil) })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: v.bounds.height + 4), in: v)
    }

    private func projectItem(_ pid: UUID, group: UUID?, slot: UUID?) -> NSMenuItem {
        let name = store.project(pid)?.name ?? "?"
        return ActionItem(title: L("＋ 新聊天室（\(name)）")) { [weak self] in self?.fillEmpty(slot, newIn: pid, group: group) }
    }

    private func pickFolderForEmpty(_ slot: UUID?, group: UUID?) {
        guard let window else { return }
        dirPicker.show(in: window, current: nil) { [weak self] path in
            guard let self else { return }
            let pid = self.store.projects.first(where: { $0.path == path })?.id ?? self.store.addProject(path: path).id
            self.fillEmpty(slot, newIn: pid, group: group)
        }
    }

    /// 在那個資料夾開新聊天室放進空格子（選了組就歸那組）
    func fillEmpty(_ slot: UUID?, newIn pid: UUID, group: UUID?) {
        let c = store.createConversation(in: pid, draft: true)
        if let group, store.groupOf(c) != group { store.move(c.id, toGroup: group) }
        fillEmpty(slot, with: c.id)
    }

    /// 把某段聊天放進空格子（原本擺在別處會搬過來）
    func fillEmpty(_ slot: UUID?, with conv: UUID) {
        if let slot, store.locate(slot) != nil {
            _ = store.replacePane(slot, with: conv)
            Store.emptySlots.remove(slot)
        } else if let w = store.currentWindow {
            store.movePane(conv, toWindow: w.id)
        }
        store.selected = conv
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in _ = self?.focusChatInput() }
    }
}

/// 帶 closure 的選單項目
final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
