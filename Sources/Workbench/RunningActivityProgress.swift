import Foundation
import Combine
import Darwin

/// 進度檔只可從 Claude 設定、目前專案或本使用者的暫存目錄讀取。
enum ProgressPathPolicy {
    static func roots(project: URL? = nil) -> [URL] {
        [ClaudeSessions.home, project, URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)]
            .compactMap { $0 }
    }

    /// 回傳已解 symlink 的路徑，確保後續開檔使用同一個白名單內的目標。
    static func canonicalAllowedURL(_ url: URL, roots: [URL]) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let path = resolved.path
        let allowed = roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard rootPath != "/" else { return false }
            return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
        return allowed ? resolved : nil
    }
}

private struct AgentMetadata {
    let toolUseID: String?
    let description: String?
}

/// 子代理的 metadata 以實際檔案修改時間快取，最多保留 256 筆。
private final class AgentMetadataCache {
    private struct Entry {
        let modifiedAt: Date
        let metadata: AgentMetadata?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let limit = 256

    func value(at url: URL, allowedRoots: [URL]) -> AgentMetadata? {
        guard let safeURL = ProgressPathPolicy.canonicalAllowedURL(url, roots: allowedRoots),
              let modifiedAt = (try? safeURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return nil
        }
        let path = safeURL.path
        lock.lock()
        if let entry = entries[path], entry.modifiedAt == modifiedAt {
            lock.unlock()
            return entry.metadata
        }
        lock.unlock()

        var metadata: AgentMetadata?
        if let data = try? Data(contentsOf: safeURL),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            metadata = AgentMetadata(toolUseID: object["toolUseId"] as? String,
                                     description: object["description"] as? String)
        }

        lock.lock()
        entries[path] = Entry(modifiedAt: modifiedAt, metadata: metadata)
        if entries.count > limit, let evicted = entries.keys.first(where: { $0 != path }) {
            entries.removeValue(forKey: evicted)
        }
        lock.unlock()
        return metadata
    }
}

/// 只在本機右欄顯示的進度來源，不會寫入 Store、看板或共用狀態檔。
enum RunningActivityProgress {
    static let tailLimit = 64 * 1024
    static let staleAfter: TimeInterval = 5 * 60

    enum Source {
        case agent(directory: URL, taskID: String, description: String, since: Date, allowedRoots: [URL])
        case outputs([URL], allowedRoots: [URL])
    }

    struct Snapshot: Equatable {
        var line: String
        var kind: String
        var stale: Bool
        var staleMinutes: Int?
    }

    static let none = Snapshot(line: "", kind: "none", stale: false, staleMinutes: nil)

    /// 只讀最後 64 KB；格式或檔案無法辨識時安靜退回 none。
    static func read(_ url: URL, now: Date = Date()) -> Snapshot {
        read(url, allowedRoots: ProgressPathPolicy.roots(), now: now)
    }

    static func read(_ url: URL, allowedRoots: [URL], now: Date = Date()) -> Snapshot {
        guard let safeURL = ProgressPathPolicy.canonicalAllowedURL(url, roots: allowedRoots),
              let handle = try? FileHandle(forReadingFrom: safeURL) else { return none }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return none }
        let start = end > UInt64(tailLimit) ? end - UInt64(tailLimit) : 0
        do { try handle.seek(toOffset: start) } catch { return none }
        guard let data = try? handle.read(upToCount: tailLimit), !data.isEmpty else { return none }

        let text = String(decoding: data, as: UTF8.self)
        let modified = (try? safeURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let isJSONL = url.pathExtension.lowercased() == "jsonl" || lines.contains { line in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return false }
            return ["assistant", "user", "system", "result", "stream_event"].contains(object["type"] as? String ?? "")
        }
        if isJSONL { return jsonlSnapshot(lines, modified: modified, now: now) }

