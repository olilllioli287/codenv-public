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

    // MARK: 用量圖示（去背版）

    /// 圖示：image 加上是不是單色（單色的要跟著文字顏色上色）
    struct Glyph { let image: NSImage; let template: Bool }

    /// 輸入框下面那條用的：Claude＝橘色星芒、Codex＝ChatGPT 線條標誌（單色跟字色）、agy＝Antigravity 的彩色「A」（去背）；
    /// 取不到就回 nil（呼叫端退回 SF Symbols）。圖都是使用者電腦上真的 App／面板那套，不自己畫
    static func glyph(for key: String) -> Glyph? {
        switch key {
        case "cc": return ModelTab.claude.image.map { Glyph(image: $0, template: false) }
        case "codex": return ModelTab.chatgpt.image.map { Glyph(image: $0, template: true) }
        case "agy": return agyGlyph().map { Glyph(image: $0, template: false) }
        default: return nil
        }
    }

    private static var agyCache: NSImage??
    /// Antigravity.app 的 App 圖示去背：拿掉白色底，只留彩色的「A」。App 不存在或圖讀不出來回 nil
    static func agyGlyph() -> NSImage? {
        if let c = agyCache { return c }
        var out: NSImage?
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity")
            ?? (FileManager.default.fileExists(atPath: "/Applications/Antigravity.app") ? URL(fileURLWithPath: "/Applications/Antigravity.app") : nil)
        if let app, let bundle = Bundle(url: app) {
            var name = (bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String) ?? "icon"
            if (name as NSString).pathExtension.isEmpty { name += ".icns" }
            let file = app.appendingPathComponent("Contents/Resources/" + name)
            // 直接讀 .icns 檔（不是 NSWorkspace.icon：那個會套系統的圓角底和陰影）
            if let img = NSImage(contentsOf: file) { out = cutOutWhiteBackground(img) }
        }
        agyCache = .some(out)
        return out
    }

    /// 白底去背。步驟：①從四邊往裡填，連到邊的近白色＝背景 ②離背景 3 點以上的才算「確定的內部」③靠邊的像素（跟白底混過）
    /// 用最近的內部顏色當原色、反推它蓋了多少％（color-to-alpha），所以邊緣乾淨、沒有白邊；内部像素原樣保留
    static func cutOutWhiteBackground(_ image: NSImage, size n: Int = 256) -> NSImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // 先鋪白底再畫圖：原本就透明的地方（圓角外面）也變成白色背景
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let raw = ctx.data else { return nil }
        let px = raw.bindMemory(to: UInt8.self, capacity: n * n * 4)
        func minC(_ i: Int) -> Int { Int(min(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])) }

        // ① 背景：從邊界往裡填近白色
        var bg = [Bool](repeating: false, count: n * n)
        var stack: [Int] = []
        func push(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < n, y < n else { return }
            let i = y * n + x
            if !bg[i], minC(i) >= 250 { bg[i] = true; stack.append(i) }
        }
        for k in 0..<n { push(k, 0); push(k, n - 1); push(0, k); push(n - 1, k) }
        while let i = stack.popLast() { let x = i % n, y = i / n; push(x + 1, y); push(x - 1, y); push(x, y + 1); push(x, y - 1) }
        if !bg.contains(true) { return nil }          // 邊上找不到白底：不是預期的圖，不動它

        // ② 內部：非背景、而且 3 點內（8 方向）都沒有背景
        var core = bg.map { !$0 }
        for _ in 0..<3 {
            var next = core
            for y in 0..<n { for x in 0..<n where core[y * n + x] {
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    if xx < 0 || yy < 0 || xx >= n || yy >= n || !core[yy * n + xx] { next[y * n + x] = false }
                } }
            } }
            core = next
        }

        // ③ 輸出：背景透明、內部原樣、邊緣用 color-to-alpha
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let i = y * n + x
            if bg[i] { continue }
            var r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2]), a = 1.0
            if !core[i] {
                // 找最近的內部像素（半徑 8 內）當「原本的顏色」
                var best: Int?, bestD = Int.max
                for dy in -8...8 { for dx in -8...8 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < n, yy < n, core[yy * n + xx] else { continue }
                    let d = dx * dx + dy * dy
                    if d < bestD { bestD = d; best = yy * n + xx }
                } }
                if let j = best {
                    let c = [Double(px[j * 4]), Double(px[j * 4 + 1]), Double(px[j * 4 + 2])]
                    let p = [r, g, b]
                    // 蓋了幾％：p = a·C + (1-a)·255，取分母最大（最不受雜訊影響）的那個色版
                    var k = 0
                    for t in 1..<3 where 255 - c[t] > 255 - c[k] { k = t }
                    if 255 - c[k] > 24 { a = min(1, max(0, (255 - p[k]) / (255 - c[k]))) } else { a = 0 }
                    r = c[0]; g = c[1]; b = c[2]
                } else {
                    a = 0
                }
            }
            if a <= 0.01 { continue }
            // CGContext 要預乘過的
            rgba[i * 4] = UInt8(max(0, min(255, (r * a).rounded())))
            rgba[i * 4 + 1] = UInt8(max(0, min(255, (g * a).rounded())))
            rgba[i * 4 + 2] = UInt8(max(0, min(255, (b * a).rounded())))
            rgba[i * 4 + 3] = UInt8(max(0, min(255, (a * 255).rounded())))
        } }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        // 圖有留白的邊：裁到 A 的範圍，圖示才不會因為留白顯得太小
        var minX = n, minY = n, maxX = -1, maxY = -1
        for y in 0..<n { for x in 0..<n where rgba[(y * n + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return nil }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cg.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: crop.width, height: crop.height))
    }
}
