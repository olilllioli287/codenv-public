import SwiftUI
import AppKit

// 輸入框右下角按下去的浮動面板（照 Codex 的樣子，自己畫，不用系統的選單）：
//   第一頁：上面一條拉桿（最左邊最弱），下面是思考強度的名字＋模型名稱（這整塊點了換到模型清單；10/25 使用者要的上下對調，
//   靠近輸入框的模型按鈕）；那塊右上角 ↺ 回到「跟 Claude 的設定」。滑鼠離開面板就自動收。
//   第二頁：選取模型。最下面一排分頁（Claude／Gemini／ChatGPT／本機），第一行「當前模型」右邊寫「Opus 5.5 — 高」，
//   下面列出這個分頁的模型、目前的打勾；選好回第一頁。Claude 分頁裡 Claude Code 的寫 (cc)、經 agy 的寫 (agy)。

struct ModelRow: Identifiable, Equatable {
    let id: String          // 傳給 applyModel 的值（opus、claude-opus-5、local:<id>、agy:<id>…）
    let title: String
    let tip: String
    let checked: Bool

    /// 放在哪個分頁：看 id 的前綴（local: 本機；agy: 經 agy，名字有 claude 的歸 Claude，其他歸 Gemini；沒前綴是 Claude Code）
    var tab: ModelTab {
        if id.hasPrefix("local:") { return .local }
        if id.hasPrefix("codex:") { return .chatgpt }
        if id.hasPrefix("copilot:") { return .copilot }
        if id.hasPrefix("agy:") { return id.lowercased().contains("claude") ? .claude : .gemini }
        return .claude
    }
    /// 畫面上的名字：經 agy 的 Claude 拿掉前面的「Claude 」，跟 Claude Code 那列同名（只差後面括號）
    var shownTitle: String {
        guard via == "agy", title.hasPrefix("Claude ") else { return title }
        return String(title.dropFirst("Claude ".count))
    }
    /// Claude 分頁裡標出從哪裡跑：(cc)＝Claude Code、(agy)＝Antigravity
    var via: String? {
        guard tab == .claude else { return nil }
        return id.hasPrefix("agy:") ? "agy" : "cc"
    }
}

enum ModelTab: String, CaseIterable {
    case claude, gemini, chatgpt, copilot, local
    var title: String { switch self { case .claude: "Claude"; case .gemini: "Gemini"; case .chatgpt: "ChatGPT"; case .copilot: "Copilot"; case .local: "本機" } }
    /// 單色圖示（OpenAI、Copilot、本機）：跟著文字顏色上色
    var monochrome: Bool { self == .chatgpt || self == .copilot || self == .local }
    /// 圖示：Resources/icons 裡的 SVG（LobeHub Icons，MIT）；本機用系統圖示
    var image: NSImage? {
        switch self {
        case .claude: Self.load("claude")
        case .gemini: Self.load("gemini")
        case .chatgpt: Self.load("openai")
        case .copilot: Self.load("copilot")
        case .local: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        }
    }
    private static var cache: [String: NSImage] = [:]
    private static func load(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let u = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "icons"), let i = NSImage(contentsOf: u) else { return nil }
        cache[name] = i
        return i
    }
}

final class ModelPanelModel: ObservableObject {
    static weak var last: ModelPanelModel?             // 測試用：最近打開的那個面板（--shot-models）
    init() { Self.last = self }
    @Published var levels: [String] = Effort.order    // 這個模型支援的幾段，弱到強
    @Published var effort: String?                     // nil＝跟 Claude 的設定
    @Published var modelName = ""
    @Published var isLocal = false
    @Published var showingModels = false
    @Published var sections: [[ModelRow]] = []         // 一個系列一組，最後一組是本機模型
    @Published var tab: ModelTab?                      // 模型清單現在看哪個分頁；nil＝目前用的模型所在那頁
    @Published var defaultEffort: String?              // Claude 設定裡這個模型的預設（settings.json）
    @Published var canSetDefault = false               // Claude 模型才有「設為預設」（存進 settings.json）
    @Published var defaultNote: String?                // 存完的結果（存好了／存不進去）
    var onSetDefault: ((String) -> Void)?
    var onEffort: ((String?) -> Void)?
    var onPickModel: ((String) -> Void)?
    var onLocalSettings: (() -> Void)?
    var onSizeChange: (() -> Void)?

    var shownLevel: String? { effort ?? defaultEffort }
    var index: Double {
        get { Double(levels.firstIndex(of: shownLevel ?? "") ?? max(0, levels.count / 2)) }
        set {
            let i = Int(newValue.rounded())
            guard levels.indices.contains(i) else { return }
            let v = levels[i]
            if v != effort { effort = v; onEffort?(v) }
        }
    }
    var currentText: String { isLocal ? modelName : modelName + (shownLevel.map { " — " + Effort.name($0) } ?? "") }

