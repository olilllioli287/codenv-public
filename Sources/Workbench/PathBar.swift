import AppKit

/// 每一格最下面的資料夾路徑列（照 Finder 視窗底部那條）：Macintosh HD › 使用者 › 名字 › 文件 › …，每一層一個圖示＋名字。
/// 名字用 Finder 顯示的（系統語言的「使用者」「文件」）；放不下時從最前面開始收成「…」，最後一層一定留著。
/// 點某一層＝在 Finder 打開那個資料夾。
final class PathBar: NSView {
    static let height: CGFloat = 26
    private(set) var path: String?
    private var buttons: [NSButton] = []
    private var arrows: [NSTextField] = []
    private let more = NSTextField(labelWithString: "…")

    override init(frame: NSRect) {
        super.init(frame: frame)
        more.textColor = .tertiaryLabelColor
        addSubview(more)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setPath(_ p: String?) {
        guard p != path else { return }
        path = p
        buttons.forEach { $0.removeFromSuperview() }
        arrows.forEach { $0.removeFromSuperview() }
        buttons = []
        arrows = []
        guard let p, !p.isEmpty else { needsLayout = true; return }
        let f = UIScale.shared.f
        for (i, seg) in Self.segments(p).enumerated() {
            if i > 0 {
                let a = NSTextField(labelWithString: "›")
                a.font = .systemFont(ofSize: 12 * f)
                a.textColor = .tertiaryLabelColor
                addSubview(a)
                arrows.append(a)
            }
            let b = NSButton(title: seg.name, target: self, action: #selector(open(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11.5 * f)
            b.contentTintColor = .secondaryLabelColor
            let icon = NSWorkspace.shared.icon(forFile: seg.path)
            icon.size = NSSize(width: 14 * f, height: 14 * f)
            b.image = icon
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            b.toolTip = seg.path + "\n" + L("點一下：在 Finder 打開")
            b.identifier = NSUserInterfaceItemIdentifier(seg.path)
            b.lineBreakMode = .byTruncatingTail
            addSubview(b)
            buttons.append(b)
        }
        more.font = .systemFont(ofSize: 11.5 * f)
        needsLayout = true
    }

    /// 家目錄底下的「Documents」→ [Macintosh HD, 使用者, 你的名字, 文件]（每一層的名字和完整路徑）
    static func segments(_ p: String) -> [(name: String, path: String)] {
        let fm = FileManager.default
        var out = [(name: fm.displayName(atPath: "/"), path: "/")]
        var cur = ""
        for comp in (p as NSString).standardizingPath.split(separator: "/") {
            cur += "/" + comp
            out.append((fm.displayName(atPath: cur), cur))
        }
        return out
    }

    @objc private func open(_ sender: NSButton) {
        guard let p = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p, isDirectory: true))
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 2
        let x0: CGFloat = 10, maxX = bounds.width - 10
        let widths = buttons.map { ceil($0.intrinsicContentSize.width) }
        let aw = arrows.first.map { ceil($0.intrinsicContentSize.width) } ?? 0
        // 從最後一層往前放，放不下就停（前面收成「…」）
        var first = buttons.count
        var used: CGFloat = 0
        let moreW = ceil(more.intrinsicContentSize.width) + aw + gap * 2
        // 整條放得下就全部顯示；放不下才從最後一層往前放、前面留「…」的位置
        let all = widths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * (aw + gap * 2)
        if all <= maxX - x0 { first = 0 } else { for i in stride(from: buttons.count - 1, through: 0, by: -1) {
            let w = widths[i] + (i > 0 ? aw + gap * 2 : 0)
            let reserve: CGFloat = i > 0 ? moreW : 0
            if used + w + reserve > maxX - x0, first < buttons.count { break }
            used += w
            first = i
        } }
        var x = x0
        more.isHidden = first == 0 || buttons.isEmpty
        if !more.isHidden {
            let s = more.intrinsicContentSize
            more.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            x += s.width + gap
        }
        for (i, b) in buttons.enumerated() {
            let hidden = i < first
            b.isHidden = hidden
            // 「›」在這一層前面：兩層都看得到，或前面是「…」時才畫
            if i > 0 {
                let a = arrows[i - 1]
                let show = !hidden && (i > first || !more.isHidden)
                a.isHidden = !show
                if show {
                    let s = a.intrinsicContentSize
                    a.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
                    x += s.width + gap
                }
            }
            guard !hidden else { continue }
            let w = min(widths[i], max(0, maxX - x))
            let h = b.intrinsicContentSize.height
            b.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
            x += w + gap
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 上緣一條細線，跟上面的內容隔開（跟 Finder 一樣）
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
