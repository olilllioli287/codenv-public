import AppKit
import Darwin

// 聊天輸入框送出前的金鑰攔截（所有引擎共用：輸入框是唯一入口，Claude、Codex、Copilot、agy、OpenCode、本機模型都經過這裡）。
// 命中就不送出，跳卡片：存到金鑰管理（輸入框裡那段換成〔金鑰：NVIDIA，已存〕）／取消／仍要送出（再確認一次）。
// 偵測樣式在 KeyVault.swift 的 KeyScan。

enum KeyGuardDecision {
    case save(service: String, label: String)    // service＝鑰匙圈 service 全名；label＝輸入框裡顯示的名字
    case sendAnyway
    case notAKey                                 // 「這段不是金鑰，以後別再攔」：記錄誤攔並加入精確字串白名單
    case cancel
}

enum KeyGuardFileDecision {
    case cancel
    case sendAnyway
    case notAKey
}

struct KeyGuardFileWarning {
    let name: String
    let source: String
    let hits: [KeyHit]
}

enum KeyGuardUnscannedReason: String {
    case unavailable
    case symbolicLink
    case notRegularFile
    case openFailed
    case readFailed
    case changedWhileReading
}

struct KeyGuardUnscannedFile {
    let name: String
    let reason: KeyGuardUnscannedReason
}

enum KeyGuardFileScanResult {
    case clean(truncated: Bool)
    case hits(KeyGuardFileWarning, truncated: Bool)
    case unscanned(KeyGuardUnscannedFile)
}

struct KeyGuardLearnedFeature: Identifiable {
    let id: String
    let rule: String
    let feature: String
    let count: Int
}

enum KeyGuard {
    /// 測試用：直接給決定，不跳視窗（--keyguard-test）
    static var testDecision: ((KeyHit) -> KeyGuardDecision)?
    static var testConfirm: (() -> Bool)?
    static var testFileDecision: (() -> KeyGuardFileDecision)?
    static var testBigFileDecision: (() -> Bool)?
    static var testUnscannedDecision: (() -> Bool)?
    /// 隔離探針觀察真正進入產品確認路徑的項目；nil 時不影響正式行為。
    static var testFileWarningObserver: (([KeyGuardFileWarning], Bool) -> Void)?
    static var testBigFileObserver: (([String]) -> Void)?
    static var testUnscannedObserver: (([KeyGuardUnscannedFile]) -> Void)?

    private static let allowKey = "keyAllowHashes"
    private static let learningFile = "keyguard-false-positives.jsonl"
    private static let stateLock = NSRecursiveLock()
    private static var wired = false
    private static var loggedSuppressions: Set<String> = []
    private static func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// 把「這段不是金鑰」的雜湊清單接上設定檔（只記雜湊）。第一次用到時接
    static func wire() {
        withStateLock {
            guard !wired else { return }
            let allowHashes = Set((appDefaults.array(forKey: allowKey) as? [String]) ?? [])
            let learning = loadLearningState()
            let callback: (String, String, Int) -> Void = { rule, feature, count in
                noteLearnedSuppression(rule: rule, feature: feature, count: count)
            }
            KeyScan.replaceState(allowHashes: allowHashes, learnedFeatureCounts: learning.counts,
                                 onLearnedSuppression: callback)
            loggedSuppressions = learning.logged
            wired = true
        }
    }
    static func allow(_ text: String) {
        withStateLock {
            wire()
            KeyScan.insertAllowHash(KeyScan.hash(text))
            appDefaults.set(Array(KeyScan.allowHashes), forKey: allowKey)
        }
    }

    /// 精確白名單及學習都只接受弱規則；JWT 與明確前綴永遠保留警告。
    static func allow(_ hit: KeyHit) {
        guard hit.isLearnableWeak else { return }
        allow(hit.key)
    }

    static func recordFalsePositive(_ hit: KeyHit, source: String) {
        guard hit.isLearnableWeak else { return }
        withStateLock {
            allow(hit)
            recordLearning(type: "false-positive", hit: hit, source: source)
        }
    }