    /// 有東西的分頁（本機一定有，裡面有「設定本機模型…」）
    var tabs: [ModelTab] {
        let have = Set(sections.joined().map(\.tab))
        return ModelTab.allCases.filter { $0 == .local || have.contains($0) }
    }
    var shownTab: ModelTab {
        if let t = tab, tabs.contains(t) { return t }
        return sections.joined().first(where: \.checked)?.tab ?? .claude
    }
    /// 這個分頁要列的組（每組只留這頁的模型，空的組拿掉）。
    /// Claude 分頁：經 agy 的放在同名的 Claude Code 那列正下面（Opus 5.5 (cc)、Opus 5.5 (agy)）；找不到同名的才另成一組放最後
    var shownSections: [[ModelRow]] {
        let t = shownTab
        var secs = sections.map { $0.filter { $0.tab == t } }.filter { !$0.isEmpty }
        guard t == .claude else { return secs }
        let agy = secs.joined().filter { $0.via == "agy" }
        secs = secs.map { $0.filter { $0.via != "agy" } }.filter { !$0.isEmpty }
        var left: [ModelRow] = []
        for a in agy {
            if let si = secs.firstIndex(where: { $0.contains { $0.shownTitle == a.shownTitle } }),
               let ri = secs[si].lastIndex(where: { $0.shownTitle == a.shownTitle }) {
                secs[si].insert(a, at: ri + 1)
            } else {
                left.append(a)
            }
        }
        if !left.isEmpty { secs.append(left) }
        return secs
    }
}

struct ModelPanel: View {
    @ObservedObject var m: ModelPanelModel

    var body: some View {
        Group {
            if m.showingModels { modelList } else { effortPage.frame(maxHeight: .infinity, alignment: .bottom) }
        }
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private var effortPage: some View {
        VStack(spacing: 10) {
            if !m.isLocal && m.levels.count > 1 {
                StepSlider(count: m.levels.count, value: Binding(get: { m.index }, set: { m.index = $0 }))
                    .frame(height: 30)
                HStack {
                    Text(Effort.name(m.levels.first!)).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text(Effort.name(m.levels.last!)).font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                if m.canSetDefault { defaultRow }
                Divider().opacity(0.4).padding(.top, 2)
            }
            ZStack(alignment: .topTrailing) {
                // 這整塊（強度名字＋模型名稱）點了就換模型
                Button(action: { m.showingModels = true; m.onSizeChange?() }) {
                    VStack(spacing: 4) {
                        Text(m.isLocal ? "本機模型" : (m.shownLevel.map(Effort.name) ?? "預設"))
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.accentColor)
                        HStack(spacing: 3) {
                            Text(m.modelName).font(.system(size: 14))
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverPlain())
                .help("換模型")
                Button(action: { m.effort = nil; m.onEffort?(nil) }) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("回到 Claude 的設定")
                .opacity(m.effort == nil ? 0.3 : 1)
                .disabled(m.effort == nil)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    /// 拉桿下面：目前的預設＋「設為預設」（max 不能存：Claude Code 規定只限這一次）
    private var defaultRow: some View {
        let e = m.effort
        let isMax = e == "max"
        let can = e != nil && e != m.defaultEffort && !isMax
        return HStack(spacing: 8) {
            Text(m.defaultNote ?? "預設：" + (m.defaultEffort.map(Effort.name) ?? "Claude 內建"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("設為預設") { if let e { m.onSetDefault?(e) } }
                .controlSize(.small)
                .disabled(!can)
                .help(isMax ? "「最高」Claude Code 只能每次手動選，不能存成預設"
                      : "存進 ~/.claude/settings.json：新對話和沒調過強度的對話都用這個；終端機的 Claude Code 也會跟著用")
        }
        .padding(.top, 2)
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("選取模型").font(.system(size: 14)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            HStack {
                Text("當前模型").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(m.currentText).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(m.shownSections.enumerated()), id: \.offset) { i, sec in
                        Divider().opacity(0.4).padding(.vertical, 4).padding(.horizontal, 12)
                        ForEach(sec) { row in
                            Button(action: { m.onPickModel?(row.id); m.showingModels = false; m.tab = nil; m.onSizeChange?() }) {
                                HStack(spacing: 6) {
                                    Text(row.shownTitle).font(.system(size: 15))
                                    if let v = row.via { Text("(\(v))").font(.system(size: 13)).foregroundStyle(.tertiary) }
                                    Spacer()
                                    if row.checked { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                                }
                                .padding(.horizontal, 18).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HoverPlain())
                            .help(row.tip)
                        }
                    }
                    if m.shownTab == .local {
                        Divider().opacity(0.4).padding(.vertical, 4).padding(.horizontal, 12)
                        Button(action: { m.onLocalSettings?() }) {
                            Text("設定本機模型…").font(.system(size: 14)).foregroundStyle(.secondary)
                                .padding(.horizontal, 18).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverPlain())
                    }
                }
                .padding(.bottom, 8)
                .id(m.shownTab)
                .transition(.opacity)
            }
            // 換分頁時視窗用動畫改高度：清單跟著視窗伸縮（理想高度＝內容高度，量大小用），最下面的分頁不動
            .frame(minHeight: 0, idealHeight: listHeight, maxHeight: .infinity)
            .clipped()
            Divider().opacity(0.4).padding(.horizontal, 12)
            tabBar
        }
    }

    /// 最下面一排分頁：圖示＋名字，選到的有底色。全部寫名字放不下（五頁）時，沒選到的只留圖示
    private var tabBar: some View {
        ViewThatFits(in: .horizontal) {
            tabRow(compact: false)
            tabRow(compact: true)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
    }

    private func tabRow(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(m.tabs, id: \.self) { t in
                let on = t == m.shownTab
                Button(action: {
                    guard t != m.shownTab else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { m.tab = t }
                    m.onSizeChange?()
                }) {
                    // 四頁要擠進 320 點寬：圖示 14、字 12、左右各 6
                    HStack(spacing: 4) {
                        if let img = t.image {
                            Image(nsImage: img).resizable().renderingMode(t.monochrome ? .template : .original)
                                .aspectRatio(contentMode: .fit).frame(width: 14, height: 14)
                        }
                        if on || !compact { Text(t.title).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize() }
                    }
                    .foregroundStyle(on ? .primary : .secondary)
                    .padding(.horizontal, 6).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(on ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t == .local ? "本機模型" : t.title + " 的模型")
            }
            Spacer(minLength: 0)
        }
    }

    /// 清單照模型數量撐開（每列約 34 點、分隔線約 9 點），最多 380，超過可以捲
    private var listHeight: CGFloat {
        let secs = m.shownSections
        let rows = secs.reduce(0) { $0 + $1.count } + (m.shownTab == .local ? 1 : 0)
        let dividers = secs.count + (m.shownTab == .local ? 1 : 0)
        return min(380, CGFloat(rows) * 34 + CGFloat(dividers) * 9 + 8)
    }
}

/// 滑過去有一點底色的平面按鈕
struct HoverPlain: ButtonStyle {
    var marked = false   // 用鍵盤選到的那一行：跟滑過去一樣有底色
    func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration, marked: marked) }
    struct HoverBody: View {
        let configuration: Configuration
        let marked: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(configuration.isPressed ? 0.12 : (hover || marked ? 0.07 : 0))).padding(.horizontal, 6))
                .onHover { hover = $0 }
        }
    }
}

/// 浮動面板的視窗：自己決定位置（右緣對齊輸入框，不會伸進桌寵的格子），點外面或按 Esc 就關
final class FloatingPanel: NSPanel {
    private var monitors: [Any] = []
    var onClose: (() -> Void)?
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        contentView = content
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            if let self, e.window !== self { self.close() }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, let self, self.isVisible { self.close(); return nil }
            return e
        } as Any)
        NotificationCenter.default.addObserver(self, selector: #selector(appLeft), name: NSApplication.didResignActiveNotification, object: nil)
    }
    override var canBecomeKey: Bool { true }
    @objc private func appLeft() { close() }

    /// 滑鼠離開面板就自動收（模型面板用，使用者 10/25）：要先移進來過一次才算，打開時滑鼠還在按鈕上不會馬上關
    func closeWhenMouseLeaves() {
        var entered = false
        mouseTimer?.invalidate()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let at = NSEvent.mouseLocation
            if self.frame.contains(at) { entered = true }
            else if entered, !self.frame.insetBy(dx: -10, dy: -10).contains(at), NSEvent.pressedMouseButtons == 0 { self.close() }
        }
    }
    private var mouseTimer: Timer?

