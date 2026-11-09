import Foundation
import Darwin

/// 與 ChatSession 一樣由主執行緒同步呼叫。先落盤才交給後端，回送 UUID 才逐則刪除。
final class OutboxPersistence {
    struct Image: Codable {
        let path: String
        let mediaType: String
        let no: Int?
        let edited: Bool?
    }
    struct Record: Codable {
        let id: String
        let text: String
        let wireText: String
        let quotes: [MessageQuote]
        let filePaths: [String]
        let images: [Image]
        // 只比對送出後新增的紀錄，舊的同文訊息不能拿來確認這次送出。
        var transcriptOffsets: [String: UInt64]
    }

    let fileURL: URL
    private let directory: URL
    private let imageDirectory: URL

    init(directory: URL, conversationID: UUID) {
        self.directory = directory.appendingPathComponent("outbox", isDirectory: true)
        fileURL = self.directory.appendingPathComponent("\(conversationID.uuidString.lowercased()).json")
        imageDirectory = self.directory.appendingPathComponent(conversationID.uuidString.lowercased(), isDirectory: true)
    }

    func read() throws -> [Record] {
        // 讀不懂時保留原檔，後續 append 也必須失敗，不能用空陣列蓋掉。
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        let records = try JSONDecoder().decode([Record].self, from: data)
        let imagePaths = records.flatMap(\.images).map(\.path)
        guard Set(records.map(\.id)).count == records.count,
              Set(imagePaths).count == imagePaths.count,
              records.allSatisfy({ record in
                  let numbers = record.images.enumerated().map { $0.element.no ?? ($0.offset + 1) }
                  return !record.id.isEmpty && record.id == record.id.lowercased()
                      && Set(numbers).count == numbers.count && numbers.allSatisfy { $0 > 0 && $0 < Int.max }
                      && record.images.allSatisfy { image in
                          let url = URL(fileURLWithPath: image.path).standardizedFileURL
                          return containsImageURL(url)
                              && ["image/png", "image/jpeg"].contains(image.mediaType)
                      }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return records
    }

    /// 寄件匣檔存在但讀不懂（read() 丟錯）
    var isUnreadable: Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        return (try? read()) == nil
    }

    /// 讀不懂的寄件匣改名成 <檔名>.bad-<時間>（不刪），之後就能開新的一份
    func quarantine() throws {
        // 加年份與短亂碼：同一秒隔離兩次時不會撞名、害這則送不出去（agy Argon 11/6 審查）
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let tag = f.string(from: Date()) + "-" + UUID().uuidString.prefix(6)
        let bad = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".bad-" + tag)
        try FileManager.default.moveItem(at: fileURL, to: bad)
    }

