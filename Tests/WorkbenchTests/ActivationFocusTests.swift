import AppKit
import WebKit
import XCTest
@testable import Workbench

final class ActivationFocusTests: XCTestCase {

    // MARK: - 純邏輯判斷矩陣

    func testCodeLabResponderIsNotStolenOnActivation() {
        XCTAssertFalse(
            MainWindowController.shouldFocusChatInputOnActivation(
                isKeyWindow: true,
                hasFocusedChatPane: true,
                responderInCodeLab: true,
                responderIsOtherEditableTextView: false
            ),
            "焦點在 CodeLab 編輯器（WKWebView）時，切回 App 不應把焦點搶回聊天輸入框"
        )
    }

    func testChatInputResponderKeepsFocusOnActivation() {
        XCTAssertTrue(
            MainWindowController.shouldFocusChatInputOnActivation(
                isKeyWindow: true,
                hasFocusedChatPane: true,
                responderInCodeLab: false,
                responderIsOtherEditableTextView: false
            ),
            "焦點在聊天輸入框（或非編輯區域）時，切回 App 應聚焦聊天輸入框"
        )
    }

    func testOtherEditableTextViewIsNotStolenOnActivation() {
        XCTAssertFalse(
            MainWindowController.shouldFocusChatInputOnActivation(
                isKeyWindow: true,
                hasFocusedChatPane: true,
                responderInCodeLab: false,
                responderIsOtherEditableTextView: true
            ),
            "焦點在改名／搜尋等其他可編輯 NSTextView 時，切回 App 不應搶焦點"
        )
    }

    func testNonKeyWindowDoesNotFocusWhenKeyWindowRequired() {
        XCTAssertFalse(
            MainWindowController.shouldFocusChatInputOnActivation(
                isKeyWindow: false,
                requireKeyWindow: true,
                hasFocusedChatPane: true,
                responderInCodeLab: false,
                responderIsOtherEditableTextView: false
            ),
            "正式模式下主視窗不是 keyWindow 時不應搶焦點"
        )
        XCTAssertTrue(
            MainWindowController.shouldFocusChatInputOnActivation(
                isKeyWindow: false,
                requireKeyWindow: false,
                hasFocusedChatPane: true,
                responderInCodeLab: false,
                responderIsOtherEditableTextView: false
            ),
            "隔離背景探針（requireKeyWindow=false）仍應照焦點規則判斷"
        )
    }

    func testNoFocusedChatPaneReturnsFalse() {
        XCTAssertFalse(
            MainWindowController.shouldFocusChatInputOnActivation(
                isKeyWindow: true,
                hasFocusedChatPane: false,
                responderInCodeLab: false,
                responderIsOtherEditableTextView: false
            ),
            "目前聚焦的不是聊天格時不應聚焦聊天輸入框"
        )
    }

    // MARK: - AppKit 隱藏視窗與 View 階層驗證（不顯示、不搶焦點）

    @MainActor
    func testWindowResponderClassificationWithCodeLabAndTextViews() {
        let win = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        guard let content = win.contentView else {
            XCTFail("無法取得隱藏視窗的 contentView")
            return
        }
        let codeLabContainer = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let editorWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        codeLabContainer.addSubview(editorWebView)

        let chatInput = NSTextView(frame: NSRect(x: 0, y: 200, width: 200, height: 40))
        chatInput.isEditable = true

        let renameField = NSTextView(frame: NSRect(x: 200, y: 200, width: 150, height: 24))
        renameField.isEditable = true

        content.addSubview(codeLabContainer)
        content.addSubview(chatInput)
        content.addSubview(renameField)

        func classifyAndDecide() -> Bool {
            let v = win.firstResponder as? NSView
            let inLab = v?.isDescendant(of: codeLabContainer) ?? false
            let otherEditable: Bool = {
                guard let t = win.firstResponder as? NSTextView else { return false }
                return t.isEditable && t !== chatInput
            }()
            return MainWindowController.shouldFocusChatInputOnActivation(
                isKeyWindow: true,
                hasFocusedChatPane: true,
                responderInCodeLab: inLab,
                responderIsOtherEditableTextView: otherEditable
            )
        }

        // 情境①：CodeLab WKWebView 有焦點 → isDescendant 為 true、不是 NSTextView、決策為 false
        XCTAssertTrue(win.makeFirstResponder(editorWebView))
        XCTAssertTrue((win.firstResponder as? NSView)?.isDescendant(of: codeLabContainer) == true)
        XCTAssertFalse(win.firstResponder is NSTextView)
        XCTAssertFalse(classifyAndDecide())

        // 情境②：聊天輸入框有焦點 → 不在 CodeLab、不是其他 NSTextView、決策為 true
        XCTAssertTrue(win.makeFirstResponder(chatInput))
        XCTAssertTrue(win.firstResponder === chatInput)
        XCTAssertFalse((win.firstResponder as? NSView)?.isDescendant(of: codeLabContainer) == true)
        XCTAssertTrue(classifyAndDecide())

        // 情境③：別的可編輯 NSTextView（改名欄位）有焦點 → 決策為 false
        XCTAssertTrue(win.makeFirstResponder(renameField))
        XCTAssertTrue(win.firstResponder === renameField)
        XCTAssertFalse((win.firstResponder as? NSView)?.isDescendant(of: codeLabContainer) == true)
        XCTAssertFalse(classifyAndDecide())
    }
}
