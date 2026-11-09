import AppKit
import SwiftUI

// 事件紀錄（類似 BetterDisplay 的 Console）：記下啟動、螢幕變化、聊天程序啟停、獨立視窗、存檔錯誤、瀏覽器載入結果，
// 方便使用者（特別是公版使用者）遇到問題時把最近 3 天的紀錄交給開發者。
// 隱私原則：不記對話內容、提示詞、模型輸出、網址路徑與查詢參數（只留主機名稱）、token 與 cookie；家目錄一律換成 ~。

enum EventLog {
    static let didAppend = Notification.Name("CodenvEventLogDidAppend")
    static let didReload = Notification.Name("CodenvEventLogDidReload")
    static let changed = Notification.Name("CodenvEventLogChanged")

    static let defaultsKey = "eventLogOn"
    static let maxMemoryLines = 2000
    static let maxFileBytes: UInt64 = 20 * 1024 * 1024
    static let pruneInterval: TimeInterval = 6 * 3600

    /// ~/Library/Logs/codenv/events（私人版與公版都照 ChatSession.debugLogDir 的慣例放在 codenv 底下；--state-dir 測試時改放測試資料夾，不碰正式紀錄）
    static let dir: URL = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count {
            return URL(fileURLWithPath: a[i + 1], isDirectory: true).appendingPathComponent("events", isDirectory: true)
        }
        return ChatSession.debugLogDir.appendingPathComponent("events", isDirectory: true)
    }()

    /// 是否記錄事件（預設開；關掉後不再寫入新事件，已經寫下的檔案與畫面保留）
    static var enabled: Bool {
        get { appDefaults.object(forKey: defaultsKey) as? Bool ?? true }
        set {
            appDefaults.set(newValue, forKey: defaultsKey)
            if Thread.isMainThread {
                NotificationCenter.default.post(name: changed, object: nil)
            } else {
                DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
            }
        }
    }

    private static let queue = DispatchQueue(label: "codenv.eventlog", qos: .utility)
    private static let lock = NSLock()
    private static var recentLines: [String] = []
    private static var sequence: UInt64 = 0
    private static var started = false
    private static var pruneTimer: DispatchSourceTimer?
    private static var cappedDay: String?
    /// 當天紀錄達到 20 MB 上限後，未能寫入磁碟的新紀錄（最多 2000 行），供 copyRecentThreeDays 附在尾部
    private static var cappedMemoryLines: [String] = []

    private static var localCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .autoupdatingCurrent
        return cal
    }

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func fileURL(forDay day: String) -> URL {
        dir.appendingPathComponent("events-\(day).log")
    }

    /// 啟動時清掉 3 天以前的舊檔、載入保留檔案中最近的最多 2000 行，之後每 6 小時再檢查一次
    static func start() {
        queue.async {
            guard !started else { return }
            started = true
            let now = Date()
            pruneOnQueue(now: now)
            reloadRecentLinesOnQueue(now: now)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + pruneInterval, repeating: pruneInterval)
            t.setEventHandler { pruneOnQueue(now: Date()) }
            t.resume()
            pruneTimer = t
        }
    }

    /// 可從任何執行緒呼叫：在專用 serial queue 上清洗並寫檔，不卡主執行緒
    static func log(_ category: String, _ message: String) {
        guard enabled else { return }
        let now = Date()
        queue.async {
            let ts = lineFormatter.string(from: now)
            let day = dayFormatter.string(from: now)
            let cat = scrub(category, maxLen: 40)
            let msg = scrub(message, maxLen: 400)
            let line = "[\(ts)] \(cat) - \(msg)"

            lock.lock()
            recentLines.append(line)
            if recentLines.count > maxMemoryLines {
                recentLines.removeFirst(recentLines.count - maxMemoryLines)
            }
            sequence += 1
            let seq = sequence
            lock.unlock()

            appendToDiskOnQueue(line: line, day: day, timestamp: ts)
            if cappedDay == day {
                cappedMemoryLines.append(line)
                if cappedMemoryLines.count > maxMemoryLines {
                    cappedMemoryLines.removeFirst(cappedMemoryLines.count - maxMemoryLines)
                }
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: didAppend, object: nil, userInfo: ["line": line, "seq": seq])
            }
        }
    }

    /// 結束 App 前把佇列裡還沒寫完的一併寫進磁碟（最多等 0.5 秒，免得結束 App 時卡住）
    static func flush() {
        let sema = DispatchSemaphore(value: 0)
        queue.async { sema.signal() }
        _ = sema.wait(timeout: .now() + 0.5)
    }

    static func snapshot() -> (lines: [String], seq: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (recentLines, sequence)
    }

    /// 清掉畫面與今天的紀錄檔，並從保留下來的前兩天檔案重新載入記憶體
    static func clearToday() {
        queue.async {
            let now = Date()
            let today = dayFormatter.string(from: now)
            try? FileManager.default.removeItem(at: fileURL(forDay: today))
            if cappedDay == today { cappedDay = nil }
            cappedMemoryLines.removeAll()
            reloadRecentLinesOnQueue(now: now)
        }
    }

    /// 把保留範圍內的事件紀錄合起來拷貝到剪貼簿，回傳總行數
    static func copyRecentThreeDays(done: @escaping (Int) -> Void) {
        recentThreeDaysText { combined, count in
            if !combined.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(combined, forType: .string)
            }
            done(count)
        }
    }

    /// 保留範圍內（今天與前 2 天，共 3 個日曆日）的事件紀錄合成一段文字（拷貝與回報檔共用），回到主執行緒：(全文, 行數)
    static func recentThreeDaysText(done: @escaping (String, Int) -> Void) {
        queue.async {
            let now = Date()
            pruneOnQueue(now: now)
            let cal = localCalendar
            let startOfToday = cal.startOfDay(for: now)
            let keepCutoff = cal.date(byAdding: .day, value: -2, to: startOfToday) ?? startOfToday

            let fm = FileManager.default
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { url in
                    guard url.lastPathComponent.hasPrefix("events-") && url.pathExtension == "log" else { return false }
                    let stem = String(url.deletingPathExtension().lastPathComponent.dropFirst("events-".count))
                    if let fileDate = dayFormatter.date(from: stem) {
                        return cal.startOfDay(for: fileDate) >= keepCutoff
                    }
                    if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        return cal.startOfDay(for: mtime) >= keepCutoff
                    }
                    return false
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var chunks: [String] = []
            var count = 0
            for f in files {
                guard let h = try? FileHandle(forReadingFrom: f) else { continue }
                defer { try? h.close() }
                let size = (try? h.seekToEnd()) ?? 0
                // 正常一天只有幾十 KB；若真的碰到接近 20 MB 的極端情況，每檔最多取最後 4 MB 免得剪貼簿卡住
                let cap: UInt64 = 4 * 1024 * 1024
                try? h.seek(toOffset: size > cap ? size - cap : 0)
                let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                if !text.isEmpty {
                    chunks.append(text)
                    count += text.split(whereSeparator: \.isNewline).count
                }
            }
            let today = dayFormatter.string(from: now)
            if cappedDay == today && !cappedMemoryLines.isEmpty {
                let notice = "---- 以下為單日紀錄達 20 MB 上限後，保留在記憶體中的最新紀錄 ----"
                chunks.append(notice)
                chunks.append(cappedMemoryLines.joined(separator: "\n"))
                count += 1 + cappedMemoryLines.count
            }
            if chunks.isEmpty {
                let mem = snapshot().lines
                if !mem.isEmpty {
                    chunks = [mem.joined(separator: "\n")]
                    count = mem.count
                }
            }
            let combined = chunks.joined(separator: "\n")
            DispatchQueue.main.async { done(combined, count) }
        }
    }

    static func revealInFinder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let latest = files.last {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    // MARK: 清洗與摘要工具

    /// 隱私清洗：壓成單行、網址只留主機名稱（支援 file://）、遮掉 token／cookie／金鑰、家目錄換成 ~、使用者名稱換成 [user]
    static func scrub(_ raw: String, maxLen: Int = 400) -> String {
        var t = raw.replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
        // file:// 網址只留 "file"，不留後續路徑
        t = t.replacingOccurrences(
            of: #"(?i)(?<![A-Za-z0-9_])file://[^\s"'<>）)】\]]*"#,
            with: "file",
            options: .regularExpression
        )
        // http / https / ws / wss 網址只留主機名稱
        t = t.replacingOccurrences(
            of: #"(?i)(?<![A-Za-z0-9_])(?:https?|wss?)://(?:[^\s/@]+@)?(\[[0-9a-f:]+\]|[a-z0-9.-]+)(?::\d+)?(?:[/\?#][^\s"'<>）)】\]]*)?"#,
            with: "$1",
            options: .regularExpression
        )
        t = t.replacingOccurrences(of: #"(?i)(?<![A-Za-z0-9_])(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#, with: "$1 ***", options: .regularExpression)
        t = t.replacingOccurrences(
            of: #"(?<![A-Za-z0-9_])(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|AIza[A-Za-z0-9_-]{20,}|ya29\.[A-Za-z0-9._-]+|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*)"#,
            with: "***",
            options: .regularExpression
        )
        t = t.replacingOccurrences(
            of: #"(?i)(?<![A-Za-z0-9_])(set-cookie|cookie)\s*:\s*(?:[^\s;=]+=[^\s;]+;?\s*)+"#,
            with: "$1: *** ",
            options: .regularExpression
        )
        t = t.replacingOccurrences(
            of: #"(?i)(?<![A-Za-z0-9_])(access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token|api[_-]?key|token|secret|password|authorization|set-cookie|cookie|session[_-]?id)(["']?)\s*([=:])\s*["']?([^\s,;"'）)】\]]+)"#,
            with: "$1$2$3***",
            options: .regularExpression
        )
        let home = Edition.home.path
        if !home.isEmpty { t = t.replacingOccurrences(of: home, with: "~") }
        let nsHome = NSHomeDirectory()
        if !nsHome.isEmpty { t = t.replacingOccurrences(of: nsHome, with: "~") }
        let usersDir = NSRegularExpression.escapedPattern(for: (nsHome as NSString).deletingLastPathComponent)
        if !usersDir.isEmpty && usersDir != "/" {
            t = t.replacingOccurrences(of: usersDir + #"/[^/\s"'）)】\]]+"#, with: "~", options: .regularExpression)
        }
        // 使用者帳號與全名（長度 ≥ 2 才換）全域換成 [user]
        let uName = NSUserName()
        if uName.count >= 2 {
            t = t.replacingOccurrences(of: uName, with: "[user]")
        }
        let fullUName = NSFullUserName()
        if fullUName.count >= 2 {
            t = t.replacingOccurrences(of: fullUName, with: "[user]")
        }
        t = t.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        t = KeyScan.redact(t)     // 前面的規則漏掉的金鑰樣式（nvapi-、sk-or-、高熵長字串…）也只留末四碼
        return t.count > maxLen ? String(t.prefix(maxLen)) + "…" : t
    }

    /// 標題截短成最多 20 字（避免把使用者長句帶進紀錄）
    static func shortTitle(_ raw: String?, fallback: String = "") -> String {
        let s = (raw ?? "").replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? fallback : String(s.prefix(20))
    }

    /// 取最後一個非空行的前 max 個字（給程序結束時的 stderr 摘要用）
    static func tailLine(_ raw: String, max: Int = 120) -> String {
        guard let last = raw.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        return scrub(String(last.trimmingCharacters(in: .whitespaces).prefix(max)), maxLen: max)
    }

    /// 目前所有螢幕的編號、種類（內建／外接）、像素解析度與 frame（不記 localizedName 避免洩漏人名或裝置名稱）
    static func screensSummary() -> String {
        let list = NSScreen.screens
        guard !list.isEmpty else { return "無螢幕" }
        return list.enumerated().map { i, s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let kind = CGDisplayIsBuiltin(id) != 0 ? "內建" : "外接"
            let f = s.frame
            let pxW = Int((f.width * s.backingScaleFactor).rounded())
            let pxH = Int((f.height * s.backingScaleFactor).rounded())
            return "螢幕 \(i + 1)（\(kind)）\(pxW)×\(pxH)px frame(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
        }.joined(separator: "；")
    }

    /// 視窗的位置與所在螢幕編號（獨立視窗拉出／還原時記，只記「螢幕 N」加位置，不記 localizedName 避免洩漏人名）
    static func windowSummary(_ w: NSWindow?) -> String {
        guard let w else { return "" }
        let f = w.frame
        let screens = NSScreen.screens
        let screenLabel: String
        if let s = w.screen, let i = screens.firstIndex(of: s) {
            screenLabel = "螢幕 \(i + 1)"
        } else {
            screenLabel = "未知螢幕"
        }
        return "\(screenLabel) (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
    }

    // MARK: 檔案讀寫與清理（只在 queue 上執行）

    /// 從磁碟載入現存保留檔案（最多最近 2000 行）進記憶體
    private static func reloadRecentLinesOnQueue(now: Date) {
        let cal = localCalendar
        let startOfToday = cal.startOfDay(for: now)
        let keepCutoff = cal.date(byAdding: .day, value: -2, to: startOfToday) ?? startOfToday
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { url in
                guard url.lastPathComponent.hasPrefix("events-") && url.pathExtension == "log" else { return false }
                let stem = String(url.deletingPathExtension().lastPathComponent.dropFirst("events-".count))
                if let fileDate = dayFormatter.date(from: stem) {
                    return cal.startOfDay(for: fileDate) >= keepCutoff
                }
                if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    return cal.startOfDay(for: mtime) >= keepCutoff
                }
                return false
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var collected: [String] = []
        for f in files {
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let tailCap: UInt64 = 512 * 1024
            try? h.seek(toOffset: size > tailCap ? size - tailCap : 0)
            var text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
            if size > tailCap, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            collected.append(contentsOf: lines)
        }

        let loaded = Array(collected.suffix(maxMemoryLines))
        lock.lock()
        recentLines = loaded
        sequence += 1
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didReload, object: nil)
        }
    }

    /// 依當地日曆日保留今天與前 2 天（共 3 天），日期更早的刪除
    private static func pruneOnQueue(now: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cal = localCalendar
        let startOfToday = cal.startOfDay(for: now)
        let keepCutoff = cal.date(byAdding: .day, value: -2, to: startOfToday) ?? startOfToday

        for f in files where f.lastPathComponent.hasPrefix("events-") && f.pathExtension == "log" {
            let stem = String(f.deletingPathExtension().lastPathComponent.dropFirst("events-".count))
            if let fileDate = dayFormatter.date(from: stem) {
                if cal.startOfDay(for: fileDate) < keepCutoff {
                    try? fm.removeItem(at: f)
                }
            } else if let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if cal.startOfDay(for: mtime) < keepCutoff {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }

    private static func appendToDiskOnQueue(line: String, day: String, timestamp: String) {
        guard cappedDay != day else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(forDay: day)
        let data = Data((line + "\n").utf8)
        let notice = "[\(timestamp)] [codenv] log size limit reached\n"
        let noticeData = Data(notice.utf8)

        let exists = fm.fileExists(atPath: url.path)
        var size: UInt64 = 0
        if exists {
            if let attrs = try? fm.attributesOfItem(atPath: url.path), let s = attrs[.size] as? NSNumber {
                size = s.uint64Value
            }
        }

        // 新檔與既有檔皆走同樣容量判斷：若目前大小加上此行與提示行會超標，則停止寫入常規行，改寫純 ASCII 提示行
        if size + UInt64(data.count) + UInt64(noticeData.count) > maxFileBytes || size + UInt64(noticeData.count) >= maxFileBytes {
            cappedDay = day
            // 空間不夠就不寫，不要截一半
            if maxFileBytes >= size, UInt64(maxFileBytes - size) >= UInt64(noticeData.count) {
                if !exists {
                    _ = fm.createFile(atPath: url.path, contents: noticeData, attributes: [.posixPermissions: 0o600])
                } else if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    try? h.seekToEnd()
                    if !tailHasCapMarker(url: url, size: size) {
                        try? h.write(contentsOf: noticeData)
                    }
                }
            }
            return
        }

        if !exists {
            _ = fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            return
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    private static func tailHasCapMarker(url: URL, size: UInt64) -> Bool {
        guard size > 0, let r = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? r.close() }
        try? r.seek(toOffset: size > 256 ? size - 256 : 0)
        let tail = String(decoding: (try? r.readToEnd()) ?? Data(), as: UTF8.self)
        return tail.contains("[codenv] log size limit reached")
    }
}

// MARK: - Console 視窗

final class EventConsoleWindowController: NSWindowController {
    static let shared = EventConsoleWindowController()
    static let didOpen = Notification.Name("CodenvEventConsoleDidOpen")

    private init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isRestorable = false
        w.title = L("事件紀錄")
        w.contentViewController = NSHostingController(rootView: EventConsoleView())
        w.setContentSize(NSSize(width: 760, height: 480))
        w.minSize = NSSize(width: 520, height: 320)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        let wasVisible = window?.isVisible == true
        if CommandLine.arguments.contains("--state-dir") {
            // 測試實例（使用者規則 10/29）：不搶前景、不搶文字框焦點，只把視窗擺出來
            window?.orderFrontRegardless()
        } else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if !wasVisible {
            NotificationCenter.default.post(name: Self.didOpen, object: nil)
        }
    }
}

private struct EventConsoleView: View {
    @State private var recording = EventLog.enabled
    @State private var statusText: String?
    @State private var clearStatusWork: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("只記最近 3 天，不含對話內容與完整網址"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(L("記錄"), isOn: Binding(get: { recording }, set: { recording = $0; EventLog.enabled = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button(action: confirmClearToday) {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help(L("清除畫面與今天的紀錄檔"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            EventLogTextView()

            Divider()

            HStack(spacing: 10) {
                Button(L("拷貝最近 3 天")) { copyRecent() }
                Button(L("在 Finder 顯示")) { EventLog.revealInFinder() }
                if let statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Edition.display(EventLog.dir))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 520, minHeight: 320)
        .onReceive(NotificationCenter.default.publisher(for: EventLog.changed)) { _ in
            recording = EventLog.enabled
        }
    }

    private func copyRecent() {
        EventLog.copyRecentThreeDays { count in
            showStatus(count > 0 ? L("已拷貝 \(count) 行") : L("目前沒有可拷貝的紀錄"))
        }
    }

    private func showStatus(_ text: String) {
        clearStatusWork?.cancel()
        statusText = text
        let work = DispatchWorkItem { statusText = nil }
        clearStatusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func confirmClearToday() {
        let alert = NSAlert()
        alert.messageText = L("清除今天的事件紀錄？")
        alert.informativeText = L("畫面和今天的紀錄檔會清掉；前兩天的紀錄檔不受影響。")
        alert.addButton(withTitle: L("清除"))
        alert.addButton(withTitle: L("取消"))
        alert.buttons.first?.hasDestructiveAction = true
        if let w = EventConsoleWindowController.shared.window, w.isVisible {
            alert.beginSheetModal(for: w) { r in
                if r == .alertFirstButtonReturn { EventLog.clearToday() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            EventLog.clearToday()
        }
    }
}

/// 深色等寬字的唯讀文字區：在底部時自動跟著新事件捲動；使用者往上捲看舊紀錄時不硬拉回底部
private struct EventLogTextView: NSViewRepresentable {
    static let bgColor = NSColor(srgbRed: 0.10, green: 0.105, blue: 0.125, alpha: 1)
    static let fgColor = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.94, alpha: 1)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let textAttrs: [NSAttributedString.Key: Any] = [
        .font: monoFont,
        .foregroundColor: fgColor,
    ]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.bgColor
        scroll.appearance = NSAppearance(named: .darkAqua)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 740, height: 360))
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 740, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.drawsBackground = true
        tv.backgroundColor = Self.bgColor
        tv.textColor = Self.fgColor
        tv.font = Self.monoFont
        tv.typingAttributes = Self.textAttrs
        tv.selectedTextAttributes = [
            .backgroundColor: NSColor(srgbRed: 0.24, green: 0.34, blue: 0.52, alpha: 1),
            .foregroundColor: NSColor.white,
        ]
        tv.textContainerInset = NSSize(width: 10, height: 10)

        scroll.documentView = tv
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(scroll: scroll, textView: tv)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    final class Coordinator {
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?
        private var observers: [NSObjectProtocol] = []
        private var lastSeq: UInt64 = 0
        private var displayedLineCount = 0
        private var pinnedToBottom = true
        private var isProgrammaticScroll = false

        deinit {
            for o in observers { NotificationCenter.default.removeObserver(o) }
        }

        func attach(scroll: NSScrollView, textView tv: NSTextView) {
            scrollView = scroll
            textView = tv
            reload(forceBottom: true)

            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                self?.updatePinnedState()
            })
            observers.append(nc.addObserver(forName: EventLog.didAppend, object: nil, queue: .main) { [weak self] n in
                guard let line = n.userInfo?["line"] as? String,
                      let seq = n.userInfo?["seq"] as? UInt64 else { return }
                self?.append(line: line, seq: seq)
            })
            observers.append(nc.addObserver(forName: EventLog.didReload, object: nil, queue: .main) { [weak self] _ in
                self?.reload(forceBottom: false)
            })
            observers.append(nc.addObserver(forName: EventConsoleWindowController.didOpen, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.reload(forceBottom: true)
                DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
            })
        }

        private func updatePinnedState() {
            guard !isProgrammaticScroll, let scroll = scrollView, let tv = textView else { return }
            let vis = scroll.contentView.bounds
            let docH = tv.bounds.height
            pinnedToBottom = docH <= vis.height + 4 || vis.maxY >= docH - 28
        }

        private func reload(forceBottom: Bool) {
            guard let tv = textView else { return }
            let shouldScroll = forceBottom || pinnedToBottom
            let snap = EventLog.snapshot()
            lastSeq = snap.seq
            displayedLineCount = snap.lines.count
            let body = snap.lines.joined(separator: "\n")
            isProgrammaticScroll = true
            tv.textStorage?.setAttributedString(NSAttributedString(string: body, attributes: EventLogTextView.textAttrs))
            isProgrammaticScroll = false
            if shouldScroll { scrollToBottom() }
        }

        private func append(line: String, seq: UInt64) {
            guard seq > lastSeq, let tv = textView, let ts = tv.textStorage else { return }
            lastSeq = seq
            let shouldScroll = pinnedToBottom
            let prefix = displayedLineCount > 0 ? "\n" : ""
            isProgrammaticScroll = true
            ts.append(NSAttributedString(string: prefix + line, attributes: EventLogTextView.textAttrs))
            displayedLineCount += 1

            // 在底部跟捲時修剪超過 maxMemoryLines；若往上捲看舊行則加硬上限（2 倍 maxMemoryLines），超過強制從頭刪到 maxMemoryLines
            let hardCap = EventLog.maxMemoryLines * 2
            let needTrim = (shouldScroll && displayedLineCount > EventLog.maxMemoryLines) || (displayedLineCount > hardCap)
            if needTrim {
                while displayedLineCount > EventLog.maxMemoryLines {
                    let r = (ts.string as NSString).range(of: "\n")
                    guard r.location != NSNotFound else { break }
                    ts.deleteCharacters(in: NSRange(location: 0, length: r.location + 1))
                    displayedLineCount -= 1
                }
            }
            isProgrammaticScroll = false
            if shouldScroll { scrollToBottom() }
        }

        private func scrollToBottom() {
            guard let tv = textView else { return }
            isProgrammaticScroll = true
            if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }
            tv.scrollRangeToVisible(NSRange(location: (tv.string as NSString).length, length: 0))
            pinnedToBottom = true
            isProgrammaticScroll = false
        }
    }
}
