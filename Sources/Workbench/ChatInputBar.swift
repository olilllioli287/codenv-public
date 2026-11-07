import AppKit
import UniformTypeIdentifiers
import Combine

/// 輸入框本體：原生文字框，輸入法（唯音）照系統的走。
/// 按鍵照使用者在 Claude Code 的設定：Enter 換行；⌘ Enter 或 ctrl+x ctrl+s 送出；⌃ C 停止並把剛送的字放回來（Esc 不停止，只提示按 ⌃ C）。
final class ChatTextView: NSTextView {
    /// 從別的 App 點回來的第一下就放游標（不只啟用視窗）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// 點在結尾那條空行（最後打了換行、還沒打字）上：系統文字框自己的點擊處理在焦點原本不在這裡時，
    /// 會把游標放到上一行（實測點空行中間落在第二行第 2 個字；同一點用 characterIndexForInsertion 算是結尾）。
    /// 點完補正到最後
    override func mouseDown(with e: NSEvent) {
        var onEmptyLast = false
        if e.clickCount == 1, e.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty, !hasMarkedText(),
           let lm = layoutManager, let tc = textContainer {
            lm.ensureLayout(for: tc)
            let p = convert(e.locationInWindow, from: nil)
            let extra = lm.extraLineFragmentRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            onEmptyLast = lm.extraLineFragmentTextContainer === tc && extra.height > 0 && p.y >= extra.minY
        }
        super.mouseDown(with: e)
        if onEmptyLast, selectedRange().length == 0, !hasMarkedText() {
            let len = (string as NSString).length
            if selectedRange().location != len { setSelectedRange(NSRange(location: len, length: 0)) }
        }
    }
    /// macOS 文字框內建的「補完單字」（F5、⌥ Esc）：只認英文單字、跳出一個小清單，在這裡沒用又讓人困惑
    override func complete(_ sender: Any?) {}
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
        // 組字中（注音還沒選完）不算插話，也不彈右鍵選單：留給輸入法（agy Argon、Sonnet 11/6）
        if hasMarkedText(), let e = NSApp.currentEvent, e.type == .keyDown, e.keyCode == 36 || e.keyCode == 76 { return }
        if let e = NSApp.currentEvent, e.type == .keyDown,
           e.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
           e.keyCode == 36 || e.keyCode == 76 { onSendNow?(); return }
        super.showContextMenuForSelection(sender)
    }

    override func keyDown(with e: NSEvent) {
        // 組字中（選字、注音還沒送出）的按鍵一律交給輸入法
        // ⌃ X 之後的下一個鍵才算 ⌃ X ⌃ S：一進來就取出旗標並重設，後面不管走哪個分支（方向鍵、刪除…）提早 return 都不會留著
        let wasAfterCtrlX = afterCtrlX
        afterCtrlX = false
        if hasMarkedText() { return super.keyDown(with: e) }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if onMenuKey?(e) == true { return }
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
        // 用 keyCode 判斷（s＝1、x＝7）：注音模式下 charactersIgnoringModifiers 不一定是英文字母
        if wasAfterCtrlX, mods == .control, e.keyCode == 1 { onSend?(); return }
        if mods == .control && e.keyCode == 7 { afterCtrlX = true; return }
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

    // 貼上：剪貼簿裡是圖片（截圖、圖片檔）就變成附件；Finder 拷貝的檔案 → 變成檔案卡片；文字照原樣貼（路徑文字不變卡片）
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
                // 「Tab」放最左邊，後面接建議的句子
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
        let x = NSButton(title: "", image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("拿掉"))!, target: self, action: #selector(remove))
        x.isBordered = false
        x.contentTintColor = .white
        x.frame = NSRect(x: w - 22, y: Self.height - 22, width: 18, height: 18)
        addSubview(x)
        let tag = NSTextField(labelWithString: edited ? L("#\(number) 已編輯") : "#\(number)")
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
        toolTip = L("點一下編輯（畫框、箭頭、文字）")
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
        let x = NSButton(title: "", image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("拿掉"))!, target: self, action: #selector(remove))
        x.isBordered = false
        x.contentTintColor = fg.withAlphaComponent(0.7)
        x.frame = NSRect(x: bounds.width - 22, y: bounds.height - 22, width: 18, height: 18)
        addSubview(x)
        toolTip = url.path + "\n" + L("點一下在 Finder 顯示")
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

    /// Finder 樣式的資料夾外形（左上一個分頁＋前面一片面板，圓角），只畫框不填色
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
/// 輸入框的圓角框：點到裡面沒有按鈕的空白處（文字上下的留白、狀態列空的地方），交給 ChatInputBar 把游標放進文字框
private final class InputBoxView: NSView {
    var onClick: ((NSEvent) -> Void)?
    /// 從別的 App 或別格點回來的第一下也要算數，不然只會啟用視窗、游標留在舊位置（空的最後一行點不到）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        if let onClick { onClick(e) } else { super.mouseDown(with: e) }
    }
}

/// 輸入框卡片下面那一行：左邊「上下文」＋細條＋「128K / 上限」，右邊預留一個標籤位置
/// 卡片列用的捲動區：捲軸永遠是浮出樣式。
/// 系統接著滑鼠（或設成「一直顯示捲軸」）時會把每個 NSScrollView 改成傳統樣式，橫捲軸佔 15 點高，
/// 卡片列只有一張卡片高，可視區被壓成 95，卡片頂端被切掉、底下多一條灰色捲軸軌道
final class OverlayOnlyScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style { get { .overlay } set { super.scrollerStyle = .overlay } }
}

final class ContextStrip: NSView {
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private var fraction: CGFloat?
    /// 「上下文」右邊那片：各家用量
    let usage = UsageGlanceStrip()
    var fg: NSColor = .labelColor { didSet { restyle() } }
    static let barWidth: CGFloat = 56

