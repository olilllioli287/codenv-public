import Foundation
import XCTest
@testable import Workbench

final class BrowserServerGateTests: XCTestCase {
    private let existingAllowedCommands = [
        "wake", "show", "team", "rename", "new", "model", "mcp", "topic",
        "archive", "area", "send", "stop", "last", "new_engine", "merge_check",
        "sprint", "board_read", "board_write",
    ]

    private let handoffCommands = [
        "handoff_info", "handoff_create", "handoff_send", "handoff_finish",
    ]

    func testHandoffCommandsAllowedWhenWebDisabled() {
        for cmd in handoffCommands {
            XCTAssertTrue(
                BrowserServer.isAllowedWhenWebDisabled(cmd),
                "\(cmd) 應在網頁外掛關閉時放行"
            )
            XCTAssertNil(
                BrowserServer.webDisabledGateReply(for: cmd, webFeaturesEnabled: false),
                "\(cmd) 不應被網頁外掛開關攔截"
            )
        }
    }

    func testExistingNonWebCommandsRemainAllowedWhenWebDisabled() {
        for cmd in existingAllowedCommands {
            XCTAssertTrue(
                BrowserServer.isAllowedWhenWebDisabled(cmd),
                "既有非網頁指令 \(cmd) 應維持放行"
            )
            XCTAssertNil(
                BrowserServer.webDisabledGateReply(for: cmd, webFeaturesEnabled: false),
                "既有非網頁指令 \(cmd) 不應被攔截"
            )
        }
        XCTAssertEqual(
            BrowserServer.allowedCommandsWhenWebDisabled,
            Set(existingAllowedCommands + handoffCommands),
            "放行清單只應包含既有 18 個指令與 4 個 handoff 指令"
        )
    }

    func testWebAndUnknownCommandsBlockedWhenWebDisabled() {
        let blocked: [String?] = ["text", "shot", "url", "export", "unknown_cmd", "handoff", "", nil]
        let expectedError = L("網頁外掛功能已關閉（設定可打開）")
        for cmd in blocked {
            XCTAssertFalse(
                BrowserServer.isAllowedWhenWebDisabled(cmd),
                "\(String(describing: cmd)) 不應在放行清單內"
            )
            let reply = BrowserServer.webDisabledGateReply(for: cmd, webFeaturesEnabled: false)
            XCTAssertNotNil(reply, "\(String(describing: cmd)) 應在網頁外掛關閉時被擋")
            XCTAssertEqual(reply?["ok"] as? Bool, false)
            XCTAssertEqual(reply?["error"] as? String, expectedError)
        }
    }

    func testLsSpecialCaseReturnsEmptyPanesWhenWebDisabled() throws {
        XCTAssertFalse(BrowserServer.isAllowedWhenWebDisabled("ls"))
        let reply = try XCTUnwrap(BrowserServer.webDisabledGateReply(for: "ls", webFeaturesEnabled: false))
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let panes = try XCTUnwrap(reply["panes"] as? [Any])
        XCTAssertTrue(panes.isEmpty)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
        let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"ok":true,"panes":[]}"#)
    }

    func testGateAllowsAllCommandsWhenWebEnabled() {
        let samples: [String?] = handoffCommands + existingAllowedCommands + ["ls", "text", "shot", "url", "export", "unknown_cmd", nil]
        for cmd in samples {
            XCTAssertNil(
                BrowserServer.webDisabledGateReply(for: cmd, webFeaturesEnabled: true),
                "網頁外掛開啟時，\(String(describing: cmd)) 不應被前置閘門攔截"
            )
        }
    }
}
