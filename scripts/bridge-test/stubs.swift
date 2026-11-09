import Foundation
let appDefaults = UserDefaults(suiteName: "codenv-bridge-unit")!
func L(_ s: String) -> String { s }
enum Transcripts {
    static func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func redactedJSON(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}
enum Edition { static func support(_ s: String) -> URL { URL(fileURLWithPath: NSTemporaryDirectory()) } }
enum Effort { static let order = ["low", "medium", "high"] }
extension Transcripts { static func append(_ line: Data, to url: URL) {
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: url) } } }
