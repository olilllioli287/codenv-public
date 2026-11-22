import Foundation
import Darwin

struct LargeDraftImage: Sendable {
    let data: Data
    let mediaType: String
    let no: Int
    let edited: Bool
}

struct LargeDraftSnapshot: @unchecked Sendable {
    let revision: UInt64
    let writeID: UUID
    let text: String
    let quotes: [MessageQuote]
    let filePaths: [String]
    let images: [LargeDraftImage]
    let directory: URL
    let fileURL: URL
    let recoveryDirectory: URL
    let recoveryURL: URL
    let imagePrefix: String
    let testWriteDelay: TimeInterval
    // 只供 --state-dir 審查探針在「圖片已寫、JSON 尚未提交」的邊界做可重現取消。
    let testAfterPrimaryImageWrite: ((Int) -> Void)?
    // 只供 --state-dir 審查探針在正式 JSON I/O 的位置量測鎖競爭。
    let testBeforePrimaryJSONWrite: (() -> Void)?
    // 只供 --state-dir 探針在 primary writer 完成或作廢時同步取樣磁碟狀態。
    let testAfterPrimaryWrite: ((Bool) -> Void)?
}

private struct LargeDraftImageRecord: Codable {
    let no: Int
    let mediaType: String
    let file: String
    let edited: Bool
}

private struct LargeDraftRecord: Codable {
    let text: String
    let quotes: [MessageQuote]
    let filePaths: [String]
    let images: [LargeDraftImageRecord]
}

/// Per-draft serial revision gate. It deliberately has no process-wide pending registry.
final class LargeDraftWriteState: @unchecked Sendable {
    let queue: DispatchQueue
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var pending = false
    private var latest: LargeDraftSnapshot?

    init(fileURL: URL) {
        queue = DispatchQueue(label: "codenv.large-draft.\(fileURL.lastPathComponent)", qos: .utility)
    }

    func begin(_ make: (UInt64) -> LargeDraftSnapshot) -> LargeDraftSnapshot {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        pending = true
        let snapshot = make(revision)
        latest = snapshot
        return snapshot
    }

    /// Mark a debounced large draft dirty immediately, so an older queued write cannot
    /// commit after a newer edit but before its debounce fires.
    func markScheduled() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        pending = true
        latest = nil
    }

    func currentSnapshot() -> LargeDraftSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revision == candidate
    }

    func commitIfCurrent(_ candidate: UInt64, _ commit: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard revision == candidate else { return false }
        return commit()
    }

    func finish(_ candidate: UInt64, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard revision == candidate else { return }
        pending = !succeeded
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        pending = false
        latest = nil
    }

    /// 交接逾時時作廢舊 writer，但仍保留「草稿待寫」狀態，讓關格／結束路徑能建立復原快照。
    func invalidateForHandoffTimeout() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        pending = true
        latest = nil
    }
}