    /// 附件對話框的「不是金鑰」動作；同一份回報含強規則時整體拒絕學習。
    @discardableResult
    static func recordNotAKey(_ warnings: [KeyGuardFileWarning]) -> Bool {
        guard warnings.flatMap(\.hits).allSatisfy(\.isLearnableWeak) else { return false }
        return withStateLock {
            for warning in warnings {
                for hit in warning.hits { recordFalsePositive(hit, source: warning.source) }
            }
            return true
        }
    }

    private static func records() -> [[String: Any]] {
        withStateLock {
            guard let text = try? String(contentsOf: learningURL(), encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
    }

    private static func storedFeature(_ record: [String: Any]) -> String? {
        if let feature = record["feature"] as? String, !feature.isEmpty { return feature }
        // 舊版誤報紀錄有 context/text，讀取時轉成穩定特徵；新紀錄不再保存金鑰原文。
        guard let context = record["context"] as? String, let text = record["text"] as? String else { return nil }
        let range = (context as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        let hit = KeyHit(range: range, text: text, kind: record["rule"] as? String ?? "", service: nil, strong: false)
        return KeyScan.feature(for: hit, in: context)
    }

    private static func loadLearningState() -> (counts: [String: Int], logged: Set<String>) {
        var counts: [String: Int] = [:]
        var logged = Set<String>()
        for record in records() {
            guard let type = record["type"] as? String,
                  let rule = record["rule"] as? String,
                  let feature = storedFeature(record) else { continue }
            guard ["十六進位金鑰", "高熵長字串"].contains(rule) else { continue }
            // 舊學習檔可能有 key=／secret=／任意屬性名特徵：載入時不採用（檔案不動）
            guard KeyScan.isSafeLearnedFeature(feature) else { continue }
            let id = KeyScan.learningKey(rule: rule, feature: feature)
            if type == "false-positive" { counts[id, default: 0] += 1 }
            if type == "learned-suppressed" { logged.insert(id) }
        }
        return (counts, logged)
    }

    static func reloadLearning() {
        withStateLock {
            wire()
            let learning = loadLearningState()
            KeyScan.learnedFeatureCounts = learning.counts
            loggedSuppressions = learning.logged
        }
    }

    private static func appendRecord(_ record: [String: Any]) {
        withStateLock {
            let url = learningURL()
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .fragmentsAllowed]) + Data([0x0A])
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                NSLog("KeyGuard learning log write failed: %@", String(describing: error))
            }
        }
    }

    /// 已學會的前文每個特徵只記一次抑制紀錄，避免同一檔案反覆掃描時灌滿 JSONL。
    static func noteLearnedSuppression(rule: String, feature: String, count: Int) {
        withStateLock {
            wire()
            let id = KeyScan.learningKey(rule: rule, feature: feature)
            guard !loggedSuppressions.contains(id) else { return }
            loggedSuppressions.insert(id)
            appendRecord(["type": "learned-suppressed", "rule": rule, "feature": feature,
                          "count": count, "timestamp": ISO8601DateFormatter().string(from: Date())])
        }
    }

    static func learnedFeatures() -> [KeyGuardLearnedFeature] {
        withStateLock {
            wire()
            return KeyScan.snapshot().learnedFeatureCounts.compactMap { id, count in
                guard count >= 2, let separator = id.firstIndex(of: "\u{1f}") else { return nil }
                return KeyGuardLearnedFeature(id: id, rule: String(id[..<separator]), feature: String(id[id.index(after: separator)...]), count: count)
            }.sorted { $0.rule == $1.rule ? $0.feature < $1.feature : $0.rule < $1.rule }
        }
    }

