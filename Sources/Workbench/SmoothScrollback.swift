import AppKit
import SwiftTerm

// 平滑捲動閱讀層：往上捲看歷史紀錄時，蓋在終端機上面的一層 Mac 原生捲動畫面（像素捲動、有慣性、會回彈），
// 照終端機同樣的格子大小、基線、顏色畫出每一行，所以剛出現、剛收起來的那一刻看起來跟終端機一模一樣。
// 終端機本身照常負責輸入、輸入法、游標；捲回最底下或開始打字，這層就收起來。

/// 一格要畫的東西（在終端機的鎖裡複製出來，畫的時候就不用再拿鎖）
private struct Cell {
    var text: String
    var width: Int
    var fg, bg: Attribute.Color
    var style: CharacterStyle
}

final class ScrollbackDocument: NSView {
    weak var terminal: TerminalView?
    var palette: Palette
    var font: NSFont
    var boldFont: NSFont
    var cell: CGSize = .zero
    var baseline: CGFloat = 0        // 從格子底部到基線的距離（跟 SwiftTerm 的 CellGeometry.baselineOffset 同一個算法）
    var firstAbsolute = 0            // 第 0 行對應到緩衝區的絕對行號（含已經被丟掉的舊行）
    var cursor: (row: Int, col: Int)? // 絕對行號、欄