    override init(frame: NSRect) {
        super.init(frame: frame)
        for l in [title, value, trailing] { l.font = .systemFont(ofSize: 11); l.lineBreakMode = .byTruncatingTail; addSubview(l) }
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        title.stringValue = L("上下文")
        trailing.alignment = .right
        trailing.isHidden = true
        for v in [track, fill] { v.wantsLayer = true; addSubview(v) }
        track.layer?.cornerRadius = 1.5; fill.layer?.cornerRadius = 1.5
        addSubview(usage)
        restyle()
        setContext(tokens: nil, limit: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let c = fg.withAlphaComponent(0.5)
        [title, value, trailing].forEach { $0.textColor = c }
        track.layer?.backgroundColor = fg.withAlphaComponent(0.12).cgColor
        fill.layer?.backgroundColor = fg.withAlphaComponent(0.45).cgColor
        usage.fg = fg
    }

    func setContext(tokens: Int?, limit: Int?) {
        if let n = tokens {
            value.stringValue = ContextMonitor.text(n) + (limit.map { " / " + ContextMonitor.text($0) } ?? "")
            fraction = limit.map { min(1, max(0, CGFloat(n) / CGFloat($0))) }
        } else {
            value.stringValue = "—"; fraction = nil
        }
        needsLayout = true
    }

    func setTrailingNote(_ text: String?) {
        trailing.stringValue = text ?? ""
        trailing.isHidden = (text ?? "").isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h: CGFloat = 14, y = (bounds.height - h) / 2
        title.sizeToFit(); value.sizeToFit()
        title.frame = NSRect(x: 0, y: y, width: title.frame.width, height: h)
        let bx = title.frame.maxX + 6
        track.frame = NSRect(x: bx, y: (bounds.height - 3) / 2, width: Self.barWidth, height: 3)
        fill.frame = NSRect(x: bx, y: track.frame.minY, width: Self.barWidth * (fraction ?? 0), height: 3)
        track.isHidden = fraction == nil; fill.isHidden = fraction == nil
        let vx = (fraction == nil ? title.frame.maxX : track.frame.maxX) + 6
        var right = bounds.width
        if !trailing.isHidden {
            trailing.sizeToFit()
            let tw = min(trailing.frame.width, max(0, bounds.width - vx - value.frame.width - 12))
            trailing.frame = NSRect(x: bounds.width - tw, y: y, width: tw, height: h)
            right = trailing.frame.minX - 8
        }
        value.frame = NSRect(x: vx, y: y, width: max(0, min(value.frame.width, right - vx)), height: h)
        let ux = value.frame.maxX + 16
        usage.frame = NSRect(x: ux, y: 0, width: max(0, right - ux), height: bounds.height)
    }
}

/// 輸入框下面「上下文」右邊的用量：「剩餘 ✳ 64% · 90%   ⬡ 88% · 82%   ✦ 94% · 98% · 阿公 100%」
/// 數字是剩下的百分比（跟左下角、右側欄一致）；剩兩成以下紅。放不下時從後面整組拿掉（agy → Codex → Claude），不換行、不截成「…」。
/// 滑過一組看每個數字是什麼、多久後重置；點一下開完整用量頁。
final class UsageGlanceStrip: NSView, NSViewToolTipOwner {
    var fg: NSColor = .labelColor { didSet { rebuild() } }
    private var groups: [UsageGlanceGroup] = []
    private var cells: [(icon: NSImageView, text: NSTextField)] = []
    private let lead = NSTextField(labelWithString: L("剩餘"))
    private var sub: AnyCancellable?
    private var shown = 0
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override init(frame: NSRect) {
        super.init(frame: frame)
        lead.font = .systemFont(ofSize: 11); addSubview(lead)
        // UsageMonitor 每次改值都重畫（objectWillChange 在改之前發，所以等下一輪再讀）
        sub = UsageMonitor.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只有畫出東西的那段算（空白處照舊點到輸入框）
        guard shown > 0, let last = cells.prefix(shown).last?.text, let p = superview?.convert(point, to: self),
              p.x <= last.frame.maxX, p.x >= 0 else { return nil }
        return self
    }
    override func mouseDown(with e: NSEvent) { UsageSheet.toggle() }

    private func rebuild() {
        groups = UsageMonitor.shared.glance
        cells.forEach { $0.icon.removeFromSuperview(); $0.text.removeFromSuperview() }
        cells = groups.map { g in
            let iv = NSImageView()
            // 各家的圖示直接讀使用者電腦上裝的 App（不打包、不自己畫商標）；沒裝就退回 SF Symbols
            if let img = AppIcons.icon(for: g.key) {
                iv.image = img; iv.imageScaling = .scaleProportionallyUpOrDown; iv.contentTintColor = nil
            } else {
                iv.image = NSImage(systemSymbolName: g.symbol, accessibilityDescription: g.name)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
                iv.contentTintColor = fg.withAlphaComponent(0.55)
            }
            let t = NSTextField(labelWithString: "")
            let str = NSMutableAttributedString()
            for p in g.parts() {
                str.append(NSAttributedString(string: p.text, attributes: [.font: Self.font,
                    .foregroundColor: p.low ? NSColor.systemRed : fg.withAlphaComponent(0.5)]))
            }
            t.attributedStringValue = str
            t.lineBreakMode = .byClipping
            addSubview(iv); addSubview(t)
            return (iv, t)
        }
        lead.textColor = fg.withAlphaComponent(0.5)
        needsLayout = true
    }

    /// 放得下幾組（測試也用）
    static func fit(widths: [CGFloat], lead: CGFloat, available: CGFloat, gap: CGFloat = 12, icon: CGFloat = 16) -> Int {
        var x = lead, n = 0
        for w in widths {
            let end = x + gap + icon + w
            if end > available { break }
            x = end; n += 1
        }
        return n
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        let h: CGFloat = 14, y = (bounds.height - h) / 2
        lead.sizeToFit()
        cells.forEach { $0.text.sizeToFit() }
        shown = Self.fit(widths: cells.map { $0.text.frame.width }, lead: lead.frame.width, available: bounds.width)
        lead.isHidden = shown == 0
        lead.frame = NSRect(x: 0, y: y, width: lead.frame.width, height: h)
        var x = lead.frame.maxX
        for (i, c) in cells.enumerated() {
            let on = i < shown
            c.icon.isHidden = !on; c.text.isHidden = !on
            guard on else { continue }
            x += 12
            c.icon.frame = NSRect(x: x, y: (bounds.height - 13) / 2, width: 13, height: 13)
            c.text.frame = NSRect(x: x + 16, y: y, width: c.text.frame.width, height: h)
            addToolTip(NSRect(x: x - 4, y: 0, width: c.text.frame.maxX - x + 8, height: bounds.height), owner: self, userData: nil)
            x = c.text.frame.maxX
        }
    }