    /// 移除一個已學特徵及其精確 allow 雜湊，刪除後相同弱規則會重新警告。
    static func removeLearnedFeature(_ id: String) {
        withStateLock {
            wire()
            let existing = records()
            var kept: [[String: Any]] = []
            var removeHashes: Set<String> = []
            for record in existing {
                let rule = record["rule"] as? String ?? ""
                let feature = storedFeature(record)
                let recordID = feature.map { KeyScan.learningKey(rule: rule, feature: $0) }
                if recordID == id, ["false-positive", "learned-suppressed"].contains(record["type"] as? String ?? "") {
                    if let hash = record["allowHash"] as? String { removeHashes.insert(hash) }
                    if let oldText = record["text"] as? String { removeHashes.insert(KeyScan.hash(oldText)) }
                } else {
                    kept.append(record)
                }
            }
            let body = kept.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
                .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
            do {
                try FileManager.default.createDirectory(at: learningURL().deletingLastPathComponent(), withIntermediateDirectories: true)
                try (body.isEmpty ? "" : body + "\n").write(to: learningURL(), atomically: true, encoding: .utf8)
            } catch {
                NSLog("KeyGuard learning log update failed: %@", String(describing: error))
                return
            }
            let learning = loadLearningState()
            let allowHashes = KeyScan.snapshot().allowHashes.subtracting(removeHashes)
            appDefaults.set(Array(allowHashes), forKey: allowKey)
            KeyScan.updateAllowAndLearned(allowHashes: allowHashes, learnedFeatureCounts: learning.counts)
            loggedSuppressions = learning.logged
        }
    }

    /// 將使用者對命中結果的回饋附加到 JSONL。誤報只存特徵與命中雜湊，不保存金鑰原文。
    static func recordLearning(type: String, hit: KeyHit, source: String) {
        withStateLock {
            wire()
            guard type != "false-positive" || hit.isLearnableWeak else { return }
            var record: [String: Any] = ["type": type, "rule": hit.kind, "timestamp": ISO8601DateFormatter().string(from: Date())]
            if type == "false-positive" {
                record["allowHash"] = KeyScan.hash(hit.key)
                if let feature = KeyScan.feature(for: hit, in: source) { record["feature"] = feature }
            } else {
                let context: String
                if let match = Range(hit.range, in: source) {
                    let start = source.index(match.lowerBound, offsetBy: -min(40, source.distance(from: source.startIndex, to: match.lowerBound)))
                    let end = source.index(match.upperBound, offsetBy: min(40, source.distance(from: match.upperBound, to: source.endIndex)))
                    context = String(source[start..<end])
                } else { context = "" }
                record["length"] = hit.text.count
                record["keywords"] = Self.contextKeywords(context)
            }
            appendRecord(record)
            if type == "false-positive" { reloadLearning() }
        }
    }

