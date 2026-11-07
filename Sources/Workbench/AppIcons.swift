import AppKit

/// 用量條各家前面的圖示：直接用使用者電腦上已安裝 App 的真圖示（NSWorkspace），找不到回 nil（呼叫端退回 SF Symbols）。
enum AppIcons {
    /// 用量組的 key（cc／codex／agy）→ 依序找的 App（bundle id、常見的安裝位置）
    private static let candidates: [String: (ids: [String], paths: [String])] = [
        "cc": (["com.anthropic.claudefordesktop"], ["/Applications/Claude.app"]),
        "codex": (["com.openai.codex", "com.openai.chat"], ["/Applications/Codex.app", "/Applications/ChatGPT.app"]),
        "agy": (["com.google.antigravity"], ["/Applications/Antigravity.app"]),
    ]
    private static var cache: [String: NSImage?] = [:]

    static func icon(for key: String) -> NSImage? {
        if let c = cache[key] { return c }
        var found: NSImage?
        if let c = candidates[key] {
            var urls = c.ids.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            urls += c.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            if let u = urls.first { found = NSWorkspace.shared.icon(forFile: u.path) }
        }
        cache[key] = found
        return found
    }
}