    // 滑過時才算說明：重置倒數跟著時間走
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        for (i, c) in cells.prefix(shown).enumerated() where point.x <= c.text.frame.maxX + 4 { return groups[i].tip }
        return ""
    }
}

final class ChatInputBar: NSView {
    let textView = ChatTextView()
    /// 圓角框外圍那圈留白（左右 16、底下 12）也算點輸入框：游標放到最近的位置，不留在舊位置
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        if textView.hasMarkedText() { textView.mouseDown(with: e); return }
        clickBesideText(atWindowPoint: e.locationInWindow)
    }
    var hasQuotes = false { didSet { updateButton() } }
    var onPendingInputChange: (() -> Void)?
    var onDraftChange: (() -> Void)?
    /// 草稿有內容就保留格子，引用也算。
    var hasPendingInput: Bool { hasQuotes || !textView.string.isEmpty || !attachments.isEmpty }
    private let scroll = NSScrollView()
    private let box = InputBoxView()
    /// 卡片下面那一行：上下文大小；右邊留給之後的標籤（例如「明天 06:00 交接」）
    private let ctxStrip = ContextStrip()
    static let ctxRowH: CGFloat = 16
    func setContext(tokens: Int?, limit: Int?) { ctxStrip.setContext(tokens: tokens, limit: limit) }
    func setTrailingNote(_ text: String?) { ctxStrip.setTrailingNote(text) }
    private let chips = NSStackView()
    /// 卡片多到放不下時左右捲（不要擠扁最後幾張）
    private let chipScroll = OverlayOnlyScrollView()
    /// 卡片那排和打字區中間的分隔線（兩端內縮，不碰外框）
    private let chipDivider = NSView()
    /// 最下面那排（上傳檔案、權限模式、模型、送出）上面的分隔線：樣式跟 chipDivider 一樣
    private let statusDivider = NSView()
    /// 「上傳檔案」：開檔案面板（可縮放、可移動，不是掛在視窗上的 sheet），選好的當成拖進來的檔案
    private let uploadButton = BlueCircleButton()
    /// 橘色收納鈕：在藍色資料夾鈕左邊，樣式一樣；按下去由 ChatPane 給選單（瀏覽器格的比對、回報、匯出）
    let toolsButton = BlueCircleButton()
    var onToolsButton: ((NSView) -> Void)?
    /// 有卡片的檔案（拖進來或貼上的路徑）；文字裡的路徑被刪掉，卡片也跟著拿掉
    private var files: [URL] = []
    var draftFilePaths: [String] {
        let present = Set(textView.tokenRanges().map { (textView.string as NSString).substring(with: $0) })
        return files.filter { present.contains(TerminalPane.shellEscape($0.path)) }.map(\.path)
    }
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
    var draftImages: [DraftPersistence.Image] {
        attachments.map { DraftPersistence.Image(data: $0.data, mediaType: $0.mediaType, no: $0.no, edited: $0.edited) }
    }
    private var nextImageNo = 1
    static func imageToken(_ n: Int) -> String { "[Image #\(n)]" }
    var onSend: ((String, [(data: Data, mediaType: String)], Bool) -> Bool)?   // 最後一個：⌃ Enter 馬上插話
    /// 輸入框是空的按 ⌃ Enter：排隊中的訊息全部馬上插話
    var onSendQueuedNow: (() -> Void)?
    var onStop: (() -> Void)?
    var onBlur: (() -> Void)?
    // ! 指令（Bang.swift）：開頭是 ! 就是指令模式（框線橘色），Enter 不送給模型、交給 onBang 執行；回傳 false＝沒執行（例如上一個還在跑），字留著
    var onBang: ((String) -> Bool)?
    /// 指令正在跑：⌃ C 先停指令（Esc 不停）
    var bangRunning = false
    var onStopBang: (() -> Void)?
    /// 還沒附給模型的指令結果數：輸入框上面顯示「下一則訊息會附上 N 個指令結果」和 ✕
    var bangCount = 0 { didSet { if bangCount != oldValue { rebuildBangNote() } } }
    var onBangCancel: (() -> Void)?
    private let bangNote = NSView()
    private let bangLabel = NSTextField(labelWithString: "")
    private let bangX = NSButton()
    private let bangHint = NSTextField(labelWithString: "")
    /// 做事中按 Esc 的提示（兩秒後自己消失）
    private let stopHint = NSTextField(labelWithString: "")
    private var stopHintTimer: Timer?
    var stopHintShown: Bool { !stopHint.isHidden }   // 測試用（--dump-focus 會印）
    private static let bangRow: CGFloat = 24
    private var inBang: Bool { Bang.isBangMode(textView.string) }
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
    /// 每次送出都留一份（不管當時 Claude 忙不忙）：送出失敗要放回來用。lastSent 在忙的時候是 nil（排隊的那則停下來之後還是會送，不放回），不能拿來還原送不出去的
    private var lastAttempt: (text: String, attachments: [(data: Data, mediaType: String, image: NSImage, no: Int, edited: Bool)], nextNo: Int, files: [URL])?
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
        box.onClick = { [weak self] e in
            guard let self, self.lockView.isHidden else { return }
            // 注音組字中：原始事件交回文字框，讓輸入法先收掉組字
            if self.textView.hasMarkedText() { self.textView.mouseDown(with: e); return }
            self.clickBesideText(atWindowPoint: e.locationInWindow)
        }
        box.layer?.cornerRadius = 14
        box.layer?.borderWidth = 1
        addSubview(box)
        addSubview(ctxStrip)
        chips.orientation = .horizontal
        chips.spacing = 8
        chips.isHidden = true
        // 縮圖和檔案卡片放在輸入框裡面最上面一排（原本浮在對話內容上，看不出邊界）
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
        textView.placeholder = L("輸入 / 開啟指令選單")
        textView.registerForDraggedTypes(ChatTextView.dropTypes)
        // 整個輸入框都能收（框裡的空白、按鈕旁邊、鎖住時也一樣），不是只有文字那一條
        registerForDraggedTypes(ChatTextView.dropTypes)
        textView.onDropPasteboard = { [weak self] pb in self?.takeDrop(pb) ?? false }
        textView.onSend = { [weak self] in self?.send() }
        textView.onSendNow = { [weak self] in self?.send(now: true) }
        textView.onMenuKey = { [weak self] e in self?.slashKey(e) ?? false }
        slash.isHidden = true
        slash.onPick = { [weak self] c in self?.pickSlash(c) }
        // Esc：Claude（或 ! 指令）在做時不停止，只提示改按 ⌃ C（不小心按到 Esc 會中斷）；沒在做就離開輸入框（之後按 / 再回來）
        textView.onEscape = { [weak self] in
            guard let self else { return }
            if self.bangRunning || self.busy { self.flashStopHint() } else { self.onBlur?() }
        }
        textView.onInterrupt = { [weak self] in
            if self?.bangRunning == true { self?.onStopBang?(); return }
            self?.interruptAndRestore()
        }
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
        modelButton.toolTip = L("換模型")
        box.addSubview(modelButton)
        modeButton.isBordered = false
        modeButton.target = self
        modeButton.action = #selector(cycleModePressed)
        modeButton.toolTip = L("權限模式（⇧ Tab 切換）：每次都問 → 改檔不問 → 只規劃 → 自動")
        box.addSubview(modeButton)
        statusDivider.wantsLayer = true
        box.addSubview(statusDivider)
        // 藍色圓鈕＋白色資料夾
        uploadButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: L("上傳檔案"))?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        uploadButton.target = self
        uploadButton.action = #selector(uploadPressed)
        uploadButton.toolTip = L("上傳檔案（可以選好幾個檔案或資料夾）")
        box.addSubview(uploadButton)
        toolsButton.baseColor = .systemOrange
        toolsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L("瀏覽器格的工具"))?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        toolsButton.target = self
        toolsButton.action = #selector(toolsPressed)
        toolsButton.toolTip = L("瀏覽器格的工具（請 Claude 比對、回報、匯出）")
        box.addSubview(toolsButton)
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
        // ! 指令：上面的提示條（還沒附給模型的結果）和下面狀態列左邊的說明
        bangNote.isHidden = true
        bangLabel.font = .systemFont(ofSize: 12)
        bangLabel.textColor = .systemOrange
        bangNote.addSubview(bangLabel)
        bangX.isBordered = false
        bangX.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("不附上"))
        bangX.contentTintColor = .secondaryLabelColor
        bangX.target = self
        bangX.action = #selector(bangCancelPressed)
        bangX.toolTip = L("這次不附上指令結果")
        bangNote.addSubview(bangX)
        box.addSubview(bangNote)
        bangHint.font = .systemFont(ofSize: 12)
        bangHint.textColor = .systemOrange
        bangHint.stringValue = L("執行指令（Enter 執行，結果會附給 Claude）")
        bangHint.isHidden = true
        box.addSubview(bangHint)
        stopHint.font = .systemFont(ofSize: 12, weight: .medium)
        stopHint.textColor = .systemOrange
        stopHint.stringValue = L("停止請按 ⌃ C")
        stopHint.isHidden = true
        box.addSubview(stopHint)
        updateButton()
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ pal: Palette, mono: NSFont) {
        let dark = pal.bg.usingColorSpace(.sRGB).map { $0.brightnessComponent < 0.5 } ?? true
        box.layer?.backgroundColor = (dark ? pal.bg.blended(withFraction: 0.07, of: .white) : pal.bg.blended(withFraction: 0.04, of: .black))?.cgColor
        themeBorder = pal.fg.withAlphaComponent(0.15).cgColor
        box.layer?.borderColor = themeBorder
        updateBangMode()
        chipDivider.layer?.backgroundColor = pal.fg.withAlphaComponent(0.15).cgColor
        statusDivider.layer?.backgroundColor = pal.fg.withAlphaComponent(0.15).cgColor
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
        ctxStrip.fg = pal.fg
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
        // 行高取「字型預設」和「實際排出來最高的一行」較大者：中文會換成蘋方，行比英文字型高，
        // 只用預設行高的話打中文不到 12 行就開始捲、頂端切半行（agy Argon 11/6）
        var line = lm.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 15))
        if lm.numberOfGlyphs > 0 {
            var g = 0, seen = 0
            while g < lm.numberOfGlyphs && seen < 40 {
                var r = NSRange()
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &r)
                line = max(line, frag.height); seen += 1
                g = max(g + 1, NSMaxRange(r))
            }
        }
        // 結尾換行產生的空行（extra line fragment）也要算進高度，不然那一行會被切掉、點不到
        var bottom = lm.usedRect(for: tc).maxY
        if lm.extraLineFragmentTextContainer === tc { bottom = max(bottom, lm.extraLineFragmentRect.maxY) }
        let h = max(line, bottom) + textView.textContainerInset.height * 2
        let cap = line * maxLines + textView.textContainerInset.height * 2
        return (min(h, cap), h > cap + 1)
    }
    /// 測試用：輸入框的捲軸現在有沒有、是哪種樣式
    var scrollerState: String { "scroller=\(scroll.hasVerticalScroller) style=\(scroll.scrollerStyle == .overlay ? "overlay" : "legacy")" }
    /// 測試用：框高、內容高、有沒有超過上限
    /// 測試用：把所有圖片附件標成「已編輯」（真的走標註編輯器存檔後的樣子）
    func markAllEditedForTest() {
        for i in attachments.indices { attachments[i].edited = true }
        rebuildChips()
    }
    /// 測試用：模擬系統把捲軸樣式換掉（接上／拔掉滑鼠、或「一直顯示捲軸」時，AppKit 會直接改每個 NSScrollView 的 scrollerStyle）
    func forceScrollerStyleForTest(_ s: NSScroller.Style) {
        chipScroll.scrollerStyle = s; scroll.scrollerStyle = s   // 卡片列忽略這個，永遠 overlay
    }
    /// 測試用：卡片列的位置（卡片捲動區、裡面那排卡片、可視範圍、分隔線、文字區）
    var chipMetricsForTest: String {
        let c = chipScroll.contentView
        return "chipScroll=\(chipScroll.frame) style=\(chipScroll.scrollerStyle == .overlay ? "overlay" : "legacy") hScroller=\(chipScroll.hasHorizontalScroller) clip=\(c.frame) clipBounds=\(c.bounds) chips=\(chips.frame) divider=\(chipDivider.frame) textScroll=\(scroll.frame) box=\(box.frame) bar=\(frame) fitting=\(fittingHeight(width: frame.width))"
    }
    var metricsForTest: String { let m = measureText(); return "boxH=\(Int(m.height)) overflow=\(m.overflow) scrollH=\(Int(scroll.frame.height)) textW=\(Int(textView.frame.width)) scrollW=\(Int(scroll.frame.width)) atBottom=\(abs(scroll.contentView.bounds.maxY - textView.frame.height) < 1.5)" }

    /// 下面那排狀態列（權限模式、模型、送出鍵）的高度：打字在上面，字不會碰到這一排
    private static let statusRow: CGFloat = 35   // 底排 28 ＋ 分隔線和按鈕之間留 7

    /// 卡片那排佔的高度（上緣 8、卡片、分隔線上下各留一點）
    private static let chipRow: CGFloat = AttachmentChip.height + 24

    func fittingHeight(width: CGFloat) -> CGFloat {
        (chips.isHidden ? 0 : Self.chipRow) + (bangCount > 0 ? Self.bangRow : 0) + textHeight + Self.statusRow + 4 + 16 + Self.ctxRowH + 8   // 卡片上下各 4、下面多一行上下文
    }

    override func layout() {
        super.layout()
        placeSlash()
        let margin: CGFloat = 16
        // 底下 4 留白＋上下文那一行，再往上才是卡片；卡片上緣留 4
        ctxStrip.frame = NSRect(x: margin + 6, y: 4, width: max(0, bounds.width - margin * 2 - 12), height: Self.ctxRowH)
        box.frame = NSRect(x: margin, y: 4 + Self.ctxRowH, width: max(0, bounds.width - margin * 2), height: max(0, bounds.height - Self.ctxRowH - 8))
        chipDivider.isHidden = chips.isHidden
        chipScroll.isHidden = chips.isHidden
        let bangH: CGFloat = bangCount > 0 ? Self.bangRow : 0
        bangNote.isHidden = bangCount == 0
        if bangCount > 0 {
            bangNote.frame = NSRect(x: 10, y: box.bounds.height - 4 - Self.bangRow, width: max(0, box.bounds.width - 20), height: Self.bangRow)
            bangX.frame = NSRect(x: bangNote.bounds.maxX - 22, y: 2, width: 20, height: 20)
            bangLabel.frame = NSRect(x: 4, y: 3, width: max(0, bangNote.bounds.width - 30), height: 18)
        }
        if !chips.isHidden {
            chipScroll.frame = NSRect(x: 10, y: box.bounds.height - 8 - bangH - AttachmentChip.height, width: max(0, box.bounds.width - 20), height: AttachmentChip.height)
            chips.frame = NSRect(x: 0, y: 0, width: max(chips.fittingSize.width, chipScroll.contentSize.width), height: AttachmentChip.height)
            chipDivider.frame = NSRect(x: 14, y: chipScroll.frame.minY - 7, width: max(0, box.bounds.width - 28), height: 1)
        }
        let inner = box.bounds.insetBy(dx: 10, dy: 8)
        // 先用新寬度排版再量高度：視窗變窄時用舊寬度量，折出來的行會被裁掉（agy Argon 11/6；捲軸是浮出式，不佔寬）
        if abs(textView.frame.width - inner.width) > 0.5 { textView.frame.size.width = inner.width; superview?.needsLayout = true }
        let (th, overflow) = measureText()
        // 捲軸：字超過最多行數才有，而且一律用浮出來的樣式。
        // 系統設成「一直顯示捲軸」（接滑鼠時）的話，行高差幾點就會在空的輸入框右邊畫出一條有外框的捲軸
        if scroll.hasVerticalScroller != overflow { scroll.hasVerticalScroller = overflow }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        // 兩行：最下面一排是狀態列（右邊依序 權限模式、模型、送出鍵），上面整條寬度都給打字
        let row = inner.minY
        sendButton.frame = NSRect(x: inner.maxX - 28, y: row, width: 28, height: 28)
        bangHint.isHidden = !(inBang && lockView.isHidden) || !stopHint.isHidden   // 停止提示顯示時讓位，不疊在一起
        bangHint.frame = NSRect(x: inner.minX + 4, y: row + 5, width: max(0, inner.width - 40), height: 18)
        stopHint.frame = bangHint.frame
        // 空的輸入框只提示 / 指令選單（不要按鍵說明；Claude 在忙時也一樣）
        let want = L("輸入 / 開啟指令選單")
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
        // 上傳檔案：在「自動」的左邊（模式按鈕收起來時接在模型按鈕左邊）；太窄就收起來
        uploadButton.isHidden = !lockView.isHidden || inner.width < 200
        let ux = (modeButton.isHidden ? modelButton.frame.minX : modeButton.frame.minX) - 26
        uploadButton.frame = NSRect(x: ux, y: row + 3, width: 22, height: 22)
        // 橘色收納鈕：接在資料夾鈕左邊；上傳鈕收起來（太窄）時一起收
        toolsButton.isHidden = !Prefs.shared.webFeaturesEnabled || uploadButton.isHidden || inner.width < 230
        toolsButton.frame = NSRect(x: uploadButton.frame.minX - 26, y: row + 3, width: 22, height: 22)
        statusDivider.isHidden = !lockView.isHidden
        statusDivider.frame = NSRect(x: 14, y: row + Self.statusRow + 1, width: max(0, box.bounds.width - 28), height: 1)
        var y = row + Self.statusRow + 4
        scroll.frame = NSRect(x: inner.minX, y: y, width: inner.width, height: th)
        y += th
        textView.frame.size.width = scroll.contentSize.width
        // 只有字數或框高變了才捲到底：往上捲著看前文時，別的事（Claude 跑完、提示出現）觸發排版不能把人拉回最底（agy Argon 11/6）
        // 寬度和實際內容高度也算：拖寬拖窄、同字數換成會多折一行的字時，字數和框高都沒變但最後一行位置變了（agy Sonnet 11/6）
        let usedH = textView.layoutManager.flatMap { lm in textView.textContainer.map { lm.usedRect(for: $0).height } } ?? 0
        let revealKey = "\(textView.textStorage?.length ?? 0):\(Int(th)):\(Int(textView.frame.width)):\(Int(usedH))"
        if overflow, revealKey != lastRevealKey { revealEndIfCaretAtEnd() }
        lastRevealKey = revealKey
        lockView.frame = box.bounds
        let bw = lockButton.isHidden ? 0 : lockButton.intrinsicContentSize.width + 8
        lockButton.frame = NSRect(x: box.bounds.maxX - bw - 10, y: (box.bounds.height - 28) / 2, width: bw, height: 28)
        lockLabel.frame = NSRect(x: 14, y: 6, width: box.bounds.width - bw - 34, height: box.bounds.height - 12)
    }

    @objc private func toolsPressed() {
        guard Prefs.shared.webFeaturesEnabled else { return }
        onToolsButton?(toolsButton)
    }

    /// 在輸入框最後面放一段字（不送出）；游標與焦點移到後面，使用者看過再送
    func putText(_ s: String) {
        let t = textView.string as NSString
        let lead = t.length == 0 || t.hasSuffix("\n") ? "" : "\n"
        textView.insertText(lead + s, replacementRange: NSRange(location: t.length, length: 0))
        textChanged()
    }

    @objc private func textChanged() {
        // 文字裡的 [Image #n] 或檔案路徑被刪掉：那張圖、那張卡片也拿掉（跟 Claude Code 一樣）
        if !attachments.isEmpty || !files.isEmpty, !textView.hasMarkedText() {
            let s = textView.string
            let kept = attachments.filter { s.contains(Self.imageToken($0.no)) }
            // 路徑還在文字裡就留著卡片：用 ← → 跳過路徑後直接打字，路徑後面會黏著字，不能因此把卡片丟掉（agy Argon 11/6）。
            // 長的路徑先比、比到就遮掉：/a/b 和 /a/b.png 都有卡片時，刪掉 /a/b 不能因為 /a/b.png 裡含它而誤留（agy Sonnet 11/6）
            let masked = NSMutableString(string: s)
            var keptPaths = Set<String>()
            for f in files.sorted(by: { TerminalPane.shellEscape($0.path).count > TerminalPane.shellEscape($1.path).count }) {
                let r = masked.range(of: TerminalPane.shellEscape(f.path))
                guard r.location != NSNotFound else { continue }
                masked.replaceCharacters(in: r, with: String(repeating: "\u{1}", count: r.length))
                keptPaths.insert(f.path)
            }
            let keptFiles = files.filter { keptPaths.contains($0.path) }
            if kept.count != attachments.count || keptFiles.count != files.count {
                // 文字裡的標記被刪掉：圖也跟著拿掉；⌘Z 把標記救回來時圖要一起回來（不然標記在、縮圖沒了，送出也不帶圖）
                let removed = attachments.filter { a in !kept.contains { $0.no == a.no } }
                let removedFiles = files.filter { f in !keptFiles.contains { $0.path == f.path } }   // 檔案卡片也要能 ⌘Z 救回（agy Argon 11/6）
                if !removed.isEmpty || !removedFiles.isEmpty, let um = textView.undoManager, !um.isUndoing {      // redo 刪標記時也要登記，不然「刪→復原→重做→再復原」只剩標記
                    um.registerUndo(withTarget: self) { me in
                        for a in removed where !me.attachments.contains(where: { $0.no == a.no }) { me.attachments.append(a) }
                        me.attachments.sort { $0.no < $1.no }
                        for f in removedFiles where !me.files.contains(where: { $0.path == f.path }) { me.files.append(f) }
                        me.rebuildChips()
                        me.onDraftChange?()
                    }
                }
                attachments = kept; files = keptFiles; rebuildChips()
            }
        }
        updateSlash()
        updateBangMode()
        superview?.needsLayout = true
        needsLayout = true
        updateButton()
        onDraftChange?()
        onPendingInputChange?()
    }

    // MARK: ! 指令外觀

    private var themeBorder: CGColor?
    private func updateBangMode() {
        if themeBorder == nil { themeBorder = box.layer?.borderColor }
        let on = inBang
        box.layer?.borderColor = on ? NSColor.systemOrange.cgColor : themeBorder
        box.layer?.borderWidth = on ? 1.5 : 1
        textView.placeholder = on ? "" : L("輸入 / 開啟指令選單")
    }
    private func rebuildBangNote() {
        bangLabel.stringValue = L("下一則訊息會附上 \(bangCount) 個指令結果")
        needsLayout = true
        superview?.needsLayout = true
    }
    @objc private func bangCancelPressed() { onBangCancel?() }

    private func flashStopHint() {
        stopHint.isHidden = false
        needsLayout = true
        stopHintTimer?.invalidate()
        stopHintTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.stopHint.isHidden = true; self?.needsLayout = true }
    }

    private func updateButton() {
        let name = busy ? "stop.circle.fill" : "arrow.up.circle.fill"
        sendButton.image = NSImage(systemSymbolName: name, accessibilityDescription: L(busy ? "停止" : "送出"))?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        sendButton.toolTip = L(busy ? "停止（⌃ C）" : "送出（⌘ Enter）")
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && !hasQuotes
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
        uploadButton.isHidden = text != nil
        needsLayout = true
    }
    @objc private func lockPressed() { lockAction?() }

    /// 開檔案面板：獨立視窗（不是 sheet），能放大、能移動，大小記起來；選好的圖片變縮圖附件、其他檔案插入路徑（跟拖進來一樣）
    @objc func uploadPressed() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("上傳")
        panel.message = L("選要放進這個聊天室的檔案或資料夾（可以多選）")
        if let f = appDefaults.string(forKey: "uploadPanelFrame") { panel.setFrame(NSRectFromString(f), display: false) }
        let ok = panel.runModal() == .OK
        appDefaults.set(NSStringFromRect(panel.frame), forKey: "uploadPanelFrame")
        guard ok else { window?.makeFirstResponder(textView); return }
        takeFiles(panel.urls)
    }

    /// 選好的檔案（或測試用）：圖片變附件、其他插入路徑
    func takeFiles(_ urls: [URL]) {
        let imgs = urls.filter(ChatTextView.isImage)
        let others = urls.filter { !ChatTextView.isImage($0) }
        if !imgs.isEmpty { attach(urls: imgs, images: []) }
        if !others.isEmpty { insertPaths(others) }
        window?.makeFirstResponder(textView)
    }

    /// 從跨啟動草稿還原檔案卡片；檔案已不存在的路徑不會加入。
    /// 路徑文字已經在還原的草稿裡：只登記成卡片，不再插一次字，也不拿焦點（Astra 11/5 審查：原本會重複插入、搶焦點）
    func restoreFilePaths(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        for u in urls where !files.contains(u) { files.append(u) }
        rebuildChips()
    }

    /// 草稿文字已有 [Image #n]：只還原附件與縮圖，保留編號、編輯狀態，不插字、不拿焦點。
    func restoreImages(_ images: [DraftPersistence.Image]) {
        for a in images where a.no > 0 && a.no < Int.max {
            guard !attachments.contains(where: { $0.no == a.no }), let image = NSImage(data: a.data) else { continue }
            attachments.append((a.data, a.mediaType, image, a.no, a.edited))
            nextImageNo = max(nextImageNo, a.no + 1)
        }
        // 圖檔遺失仍保留文字；新貼圖不能重用該標記的編號。
        let text = textView.string as NSString
        if let regex = try? NSRegularExpression(pattern: #"\[Image #(\d+)\]"#) {
            for match in regex.matches(in: textView.string, range: NSRange(location: 0, length: text.length)) {
                if let no = Int(text.substring(with: match.range(at: 1))), no > 0, no < Int.max {
                    nextImageNo = max(nextImageNo, no + 1)
                }
            }
        }
        rebuildChips()
        updateButton()
    }

    @objc private func buttonPressed() { busy ? onStop?() : send() }

    /// ⌃ C：Claude 在做（或剛送出、還沒開始）就停下來；輸入框是空的話，把剛送出的字和圖放回來
    func interruptAndRestore() {
        guard busy || lastSent != nil else { return }
        onStop?()
        restoreLastSent()
    }

    /// 超過最多行數、游標在最後面：捲到最底，讓最後一行（包括換行產生的空行）一定看得到、點得到。
    /// 直接放進草稿（setDraft、restoreLost、restoreLastSent）或輸入框高度改變時，捲動位置不會自己跟上，
    /// 最後那條空行會落在可見範圍外（測試掛鉤 --input-probe 量到空行在 y 323 而可見只到 300）
    private var lastRevealKey = ""
    private func revealEndIfCaretAtEnd() {
        let len = (textView.string as NSString).length
        guard textView.selectedRange().location == len, let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        textView.sizeToFit()
        let clip = scroll.contentView
        let bottom = max(0, textView.frame.height - clip.bounds.height)
        guard abs(clip.bounds.origin.y - bottom) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bottom))
        scroll.reflectScrolledClipView(clip)
    }

    /// 點在文字框外、圓角框裡的空白：游標放到最靠近的那一行（點在文字下面＝最後一行，點在行尾右邊＝行尾），並把焦點給文字框。
    /// 晚上：只有 3 行時點最後一行下面那排，游標留在原處（點擊落在圓角框，不是文字框）
    func clickBesideText(atWindowPoint w: NSPoint) {
        guard lockView.isHidden else { return }
        let p = textView.convert(w, from: nil)
        let vis = textView.visibleRect
        guard vis.width > 2, vis.height > 2 else { return }
        let cp = NSPoint(x: min(max(p.x, vis.minX + 1), vis.maxX - 1), y: min(max(p.y, vis.minY + 1), vis.maxY - 1))
        window?.makeFirstResponder(textView)
        let len = (textView.string as NSString).length
        var i = textView.characterIndexForInsertion(at: cp)
        // 結尾是空行、點在它（或它下面）：直接放到最後。先判斷原始座標再夾進可見範圍，
        // 空行只露一部分時夾過的點會落到上一行（Codex 11/7 判讀）
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            let o = textView.textContainerOrigin
            let extra = lm.extraLineFragmentRect.offsetBy(dx: o.x, dy: o.y)
            if lm.extraLineFragmentTextContainer === tc, extra.height > 0, p.y >= extra.minY { i = len }
        }
        textView.setSelectedRange(NSRange(location: i, length: 0))
        textView.scrollRangeToVisible(NSRange(location: i, length: 0))
        if i == len { revealEndIfCaretAtEnd() }
    }

    /// 程式碼區的「問 AI」：把整理好的訊息放進輸入框讓使用者看過、改過再送（不直接送出）。輸入框已經有字就接在後面
    func setDraft(_ t: String) {
        let cur = textView.string
        textView.string = cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t : cur + "\n\n" + t
        textView.undoManager?.removeAllActions()
        textChanged()
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        window?.makeFirstResponder(textView)
    }

    /// 送出後程序結束、訊息沒被讀到：字和圖放回輸入框（輸入框已經有字就不蓋掉，回傳 false）
    @discardableResult
    func restoreLost(text: String, images: [(data: Data, mediaType: String)]) -> Bool {
        guard textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty, !hasQuotes else { return false }
        var t = text
        // 送出的字裡原本的 [Image #n] 記號已經對不上新的附件編號：全部拿掉，照新編號重放
        t = t.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        attachments = []
        nextImageNo = 1
        for im in images {
            guard let img = NSImage(data: im.data) else { continue }
            attachments.append((im.data, im.mediaType, img, nextImageNo, false))
            t += (t.isEmpty ? "" : " ") + Self.imageToken(nextImageNo)
            nextImageNo += 1
        }
        textView.string = t
        textView.undoManager?.removeAllActions()
        rebuildChips()
        textChanged()
        textView.setSelectedRange(NSRange(location: (t as NSString).length, length: 0))
        return true
    }

    /// 送出成功了：不再保留「失敗時可放回」的那一則
    func clearAttempt() { lastAttempt = nil }

    /// 送出失敗（程序開不起來、寫不進去）：這一則放回輸入框，忙不忙都一樣
    func restoreFailedSend() {
        guard let last = lastAttempt else { return }
        lastSent = last
        lastAttempt = nil
        restoreLastSent()
    }

    /// 剛送出的字放回輸入框（⌃ C；Gemini 連不上 Google 沒送出時也用）
    func restoreLastSent() {
        guard let last = lastSent else { return }
        // 輸入框已經有新打的字就不蓋掉它；暫存的留著（還沒放回去，不能丟）
        guard textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else { return }
        lastSent = nil
        textView.string = last.text
        textView.undoManager?.removeAllActions()   // 直接換掉整段字不會進復原紀錄，舊紀錄套上來會錯位
        attachments = last.attachments
        nextImageNo = last.nextNo
        files = last.files
        rebuildChips()
        textChanged()
        textView.setSelectedRange(NSRange(location: (last.text as NSString).length, length: 0))
        // 送出失敗是非同步回來的，使用者可能已經在別格打字：焦點沒落在別處、或本來就在這裡才拉回（agy Argon 11/6）
        if let w = window {
            let fr = w.firstResponder
            let nowhere = fr == nil || fr === w || fr === w.contentView
            let here = (fr as? NSView).map { $0 === textView || $0.isDescendant(of: self) } ?? false
            if nowhere || here { w.makeFirstResponder(textView) }
        }
    }

    /// 焦點不在輸入框時按 ⌃ Enter（MainWindow 轉過來）：輸入框有字就馬上插話送出，空的就讓排隊的馬上插話
    func sendNowFromOutside() { send(now: true) }

    private func send(now: Bool = false) {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        // ! 指令：不走模型。只有 ! 沒有指令就什麼都不做
        if Bang.isBangMode(text) {
            guard let cmd = Bang.command(in: text), onBang?(cmd) == true else { return }
            textView.string = ""
            textView.undoManager?.removeAllActions()
            textChanged()
            return
        }
        guard !text.isEmpty || !attachments.isEmpty || hasQuotes else {
            if now { onSendQueuedNow?() }
            return
        }
        suggestion = nil
        // Claude 在做時送的是排隊的那則，停下來之後它還是會送出去，所以不放回
        lastAttempt = (text: text, attachments: attachments, nextNo: nextImageNo, files: files)
        if busy { lastSent = nil } else { lastSent = lastAttempt }
        // 只有寄件匣已落盤、後端接受寫入才清空；失敗時字、圖、引用留在原處，不切焦點。
        guard onSend?(text, attachments.map { ($0.data, $0.mediaType) }, now) == true else {
            lastAttempt = nil
            return
        }
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
    /// 游標停在 [Image #n] 或檔案路徑整塊標記的中間（滑鼠點進去）：插東西會把標記切成兩半，原本那張圖／卡片就被當成被刪掉而丟掉。改插在標記後面
    private func outsideTokens(_ r: NSRange) -> NSRange {
        guard r.length == 0, let t = textView.tokenRanges().first(where: { r.location > $0.location && r.location < $0.upperBound }) else { return r }
        return NSRange(location: t.upperBound, length: 0)
    }

    func insertPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for u in urls where !files.contains(u) { files.append(u) }
        rebuildChips()   // 先登記成整塊標記，插進去的字才認得
        let s = textView.string as NSString
        var r = textView.selectedRange()
        if r.location == NSNotFound || r.upperBound > s.length { r = NSRange(location: s.length, length: 0) }   // 還沒有有效的選取位置：放到最後面，不要用越界的位置去取字
        r = outsideTokens(r)
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
        var r = textView.selectedRange()
        if r.location == NSNotFound || r.upperBound > (textView.string as NSString).length { r = NSRange(location: (textView.string as NSString).length, length: 0) }
        r = outsideTokens(r)
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
            guard let self, let data, let img = NSImage(data: data), let i = self.attachments.firstIndex(where: { $0.no == no && $0.data == a.data }) else { return }      // 編輯器開著的時候草稿送出又貼了別張圖（編號重來）：別蓋到新圖上
            let fitted = Self.fit(data, "image/png") ?? (data, "image/png")
            self.attachments[i] = (fitted.0, fitted.1, img, no, true)
            self.rebuildChips()
            self.onDraftChange?()
            // 編輯器關掉時使用者可能已經在別的地方打字：只有焦點還沒落在別的文字框時才拉回來（Astra 11/5）
            if let w = self.window, w.isKeyWindow {
                // 只有焦點沒落在任何地方（視窗本身）或本來就在這個輸入框時才拉回；在終端機、網頁、別格都不動（agy Sonnet 11/6）
                let fr = w.firstResponder
                let nowhere = fr == nil || fr === w || fr === w.contentView
                let here = (fr as? NSView).map { $0 === self.textView || $0.isDescendant(of: self) } ?? false
                if nowhere || here { w.makeFirstResponder(self.textView) }
            }
        }
    }

    /// 點縮圖的 ×：圖和文字裡的 [Image #n] 一起拿掉
    private func removeImage(_ no: Int) {
        // 先刪文字標記、讓 textChanged 拿掉圖並登記復原（⌘Z 圖會一起回來）；先拿掉圖的話復原只救回標記（agy Argon 11/6）
        let s = textView.string as NSString
        var r = s.range(of: Self.imageToken(no) + " ")
        if r.location == NSNotFound { r = s.range(of: Self.imageToken(no)) }
        if r.location != NSNotFound { textView.insertText("", replacementRange: r) }
        // 文字裡本來沒有標記、有兩個一樣的標記（只刪了一個）、或文字沒刪成：圖還是要拿掉（agy Sonnet 11/6）
        if attachments.contains(where: { $0.no == no }) { attachments.removeAll { $0.no == no } }
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
        // JPEG：品質由高往低試，第一個不超過上限的就用；都超過就用最小的那個（長邊已經不超過 2000，這種情況很少見）
        var smallest: Data?
        for q in [0.88, 0.7, 0.5, 0.3] {
            guard let d = rep.representation(using: .jpeg, properties: [.compressionFactor: q]) else { continue }
            if d.count <= limit { return (d, "image/jpeg") }
            if smallest == nil || d.count < smallest!.count { smallest = d }
        }
        return smallest.map { ($0, "image/jpeg") }
    }

    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}


/// 藍色圓形按鈕（systemBlue，白色圖示）：滑鼠移上去稍微亮一點。深淺色主題都看得清楚
final class BlueCircleButton: NSButton {
    /// 圓鈕的底色（預設藍色；橘色收納鈕用 systemOrange）
    var baseColor: NSColor = .systemBlue { didSet { refresh() } }
    private var hover = false { didSet { refresh() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .white
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); layer?.cornerRadius = bounds.height / 2 }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func viewDidChangeEffectiveAppearance() { refresh() }
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = baseColor
            layer?.backgroundColor = (hover ? (base.blended(withFraction: 0.18, of: .white) ?? base) : base).cgColor
        }
    }
}
