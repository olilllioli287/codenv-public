import AppKit
import UniformTypeIdentifiers

/// 輸入框本體：原生文字框，輸入法（唯音）照系統的走。
/// 按鍵照使用者在 Claude Code 的設定：Enter 換行；⌘ Enter 或 ctrl+x ctrl+s 送出；Esc 停止；⌃ C 停止並把剛送的字放回來。
final class ChatTextView: NSTextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCycleMode: (() -> Void)?
    var onSendNow: (() -> Void)?
    /// ⌃ C：停止 Claude，剛送出的字放回輸入框
    var onInterrupt: (() -> Void)?
    /// / 選單開著的時候先問它要不要這個按鍵（↑ ↓ Tab Enter Esc）
    var onMenuKey: ((NSEvent) -> Bool)?
    /// Claude 猜的下一句：輸入框空的時候用灰字顯示，Tab 採用
    var suggestion: String? { didSet { needsDisplay = true } }
    var onImages: (([URL], [NSImage]) -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderColor = NSColor.placeholderTextColor
    private var afterCtrlX = false

    // macOS 14 起 ⌃ Return 是系統的「顯示右鍵選單」，會在 keyDown 之前被接走：這裡先攔下來當插話
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if window?.firstResponder === self, !hasMarkedText(), (e.keyCode == 36 || e.keyCode == 76), mods == .control {
            onSendNow?(); return true
        }
        return super.performKeyEquivalent(with: e)
    }
    @available(macOS 15.0, *)
    override func showContextMenuForSelection(_ sender: Any?) {
        if let e = NSApp.currentEvent, e.type == .keyDown, e.keyCode == 36 || e.keyCode == 76 { onSendNow?(); return }
        super.showContextMenuForSelection(sender)
    }

    override func keyDown(with e: NSEvent) {
        // 組字中（選字、注音還沒送出）的按鍵一律交給輸入法
        if hasMarkedText() { afterCtrlX = false; return super.keyDown(with: e) }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if onMenuKey?(e) == true { afterCtrlX = false; return }
        // 空的輸入框按 /：直接打出 /（注音模式下這顆是 ㄥ，不用先切英文就能叫出指令選單）
        if e.keyCode == 44, mods.isEmpty, !e.modifierFlags.contains(.shift), string.isEmpty {
            insertText("/", replacementRange: selectedRange()); return
        }
        // delete 碰到 [Image #n] 或檔案路徑：整個標記一次刪掉（上面的卡片也跟著拿掉），不用一個字一個字刪
        if (e.keyCode == 51 || e.keyCode == 117), mods.isEmpty, selectedRange().length == 0,
           let r = imageToken(near: selectedRange().location, forward: e.keyCode == 117) {
            insertText("", replacementRange: r); return
        }
        // 選取範圍只蓋到標記的一部分：擴大到整個標記再刪，不留半截路徑
        if (e.keyCode == 51 || e.keyCode == 117), mods.isEmpty, selectedRange().length > 0 {
            let sel = selectedRange()
            var r = sel
            for t in tokenRanges() where NSIntersectionRange(t, sel).length > 0 { r = NSUnionRange(r, t) }
            if r != sel { insertText("", replacementRange: r); return }
        }
        // ← → 碰到 [Image #n] 或檔案路徑：整段跳過，不用一格一格移
        if (e.keyCode == 123 || e.keyCode == 124), mods.isEmpty, selectedRange().length == 0,
           let r = imageTokenSpan(at: selectedRange().location, right: e.keyCode == 124) {
            setSelectedRange(NSRange(location: e.keyCode == 124 ? r.upperBound : r.location, length: 0))
            scrollRangeToVisible(selectedRange()); return
        }
        if afterCtrlX {
            afterCtrlX = false
            if mods == .control && ch == "s" { onSend?(); return }
        }
        if mods == .control && ch == "x" { afterCtrlX = true; return }
        // 用 keyCode（c 鍵）判斷：注音模式下 charactersIgnoringModifiers 不一定是 c
        if mods == .control && e.keyCode == 8 { onInterrupt?(); return }
        if (e.keyCode == 36 || e.keyCode == 76) && mods == .command { onSend?(); return }
        if (e.keyCode == 36 || e.keyCode == 76) && mods == .control { onSendNow?(); return }
        // Tab：採用灰字的建議（變成真的文字，可以再改）
        if e.keyCode == 48 && mods.isEmpty, string.isEmpty, let s = suggestion, !s.isEmpty {
            insertText(s, replacementRange: selectedRange()); return
        }
        // 設定頁選了「Enter 送出」：Enter 送出、Shift+Enter 換行
        if Prefs.shared.sendWithEnter && (e.keyCode == 36 || e.keyCode == 76) {
            if mods.isEmpty { onSend?(); return }
            if mods == .shift { insertNewlineIgnoringFieldEditor(nil); return }
        }
        // ⌘ ↑／⌘ ↓ 在輸入框裡只移游標到最前／最後（系統預設）；跳對話最上面／最下面是游標不在輸入框時（chat.js）
        if e.keyCode == 53 && mods.isEmpty { onEscape?(); return }
        // ⇧ Tab：換權限模式（跟 Claude Code 一樣）
        if e.keyCode == 48 && mods == .shift { onCycleMode?(); return }
        super.keyDown(with: e)
    }

    /// 輸入框上面有卡片的檔案路徑（跳脫過的樣子，跟文字裡的一樣）：跟 [Image #n] 一樣整塊刪、整塊跳
    var fileTokens: [String] = []

    /// 文字裡所有整塊的標記：[Image #n] 和有卡片的檔案路徑
    func tokenRanges() -> [NSRange] {
        let s = string as NSString
        var out: [NSRange] = []
        if let re = try? NSRegularExpression(pattern: #"\[Image #\d+\]"#) {
            out += re.matches(in: string, range: NSRange(location: 0, length: s.length)).map(\.range)
        }
        for t in fileTokens where !t.isEmpty {
            var from = 0
            while from < s.length {
                let r = s.range(of: t, range: NSRange(location: from, length: s.length - from))
                if r.location == NSNotFound { break }
                // 前後要是空白、換行或頭尾，才算這個路徑本身（不是更長路徑的一段）
                let okL = r.location == 0 || [0x20, 0x0a].contains(s.character(at: r.location - 1))
                let okR = r.upperBound == s.length || [0x20, 0x0a].contains(s.character(at: r.upperBound))
                if okL && okR { out.append(r) }
                from = r.upperBound
            }
        }
        return out.sorted { $0.location < $1.location }
    }

    /// 游標旁邊的標記（往前刪：游標在標記後面、裡面或後面那個空白之後；往後刪：游標在標記前面或裡面）
    private func imageToken(near loc: Int, forward: Bool) -> NSRange? {
        let s = string as NSString
        for m in tokenRanges() {
            var r = m
            let space = r.upperBound < s.length && s.character(at: r.upperBound) == 0x20
            if forward {
                if loc >= r.location && loc < r.upperBound { if space { r.length += 1 }; return r }
            } else {
                if loc > r.location && loc <= r.upperBound { if space { r.length += 1 }; return r }
                if space && loc == r.upperBound + 1 { r.length += 1; return r }
            }
        }
        return nil
    }

    /// 往右移：游標在標記開頭或裡面；往左移：游標在標記結尾或裡面
    private func imageTokenSpan(at loc: Int, right: Bool) -> NSRange? {
        for r in tokenRanges() {
            if right ? (loc >= r.location && loc < r.upperBound) : (loc > r.location && loc <= r.upperBound) { return r }
        }
        return nil
    }

    // 貼上：剪貼簿裡是圖片（截圖、圖片檔）就變成附件；Finder 拷貝的檔案 → 變成檔案卡片；文字照原樣貼（路徑文字不變卡片，使用者 10/25）
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if takeImages(from: pb) { return }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty,
           let f = onDropPasteboard, f(pb) { return }
        super.paste(sender)
    }

    // 拖進來：圖片變附件，其他檔案插入路徑（NSTextView 自己的拖放規則會擋掉圖片，所以明確說要）
    var onDropPasteboard: ((NSPasteboard) -> Bool)?
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static func isFileDrag(_ pb: NSPasteboard) -> Bool {
        if DropOverlay.conversation(in: pb) != nil { return false }   // 側欄拖來的對話不是檔案
        return pb.availableType(from: [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]) != nil
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }
    private func isFileDrag(_ pb: NSPasteboard) -> Bool { Self.isFileDrag(pb) }

    /// 拖放紀錄（~/Library/Application Support/AI 工作台/drop.log，只留最後 200 行）：拖不進去時看東西掉在哪裡
    static func dropLog(_ what: String, _ pb: NSPasteboard?) {
        guard appDefaults === UserDefaults.standard else { return }   // 測試 App 不寫
        let f = Edition.support("drop.log")
        let types = pb.map { " types=" + ($0.types ?? []).map(\.rawValue).prefix(6).joined(separator: ",") } ?? ""
        let line = "\(Date()) \(what)\(types)\n"
        let old = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        try? (old.split(separator: "\n").suffix(199).joined(separator: "\n") + "\n" + line).write(to: f, atomically: true, encoding: .utf8)
    }
    // NSTextView 換可不可以編輯（輸入框鎖住／解鎖）時會照這份清單重新登記能收的拖放類型，
    // 只靠 registerForDraggedTypes 的話解鎖之後就收不到圖片了
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        Array(Set(super.acceptableDragTypes + Self.dropTypes))
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { isFileDrag(s.draggingPasteboard) ? .copy : super.draggingEntered(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { isFileDrag(s.draggingPasteboard) ? .copy : super.draggingUpdated(s) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { isFileDrag(s.draggingPasteboard) ? true : super.prepareForDragOperation(s) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        Self.dropLog("輸入框文字區 收=\(isFileDrag(pb))", pb)
        if isFileDrag(pb), let f = onDropPasteboard { return f(pb) }
        return super.performDragOperation(sender)
    }

    private func takeImages(from pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let imgs = urls.filter(Self.isImage)
            if !imgs.isEmpty && imgs.count == urls.count { onImages?(imgs, []); return true }
            if !urls.isEmpty { return false }
        }
        // 只有圖片資料（截圖到剪貼簿、從瀏覽器拷貝圖片）
        if pb.availableType(from: [.png, .tiff]) != nil, let img = NSImage(pasteboard: pb) {
            onImages?([], [img]); return true
        }
        return false
    }

    static func isImage(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !hasMarkedText() {
            let f = font ?? .systemFont(ofSize: 14)
            let at = NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height)
            if let s = suggestion, !s.isEmpty {
                let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
                // 「Tab」放最左邊，後面接建議的句子（使用者 10/23 要的）
                let line = NSMutableAttributedString(string: "Tab  ", attributes: [.font: NSFont.systemFont(ofSize: f.pointSize * 0.75), .foregroundColor: placeholderColor.withAlphaComponent(placeholderColor.alphaComponent * 0.6), .paragraphStyle: para, .baselineOffset: f.pointSize * 0.1])
                line.append(NSAttributedString(string: s.replacingOccurrences(of: "\n", with: " "), attributes: [.font: f, .foregroundColor: placeholderColor, .paragraphStyle: para]))
                line.draw(with: NSRect(x: at.x, y: at.y, width: max(0, bounds.width - at.x * 2), height: f.boundingRectForFont.height + 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            } else {
                (placeholder as NSString).draw(at: at, withAttributes: [.font: f, .foregroundColor: placeholderColor])
            }
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
}

/// 送出前的圖片縮圖（輸入框上面那排），左下角標 #編號 對應文字裡的 [Image #編號]，點 × 拿掉
private final class AttachmentChip: NSView {
    var onRemove: (() -> Void)?
    var onEdit: (() -> Void)?
    static let height: CGFloat = 110
    /// 不管圖片多長多寬，框一律 4:3；圖片照原比例縮進框裡（不裁切）
    static func width(for image: NSImage) -> CGFloat { (height * 4 / 3).rounded() }
    init(image: NSImage, number: Int, edited: Bool = false) {
        let w = Self.width(for: image)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        let iv = NSImageView(frame: bounds)
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        addSubview(iv)
        let x = NSButton(title: "", image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "拿掉")!, target: self, action: #selector(remove))
        x.isBordered = false
        x.contentTintColor = .white
        x.frame = NSRect(x: w - 22, y: Self.height - 22, width: 18, height: 18)
        addSubview(x)
        let tag = NSTextField(labelWithString: edited ? "#\(number) 已編輯" : "#\(number)")
        tag.font = .systemFont(ofSize: 12, weight: .bold)
        tag.textColor = .white
        tag.wantsLayer = true
        tag.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        tag.layer?.cornerRadius = 4
        tag.alignment = .center
        tag.frame = NSRect(x: 4, y: 4, width: tag.intrinsicContentSize.width + 8, height: 18)
        addSubview(tag)
        // 編輯過：橘框（跟 image-shelf 一樣）
        layer?.borderWidth = edited ? 2 : 1
        layer?.borderColor = (edited ? NSColor.systemOrange : NSColor.white.withAlphaComponent(0.25)).cgColor
        toolTip = "點一下編輯（畫框、箭頭、文字）"
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func remove() { onRemove?() }
    // × 以外的地方都算點在縮圖上（不要被裡面的圖片元件吃掉）
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v is NSButton ? v : (v == nil ? nil : self)
    }
    override func mouseDown(with e: NSEvent) { onEdit?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 送出前的檔案卡片（跟圖片縮圖同大小、排在同一排）：中間是摺角紙張寫副檔名，下面是小圖示＋不含副檔名的檔名；
/// 完整路徑滑鼠停上去才看得到，點一下在 Finder 選起來，點 × 連文字裡的路徑一起拿掉
private final class FileChip: NSView {
    var onRemove: (() -> Void)?
    let url: URL
    private let fg: NSColor
    /// 資料夾外框的顏色：跟選中格子的紫框同一色
    private let accent: NSColor
    private let isDir: Bool
    init(url: URL, fg: NSColor, accent: NSColor) {
        self.url = url
        self.fg = fg
        self.accent = accent
        var d: ObjCBool = false
        isDir = FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path)
        super.init(frame: NSRect(x: 0, y: 0, width: AttachmentChip.width(for: NSImage()), height: AttachmentChip.height))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = fg.withAlphaComponent(0.22).cgColor
        layer?.backgroundColor = fg.withAlphaComponent(0.06).cgColor
        let x = NSButton(title: "", image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "拿掉")!, target: self, action: #selector(remove))
        x.isBordered = false
        x.contentTintColor = fg.withAlphaComponent(0.7)
        x.frame = NSRect(x: bounds.width - 22, y: bounds.height - 22, width: 18, height: 18)
        addSubview(x)
        toolTip = url.path + "\n點一下在 Finder 顯示"
    }
    required init?(coder: NSCoder) { fatalError() }
    /// 副檔名（.pdf）；資料夾、沒有副檔名的回空字串
    private var ext: String { isDir || url.pathExtension.isEmpty ? "" : "." + url.pathExtension.lowercased() }
    private var baseName: String {
        let n = url.lastPathComponent
        return ext.isEmpty ? n : (n as NSString).deletingPathExtension
    }

    /// 摺角紙張（右上角摺起來）：讓人一看就知道是檔案
    private func drawPage(in r: NSRect, label: String, fontSize: CGFloat, line: CGFloat) {
        let fold = min(r.width, r.height) * 0.28
        let body = NSBezierPath()
        body.move(to: NSPoint(x: r.minX, y: r.minY))
        body.line(to: NSPoint(x: r.maxX, y: r.minY))
        body.line(to: NSPoint(x: r.maxX, y: r.maxY - fold))
        body.line(to: NSPoint(x: r.maxX - fold, y: r.maxY))
        body.line(to: NSPoint(x: r.minX, y: r.maxY))
        body.close()
        fg.withAlphaComponent(0.10).setFill(); body.fill()
        fg.withAlphaComponent(0.55).setStroke(); body.lineWidth = line; body.lineJoinStyle = .round; body.stroke()
        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: r.maxX - fold, y: r.maxY))
        corner.line(to: NSPoint(x: r.maxX - fold, y: r.maxY - fold))
        corner.line(to: NSPoint(x: r.maxX, y: r.maxY - fold))
        fg.withAlphaComponent(0.25).setFill(); corner.fill()
        corner.lineWidth = line; corner.lineJoinStyle = .round; corner.stroke()
        guard !label.isEmpty else { return }
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: fg.withAlphaComponent(0.85), .paragraphStyle: para]
        let h = NSFont.systemFont(ofSize: fontSize, weight: .bold).boundingRectForFont.height
        (label as NSString).draw(with: NSRect(x: r.minX + 2, y: r.minY + (r.height - fold - h) / 2, width: r.width - 4, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
    }

    /// Finder 樣式的資料夾外形（左上一個分頁＋前面一片面板，圓角），只畫框不填色（使用者 10/25）
    private func drawFolder(in r: NSRect, line: CGFloat) {
        let rad = min(r.width, r.height) * 0.12
        let tabH = r.height * 0.16
        let bodyTop = r.maxY - tabH
        let tabEnd = r.minX + r.width * 0.4
        let back = NSBezierPath()
        back.move(to: NSPoint(x: r.minX + rad, y: r.minY))
        back.appendArc(from: NSPoint(x: r.maxX, y: r.minY), to: NSPoint(x: r.maxX, y: bodyTop), radius: rad)
        back.appendArc(from: NSPoint(x: r.maxX, y: bodyTop), to: NSPoint(x: tabEnd, y: bodyTop), radius: rad)
        back.line(to: NSPoint(x: tabEnd + tabH * 0.9, y: bodyTop))
        back.line(to: NSPoint(x: tabEnd, y: r.maxY))
        back.appendArc(from: NSPoint(x: r.minX, y: r.maxY), to: NSPoint(x: r.minX, y: r.minY), radius: rad * 0.8)
        back.appendArc(from: NSPoint(x: r.minX, y: r.minY), to: NSPoint(x: r.maxX, y: r.minY), radius: rad)
        back.close()
        back.lineWidth = line; back.lineJoinStyle = .round
        accent.setStroke(); back.stroke()
        // 前面板的上緣：分頁下面一條橫線，兩端接到外框
        let front = NSBezierPath()
        let fy = bodyTop - tabH * 0.7
        front.move(to: NSPoint(x: r.minX, y: fy))
        front.line(to: NSPoint(x: r.maxX, y: fy))
        front.lineWidth = line; front.lineCapStyle = .round
        front.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bottom: CGFloat = 26
        // 中間的大圖示
        let area = NSRect(x: 0, y: bottom, width: bounds.width, height: bounds.height - bottom)
        if isDir {
            let w: CGFloat = 62, h: CGFloat = 48
            drawFolder(in: NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h), line: 1.5)
        } else {
            let w: CGFloat = 46, h: CGFloat = 58
            drawPage(in: NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h), label: ext, fontSize: ext.count > 5 ? 9 : 11, line: 1.5)
        }
        // 下面一行：左邊小圖示、右邊檔名（不含副檔名）
        let icon = NSRect(x: 8, y: 7, width: 11, height: 14)
        if isDir {
            drawFolder(in: NSRect(x: 6, y: 8, width: 15, height: 12), line: 1)
        } else {
            drawPage(in: icon, label: "", fontSize: 0, line: 1)
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
        let f = NSFont.systemFont(ofSize: 12, weight: .medium)
        (baseName as NSString).draw(with: NSRect(x: 25, y: 5, width: bounds.width - 31, height: f.boundingRectForFont.height),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: f, .foregroundColor: fg.withAlphaComponent(0.9), .paragraphStyle: para])
    }
    @objc private func remove() { onRemove?() }
    override func hitTest(_ p: NSPoint) -> NSView? {
        let v = super.hitTest(p)
        return v is NSButton ? v : (v == nil ? nil : self)
    }
    override func mouseDown(with e: NSEvent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 下面那條輸入列：附件縮圖＋文字框＋送出／停止按鈕
final class ChatInputBar: NSView {
    let textView = ChatTextView()
    /// 打到一半還沒送的字或圖（關掉格子時有這些就不要收掉 Claude，免得字不見）
    var hasPendingInput: Bool { !textView.string.isEmpty || !attachments.isEmpty }
    private let scroll = NSScrollView()
    private let box = NSView()
    private let chips = NSStackView()
    /// 卡片多到放不下時左右捲（不要擠扁最後幾張）
    private let chipScroll = NSScrollView()
    /// 卡片那排和打字區中間的分隔線（兩端內縮，不碰外框）
    private let chipDivider = NSView()
    /// 有卡片的檔案（拖進來或貼上的路徑）；文字裡的路徑被刪掉，卡片也跟著拿掉
    private var files: [URL] = []
    private var chipFG: NSColor = .labelColor
    private var chipAccent: NSColor = .controlAccentColor
    private let sendButton = NSButton()
    /// 右下角的模型選單（按下去由 ChatPane 給選單內容）
    let modelButton = NSButton()
    var onModelButton: ((NSView) -> Void)?
    /// 模型按鈕左邊的權限模式（按一下或 ⇧ Tab 換下一個）
    let modeButton = NSButton()
    var onCycleMode: (() -> Void)?
    /// no：這則訊息裡的第幾張圖，文字裡用 [Image #no] 標出位置（跟 Claude Code 一樣）
    private var attachments: [(data: Data, mediaType: String, image: NSImage, no: Int, edited: Bool)] = []
    private var nextImageNo = 1
    static func imageToken(_ n: Int) -> String { "[Image #\(n)]" }
    var onSend: ((String, [(data: Data, mediaType: String)], Bool) -> Void)?   // 最後一個：⌃ Enter 馬上插話
    /// 輸入框是空的按 ⌃ Enter：排隊中的訊息全部馬上插話
    var onSendQueuedNow: (() -> Void)?
    var onStop: (() -> Void)?
    var onBlur: (() -> Void)?
    /// 打 / 開頭時跳出的指令清單（放在上一層，蓋在對話內容上面）
    let slash = SlashMenu()
    var commands: [SlashCommand] = SlashCommand.known { didSet { updateSlash() } }
    private var slashDismissedFor: String?
    var busy = false {
        didSet {
            if busy { suggestion = nil }
            if oldValue && !busy { lastSent = nil }   // 這輪做完了，⌃ C 就不再放回
            updateButton(); needsLayout = true
        }
    }
    /// 上一則送出的字和圖：這輪還沒做完時按 ⌃ C，停下來並放回輸入框，不用重打
    private var lastSent: (text: String, attachments: [(data: Data, mediaType: String, image: NSImage, no: Int, edited: Bool)], nextNo: Int, files: [URL])?
    var suggestion: String? { get { textView.suggestion } set { textView.suggestion = newValue } }
    /// 鎖住輸入（對話正在別處進行）：顯示說明和一顆按鈕
    private let lockView = NSView()
    private let lockLabel = NSTextField(wrappingLabelWithString: "")
    private let lockButton = NSButton()
    private var lockAction: (() -> Void)?
    var isLocked: Bool { !lockView.isHidden }
    private let maxLines: CGFloat = 12

    init() {
        super.init(frame: .zero)
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.borderWidth = 1
        addSubview(box)
        chips.orientation = .horizontal
        chips.spacing = 8
        chips.isHidden = true
        // 縮圖和檔案卡片放在輸入框裡面最上面一排（使用者 10/25：原本浮在對話內容上，看不出邊界）
        chipScroll.documentView = chips
        chipScroll.drawsBackground = false
        chipScroll.borderType = .noBorder
        chipScroll.hasHorizontalScroller = true
        chipScroll.hasVerticalScroller = false
        chipScroll.autohidesScrollers = true
        chipScroll.scrollerStyle = .overlay
        chipScroll.isHidden = true
        box.addSubview(chipScroll)
        chipDivider.wantsLayer = true
        chipDivider.isHidden = true
        box.addSubview(chipDivider)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = "輸入 / 開啟指令選單"
        textView.registerForDraggedTypes(ChatTextView.dropTypes)
        // 整個輸入框都能收（框裡的空白、按鈕旁邊、鎖住時也一樣），不是只有文字那一條
        registerForDraggedTypes(ChatTextView.dropTypes)
        textView.onDropPasteboard = { [weak self] pb in self?.takeDrop(pb) ?? false }
        textView.onSend = { [weak self] in self?.send() }
        textView.onSendNow = { [weak self] in self?.send(now: true) }
        textView.onMenuKey = { [weak self] e in self?.slashKey(e) ?? false }
        slash.isHidden = true
        slash.onPick = { [weak self] c in self?.pickSlash(c) }
        // Esc：Claude 在做就停止；沒在做就離開輸入框（之後按 / 再回來）
        textView.onEscape = { [weak self] in if self?.busy == true { self?.onStop?() } else { self?.onBlur?() } }
        textView.onInterrupt = { [weak self] in self?.interruptAndRestore() }
        textView.onCycleMode = { [weak self] in self?.onCycleMode?() }
        textView.onImages = { [weak self] urls, images in self?.attach(urls: urls, images: images) }
        scroll.documentView = textView
        scroll.hasVerticalScroller = false   // 字超過最多行數時 layout() 才打開
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        box.addSubview(scroll)

        sendButton.isBordered = false
        sendButton.target = self
        sendButton.action = #selector(buttonPressed)
        sendButton.imageScaling = .scaleProportionallyUpOrDown
        box.addSubview(sendButton)
        modelButton.isBordered = false
        modelButton.font = .systemFont(ofSize: 12, weight: .medium)
        modelButton.target = self
        modelButton.action = #selector(showModels)
        modelButton.toolTip = "換模型"
        box.addSubview(modelButton)
        modeButton.isBordered = false
        modeButton.target = self
        modeButton.action = #selector(cycleModePressed)
        modeButton.toolTip = "權限模式（⇧ Tab 切換）：每次都問 → 改檔不問 → 只規劃 → 自動"
        box.addSubview(modeButton)
        lockView.wantsLayer = true
        lockView.isHidden = true
        lockLabel.font = .systemFont(ofSize: 13)
        lockLabel.textColor = .secondaryLabelColor
        lockView.addSubview(lockLabel)
        lockButton.bezelStyle = .rounded
        lockButton.target = self
        lockButton.action = #selector(lockPressed)
        lockView.addSubview(lockButton)
        box.addSubview(lockView)
        updateButton()
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ pal: Palette, mono: NSFont) {
        let dark = pal.bg.usingColorSpace(.sRGB).map { $0.brightnessComponent < 0.5 } ?? true
        box.layer?.backgroundColor = (dark ? pal.bg.blended(withFraction: 0.07, of: .white) : pal.bg.blended(withFraction: 0.04, of: .black))?.cgColor
        box.layer?.borderColor = pal.fg.withAlphaComponent(0.15).cgColor
        chipDivider.layer?.backgroundColor = pal.fg.withAlphaComponent(0.15).cgColor
        let acc = pal.ansi.count > 12 ? pal.ansi[12] : .controlAccentColor   // 跟 WindowHost 選中格子的紫框同一色
        if chipFG != pal.fg || chipAccent != acc { chipFG = pal.fg; chipAccent = acc; rebuildChips() }
        slash.fg = pal.fg
        slash.bg = (dark ? pal.bg.blended(withFraction: 0.1, of: .white) : pal.bg.blended(withFraction: 0.06, of: .black)) ?? pal.bg
        slash.font = NSFontManager.shared.convert(mono, toHaveTrait: .boldFontMask).withSize(14)
        slash.needsDisplay = true
        textView.textColor = pal.fg
        textView.insertionPointColor = pal.cursor
        textView.placeholderColor = pal.fg.withAlphaComponent(0.4)
        sendButton.contentTintColor = pal.fg
        modelButton.contentTintColor = pal.fg.withAlphaComponent(0.6)
        modelTitle = modelTitleText
        permissionMode = permissionModeValue
    }

    private var permissionModeValue = "default"
    /// 目前的權限模式；換了就重畫按鈕（顏色照 Claude Code：改檔不問紫、只規劃青、自動橘）
    var permissionMode: String {
        get { permissionModeValue }
        set {
            permissionModeValue = newValue
            let color: NSColor
            switch newValue {
            case "acceptEdits": color = .systemPurple
            case "plan": color = .systemTeal
            case "auto": color = .systemOrange
            case "bypassPermissions": color = .systemRed
            default: color = modelButton.contentTintColor ?? .secondaryLabelColor
            }
            modeButton.attributedTitle = NSAttributedString(string: PermissionMode.label(newValue), attributes: [.font: NSFont.systemFont(ofSize: 12 * UIScale.shared.f, weight: .medium), .foregroundColor: color])
            needsLayout = true
        }
    }
    @objc private func cycleModePressed() { onCycleMode?() }

    private var modelTitleText = ""
    /// 模型按鈕上的字，例如「Opus 5.5」
    var modelTitle: String {
        get { modelTitleText }
        set {
            modelTitleText = newValue
            let color = modelButton.contentTintColor ?? .secondaryLabelColor
            let size = 12 * UIScale.shared.f
            let font = NSFont.systemFont(ofSize: size, weight: .medium)
            let title = NSMutableAttributedString(string: newValue + " ", attributes: [.font: font, .foregroundColor: color])
            // 「⌄」這個字畫在下半格，整組看起來會往下沉：改用 chevron.down 圖示，垂直置中在大寫字母的高度上（不撐高行高）
            if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.6, weight: .semibold).applying(.init(paletteColors: [color]))) {
                let a = NSTextAttachment(); a.image = img
                a.bounds = NSRect(x: 0, y: ((font.capHeight - img.size.height) / 2).rounded(), width: img.size.width, height: img.size.height)
                title.append(NSAttributedString(attachment: a))
            }
            modelButton.attributedTitle = title
            needsLayout = true
        }
    }

    @objc private func showModels() { onModelButton?(modelButton) }

    /// 整體文字大小
    /// 打字的字型：nil＝系統字型；有給就用它（跟終端機一樣），大小照終端機點數換算
    var textFont: NSFont? { didSet { if textFont != oldValue { setFontScale(lastScale) } } }
    private var lastScale: CGFloat = 1
    func setFontScale(_ f: CGFloat) {
        lastScale = f
        if let base = textFont {
            textView.font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize / CGFloat(UIScale.defaultFactor) * f) ?? .systemFont(ofSize: 15 * f)
        } else {
            textView.font = .systemFont(ofSize: 15 * f)
        }
        modelButton.font = .systemFont(ofSize: 12 * f, weight: .medium)
        modelTitle = modelTitleText
        permissionMode = permissionModeValue
        textChanged()
    }
    /// 輸入框（圓角那塊）在視窗裡的位置：浮動面板對齊它的右緣
    var boxRectInWindow: NSRect { box.convert(box.bounds, to: nil) }

    private var textHeight: CGFloat { measureText().height }
    /// 內容高度（最多 maxLines 行）＋是不是超過了（超過才需要捲軸）
    private func measureText() -> (height: CGFloat, overflow: Bool) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return (24, false) }
        lm.ensureLayout(for: tc)
        let line = lm.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 15))
        let h = max(line, lm.usedRect(for: tc).height) + textView.textContainerInset.height * 2
        let cap = line * maxLines + textView.textContainerInset.height * 2
        return (min(h, cap), h > cap + 1)
    }
    /// 測試用：輸入框的捲軸現在有沒有、是哪種樣式
    var scrollerState: String { "scroller=\(scroll.hasVerticalScroller) style=\(scroll.scrollerStyle == .overlay ? "overlay" : "legacy")" }

    /// 下面那排狀態列（權限模式、模型、送出鍵）的高度：打字在上面，字不會碰到這一排（使用者 10/25）
    private static let statusRow: CGFloat = 28

    /// 卡片那排佔的高度（上緣 8、卡片、分隔線上下各留一點）
    private static let chipRow: CGFloat = AttachmentChip.height + 24

    func fittingHeight(width: CGFloat) -> CGFloat {
        (chips.isHidden ? 0 : Self.chipRow) + textHeight + Self.statusRow + 4 + 16 + 16
    }

    override func layout() {
        super.layout()
        placeSlash()
        let margin: CGFloat = 16
        box.frame = NSRect(x: margin, y: 12, width: max(0, bounds.width - margin * 2), height: max(0, bounds.height - 16))
        chipDivider.isHidden = chips.isHidden
        chipScroll.isHidden = chips.isHidden
        if !chips.isHidden {
            chipScroll.frame = NSRect(x: 10, y: box.bounds.height - 8 - AttachmentChip.height, width: max(0, box.bounds.width - 20), height: AttachmentChip.height)
            chips.frame = NSRect(x: 0, y: 0, width: max(chips.fittingSize.width, chipScroll.contentSize.width), height: AttachmentChip.height)
            chipDivider.frame = NSRect(x: 14, y: chipScroll.frame.minY - 7, width: max(0, box.bounds.width - 28), height: 1)
        }
        let inner = box.bounds.insetBy(dx: 10, dy: 8)
        let (th, overflow) = measureText()
        // 捲軸：字超過最多行數才有，而且一律用浮出來的樣式。
        // 系統設成「一直顯示捲軸」（接滑鼠時）的話，行高差幾點就會在空的輸入框右邊畫出一條有外框的捲軸
        if scroll.hasVerticalScroller != overflow { scroll.hasVerticalScroller = overflow }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        // 兩行：最下面一排是狀態列（右邊依序 權限模式、模型、送出鍵），上面整條寬度都給打字
        let row = inner.minY
        sendButton.frame = NSRect(x: inner.maxX - 28, y: row, width: 28, height: 28)
        // 空的輸入框只提示 / 指令選單（使用者 10/23：不要按鍵說明；Claude 在忙時也一樣）
        let want = "輸入 / 開啟指令選單"
        if textView.placeholder != want { textView.placeholder = want }
        // 太窄（例如右下角讓給桌寵之後）：先收模式按鈕、再收模型按鈕（⇧ Tab 照樣能換）
        if lockView.isHidden {
            modelButton.isHidden = inner.width < 160
            modeButton.isHidden = inner.width < 240
        }
        let mw = modelButton.isHidden ? 0 : min(max(0, inner.width - 40), min(240, modelButton.intrinsicContentSize.width + 8))
        modelButton.frame = NSRect(x: inner.maxX - 34 - mw, y: row + 4, width: mw, height: 20)
        let dw = modeButton.isHidden ? 0 : min(130, modeButton.intrinsicContentSize.width + 8)
        modeButton.frame = NSRect(x: modelButton.frame.minX - dw - (mw > 0 ? 2 : 0), y: row + 4, width: dw, height: 20)
        var y = row + Self.statusRow + 4
        scroll.frame = NSRect(x: inner.minX, y: y, width: inner.width, height: th)
        y += th
        textView.frame.size.width = scroll.contentSize.width
        lockView.frame = box.bounds
        let bw = lockButton.isHidden ? 0 : lockButton.intrinsicContentSize.width + 8
        lockButton.frame = NSRect(x: box.bounds.maxX - bw - 10, y: (box.bounds.height - 28) / 2, width: bw, height: 28)
        lockLabel.frame = NSRect(x: 14, y: 6, width: box.bounds.width - bw - 34, height: box.bounds.height - 12)
    }

    @objc private func textChanged() {
        // 文字裡的 [Image #n] 或檔案路徑被刪掉：那張圖、那張卡片也拿掉（跟 Claude Code 一樣）
        if !attachments.isEmpty || !files.isEmpty, !textView.hasMarkedText() {
            let s = textView.string
            let kept = attachments.filter { s.contains(Self.imageToken($0.no)) }
            let present = Set(textView.tokenRanges().map { (s as NSString).substring(with: $0) })
            let keptFiles = files.filter { present.contains(TerminalPane.shellEscape($0.path)) }
            if kept.count != attachments.count || keptFiles.count != files.count {
                attachments = kept; files = keptFiles; rebuildChips()
            }
        }
        updateSlash()
        superview?.needsLayout = true
        needsLayout = true
        updateButton()
    }

    private func updateButton() {
        let name = busy ? "stop.circle.fill" : "arrow.up.circle.fill"
        sendButton.image = NSImage(systemSymbolName: name, accessibilityDescription: busy ? "停止" : "送出")?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        sendButton.toolTip = busy ? "停止（Esc）" : "送出（⌘ Enter）"
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        sendButton.alphaValue = busy || !empty ? 1 : 0.35
    }

    private func canDrop(_ s: NSDraggingInfo) -> Bool { textView.isEditable && ChatTextView.isFileDrag(s.draggingPasteboard) }   // 鎖住時不收
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { canDrop(s) ? .copy : [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { canDrop(s) ? .copy : [] }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { canDrop(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        ChatTextView.dropLog("輸入框外框", s.draggingPasteboard)
        return takeDrop(s.draggingPasteboard)
    }

    func setLocked(_ text: String?, button: String = "", action: (() -> Void)? = nil) {
        lockView.isHidden = text == nil
        lockLabel.stringValue = text ?? ""
        lockButton.title = button
        lockButton.isHidden = button.isEmpty
        lockAction = action
        textView.isEditable = text == nil
        scroll.isHidden = text != nil
        sendButton.isHidden = text != nil
        modelButton.isHidden = text != nil
        modeButton.isHidden = text != nil
        needsLayout = true
    }
    @objc private func lockPressed() { lockAction?() }

    @objc private func buttonPressed() { busy ? onStop?() : send() }

    /// ⌃ C：Claude 在做（或剛送出、還沒開始）就停下來；輸入框是空的話，把剛送出的字和圖放回來
    func interruptAndRestore() {
        guard busy || lastSent != nil else { return }
        onStop?()
        restoreLastSent()
    }

    /// 剛送出的字放回輸入框（⌃ C；Gemini 連不上 Google 沒送出時也用）
    func restoreLastSent() {
        guard let last = lastSent else { return }
        lastSent = nil
        guard textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else { return }
        textView.string = last.text
        textView.undoManager?.removeAllActions()   // 直接換掉整段字不會進復原紀錄，舊紀錄套上來會錯位
        attachments = last.attachments
        nextImageNo = last.nextNo
        files = last.files
        rebuildChips()
        textChanged()
        textView.setSelectedRange(NSRange(location: (last.text as NSString).length, length: 0))
        window?.makeFirstResponder(textView)
    }

    /// 焦點不在輸入框時按 ⌃ Enter（MainWindow 轉過來）：輸入框有字就馬上插話送出，空的就讓排隊的馬上插話
    func sendNowFromOutside() { send(now: true) }

    private func send(now: Bool = false) {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else {
            if now { onSendQueuedNow?() }
            return
        }
        suggestion = nil
        // Claude 在做時送的是排隊的那則，停下來之後它還是會送出去，所以不放回
        if busy { lastSent = nil } else { lastSent = (text: text, attachments: attachments, nextNo: nextImageNo, files: files) }
        onSend?(text, attachments.map { ($0.data, $0.mediaType) }, now)
        textView.string = ""
        textView.undoManager?.removeAllActions()
        attachments.removeAll()
        files.removeAll()
        nextImageNo = 1
        rebuildChips()
        textChanged()
    }

    /// 拖進來的東西（從輸入框或上面的對話內容）：圖片變附件、其他檔案插入路徑、承諾式檔案（照片 App 之類）等寫好再處理
    /// 從別的 App 拖東西進來成功之後（ShotLine 的截圖、Finder 的檔案）
    var onDropped: (() -> Void)?

    func takeDrop(_ pb: NSPasteboard) -> Bool {
        let ok = acceptDrop(pb)
        if ok { onDropped?() }
        return ok
    }

    private func acceptDrop(_ pb: NSPasteboard) -> Bool {
        if ProcessInfo.processInfo.environment["AI_WORKBENCH_DEBUG"] != nil { NSLog("takeDrop types=\(pb.types ?? []) urls=\(String(describing: pb.readObjects(forClasses: [NSURL.self], options: nil)))") }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let imgs = urls.filter(ChatTextView.isImage)
            let others = urls.filter { !ChatTextView.isImage($0) }
            if !imgs.isEmpty { attach(urls: imgs, images: []) }
            if !others.isEmpty { insertPaths(others) }
            window?.makeFirstResponder(textView)
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dest = TerminalPane.dropFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for p in promises {
                p.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: .main) { [weak self] url, err in
                    guard err == nil, let self else { return }
                    if ChatTextView.isImage(url) { self.attach(urls: [url], images: []) } else { self.insertPaths([url]) }
                }
            }
            return true
        }
        if pb.availableType(from: [.png, .tiff]) != nil, let img = NSImage(pasteboard: pb) {
            attach(urls: [], images: [img])
            return true
        }
        return false
    }

    /// 插入檔案路徑：每個路徑上面多一張卡片，文字裡前後各留一個英文空格（前面已經是空格、換行或最前面就不再補）
    func insertPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for u in urls where !files.contains(u) { files.append(u) }
        rebuildChips()   // 先登記成整塊標記，插進去的字才認得
        let r = textView.selectedRange()
        let s = textView.string as NSString
        let before = r.location > 0 ? s.character(at: r.location - 1) : 0
        let after = r.upperBound < s.length ? s.character(at: r.upperBound) : 0
        let lead = before == 0 || before == 0x20 || before == 0x0a ? "" : " "   // 最前面、換行後面不補
        let trail = after == 0x20 ? "" : " "
        textView.insertText(lead + urls.map { TerminalPane.shellEscape($0.path) }.joined(separator: " ") + trail, replacementRange: r)
        if trail.isEmpty { textView.setSelectedRange(NSRange(location: textView.selectedRange().location + 1, length: 0)) }
    }

    func attach(urls: [URL], images: [NSImage]) {
        if ProcessInfo.processInfo.environment["AI_WORKBENCH_DEBUG"] != nil { FileHandle.standardError.write(Data("attach \(urls.map(\.lastPathComponent)) loaded=\(urls.map { NSImage(contentsOf: $0) != nil }) chipsHidden=\(chips.isHidden) count=\(attachments.count) frame=\(frame)\n".utf8)) }
        var added: [(data: Data, mediaType: String, image: NSImage)] = []
        for u in urls {
            guard let img = NSImage(contentsOf: u) else { continue }
            let ext = u.pathExtension.lowercased()
            if ext == "png", let d = try? Data(contentsOf: u) { added.append((d, "image/png", img)) }
            else if ext == "jpg" || ext == "jpeg", let d = try? Data(contentsOf: u) { added.append((d, "image/jpeg", img)) }
            else if let d = Self.png(img) { added.append((d, "image/png", img)) }   // HEIC、GIF 等先轉成 PNG
        }
        for img in images { if let d = Self.png(img) { added.append((d, "image/png", img)) } }
        guard !added.isEmpty else { return }
        // 太大的（Retina 截圖、相機照片）先縮：Claude 一張最多收 5 MB，太大會整則被退回
        added = added.map { a in Self.fit(a.data, a.mediaType).map { ($0.0, $0.1, a.image) } ?? a }
        var tokens: [String] = []
        for a in added {
            attachments.append((a.data, a.mediaType, a.image, nextImageNo, false))
            tokens.append(Self.imageToken(nextImageNo))
            nextImageNo += 1
        }
        // 在游標的位置插入 [Image #n]，說明文字可以寫在它前後
        let r = textView.selectedRange()
        let before = r.location > 0 ? (textView.string as NSString).substring(with: NSRange(location: r.location - 1, length: 1)) : "\n"
        let lead = before == " " || before == "\n" ? "" : " "
        textView.insertText(lead + tokens.joined(separator: " ") + " ", replacementRange: r)
        rebuildChips()
        textChanged()
        if ProcessInfo.processInfo.environment["AI_WORKBENCH_DEBUG"] != nil { FileHandle.standardError.write(Data("after attach count=\(attachments.count) chipsHidden=\(chips.isHidden) chips=\(chips.frame) bar=\(frame) super=\(String(describing: superview?.frame))\n".utf8)) }
    }

    private func rebuildChips() {
        textView.fileTokens = files.map { TerminalPane.shellEscape($0.path) }
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for a in attachments {
            let c = AttachmentChip(image: a.image, number: a.no, edited: a.edited)
            let no = a.no
            c.onEdit = { [weak self] in self?.editImage(no) }
            c.onRemove = { [weak self] in self?.removeImage(no) }
            c.widthAnchor.constraint(equalToConstant: AttachmentChip.width(for: a.image)).isActive = true
            c.heightAnchor.constraint(equalToConstant: AttachmentChip.height).isActive = true
            chips.addArrangedSubview(c)
        }
        for u in files {
            let c = FileChip(url: u, fg: chipFG, accent: chipAccent)
            c.onRemove = { [weak self] in self?.removeFile(u) }
            c.widthAnchor.constraint(equalToConstant: c.frame.width).isActive = true
            c.heightAnchor.constraint(equalToConstant: AttachmentChip.height).isActive = true
            chips.addArrangedSubview(c)
        }
        chips.isHidden = attachments.isEmpty && files.isEmpty
        needsLayout = true
    }

    /// 點檔案卡片的 ×：卡片和文字裡的路徑（連後面一個空格）一起拿掉
    private func removeFile(_ u: URL) {
        let tok = TerminalPane.shellEscape(u.path)
        let s = textView.string as NSString
        if let r = textView.tokenRanges().first(where: { s.substring(with: $0) == tok }) {
            var rr = r
            if rr.upperBound < s.length, s.character(at: rr.upperBound) == 0x20 { rr.length += 1 }
            textView.insertText("", replacementRange: rr)
        }
        files.removeAll { $0 == u }
        rebuildChips()
        textChanged()
    }

    // MARK: / 指令選單

    /// 目前游標前面的指令字（文字以 / 開頭、游標還在第一個字裡）；不是的話 nil
    private var slashQuery: String? {
        let s = textView.string as NSString
        let cur = textView.selectedRange().location
        guard s.hasPrefix("/"), cur >= 1, cur <= s.length, !textView.hasMarkedText() else { return nil }
        let head = s.substring(with: NSRange(location: 1, length: cur - 1))
        if head.contains(where: { $0.isWhitespace || $0 == "/" }) { return nil }   // 已經在打參數，或是路徑（以 / 開頭）
        return head
    }

    private func updateSlash() {
        guard let q = slashQuery, textView.string != slashDismissedFor, !isLocked else {
            if !slash.isHidden { slash.set([]) }
            if slashQuery == nil { slashDismissedFor = nil }
            return
        }
        slash.set(SlashCommand.matches(q, in: commands))
        placeSlash()
    }

    private func placeSlash() {
        guard let sv = superview, !slash.isHidden else { return }
        if slash.superview !== sv { sv.addSubview(slash, positioned: .above, relativeTo: nil) }
        let w = min(frame.width - 32, 820)
        slash.frame = NSRect(x: frame.minX + 16, y: frame.maxY - 6, width: max(200, w), height: slash.height)
    }

    private func slashKey(_ e: NSEvent) -> Bool {
        guard !slash.isHidden else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        switch e.keyCode {
        case 125 where mods.isEmpty: slash.move(1); return true
        case 126 where mods.isEmpty: slash.move(-1); return true
        case 48 where mods.isEmpty, 36 where mods.isEmpty, 76 where mods.isEmpty:
            if let c = slash.current { pickSlash(c) }
            return true
        case 53:
            slashDismissedFor = textView.string
            slash.set([])
            return true
        default: return false
        }
    }

    /// 選了指令：把打到一半的 /xxx 換成完整的「/指令 」，游標停在後面可以接著打參數
    private func pickSlash(_ c: SlashCommand) {
        let cur = textView.selectedRange().location
        textView.insertText("/" + c.name + " ", replacementRange: NSRange(location: 0, length: min(cur, (textView.string as NSString).length)))
        slashDismissedFor = textView.string
        slash.set([])
        window?.makeFirstResponder(textView)
    }

    /// 點縮圖：用標註編輯器打開，存檔了就換成編好的圖（還是同一個 #編號）
    private func editImage(_ no: Int) {
        guard let a = attachments.first(where: { $0.no == no }) else { return }
        ImageEditor.edit(a.data, mediaType: a.mediaType, label: "Image #\(no)") { [weak self] data in
            guard let self, let data, let img = NSImage(data: data), let i = self.attachments.firstIndex(where: { $0.no == no }) else { return }
            let fitted = Self.fit(data, "image/png") ?? (data, "image/png")
            self.attachments[i] = (fitted.0, fitted.1, img, no, true)
            self.rebuildChips()
            self.window?.makeFirstResponder(self.textView)
        }
    }

    /// 點縮圖的 ×：圖和文字裡的 [Image #n] 一起拿掉
    private func removeImage(_ no: Int) {
        attachments.removeAll { $0.no == no }
        let s = textView.string as NSString
        var r = s.range(of: Self.imageToken(no) + " ")
        if r.location == NSNotFound { r = s.range(of: Self.imageToken(no)) }
        if r.location != NSNotFound { textView.insertText("", replacementRange: r) }
        rebuildChips()
        textChanged()
    }

    /// 長邊超過 2000 像素或檔案超過 3.5 MB：縮到長邊 2000；PNG 還是太大就改存 JPEG。不用縮回 nil
    static func fit(_ data: Data, _ type: String) -> (Data, String)? {
        guard let src = NSBitmapImageRep(data: data) else { return nil }
        let w = src.pixelsWide, h = src.pixelsHigh, limit = 3_500_000
        guard max(w, h) > 2000 || data.count > limit else { return nil }
        let k = min(1, 2000 / CGFloat(max(w, h)))
        let nw = max(1, Int(CGFloat(w) * k)), nh = max(1, Int(CGFloat(h) * k))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: nw, pixelsHigh: nh, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: nw, height: nh), from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        if type == "image/png", let d = rep.representation(using: .png, properties: [:]), d.count <= limit { return (d, "image/png") }
        if let d = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) { return (d, "image/jpeg") }
        return nil
    }

    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
