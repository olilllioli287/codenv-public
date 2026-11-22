import XCTest
@testable import Workbench

final class LidNoticeDeduplicatorTests: XCTestCase {
    func testDuplicateOpenAndCloseMessagesAreSentOncePerConversation() {
        let deduplicator = LidNoticeDeduplicator()
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let chats = [UUID(), UUID()]
        let texts = ["闔蓋通知", "開蓋通知"]
        var counts: [UUID: [String: Int]] = [:]
        for chat in chats {
            for message in texts {
                for duplicate in 0..<2 {
                    _ = deduplicator.send(conversationID: chat, text: message,
                                          now: origin.addingTimeInterval(Double(duplicate) * 0.5)) {
                        counts[chat, default: [:]][message, default: 0] += 1
                        return true
                    }
                }
            }
        }
        for chat in chats {
            XCTAssertEqual(counts[chat]?[texts[0]], 1)
            XCTAssertEqual(counts[chat]?[texts[1]], 1)
        }
    }

    func testFailedSendDoesNotReserveDeduplicationWindow() {
        let deduplicator = LidNoticeDeduplicator()
        let chat = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(deduplicator.send(conversationID: chat, text: "通知", now: now) { false })
        XCTAssertTrue(deduplicator.send(conversationID: chat, text: "通知", now: now.addingTimeInterval(0.2)) { true })
    }
}
