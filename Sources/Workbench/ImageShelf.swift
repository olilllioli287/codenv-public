import AppKit
import SwiftTerm

// 給 image-shelf（Claude Code 的圖片架 mod，原始碼位置由 Info.plist 的 CodenvImageShelf 指定）用的圖片架。
// image-shelf 在輸入框上方留空白列，把架上的圖寫進 /private/tmp/image-shelf/<對話編號前 8 碼>/shelf.json；
// 在 iTerm／tmux 裡由它自己的浮動視窗（panel/shelf.swift）蓋上縮圖。工作台裡那個視窗找不到位置，
// 所以改由這裡畫：工作台知道每一格在哪，不用截螢幕量位置。找空白列的規則照搬 panel/shelf.swift 的 layout()。

private struct ShelfItem: Decodable { let n: Int; let thumb: String; let copy: String; let edited: Bool; let label: String? }
private struct ShelfFile: Decodable {
    let visible: Bool
    let items: [ShelfItem]
    var editor: String? = nil
    var page: String? = nil
}

private final class ShelfTile: NSImageView {
    var file = "", label = "", n = 0
    var editor: String?, page: String?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 點一下用 image-shelf 的標註編輯器打開；編輯器還沒編好就用預覽程式
    override func mouseDown(with event: NSEvent) {
        if let editor, !editor.isEmpty, let page {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: editor)
            p.arguments = [page, file, file, label.isEmpty ? "Image #\(n)" : label, "zh-Hant"]
            p.standardOutput = FileHandle.nullDevice
            if (try? p.run()) != nil { return }
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: file)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 圖片列可以左右捲：觸控板左右滑，或按住 Shift 滾滾輪
private final class ShelfStrip: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if event.deltaX == 0 && event.modifierFlags.contains(.shift), let cg = event.cgEvent?.copy() {
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            if let turned = NSEvent(cgEvent: cg) { return super.scrollWheel(with: turned) }
        }
        if event.phase != [] || event.momentumPhase != [] || event.deltaX != 0 { super.scrollWheel(with: event) }
    }
}

final class ImageShelfOverlay: NSView {
    private let folder: String
    private let strip = ShelfStrip()
    private let content = NSView()
    private let patch = NSView()      // 蓋住 Claude Code 畫的 [-]
    private let backdrop = NSView()   // 空白列裡有提示字時墊在圖片底下
    private var lastMTime: Date?
    private var shelf: ShelfFile?
    private var drawnKey = ""
    private var toldRows = -1
    private var lastCount = 0
    private var images: [String: NSImage] = [:]
    var background: NSColor = .black

    private static let gap: CGFloat = 8, mostRows = 6, aspect: CGFloat = 1.6

    init(claudeSession: UUID) {
        folder = "/private/tmp/image-shelf/" + String(claudeSession.uuidString.lowercased().prefix(8))
        super.init(frame: .zero)
        isHidden = true
        for v in [backdrop, patch] { v.wantsLayer = true }
        strip.drawsBackground = false
        strip.hasHorizontalScroller = true
        strip.hasVerticalScroller = false
        strip.scrollerStyle = .overlay
        strip.horizontalScrollElasticity = .allowed
        strip.verticalScrollElasticity = .none
        strip.documentView = content
        addSubview(backdrop)
        addSubview(strip)
        addSubview(patch)
    }
    required init?(coder: NSCoder) { fatalError() }

