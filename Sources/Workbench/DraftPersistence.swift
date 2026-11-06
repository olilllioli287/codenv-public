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

        init(text: String, quotes: [MessageQuote], filePaths: [String], images: [ImageRecord]) {
            self.text = text; self.quotes = quotes; self.filePaths = filePaths; self.images = images
        }

        private enum CodingKeys: String, CodingKey { case text, quotes, filePaths, images }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            quotes = try c.decode([MessageQuote].self, forKey: .quotes)
            filePaths = try c.decode([String].self, forKey: .filePaths)
            images = try c.decodeIfPresent([ImageRecord].self, forKey: .images) ?? []
        }
    }

    private let directory: URL
    private let imagePrefix: String
    let fileURL: URL
    private var work: DispatchWorkItem?

    init(directory: URL, conversationID: UUID) {
        self.directory = directory.appendingPathComponent("drafts", isDirectory: true)
        self.fileURL = self.directory.appendingPathComponent("\(conversationID.uuidString.lowercased()).json")
        self.imagePrefix = "\(conversationID.uuidString.lowercased())-img-"
    }

    func schedule(text: String, quotes: [MessageQuote], filePaths: [String], images: [Image]) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.write(text: text, quotes: quotes, filePaths: filePaths, images: images) }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    /// 回傳草稿 JSON 有沒有真的寫進磁碟（寄件匣要等這個成功才能刪）
    @discardableResult
    func write(text: String, quotes: [MessageQuote], filePaths: [String], images: [Image]) -> Bool {
        work?.cancel(); work = nil
        guard !text.isEmpty || !quotes.isEmpty || !filePaths.isEmpty || !images.isEmpty else { remove(); return true }
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
            // 圖片和 JSON 都成功落盤後，才刪掉這段對話不再使用的舊圖。
            do { try removeImages(except: Set(records.map(\.file))) }
            catch { NSLog("codenv 草稿舊圖清除失敗：%@", String(describing: error)) }
            return true
        } catch {
            NSLog("codenv 草稿寫入失敗：%@", String(describing: error))
            return false
        }
    }

    func read() -> Record? {
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

    /// 有沒有讀不懂而隔離起來的草稿（舊版的 .bad 或新版 .bad-時間）：有的話這段對話不能被當成空草稿清掉
    var hasQuarantined: Bool {
        let prefix = fileURL.lastPathComponent + ".bad"
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.contains { $0.hasPrefix(prefix) } ?? false
    }

    func readImages(_ record: Record) -> [Image] {
        record.images.compactMap { image in
            // 只接受本對話的預期檔名，避免損壞紀錄指向 drafts 之外。
            guard image.file == imageFile(no: image.no, mediaType: image.mediaType),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(image.file)) else { return nil }
            return Image(data: data, mediaType: image.mediaType, no: image.no, edited: image.edited)
        }
    }

    func remove() {
        work?.cancel(); work = nil
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            try removeImages(except: [])
        } catch { NSLog("codenv 草稿刪除失敗：%@", String(describing: error)) }
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
                  let no = Int(url.deletingPathExtension().lastPathComponent.dropFirst(imagePrefix.count)),
                  imageFile(no: no, mediaType: url.pathExtension == "png" ? "image/png" : "image/jpeg") == name else { continue }
            try FileManager.default.removeItem(at: url)
        }
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
