import AppKit
import UniformTypeIdentifiers
import Combine

/// 輸入框本體：原生文字框，輸入法（唯音）照系統的走。
/// 按鍵照使用者在 Claude Code 的設定：Enter 換行；⌘ Enter 或 ctrl+x ctrl+s 送出；⌃ C 停止並把剛送的字放回來（Esc 不停止，只提示按 ⌃ C）。
final class ChatTextView: NSTextView {
    struct PlaceholderDrawing {
        let attributedString: NSAttributedString
        let rect: NSRect
    }

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
    var onInterrupt: (() -> Bool)?
    /// / 選單開著的時候先問它要不要這個按鍵（↑ ↓ Tab Enter Esc）
    var onMenuKey: ((NSEvent) -> Bool)?
    /// Claude 猜的下一句：輸入框空的時候用灰字顯示，Tab 採用
    var suggestion: String? { didSet { needsDisplay = true } }
    var onImages: (([URL], [NSImage]) -> Void)?
    var onPasteShouldBeRejected: (() -> Bool)?
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderColor = NSColor.placeholderTextColor
    private(set) var inputBaselineOffset: CGFloat = 0
    private var afterCtrlX = false
    /// IME 組字期間不改整份 storage；組字提交或取消後再統一套用一次。
    private var baselineNormalizationPending = false
    private var baselineWasComposing = false
    private var baselineOffsetNormalizationInProgress = false
    private var lastBaselineOffsetRepairLogAt: Date?
    private var skippedBaselineOffsetRepairLogCount = 0
    private var baselineOffsetRepairLogEpoch = 0

    /// 切字型時同步文字、游標將使用的屬性，以及已輸入的純文字。
    func applyInputFont(_ font: NSFont) {
        let composing = hasMarkedText()
        if composing { baselineWasComposing = true }
        self.font = font
        var attributes = typingAttributes
        attributes[.font] = font
        if !composing { attributes.removeValue(forKey: .baselineOffset) }
        typingAttributes = attributes
        if !composing { inputBaselineOffset = 0 }
        else { baselineNormalizationPending = true }
        if let storage = textStorage, storage.length > 0 {
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            if !composing { storage.removeAttribute(.baselineOffset, range: NSRange(location: 0, length: storage.length)) }
            storage.endEditing()
        }
        if let layoutManager, let textContainer { layoutManager.ensureLayout(for: textContainer) }
        updateBaselineOffsetForLineCount()
        needsDisplay = true
        needsLayout = true
    }

    private func centeredBaselineOffset(for font: NSFont) -> CGFloat {
        -(font.ascender + font.descender) / 2
    }

    /// 單行不加 baselineOffset：NSTextView 的標準字型度量已在行框內排好；舊的負 offset 會把墨跡往下推。
    /// 多行沿用舊 offset，保持既有的逐行排版外觀。
    func updateBaselineOffsetForLineCount(wasComposing: Bool = false) {
        guard !baselineOffsetNormalizationInProgress, let font = self.font else { return }
        // setMarkedText 可能在換行數改變時替換一部分 attributed string。先保留組字前的屬性，
        // 等 IME commit／unmark 後再統一重套，避免同一行新舊文字各帶不同 offset。
        if hasMarkedText() {
            baselineNormalizationPending = true
            return
        }
        let target = visualLineCount <= 1 ? 0 : centeredBaselineOffset(for: font)
        // 即使目標值沒變，也必須檢查所有 run；輸入法或其他文字屬性更新可能只改了部分區段。
        if baselineNormalizationPending || abs(target - inputBaselineOffset) > 0.01 {
            baselineNormalizationPending = false
            // 先對照統一前的值留存錯位證據。正常行數切換時每段仍等於舊 inputBaselineOffset，
            // 因此目標值改變本身不會被記成錯誤。
            if let storage = textStorage, storage.length > 0 {
                let mismatches = baselineOffsetMismatches(in: storage, expected: inputBaselineOffset)
                logBaselineOffsetRepairIfNeeded(mismatches, wasComposing: wasComposing || baselineWasComposing)
            }
            inputBaselineOffset = target
            applyBaselineOffsetToTypingAttributes(target)
            if let storage = textStorage, storage.length > 0 {
                baselineOffsetNormalizationInProgress = true
                storage.beginEditing()
                if target == 0 {
                    storage.removeAttribute(.baselineOffset, range: NSRange(location: 0, length: storage.length))
                } else {
                    storage.addAttribute(.baselineOffset, value: target, range: NSRange(location: 0, length: storage.length))
                }
                storage.endEditing()
                baselineOffsetNormalizationInProgress = false
            }
            needsLayout = true
        }
        normalizeBaselineOffsetRuns(wasComposing: wasComposing || baselineWasComposing)
    }

    private func applyBaselineOffsetToTypingAttributes(_ target: CGFloat) {
        var attributes = typingAttributes
        if target == 0 { attributes.removeValue(forKey: .baselineOffset) }
        else { attributes[.baselineOffset] = target }
        typingAttributes = attributes
    }

    private func baselineOffsetMismatches(in storage: NSTextStorage, expected: CGFloat) -> [String] {
        var mismatchedOffsets: [String] = []
        let target = Double(expected)
        storage.enumerateAttribute(.baselineOffset, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            let offset = (value as? NSNumber)?.doubleValue ?? 0
            if !offset.isFinite || abs(offset - target) > 0.01 {
                let label = value == nil ? "nil(0)" : (offset.isFinite ? String(format: "%.3f", offset) : String(describing: offset))
                mismatchedOffsets.append(label)
            }
        }
        return mismatchedOffsets
    }

    private func logBaselineOffsetRepairIfNeeded(_ mismatchedOffsets: [String], wasComposing: Bool) {
        guard !mismatchedOffsets.isEmpty else { return }
        baselineOffsetRepairLogEpoch += 1
        let now = Date()
        if lastBaselineOffsetRepairLogAt.map({ now.timeIntervalSince($0) >= 1 }) ?? true {
            lastBaselineOffsetRepairLogAt = now
            let skipped = skippedBaselineOffsetRepairLogCount
            skippedBaselineOffsetRepairLogCount = 0
            let skippedSuffix = skipped > 0 ? "、略過=\(skipped)" : ""
            EventLog.log("輸入框", "baselineOffset 自我修正：不一致段數=\(mismatchedOffsets.count)、各段offset=[\(mismatchedOffsets.joined(separator: ","))]、視覺行數=\(visualLineCount)、wasComposing=\(wasComposing)\(skippedSuffix)")
        } else {
            skippedBaselineOffsetRepairLogCount += 1
        }
    }

    /// IME 結束或文字／版面更新後的保險檢查；不記錄文字，只記 offset 數值與視覺行數。
    private func normalizeBaselineOffsetRuns(wasComposing: Bool) {
        guard !hasMarkedText(), !baselineOffsetNormalizationInProgress,
              let storage = textStorage, storage.length > 0 else { return }
        let mismatchedOffsets = baselineOffsetMismatches(in: storage, expected: inputBaselineOffset)
        guard !mismatchedOffsets.isEmpty else { return }

        baselineOffsetNormalizationInProgress = true
        storage.beginEditing()
        if inputBaselineOffset == 0 {
            storage.removeAttribute(.baselineOffset, range: NSRange(location: 0, length: storage.length))
        } else {
            storage.addAttribute(.baselineOffset, value: inputBaselineOffset, range: NSRange(location: 0, length: storage.length))
        }
        storage.endEditing()
        applyBaselineOffsetToTypingAttributes(inputBaselineOffset)
        baselineOffsetNormalizationInProgress = false
        needsLayout = true
        logBaselineOffsetRepairIfNeeded(mismatchedOffsets, wasComposing: wasComposing)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        baselineWasComposing = true
        baselineNormalizationPending = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updateBaselineOffsetForLineCount()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let hadMarkedText = hasMarkedText()
        let wasComposing = baselineWasComposing || hadMarkedText
        let mismatchesBeforeInsert: [String]
        if hadMarkedText, let storage = textStorage {
            mismatchesBeforeInsert = baselineOffsetMismatches(in: storage, expected: inputBaselineOffset)
        } else {
            mismatchesBeforeInsert = []
        }
        let repairLogEpochBefore = baselineOffsetRepairLogEpoch
        super.insertText(string, replacementRange: replacementRange)
        if !hasMarkedText() {
            if baselineNormalizationPending {
                baselineWasComposing = false
                updateBaselineOffsetForLineCount(wasComposing: wasComposing)
            }
            // super.insertText 可能以新文字取代帶有錯位 offset 的 marked text，使系統端已抹平差異；
            // 若這次提交過程尚未記錄過修復，補記同一筆錯位證據。
            if hadMarkedText, !mismatchesBeforeInsert.isEmpty,
               baselineOffsetRepairLogEpoch == repairLogEpochBefore,
               let storage = textStorage,
               baselineOffsetMismatches(in: storage, expected: inputBaselineOffset).isEmpty {
                logBaselineOffsetRepairIfNeeded(mismatchesBeforeInsert, wasComposing: true)
            }
        }
    }

    override func unmarkText() {
        let wasComposing = baselineWasComposing || hasMarkedText()
        // 先記組字提交前相對於既有目標的錯位。NSTextView.unmarkText 可能先整理 marked attributed string，
        // 若只在 super 返回後比較，系統已抹平的差異會消失，無法留下自我修正紀錄。
        let mismatchesBeforeUnmark: [String]
        if wasComposing, let storage = textStorage {
            mismatchesBeforeUnmark = baselineOffsetMismatches(in: storage, expected: inputBaselineOffset)
        } else {
            mismatchesBeforeUnmark = []
        }
        let repairLogEpochBefore = baselineOffsetRepairLogEpoch
        super.unmarkText()
        if !hasMarkedText() {
            baselineWasComposing = false
            updateBaselineOffsetForLineCount(wasComposing: wasComposing)
            // 通常 updateBaselineOffsetForLineCount 會在改寫前記錄；若 super 已自行修正且本輪尚未記錄，補記同一筆錯位證據。
            if !mismatchesBeforeUnmark.isEmpty,
               baselineOffsetRepairLogEpoch == repairLogEpochBefore,
               let storage = textStorage,
               baselineOffsetMismatches(in: storage, expected: inputBaselineOffset).isEmpty {
                logBaselineOffsetRepairIfNeeded(mismatchesBeforeUnmark, wasComposing: true)
            }
        }
    }

    override func layout() {
        super.layout()
        guard !baselineOffsetNormalizationInProgress else { return }
        if hasMarkedText() {
            baselineNormalizationPending = true
            baselineWasComposing = true
        } else {
            let wasComposing = baselineWasComposing
            baselineWasComposing = false
            updateBaselineOffsetForLineCount(wasComposing: wasComposing)
        }
    }

    /// 隔離探針讀取每個 storage attributed run 與排版後的視覺行數。
    func baselineOffsetProbeSnapshot() -> [String: Any] {
        let storage = textStorage
        let source = storage?.string ?? ""
        var runs: [[String: Any]] = []
        var offsets: [Double] = []
        if let storage, storage.length > 0 {
            storage.enumerateAttribute(.baselineOffset, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                let offset = (value as? NSNumber)?.doubleValue ?? 0
                offsets.append(offset)
                var run: [String: Any] = [
                    "range": [range.location, range.length],
                    "text": (source as NSString).substring(with: range)
                ]
                run["baselineOffset"] = value == nil ? NSNull() : NSNumber(value: offset)
                runs.append(run)
            }
        }
        let baselineUniform = offsets.dropFirst().allSatisfy { abs($0 - offsets[0]) <= 0.01 }
        let baselineMatchesInput = offsets.allSatisfy { abs($0 - Double(inputBaselineOffset)) <= 0.01 }
        return [
            "text": source,
            "hasMarkedText": hasMarkedText(),
            "visualLineCount": visualLineCount,
            "inputBaselineOffset": Double(inputBaselineOffset),
            "baselineUniform": baselineUniform,
            "baselineMatchesInput": baselineMatchesInput,
            "runs": runs
        ]
    }

    /// 隔離探針注入單一錯誤 offset；暫停 layout 自我修復，讓探針能先讀到修正前狀態。
    func corruptBaselineOffsetForProbe(_ range: NSRange, offset: CGFloat) -> [String: Any]? {
        guard let storage = textStorage, range.location >= 0, range.length > 0,
              range.location <= storage.length, range.length <= storage.length - range.location,
              offset.isFinite else { return nil }
        baselineOffsetNormalizationInProgress = true
        defer { baselineOffsetNormalizationInProgress = false }
        storage.addAttribute(.baselineOffset, value: offset, range: range)
        return baselineOffsetProbeSnapshot()
    }