    // 只有圖片本身吃滑鼠，其他地方交給底下的終端機（選字、點擊）
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let hit = super.hitTest(point) else { return nil }
        var v: NSView? = hit
        while let x = v, x !== self { if x is ShelfTile || x is NSScroller { return hit }; v = x.superview }
        return nil
    }

    /// 定時呼叫：讀 shelf.json、從終端機畫面找空白列，擺好縮圖
    func update(terminal: TerminalView, hidden: Bool) {
        readShelf()
        guard !hidden, let s = shelf, s.visible, !s.items.isEmpty else { isHidden = true; return }
        let cell = terminal.cellSizePublic
        guard cell.height > 0 else { isHidden = true; return }
        var lines: [String] = [], cols = 0
        terminal.withTerminalPublic { t in
            cols = t.cols
            for r in 0..<t.rows {
                lines.append((t.getLine(row: r)?.translateToString(trimRight: true) ?? "").replacingOccurrences(of: "\u{0}", with: " "))
            }
        }
        guard let m = Self.layout(lines, cols, Self.mostRows), m.tileRows >= 1 else { isHidden = true; return }
        if m.tileRows != toldRows {
            toldRows = m.tileRows
            try? "{\"rows\":\(m.tileRows)}".write(toFile: folder + "/layout.json", atomically: true, encoding: .utf8)
        }
        draw(s, marks: m, cell: cell, cols: cols, in: terminal)
        isHidden = false
    }

    private func readShelf() {
        let path = folder + "/shelf.json"
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard mtime != lastMTime else { return }
        lastMTime = mtime
        shelf = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(ShelfFile.self, from: $0) }
    }

    private func image(_ file: String) -> NSImage? {
        if let held = images[file] { return held }
        guard let made = NSImage(contentsOfFile: file) else { return nil }
        images[file] = made
        return made
    }

    private func draw(_ s: ShelfFile, marks m: Marks, cell: CGSize, cols: Int, in terminal: TerminalView) {
        // 這個 view 跟終端機同大小、同位置；SwiftTerm 的列從頂端往下排
        frame = terminal.frame
        let top = bounds.height
        let height = CGFloat(m.tileRows) * cell.height
        let bandBottom = top - CGFloat(m.rule) * cell.height
        let below = m.hasText ? (cell.height * 0.3).rounded() : 0
        let reserved = 5 * cell.width
        let width = CGFloat(cols) * cell.width
        strip.frame = NSRect(x: 0, y: bandBottom, width: max(0, width - reserved), height: height)
        backdrop.frame = NSRect(x: 0, y: bandBottom - below, width: width, height: below + height - 5)
        backdrop.layer?.backgroundColor = background.cgColor
        backdrop.isHidden = !m.hasText
        if let c = m.collapse {
            let extra = cell.height * 0.35
            let rowBottom = top - CGFloat(c + 1) * cell.height
            patch.frame = NSRect(x: width - reserved, y: rowBottom - extra, width: reserved, height: cell.height + 2 * extra)
            patch.layer?.backgroundColor = background.cgColor
            patch.isHidden = false
        } else {
            patch.isHidden = true
        }

        let isLight = (background.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.5
        let key = s.items.map { "\($0.n):\($0.thumb):\($0.edited)" }.joined(separator: ",") + "@\(width)x\(height)\(isLight ? "L" : "D")"
        guard key != drawnKey else { return }
        drawnKey = key
        let shown = s.items.compactMap { item -> (ShelfItem, NSImage)? in
            guard let p = image(item.thumb), p.size.height > 0 else { return nil }
            return (item, p)
        }
        let tileH = height - 7, tileW = tileH * Self.aspect
        content.subviews.forEach { $0.removeFromSuperview() }
        let total = max(width - reserved, CGFloat(shown.count) * (tileW + Self.gap) - Self.gap)
        content.frame = NSRect(x: 0, y: 0, width: total, height: height)
        for (i, (item, picture)) in shown.enumerated() {
            let x = CGFloat(i) * (tileW + Self.gap)
            let tile = ShelfTile(frame: NSRect(x: x, y: 2, width: tileW, height: tileH))
            tile.image = picture
            tile.imageScaling = .scaleProportionallyDown
            tile.file = item.copy; tile.n = item.n; tile.label = item.label ?? ""
            tile.editor = s.editor; tile.page = s.page
            tile.wantsLayer = true
            tile.layer?.backgroundColor = (isLight ? NSColor(white: 0.88, alpha: 0.95) : NSColor(white: 0.08, alpha: 0.95)).cgColor
            tile.layer?.cornerRadius = 4
            tile.layer?.borderWidth = item.edited ? 2 : 1
            tile.layer?.borderColor = (item.edited ? NSColor.systemOrange : (isLight ? NSColor.black.withAlphaComponent(0.25) : NSColor.white.withAlphaComponent(0.35))).cgColor
            tile.layer?.masksToBounds = true
            let name = item.label ?? "#\(item.n)"
            tile.toolTip = "\(item.label ?? "Image #\(item.n)")：點一下標註"
            content.addSubview(tile)
            let badge = NSTextField(labelWithString: item.edited ? " \(name) 已編輯 " : " \(name) ")
            badge.font = .boldSystemFont(ofSize: m.tileRows <= 2 ? 9 : 11)
            badge.textColor = .white
            badge.drawsBackground = true
            badge.backgroundColor = NSColor.black.withAlphaComponent(0.7)
            badge.sizeToFit()
            badge.frame.origin = NSPoint(x: x + 2, y: 4)
            content.addSubview(badge)
        }
        // 新貼的圖捲到看得見
        if shown.count > lastCount {
            strip.contentView.scroll(to: NSPoint(x: max(0, total - (width - reserved)), y: 0))
            strip.reflectScrolledClipView(strip.contentView)
        }
        lastCount = shown.count
    }

    // MARK: 找空白列（照 image-shelf 的 panel/shelf.swift）

    struct Marks { let rule: Int; let under: Int; let collapse: Int?; let tileRows: Int; let hasText: Bool }

    static func isFrame(_ l: String, _ width: Int, _ open: Character, _ close: Character) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.first == open && t.last == close && t.count >= width * 9 / 10
    }

    /// 橫跨整格的線：全是「─」，或（對話有標題時）兩端是「─」、中間夾一段標題
    static func isRule(_ line: String, _ width: Int) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.count >= max(10, width * 6 / 10) && t.allSatisfy({ $0 == "─" }) { return true }
        guard t.first == "─", t.last == "─", t.prefix(10).allSatisfy({ $0 == "─" }) else { return false }
        let inner = t.drop { $0 == "─" }.reversed().drop { $0 == "─" }
        let wide: [ClosedRange<UInt32>] = [0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                                           0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD]
        let columns = t.unicodeScalars.reduce(0) { n, s in n + (wide.contains { $0.contains(s.value) } ? 2 : 1) }
        return !inner.contains("─") && columns >= width * 9 / 10
    }

    static func layout(_ lines: [String], _ width: Int, _ most: Int) -> Marks? {
        let rules = lines.enumerated().filter { isRule($0.element, width) }.map { $0.offset }
        guard rules.count >= 2 else { return nil }
        let rule = rules[rules.count - 2]
        let collapse = lines[max(0, rule - 8)..<rule].lastIndex { $0.trimmingCharacters(in: .whitespaces).hasSuffix("[-]") }
        var tileRows = collapse.map { min(most, rule - $0) } ?? 0
        if tileRows < 3, let bottom = lines[max(0, rule - 3)..<rule].lastIndex(where: { isFrame($0, width, "╰", "╯") }),
           let top = lines[..<bottom].lastIndex(where: { isFrame($0, width, "╭", "╮") }) {
            tileRows = max(tileRows, min(4, most, rule - top - 1))
        }
        let hasText = lines[max(0, rule - tileRows)..<rule].contains { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t != "[-]"
        }
        return Marks(rule: rule, under: rules[rules.count - 1], collapse: collapse, tileRows: tileRows, hasText: hasText)
    }
}