enum LargeDraftFileWriter {
    static func writePrimary(_ snapshot: LargeDraftSnapshot, state: LargeDraftWriteState) -> Bool {
        guard state.isCurrent(snapshot.revision) else { return false }
        if snapshot.testWriteDelay > 0 { Thread.sleep(forTimeInterval: snapshot.testWriteDelay) }
        let masked = KeyScan.redact(snapshot.text, strongOnly: true)
        guard state.isCurrent(snapshot.revision) else { return false }
        let imagePlan = makeImagePlan(snapshot, recovery: false)
        guard imagePlan != nil else { return false }
        let images = imagePlan!.records
        let record = LargeDraftRecord(text: masked, quotes: snapshot.quotes, filePaths: snapshot.filePaths, images: images)
        let json: Data
        do { json = try JSONEncoder().encode(record) }
        catch { NSLog("codenv 大草稿序列化失敗：%@", String(describing: error)); return false }
        var writtenImageURLs: [URL] = []
        defer { for url in writtenImageURLs { cleanup(url) } }
        do {
            try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
            for (index, item) in imagePlan!.files.enumerated() {
                guard state.isCurrent(snapshot.revision) else { return false }
                try writeAtomic(item.data, to: item.url)
                writtenImageURLs.append(item.url)
                snapshot.testAfterPrimaryImageWrite?(index)
            }
            let stagedJSON = try stageAtomic(json, to: snapshot.fileURL)
            defer { cleanup(stagedJSON) }
            let previousPrimaryImages = referencedImages(snapshot.fileURL, imagePrefix: snapshot.imagePrefix)
            let previousRecoveryImages = referencedImages(snapshot.recoveryURL, imagePrefix: snapshot.imagePrefix,
                                                          recovery: true)
            var displacedRecoveryURL: URL?
            snapshot.testBeforePrimaryJSONWrite?()
            let committed = state.commitIfCurrent(snapshot.revision) {
                do {
                    try commitStaged(stagedJSON, to: snapshot.fileURL)
                    displacedRecoveryURL = moveAside(snapshot.recoveryURL)
                    return true
                } catch {
                    NSLog("codenv 大草稿寫入失敗：%@", String(describing: error))
                    return false
                }
            }
            if !committed {
                return false
            }
            if let displacedRecoveryURL { cleanup(displacedRecoveryURL) }
            removeReferencedImages(previousPrimaryImages, in: snapshot.directory,
                                   keeping: Set(images.map(\.file)), imagePrefix: snapshot.imagePrefix)
            if displacedRecoveryURL != nil {
                removeReferencedImages(previousRecoveryImages, in: snapshot.recoveryDirectory, keeping: [],
                                       imagePrefix: snapshot.imagePrefix)
            }
            writtenImageURLs.removeAll()
            return committed
        } catch {
            NSLog("codenv 大草稿寫入失敗：%@", String(describing: error))
            return false
        }
    }

    static func writeRecovery(_ snapshot: LargeDraftSnapshot, state: LargeDraftWriteState) -> Bool {
        guard state.isCurrent(snapshot.revision) else { return false }
        if snapshot.testWriteDelay > 0 { Thread.sleep(forTimeInterval: snapshot.testWriteDelay) }
        let masked = KeyScan.redact(snapshot.text, strongOnly: true)
        guard state.isCurrent(snapshot.revision), let imagePlan = makeImagePlan(snapshot, recovery: true) else { return false }
        let record = LargeDraftRecord(text: masked, quotes: snapshot.quotes, filePaths: snapshot.filePaths, images: imagePlan.records)
        let json: Data
        do { json = try JSONEncoder().encode(record) }
        catch { NSLog("codenv 大草稿復原快照序列化失敗：%@", String(describing: error)); return false }
        var writtenImageURLs: [URL] = []
        defer { for url in writtenImageURLs { cleanup(url) } }
        do {
            try FileManager.default.createDirectory(at: snapshot.recoveryDirectory, withIntermediateDirectories: true)
            for item in imagePlan.files {
                guard state.isCurrent(snapshot.revision) else { return false }
                try writeAtomic(item.data, to: item.url)
                writtenImageURLs.append(item.url)
            }
            let stagedJSON = try stageAtomic(json, to: snapshot.recoveryURL)
            defer { cleanup(stagedJSON) }
            let previousRecoveryImages = referencedImages(snapshot.recoveryURL, imagePrefix: snapshot.imagePrefix,
                                                          recovery: true)
            let committed = state.commitIfCurrent(snapshot.revision) {
                do {
                    try commitStaged(stagedJSON, to: snapshot.recoveryURL)
                    return true
                } catch {
                    NSLog("codenv 大草稿復原快照寫入失敗：%@", String(describing: error))
                    return false
                }
            }
            guard committed else { return false }
            removeReferencedImages(previousRecoveryImages, in: snapshot.recoveryDirectory,
                                   keeping: Set(imagePlan.records.map { URL(fileURLWithPath: $0.file).lastPathComponent }),
                                   imagePrefix: snapshot.imagePrefix)
            writtenImageURLs.removeAll()
            return committed
        } catch {
            NSLog("codenv 大草稿復原快照寫入失敗：%@", String(describing: error))
            return false
        }
    }

