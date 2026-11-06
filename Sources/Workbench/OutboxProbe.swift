import Foundation

/// 不開 App、不啟動後端；所有 fixture 都在明確指定的 --state-dir 裡。
enum OutboxProbe {
    static func run(in root: URL) -> Bool {
        let directory = root.appendingPathComponent("outbox-selftest-" + UUID().uuidString.lowercased(), isDirectory: true)
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let conversation = UUID()
            let store = OutboxPersistence(directory: directory, conversationID: conversation)
            let transcript = directory.appendingPathComponent("fixture.jsonl")
            func row(_ type: String, _ text: String, uuid: String? = nil) throws -> Data {
                var object: [String: Any] = ["type": type, "message": ["role": type, "content": [["type": "text", "text": text]]]]
                if let uuid { object["uuid"] = uuid }
                return try JSONSerialization.data(withJSONObject: object) + Data([0x0a])
            }
            // 舊的同文訊息不能確認新送出的訊息。
            var history = try row("user", "相同文字")
            try history.write(to: transcript)
            let quote = MessageQuote(qid: "q1", role: "assistant", text: "引用內容")
            let image = Data([1, 2, 3, 4])
            let file = directory.appendingPathComponent("attachment.txt")
            try Data("附件".utf8).write(to: file)
            try store.append(id: "a", text: "相同文字", wireText: "相同文字", quotes: [quote], filePaths: [file.path],
                             images: [(image, "image/png")], transcriptURLs: [transcript],
                             imageDrafts: [DraftPersistence.Image(data: image, mediaType: "image/png", no: 7, edited: true)])
            try store.append(id: "b", text: "排隊 B", wireText: "排隊 B", quotes: [], filePaths: [], images: [], transcriptURLs: [transcript])
            let reopened = OutboxPersistence(directory: directory, conversationID: conversation)
            let records = try reopened.read()
            check(records.map(\.id) == ["a", "b"], "reopen IDs/order")
            check(records.first?.quotes == [quote] && records.first?.filePaths == [file.path], "quotes/files")
            let restored = try reopened.draftImages(records[0])
            check(restored.first?.data == image, "image bytes")
            check(restored.first?.no == 7 && restored.first?.edited == true, "image number/edit metadata")
            check(try reopened.reconcile(transcriptURLs: [transcript]).count == 2, "old identical text is not delivery")
            history.append(try row("assistant", "排隊 B"))
            history.append(try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["content": [["type": "tool_result", "content": "排隊 B"]]]]) + Data([0x0a]))
            try history.write(to: transcript)
            check(try reopened.reconcile(transcriptURLs: [transcript]).count == 2, "assistant/tool results are not delivery")
            try reopened.remove(ids: ["a"])
            check(try reopened.read().map(\.id) == ["b"], "ack A keeps queued B")
            check(!FileManager.default.fileExists(atPath: records[0].images[0].path), "ack cleans image after JSON")
            history.append(try row("user", "排隊 B"))
            try history.write(to: transcript)
            check(try reopened.reconcile(transcriptURLs: [transcript]).isEmpty, "new user text confirms B")
            check(!FileManager.default.fileExists(atPath: reopened.fileURL.path), "empty outbox removed")
            // 同文的兩則排隊訊息，一行紀錄只能確認一則。
            for id in ["c", "d"] {
                try store.append(id: id, text: "同文", wireText: "同文", quotes: [], filePaths: [], images: [], transcriptURLs: [transcript])
            }
            history.append(try row("user", "同文", uuid: "d"))
            try history.write(to: transcript)
            check(try store.reconcile(transcriptURLs: [transcript]).map(\.id) == ["c"], "UUID preferred; one row confirms one message")
            check(try store.reconcile(transcriptURLs: [transcript]).map(\.id) == ["c"], "same row cannot confirm again on reopen")
            history.append(try row("user", "同文", uuid: "another-id"))
            try history.write(to: transcript)
            check(try store.reconcile(transcriptURLs: [transcript]).map(\.id) == ["c"], "different UUID cannot confirm identical text")
            // 半行不算確認，完整一行寫入後才算。
            let last = try row("user", "同文")
            history.append(last.dropLast())
            try history.write(to: transcript)
            check(try store.reconcile(transcriptURLs: [transcript]).count == 1, "partial JSONL is uncertain")
            history.append(0x0a)
            try history.write(to: transcript)
            check(try store.reconcile(transcriptURLs: [transcript]).isEmpty, "complete JSONL confirms")
            // 新發現的紀錄檔沒有送出時的基準，不能拿裡面的舊同文訊息確認。
            try store.append(id: "unknown-path", text: "舊同文", wireText: "舊同文", quotes: [], filePaths: [], images: [], transcriptURLs: [transcript])
            let unknown = directory.appendingPathComponent("unknown.jsonl")
            try (row("assistant", "開頭") + row("user", "舊同文")).write(to: unknown)
            check(try store.reconcile(transcriptURLs: [unknown]).count == 1, "unknown transcript cannot confirm old identical text")
            try store.remove(ids: ["unknown-path"])
            // 純圖訊息不因文字都是空字串就被任意圖片確認；紀錄路徑也可由寄件匣自行找回。
            try store.append(id: "image", text: "", wireText: "", quotes: [], filePaths: [],
                             images: [(image, "image/png")], transcriptURLs: [transcript])
            func imageRow(_ data: Data) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["type": "user", "message": ["content": [["type": "image", "source": ["type": "base64", "data": data.base64EncodedString()]]]]]) + Data([0x0a])
            }
            history.append(try imageRow(Data([9])))
            try history.write(to: transcript)
            check(try store.reconcile(transcriptURLs: []).count == 1, "different image stays uncertain")
            history.append(try imageRow(image))
            try history.write(to: transcript)
            check(try store.reconcile(transcriptURLs: []).isEmpty, "matching image confirms from saved transcript path")
            // 圖文訊息也必須比對圖片，不能只用相同文字確認。
            try store.append(id: "mixed", text: "圖文", wireText: "圖文", quotes: [], filePaths: [],
                             images: [(image, "image/png")], transcriptURLs: [transcript])
            history.append(try row("user", "圖文"))
            try history.write(to: transcript)
            check(try store.reconcile(transcriptURLs: []).count == 1, "same text without image stays uncertain")
            // 缺圖不影響原 JSON，讀圖失敗交由畫面提示，不可靜默當成已完整復原。
            let mixed = try store.read()[0]
            let mixedJSON = try Data(contentsOf: store.fileURL)
            try FileManager.default.removeItem(atPath: mixed.images[0].path)
            do { _ = try store.draftImages(mixed); failures.append("missing image silently restored") } catch { }
            check(try Data(contentsOf: store.fileURL) == mixedJSON, "missing image preserves record")
            check(try store.read().map(\.id) == ["mixed"], "missing image still permits read")
            let canonicalStore = OutboxPersistence(directory: directory.standardizedFileURL, conversationID: conversation)
            check(try canonicalStore.read().map(\.id) == ["mixed"], "missing image permits reopen with canonical directory")
            try store.remove(ids: ["mixed"])
            check(try store.read().isEmpty, "missing image still permits remove")
            check(!FileManager.default.fileExists(atPath: store.fileURL.path), "missing image removal clears JSON")
            // 正規化後仍只能指向本對話的圖片目錄，不能讓 remove 刪掉外面的附件。
            let outside = OutboxPersistence.Record(id: mixed.id, text: mixed.text, wireText: mixed.wireText,
                quotes: mixed.quotes, filePaths: mixed.filePaths,
                images: [.init(path: file.path, mediaType: "image/png", no: 1, edited: false)],
                transcriptOffsets: mixed.transcriptOffsets)
            let outsideJSON = try JSONEncoder().encode([outside])
            try outsideJSON.write(to: store.fileURL)
            do { _ = try store.read(); failures.append("outside image path accepted by read") }
            catch CocoaError.fileReadCorruptFile { }
            do { try store.remove(ids: [mixed.id]); failures.append("outside image path accepted by remove") }
            catch CocoaError.fileReadCorruptFile { }
            check(try Data(contentsOf: store.fileURL) == outsideJSON, "outside image path preserves JSON")
            check(try Data(contentsOf: file) == Data("附件".utf8), "outside image path preserves attachment")
            // 寫入路徑被檔案擋住時必須拋錯，讓 ChatSession 阻止送出。
            let blocked = directory.appendingPathComponent("blocked")
            try Data([0]).write(to: blocked)
            let unwritable = OutboxPersistence(directory: blocked, conversationID: UUID())
            do {
                try unwritable.append(id: "blocked", text: "不准送出", wireText: "不准送出", quotes: [], filePaths: [], images: [], transcriptURLs: [])
                failures.append("unwritable outbox accepted append")
            } catch { }
            // 讀不懂的寄件匣必須原樣保留，不能在下一次送出時蓋掉。
            let bad = Data("{broken".utf8)
            try bad.write(to: store.fileURL)
            do {
                try store.append(id: "e", text: "不能蓋掉", wireText: "不能蓋掉", quotes: [], filePaths: [], images: [], transcriptURLs: [])
                failures.append("corrupt outbox accepted append")
            } catch { }
            check(try Data(contentsOf: store.fileURL) == bad, "corrupt file preserved")
            // 原子更新不應留下暫存 JSON。
            let files = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
            check(!files.contains { $0.hasSuffix(".tmp") }, "no temporary JSON remains")
        } catch { failures.append(String(describing: error)) }
        print("outbox-selftest: " + (failures.isEmpty ? "PASS" : "FAIL\n" + failures.joined(separator: "\n")))
        print("fixtures=" + directory.path)
        return failures.isEmpty
    }
}