    /// NSTextView 的 layout manager 座標轉成文字檢視座標。placeholder 和輸入行共用這個行框。
    func emptyLineFragmentRect() -> NSRect {
        let f = font ?? .systemFont(ofSize: 15)
        guard let lm = layoutManager, let tc = textContainer else {
            return NSRect(origin: textContainerOrigin, size: NSSize(width: bounds.width, height: f.ascender - f.descender + f.leading))
        }
        lm.ensureLayout(for: tc)
        let line = lm.extraLineFragmentRect
        if line.height > 0 {
            return line.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        return NSRect(origin: textContainerOrigin, size: NSSize(width: max(0, bounds.width - textContainerOrigin.x * 2), height: f.ascender - f.descender + f.leading))
    }

    /// 單行時把 AppKit 傳入的游標矩形置於文字檢視中央；多行仍留在目前行的位置。
    func centeredCaretRectForInput(_ rect: NSRect) -> NSRect {
        guard visualLineCount <= 1 else { return rect }
        return rect.offsetBy(dx: 0, dy: bounds.midY - rect.midY)
    }

    private var visualLineCount: Int {
        guard let lm = layoutManager, let tc = textContainer else { return 1 }
        lm.ensureLayout(for: tc)
        var count = 0
        var glyph = 0
        while glyph < lm.numberOfGlyphs && count < 40 {
            var range = NSRange()
            _ = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            glyph = max(glyph + 1, NSMaxRange(range))
            count += 1
        }
        if lm.extraLineFragmentTextContainer === tc, lm.extraLineFragmentRect.height > 0 { count += 1 }
        return count
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: centeredCaretRectForInput(rect), color: color, turnedOn: flag)
    }

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
        // 反白文字時保留 NSTextView／系統的複製行為；沒有選取、且這輪可停止時才當中斷。
        if mods == .control && e.keyCode == 8, selectedRange().length == 0, onInterrupt?() == true { return }
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
        paste(from: NSPasteboard.general, sender: sender)
    }

    /// 隔離考題以私有 pasteboard 走與 ⌘V 相同的解析與拒絕路徑，不碰使用者剪貼簿。
    func paste(from pasteboard: NSPasteboard, sender: Any? = nil) {
        if onPasteShouldBeRejected?() == true { return }
        if takeImages(from: pasteboard) { return }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty,
           let f = onDropPasteboard, f(pasteboard) { return }
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
        if let drawing = placeholderDrawing() {
            drawing.attributedString.draw(with: drawing.rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    func placeholderDrawing() -> PlaceholderDrawing? {
        guard string.isEmpty, !hasMarkedText() else { return nil }
        let f = font ?? .systemFont(ofSize: 14)
        var lineRect = emptyLineFragmentRect()
        let padding = textContainer?.lineFragmentPadding ?? 5
        lineRect.origin.x += padding
        lineRect.size.width = max(0, lineRect.width - padding * 2)
        let baseline = inputBaselineOffset
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        para.minimumLineHeight = lineRect.height
        para.maximumLineHeight = lineRect.height
        if let s = suggestion, !s.isEmpty {
            let small = NSFont.systemFont(ofSize: f.pointSize * 0.75)
            // 兩段共用 NSTextView 的行框基線；小字只縮小字身，不另套 offset，避免字型不同時錯位。
            let line = NSMutableAttributedString(string: "Tab  ", attributes: [.font: small, .foregroundColor: placeholderColor.withAlphaComponent(placeholderColor.alphaComponent * 0.6), .paragraphStyle: para])
            line.append(NSAttributedString(string: s.replacingOccurrences(of: "\n", with: " "), attributes: [.font: f, .foregroundColor: placeholderColor, .paragraphStyle: para, .baselineOffset: baseline]))
            return PlaceholderDrawing(attributedString: line, rect: lineRect)
        }
        let text = NSAttributedString(string: placeholder, attributes: [.font: f, .foregroundColor: placeholderColor, .paragraphStyle: para, .baselineOffset: baseline])
        return PlaceholderDrawing(attributedString: text, rect: lineRect)
    }

    /// 建議提示專用量測：兩段的字框與實際輸入行框都在 textView 座標，基線使用 AppKit 字型 metrics 推算。
    func suggestionMetricsForProbe() -> [String: Any] {
        guard let suggestion, !suggestion.isEmpty, let drawing = placeholderDrawing(),
              let font = self.font else { return [:] }
        let lineRect = drawing.rect
        let tabFont = NSFont.systemFont(ofSize: font.pointSize * 0.75)
        let textRect = NSRect(x: lineRect.minX, y: lineRect.midY - (font.ascender - font.descender) / 2 + inputBaselineOffset,
                              width: lineRect.width, height: font.ascender - font.descender)
        let tabRect = NSRect(x: lineRect.minX, y: lineRect.midY - (tabFont.ascender - tabFont.descender) / 2 + inputBaselineOffset,
                             width: lineRect.width, height: tabFont.ascender - tabFont.descender)
        func baseline(_ rect: NSRect, _ f: NSFont) -> CGFloat {
            isFlipped ? rect.minY + (rect.height - (f.ascender - f.descender)) / 2 + f.ascender - inputBaselineOffset
                      : rect.minY + (rect.height - (f.ascender - f.descender)) / 2 - f.descender + inputBaselineOffset
        }
        func gaps(_ rect: NSRect) -> (CGFloat, CGFloat) {
            isFlipped ? (rect.minY - lineRect.minY, lineRect.maxY - rect.maxY)
                      : (lineRect.maxY - rect.maxY, rect.minY - lineRect.minY)
        }
        let tg = gaps(textRect), bg = gaps(tabRect)
        let inputLine = emptyLineFragmentRect()
        return [
            "inputFontName": font.fontName, "inputFontSize": Double(font.pointSize),
            "suggestionFontName": font.fontName, "suggestionFontSize": Double(font.pointSize),
            "tabFontName": tabFont.fontName, "tabFontSize": Double(tabFont.pointSize),
            "coordinateSpace": "ChatTextView 座標", "unit": "pt", "isFlipped": isFlipped,
            "lineFrame": rectMetricsForSuggestion(lineRect),
            "suggestionFrame": rectMetricsForSuggestion(textRect),
            "tabFrame": rectMetricsForSuggestion(tabRect),
            "inputLineFrame": rectMetricsForSuggestion(inputLine),
            "suggestionBaseline": Double(baseline(textRect, font)),
            "tabBaseline": Double(baseline(tabRect, tabFont)),
            "inputBaseline": Double(baseline(inputLine, font)),
            "suggestionTopGap": Double(tg.0), "suggestionBottomGap": Double(tg.1),
            "tabTopGap": Double(bg.0), "tabBottomGap": Double(bg.1)
        ]
    }

    private func rectMetricsForSuggestion(_ rect: NSRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height),
         "minY": Double(rect.minY), "maxY": Double(rect.maxY)]
    }
    override func didChangeText() {
        let wasComposing = baselineWasComposing || hasMarkedText()
        super.didChangeText()
        if hasMarkedText() {
            baselineWasComposing = true
            baselineNormalizationPending = true
        } else {
            baselineWasComposing = false
            updateBaselineOffsetForLineCount(wasComposing: wasComposing)
        }
        needsDisplay = true
    }
}

private final class DropFocusProbeWindow: NSWindow {
    private(set) var makeFirstResponderCalls = 0
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        makeFirstResponderCalls += 1
        return super.makeFirstResponder(responder)
    }
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
    private var testForcedStyle: NSScroller.Style?
    override var scrollerStyle: NSScroller.Style { get { testForcedStyle ?? .overlay } set { super.scrollerStyle = testForcedStyle ?? .overlay } }

    func forceStyleForTest(_ style: NSScroller.Style) {
        testForcedStyle = style
        super.scrollerStyle = style
    }
}

final class ContextStrip: NSView {
    /// 上排 total：總上下文（上限，例如 640K）；下排 value：目前已用（例如 196K）。兩行的字級跟右邊用量一樣、整段上下置中，所以兩邊的行會對齊
    private let total = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    /// 「上下文」右邊那片：各家用量
    let usage = UsageGlanceStrip()
    var fg: NSColor = .labelColor { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for l in [total, value] { l.alignment = .center; l.lineBreakMode = .byClipping; addSubview(l) }
        total.font = UsageGlanceStrip.rowLabelFont
        value.font = UsageGlanceStrip.rowValueFont
        trailing.font = .systemFont(ofSize: 11)
        trailing.lineBreakMode = .byTruncatingTail
        trailing.alignment = .right
        trailing.isHidden = true
        addSubview(trailing)
        addSubview(usage)
        restyle()
        setContext(tokens: nil, limit: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let c = fg.withAlphaComponent(0.5)
        [total, value, trailing].forEach { $0.textColor = c }
        usage.fg = fg
    }

    /// 上排＝總上下文（上限），下排＝目前已用；不知道就顯示「—」（跟用量查不到的寫法一樣）
    func setContext(tokens: Int?, limit: Int?) {
        total.stringValue = limit.map { ContextMonitor.text($0) } ?? "—"
        value.stringValue = tokens.map { ContextMonitor.text($0) } ?? "—"
        needsLayout = true
    }

    func setTrailingNote(_ text: String?) {
        trailing.stringValue = text ?? ""
        trailing.isHidden = (text ?? "").isEmpty
        needsLayout = true
    }

    /// 測試用（TestHarness --usage-strip-probe）：上下文兩行的文字、字級、行的位置（跟右邊用量的行比對）
    func probeLine() -> String {
        "context total=\(total.stringValue) used=\(value.stringValue) labelPt=\(UsageGlanceStrip.rowLabelFont.pointSize) valuePt=\(UsageGlanceStrip.rowValueFont.pointSize) labelY=\(total.frame.minY) valueY=\(value.frame.minY) rows=2"
    }

    override func layout() {
        super.layout()
        // 兩行的高度和基線跟右邊用量一樣（同一組字級），整段上下置中
        let labelH = ceil(UsageGlanceStrip.rowLabelFont.ascender - UsageGlanceStrip.rowLabelFont.descender)
        let valueH = ceil(UsageGlanceStrip.rowValueFont.ascender - UsageGlanceStrip.rowValueFont.descender)
        let baseY = ((bounds.height - labelH - valueH) / 2).rounded()
        let colW = ceil(max(Self.textWidth(total.stringValue, UsageGlanceStrip.rowLabelFont),
                            Self.textWidth(value.stringValue, UsageGlanceStrip.rowValueFont)))
        var right = bounds.width
        if !trailing.isHidden {
            trailing.sizeToFit()
            let rth = trailing.frame.height
            let tw = min(trailing.frame.width, max(0, bounds.width - colW - 12))
            trailing.frame = NSRect(x: bounds.width - tw, y: ((bounds.height - rth) / 2).rounded(), width: tw, height: rth)
            right = trailing.frame.minX - 8
        }
        let w = max(0, min(colW, right))
        total.frame = NSRect(x: 0, y: baseY + valueH, width: w, height: labelH)
        value.frame = NSRect(x: 0, y: baseY, width: w, height: valueH)
        let ux = w + 16
        usage.frame = NSRect(x: ux, y: 0, width: max(0, right - ux), height: bounds.height)
    }

    private static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width + 4   // 同上：兩邊各留 2 點
    }
}

