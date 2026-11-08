import AppKit

/// 測試用：--test-screen <螢幕名稱子字串>（例：ipad）。只在測試實例（有 --state-dir 或 --background）生效，
/// 主視窗和分離視窗都擺進那台螢幕的 visibleFrame（太大就照比例縮）。找不到那台螢幕就照舊。不 activate、不 makeKey。
enum TestScreen {
    static var screen: NSScreen? {
        let a = CommandLine.arguments
        guard a.contains("--state-dir") || a.contains("--background"),
              let i = a.firstIndex(of: "--test-screen"), i + 1 < a.count else { return nil }
        let key = a[i + 1].lowercased()
        guard !key.isEmpty else { return nil }
        return NSScreen.screens.first { $0.localizedName.lowercased().contains(key) }
    }

    static func fit(_ w: NSWindow) {
        guard let s = screen else { return }
        let vf = s.visibleFrame
        var f = w.frame
        guard f.width > 0, f.height > 0 else { return }
        let k = min(1, vf.width / f.width, vf.height / f.height)
        f.size = NSSize(width: (f.width * k).rounded(.down), height: (f.height * k).rounded(.down))
        f.origin = NSPoint(x: (vf.midX - f.width / 2).rounded(), y: (vf.midY - f.height / 2).rounded())
        w.setFrame(f, display: false)
    }
}
