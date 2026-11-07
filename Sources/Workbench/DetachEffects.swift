import AppKit

// Window 分頁拉出去變獨立視窗的動畫和視覺回饋
//  1. 拖到主視窗外面：游標旁邊跟著一個半透明的預覽小視窗（那個 Window 版面的縮圖），拖回來就淡出
//  2. 放開：獨立視窗從預覽的位置和大小長大、淡入；主視窗分頁列上的分頁縮小淡出
//  3. 關掉獨立視窗：縮小飛回分頁列上新分頁的位置，分頁亮一下
//  4. 拉出去的當下，主視窗跳一個 2 秒的小提示
//  系統設定開了「減少動態效果」就只淡入淡出，不縮放、不飛行。

enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// 預覽小視窗的內容：那個 Window 版面的縮圖（每格一個方塊加聊天室名字）
final class DetachPreviewView: NSView {
    var title = ""
    var panes: [(name: String, rect: CGRect)] = []     // rect 在 0～1 正方形裡，y 往下（PaneNode.rects）
    var accent: NSColor = .controlAccentColor
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let bg = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor(white: 0.1, alpha: 1).setFill(); bg.fill()
        accent.withAlphaComponent(0.9).setStroke(); bg.lineWidth = 2; bg.stroke()
        let head: CGFloat = 20
        let t = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        t.draw(at: NSPoint(x: 10, y: 3))
        let body = NSRect(x: r.minX + 6, y: r.minY + head, width: r.width - 12, height: r.height - head - 6)
        for p in panes {
            let pr = NSRect(x: body.minX + p.rect.minX * body.width, y: body.minY + p.rect.minY * body.height, width: p.rect.width * body.width, height: p.rect.height * body.height).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: pr, xRadius: 5, yRadius: 5)
            NSColor(white: 1, alpha: 0.10).setFill(); path.fill()
            NSColor(white: 1, alpha: 0.28).setStroke(); path.lineWidth = 1; path.stroke()
            let label = NSAttributedString(string: p.name, attributes: [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor(white: 1, alpha: 0.75)])
            if pr.width > 40 { label.draw(in: NSRect(x: pr.minX + 5, y: pr.minY + 4, width: pr.width - 10, height: 14)) }
        }
    }
}

/// 跟著游標走的預覽小視窗
final class DetachPreview {
    private var panel: NSPanel?
    private var view: DetachPreviewView?
    var frame: NSRect? { panel?.frame }

    func show(title: String, panes: [(String, CGRect)], size: NSSize, accent: NSColor, at p: NSPoint) {
        if panel == nil {
            let pn = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            pn.isOpaque = false
            pn.backgroundColor = .clear
            pn.level = .floating
            pn.hasShadow = true
            pn.ignoresMouseEvents = true
            pn.hidesOnDeactivate = false
            let v = DetachPreviewView(frame: NSRect(origin: .zero, size: size))
            v.title = title; v.panes = panes.map { ($0.0, $0.1) }; v.accent = accent
            v.wantsLayer = true
            v.layer?.cornerRadius = 10
            pn.contentView = v
            pn.alphaValue = 0
            pn.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; pn.animator().alphaValue = 0.85 }
            panel = pn; view = v
        }
        move(to: p)
    }

    func move(to p: NSPoint) {
        guard let panel else { return }
        // 游標旁邊（右下一點），不蓋住游標
        panel.setFrameOrigin(NSPoint(x: p.x + 14, y: p.y - panel.frame.height - 14))
    }

    /// 拖回視窗裡面（或取消）：淡出
    func hide() {
        guard let pn = panel else { return }
        panel = nil; view = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; pn.animator().alphaValue = 0 }, completionHandler: { pn.orderOut(nil) })
    }

    /// 測試用：把預覽畫成圖
    func snapshot() -> NSImage? {
        guard let v = view, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size); img.addRepresentation(rep); return img
    }

    /// 放開、要拉出去：立刻收掉（獨立視窗從這個位置長出來），回傳它最後的位置和大小
    func consume() -> NSRect? {
        guard let pn = panel else { return nil }
        let f = pn.frame
        panel = nil; view = nil
        pn.orderOut(nil)
        return f
    }
}

/// 主視窗上的小提示（2 秒後淡出）
enum Toast {
    private static var panel: NSPanel?
    static func show(_ text: String, over window: NSWindow?, seconds: TimeInterval = 2) {
        guard let window else { return }
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        let s = label.intrinsicContentSize
        let w = s.width + 36, h: CGFloat = 34
        let pn = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pn.isOpaque = false; pn.backgroundColor = .clear; pn.level = .floating; pn.ignoresMouseEvents = true; pn.hasShadow = true
        let bg = NSView(frame: pn.contentView!.bounds)
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        bg.layer?.cornerRadius = 10
        label.frame = NSRect(x: 18, y: (h - s.height) / 2, width: s.width, height: s.height)
        bg.addSubview(label)
        pn.contentView = bg
        let f = window.frame
        pn.setFrameOrigin(NSPoint(x: f.midX - w / 2, y: f.maxY - 90))
        pn.alphaValue = 0
        pn.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; pn.animator().alphaValue = 1 }
        panel = pn
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; pn.animator().alphaValue = 0 }, completionHandler: { pn.orderOut(nil); if panel === pn { panel = nil } })
        }
    }
}