/// 輸入框下面「上下文」右邊的用量（11/10 使用者定版面）：兩行、一家一組，拿掉長條，只留數字。
/// 上行小字標籤（week／5h；agy 再加 argon），下行剩餘百分比；數字照剩餘量上色（>50 綠、20～50 黃、<20 紅，沿用原本的門檻與顏色）。
/// 組的順序：Claude、Codex、agy；每組都是「每週、5 小時」，agy 再多一個 Argon。引擎圖示放在每組最前面。
/// 放不下時先換小字（compact）；還放不下才從後面整組拿掉（agy → Codex → Claude），不換行、不截成「…」。
/// 滑過一組看每個數字是什麼、多久後重置；點一下開完整用量頁。
final class UsageGlanceStrip: NSView, NSViewToolTipOwner {
    var fg: NSColor = .labelColor { didSet { rebuild() } }
    private var groups: [UsageGlanceGroup] = []
    /// 兩行的字級：上行小字標籤、下行數字。上下文的兩行也用這一組，兩邊的行才會對齊
    static let rowLabelFont = NSFont.systemFont(ofSize: 9)
    static let rowValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// 字級與間距兩檔：正常；放不下時換成小字這一檔
    private struct Tier {
        let label: NSFont
        let value: NSFont
        let icon: CGFloat, iconGap: CGFloat, columnGap: CGFloat, groupGap: CGFloat
        let name: String
        static let normal = Tier(label: UsageGlanceStrip.rowLabelFont, value: UsageGlanceStrip.rowValueFont,
                                 icon: 13, iconGap: 4, columnGap: 8, groupGap: 12, name: "normal")
        static let compact = Tier(label: .systemFont(ofSize: 8), value: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                  icon: 11, iconGap: 3, columnGap: 5, groupGap: 8, name: "compact")
    }
    /// 一欄＝上行標籤＋下行數字；level 是顏色的名字（green／yellow／red／none），給測試對照用
    private struct Column {
        let label: NSTextField
        let value: NSTextField
        let labelText: String
        let valueText: String
        let level: String
    }
    private struct Cell { let icon: NSImageView; let columns: [Column] }
    private var cells: [Cell] = []
    private var tier = Tier.normal
    private var shown = 0
    /// 每一組畫到的右邊界（滑過說明、點擊範圍用）
    private var ends: [CGFloat] = []
    private var sub: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // UsageMonitor 每次改值都重畫（objectWillChange 在改之前發，所以等下一輪再讀）
        sub = UsageMonitor.shared.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只有畫出東西的那段算（空白處照舊點到輸入框）
        guard shown > 0, let end = ends.last, let p = superview?.convert(point, to: self), p.x >= 0, p.x <= end else { return nil }
        return self
    }
    override func mouseDown(with e: NSEvent) { UsageSheet.toggle() }

    /// 剩餘量的顏色與名字（沿用原本的門檻：>50 綠、20～50 黃、<20 紅）
    static func levelColor(_ remaining: Int) -> NSColor { remaining > 50 ? .systemGreen : (remaining >= 20 ? .systemYellow : .systemRed) }
    static func levelName(_ remaining: Int) -> String { remaining > 50 ? "green" : (remaining >= 20 ? "yellow" : "red") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    private func rebuild() {
        rebuild(groups: UsageMonitor.shared.glance)
    }

    private func rebuild(groups: [UsageGlanceGroup]) {
        self.groups = groups
        for c in cells {
            c.icon.removeFromSuperview()
            c.columns.forEach { $0.label.removeFromSuperview(); $0.value.removeFromSuperview() }
        }
        let textColor = fg.withAlphaComponent(0.5)
        cells = groups.map { g in
            let iv = NSImageView()
            // 圖示不自己畫：Claude／Codex 用面板那套（Resources/icons），agy 讀使用者裝的 Antigravity.app 去背；取不到就退回 SF Symbols
            if let gl = AppIcons.glyph(for: g.key) {
                // 跟「全部的用量」面板同一套去背圖示：Claude 橘星芒、Codex 單色（跟字色）、agy 彩色 A
                let img = gl.image.copy() as! NSImage
                img.isTemplate = gl.template
                iv.image = img; iv.imageScaling = .scaleProportionallyUpOrDown
                iv.contentTintColor = gl.template ? fg.withAlphaComponent(0.6) : nil
            } else {
                iv.image = NSImage(systemSymbolName: g.symbol, accessibilityDescription: g.name)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
                iv.contentTintColor = fg.withAlphaComponent(0.55)
            }
            addSubview(iv)
            let columns = g.items.map { it -> Column in
                let remaining = it.bucket?.remaining
                let label = NSTextField(labelWithString: it.short ?? it.what)
                label.textColor = textColor
                label.alignment = .center
                label.lineBreakMode = .byClipping
                let value = NSTextField(labelWithString: remaining.map { "\($0)%" } ?? "—")
                value.textColor = remaining.map { UsageGlanceStrip.levelColor($0) } ?? textColor
                value.alignment = .center
                value.lineBreakMode = .byClipping
                addSubview(label); addSubview(value)
                return Column(label: label, value: value, labelText: label.stringValue, valueText: value.stringValue,
                              level: remaining.map { UsageGlanceStrip.levelName($0) } ?? "none")
            }
            return Cell(icon: iv, columns: columns)
        }
        needsLayout = true
    }

    /// 考卷用：透過相同 NSTextField 建立流程讀出指定資料的畫面標籤。
    static func probeLines(for groups: [UsageGlanceGroup], width: CGFloat = 360) -> [String] {
        let strip = UsageGlanceStrip(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        strip.rebuild(groups: groups)
        strip.layoutSubtreeIfNeeded()
        return strip.probeLines()
    }

    /// 從前面開始放得下幾組（組與組之間空 gap）
    static func fitCount(widths: [CGFloat], gap: CGFloat, available: CGFloat) -> Int {
        var used: CGFloat = 0, n = 0
        for w in widths {
            let need = (n == 0 ? 0 : gap) + w
            if used + need > available { break }
            used += need; n += 1
        }
        return n
    }

    private static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width) + 4   // 兩邊各留 2 點：NSTextField 會在邊上留白，不留的話最後一個字會被切掉
    }
    /// 一欄的寬：標籤和數字取較寬的那個
    private static func columnWidth(_ col: Column, _ t: Tier) -> CGFloat {
        max(textWidth(col.labelText, t.label), textWidth(col.valueText, t.value))
    }
    /// 一組的寬：圖示＋圖示間距＋每一欄（欄與欄之間空 columnGap）
    private func width(of c: Cell, _ t: Tier) -> CGFloat {
        let cols = c.columns.reduce(CGFloat(0)) { $0 + Self.columnWidth($1, t) }
        return t.icon + t.iconGap + cols + CGFloat(max(0, c.columns.count - 1)) * t.columnGap
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        // 先試正常字級，全部放得下就用它；放不下改小字；小字還放不下才從後面整組拿掉
        func fitAll(_ t: Tier) -> Int { Self.fitCount(widths: cells.map { width(of: $0, t) }, gap: t.groupGap, available: bounds.width) }
        tier = fitAll(.normal) == cells.count ? .normal : .compact
        shown = fitAll(tier)
        let t = tier
        // 兩行整段上下置中：數字在下、標籤在上
        let labelH = ceil(t.label.ascender - t.label.descender)
        let valueH = ceil(t.value.ascender - t.value.descender)
        let baseY = ((bounds.height - labelH - valueH) / 2).rounded()
        var x: CGFloat = 0
        ends = []
        for (i, c) in cells.enumerated() {
            let on = i < shown
            c.icon.isHidden = !on
            for col in c.columns { col.label.isHidden = !on; col.value.isHidden = !on }
            guard on else { continue }
            if i > 0 { x += t.groupGap }
            c.icon.frame = NSRect(x: x, y: ((bounds.height - t.icon) / 2).rounded(), width: t.icon, height: t.icon)
            var cx = x + t.icon + t.iconGap
            for (k, col) in c.columns.enumerated() {
                if k > 0 { cx += t.columnGap }
                let w = Self.columnWidth(col, t)
                col.label.font = t.label; col.value.font = t.value
                col.value.frame = NSRect(x: cx, y: baseY, width: w, height: valueH)
                col.label.frame = NSRect(x: cx, y: baseY + valueH, width: w, height: labelH)
                cx += w
            }
            addToolTip(NSRect(x: x - 4, y: 0, width: cx - x + 8, height: bounds.height), owner: self, userData: nil)
            ends.append(cx)
            x = cx
        }
    }

    // 滑過時才算說明：重置倒數跟著時間走
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        for (i, end) in ends.enumerated() where point.x <= end + 4 { return groups[i].tip }
        return ""
    }

    /// 測試用（TestHarness --usage-strip-probe）：第一行是字級、顯示幾組、沒有長條的裸 NSView 有幾個（應為 0）；之後每組一行、每欄一行
    func probeLines() -> [String] {
        let bars = subviews.filter { type(of: $0) == NSView.self }.count
        var out = ["tier=\(tier.name) shown=\(shown)/\(cells.count) bars=\(bars)"]
        if let first = cells.first?.columns.first {
            out.append("rowsY labelY=\(first.label.frame.minY) valueY=\(first.value.frame.minY) labelPt=\(tier.label.pointSize) valuePt=\(tier.value.pointSize)")
        }
        for (i, c) in cells.enumerated() {
            out.append("group key=\(groups[i].key) shown=\(i < shown ? 1 : 0)")
            for col in c.columns { out.append("  col label=\(col.labelText) value=\(col.valueText) level=\(col.level)") }
        }
        return out
    }
}

private final class KeyGuardSuppressionCollector {
    private let lock = NSLock()
    private var rows: [(rule: String, feature: String, count: Int)] = []
    func append(rule: String, feature: String, count: Int) {
        lock.lock(); rows.append((rule, feature, count)); lock.unlock()
    }
    func snapshot() -> [(rule: String, feature: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        return rows
    }
}

private final class KeyGuardScanCancellation {
    private let lock = NSLock()
    private var cancelledStorage = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledStorage }
    func cancel() { lock.lock(); cancelledStorage = true; lock.unlock() }
}

private struct KeyGuardScanOutput {
    let textHits: [KeyHit]
    let files: [KeyGuardFileScanResult]
    let suppressionRows: [(rule: String, feature: String, count: Int)]
    let elapsedMilliseconds: Int
    let failed: Bool
}

