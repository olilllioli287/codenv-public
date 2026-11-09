import AppKit
import SwiftUI

struct HelpDocument: Identifiable {
    let id: String
    let title: String
    let markdown: String
}

enum HelpCatalog {
    static func load() throws -> [HelpDocument] {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("help", isDirectory: true) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let documents = try files.map { url -> HelpDocument in
            let markdown = try String(contentsOf: url, encoding: .utf8)
            let title = markdown.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("# ") })
                .map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent
            return HelpDocument(id: url.lastPathComponent, title: title, markdown: markdown)
        }
        guard !documents.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        return documents
    }

    static func search(_ query: String, in documents: [HelpDocument]) -> [HelpDocument] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return documents }
        return documents.filter {
            $0.title.localizedStandardContains(term) || $0.markdown.localizedStandardContains(term)
        }
    }
}

private final class HelpPanel: NSPanel {
    var onClose: (() -> Void)?
    private(set) var wasKeyBeforeClose = false

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = L("codenv 說明")
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isFloatingPanel = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        minSize = NSSize(width: 720, height: 480)
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func close() {
        guard isVisible else { return }
        wasKeyBeforeClose = isKeyWindow
        super.close()
        onClose?()
    }
}

enum HelpSheet {
    private static weak var panel: HelpPanel?
    private static weak var focusWindow: NSWindow?
    private static weak var focusResponder: NSResponder?
    private static var focusApp: NSRunningApplication?
    private static var shouldRestoreExternalApp = false

    static var isOpen: Bool { panel?.isVisible == true }
    static var current: NSPanel? { panel }
    static func owns(_ window: NSWindow?) -> Bool { window === panel }

    static func toggle(in sourceWindow: NSWindow? = nil) {
        if isOpen { close(); return }
        guard let window = sourceWindow ?? NSApp.mainWindow ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        let priorApp = NSWorkspace.shared.frontmostApplication
        focusApp = priorApp
        shouldRestoreExternalApp = priorApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        focusWindow = sourceWindow ?? NSApp.keyWindow ?? window
        focusResponder = focusWindow?.firstResponder

        let view = HelpView()
        let host = NSHostingView(rootView: view)
        let p = HelpPanel(content: host)
        p.onClose = { [weak p] in
            restoreFocus(panelWasKey: p?.wasKeyBeforeClose == true)
            clearFocusTarget()
        }
        let frame = window.frame
        p.setFrameOrigin(NSPoint(x: frame.midX - p.frame.width / 2, y: frame.midY - p.frame.height / 2))
        window.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
        panel = p
    }

    private static func restoreFocus(panelWasKey: Bool) {
        FocusRestoration.restore(window: focusWindow, responder: focusResponder, app: focusApp,
                                 external: shouldRestoreExternalApp, panelWasKey: panelWasKey)
    }

    private static func clearFocusTarget() {
        focusWindow = nil
        focusResponder = nil
        focusApp = nil
        shouldRestoreExternalApp = false
    }

    static func close() { panel?.close() }
}

enum FocusRestoration {
    static func restore(window: NSWindow?, responder: NSResponder?, app: NSRunningApplication?,
                        external: Bool, panelWasKey: Bool) {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard frontmostPID == ownPID || panelWasKey else { return }
        if external {
            guard let app, !app.isTerminated else { return }
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard let window, NSApp.windows.contains(where: { $0 === window }),
              !window.isMiniaturized, window.isVisible,
              let responder,
              (responder as? NSView)?.window === window || responder === window.firstResponder else { return }
        window.makeKey()
        window.makeFirstResponder(responder)
    }
}

private struct HelpView: View {
    @State private var documents: [HelpDocument] = []
    @State private var selectedID: String?
    @State private var query = ""
    @State private var loadError: String?

    private var filtered: [HelpDocument] { HelpCatalog.search(query, in: documents) }
    private var selected: HelpDocument? { filtered.first { $0.id == selectedID } ?? filtered.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                TextField(L("搜尋說明"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filtered) { document in
                            Button {
                                selectedID = document.id
                            } label: {
                                HStack {
                                    Text(document.title).lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 10)
                                .background(selected?.id == document.id ? Color.accentColor.opacity(0.18) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(width: 250)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            Group {
                if let loadError {
                    ContentUnavailableView(L("說明文件無法載入"), systemImage: "doc.questionmark", description: Text(loadError))
                } else if let selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(selected.title).font(.system(size: 26, weight: .semibold))
                            markdown(selected.markdown)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(32)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                    ContentUnavailableView(L("沒有符合的說明"), systemImage: "magnifyingglass")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            do {
                documents = try HelpCatalog.load()
                selectedID = documents.first?.id
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onChange(of: query) { _, _ in
            if let selectedID, !filtered.contains(where: { $0.id == selectedID }) {
                self.selectedID = filtered.first?.id
            } else if selectedID == nil {
                selectedID = filtered.first?.id
            }
        }
    }

    @ViewBuilder
    private func markdown(_ source: String) -> some View {
        switch Result<AttributedString, Error>(catching: { try AttributedString(markdown: source) }) {
        case .success(let content):
            Text(content)
                .font(.system(size: 15))
                .lineSpacing(5)
        case .failure(let error):
            Text(L("這一頁的 Markdown 格式無法顯示：\(error.localizedDescription)"))
                .foregroundStyle(.red)
        }
    }
}