    init(palette: Palette, font: NSFont, boldFont: NSFont) {
        self.palette = palette
        self.font = font
        self.boldFont = boldFont
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirty: NSRect) {
        palette.bg.setFill()
        dirty.fill()
        guard let terminal, cell.height > 0 else { return }
        let first = max(0, Int(floor(dirty.minY / cell.height)))
        let last = Int(ceil(dirty.maxY / cell.height))
        // 在鎖裡只複製這幾行的資料
        var rows: [(index: Int, cells: [Cell])] = []
        terminal.withTerminalPublic { t in
            let trimmed = t.buffer.totalLinesTrimmed
            for i in first...last {
                guard let line = t.bufferLine(atRow: firstAbsolute + i - trimmed) else { continue }
                var cells: [Cell] = []
                cells.reserveCapacity(line.count)
                for c in 0..<line.count {
                    let cd = line[c]
                    cells.append(Cell(text: String(cd.getCharacter()), width: Int(cd.width),
                                      fg: cd.attribute.fg, bg: cd.attribute.bg, style: cd.attribute.style))
                }
                rows.append((i, cells))
            }
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for r in rows { drawLine(r.cells, top: CGFloat(r.index) * cell.height, in: ctx) }
        if let cur = cursor {
            let row = cur.row - firstAbsolute
            if row >= first && row <= last {
                palette.cursor.setFill()
                NSRect(x: CGFloat(cur.col) * cell.width, y: CGFloat(row) * cell.height, width: 2, height: cell.height).fill()
            }
        }
    }

    /// 同樣樣式、同樣寬度的連續格子當成一段，每段從自己的欄位開始畫，就算有缺字換字型也不會一路歪過去
    private func drawLine(_ cells: [Cell], top: CGFloat, in ctx: CGContext) {
        var col = 0
        var i = 0
        while i < cells.count {
            let c = cells[i]
            if c.width == 0 { i += 1; col += 0; continue }   // 全形字的後半格
            var j = i + 1, text = c.text, span = c.width
            if c.width == 1 {
                while j < cells.count, cells[j].width == 1, cells[j].fg == c.fg, cells[j].bg == c.bg, cells[j].style == c.style {
                    text += cells[j].text; span += 1; j += 1
                }
            }
            drawSegment(text, startCol: col, span: span, cell: c, top: top, in: ctx)
            col += span
            i = j
            while i < cells.count && cells[i].width == 0 { i += 1 }
        }
    }

    private func drawSegment(_ text: String, startCol: Int, span: Int, cell c: Cell, top: CGFloat, in ctx: CGContext) {
        let bold = c.style.contains(.bold)
        // 反白：前景背景對調，對調後的「預設」改成「反轉的預設」（照 SwiftTerm）
        var fgC = c.fg, bgC = c.bg
        if c.style.contains(.inverse) {
            swap(&fgC, &bgC)
            if fgC == .defaultColor { fgC = .defaultInvertedColor }
            if bgC == .defaultColor { bgC = .defaultInvertedColor }
        }
        var fg = palette.color(fgC, isFg: true, bold: bold)
        let bg = palette.color(bgC, isFg: false)
        if c.style.contains(.dim) { fg = fg.withAlphaComponent(0.6) }
        let rect = NSRect(x: CGFloat(startCol) * cell.width, y: top, width: CGFloat(span) * cell.width, height: cell.height)
        if bgC != .defaultColor {   // 預設背景不用塗（整片已經是背景色）
            bg.setFill(); rect.fill()
        }
        let trimmed = text.replacingOccurrences(of: "\u{0}", with: " ")
        guard !trimmed.allSatisfy({ $0 == " " }), !c.style.contains(.invisible) else { return }
        var attrs: [NSAttributedString.Key: Any] = [.font: bold ? boldFont : font, .foregroundColor: fg]
        if c.style.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if c.style.contains(.crossedOut) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: trimmed, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // 這個 view 是翻轉的，字要再翻回來
        ctx.textPosition = CGPoint(x: rect.minX, y: top + cell.height - baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

final class SmoothScrollback: NSScrollView {
    let document: ScrollbackDocument
    var onReachBottom: (() -> Void)?
    private var leftover: CGFloat = 0          // 終端機畫面底下沒畫滿一格的空間
    private var lastY: CGFloat = 0

    init(palette: Palette, font: NSFont, boldFont: NSFont) {
        document = ScrollbackDocument(palette: palette, font: font, boldFont: boldFont)
        super.init(frame: .zero)
        documentView = document
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        drawsBackground = true
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 從終端機現在的樣子開始：最後 rows 行剛好對在畫面最上面那幾格，跟終端機的位置一模一樣
    func begin(from terminal: TerminalView, palette: Palette) {
        document.terminal = terminal
        document.palette = palette
        backgroundColor = palette.bg
        document.font = terminal.font
        document.cell = terminal.cellSizePublic
        let ch = document.cell.height
        document.baseline = Self.baselineOffset(font: terminal.font, cellHeight: ch)
        var total = 0, rows = 0, trimmed = 0
        terminal.withTerminalPublic { t in
            rows = t.rows
            trimmed = t.buffer.totalLinesTrimmed
            total = t.buffer.yDisp + t.rows
            document.cursor = (trimmed + t.buffer.yDisp + t.buffer.y, t.buffer.x)
        }
        document.firstAbsolute = trimmed
        leftover = max(0, bounds.height - CGFloat(rows) * ch)
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat(total) * ch + leftover)
        let bottom = CGFloat(max(0, total - rows)) * ch
        contentView.scroll(to: NSPoint(x: 0, y: bottom))
        reflectScrolledClipView(contentView)
        lastY = bottom
        document.needsDisplay = true
    }

    /// 顯示期間終端機又印了東西：文件往下長，目前看的位置不動
    func refresh() {
        guard let terminal = document.terminal else { return }
        var total = 0, trimmed = 0
        terminal.withTerminalPublic { t in
            trimmed = t.buffer.totalLinesTrimmed
            total = t.buffer.yDisp + t.rows
            document.cursor = (trimmed + t.buffer.yDisp + t.buffer.y, t.buffer.x)
        }
        let height = CGFloat(trimmed + total - document.firstAbsolute) * document.cell.height + leftover
        if abs(height - document.frame.height) > 0.5 {
            document.setFrameSize(NSSize(width: bounds.width, height: height))
        }
        document.needsDisplay = true
    }

    var atBottom: Bool {
        let maxY = document.frame.height - contentView.bounds.height
        return contentView.bounds.minY >= maxY - 1
    }

    @objc private func boundsChanged() {
        let y = contentView.bounds.minY
        let movingDown = y > lastY
        lastY = y
        if movingDown && atBottom { onReachBottom?() }
    }

    static func baselineOffset(font: NSFont, cellHeight: CGFloat) -> CGFloat {
        let f = font as CTFont
        let descent = CTFontGetDescent(f), leading = CTFontGetLeading(f)
        let natural = ceil(CTFontGetAscent(f) + descent + leading)
        return ceil(descent + leading) + floor(max(0, cellHeight - natural) / 2)
    }

    // 這層只負責看，不搶鍵盤（打字還是給底下的終端機）
    override var acceptsFirstResponder: Bool { false }
}
