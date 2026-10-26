import AppKit

/// 測試用：假裝有人從 Finder 把檔案拖進某個 view（不動真的滑鼠）。
/// 照系統拖放的順序呼叫 draggingEntered → draggingUpdated → prepare → perform → conclude，
/// 看那個 view（例如瀏覽器格子的 WKWebView）會不會把檔案交給網頁。
final class FakeFileDrag: NSObject, NSDraggingInfo {
    let pb: NSPasteboard
    let win: NSWindow
    let point: NSPoint   // 視窗座標
    let files: [URL]

    init(files: [URL], window: NSWindow, at point: NSPoint) {
        // 一定要用系統的拖放剪貼板：WebKit 只准網頁讀這一塊（不是 ⌘ C 的剪貼簿，每次真的拖東西都會蓋掉）
        pb = NSPasteboard(name: .drag)
        pb.clearContents()
        pb.writeObjects(files as [NSURL])
        // Finder 的真拖放也帶舊式檔名清單；WebKit 靠它發「網頁可以讀這個檔」的權限
        pb.addTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType")], owner: nil)
        pb.setPropertyList(files.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        win = window
        self.files = files
        self.point = point
    }

    var draggingDestinationWindow: NSWindow? { win }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4242 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop: Int { get { files.count } set {} }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        // WebKit 用這個一個個拿被拖的檔案（NSURL）
        var stop: ObjCBool = false
        for (i, u) in files.enumerated() where !stop.boolValue {
            block(NSDraggingItem(pasteboardWriter: u as NSURL), i, &stop)
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}

    /// 拖到 view 中間放開；分幾段做（WebKit 的 draggingUpdated 是非同步問網頁要不要收）
    /// 回報：系統挑中的接收者是誰、每一步的回傳值
    static func run(files: [URL], onto view: NSView, log: @escaping (String) -> Void) {
        guard let win = view.window, let content = win.contentView else { return log("沒有視窗") }
        let mid = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let hit = content.hitTest(content.convert(mid, from: nil))
        log("hitTest：\(hit.map { String(describing: type(of: $0)) } ?? "nil")；在 view 裡：\(hit?.isDescendant(of: view) ?? false)")
        let d = FakeFileDrag(files: files, window: win, at: mid)
        let target = hit.flatMap { h in sequence(first: h, next: { $0.superview }).first { !$0.registeredDraggedTypes.isEmpty } } ?? view
        log("接收者（往上找第一個有登記拖放類型的）：\(type(of: target))，類型：\(target.registeredDraggedTypes.map(\.rawValue).filter { $0.contains("file") || $0.contains("URL") || $0.contains("url") }.prefix(4))")
        log("entered → \(target.draggingEntered(d).rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            log("updated → \(target.draggingUpdated(d).rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                log("updated(2) → \(target.draggingUpdated(d).rawValue)")
                let ok = target.prepareForDragOperation(d)
                log("prepare → \(ok)")
                log("perform → \(target.performDragOperation(d))")
                target.concludeDragOperation(d)
            }
        }
    }
}
