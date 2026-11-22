import Foundation
import Darwin

/// 跨啟動保存每個聊天室未送出的輸入。
@MainActor
final class DraftPersistence {
    /// 只保存附件資料，不把 AppKit 的縮圖帶進防抖快照。
    struct Image: Sendable {
        var data: Data
        var mediaType: String
        var no: Int
        var edited: Bool
    }

    struct ImageRecord: Codable {
        var no: Int
        var mediaType: String
        var file: String
        var edited: Bool
    }

    struct Record: Codable {
        var text: String
        var quotes: [MessageQuote]
        var filePaths: [String]
        var images: [ImageRecord]
        var recoveredFromEmergency: Bool

        init(text: String, quotes: [MessageQuote], filePaths: [String], images: [ImageRecord]) {
            self.text = text; self.quotes = quotes; self.filePaths = filePaths; self.images = images
            self.recoveredFromEmergency = false
        }

        private enum CodingKeys: String, CodingKey { case text, quotes, filePaths, images }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            quotes = try c.decode([MessageQuote].self, forKey: .quotes)
            filePaths = try c.decode([String].self, forKey: .filePaths)
            images = try c.decodeIfPresent([ImageRecord].self, forKey: .images) ?? []
            recoveredFromEmergency = false
        }
    }

    private let directory: URL
    private let imagePrefix: String
    private let recoveryDirectory: URL
    private let recoveryURL: URL
    let fileURL: URL
    private var work: DispatchWorkItem?
    private var scheduledCompletion: ((Bool) -> Void)?
    private let largeWriteState: LargeDraftWriteState

    /// The sole size boundary for choosing synchronous vs background persistence.
    static func requiresBackground(text: String) -> Bool { text.utf8.count >= 1_048_576 }
    /// Only --state-dir lifecycle probes may inject a queued-write delay; ordinary runs always use zero.
    static var testLargeWriteDelay: TimeInterval = 0
    /// Per-instance pause points for isolated draft-review probes; never attached outside --state-dir.
    var testAfterPrimaryImageWrite: ((Int) -> Void)?
    var testBeforePrimaryJSONWrite: (() -> Void)?
    /// Completion signal for isolated probes that must inspect disk before the debounce fires.
    var testAfterPrimaryWrite: ((Bool) -> Void)?
    /// N2 lengthens only the isolated probe's debounce observation window.
    var testDebounceDelay: TimeInterval = 1

    init(directory: URL, conversationID: UUID) {
        self.directory = directory.appendingPathComponent("drafts", isDirectory: true)
        self.fileURL = self.directory.appendingPathComponent("\(conversationID.uuidString.lowercased()).json")
        self.imagePrefix = "\(conversationID.uuidString.lowercased())-img-"
        self.recoveryDirectory = self.directory.appendingPathComponent(".recovery", isDirectory: true)
        self.recoveryURL = self.recoveryDirectory.appendingPathComponent("\(conversationID.uuidString.lowercased()).json")
        self.largeWriteState = LargeDraftWriteState(fileURL: self.fileURL)
    }

    static func hasEmergencySnapshot(directory: URL, conversationID: UUID) -> Bool {
        let url = directory.appendingPathComponent("drafts/.recovery/\(conversationID.uuidString.lowercased()).json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    var hasPendingLargeWrite: Bool { largeWriteState.hasPending }

    /// 交接失敗回滾目標格時取消其延遲寫入，但保留既有磁碟快照。
    func cancelPendingWriteKeepingDisk() {
        work?.cancel(); work = nil
        scheduledCompletion = nil
        largeWriteState.invalidate()
    }

    private func largeSnapshot(revision: UInt64, text: String, quotes: [MessageQuote], filePaths: [String], images: [Image], testWriteDelay: TimeInterval = 0) -> LargeDraftSnapshot {
        let testHooksEnabled = CommandLine.arguments.contains("--state-dir")
        return LargeDraftSnapshot(revision: revision, writeID: UUID(), text: text, quotes: quotes, filePaths: filePaths,
                                  images: images.map { LargeDraftImage(data: $0.data, mediaType: $0.mediaType, no: $0.no, edited: $0.edited) },
                                  directory: directory, fileURL: fileURL, recoveryDirectory: recoveryDirectory,
                                  recoveryURL: recoveryURL, imagePrefix: imagePrefix, testWriteDelay: testWriteDelay,
                                  testAfterPrimaryImageWrite: testHooksEnabled ? testAfterPrimaryImageWrite : nil,
                                  testBeforePrimaryJSONWrite: testHooksEnabled ? testBeforePrimaryJSONWrite : nil,
                                  testAfterPrimaryWrite: testHooksEnabled ? testAfterPrimaryWrite : nil)
    }

    @discardableResult
    private func enqueueLargeWrite(text: String, quotes: [MessageQuote], filePaths: [String], images: [Image],
                                   recovery: Bool, completion: ((Bool) -> Void)? = nil,
                                   deliverOnMain: Bool = true, testWriteDelay: TimeInterval = 0) -> UInt64 {
        let snapshot = largeWriteState.begin { revision in
            largeSnapshot(revision: revision, text: text, quotes: quotes, filePaths: filePaths, images: images,
                          testWriteDelay: testWriteDelay)
        }
        let state = largeWriteState
        state.queue.async {
            let succeeded = recovery
                ? LargeDraftFileWriter.writeRecovery(snapshot, state: state)
                : LargeDraftFileWriter.writePrimary(snapshot, state: state)
            if !recovery { snapshot.testAfterPrimaryWrite?(succeeded) }
            state.finish(snapshot.revision, succeeded: succeeded)
            guard let completion else { return }
            guard state.isCurrent(snapshot.revision) else { return }
            if deliverOnMain {
                RunLoop.main.perform(inModes: [.common]) {
                    guard state.isCurrent(snapshot.revision) else { return }
                    completion(succeeded)
                }
            } else {
                completion(succeeded)
            }
        }
        return snapshot.revision
    }

    /// 關格／結束時優先保住尚未落盤的最新快照。這是極少數救援路徑，直接原子寫入隔離檔，
    /// 避免 applicationWillTerminate 返回後背景佇列被程序結束而留下空的復原檔。
    func preserveIncompleteLargeDraft(text: String, quotes: [MessageQuote], filePaths: [String], images: [Image]) {
        guard Self.requiresBackground(text: text) else { return }
        work?.cancel(); work = nil
        scheduledCompletion = nil
        let snapshot = largeWriteState.begin { revision in
            largeSnapshot(revision: revision, text: text, quotes: quotes, filePaths: filePaths, images: images)
        }
        let succeeded = LargeDraftFileWriter.writeRecovery(snapshot, state: largeWriteState)
        largeWriteState.finish(snapshot.revision, succeeded: succeeded)
    }

    /// 大草稿交接才用：最多等 2 秒；逾時作廢該次 writer，但保留待寫狀態供結束路徑保全來源。
    func writeForHandoff(text: String, quotes: [MessageQuote], filePaths: [String], images: [Image], timeout: TimeInterval = 2,
                         testWriteDelay: TimeInterval = 0) -> Bool {
        work?.cancel(); work = nil
        scheduledCompletion = nil
        guard Self.requiresBackground(text: text) else {
            return write(text: text, quotes: quotes, filePaths: filePaths, images: images)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = DraftWriteResult()
        enqueueLargeWrite(text: text, quotes: quotes, filePaths: filePaths, images: images,
                          recovery: false, completion: { result.set($0); semaphore.signal() }, deliverOnMain: false,
                          testWriteDelay: testWriteDelay)
        guard semaphore.wait(timeout: .now() + min(2, max(0, timeout))) == .success else {
            largeWriteState.invalidateForHandoffTimeout()
            return false
        }
        return result.value
    }

    func schedule(text: String, quotes: [MessageQuote], filePaths: [String], images: [Image],
                  completion: ((Bool) -> Void)? = nil) {
        work?.cancel()
        if Self.requiresBackground(text: text) { largeWriteState.markScheduled() }
        else { largeWriteState.invalidate() }
        scheduledCompletion = completion
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.work = nil
            let completion = self.scheduledCompletion
            self.scheduledCompletion = nil
            self.write(text: text, quotes: quotes, filePaths: filePaths, images: images, completion: completion)
        }
        work = item
        let delay = CommandLine.arguments.contains("--state-dir") ? max(0, testDebounceDelay) : 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 回傳草稿 JSON 有沒有真的寫進磁碟（寄件匣要等這個成功才能刪）
    @discardableResult
    func write(text rawText: String, quotes: [MessageQuote], filePaths: [String], images: [Image],
               completion: ((Bool) -> Void)? = nil) -> Bool {
        let completion = completion ?? scheduledCompletion
        scheduledCompletion = nil
        work?.cancel(); work = nil
        if Self.requiresBackground(text: rawText) {
            enqueueLargeWrite(text: rawText, quotes: quotes, filePaths: filePaths, images: images,
                              recovery: false, completion: completion,
                              testWriteDelay: CommandLine.arguments.contains("--state-dir") ? Self.testLargeWriteDelay : 0)
            return false // 背景寫入尚未完成，不冒稱已落盤。
        }
        largeWriteState.invalidate()
        let text = KeyScan.redact(rawText, strongOnly: true)      // 還沒送出的草稿也不把明確的 API 金鑰寫進檔案（只遮有前綴的，KeyVault.swift）
        guard !text.isEmpty || !quotes.isEmpty || !filePaths.isEmpty || !images.isEmpty else {
            remove()
            completion?(false)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var records: [ImageRecord] = []
            for image in images {
                guard let file = imageFile(no: image.no, mediaType: image.mediaType) else { throw CocoaError(.fileWriteInvalidFileName) }
                let url = directory.appendingPathComponent(file)
                // 打字不改圖片時，不必每秒重寫整張圖。
                if (try? Data(contentsOf: url)) != image.data { try atomicWrite(image.data, to: url) }
                records.append(ImageRecord(no: image.no, mediaType: image.mediaType, file: file, edited: image.edited))
            }
            let data = try JSONEncoder().encode(Record(text: text, quotes: quotes, filePaths: filePaths, images: records))
            try atomicWrite(data, to: fileURL)
            clearRecoverySnapshot()
            // 圖片和 JSON 都成功落盤後，才刪掉這段對話不再使用的舊圖。
            do { try removeImages(except: Set(records.map(\.file))) }
            catch { NSLog("codenv 草稿舊圖清除失敗：%@", String(describing: error)) }
            completion?(true)
            return true
        } catch {
            NSLog("codenv 草稿寫入失敗：%@", String(describing: error))
            completion?(false)
            return false
        }
    }

    /// 將隔離背景存檔接到非同步流程；大草稿只在最新 revision 確認落盤後回報成功。
    func writeAsync(text: String, quotes: [MessageQuote], filePaths: [String], images: [Image],
                    completion: @escaping (Bool) -> Void) {
        write(text: text, quotes: quotes, filePaths: filePaths, images: images, completion: completion)
    }

    /// 只供 state-dir 掛鉤等待本實例 serial queue 排空。
    func waitForWritesForTest(timeout: TimeInterval = 10) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        largeWriteState.queue.async { semaphore.signal() }
        return semaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func read() -> Record? {
        if shouldReadRecoverySnapshot {
            do {
                var recovered = try JSONDecoder().decode(Record.self, from: Data(contentsOf: recoveryURL))
                recovered.recoveredFromEmergency = true
                return recovered
            } catch {
                quarantineRecoverySnapshot()
                return readPrimary()
            }
        }
        return readPrimary()
    }

    private func readPrimary() -> Record? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do { return try JSONDecoder().decode(Record.self, from: Data(contentsOf: fileURL)) }
        catch {
            // 文字檔和這段對話的圖片一起改名隔離（加時間＋亂碼，第二次壞掉也各留一份）：
            // 只改文字檔的話，留在原地的圖會被之後的存檔／清除當成沒用的圖刪掉（agy Argon 11/6）
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            let tag = ".bad-" + f.string(from: Date()) + "-" + UUID().uuidString.prefix(6)
            try? FileManager.default.moveItem(at: fileURL, to: directory.appendingPathComponent(fileURL.lastPathComponent + tag))
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
                for name in names where name.hasPrefix(imagePrefix) && (name.hasSuffix(".png") || name.hasSuffix(".jpg")) {
                    try? FileManager.default.moveItem(at: directory.appendingPathComponent(name), to: directory.appendingPathComponent(name + tag))
                }
            }
            NSLog("codenv 草稿讀取失敗，已保留：%@", fileURL.lastPathComponent)
            return nil
        }
    }

    private func quarantineRecoverySnapshot() {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let tag = ".bad-" + f.string(from: Date()) + "-" + UUID().uuidString.prefix(6)
        let quarantined = recoveryDirectory.appendingPathComponent(recoveryURL.lastPathComponent + tag)
        do { try FileManager.default.moveItem(at: recoveryURL, to: quarantined) }
        catch {
            NSLog("codenv 大草稿復原快照隔離失敗，已保留：%@", recoveryURL.lastPathComponent)
            return
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path) {
            for name in names where name.hasPrefix(imagePrefix) && (name.hasSuffix(".png") || name.hasSuffix(".jpg")) {
                do {
                    try FileManager.default.moveItem(at: recoveryDirectory.appendingPathComponent(name),
                                                     to: recoveryDirectory.appendingPathComponent(name + tag))
                } catch {
                    NSLog("codenv 大草稿復原附件隔離失敗：%@", name)
                }
            }
        }
        NSLog("codenv 大草稿復原快照讀取失敗，已隔離：%@", recoveryURL.lastPathComponent)
    }

    private var shouldReadRecoverySnapshot: Bool {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return false }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        let recoveryAttributes = try? FileManager.default.attributesOfItem(atPath: recoveryURL.path)
        let primaryAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let recoveryDate = recoveryAttributes?[.modificationDate] as? Date
        let primaryDate = primaryAttributes?[.modificationDate] as? Date
        guard let recoveryDate, let primaryDate else { return true }
        return recoveryDate >= primaryDate
    }

    private func clearRecoverySnapshot() {
        do {
            if FileManager.default.fileExists(atPath: recoveryURL.path) { try FileManager.default.removeItem(at: recoveryURL) }
            try removeRecoveryImages(except: [])
        } catch { NSLog("codenv 大草稿復原快照清除失敗：%@", recoveryURL.lastPathComponent) }
    }

    /// 有沒有讀不懂而隔離起來的草稿（舊版的 .bad 或新版 .bad-時間）：有的話這段對話不能被當成空草稿清掉
    var hasQuarantined: Bool {
        let prefix = fileURL.lastPathComponent + ".bad"
        let primary = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.contains { $0.hasPrefix(prefix) } ?? false
        let recoveryPrefix = recoveryURL.lastPathComponent + ".bad"
        let recovery = (try? FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path))?.contains { $0.hasPrefix(recoveryPrefix) } ?? false
        return primary || recovery
    }

    func readImages(_ record: Record) -> [Image] {
        record.images.compactMap { image in
            // 只接受本對話的預期檔名，避免損壞紀錄指向 drafts 之外。
            guard isAllowedImageFile(image.file, no: image.no, mediaType: image.mediaType),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(image.file)) else { return nil }
            return Image(data: data, mediaType: image.mediaType, no: image.no, edited: image.edited)
        }
    }

    func remove() {
        work?.cancel(); work = nil
        scheduledCompletion = nil
        largeWriteState.invalidate()
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            try removeImages(except: [])
            if FileManager.default.fileExists(atPath: recoveryURL.path) { try FileManager.default.removeItem(at: recoveryURL) }
            try removeRecoveryImages(except: [])
        } catch { NSLog("codenv 草稿刪除失敗：%@", String(describing: error)) }
    }

    private func isAllowedImageFile(_ file: String, no: Int, mediaType: String) -> Bool {
        guard let expected = imageFile(no: no, mediaType: mediaType) else { return false }
        if file == expected { return true }
        let suffix = "-\(no).\(URL(fileURLWithPath: expected).pathExtension)"
        let recoveryPrefix = ".recovery/"
        let relative = file.hasPrefix(recoveryPrefix) ? String(file.dropFirst(recoveryPrefix.count)) : file
        guard relative.hasPrefix(imagePrefix), relative.hasSuffix(suffix) else { return false }
        let stem = relative.dropFirst(imagePrefix.count).dropLast(suffix.count)
        if stem.hasPrefix("r") {
            let revision = stem.dropFirst()
            return !revision.isEmpty && revision.allSatisfy(\.isNumber)
        }
        guard stem.hasPrefix("u") else { return false }
        return UUID(uuidString: String(stem.dropFirst())) != nil
    }

    private func removeRecoveryImages(except kept: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: recoveryDirectory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil) {
            let name = ".recovery/\(url.lastPathComponent)"
            guard url.lastPathComponent.hasPrefix(imagePrefix), ["png", "jpg"].contains(url.pathExtension), !kept.contains(name) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func imageFile(no: Int, mediaType: String) -> String? {
        guard no > 0, no < Int.max else { return nil }
        switch mediaType {
        case "image/png": return "\(imagePrefix)\(no).png"
        case "image/jpeg": return "\(imagePrefix)\(no).jpg"
        default: return nil
        }
    }

    private func removeImages(except kept: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasPrefix(imagePrefix), ["png", "jpg"].contains(url.pathExtension), !kept.contains(name),
                  isOwnedImageName(name) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func isOwnedImageName(_ name: String) -> Bool {
        guard name.hasPrefix(imagePrefix) else { return false }
        let ext = URL(fileURLWithPath: name).pathExtension
        guard ["png", "jpg"].contains(ext) else { return false }
        let stem = String(name.dropLast(ext.count + 1)).dropFirst(imagePrefix.count)
        if let number = Int(stem), number > 0, imageFile(no: number, mediaType: ext == "png" ? "image/png" : "image/jpeg") == name {
            return true
        }
        if stem.hasPrefix("r"), let dash = stem.firstIndex(of: "-"), dash > stem.startIndex,
           let number = Int(stem[stem.index(after: dash)...]), number > 0 {
            let revision = stem[stem.index(after: stem.startIndex)..<dash]
            return !revision.isEmpty && revision.allSatisfy(\.isNumber)
        }
        guard stem.hasPrefix("u"), let dash = stem.lastIndex(of: "-"), dash > stem.startIndex,
              let number = Int(stem[stem.index(after: dash)...]), number > 0 else { return false }
        let id = stem[stem.index(after: stem.startIndex)..<dash]
        return UUID(uuidString: String(id)) != nil
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        // POSIX rename 在同一目錄內原子替換既有目標。
        let result = temporary.path.withCString { source in
            url.path.withCString { destination in rename(source, destination) }
        }
        if result != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

private final class DraftWriteResult {
    private let lock = NSLock()
    private var storage = false
    func set(_ value: Bool) { lock.lock(); storage = value; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
}
