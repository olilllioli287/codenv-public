import AppKit

// 桌寵的位置：在畫面右下角留一塊空位（裡面沒有任何字），使用者自己把打字桌寵擺進去。
// 跟 tmux 的 pet-slot（Ctrl+A b）同一個意思，但這裡是真的讓出空間：那一格的輸入框變窄、對話內容整塊往上讓，字不會被桌寵蓋住。
// 不會去動桌寵本身（使用者：「不要動我的桌寵，我會調」）。大小分筆電螢幕／外接螢幕各記一組。

enum PetSlot {
    static let changed = Notification.Name("AIWorkbenchPetSlotChanged")
    private static let d = appDefaults

    static var enabled: Bool {
        get { d.bool(forKey: "petSlotOn") }
        set { d.set(newValue, forKey: "petSlotOn"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// 這個螢幕記住的大小；沒記過就照桌寵本身的大小（desktop-pet 存的 petWidth、height）多留一點邊
    static func size(on screen: NSScreen?) -> NSSize {
        if let s = (d.dictionary(forKey: "petSlotSize") as? [String: [Double]])?[key(screen)], s.count == 2 { return NSSize(width: s[0], height: s[1]) }
        let pet = UserDefaults(suiteName: "com.local.desktoppet")
        let w = pet?.double(forKey: "petWidth") ?? 0, h = pet?.double(forKey: "height") ?? 0
        return NSSize(width: (w > 0 ? w : 181) + 16, height: (h > 0 ? h : 150) + 8)
    }

    /// 設定頁用：照「builtin／external」讀寫
    static func size(forKey k: String) -> NSSize {
        if let s = (d.dictionary(forKey: "petSlotSize") as? [String: [Double]])?[k], s.count == 2 { return NSSize(width: s[0], height: s[1]) }
        return size(on: nil)
    }
    static func setSize(_ size: NSSize, forKey k: String) {
        var all = d.dictionary(forKey: "petSlotSize") as? [String: [Double]] ?? [:]
        all[k] = [Double(size.width.rounded()), Double(size.height.rounded())]
        d.set(all, forKey: "petSlotSize")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func setSize(_ size: NSSize, on screen: NSScreen?) {
        var all = d.dictionary(forKey: "petSlotSize") as? [String: [Double]] ?? [:]
        all[key(screen)] = [Double(size.width.rounded()), Double(size.height.rounded())]
        d.set(all, forKey: "petSlotSize")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// 筆電內建螢幕還是外接螢幕（跟 pet-slot 一樣分兩組）
    static func key(_ screen: NSScreen?) -> String {
        guard let s = screen ?? NSScreen.main else { return "builtin" }
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return CGDisplayIsBuiltin(id) != 0 ? "builtin" : "external"
    }
}

/// 畫在空位上的淡淡虛線框；左上角那個小把手可以拖來調大小
final class PetSlotView: NSView {
    var onResize: ((NSSize) -> Void)?
    private var dragStart: (NSPoint, NSSize)?
    private let grip: CGFloat = 16
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // 欄位左邊已經有一條線；這裡只畫格子上緣那條，從左到右
        let top = bounds.height - 0.5
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: top))
        p.line(to: NSPoint(x: bounds.width, y: top))
        p.lineWidth = 1
        NSColor.separatorColor.setStroke()
        p.stroke()
        // 左上角的把手：兩條小斜線（拖來調大小）
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        for i in 0..<2 {
            let o = CGFloat(i) * 4 + 8
            let l = NSBezierPath()
            l.move(to: NSPoint(x: 3 + o, y: top - 3))
            l.line(to: NSPoint(x: 3, y: top - 3 - o))
            l.lineWidth = 1
            l.stroke()
        }
    }

    private var gripRect: NSRect { NSRect(x: 0, y: bounds.height - grip - 6, width: grip + 6, height: grip + 6) }

    // 只有把手吃滑鼠；其他地方讓給底下（其實底下沒東西，桌寵本身在自己的視窗）
    override func hitTest(_ point: NSPoint) -> NSView? {
        gripRect.contains(convert(point, from: superview)) ? self : nil
    }
    override func resetCursorRects() { addCursorRect(gripRect, cursor: .crosshair) }
    override func mouseDown(with e: NSEvent) { dragStart = (NSEvent.mouseLocation, bounds.size) }
    override func mouseDragged(with e: NSEvent) {
        guard let (p0, s0) = dragStart else { return }
        let p = NSEvent.mouseLocation
        // 往左上拖＝變大（右下角固定）
        let w = min(600, max(80, s0.width + (p0.x - p.x)))
        let h = min(500, max(60, s0.height + (p.y - p0.y)))
        onResize?(NSSize(width: w, height: h))
    }
    override func mouseUp(with e: NSEvent) { dragStart = nil }
}
