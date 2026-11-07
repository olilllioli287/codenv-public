import AppKit

/// 浮動終端機按鈕：放在右欄桌寵框左上角，不透明、只有圖示；開著時用強調色
final class FloatTermButton: NSButton {
    static let visibilityChanged = Notification.Name("FloatTermButton.visibility")
    private(set) static var terminalVisible = false
    static func setVisible(_ v: Bool) {
        terminalVisible = v
        NotificationCenter.default.post(name: visibilityChanged, object: nil)
    }

    private var hovering = false { didSet { refresh() } }
    private var observer: NSObjectProtocol?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        image = NSImage(systemSymbolName: "terminal", accessibilityDescription: L("浮動終端機"))
        image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        toolTip = L("浮動終端機（F5）")
        setAccessibilityLabel(L("浮動終端機"))
        target = self
        action = #selector(toggle)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        observer = NotificationCenter.default.addObserver(forName: Self.visibilityChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    private func refresh() {
        let on = Self.terminalVisible
        contentTintColor = on ? .controlAccentColor : .labelColor
        layer?.backgroundColor = (hovering ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).cgColor
        layer?.borderColor = (on ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    @objc private func toggle() { (NSApp.delegate as? AppDelegate)?.toggleFloatingTerminal() }
}