    func append(id: String, text: String, wireText: String, quotes: [MessageQuote], filePaths: [String],
                images: [(data: Data, mediaType: String)], transcriptURLs: [URL], imageDrafts: [DraftPersistence.Image] = []) throws {
        var records = try read()
        guard !id.isEmpty, !records.contains(where: { $0.id == id.lowercased() }) else { throw CocoaError(.fileWriteFileExists) }
        var offsets: [String: UInt64] = [:]
        for url in transcriptURLs {
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                offsets[url.path] = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            } else { offsets[url.path] = 0 }
        }
        var saved: [Image] = []
        for (i, image) in images.enumerated() {
            guard ["image/png", "image/jpeg"].contains(image.mediaType) else { throw CocoaError(.fileWriteInvalidFileName) }
            let ext = image.mediaType == "image/jpeg" ? "jpg" : "png"
            let url = imageDirectory.appendingPathComponent(UUID().uuidString.lowercased() + "." + ext)
            try Self.atomicWrite(image.data, to: url)
            let draft = imageDrafts.indices.contains(i) ? imageDrafts[i] : nil
            saved.append(Image(path: url.path, mediaType: image.mediaType, no: draft?.no ?? (i + 1), edited: draft?.edited ?? false))
        }
        // 不套 KeyScan.redact：wireText 要跟實際送出的字完全一致，才能拿去比對「已送達」，遮了會重送或誤判沒送到；只有使用者在金鑰卡片選「仍要送出」才會留明文，送達後即刪（金鑰管理，總指揮 11/8 裁決）
        records.append(Record(id: id.lowercased(), text: text, wireText: wireText, quotes: quotes,
                              filePaths: filePaths, images: saved, transcriptOffsets: offsets))
        try save(records)
    }

    /// 有沒有讀不懂而隔離的寄件匣檔，或還留著的圖片資料夾：有的話這段對話不能被當成空草稿清掉（agy Argon 11/6）
    var hasLeftovers: Bool {
        let dir = fileURL.deletingLastPathComponent(), prefix = fileURL.lastPathComponent + ".bad"
        if let imgs = try? FileManager.default.contentsOfDirectory(atPath: imageDirectory.path), !imgs.isEmpty { return true }   // 空資料夾不算
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasPrefix(prefix) } ?? false
    }

    func remove(ids: Set<String>) throws {
        let ids = Set(ids.map { $0.lowercased() })   // 寄件匣存的一律小寫
        guard !ids.isEmpty else { return }
        let records = try read()
        let removed = records.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        try save(records.filter { !ids.contains($0.id) })
        cleanImages(removed)
    }

    private func cleanImages(_ removed: [Record]) {
        // JSON 更新成功後才清圖；當掉最多留下孤兒圖，不會留下指向已刪圖片的紀錄。
        for image in removed.flatMap(\.images) {
            let url = URL(fileURLWithPath: image.path).standardizedFileURL
            if containsImageURL(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func containsImageURL(_ url: URL) -> Bool {
        // macOS 對存在的檔案會把 /private/tmp 標準化成 /tmp，缺圖時卻保留 /private/tmp。
        // 取父目錄後再標準化，避免驗證結果隨圖片存在與否改變；比 path 也不受 URL 結尾斜線影響。
        url.deletingLastPathComponent().standardizedFileURL.path == imageDirectory.standardizedFileURL.path
    }

    /// 每則保留原始編號；多則合併時由 ChatPane 重編避免 [Image #1] 互撞。
    func draftImages(_ record: Record) throws -> [DraftPersistence.Image] {
        try record.images.enumerated().map { i, image in
            DraftPersistence.Image(data: try Data(contentsOf: URL(fileURLWithPath: image.path)),
                                   mediaType: image.mediaType, no: image.no ?? (i + 1), edited: image.edited ?? false)
        }
    }

    /// 每個紀錄行最多確認一則。只比對 user 的實際文字區塊，不把 assistant／tool_result 裡的引文當送達。
    func reconcile(transcriptURLs: [URL]) throws -> [Record] {
        let original = try read()
        guard !original.isEmpty else { return [] }
        var pending = original
        var confirmed = Set<String>()
        let paths = Set(transcriptURLs.map(\.path) + pending.flatMap { $0.transcriptOffsets.keys })
        for path in paths.sorted() {
            guard !pending.isEmpty, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
            defer { try? handle.close() }
            let textEligibleIDs = Set(pending.filter { $0.transcriptOffsets[path] != nil }.map(\.id))
            let start = pending.map { $0.transcriptOffsets[path] ?? 0 }.min() ?? 0
            do {
                try handle.seek(toOffset: start)
                var buffer = Data(), position = start
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0a) {
                        let line = Data(buffer[..<newline])
                        let offset = position
                        position += UInt64(line.count + 1)
                        buffer.removeSubrange(...newline)
                        // 已掃過的行不能在下次啟動再次拿來確認另一則同文訊息。
                        defer {
                            for i in pending.indices {
                                pending[i].transcriptOffsets[path] = max(pending[i].transcriptOffsets[path] ?? 0, position)
                            }
                        }
                        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                              obj["type"] as? String == "user", obj["isCompactSummary"] as? Bool != true,
                              let message = obj["message"] as? [String: Any] else { continue }
                        let blocks = message["content"] as? [[String: Any]] ?? []
                        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                        let text = (message["content"] as? String) ?? blocks.compactMap {
                            $0["type"] as? String == "text" ? $0["text"] as? String : nil
                        }.joined(separator: "\n")
                        let uuid = (obj["uuid"] as? String)?.lowercased()
                        let eligible = pending.indices.filter { offset >= (pending[$0].transcriptOffsets[path] ?? 0) }
                        let match = eligible.first { pending[$0].id == uuid } ?? eligible.first { i in
                            let record = pending[i]
                            // 有 UUID 必須對 UUID；無 UUID 的橋接紀錄才用送出後的文字＋圖片比對。
                            guard uuid == nil, textEligibleIDs.contains(record.id),
                                  !record.wireText.isEmpty || !record.images.isEmpty, text == record.wireText else { return false }
                            let sources = blocks.filter { $0["type"] as? String == "image" }.compactMap { $0["source"] as? [String: Any] }
                            return sources.count == record.images.count && zip(sources, record.images).allSatisfy { source, image in
                                guard let data = try? Data(contentsOf: URL(fileURLWithPath: image.path)) else { return false }
                                return source["data"] as? String == data.base64EncodedString()
                            }
                        }
                        if let i = match { confirmed.insert(pending.remove(at: i).id) }
                    }
                }
            } catch {
                // 讀不到／半行紀錄都不能當確認；保留待確認資料。
                NSLog("codenv 寄件匣對照紀錄失敗：%@", String(describing: error))
            }
        }
        try save(pending)
        cleanImages(original.filter { confirmed.contains($0.id) })
        return pending
    }

    private func save(_ records: [Record]) throws {
        if records.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        } else { try Self.atomicWrite(JSONEncoder().encode(records), to: fileURL) }
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        let result = temporary.path.withCString { source in url.path.withCString { rename(source, $0) } }
        if result != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
