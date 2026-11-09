import Foundation

/// 靜態考卷：不啟動 App 或測試實例，由專案驗證腳本讀取／執行。
enum BtnMoveTests {
    static func verify(repository: URL) throws {
        let input = try String(contentsOf: repository.appendingPathComponent("Sources/Workbench/ChatInputBar.swift"), encoding: .utf8)
        let pane = try String(contentsOf: repository.appendingPathComponent("Sources/Workbench/ChatPane.swift"), encoding: .utf8)
        let slot = try String(contentsOf: repository.appendingPathComponent("Sources/Workbench/PetSlot.swift"), encoding: .utf8)
        let keys = try String(contentsOf: repository.appendingPathComponent("Sources/Workbench/PrefixKeys.swift"), encoding: .utf8)

        let terminalID = #"chatInputBar.terminalButton"#
        let graphID = #"chatInputBar.graphButton"#
        let folderID = #"chatInputBar.folderButton"#
        precondition(input.contains(terminalID), "missing terminal input control identifier")
        precondition(input.contains(graphID), "missing graph input control identifier")
        precondition(input.contains("uploadButton.setAccessibilityIdentifier(\"chatInputBar.folderButton\")"), "missing folder input control identifier")

        guard let terminal = input.range(of: terminalID), let graph = input.range(of: graphID), let folder = input.range(of: folderID) else {
            fatalError("missing graph or folder control identifier")
        }
        precondition(terminal.lowerBound < folder.lowerBound, "terminal control must precede folder control")
        precondition(graph.lowerBound < folder.lowerBound, "graph control must precede folder control")
        precondition(terminal.lowerBound < graph.lowerBound, "terminal control must precede graph control")
        precondition(input.contains("terminalButton.frame = NSRect(x: uploadButton.frame.minX - 26"), "terminal control must sit directly left of folder control")
        precondition(input.contains("graphButton.frame = NSRect(x: terminalButton.frame.minX - 26"), "graph control must sit left of terminal control")
        precondition(input.contains("terminalButton.isHidden = !lockView.isHidden || inner.width < 310 || uploadButton.isHidden"), "terminal control must hide while locked or narrow")
        precondition(input.contains("graphButton.isHidden = terminalButton.isHidden"), "graph control visibility must follow terminal control")
        precondition(input.contains("button.layer?.cornerRadius = 11") && input.contains("button.contentTintColor = .secondaryLabelColor"), "utility button styling is missing")
        precondition(input.contains("width: 22, height: 22"), "utility controls must use 22 point frames")

        precondition(pane.contains("onTerminalButton") && pane.contains("toggleFloatingTerminal"), "terminal action is not connected")
        precondition(pane.contains("onGraphButton") && pane.contains("toggleGraphPanel"), "graph action is not connected")
        precondition(input.contains("浮動終端機（F5）") && input.contains("關聯圖（F6）"), "shortcut tooltips are missing")
        precondition(!slot.contains("FloatTermButton()") && !slot.contains("GraphButton()"), "old PetSlot controls remain")
        precondition(!slot.contains("termButton") && !slot.contains("graphButton"), "old PetSlot control members remain")
        precondition(slot.contains("static let termSize: CGFloat = 34") && slot.contains("static let buttonLeft: CGFloat = 10") && slot.contains("static let buttonTop: CGFloat = 4"), "shared PetSlot layout constants are missing")
        precondition(keys.contains("F5") && keys.contains("F6"), "global shortcuts are missing")
        precondition(input.contains("@objc private func terminalPressed() { onTerminalButton?() }") && input.contains("@objc private func graphPressed() { onGraphButton?() }"), "utility button actions do not invoke their callbacks")
    }
}