final class ChatInputBar: NSView {
    /// 只供 --state-dir 隔離測試注入掃描延遲與失敗；正式程序不設定。
    static var keyGuardTestScanDelay: TimeInterval = 0
    static var keyGuardTestForceScanFailure = false

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
    private let scroll = OverlayOnlyScrollView()
    private let box = InputBoxView()
    /// 卡片下面那一行：上下文大小；右邊留給之後的標籤（例如「明天 06:00 交接」）
    /// 不設 private：測試掛鉤（--usage-strip-probe）要讀底部列的用量
    let ctxStrip = ContextStrip()
    /// 底部列兩行（用量的小字標籤＋數字）：24 點；原本一行 16 點
    static let ctxRowH: CGFloat = 24
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
    /// 專用安全貼上金鑰入口（面板不顯示明文，成功只插入佔位字）。
    private let keyButton = BlueCircleButton()
    private var keyPanel: NSPanel?
    private var keySecret = ""
    private var keyServicePopup: NSPopUpButton?
    private var keyErrorLabel: NSTextField?
    private var keyTextView: NSTextView?
    private var keyTextViewDelegate: KeyPasteTextViewDelegate?
    /// 橘色收納鈕：在藍色資料夾鈕左邊，樣式一樣；按下去由 ChatPane 給選單（瀏覽器格的比對、回報、匯出）
    let toolsButton = BlueCircleButton()
    var onToolsButton: ((NSView) -> Void)?
    /// 全域浮動終端機與關聯圖切換入口；放在資料夾按鈕左側。
    let terminalButton = NSButton()
    let graphButton = NSButton()
    var onTerminalButton: (() -> Void)?
    var onGraphButton: (() -> Void)?
    /// 有卡片的檔案（拖進來或貼上的路徑）；文字裡的路徑被刪掉，卡片也跟著拿掉
    private var files: [URL] = []
    private(set) var isKeyScanInProgress = false
    private var keyScanGeneration: UInt64 = 0
    private var keyScanContentVersion: UInt64 = 0
    private var keyScanCancellation: KeyGuardScanCancellation?
    private var keyScanHint: String?
    private var keyScanHintTimer: Timer?
    private(set) var keyGuardScanStartCount = 0
    private(set) var keyGuardLastScanElapsedMillisecondsForTest = 0
    var keyGuardScanContentVersionForTest: UInt64 { keyScanContentVersion }
    var keyGuardScanHintForTest: String? { keyScanHint }
    var keyGuardHintVisibleForTest: Bool { !bangHint.isHidden }
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
    var onSelectBypassMode: (() -> Void)?
    /// no：這則訊息裡的第幾張圖，文字裡用 [Image #no] 標出位置（跟 Claude Code 一樣）
    private var attachments: [(data: Data, mediaType: String, image: NSImage, no: Int, edited: Bool)] = []
    var draftImages: [DraftPersistence.Image] {
        attachments.map { DraftPersistence.Image(data: $0.data, mediaType: $0.mediaType, no: $0.no, edited: $0.edited) }
    }
    private var nextImageNo = 1
    private static let maxImageNo = Int.max - 1
    private func allocateImageNo() -> Int? {
        guard nextImageNo > 0, nextImageNo <= Self.maxImageNo else { return nil }
        defer { nextImageNo += 1 }
        return nextImageNo
    }
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
            if oldValue && !busy { lastSent = nil; lastSentQuotes = [] }   // 這輪做完了，⌃ C 就不再放回
            updateButton(); needsLayout = true
        }
    }
    /// 上一則送出的字和圖：這輪還沒做完時按 ⌃ C，停下來並放回輸入框，不用重打
    /// 每次送出都留一份（不管當時 Claude 忙不忙）：送出失敗要放回來用。lastSent 在忙的時候是 nil（排隊的那則停下來之後還是會送，不放回），不能拿來還原送不出去的
    private var lastAttempt: (text: String, attachments: [(data: Data, mediaType: String, image: NSImage, no: Int, edited: Bool)], nextNo: Int, files: [URL])?
    private var lastSent: (text: String, attachments: [(data: Data, mediaType: String, image: NSImage, no: Int, edited: Bool)], nextNo: Int, files: [URL])?
    /// 送出時一起帶走的引用（ChatPane 送出成功才清掉它們），⌃ C／送出失敗放回輸入框時要一起還原，不然引用的內容會遺失
    var quotesProvider: () -> [MessageQuote] = { [] }
    var onRestoreQuotes: ([MessageQuote]) -> Void = { _ in }
    private var lastAttemptQuotes: [MessageQuote] = []
    private var lastSentQuotes: [MessageQuote] = []
    var suggestion: String? { get { textView.suggestion } set { textView.suggestion = newValue } }
    /// 鎖住輸入（對話正在別處進行）：顯示說明和一顆按鈕
    private let lockView = NSView()
    private let lockLabel = NSTextField(wrappingLabelWithString: "")
    private let lockButton = NSButton()
    private var lockAction: (() -> Void)?
    var isLocked: Bool { !lockView.isHidden }
    private let maxLines: CGFloat = 12
    private struct TextMeasureCache {
        let contentVersion: UInt64
        let textViewWidth: CGFloat
        let containerWidth: CGFloat
        let fontName: String
        let fontSize: CGFloat
        let baselineOffset: CGFloat
        let insetHeight: CGFloat
        let lineFragmentPadding: CGFloat
        let result: (height: CGFloat, overflow: Bool)
    }
    private var textMeasureCache: TextMeasureCache?

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
        textView.applyInputFont(.systemFont(ofSize: 15))
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
        textView.onPasteShouldBeRejected = { [weak self] in
            guard let self else { return true }
            if self.isKeyScanInProgress { return self.rejectMutationDuringKeyScan() }
            if !self.lockView.isHidden {
                self.showKeyScanMessage(self.lockLabel.stringValue.isEmpty ? L("這格目前不能修改") : self.lockLabel.stringValue)
                return true
            }
            return false
        }
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
            self?.stopFromInput() ?? false
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
        modeButton.toolTip = PermissionMode.tooltip(engine: permissionEngine, mode: permissionModeValue)
        modeButton.menu = NSMenu()
        let bypass = NSMenuItem(title: L("⏵⏵ 全部不問"), action: #selector(selectBypassMode), keyEquivalent: "")
        bypass.target = self; bypass.attributedTitle = NSAttributedString(string: bypass.title, attributes: [.foregroundColor: NSColor.systemRed])
        modeButton.menu?.addItem(bypass)
        box.addSubview(modeButton)
        statusDivider.wantsLayer = true
        box.addSubview(statusDivider)
        // 藍色圓鈕＋白色資料夾
        uploadButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: L("上傳檔案"))?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        uploadButton.target = self
        uploadButton.action = #selector(uploadPressed)
        uploadButton.toolTip = L("上傳檔案（可以選好幾個檔案或資料夾）")
        box.addSubview(uploadButton)
        keyButton.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: L("貼上 API 金鑰（不會進聊天紀錄）"))?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        keyButton.target = self
        keyButton.action = #selector(keyPressed)
        keyButton.toolTip = L("貼上 API 金鑰（不會進聊天紀錄）")
        box.addSubview(keyButton)
        toolsButton.baseColor = .systemOrange
        toolsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L("瀏覽器格的工具"))?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        toolsButton.target = self
        toolsButton.action = #selector(toolsPressed)
        toolsButton.toolTip = L("瀏覽器格的工具（請 Claude 比對、回報、匯出）")
        box.addSubview(toolsButton)
        configureUtilityButton(terminalButton, symbol: "terminal", label: "浮動終端機", shortcut: "F5", tooltip: "浮動終端機（F5）", identifier: "chatInputBar.terminalButton", action: #selector(terminalPressed))
        configureUtilityButton(graphButton, symbol: "point.3.connected.trianglepath.dotted", label: "關聯圖", shortcut: "F6", tooltip: "關聯圖（F6）", identifier: "chatInputBar.graphButton", action: #selector(graphPressed))
        uploadButton.setAccessibilityIdentifier("chatInputBar.folderButton")
        box.addSubview(terminalButton)
        box.addSubview(graphButton)
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

    private func configureUtilityButton(_ button: NSButton, symbol: String, label: LString, shortcut: String, tooltip: LString, identifier: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L(label))?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = L(tooltip)
        button.setAccessibilityLabel(L(label))
        button.setAccessibilityIdentifier(identifier)
    }

    @objc private func terminalPressed() { onTerminalButton?() }
    @objc private func graphPressed() { onGraphButton?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { invalidatePendingKeyGuardScan() }
        keyPanel?.close()
        keyPanel = nil; keyTextView?.string = ""; keyTextView = nil; keyTextViewDelegate = nil; keySecret = ""
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyTheme(_ pal: Palette, mono: NSFont) {
        let dark = pal.bg.usingColorSpace(.sRGB).map { $0.brightnessComponent < 0.5 } ?? true
        box.layer?.backgroundColor = (dark ? pal.bg.blended(withFraction: 0.07, of: .white) : pal.bg.blended(withFraction: 0.04, of: .black))?.cgColor
        themeBorder = dark ? pal.fg.withAlphaComponent(0.15).cgColor : Theme.lightSeparatorColor.cgColor
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
    private var permissionEngine: PermissionMode.Engine = .claude
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
            modeButton.attributedTitle = NSAttributedString(string: PermissionMode.label(newValue, engine: permissionEngine), attributes: [.font: NSFont.systemFont(ofSize: 12 * UIScale.shared.f, weight: .medium), .foregroundColor: color])
            modeButton.toolTip = PermissionMode.tooltip(engine: permissionEngine, mode: newValue)
            needsLayout = true
        }
    }
    var permissionEngineForHint: PermissionMode.Engine {
        get { permissionEngine }
        set {
            permissionEngine = newValue
            permissionMode = permissionModeValue      // 換引擎時 auto 的字樣會變（Copilot／agy 顯示「全都不問」），整顆重畫
        }
    }
    /// 測試用：按鈕現在顯示的字與提示
    var permissionButtonText: String { modeButton.attributedTitle.string }
    var permissionButtonTip: String { modeButton.toolTip ?? "" }
    @objc private func cycleModePressed() { onCycleMode?() }
    @objc private func selectBypassMode() { onSelectBypassMode?() }

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

    @objc private func keyPressed() { guard !rejectMutationDuringKeyScan() else { return }; showKeyPanel() }

    private func showKeyPanel() {
        guard keyPanel == nil else { keyPanel?.makeKeyAndOrderFront(nil); return }
        let w: CGFloat = 330, h: CGFloat = 210
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L("安全貼上 API 金鑰")
        panel.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let label = NSTextField(labelWithString: L("內容只會存進鑰匙圈，不會進聊天紀錄。"))
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 16, y: 170, width: w - 32, height: 18); root.addSubview(label)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 92, width: w - 32, height: 70))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .clear
        editor.insertionPointColor = .labelColor
        editor.selectedTextAttributes = [.foregroundColor: NSColor.clear, .backgroundColor: NSColor.selectedTextBackgroundColor]
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        let delegate = KeyPasteTextViewDelegate { [weak self] secret in
            guard let self else { return }
            self.keySecret = KeyVaultPaste.clean(secret)
            let guessed = KeyService.guess(self.keySecret)
            if let i = KeyService.everything.firstIndex(where: { $0.id == guessed.id }) { self.keyServicePopup?.selectItem(at: i) }
            editor.textStorage?.addAttributes([.foregroundColor: NSColor.clear], range: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
        }
        editor.delegate = delegate
        keyTextViewDelegate = delegate
        keyTextView = editor
        scroll.documentView = editor; root.addSubview(scroll)
        let popup = NSPopUpButton(frame: NSRect(x: 16, y: 54, width: 190, height: 26), pullsDown: false)
        popup.addItems(withTitles: KeyService.everything.map(\.name))
        let guessed = KeyService.find("other")!
        popup.selectItem(at: KeyService.everything.firstIndex(where: { $0.id == guessed.id }) ?? KeyService.everything.count - 1)
        root.addSubview(popup); keyServicePopup = popup
        let error = NSTextField(labelWithString: "")
        error.textColor = .systemRed; error.font = .systemFont(ofSize: 11)
        error.frame = NSRect(x: 16, y: 25, width: 190, height: 20); root.addSubview(error); keyErrorLabel = error
        let save = NSButton(title: L("存進鑰匙圈"), target: self, action: #selector(saveKeyFromPanel))
        save.bezelStyle = .rounded; save.frame = NSRect(x: w - 120, y: 48, width: 104, height: 30); root.addSubview(save)
        panel.contentView = root
        keySecret = ""
        keyPanel = panel
        if let win = window {
            let p = convert(NSPoint(x: keyButton.frame.midX, y: keyButton.frame.maxY), to: nil)
            let screen = win.convertPoint(toScreen: p)
            panel.setFrameTopLeftPoint(NSPoint(x: screen.x - w / 2, y: screen.y + 8))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
    }

    @objc private func saveKeyFromPanel() {
        guard !rejectMutationDuringKeyScan() else { return }
        guard let popup = keyServicePopup else { return }
        let item = KeyService.everything[popup.indexOfSelectedItem]
        let result = KeyVaultPaste.save(keySecret, service: KeyVault.service(item.id))
        if let error = result.error { keyErrorLabel?.stringValue = error; return }
        if let placeholder = result.placeholder {
            textView.insertText(placeholder, replacementRange: textView.selectedRange())
            textView.didChangeText(); onPendingInputChange?()
            keyTextView?.string = ""; keyTextView = nil
            keyPanel?.close(); keyPanel = nil; keySecret = ""
        }
    }

    /// 整體文字大小
    /// 打字的字型：nil＝系統字型；有給就用它（跟終端機一樣），大小照終端機點數換算
    var textFont: NSFont? { didSet { if textFont != oldValue { setFontScale(lastScale) } } }
    private var lastScale: CGFloat = 1
    func setFontScale(_ f: CGFloat) {
        lastScale = f
        if let base = textFont {
            textView.applyInputFont(NSFont(descriptor: base.fontDescriptor, size: base.pointSize / CGFloat(UIScale.defaultFactor) * f) ?? .systemFont(ofSize: 15 * f))
        } else {
            textView.applyInputFont(.systemFont(ofSize: 15 * f))
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
        let font = textView.font ?? .systemFont(ofSize: 15)
        let textViewWidth = textView.frame.width
        let containerWidth = tc.containerSize.width
        let insetHeight = textView.textContainerInset.height
        let lineFragmentPadding = tc.lineFragmentPadding
        if let cache = textMeasureCache,
           cache.contentVersion == keyScanContentVersion,
           abs(cache.textViewWidth - textViewWidth) <= 0.5,
           abs(cache.containerWidth - containerWidth) <= 0.5,
           cache.fontName == font.fontName,
           abs(cache.fontSize - font.pointSize) <= 0.01,
           abs(cache.baselineOffset - textView.inputBaselineOffset) <= 0.01,
           abs(cache.insetHeight - insetHeight) <= 0.01,
           abs(cache.lineFragmentPadding - lineFragmentPadding) <= 0.01 {
            return cache.result
        }
        lm.ensureLayout(for: tc)
        // 行高取「字型預設」和「實際排出來最高的一行」較大者：中文會換成蘋方，行比英文字型高，
        // 只用預設行高的話打中文不到 12 行就開始捲、頂端切半行（agy Argon 11/6）
        var line = lm.defaultLineHeight(for: font)
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
        let result = (height: min(h, cap), overflow: h > cap + 1)
        textMeasureCache = TextMeasureCache(contentVersion: keyScanContentVersion,
                                            textViewWidth: textViewWidth,
                                            containerWidth: containerWidth,
                                            fontName: font.fontName,
                                            fontSize: font.pointSize,
                                            baselineOffset: textView.inputBaselineOffset,
                                            insetHeight: insetHeight,
                                            lineFragmentPadding: lineFragmentPadding,
                                            result: result)
        return result
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
        chipScroll.scrollerStyle = s; scroll.forceStyleForTest(s)   // 正式卡片列永遠 overlay；此探針只模擬文字區的系統樣式
    }
    /// 測試用：卡片列的位置（卡片捲動區、裡面那排卡片、可視範圍、分隔線、文字區）
    var chipMetricsForTest: String {
        let c = chipScroll.contentView
        return "chipScroll=\(chipScroll.frame) style=\(chipScroll.scrollerStyle == .overlay ? "overlay" : "legacy") hScroller=\(chipScroll.hasHorizontalScroller) clip=\(c.frame) clipBounds=\(c.bounds) chips=\(chips.frame) divider=\(chipDivider.frame) textScroll=\(scroll.frame) box=\(box.frame) bar=\(frame) fitting=\(fittingHeight(width: frame.width))"
    }
    var metricsForTest: String { let m = measureText(); return "boxH=\(Int(m.height)) overflow=\(m.overflow) scrollH=\(Int(scroll.frame.height)) textW=\(Int(textView.frame.width)) scrollW=\(Int(scroll.frame.width)) atBottom=\(abs(scroll.contentView.bounds.maxY - textView.frame.height) < 1.5)" }

    /// 用於 --dump-input-metrics：以 ChatInputBar 的分隔線和框內留白組成文字區容器，所有上下距離都相對這個容器量測。
    func inputMetricsForFontProbe(sample: String, inputLines: Int? = nil, inputAttachImage: Bool = false) -> [String: Any] {
        let input = inputLines.map { Array(repeating: "測試", count: $0).joined(separator: "\n") } ?? sample
        textView.string = input
        if let font = textView.font { textView.applyInputFont(font) }
        textChanged()
        textView.setSelectedRange(NSRange(location: (input as NSString).length, length: 0))
        if inputAttachImage {
            let image = NSImage(size: NSSize(width: 24, height: 24))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 20, height: 20)).fill()
            image.unlockFocus()
            // 走正式圖片附件路徑，讓文字標記、資料和縮圖列都由 attach 建立。
            attach(urls: [], images: [image])
        }
        // 附件列會增加輸入列總高；先按正式 fittingHeight 重排，讓文字區位於縮圖列下方。
        frame.size.height = fittingHeight(width: frame.width)
        needsLayout = true
        layout()

        guard let lm = textView.layoutManager, let tc = textView.textContainer, lm.numberOfGlyphs > 0 else { return [:] }
        lm.ensureLayout(for: tc)
        var actualGlyphRange = NSRange()
        let textRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let glyphRange = lm.glyphRange(forCharacterRange: textRange, actualCharacterRange: &actualGlyphRange)
        let caretGlyph = max(glyphRange.location, glyphRange.upperBound - 1)
        var caretLineRange = NSRange()
        let caretLine = lm.lineFragmentRect(forGlyphAt: caretGlyph, effectiveRange: &caretLineRange)
        let glyphRect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let textRectInTextView = glyphRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let lineRectInTextView = caretLine.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        var lineUsedRange = NSRange()
        let lineUsedRect = lm.lineFragmentUsedRect(forGlyphAt: caretGlyph, effectiveRange: &lineUsedRange)
        let lineUsedRectInTextView = lineUsedRect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let usedRectInTextView = lm.usedRect(for: tc).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let font = textView.font ?? .systemFont(ofSize: 15)
        let fontBaselineOffset = textView.inputBaselineOffset
        let fontBands = probeFontBands(in: lineRectInTextView, font: font, baselineOffset: fontBaselineOffset, isFlipped: textView.isFlipped)
        let textRectInScroll = textView.convert(textRectInTextView, to: scroll)
        let textGaps = verticalGaps(textRectInScroll, in: scroll)
        let inputContainer = textAreaContainerRectInBox()
        let inputContainerTop = containerTop(inputContainer)
        let inputContainerBottom = containerBottom(inputContainer)
        let textRectInBox = textView.convert(textRectInTextView, to: box)
        let containerTextGaps = verticalGaps(textRectInBox, within: inputContainer, in: box)
        let scrollRectInBox = scroll.convert(scroll.bounds, to: box)
        let textViewRectInBox = textView.convert(textView.bounds, to: box)
        let probeContainerFrame = box.convert(inputContainer, to: self)
        let probeCardFrame = box.convert(box.bounds, to: self)
        let probeThumbnailFrame = chipScroll.convert(chipScroll.bounds, to: self)
        let probeThumbnailContentFrame = chips.convert(chips.bounds, to: self)
        let probeLowerDividerFrame = statusDivider.convert(statusDivider.bounds, to: self)
        let probeUpperDividerFrame = chips.isHidden ? nil : chipDivider.convert(chipDivider.bounds, to: self)
        let probeScrollFrame = scroll.convert(scroll.bounds, to: self)
        let probeScrollContentFrame = scroll.contentView.convert(scroll.contentView.bounds, to: self)
        let probeTextViewFrame = textView.convert(textView.bounds, to: self)
        let probeTextGlyphFrame = textView.convert(textRectInTextView, to: self)
        let probeTextLineFrame = textView.convert(lineRectInTextView, to: self)
        let probeTextLineUsedFrame = textView.convert(lineUsedRectInTextView, to: self)
        let probeTextUsedFrame = textView.convert(usedRectInTextView, to: self)
        let probeTextCapBandFrame = textView.convert(fontBands.cap, to: self)
        let probeTextXHeightBandFrame = textView.convert(fontBands.xHeight, to: self)
        let probeGlyphGaps = verticalGaps(probeTextGlyphFrame, within: probeContainerFrame, in: self)
        let probeLineGaps = verticalGaps(probeTextLineFrame, within: probeContainerFrame, in: self)
        let probeCapGaps = verticalGaps(probeTextCapBandFrame, within: probeContainerFrame, in: self)
        let probeXHeightGaps = verticalGaps(probeTextXHeightBandFrame, within: probeContainerFrame, in: self)

        let caretHeight = min(caretLine.height, max(0, font.ascender - font.descender))
        let caretRectInTextView = textView.centeredCaretRectForInput(NSRect(x: lineRectInTextView.minX, y: lineRectInTextView.minY + (caretLine.height - caretHeight) / 2, width: caretLine.width, height: caretHeight))
        let caretRectInScroll = textView.convert(caretRectInTextView, to: scroll)
        let caretGaps = verticalGaps(caretRectInScroll, in: scroll)
        let caretRectInBox = textView.convert(caretRectInTextView, to: box)
        let containerCaretGaps = verticalGaps(caretRectInBox, within: inputContainer, in: box)

        let inputBoxHeight = Double(scrollRectInBox.height)
        let chipsRowHeight = inputAttachImage ? Double(Self.chipRow) : nil
        let capped = scroll.hasVerticalScroller
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        frame.size.height = fittingHeight(width: frame.width)
        needsLayout = true
        layout()
        let placeholderGaps: (top: CGFloat, bottom: CGFloat)
        let placeholderContainer: NSRect
        let placeholderContainerGaps: (top: CGFloat, bottom: CGFloat)
        var probePlaceholderLineFrame: NSRect?
        var probePlaceholderDrawFrame: NSRect?
        var probePlaceholderCapFrame: NSRect?
        var probePlaceholderXHeightFrame: NSRect?
        var probePlaceholderCapGaps: (top: CGFloat, bottom: CGFloat)?
        var probePlaceholderXHeightGaps: (top: CGFloat, bottom: CGFloat)?
        if let drawing = textView.placeholderDrawing() {
            // 舊欄位保留以字型外框估算的間距；新欄位另用 cap/x-height 排除 g/j/p 下伸。
            let font = textView.font ?? .systemFont(ofSize: 15)
            let placeholderHeight = min(drawing.rect.height, font.boundingRectForFont.height)
            let placeholderGlyphRect = NSRect(x: drawing.rect.minX,
                                              y: drawing.rect.midY - placeholderHeight / 2,
                                              width: drawing.rect.width,
                                              height: placeholderHeight)
            let placeholderRectInScroll = textView.convert(placeholderGlyphRect, to: scroll)
            placeholderGaps = verticalGaps(placeholderRectInScroll, in: scroll)
            placeholderContainer = textAreaContainerRectInBox()
            let placeholderRectInBox = textView.convert(placeholderGlyphRect, to: box)
            placeholderContainerGaps = verticalGaps(placeholderRectInBox, within: placeholderContainer, in: box)
            let placeholderBands = probeFontBands(in: drawing.rect, font: font, baselineOffset: textView.inputBaselineOffset, isFlipped: textView.isFlipped)
            let placeholderLineInProbeSpace = textView.convert(drawing.rect, to: self)
            let placeholderCapInProbeSpace = textView.convert(placeholderBands.cap, to: self)
            let placeholderXHeightInProbeSpace = textView.convert(placeholderBands.xHeight, to: self)
            probePlaceholderLineFrame = placeholderLineInProbeSpace
            probePlaceholderDrawFrame = placeholderLineInProbeSpace
            probePlaceholderCapFrame = placeholderCapInProbeSpace
            probePlaceholderXHeightFrame = placeholderXHeightInProbeSpace
            let placeholderProbeContainer = box.convert(placeholderContainer, to: self)
            probePlaceholderCapGaps = verticalGaps(placeholderCapInProbeSpace, within: placeholderProbeContainer, in: self)
            probePlaceholderXHeightGaps = verticalGaps(placeholderXHeightInProbeSpace, within: placeholderProbeContainer, in: self)
        } else {
            placeholderGaps = (0, 0)
            placeholderContainer = .zero
            placeholderContainerGaps = (0, 0)
            probePlaceholderLineFrame = nil
            probePlaceholderDrawFrame = nil
            probePlaceholderCapFrame = nil
            probePlaceholderXHeightFrame = nil
            probePlaceholderCapGaps = nil
            probePlaceholderXHeightGaps = nil
        }

        var metrics: [String: Any] = [
            "boxHeight": inputBoxHeight,
            "lineHeight": Double(caretLine.height),
            "textTopGap": Double(textGaps.top),
            "textBottomGap": Double(textGaps.bottom),
            "placeholderTopGap": Double(placeholderGaps.top),
            "placeholderBottomGap": Double(placeholderGaps.bottom),
            "caretTopGap": Double(caretGaps.top),
            "caretBottomGap": Double(caretGaps.bottom),
            // 舊欄位維持 box 局部座標與名稱；容器邊界改成畫面上的分隔線中心或卡片外框上緣。
            "containerHeight": Double(inputContainer.height),
            "containerTop": Double(inputContainerTop),
            "containerBottom": Double(inputContainerBottom),
            "containerUnit": "pt",
            "containerCoordinates": "box 內局部座標",
            "containerTextTopGap": Double(containerTextGaps.top),
            "containerTextBottomGap": Double(containerTextGaps.bottom),
            "containerCaretTopGap": Double(containerCaretGaps.top),
            "containerCaretBottomGap": Double(containerCaretGaps.bottom),
            "containerPlaceholderTopGap": Double(placeholderContainerGaps.top),
            "containerPlaceholderBottomGap": Double(placeholderContainerGaps.bottom),
            "placeholderContainerHeight": Double(placeholderContainer.height),
            "placeholderContainerTop": Double(containerTop(placeholderContainer)),
            "placeholderContainerBottom": Double(containerBottom(placeholderContainer)),
            // 保留文字捲動框與 NSTextView 的 frame，方便辨認容器餘量落在何處。
            "textScrollHeight": Double(scrollRectInBox.height),
            "textViewHeight": Double(textViewRectInBox.height),
            "textScrollTop": Double(box.isFlipped ? scrollRectInBox.minY : scrollRectInBox.maxY),
            "textScrollBottom": Double(box.isFlipped ? scrollRectInBox.maxY : scrollRectInBox.minY),
            "textViewTop": Double(box.isFlipped ? textViewRectInBox.minY : textViewRectInBox.maxY),
            "textViewBottom": Double(box.isFlipped ? textViewRectInBox.maxY : textViewRectInBox.minY),
            // 新欄位一律用 ChatInputBar 這個共同祖先座標（pt）；這個離屏探針沒有 window。
            "probeCoordinateSpace": "ChatInputBar 共同祖先座標",
            "probeCoordinateUnit": "pt",
            "probeRootIsFlipped": isFlipped,
            "probeTextViewIsFlipped": textView.isFlipped,
            "probeCardOuterFrame": probeRectMetrics(probeCardFrame),
            "probeThumbnailRowFrame": probeRectMetrics(probeThumbnailFrame),
            "probeThumbnailContentFrame": probeRectMetrics(probeThumbnailContentFrame),
            "probeThumbnailRowVisible": !chipScroll.isHidden,
            "probeUpperDividerVisible": probeUpperDividerFrame != nil,
            "probeLowerDividerFrame": probeRectMetrics(probeLowerDividerFrame),
            "probeScrollFrame": probeRectMetrics(probeScrollFrame),
            "probeScrollContentFrame": probeRectMetrics(probeScrollContentFrame),
            "probeTextViewFrame": probeRectMetrics(probeTextViewFrame),
            "probeVisibleContainerFrame": probeRectMetrics(probeContainerFrame),
            "probeTextLineFrame": probeRectMetrics(probeTextLineFrame),
            "probeTextLineUsedFrame": probeRectMetrics(probeTextLineUsedFrame),
            "probeTextGlyphBounds": probeRectMetrics(probeTextGlyphFrame),
            "probeTextUsedBounds": probeRectMetrics(probeTextUsedFrame),
            "probeTextCapBandFrame": probeRectMetrics(probeTextCapBandFrame),
            "probeTextXHeightBandFrame": probeRectMetrics(probeTextXHeightBandFrame),
            "probeTextLineTopGap": Double(probeLineGaps.top),
            "probeTextLineBottomGap": Double(probeLineGaps.bottom),
            "probeTextGlyphTopGap": Double(probeGlyphGaps.top),
            "probeTextGlyphBottomGap": Double(probeGlyphGaps.bottom),
            "probeTextCapBandTopGap": Double(probeCapGaps.top),
            "probeTextCapBandBottomGap": Double(probeCapGaps.bottom),
            "probeTextXHeightBandTopGap": Double(probeXHeightGaps.top),
            "probeTextXHeightBandBottomGap": Double(probeXHeightGaps.bottom),
            "probeBaselineOffset": Double(fontBaselineOffset),
            "probeFontAscender": Double(font.ascender),
            "probeFontDescender": Double(font.descender),
            "probeFontCapHeight": Double(font.capHeight),
            "probeFontXHeight": Double(font.xHeight),
            "probeTextContainerInsetWidth": Double(textView.textContainerInset.width),
            "probeTextContainerInsetHeight": Double(textView.textContainerInset.height),
            "probeTextViewIsVerticallyResizable": textView.isVerticallyResizable,
            "probeTextViewFrameHeight": Double(probeTextViewFrame.height),
            "probeScrollFrameHeight": Double(probeScrollFrame.height)
        ]
        if let probeUpperDividerFrame {
            metrics["probeUpperDividerFrame"] = probeRectMetrics(probeUpperDividerFrame)
        } else {
            metrics["probeUpperDividerFrame"] = NSNull()
        }
        if let probePlaceholderLineFrame, let probePlaceholderDrawFrame,
           let probePlaceholderCapFrame, let probePlaceholderXHeightFrame,
           let probePlaceholderCapGaps, let probePlaceholderXHeightGaps {
            metrics["probePlaceholderLineFrame"] = probeRectMetrics(probePlaceholderLineFrame)
            metrics["probePlaceholderDrawingFrame"] = probeRectMetrics(probePlaceholderDrawFrame)
            metrics["probePlaceholderCapBandFrame"] = probeRectMetrics(probePlaceholderCapFrame)
            metrics["probePlaceholderXHeightBandFrame"] = probeRectMetrics(probePlaceholderXHeightFrame)
            metrics["probePlaceholderCapBandTopGap"] = Double(probePlaceholderCapGaps.top)
            metrics["probePlaceholderCapBandBottomGap"] = Double(probePlaceholderCapGaps.bottom)
            metrics["probePlaceholderXHeightBandTopGap"] = Double(probePlaceholderXHeightGaps.top)
            metrics["probePlaceholderXHeightBandBottomGap"] = Double(probePlaceholderXHeightGaps.bottom)
        }
        if let inputLines {
            metrics["lineCount"] = inputLines
            metrics["capped"] = capped
        }
        if let chipsRowHeight {
            metrics["attached"] = true
            metrics["chipsRowHeight"] = chipsRowHeight
            metrics["chipsRowHeightUnit"] = "pt"
            metrics["chipsRowHeightMethod"] = "ChatInputBar.fittingHeight 預留高度：AttachmentChip.height + 24pt 列間距，不等於卡片可視高度"
            metrics["chipsVisibleHeight"] = Double(chipScroll.frame.height)
        }
        return metrics
    }

    /// 可見文字容器，座標在 box 內：附件時取兩條分隔線中心；無附件用卡片上緣（! 提示佔位時用提示下緣）和下分隔線中心。
    private func textAreaContainerRectInBox() -> NSRect {
        let status = statusDivider.convert(statusDivider.bounds, to: box)
        let bottomEdge = status.midY
        let topEdge: CGFloat
        if chips.isHidden {
            if bangCount > 0 {
                let bang = bangNote.convert(bangNote.bounds, to: box)
                topEdge = box.isFlipped ? bang.maxY : bang.minY
            } else {
                topEdge = box.isFlipped ? box.bounds.minY : box.bounds.maxY
            }
        } else {
            let divider = chipDivider.convert(chipDivider.bounds, to: box)
            topEdge = divider.midY
        }
        let low = min(topEdge, bottomEdge)
        let high = max(topEdge, bottomEdge)
        return NSRect(x: box.bounds.minX, y: low, width: box.bounds.width, height: max(0, high - low))
    }

    private func containerTop(_ rect: NSRect) -> CGFloat { box.isFlipped ? rect.minY : rect.maxY }
    private func containerBottom(_ rect: NSRect) -> CGFloat { box.isFlipped ? rect.maxY : rect.minY }

    private func probeRectMetrics(_ rect: NSRect) -> [String: Double] {
        ["x": Double(rect.origin.x), "y": Double(rect.origin.y),
         "width": Double(rect.width), "height": Double(rect.height),
         "minX": Double(rect.minX), "maxX": Double(rect.maxX),
         "minY": Double(rect.minY), "maxY": Double(rect.maxY)]
    }

    /// 將字型 ascender/descender 範圍置於行框中央，再用 cap/x-height 估算不含下伸部的墨跡區。
    private func probeFontBands(in lineRect: NSRect, font: NSFont, baselineOffset: CGFloat, isFlipped: Bool) -> (cap: NSRect, xHeight: NSRect) {
        let fontHeight = font.ascender - font.descender
        let inset = (lineRect.height - fontHeight) / 2
        let baseline = isFlipped
            ? lineRect.minY + inset + font.ascender - baselineOffset
            : lineRect.minY + inset - font.descender + baselineOffset
        let capY = isFlipped ? baseline - font.capHeight : baseline
        let xHeightY = isFlipped ? baseline - font.xHeight : baseline
        return (NSRect(x: lineRect.minX, y: capY, width: lineRect.width, height: max(0, font.capHeight)),
                NSRect(x: lineRect.minX, y: xHeightY, width: lineRect.width, height: max(0, font.xHeight)))
    }

    private func verticalGaps(_ rect: NSRect, within container: NSRect, in view: NSView) -> (top: CGFloat, bottom: CGFloat) {
        if view.isFlipped {
            return (rect.minY - container.minY, container.maxY - rect.maxY)
        }
        return (container.maxY - rect.maxY, rect.minY - container.minY)
    }

    private func verticalGaps(_ rect: NSRect, in view: NSView) -> (top: CGFloat, bottom: CGFloat) {
        if view.isFlipped {
            return (rect.minY - view.bounds.minY, view.bounds.maxY - rect.maxY)
        }
        return (view.bounds.maxY - rect.maxY, rect.minY - view.bounds.minY)
    }

    /// 下面那排狀態列（權限模式、模型、送出鍵）的高度：打字在上面，字不會碰到這一排
    private static let statusRow: CGFloat = 35   // 底排 28 ＋ 分隔線和按鈕之間留 7

    /// fittingHeight 為縮圖列預留的總高度：可視卡片高度再加 24pt 列間距。
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
        // 先定好 viewport 寬度與浮出式捲軸，再依實際 content width 設文字檢視一次。
        // 若先設 inner.width、稍後再設 contentSize.width，Legacy scroller 切換時會讓超長草稿整份重排兩次。
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if abs(scroll.frame.width - inner.width) > 0.5 {
            var viewport = scroll.frame
            viewport.size.width = inner.width
            scroll.frame = viewport
        }
        let textWidth = scroll.contentSize.width
        if abs(textView.frame.width - textWidth) > 0.5 {
            textView.frame.size.width = textWidth
            superview?.needsLayout = true
        }
        textView.updateBaselineOffsetForLineCount()
        let (th, overflow) = measureText()
        // 捲軸：字超過最多行數才有，而且一律用浮出來的樣式。
        // 系統設成「一直顯示捲軸」（接滑鼠時）的話，行高差幾點就會在空的輸入框右邊畫出一條有外框的捲軸
        if scroll.hasVerticalScroller != overflow { scroll.hasVerticalScroller = overflow }
        // 兩行：最下面一排是狀態列（右邊依序 權限模式、模型、送出鍵），上面整條寬度都給打字
        let row = inner.minY
        sendButton.frame = NSRect(x: inner.maxX - 28, y: row, width: 28, height: 28)
        bangHint.stringValue = keyScanHint ?? L("執行指令（Enter 執行，結果會附給 Claude）")
        let showKeyScanHint = keyScanHint != nil || isKeyScanInProgress
        bangHint.isHidden = !showKeyScanHint && (!(inBang && lockView.isHidden) || !stopHint.isHidden)
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
        keyButton.isHidden = !lockView.isHidden || inner.width < 230
        keyButton.frame = NSRect(x: uploadButton.frame.minX - 26, y: row + 3, width: 22, height: 22)
        // 橘色收納鈕：接在資料夾鈕左邊；上傳鈕收起來（太窄）時一起收
        toolsButton.isHidden = !Prefs.shared.webFeaturesEnabled || keyButton.isHidden || inner.width < 230
        toolsButton.frame = NSRect(x: keyButton.frame.minX - 26, y: row + 3, width: 22, height: 22)
        terminalButton.isHidden = !lockView.isHidden || inner.width < 310 || uploadButton.isHidden
        terminalButton.frame = NSRect(x: uploadButton.frame.minX - 26, y: row + 3, width: 22, height: 22)
        graphButton.isHidden = terminalButton.isHidden
        graphButton.frame = NSRect(x: terminalButton.frame.minX - 26, y: row + 3, width: 22, height: 22)
        statusDivider.isHidden = !lockView.isHidden
        statusDivider.frame = NSRect(x: 14, y: row + Self.statusRow + 1, width: max(0, box.bounds.width - 28), height: 1)
        let textContainer = textAreaContainerRectInBox()
        let y = textContainer.midY - th / 2
        scroll.frame = NSRect(x: inner.minX, y: y, width: inner.width, height: th)
        let finalTextWidth = scroll.contentSize.width
        if abs(textView.frame.width - finalTextWidth) > 0.5 {
            textView.frame.size.width = finalTextWidth
            superview?.needsLayout = true
        }
        // NSTextView 比 viewport 矮時，NSClipView 會把 document 貼底；讓未溢出的文字檢視填滿 viewport，
        // textContainerInset 才會對稱地落在可視列高裡。溢出時保留文件高度與原有捲動行為。
        let documentHeight = overflow ? max(scroll.contentSize.height, textView.frame.height) : scroll.contentSize.height
        if abs(textView.frame.height - documentHeight) > 0.5 {
            textView.frame.size.height = documentHeight
        }
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
        guard !rejectMutationDuringKeyScan() else { return }
        let t = textView.string as NSString
        let lead = t.length == 0 || t.hasSuffix("\n") ? "" : "\n"
        textView.insertText(lead + s, replacementRange: NSRange(location: t.length, length: 0))
        textChanged()
    }

    @objc private func textChanged() {
        keyScanContentVersion &+= 1
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
        let name = isKeyScanInProgress ? "xmark.circle.fill" : (busy ? "stop.circle.fill" : "arrow.up.circle.fill")
        let label = isKeyScanInProgress ? L("取消掃描") : L(busy ? "停止" : "送出")
        sendButton.image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        sendButton.toolTip = isKeyScanInProgress ? L("取消金鑰掃描") : L(busy ? "停止（⌃ C）" : "送出（⌘ Enter）")
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && !hasQuotes
        sendButton.alphaValue = isKeyScanInProgress || busy || !empty ? 1 : 0.35
    }

    private func showKeyScanMessage(_ message: String?, seconds: TimeInterval = 2.5) {
        keyScanHintTimer?.invalidate()
        keyScanHint = message
        if let message, !isKeyScanInProgress {
            keyScanHintTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                guard let self, !self.isKeyScanInProgress else { return }
                self.keyScanHint = nil
                self.needsLayout = true
            }
        }
        needsLayout = true
    }

    private func beginKeyScan() -> (generation: UInt64, token: KeyGuardScanCancellation) {
        keyScanGeneration &+= 1
        let token = KeyGuardScanCancellation()
        keyScanCancellation = token
        isKeyScanInProgress = true
        textView.isEditable = false
        showKeyScanMessage(L("掃描中，暫時不能改"))
        updateButton()
        return (keyScanGeneration, token)
    }

    private func finishKeyScan(generation: UInt64, token: KeyGuardScanCancellation, message: String? = nil) {
        guard isKeyScanInProgress, keyScanGeneration == generation, keyScanCancellation === token else { return }
        isKeyScanInProgress = false
        keyScanCancellation = nil
        textView.isEditable = lockView.isHidden
        showKeyScanMessage(message)
        updateButton()
    }

    private func cancelKeyScan(message: String = L("掃描已取消，文字與附件保留")) {
        guard isKeyScanInProgress else { return }
        keyScanCancellation?.cancel()
        keyScanGeneration &+= 1
        isKeyScanInProgress = false
        keyScanCancellation = nil
        textView.isEditable = lockView.isHidden
        showKeyScanMessage(message)
        updateButton()
    }

    /// 關閉／移出聊天室時讓背景結果失效，避免回來後送出舊格的快照。
    func invalidatePendingKeyGuardScan() {
        cancelKeyScan(message: L("聊天室已切換，這次沒有送出；文字與附件保留"))
    }

    private func rejectMutationDuringKeyScan() -> Bool {
        guard isKeyScanInProgress else { return false }
        showKeyScanMessage(L("掃描中，暫時不能改"))
        return true
    }

    /// 非同步外部回呼帶回新附件／標註時，先作廢舊快照，再套用新內容；不能丟掉回呼結果。
    private func cancelKeyScanForExternalMutation() {
        guard isKeyScanInProgress else { return }
        cancelKeyScan(message: L("內容變了，已取消送出，請再按一次（內容在掃描中改變）"))
    }

    /// 模態確認期間也可能切換聊天室、取消掃描或收到外部內容；每次確認返回後重查同一輪掃描。
    private func validateKeyGuardScan(generation: UInt64, token: KeyGuardScanCancellation,
                                      startVersion: UInt64) -> Bool {
        guard isKeyScanInProgress, keyScanGeneration == generation,
              keyScanCancellation === token, !token.isCancelled else { return false }
        guard keyScanContentVersion == startVersion else {
            finishKeyScan(generation: generation, token: token,
                          message: L("內容在掃描中改變，這則沒有送出，請再按一次送出"))
            return false
        }
        return true
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
        textView.isEditable = text == nil && !isKeyScanInProgress
        scroll.isHidden = text != nil
        sendButton.isHidden = text != nil
        modelButton.isHidden = text != nil
        modeButton.isHidden = text != nil
        uploadButton.isHidden = text != nil
        terminalButton.isHidden = text != nil
        graphButton.isHidden = text != nil
        needsLayout = true
    }

    @objc private func lockPressed() { lockAction?() }

    /// 開檔案面板：獨立視窗（不是 sheet），能放大、能移動，大小記起來；選好的圖片變縮圖附件、其他檔案插入路徑（跟拖進來一樣）
    @objc func uploadPressed() {
        guard !rejectMutationDuringKeyScan() else { return }
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
        cancelKeyScanForExternalMutation()
        let imgs = urls.filter(ChatTextView.isImage)
        let others = urls.filter { !ChatTextView.isImage($0) }
        if !imgs.isEmpty { attach(urls: imgs, images: []) }
        if !others.isEmpty { insertPaths(others) }
        window?.makeFirstResponder(textView)
    }

    /// 從跨啟動草稿還原檔案卡片；檔案已不存在的路徑不會加入。
    /// 路徑文字已經在還原的草稿裡：只登記成卡片，不再插一次字，也不拿焦點（Astra 11/5 審查：原本會重複插入、搶焦點）
    func restoreFilePaths(_ paths: [String]) {
        guard !rejectMutationDuringKeyScan() else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        keyScanContentVersion &+= 1
        for u in urls where !files.contains(u) { files.append(u) }
        rebuildChips()
    }

    /// 草稿文字已有 [Image #n]：只還原附件與縮圖，保留編號、編輯狀態，不插字、不拿焦點。
    func restoreImages(_ images: [DraftPersistence.Image]) {
        guard !rejectMutationDuringKeyScan() else { return }
        keyScanContentVersion &+= 1
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

    @objc private func buttonPressed() {
        if isKeyScanInProgress { cancelKeyScan(); return }
        if busy { _ = stopFromInput() } else { send() }
    }

    /// Ctrl+C、停止按鈕與輸入框外快捷鍵共用同一條中斷路徑。
    @discardableResult
    func stopFromInput() -> Bool {
        if isKeyScanInProgress { cancelKeyScan(); return true }
        if bangRunning { onStopBang?(); return true }
        guard busy || lastSent != nil else { return false }
        interruptAndRestore()
        if window?.firstResponder !== textView { window?.makeFirstResponder(textView) }
        return true
    }

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
        guard !rejectMutationDuringKeyScan() else { return }
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
        guard !rejectMutationDuringKeyScan() else { return false }
        guard textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty, !hasQuotes else { return false }
        var t = text
        // 送出的字裡原本的 [Image #n] 記號已經對不上新的附件編號：全部拿掉，照新編號重放
        t = t.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        attachments = []
        nextImageNo = 1
        for im in images {
            guard let img = NSImage(data: im.data) else { continue }
            guard let no = allocateImageNo() else { break }
            attachments.append((im.data, im.mediaType, img, no, false))
            t += (t.isEmpty ? "" : " ") + Self.imageToken(no)
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
        lastSentQuotes = lastAttemptQuotes
        lastAttempt = nil
        restoreLastSent()
    }

    /// 剛送出的字放回輸入框（⌃ C；Gemini 連不上 Google 沒送出時也用）
    func restoreLastSent() {
        guard !rejectMutationDuringKeyScan() else { return }
        guard let last = lastSent else { return }
        // 輸入框已經有新打的字就不蓋掉它；暫存的留著（還沒放回去，不能丟）
        guard textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else { return }
        lastSent = nil
        let restoredQuotes = lastSentQuotes
        lastSentQuotes = []
        textView.string = last.text
        textView.undoManager?.removeAllActions()   // 直接換掉整段字不會進復原紀錄，舊紀錄套上來會錯位
        attachments = last.attachments
        nextImageNo = last.nextNo
        files = last.files
        rebuildChips()
        textChanged()
        if !restoredQuotes.isEmpty, !hasQuotes { onRestoreQuotes(restoredQuotes) }   // 還在（送出失敗）就不用補
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

    /// 測試掛鉤（--keyguard-test）：送出後在主執行緒 RunLoop 輪詢整段非同步流程，不用 semaphore。
    func testSend() {
        send()
        guard Thread.isMainThread else { return }
        let deadline = Date().addingTimeInterval(60)
        while isKeyScanInProgress, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// 隔離探針使用正式送出入口，並提供可取消／確認中的回呼。
    func startKeyGuardSendForTest(now: Bool = false) {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        send(now: now)
    }

    /// 隔離探針走 NSTextView 實際綁定的 Enter／⌘ Enter 送出閉包。
    func triggerKeyGuardKeyboardSendForTest(now: Bool = false) {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        if now { textView.onSendNow?() } else { textView.onSend?() }
    }

    func cancelKeyGuardSendForTest() {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        cancelKeyScan()
    }

    /// 隔離探針按真正的送出按鈕路徑；忙碌時也可驗證掃描期間按鈕只取消掃描。
    func pressKeyGuardSendButtonForTest() {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        buttonPressed()
    }

    /// 隔離探針在兩個獨立子情境間重設輸入列；不提供給正式執行個體。
    func resetKeyGuardInputForTest() {
        guard CommandLine.arguments.contains("--state-dir"), !isKeyScanInProgress else { return }
        textView.string = ""
        textView.undoManager?.removeAllActions()
        attachments.removeAll()
        files.removeAll()
        nextImageNo = 1
        rebuildChips()
        textChanged()
    }

    /// 測試掃描期間的檔案面板入口；只在隔離實例且掃描中呼叫，應在顯示面板前被正式 guard 擋下。
    @discardableResult
    func attemptUploadForKeyGuardTest() -> Bool {
        guard CommandLine.arguments.contains("--state-dir"), isKeyScanInProgress else { return false }
        uploadPressed()
        return isKeyScanInProgress
    }

    func removeFileForKeyGuardTest(_ url: URL) {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        removeFile(url)
    }

    func removeImageForKeyGuardTest(_ number: Int) {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        removeImage(number)
    }

    /// 模擬已在掃描前排入的非同步附件回呼。只允許隔離 state-dir 內的合成檔。
    @discardableResult
    func simulateKeyGuardAttachmentCallbackForTest(_ url: URL) -> Bool {
        guard CommandLine.arguments.contains("--state-dir"), isKeyScanInProgress,
              let index = CommandLine.arguments.firstIndex(of: "--state-dir"), index + 1 < CommandLine.arguments.count else { return false }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        guard isTestProbeOutput(url, inside: root), FileManager.default.fileExists(atPath: url.path) else { return false }
        insertPaths([url])
        let token = TerminalPane.shellEscape(url.path)
        return files.contains(url) && textView.string.contains(token)
    }

    private func send(now: Bool = false) {
        guard !isKeyScanInProgress else { return } // Enter／⌘Enter／外部 ⌃Enter 不會重入；只有按鈕會取消
        keyGuardScanStartCount += 1
        keyGuardLastScanElapsedMillisecondsForTest = 0
        KeyGuard.wire()
        let raw = textView.string
        let fileURLs = files
        let startVersion = keyScanContentVersion
        let stateSnapshot = KeyScan.snapshot() // 主執行緒快照；背景不得讀取 KeyScan 全域狀態
        let (generation, token) = beginKeyScan()
        let started = ProcessInfo.processInfo.systemUptime
        let testScanDelay: TimeInterval = CommandLine.arguments.contains("--state-dir") ? Self.keyGuardTestScanDelay : 0
        let testForceFailure: Bool = CommandLine.arguments.contains("--state-dir") && Self.keyGuardTestForceScanFailure
        let needsBackground = !fileURLs.isEmpty || raw.utf8.count > 200_000 || testForceFailure || testScanDelay > 0
        if !needsBackground {
            let collector = KeyGuardSuppressionCollector()
            let hits = KeyScan.scan(raw, using: stateSnapshot, learnedSuppressionCollector: collector.append)
            let output = KeyGuardScanOutput(textHits: hits, files: [], suppressionRows: collector.snapshot(),
                                            elapsedMilliseconds: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()), failed: false)
            completeKeyGuardScan(output, raw: raw, fileURLs: fileURLs, startVersion: startVersion,
                                 generation: generation, token: token, now: now)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let collector = KeyGuardSuppressionCollector()
            var hits: [KeyHit] = []
            var fileResults: [KeyGuardFileScanResult] = []
            var failed: Bool = testForceFailure
            let delayDeadline: TimeInterval = ProcessInfo.processInfo.systemUptime + max(0, testScanDelay)
            while !token.isCancelled && ProcessInfo.processInfo.systemUptime < delayDeadline {
                let remaining: TimeInterval = delayDeadline - ProcessInfo.processInfo.systemUptime
                Thread.sleep(forTimeInterval: min(0.02, max(0.001, remaining)))
            }
            if !token.isCancelled && !failed {
                hits = KeyScan.scan(raw, using: stateSnapshot, learnedSuppressionCollector: collector.append)
            }
            for url in (failed ? [] : fileURLs) {
                if token.isCancelled { break }
                fileResults.append(KeyGuard.scanFileCore(url, using: stateSnapshot,
                                                         learnedSuppressionCollector: collector.append))
            }
            let output = KeyGuardScanOutput(textHits: hits, files: fileResults,
                                            suppressionRows: collector.snapshot(),
                                            elapsedMilliseconds: Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()),
                                            failed: failed)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.completeKeyGuardScan(output, raw: raw, fileURLs: fileURLs, startVersion: startVersion,
                                          generation: generation, token: token, now: now)
            }
        }
    }

    private func completeKeyGuardScan(_ output: KeyGuardScanOutput, raw: String, fileURLs: [URL],
                                      startVersion initialVersion: UInt64, generation: UInt64,
                                      token: KeyGuardScanCancellation, now: Bool) {
        guard isKeyScanInProgress, keyScanGeneration == generation, keyScanCancellation === token else { return }
        var expectedVersion = initialVersion
        keyGuardLastScanElapsedMillisecondsForTest = output.elapsedMilliseconds
        guard !token.isCancelled else {
            finishKeyScan(generation: generation, token: token, message: L("掃描已取消，文字與附件保留"))
            return
        }
        guard keyScanContentVersion == expectedVersion else {
            finishKeyScan(generation: generation, token: token,
                          message: L("內容在掃描中改變，這則沒有送出，請再按一次送出"))
            return
        }
        guard !output.failed else {
            finishKeyScan(generation: generation, token: token, message: L("掃描失敗，這則沒有送出"))
            return
        }
        // 背景工作只累積 callback；只有回主執行緒且版本相符後才寫 suppression 紀錄。
        for row in output.suppressionRows {
            KeyGuard.noteLearnedSuppression(rule: row.rule, feature: row.feature, count: row.count)
        }

        var replacedAnyKey = false
        for hit in output.textHits.reversed() {
            guard keyScanContentVersion == expectedVersion else {
                finishKeyScan(generation: generation, token: token,
                              message: L("內容在掃描中改變，這則沒有送出，請再按一次送出"))
                return
            }
            let decision = KeyGuard.ask(hit)
            guard validateKeyGuardScan(generation: generation, token: token, startVersion: expectedVersion) else { return }
            switch decision {
            case .cancel:
                finishKeyScan(generation: generation, token: token)
                return
            case .sendAnyway:
                KeyGuard.recordLearning(type: "send-anyway", hit: hit, source: raw)
            case .notAKey:
                KeyGuard.recordFalsePositive(hit, source: raw)
            case .save(let service, let label):
                // ask() 內可能有兩層 modal；回來後先確認仍是同一輪掃描，才寫入鑰匙圈。
                guard validateKeyGuardScan(generation: generation, token: token, startVersion: expectedVersion) else { return }
                if let error = KeyVault.set(service: service, key: hit.key) {
                    finishKeyScan(generation: generation, token: token)
                    let alert = NSAlert(); alert.messageText = L("金鑰沒有存進去，所以這則沒有送出"); alert.informativeText = error; alert.runModal()
                    return
                }
                guard keyScanContentVersion == expectedVersion,
                      hit.range.upperBound <= (textView.string as NSString).length else {
                    finishKeyScan(generation: generation, token: token,
                                  message: L("內容在掃描中改變，這則沒有送出，請再按一次送出"))
                    return
                }
                let wasEditable = textView.isEditable
                textView.isEditable = true
                textView.insertText("〔金鑰：\(label)，已存〕", replacementRange: hit.range)
                textView.isEditable = wasEditable
                textChanged()
                expectedVersion = keyScanContentVersion
                replacedAnyKey = true
            }
            guard keyScanContentVersion == expectedVersion else {
                finishKeyScan(generation: generation, token: token,
                              message: L("內容在掃描中改變，這則沒有送出，請再按一次送出"))
                return
            }
        }

        // 替換後先讓使用者確認占位符；同一輪仍處理完其他命中，但不繼續送出。
        if replacedAnyKey {
            finishKeyScan(generation: generation, token: token,
                          message: L("已把金鑰換成占位符，請確認後再按一次送出"))
            return
        }

        var warnings: [KeyGuardFileWarning] = []
        var unscanned: [KeyGuardUnscannedFile] = []
        var bigNames: [String] = []
        for result in output.files {
            switch result {
            case .clean:
                break
            case .hits(let warning, _):
                warnings.append(warning)
            case .unscanned(let file):
                unscanned.append(file)
            }
        }
        // 保留原始附件順序，乾淨或命中但截斷的檔案都要進 askBigFiles。
        bigNames = output.files.enumerated().compactMap { index, result in
            switch result {
            case .clean(let truncated), .hits(_, let truncated): return truncated ? fileURLs[index].lastPathComponent : nil
            case .unscanned: return nil
            }
        }
        if !warnings.isEmpty {
            let sendAnyway = KeyGuard.askFiles(warnings, truncated: !bigNames.isEmpty)
            guard validateKeyGuardScan(generation: generation, token: token, startVersion: expectedVersion) else { return }
            if !sendAnyway { finishKeyScan(generation: generation, token: token); return }
        }
        guard keyScanContentVersion == expectedVersion else {
            finishKeyScan(generation: generation, token: token,
                          message: L("內容在掃描中改變，這則沒有送出，請再按一次送出"))
            return
        }
        if !unscanned.isEmpty {
            let scanAnyway = KeyGuard.askUnscannedFiles(unscanned)
            guard validateKeyGuardScan(generation: generation, token: token, startVersion: expectedVersion) else { return }
            if !scanAnyway { finishKeyScan(generation: generation, token: token); return }
        }
        guard keyScanContentVersion == expectedVersion else {
            finishKeyScan(generation: generation, token: token,
                          message: L("內容在掃描中改變，這則沒有送出，請再按一次送出"))
            return
        }
        if !bigNames.isEmpty {
            let sendAnyway = KeyGuard.askBigFiles(bigNames)
            guard validateKeyGuardScan(generation: generation, token: token, startVersion: expectedVersion) else { return }
            if !sendAnyway { finishKeyScan(generation: generation, token: token); return }
        }
        guard keyScanContentVersion == expectedVersion else {
            finishKeyScan(generation: generation, token: token,
                          message: L("內容在掃描中改變，這則沒有送出，請再按一次送出"))
            return
        }

        // 引用由 ChatPane 外部維護；在附件確認之後才重新取值並掃描。
        let quoteSnapshot = quotesProvider()
        let quoteState = KeyScan.snapshot()
        let quoteCollector = KeyGuardSuppressionCollector()
        var quoteWarnings: [KeyGuardFileWarning] = []
        for quote in quoteSnapshot {
            let hits = KeyScan.scan(quote.text, using: quoteState, learnedSuppressionCollector: quoteCollector.append)
            if !hits.isEmpty {
                quoteWarnings.append(KeyGuardFileWarning(name: L("（引用的訊息）"), source: quote.text, hits: hits))
            }
        }
        for row in quoteCollector.snapshot() {
            KeyGuard.noteLearnedSuppression(rule: row.rule, feature: row.feature, count: row.count)
        }
        if !quoteWarnings.isEmpty {
            let sendAnyway = KeyGuard.askFiles(quoteWarnings)
            guard validateKeyGuardScan(generation: generation, token: token, startVersion: expectedVersion) else { return }
            if !sendAnyway { finishKeyScan(generation: generation, token: token); return }
        }
        guard validateKeyGuardScan(generation: generation, token: token, startVersion: expectedVersion),
              quotesProvider() == quoteSnapshot else {
            finishKeyScan(generation: generation, token: token,
                          message: L("內容或引用在掃描中改變，這則沒有送出，請再按一次送出"))
            return
        }

        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if Bang.isBangMode(text) {
            guard let command = Bang.command(in: text), onBang?(command) == true else {
                finishKeyScan(generation: generation, token: token)
                return
            }
            textView.string = ""
            textView.undoManager?.removeAllActions()
            textChanged()
            finishKeyScan(generation: generation, token: token)
            return
        }
        guard !text.isEmpty || !attachments.isEmpty || !quoteSnapshot.isEmpty else {
            if now { onSendQueuedNow?() }
            finishKeyScan(generation: generation, token: token)
            return
        }
        suggestion = nil
        lastAttempt = (text: text, attachments: attachments, nextNo: nextImageNo, files: files)
        lastAttemptQuotes = quoteSnapshot
        if busy { lastSent = nil; lastSentQuotes = [] } else { lastSent = lastAttempt; lastSentQuotes = lastAttemptQuotes }
        guard validateKeyGuardScan(generation: generation, token: token, startVersion: expectedVersion),
              quotesProvider() == quoteSnapshot else {
            lastAttempt = nil
            finishKeyScan(generation: generation, token: token,
                          message: L("內容或引用在掃描中改變，這則沒有送出，請再按一次送出"))
            return
        }
        guard onSend?(text, attachments.map { ($0.data, $0.mediaType) }, now) == true else {
            lastAttempt = nil
            finishKeyScan(generation: generation, token: token)
            return
        }
        textView.string = ""
        textView.undoManager?.removeAllActions()
        attachments.removeAll()
        files.removeAll()
        nextImageNo = 1
        rebuildChips()
        textChanged()
        finishKeyScan(generation: generation, token: token)
    }

    /// 拖進來的東西（從輸入框或上面的對話內容）：圖片變附件、其他檔案插入路徑、承諾式檔案（照片 App 之類）等寫好再處理
    /// 從別的 App 拖東西進來成功之後（ShotLine 的截圖、Finder 的檔案）
    var onDropped: (() -> Void)?

    func takeDrop(_ pb: NSPasteboard) -> Bool {
        guard !rejectMutationDuringKeyScan() else { return false }
        let ok = acceptDrop(pb)
        if ok { onDropped?() }
        return ok
    }

    /// 拖放後只在目前 App 與這個視窗已在前景時取回焦點，不啟用 App／視窗。
    private func focusAfterDrop() {
        guard let window, Self.dropFocusAllowed(NSApp.isActive, window.isKeyWindow) else { return }
        window.makeFirstResponder(textView)
    }
    private static var dropFocusAllowed: (Bool, Bool) -> Bool = { appActive, keyWindow in appActive && keyWindow }

    /// --drop-focus-probe <JSON輸出>（必須搭配 --state-dir）：正式圖片附件插入路徑與不在前景時的焦點保護。
    static func runDropFocusProbe(in stateDirectory: URL, output: String) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--drop-focus-probe"), i + 1 < args.count else { return false }
        let originalDropFocusAllowed = dropFocusAllowed
        defer { dropFocusAllowed = originalDropFocusAllowed }
        let bar = ChatInputBar()
        let window = DropFocusProbeWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 240), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = bar
        window.orderBack(nil)
        bar.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let testInactive = args.contains("--drop-focus-probe-inactive")
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 20, height: 20)).fill(); image.unlockFocus()

        // 先把輸入框原有的 responder 狀態移開，並將這次移動排除於 attach 的呼叫增量。
        window.makeFirstResponder(nil)
        let foregroundResponderBeforeAttach = window.firstResponder
        let foregroundMovedAway = foregroundResponderBeforeAttach !== bar.textView
        let foregroundCallsBeforeAttach = window.makeFirstResponderCalls
        dropFocusAllowed = { _, _ in true }
        bar.attach(urls: [], images: [image])
        let token = Self.imageToken(1)
        let foregroundInput = window.firstResponder === bar.textView
        let foregroundCaret = bar.textView.selectedRange().location == (bar.textView.string as NSString).length
            && bar.textView.string.hasSuffix(token + " ")
        let foregroundCallsAfterAttach = window.makeFirstResponderCalls
        let foregroundCallDelta = foregroundCallsAfterAttach - foregroundCallsBeforeAttach
        let text = bar.textView.string
        let wasActive = NSApp.isActive
        if testInactive {
            window.makeFirstResponder(nil)
            let inactiveResponderBeforeAttach = window.firstResponder
            let inactiveCallsBeforeAttach = window.makeFirstResponderCalls
            dropFocusAllowed = { _, _ in false }
            bar.attach(urls: [], images: [image])
            let inactiveResponderAfterAttach = window.firstResponder
            let inactiveCallsAfterAttach = window.makeFirstResponderCalls
            let inactiveDidNotRequestFocus = inactiveCallsAfterAttach == inactiveCallsBeforeAttach
            let inactivePreservedResponder = inactiveResponderAfterAttach === inactiveResponderBeforeAttach
                && inactiveResponderAfterAttach !== bar.textView
            dropFocusAllowed = originalDropFocusAllowed
            let result: [String: Any] = ["firstResponderIsInput": foregroundInput,
                                         "caretAfterReference": foregroundCaret,
                                         "foregroundFirstResponderIsInput": foregroundInput,
                                         "foregroundCaretAfterReference": foregroundCaret,
                                         "foregroundMakeFirstResponderCallDelta": foregroundCallDelta,
                                         "inactiveDidNotCallMakeFirstResponder": inactiveDidNotRequestFocus,
                                         "inactivePreservedFirstResponder": inactivePreservedResponder,
                                         "insertedText": text,
                                         "appWasActive": wasActive]
            let passed = foregroundMovedAway && foregroundInput && foregroundCaret && foregroundCallDelta > 0
                && inactiveDidNotRequestFocus && inactivePreservedResponder
            let wrote = writeDropFocusProbe(result, to: output, in: stateDirectory)
            window.close()
            return passed && wrote
        }
        let result: [String: Any] = ["firstResponderIsInput": foregroundInput,
                                     "caretAfterReference": foregroundCaret,
                                     "insertedText": text,
                                     "appWasActive": wasActive]
        let wrote = writeDropFocusProbe(result, to: output, in: stateDirectory)
        window.close()
        return foregroundMovedAway && foregroundInput && foregroundCaret && foregroundCallDelta > 0 && wrote
    }

    private static func writeDropFocusProbe(_ result: [String: Any], to output: String, in stateDirectory: URL) -> Bool {
        let fm = FileManager.default
        // 對尚不存在的尾端，先找最近的既存祖先解析 symlink，再逐段接回路徑。
        // 這讓 /private/tmp 與 /tmp 在目標尚未建立時也得到一致的實際路徑。
        func resolvedPath(_ url: URL) -> URL {
            var existing = url.standardizedFileURL
            var suffix: [String] = []
            while !fm.fileExists(atPath: existing.path), existing.path != "/" {
                suffix.append(existing.lastPathComponent)
                existing.deleteLastPathComponent()
            }
            var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
            for component in suffix.reversed() { resolved.appendPathComponent(component) }
            return resolved.standardizedFileURL
        }

        let requestedState = resolvedPath(stateDirectory)
        do { try fm.createDirectory(at: requestedState, withIntermediateDirectories: true) }
        catch { return false }
        let stateRoot = resolvedPath(requestedState).path
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let outputParent = resolvedPath(outputURL.deletingLastPathComponent()).path
        let resolvedOutput = resolvedPath(outputURL).path
        func isWithinState(_ path: String) -> Bool {
            path == stateRoot || path.hasPrefix(stateRoot == "/" ? "/" : stateRoot + "/")
        }
        // 同時核對實際父目錄與目標（含既有 symlink），拒絕 .. 或 symlink 解析後逃出 state-dir。
        guard isWithinState(outputParent), isWithinState(resolvedOutput), resolvedOutput != stateRoot,
              outputURL.lastPathComponent != ".", outputURL.lastPathComponent != "..",
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) else { return false }
        do {
            try fm.createDirectory(at: URL(fileURLWithPath: outputParent, isDirectory: true), withIntermediateDirectories: true)
            // 再檢查一次，避免建立父目錄後經 symlink 解析落到 state-dir 外。
            let actualParent = resolvedPath(outputURL.deletingLastPathComponent()).path
            let actualOutput = resolvedPath(outputURL).path
            guard isWithinState(actualParent), isWithinState(actualOutput), actualOutput != stateRoot else { return false }
            try data.write(to: URL(fileURLWithPath: actualOutput), options: .atomic)
            return true
        } catch { return false }
    }

    private func acceptDrop(_ pb: NSPasteboard) -> Bool {
        if ProcessInfo.processInfo.environment["AI_WORKBENCH_DEBUG"] != nil { NSLog("takeDrop types=\(pb.types ?? []) urls=\(String(describing: pb.readObjects(forClasses: [NSURL.self], options: nil)))") }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let imgs = urls.filter(ChatTextView.isImage)
            let others = urls.filter { !ChatTextView.isImage($0) }
            if !imgs.isEmpty { attach(urls: imgs, images: []) }
            if !others.isEmpty { insertPaths(others) }
            focusAfterDrop()
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
        cancelKeyScanForExternalMutation()
        guard !urls.isEmpty else { return }
        keyScanContentVersion &+= 1
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
        focusAfterDrop()
    }

    func attach(urls: [URL], images: [NSImage]) {
        guard lockView.isHidden else {
            showKeyScanMessage(L("這格目前不能修改"))
            return
        }
        cancelKeyScanForExternalMutation()
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
            guard let no = allocateImageNo() else { break }
            attachments.append((a.data, a.mediaType, a.image, no, false))
            tokens.append(Self.imageToken(no))
        }
        guard !tokens.isEmpty else { return }
        // 在游標的位置插入 [Image #n]，說明文字可以寫在它前後
        var r = textView.selectedRange()
        if r.location == NSNotFound || r.upperBound > (textView.string as NSString).length { r = NSRange(location: (textView.string as NSString).length, length: 0) }
        r = outsideTokens(r)
        let before = r.location > 0 ? (textView.string as NSString).substring(with: NSRange(location: r.location - 1, length: 1)) : "\n"
        let lead = before == " " || before == "\n" ? "" : " "
        textView.insertText(lead + tokens.joined(separator: " ") + " ", replacementRange: r)
        rebuildChips()
        textChanged()
        focusAfterDrop()
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
        guard !rejectMutationDuringKeyScan() else { return }
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
        guard !rejectMutationDuringKeyScan() else { return }
        guard let a = attachments.first(where: { $0.no == no }) else { return }
        ImageEditor.edit(a.data, mediaType: a.mediaType, label: "Image #\(no)") { [weak self] data in
            guard let self, let data, let img = NSImage(data: data), let i = self.attachments.firstIndex(where: { $0.no == no && $0.data == a.data }) else { return }      // 編輯器開著的時候草稿送出又貼了別張圖（編號重來）：別蓋到新圖上
            self.cancelKeyScanForExternalMutation()
            let fitted = Self.fit(data, "image/png") ?? (data, "image/png")
            self.keyScanContentVersion &+= 1
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
        guard !rejectMutationDuringKeyScan() else { return }
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

/// 專用代理只把安全面板的輸入留在記憶體，避免 ChatInputBar 承擔 NSTextViewDelegate。
private final class KeyPasteTextViewDelegate: NSObject, NSTextViewDelegate {
    private let onChange: (String) -> Void
    init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView else { return }
        onChange(editor.string)
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
