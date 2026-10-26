import AppKit

// 按鍵統計：記 codenv 裡每個快捷鍵按了幾次（之後拿來調整按鍵）。
// 只記帶 ⌘ 或 ⌃ 的組合、⌃ A 前綴後面接的那一鍵、Esc／Tab／Enter／方向鍵這類功能鍵（可以帶 ⌥ ⇧）；一般打的字不記（不會記到內容）。
// 只看不攔：在 App 的 sendEvent 看（KeyStatsApp），所有按鍵都會先經過這裡。
// 不用 local monitor：好幾個 monitor 誰先拿到不固定（實測），PrefixKeys 先拿到就會把 ⌃ A 攔走、這裡看不到。
// 存在 state 資料夾：key-stats.json（累計）＋ key-stats.txt（排好序，給人看）。

final class KeyStats {
    static let shared = KeyStats()

    private struct Entry: Codable { var total = 0; var places: [String: Int] = [:] }
    private struct File: Codable { var since: Date; var keys: [String: Entry] }

    private var file = File(since: Date(), keys: [:])
    private var dir: URL?
    private var prefixAt: TimeInterval = 0     // 剛按 ⌃ A 的時間：下一鍵記成「⌃ A → x」
    private var saveWork: DispatchWorkItem?
    private var last: (time: TimeInterval, code: UInt16) = (0, 0)   // 聊天畫面沒處理的鍵會被送回來再走一次，同一個事件只算一次

    func start(in directory: URL) {
        guard dir == nil else { return }
        dir = directory
        if let d = try? Data(contentsOf: jsonURL), let f = try? Self.decoder.decode(File.self, from: d) { file = f }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in self?.saveNow() }
    }

    private var jsonURL: URL { (dir ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("key-stats.json") }
    private var textURL: URL { (dir ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("key-stats.txt") }

    func saw(_ e: NSEvent) {
        guard dir != nil else { return }
        guard !e.isARepeat else { return }   // 按住不放的自動重複不算
        guard e.timestamp != last.time || e.keyCode != last.code else { return }
        last = (e.timestamp, e.keyCode)
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let now = ProcessInfo.processInfo.systemUptime
        var key = Self.name(e.keyCode, e.charactersIgnoringModifiers)
        var shown = mods
        // ⇧＋符號鍵直接寫打出來的符號（⌃ A → ? 比 ⌃ A → ⇧ / 好認，跟 PrefixKeys 的說明一樣）
        if mods.contains(.shift), let k = Self.letters[e.keyCode], !k.first!.isLetter,
           let c = e.charactersIgnoringModifiers, c.count == 1, c != k {
            key = c
            shown.remove(.shift)
        }
        let combo = Self.symbols(shown) + key
        // ⌃ A 之後 3 秒內的下一鍵：跟前綴記在一起（⌃ A → H），這時一般字母也算（它是指令）
        if prefixAt > 0, now - prefixAt < 3 {
            prefixAt = 0
            add("⌃ A → " + combo, e)
            return
        }
        if mods == .control, e.keyCode == 0 { prefixAt = now; return }
        // 有 ⌘ 或 ⌃ 才算快捷鍵；⌥＋字母在 macOS 是打特殊字元（⌥ E 是重音），只有 ⌥（或 ⇧）的只算功能鍵（⌥ ← 跳一個字）
        let strong = !mods.intersection([.command, .control]).isEmpty
        guard strong || Self.specialAlone.contains(e.keyCode) else { return }
        add(combo, e)
    }

    private func add(_ combo: String, _ e: NSEvent) {
        let place = Self.place(e.window?.firstResponder)
        file.keys[combo, default: Entry()].total += 1
        file.keys[combo, default: Entry()].places[place, default: 0] += 1
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        guard dir != nil, let d = try? Self.encoder.encode(file) else { return }
        try? d.write(to: jsonURL, options: .atomic)
        try? report().write(to: textURL, atomically: true, encoding: .utf8)
    }

    /// 給人看的排行：次數多的在前，後面附在哪裡按的
    private func report() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        var s = "codenv 按鍵統計（\(df.string(from: file.since)) 起，更新於 \(df.string(from: Date()))）\n\n"
        for (k, v) in file.keys.sorted(by: { $0.value.total != $1.value.total ? $0.value.total > $1.value.total : $0.key < $1.key }) {
            let where_ = v.places.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "、")
            s += "\(String(v.total).leftPad(6))  \(k)　（\(where_)）\n"
        }
        return s
    }

    /// 焦點在哪：同一個鍵在聊天框、終端機裡意思可能不一樣
    private static func place(_ r: NSResponder?) -> String {
        guard let r else { return "其他" }
        let n = String(describing: type(of: r))
        if n == "ChatTextView" { return "聊天輸入框" }
        if n.contains("WebView") || n.hasPrefix("WK") { return "聊天內容" }
        if n.contains("Terminal") { return "終端機" }
        if r is NSWindow { return "視窗" }
        if r is NSTextView { return "其他文字欄" }
        return "其他"
    }

    /// 修飾鍵照 Apple 的順序，符號之間加空格（⌃ ⇧ A）
    private static func symbols(_ m: NSEvent.ModifierFlags) -> String {
        var s = ""
        if m.contains(.control) { s += "⌃ " }
        if m.contains(.option) { s += "⌥ " }
        if m.contains(.shift) { s += "⇧ " }
        if m.contains(.command) { s += "⌘ " }
        return s
    }

    private static let special: [UInt16: String] = [
        53: "Esc", 48: "Tab", 36: "Enter", 76: "Enter", 51: "Delete", 117: "⌦", 49: "Space",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    // 沒有修飾鍵時只算這些（Delete、Space 是打字，不算）
    private static let specialAlone: Set<UInt16> = [53, 48, 36, 76, 117, 123, 124, 125, 126, 115, 119, 116, 121, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// 按鍵名稱用鍵盤位置（keyCode）決定，不受輸入法影響
    private static let letters: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]
    private static func name(_ code: UInt16, _ chars: String?) -> String {
        special[code] ?? letters[code] ?? (chars?.uppercased() ?? "#\(code)")
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// 整個 App 用這個類別（main.swift 的 KeyStatsApp.shared）：按鍵先給統計看一眼，再照常處理
final class KeyStatsApp: NSApplication {
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown { KeyStats.shared.saw(e) }
        super.sendEvent(e)
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