    private static func makeImagePlan(_ snapshot: LargeDraftSnapshot, recovery: Bool) -> (files: [(data: Data, url: URL)], records: [LargeDraftImageRecord])? {
        var files: [(data: Data, url: URL)] = []
        var records: [LargeDraftImageRecord] = []
        for image in snapshot.images {
            guard let ext = imageExtension(image.mediaType), image.no > 0, image.no < Int.max else {
                NSLog("codenv 大草稿附件格式無效")
                return nil
            }
            let name = "\(snapshot.imagePrefix)u\(snapshot.writeID.uuidString.lowercased())-\(image.no).\(ext)"
            let relative = recovery ? ".recovery/\(name)" : name
            let base = recovery ? snapshot.recoveryDirectory : snapshot.directory
            files.append((image.data, base.appendingPathComponent(name)))
            records.append(LargeDraftImageRecord(no: image.no, mediaType: image.mediaType, file: relative, edited: image.edited))
        }
        return (files, records)
    }

    private static func imageExtension(_ mediaType: String) -> String? {
        switch mediaType { case "image/png": return "png"; case "image/jpeg": return "jpg"; default: return nil }
    }

    private static func referencedImages(_ url: URL, imagePrefix: String, recovery: Bool = false) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(LargeDraftRecord.self, from: data) else { return [] }
        return record.images.compactMap { image in
            let name: String
            if recovery {
                let recoveryPrefix = ".recovery/"
                guard image.file.hasPrefix(recoveryPrefix) else { return nil }
                name = String(image.file.dropFirst(recoveryPrefix.count))
            } else {
                name = image.file
            }
            guard isOwnedImageName(name, imagePrefix: imagePrefix) else { return nil }
            return name
        }
    }

    private static func removeReferencedImages(_ names: [String], in directory: URL, keeping: Set<String>,
                                               imagePrefix: String) {
        for name in Set(names) where !keeping.contains(name) && isOwnedImageName(name, imagePrefix: imagePrefix) {
            cleanup(directory.appendingPathComponent(name))
        }
    }

    private static func isOwnedImageName(_ name: String, imagePrefix: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(".."),
              URL(fileURLWithPath: name).lastPathComponent == name, name.hasPrefix(imagePrefix) else { return false }
        let ext = URL(fileURLWithPath: name).pathExtension
        guard ["png", "jpg"].contains(ext) else { return false }
        let stem = String(name.dropLast(ext.count + 1)).dropFirst(imagePrefix.count)
        if let number = Int(stem), number > 0 { return true }
        guard let separator = stem.lastIndex(of: "-"), separator > stem.startIndex,
              let number = Int(stem[stem.index(after: separator)...]), number > 0 else { return false }
        let generation = stem[..<separator]
        if generation.hasPrefix("r") {
            let revision = generation.dropFirst()
            return !revision.isEmpty && revision.allSatisfy(\.isNumber)
        }
        guard generation.hasPrefix("u") else { return false }
        return UUID(uuidString: String(generation.dropFirst())) != nil
    }

    /// 將舊復原檔在 revision lock 內以原子 rename 移出正式名稱；刪除本身在鎖外。
    private static func moveAside(_ url: URL) -> URL? {
        let displaced = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).stale")
        let result = url.path.withCString { source in
            displaced.path.withCString { destination in rename(source, destination) }
        }
        return result == 0 ? displaced : nil
    }

    private static func stageAtomic(_ data: Data, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do { try data.write(to: temporary); return temporary }
        catch { cleanup(temporary); throw error }
    }

    /// revision lock 內只做同目錄原子 rename，不在鎖內寫入整份 JSON。
    private static func commitStaged(_ temporary: URL, to url: URL) throws {
        let result = temporary.path.withCString { source in url.path.withCString { destination in rename(source, destination) } }
        if result != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private static func writeAtomic(_ data: Data, to url: URL) throws {
        let temporary = try stageAtomic(data, to: url)
        defer { cleanup(temporary) }
        try commitStaged(temporary, to: url)
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