        guard let last = lines.reversed().first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return none }
        return snapshot(line: last, kind: "output", at: modified, now: now)
    }

    /// 找進度來源；右欄的五秒輪詢器會在 utility queue 呼叫。
    static func resolve(_ source: Source) -> URL? {
        switch source {
        case let .outputs(urls, allowedRoots):
            return urls.first { url in
                guard let safeURL = ProgressPathPolicy.canonicalAllowedURL(url, roots: allowedRoots) else { return false }
                return FileManager.default.fileExists(atPath: safeURL.path)
            }.flatMap { ProgressPathPolicy.canonicalAllowedURL($0, roots: allowedRoots) }
        case let .agent(directory, taskID, description, since, allowedRoots):
            guard let safeDirectory = ProgressPathPolicy.canonicalAllowedURL(directory, roots: allowedRoots) else { return nil }
            let safeID = taskID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } ? taskID : ""
            if !safeID.isEmpty {
                let filename = safeID.hasPrefix("agent-") ? safeID : "agent-" + safeID
                let direct = safeDirectory.appendingPathComponent(filename).appendingPathExtension("jsonl")
                if let safeDirect = ProgressPathPolicy.canonicalAllowedURL(direct, roots: allowedRoots),
                   FileManager.default.fileExists(atPath: safeDirect.path) { return safeDirect }
            }
            let logs = ((try? FileManager.default.contentsOfDirectory(at: safeDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .compactMap { ProgressPathPolicy.canonicalAllowedURL($0, roots: allowedRoots) }
                .filter { $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension.lowercased() == "jsonl" }
            let metas = logs.map { log -> (log: URL, fields: AgentMetadata?) in
                let stem = String(log.path.dropLast(".jsonl".count))
                let metaURL = URL(fileURLWithPath: stem + ".meta.json")
                return (log, agentMetadataCache.value(at: metaURL, allowedRoots: allowedRoots))
            }
            let idMatches = metas.filter { $0.fields?.toolUseID == taskID }.map { $0.log }
            if idMatches.count == 1 { return idMatches[0] }

            let descriptionMatches = metas.filter { $0.fields?.description == description }.map { $0.log }
            if descriptionMatches.count == 1 { return descriptionMatches[0] }

            let fresh = logs
                .filter { url in
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return date >= since
                }
            // 描述和 id 都無法唯一配對時，只接受 since 之後唯一新增或更新的紀錄。
            return fresh.count == 1 ? fresh[0] : nil
        }
    }

    private static let agentMetadataCache = AgentMetadataCache()

    private static func jsonlSnapshot(_ lines: [String], modified: Date, now: Date) -> Snapshot {
        for raw in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "assistant",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let date = parseDate(object["timestamp"] as? String) ?? modified
            if let tool = content.reversed().first(where: { $0["type"] as? String == "tool_use" }) {
                let name = tool["name"] as? String ?? L("工具")
                let input = tool["input"] as? [String: Any] ?? [:]
                return snapshot(line: toolLine(name, input), kind: "tool", at: date, now: now)
            }
            if let output = content.reversed().compactMap({ block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }).first {
                return snapshot(line: output, kind: "output", at: date, now: now)
            }
        }
        return none
    }

    private static func toolLine(_ name: String, _ input: [String: Any]) -> String {
        func value(_ keys: [String]) -> String? {
            keys.compactMap { input[$0] as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        switch name {
        case "Read": return "Read " + (value(["file_path", "path"]).map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("檔案"))
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            return name + " " + (value(["file_path", "path", "notebook_path"]).map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("檔案"))
        case "Bash": return "Bash " + (value(["command"]) ?? L("指令"))
        case "Grep", "Glob": return name + " " + (value(["pattern"]) ?? L("搜尋"))
        case "WebFetch": return "WebFetch " + (value(["url"]) ?? L("網頁"))
        case "WebSearch": return "WebSearch " + (value(["query"]) ?? L("網路"))
        case "Task", "Agent": return name + " " + (value(["description", "prompt"]) ?? L("子代理"))
        default: return name
        }
    }

    private static func snapshot(line: String, kind: String, at date: Date, now: Date) -> Snapshot {
        let safe = redactAndShorten(line)
        guard !safe.isEmpty else { return none }
        let age = max(0, now.timeIntervalSince(date))
        let stale = age >= staleAfter
        return Snapshot(line: safe, kind: kind, stale: stale, staleMinutes: stale ? max(5, Int(age / 60)) : nil)
    }

    private static func redactAndShorten(_ raw: String) -> String {
        var printable = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                printable.append(Unicode.Scalar(0x20)!)
                continue
            }
            if scalar.value == 0xFFFD { continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
                continue
            default:
                printable.append(scalar)
            }
        }
        var line = String(printable).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let patterns: [(pattern: String, replacement: String)] = [
            (#"(?i)(\bAuthorization\s*[:=]\s*).+"#, "$1[遮罩]"),
            (#"(?i)([A-Z][A-Z0-9+.-]*://)[^/@\s]+:[^/@\s]+(@)"#, "$1[遮罩]$2"),
            (#"(?i)(--?[A-Z0-9_-]*(?:api[_-]?key|key|token|secret|password|passwd|credentials?|authorization|auth)(?:\s*=\s*|\s+))(?:\"[^\"]*\"|'[^']*'|[^,\s;&]+)"#, "$1[遮罩]"),
            (#"(?i)(\b[A-Z0-9_-]*(?:api[_-]?key|key|token|secret|password|passwd|credentials?|authorization|auth)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^,\s;&]+)"#, "$1[遮罩]"),
            (#"(?i)\bBearer\s+(?:\"[^\"]*\"|'[^']*'|[^,\s;&]+)"#, "[遮罩]"),
            (#"\bsk-[A-Za-z0-9_-]{8,}"#, "[遮罩]"),
            (#"\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|xox[baprs]-[A-Za-z0-9-]{12,}|nvapi-[A-Za-z0-9_-]{12,}|AIza[A-Za-z0-9_-]{20,})\b"#, "[遮罩]")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            line = regex.stringByReplacingMatches(in: line, range: range, withTemplate: replacement)
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > 30 else { return line }
        return String(line.prefix(29)) + "…"
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
    }
}

final class RunningActivityProgressModel: ObservableObject {
    @Published private(set) var snapshots: [String: RunningActivityProgress.Snapshot] = [:]
    private let queue = DispatchQueue(label: "running-activity-progress", qos: .utility)
    private let inFlightLock = NSLock()
    private var refreshInFlight = false

    func snapshot(for entry: RunningActivityEntry) -> RunningActivityProgress.Snapshot? {
        snapshots[entry.id]
    }

    func refresh(_ entries: [RunningActivityEntry]) {
        inFlightLock.lock()
        guard !refreshInFlight else {
            inFlightLock.unlock()
            return
        }
        refreshInFlight = true
        inFlightLock.unlock()

        let sources = entries.compactMap { entry in entry.progressSource.map { (entry.id, $0) } }
        queue.async { [weak self] in
            guard let self else { return }
            var fresh: [String: RunningActivityProgress.Snapshot] = [:]
            for (id, source) in sources {
                if let url = RunningActivityProgress.resolve(source) {
                    let allowedRoots: [URL]
                    switch source {
                    case let .agent(_, _, _, _, roots), let .outputs(_, roots): allowedRoots = roots
                    }
                    let value = RunningActivityProgress.read(url, allowedRoots: allowedRoots)
                    if value.kind != "none" { fresh[id] = value }
                }
            }
            DispatchQueue.main.async {
                self.snapshots = fresh
                self.inFlightLock.lock()
                self.refreshInFlight = false
                self.inFlightLock.unlock()
            }
        }
    }
}
