import Foundation

/// `<private>…</private>` 區段的共用過濾器。保留原始對話，只在交給摘要模型前替換內容。
enum PrivateSegments {
    static let marker = "〔已略過私人段落〕"

    static func redact(_ text: String) -> String {
        let open = "<private>"
        let close = "</private>"
        var output = ""
        var cursor = text.startIndex

        while let start = text.range(of: open, range: cursor..<text.endIndex) {
            output += text[cursor..<start.lowerBound]
            var scan = start.upperBound
            var depth = 1
            var end: String.Index?

            while scan < text.endIndex {
                let nextOpen = text.range(of: open, range: scan..<text.endIndex)
                let nextClose = text.range(of: close, range: scan..<text.endIndex)
                guard let closing = nextClose else { break }
                if let opening = nextOpen, opening.lowerBound < closing.lowerBound {
                    depth += 1
                    scan = opening.upperBound
                } else {
                    depth -= 1
                    scan = closing.upperBound
                    if depth == 0 { end = scan; break }
                }
            }

            output += marker
            guard let end else { return output }
            cursor = end
        }

        if cursor < text.endIndex { output += text[cursor...] }
        return output
    }
}
