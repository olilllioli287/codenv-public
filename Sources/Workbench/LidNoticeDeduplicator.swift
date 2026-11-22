import Foundation

/// 開／闔蓋通知在實際送出點去重，涵蓋不同事件來源短時間重複呼叫的情況。
final class LidNoticeDeduplicator {
    private struct Key: Hashable {
        let conversationID: UUID
        let text: String
    }

    private let lock = NSLock()
    private var lastSentAt: [Key: Date] = [:]
    private var pending = Set<Key>()
    let interval: TimeInterval

    init(interval: TimeInterval = 5) { self.interval = interval }

    @discardableResult
    func send(conversationID: UUID, text: String, now: Date = Date(), action: () -> Bool) -> Bool {
        let key = Key(conversationID: conversationID, text: text)
        lock.lock()
        lastSentAt = lastSentAt.filter { now.timeIntervalSince($0.value) < interval }
        let recent = lastSentAt[key].map { now.timeIntervalSince($0) < interval } ?? false
        guard !pending.contains(key), !recent else { lock.unlock(); return false }
        pending.insert(key)
        lock.unlock()

        let sent = action()

        lock.lock()
        pending.remove(key)
        if sent { lastSentAt[key] = now }
        lock.unlock()
        return sent
    }
}
