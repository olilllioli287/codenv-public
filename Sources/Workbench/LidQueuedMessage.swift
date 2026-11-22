import Foundation

/// 橋接層共用的待送訊息快照；獨立於 LidKeeper，供 bridge 單檔測試編譯。
struct LidQueuedMessage: Codable, Equatable {
    let id: String
    var text: String

    static func text(in message: [String: Any]) -> String {
        let payload = message["message"] as? [String: Any] ?? message
        if let text = payload["content"] as? String { return text }
        let blocks = payload["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { item in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
        return formattedText(text, hasImages: blocks.contains(where: { $0["type"] as? String == "image" }))
    }

    static func formattedText(_ text: String, hasImages: Bool) -> String {
        guard hasImages else { return text }
        return text.isEmpty ? "（含圖片附件）" : "\(text)（含圖片附件）"
    }
}
