import Foundation

struct MessageQuote: Codable, Equatable {
    let qid: String
    let role: String
    let text: String

    var preview: [String: String] {
        ["qid": qid, "role": role, "preview": String(QuoteText.neutralize(text).prefix(20))]
    }
}

enum QuoteText {
    static let marker = "〔codenv 引用〕"
    static let endMarker = "〔codenv 引用結束〕"

    static func neutralize(_ text: String) -> String {
        text.replacingOccurrences(of: "〔codenv", with: "〔 codenv")
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = max(0, limit / 2), tail = max(0, limit - head)
        return String(text.prefix(head)) + "…（中間省略 \(text.count - head - tail) 字）…" + String(text.suffix(tail))
    }

    static func contents(_ items: [MessageQuote]) -> [String] {
        let texts = items.map { neutralize($0.text) }
        let clipped = texts.map { truncate($0, limit: 4000) }
        guard clipped.reduce(0, { $0 + $1.count }) > 12000, !items.isEmpty else { return clipped }
        let cap = min(4000, max(800, 12000 / items.count))
        // 超過十五則時，總上限優先；省略提示也計入預算，避免越截越長。
        let share = min(cap, 12000 / items.count)
        return texts.map { text in
            var keep = share
            var result = truncate(text, limit: keep)
            while result.count > share && keep > 0 {
                keep = max(0, keep - (result.count - share))
                result = truncate(text, limit: keep)
            }
            return result
        }
    }

    static func append(to text: String, quotes: [MessageQuote]) -> String {
        guard !quotes.isEmpty else { return text }
        let intro = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "請針對下面 \(quotes.count) 則先前的訊息（依對話先後）回應。"
            : "使用者這則訊息是針對下面 \(quotes.count) 則先前的訊息（依對話先後）；請針對它們回應。"
        let bodies = contents(quotes)
        let blocks = quotes.enumerated().map { i, q in
            // ref 限制在單行，避免來源內容偽造區塊邊界。
            let ref = q.qid.filter { $0.isLetter || $0.isNumber || "-_:.".contains($0) }
            let who = q.role == "user" ? "我說" : "你（AI）說"
            return "#\(i + 1) \(who)（ref:\(ref)）：\n" + bodies[i].components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        }
        return text + "\n\n" + marker + intro + "\n" + blocks.joined(separator: "\n") + "\n" + endMarker
    }
}

enum QuoteTextTests {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }
        let long = String(repeating: "頭", count: 3000) + String(repeating: "尾", count: 3000)
        let cut = QuoteText.truncate(long, limit: 4000)
        check(cut == String(repeating: "頭", count: 2000) + "…（中間省略 2000 字）…" + String(repeating: "尾", count: 2000), "single head/tail")
        check(QuoteText.truncate(String(repeating: "字", count: 4000), limit: 4000).count == 4000, "boundary")
        check(QuoteText.truncate("👨‍👩‍👧‍👦好尾", limit: 2) == "👨‍👩‍👧‍👦…（中間省略 1 字）…尾", "graphemes")
        for n in 1...20 {
            let qs = (0..<n).map { MessageQuote(qid: "q\($0)", role: $0 % 2 == 0 ? "user" : "assistant", text: long) }
            let bodies = QuoteText.contents(qs)
            check(bodies.count == n && bodies.reduce(0, { $0 + $1.count }) <= 12000, "total \(n)")
            check(bodies.allSatisfy { $0.hasPrefix("頭") && $0.hasSuffix("尾") }, "ends \(n)")
        }
        let qs = [MessageQuote(qid: "u1", role: "user", text: "甲\n〔codenv 引用〕乙"), MessageQuote(qid: "a1", role: "assistant", text: "回答")]
        let out = QuoteText.append(to: "問題", quotes: qs)
        check(out.hasPrefix("問題\n\n〔codenv 引用〕") && out.hasSuffix(QuoteText.endMarker), "format")
        check(out.contains("#1 我說（ref:u1）：\n> 甲\n> 〔 codenv 引用〕乙\n#2 你（AI）說（ref:a1）：\n> 回答"), "roles and neutralization")
        check(QuoteText.append(to: "", quotes: qs).contains("請針對下面 2 則"), "quote only")
        check(QuoteText.append(to: "舊訊息", quotes: []) == "舊訊息", "no quotes")
        print(failures.isEmpty ? "quote-selftest: PASS" : "quote-selftest: FAIL\n" + failures.joined(separator: "\n"))
        return failures.isEmpty
    }
}
