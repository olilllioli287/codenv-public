import AppKit
import WebKit
import UniformTypeIdentifiers
import ImageIO

/// 聊天室裡 Markdown 放的本機圖片（![說明](絕對路徑/a.png)）：網頁只准讀 App 裡的 chat 資料夾，
/// 所以 chat.js 把本機路徑改寫成 codenv-img://local/<路徑>，由這裡讀檔回傳。
/// 只回圖片：副檔名要是圖片、追到 symlink 的盡頭也要是圖片、內容也真的是圖片（ImageIO 認得），其他一律 404。
/// 不把 allowingReadAccessTo 放大到 /，網頁照樣讀不到其他檔案。
final class LocalImageScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "codenv-img"
    static let shared = LocalImageScheme()
    /// 太大的不讀（相機原檔之類）：50 MB
    private static let maxBytes = 50 * 1024 * 1024

    /// 讀檔和 ImageIO 驗證放到背景（最多同時 2 張）：start 是在主執行緒呼叫的，慢磁碟或大圖會讓整個畫面卡住；回覆再切回主執行緒
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "codenv-img"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    /// 還沒回覆、也還沒被網頁取消的請求（只在主執行緒碰）：取消後不能再對那個 task 呼叫 didReceive／didFinish，會丟例外
    private var active = Set<ObjectIdentifier>()
    /// 給背景佇列看的副本（要加鎖）：網頁已經取消的請求，排在佇列裡就不要再去讀檔、解碼了
    private let activeLock = NSLock()
    private var activeCopy = Set<ObjectIdentifier>()
    private func setActive(_ k: ObjectIdentifier, _ on: Bool) {
        activeLock.lock(); if on { activeCopy.insert(k) } else { activeCopy.remove(k) }; activeLock.unlock()
    }
    private func isActive(_ k: ObjectIdentifier) -> Bool { activeLock.lock(); defer { activeLock.unlock() }; return activeCopy.contains(k) }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        active.insert(key)
        setActive(key, true)
        let url = task.request.url
        queue.addOperation { [weak self] in
            guard let self, self.isActive(key) else { return }
            let loaded = url.flatMap { Self.load($0) }
            DispatchQueue.main.async {
                guard self.active.remove(key) != nil else { return }
                self.setActive(key, false)
                guard let url, let (data, mime) = loaded else {
                    if let url, let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) {
                        task.didReceive(r)
                        task.didFinish()
                    } else {
                        task.didFailWithError(URLError(.fileDoesNotExist))
                    }
                    return
                }
                let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"])!
                task.didReceive(r)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        active.remove(key)
        setActive(key, false)
    }

    /// codenv-img://local/<百分比編碼的路徑> → 圖片資料和 MIME；不是圖片、不存在回 nil
    static func load(_ url: URL) -> (Data, String)? {
        guard url.scheme == scheme, let path = path(of: url) else { return nil }
        // 追到 symlink 的盡頭再判斷：.png 的捷徑指到文字檔也不給
        let real = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard isImageExt(real.path) else { return nil }
        guard let v = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
              (v.fileSize ?? 0) <= maxBytes, let data = try? Data(contentsOf: real) else { return nil }
        // 內容也要真的是圖片（改了副檔名的文字檔不給）
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let t = CGImageSourceGetType(src) as String?,
              let ut = UTType(t), ut.conforms(to: .image) else { return nil }
        return (data, ut.preferredMIMEType ?? "application/octet-stream")
    }

    /// 網址裡的路徑：/~/… 換成家目錄；一定要是絕對路徑
    static func path(of url: URL) -> String? {
        var p = url.path   // 已經解開百分比編碼
        if p.hasPrefix("/~/") || p == "/~" { p = NSHomeDirectory() + p.dropFirst(2) }
        guard p.hasPrefix("/") else { return nil }
        return (p as NSString).standardizingPath
    }

    private static func isImageExt(_ p: String) -> Bool {
        let ext = (p as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let t = UTType(filenameExtension: ext) else { return false }
        return t.conforms(to: .image)
    }
}