    override func close() {
        mouseTimer?.invalidate(); mouseTimer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        NotificationCenter.default.removeObserver(self)
        super.close()
        onClose?()
    }
}

/// 一條有段落的拉桿：圓鈕可以拖，也可以點段落的小點
struct StepSlider: View {
    let count: Int
    @Binding var value: Double
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { g in
            let knob: CGFloat = 30
            let track = g.size.width - knob
            let pos = (dragging ?? value) / Double(max(1, count - 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.accentColor.opacity(0.35))
                    .frame(width: knob + track * pos)
                ForEach(0..<count, id: \.self) { i in
                    Circle().fill(Color.primary.opacity(0.35)).frame(width: 5, height: 5)
                        .position(x: knob / 2 + track * CGFloat(i) / CGFloat(max(1, count - 1)), y: g.size.height / 2)
                }
                Circle().fill(Color.white).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: knob - 4, height: knob - 4)
                    .offset(x: 2 + track * pos)
                    .animation(.spring(duration: 0.25), value: dragging == nil ? value : -1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    let r = min(1, max(0, (d.location.x - knob / 2) / max(1, track)))
                    dragging = r * Double(count - 1)
                }
                .onEnded { _ in
                    if let d = dragging { value = d.rounded() }
                    dragging = nil
                })
        }
    }
}

enum ClaudeSettings {
    /// ~/.claude/settings.json 裡這個模型的預設思考強度（modelSettings.<模型>.effortLevel，或最外層 effortLevel）；只讀
    static func effort(for model: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let ms = o["modelSettings"] as? [String: Any], let m = ms[model] as? [String: Any], let e = m["effortLevel"] as? String { return e }
        return o["effortLevel"] as? String
    }
}
