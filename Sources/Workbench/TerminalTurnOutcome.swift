import Foundation

/// 將引擎串流轉成「本輪完成／停止／失敗」。只有終止 result 才能判定失敗；
/// Codex 的 api_retry 等中途錯誤事件不會結束本輪。
struct TerminalTurnTracker {
    enum Outcome: Equatable {
        case completed
        case stopped
        case failed(String)
    }

    private(set) var failureGeneration = 0
    private(set) var stopGeneration = 0
    private(set) var lastFailureMessage: String?
    private var interruptionMarkerSeen = false

    mutating func clearFailure() {
        lastFailureMessage = nil
    }

    mutating func observe(_ raw: [String: Any]) -> (event: [String: Any], outcome: Outcome?) {
        if Self.isInterruptionMarker(raw) {
            interruptionMarkerSeen = true
            return (raw, nil)
        }
        guard raw["type"] as? String == "result" else { return (raw, nil) }

        var event = raw
        let stopped = interruptionMarkerSeen || Self.isStopped(raw)
        interruptionMarkerSeen = false
        if stopped {
            event["stopped"] = true
            event["is_error"] = false
            event["subtype"] = "stopped"
            event["result"] = L("已停止")
            stopGeneration += 1
            lastFailureMessage = nil
            return (event, .stopped)
        }

        if raw["is_error"] as? Bool == true {
            let message = Self.resultMessage(raw) ?? L("引擎回報執行錯誤")
            failureGeneration += 1
            lastFailureMessage = message
            return (event, .failed(message))
        }

        lastFailureMessage = nil
        return (event, .completed)
    }

    static func isStopped(_ event: [String: Any]) -> Bool {
        event["stopped"] as? Bool == true
            || ["stopped", "interrupted"].contains(event["subtype"] as? String ?? "")
            || isInterruptionMarker(event)
    }

    static func isInterruptionMarker(_ event: [String: Any]) -> Bool {
        func containsStopMarker(_ value: String?) -> Bool {
            value?.localizedCaseInsensitiveContains("[Request interrupted by user") == true
        }
        if containsStopMarker(event["result"] as? String) { return true }
        guard event["type"] as? String == "user" else { return false }
        let message = event["message"] as? [String: Any] ?? [:]
        if containsStopMarker(message["content"] as? String) { return true }
        return (message["content"] as? [[String: Any]] ?? []).contains {
            containsStopMarker($0["text"] as? String)
        }
    }

    static func resultMessage(_ event: [String: Any]) -> String? {
        if let text = event["result"] as? String, !text.isEmpty { return text }
        if let result = event["result"] as? [String: Any] {
            return (result["error"] as? String) ?? (result["message"] as? String)
        }
        return nil
    }

    static func completionLabel(_ event: [String: Any]) -> String {
        if isStopped(event) { return L("已停止") }
        return event["is_error"] as? Bool == true ? L("出錯") : L("完成")
    }

    static func supervisionNotice(conversation: String, event: [String: Any], detail: String? = nil) -> String? {
        if isStopped(event) { return "〔總指揮監督〕「\(conversation)」\(L("已停止"))" }
        guard event["is_error"] as? Bool == true else { return nil }
        return "〔總指揮監督〕「\(conversation)」\(L("引擎回報失敗"))：\(detail ?? L("引擎回報執行錯誤"))"
    }
}

