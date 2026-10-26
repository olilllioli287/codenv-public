import AppKit

/// 斜線指令（/compact、/model、技能……）：清單是 claude 開起來時在 initialize 的回覆裡給的，
/// 記在設定裡，新對話還沒開 claude 之前也有得選
struct SlashCommand: Codable, Equatable {
    let name: String
    let description: String
    let hint: String

    init?(_ d: [String: Any]) {
        guard let n = d["name"] as? String, !n.isEmpty, !n.hasPrefix("_") else { return nil }
        name = n
        // 說明尾巴的「(user)」「(vercel) 」之類來源標記拿掉，HTML 實體還原
        var s = (d["description"] as? String ?? "")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        if let r = s.range(of: #"\s*\((user|project|bundled|dynamic workflow)\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"^\([\w-]+\)\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        description = s
        hint = d["argumentHint"] as? String ?? ""
    }

    /// 只能在終端機用的（init 的 terminal_slash_commands）不列
    static var terminalOnly: Set<String> {
        get { Set(appDefaults.stringArray(forKey: "terminalSlashCommands") ?? []) }
        set { appDefaults.set(Array(newValue), forKey: "terminalSlashCommands") }
    }
    static var known: [SlashCommand] {
        guard let d = appDefaults.data(forKey: "slashCommands"), let l = try? JSONDecoder().decode([SlashCommand].self, from: d) else { return [] }
        return l
    }
    static func remember(_ l: [SlashCommand]) {
        if let d = try? JSONEncoder().encode(l) { appDefaults.set(d, forKey: "slashCommands") }
    }

    /// 篩選：名字開頭符合的先，再來名字裡有的（vercel:deploy 打 deploy 也找得到），最後說明裡有的
    static func matches(_ q: String, in all: [SlashCommand]) -> [SlashCommand] {
        let skip = terminalOnly
        let list = all.filter { !skip.contains($0.name) }
        let q = q.lowercased()
        if q.isEmpty { return list }
        let a = list.filter { $0.name.lowercased().hasPrefix(q) }
        let b = list.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        let c = list.filter { !$0.name.lowercased().contains(q) && $0.description.lowercased().contains(q) }
        return a + b + c
    }
}

/// 輸入框上面跳出來的指令清單（跟 Claude Code 一樣）：↑ ↓ 選、Tab 或 Enter 填進去、Esc 關掉
final class SlashMenu: NSView {
    static let rowH: CGFloat = 30
    static let maxRows = 8
    private(set) var items: [SlashCommand] = []
    private(set) var selected = 0
    private var top = 0   // 捲到第幾個
    var onPick: ((SlashCommand) -> Void)?
    var fg = NSColor.labelColor
    var bg = NSColor.windowBackgroundColor
    var accent = NSColor.controlAccentColor
    var font = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)

    override var isFlipped: Bool { true }

    func set(_ l: [SlashCommand]) {
        items = l
        selected = 0
        top = 0
        isHidden = l.isEmpty
        needsDisplay = true
    }
    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + d + items.count) % items.count
        if selected < top { top = selected }
        if selected >= top + Self.maxRows { top = selected - Self.maxRows + 1 }
        needsDisplay = true
    }
    var current: SlashCommand? { items.indices.contains(selected) ? items[selected] : nil }
    var height: CGFloat { CGFloat(min(items.count, Self.maxRows)) * Self.rowH + 8 }

    override func draw(_ dirty: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        bg.setFill(); path.fill()
        fg.withAlphaComponent(0.15).setStroke(); path.stroke()
        let nameW = min(260, bounds.width * 0.4)
        let small = NSFont.systemFont(ofSize: font.pointSize * 0.86)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        for (row, i) in (top..<min(items.count, top + Self.maxRows)).enumerated() {
            let c = items[i]
            let r = NSRect(x: 4, y: 4 + CGFloat(row) * Self.rowH, width: bounds.width - 8, height: Self.rowH)
            if i == selected {
                accent.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let name = NSMutableAttributedString(string: "/" + c.name, attributes: [.font: font, .foregroundColor: i == selected ? fg : fg.withAlphaComponent(0.85), .paragraphStyle: para])
            if !c.hint.isEmpty { name.append(NSAttributedString(string: " " + c.hint, attributes: [.font: small, .foregroundColor: fg.withAlphaComponent(0.45), .paragraphStyle: para])) }
            // 兩種字型的行高不一樣：各自置中，看起來才在同一條線上
            let lh = { (f: NSFont) in ceil(f.ascender - f.descender + f.leading) }
            name.draw(with: NSRect(x: r.minX + 10, y: r.minY + (Self.rowH - lh(font)) / 2, width: nameW - 14, height: Self.rowH), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let desc = NSAttributedString(string: c.description.replacingOccurrences(of: "\n", with: " "), attributes: [.font: small, .foregroundColor: fg.withAlphaComponent(0.55), .paragraphStyle: para])
            desc.draw(with: NSRect(x: r.minX + nameW, y: r.minY + (Self.rowH - lh(small)) / 2, width: r.width - nameW - 8, height: Self.rowH), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if items.count > Self.maxRows {
            let s = NSAttributedString(string: "\(selected + 1)/\(items.count)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: fg.withAlphaComponent(0.4)])
            s.draw(at: NSPoint(x: bounds.maxX - s.size().width - 10, y: bounds.maxY - 14))
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = top + Int((p.y - 4) / Self.rowH)
        guard items.indices.contains(i) else { return }
        selected = i
        needsDisplay = true
        onPick?(items[i])
    }
    override func scrollWheel(with e: NSEvent) {
        guard items.count > Self.maxRows else { return }
        let d = e.scrollingDeltaY > 0 ? -1 : (e.scrollingDeltaY < 0 ? 1 : 0)
        top = max(0, min(items.count - Self.maxRows, top + d))
        needsDisplay = true
    }
}
