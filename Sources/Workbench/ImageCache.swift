import Foundation

/// 轉給 agy／Codex 看圖用的暫存圖資料夾（07-32）：~/Library/Caches/codenv/<name>，資料夾 0700、檔案 0600，第一次用時清掉 7 天前的舊檔。
enum ImageCache {
    private static var cleaned = Set<String>()
    private static let lock = NSLock()

    static func directory(_ name: String, base: URL? = nil, maxAge: TimeInterval = 7 * 86400) -> URL {
        let fm = FileManager.default
        let root = base ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("codenv")
        let dir = root.appendingPathComponent(name)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)      // 以前建的（0755）也收緊
        lock.lock()
        let first = cleaned.insert(dir.path).inserted
        lock.unlock()
        if first { clean(dir, olderThan: maxAge) }
        return dir
    }

    static func clean(_ dir: URL, olderThan maxAge: TimeInterval) {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-maxAge)
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < old { try? fm.removeItem(at: f) }
        }
    }

    /// 寫圖檔（0600）；失敗回 nil
    static func write(_ data: Data, to url: URL) -> Bool {
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}