    private static func learningURL() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--state-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true).appendingPathComponent(learningFile)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI 工作台", isDirectory: true)
            .appendingPathComponent(learningFile)
    }

    private static func contextKeywords(_ context: String) -> [String] {
        let candidates = ["commit", "hash", "sha", "uuid", "git", "雜湊", "提交", "版本", "金鑰", "key", "token", "secret"]
        let lower = context.lowercased()
        return candidates.filter { lower.contains($0.lowercased()) }
    }
    static func shortHint(_ hit: KeyHit) -> String { "\(hit.kind)…" + String(hit.key.suffix(4)) }

    /// 卡片：這一段看起來像金鑰
    static func ask(_ hit: KeyHit) -> KeyGuardDecision {
        if let t = testDecision {
            let decision = t(hit)
            if case .notAKey = decision, !hit.isLearnableWeak {
                return confirmSend() ? .sendAnyway : .cancel
            }
            return decision
        }
        let items: [KeyService] = KeyService.known + KeyService.extra.filter { $0.id != "other" }
        let a = NSAlert()
        a.messageText = L("這看起來像 API 金鑰")
        let info = L("送出會留在聊天紀錄，並傳給模型。要改存到金鑰管理嗎？\n偵測到：") + shortHint(hit)
        a.informativeText = info
        a.addButton(withTitle: L("存到金鑰管理"))
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("仍要送出…"))
        if hit.isLearnableWeak { a.addButton(withTitle: L("這段不是金鑰，以後別再攔")) }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 28, width: 260, height: 26), pullsDown: false)
        pop.addItems(withTitles: items.map(\.name) + [L("其他（自己取名）")])
        let guess = items.firstIndex { $0.id == hit.service } ?? items.count
        pop.selectItem(at: guess)
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = L("取個名字，例如 my-service")
        name.isHidden = guess != items.count
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        box.addSubview(pop); box.addSubview(name)
        final class Toggler: NSObject {
            let pop: NSPopUpButton, field: NSTextField, last: Int
            init(_ p: NSPopUpButton, _ f: NSTextField, _ l: Int) { pop = p; field = f; last = l }
            @objc func changed() { field.isHidden = pop.indexOfSelectedItem != last }
        }
        let tg = Toggler(pop, name, items.count)
        pop.target = tg; pop.action = #selector(Toggler.changed)
        a.accessoryView = box
        while true {
            let r = withExtendedLifetime(tg) { a.runModal() }
            switch r {
            case .alertFirstButtonReturn:
                let i = pop.indexOfSelectedItem
                let service: String, label: String
                if i < items.count {
                    service = KeyVault.service(items[i].id); label = items[i].name
                } else {
                    let n = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if n.isEmpty { NSSound.beep(); name.isHidden = false; continue }     // 沒取名：卡片留著
                    service = KeyVault.customService(named: n); label = n
                }
                // 這個名字已經有金鑰了：問過才覆蓋（不同的名字可能轉成同一個項目名稱）
                if KeyVault.status(service: service).exists {
                    let c = NSAlert()
                    c.messageText = L("「\(label)」已經有一把金鑰了，要換成這一把嗎？")
                    c.informativeText = L("舊的會被覆蓋，沒辦法還原。")
                    c.addButton(withTitle: L("取消")); c.addButton(withTitle: L("覆蓋"))
                    if c.runModal() != .alertSecondButtonReturn { continue }
                }
                return .save(service: service, label: label)
            case .alertThirdButtonReturn:
                if hit.low { return .sendAnyway }          // 低信心（JWT）：不用再確認第二次
                return confirmSend() ? .sendAnyway : .cancel
            case NSApplication.ModalResponse(rawValue: 1003) where hit.isLearnableWeak:
                return .notAKey
            default:
                return .cancel
            }
        }
    }

    static func confirmSend() -> Bool {
        if let t = testConfirm { return t() }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = L("真的要把這串金鑰送出嗎？")
        a.informativeText = L("它會寫進聊天紀錄（~/.claude/projects 底下的檔案，之後沒辦法從那裡刪乾淨），也會傳給模型供應商。送出後只能去服務商那邊作廢重產。")
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("仍要送出"))
        return a.runModal() == .alertSecondButtonReturn
    }

    /// 附件警告：只在全部命中都是弱規則時提供「不是金鑰」；強規則需保留明確警告。
    static func askFiles(_ warnings: [KeyGuardFileWarning], truncated: Bool = false) -> Bool {      // true＝仍要送出
        let canLearn = warnings.flatMap(\.hits).allSatisfy(\.isLearnableWeak)
        if let test = testFileDecision {
            testFileWarningObserver?(warnings, truncated)
            switch test() {
            case .cancel: return false
            case .sendAnyway: return confirmSend()
            case .notAKey:
                return recordNotAKey(warnings)
            }
        }
        let a = NSAlert()
        a.messageText = L("附的檔案裡有像 API 金鑰的內容")
        a.informativeText = L("檔案：") + warnings.map(\.name).joined(separator: "、") + (truncated ? L("\n（有的檔案超過 8 MB，只掃了前 8 MB。）") : "") + L("\n模型讀了檔案，金鑰就會留在聊天紀錄並傳給模型。建議先把金鑰從檔案拿掉，改存到設定的「金鑰」分頁。")
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("仍要送出…"))
        if canLearn { a.addButton(withTitle: L("不是金鑰")) }
        switch a.runModal() {
        case .alertSecondButtonReturn: return confirmSend()
        case .alertThirdButtonReturn where canLearn:
            return recordNotAKey(warnings)
        default: return false
        }
    }

    /// 附的檔案超過 8 MB：只檢查了前 8 MB，後面沒檢查。true＝仍要送出
    static func askBigFiles(_ names: [String]) -> Bool {
        if let t = testBigFileDecision { testBigFileObserver?(names); return t() }
        let a = NSAlert()
        a.messageText = L("這個檔案只檢查了前 8 MB")
        a.informativeText = L("檔案：") + names.joined(separator: "、") + L("\n超過 8 MB 的部分沒有檢查有沒有 API 金鑰。要照樣送出嗎？")
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("照樣送出"))
        return a.runModal() == .alertSecondButtonReturn
    }

    /// 附件沒有檢查到內容時的專用確認；不能借用「只檢查前 8 MB」文案。
    static func askUnscannedFiles(_ files: [KeyGuardUnscannedFile]) -> Bool {
        if let test = testUnscannedDecision { testUnscannedObserver?(files); return test() }
        let alert = NSAlert()
        alert.messageText = L("這個附件沒有檢查金鑰")
        alert.informativeText = L("檔案：") + files.map(\.name).joined(separator: "、")
            + L("\n因為檔案無法安全讀取或不是一般檔案，沒有檢查裡面是否有 API 金鑰。要照樣送出嗎？")
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("照樣送出"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    static let fileScanLimit = 8_000_000

    /// 同步核心供舊入口與背景掃描共用。先以 lstat/open(O_NOFOLLOW) 檢查型態，特殊檔不會被開啟讀取。
    static func scanFileCore(_ url: URL, using snapshot: KeyScan.StateSnapshot? = nil,
                             learnedSuppressionCollector: ((String, String, Int) -> Void)? = nil) -> KeyGuardFileScanResult {
        var before = stat()
        let lstatResult = url.path.withCString { path in lstat(path, &before) }
        guard lstatResult == 0 else {
            return .unscanned(KeyGuardUnscannedFile(name: url.lastPathComponent, reason: .unavailable))
        }
        if before.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            return .unscanned(KeyGuardUnscannedFile(name: url.lastPathComponent, reason: .symbolicLink))
        }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_size >= 0 else {
            return .unscanned(KeyGuardUnscannedFile(name: url.lastPathComponent, reason: .notRegularFile))
        }

        let fd = url.path.withCString { path in open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else {
            return .unscanned(KeyGuardUnscannedFile(name: url.lastPathComponent, reason: .openFailed))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino, opened.st_size >= 0 else {
            return .unscanned(KeyGuardUnscannedFile(name: url.lastPathComponent, reason: .changedWhileReading))
        }
        let truncated = opened.st_size > off_t(fileScanLimit)
        let data: Data
        do {
            data = try handle.read(upToCount: fileScanLimit) ?? Data()
        } catch {
            return .unscanned(KeyGuardUnscannedFile(name: url.lastPathComponent, reason: .readFailed))
        }
        var afterRead = stat()
        guard fstat(fd, &afterRead) == 0, afterRead.st_dev == opened.st_dev,
              afterRead.st_ino == opened.st_ino, afterRead.st_size == opened.st_size else {
            return .unscanned(KeyGuardUnscannedFile(name: url.lastPathComponent, reason: .changedWhileReading))
        }
        if data.isEmpty {
            guard opened.st_size == 0 else {
                return .unscanned(KeyGuardUnscannedFile(name: url.lastPathComponent, reason: .readFailed))
            }
            return .clean(truncated: false)
        }
        let source = String(decoding: data, as: UTF8.self)
        let hits = KeyScan.scan(source, using: snapshot, learnedSuppressionCollector: learnedSuppressionCollector)
        guard !hits.isEmpty else { return .clean(truncated: truncated) }
        return .hits(KeyGuardFileWarning(name: url.lastPathComponent, source: source, hits: hits), truncated: truncated)
    }

    /// 相容舊同步入口：讀不到與乾淨仍回 nil；新背景流程必須直接檢查明確的 core 結果。
    static func scanFile(_ url: URL) -> KeyGuardFileWarning? {
        guard case .hits(let warning, _) = scanFileCore(url) else { return nil }
        return warning
    }

    /// 相容既有呼叫點：檔案裡是否有仍需警告的命中。
    static func fileIsOverScanLimit(_ url: URL) -> Bool { ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 8_000_000 }
    static func fileHasKey(_ url: URL) -> Bool { scanFile(url) != nil }
}
