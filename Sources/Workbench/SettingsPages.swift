import SwiftUI
import AppKit

// ⌘ , 設定視窗的其他頁：對話、桌寵與用量、按鍵、本機模型、資料。（視窗、外觀在 Settings.swift）

struct ChatPrefsPage: View {
    @ObservedObject var p = Prefs.shared
    @ObservedObject var board = CollabBoardModel.shared
    @ObservedObject private var sourceUpdate = SourceUpdate.shared
    @State private var eventLogOn = EventLog.enabled

    private var models: [ModelChoice] { ModelChoice.known.filter { $0.value != "default" } }

    var body: some View {
        Form {
            Section(L("新對話")) {
                Picker(L("預設模型"), selection: Binding(get: { p.defaultModel ?? "" }, set: { p.defaultModel = $0.isEmpty ? nil : $0 })) {
                    Text(L("跟 Claude 的設定")).tag("")
                    ForEach(models, id: \.value) { m in Text(m.name).tag(m.value) }
                }
                Picker(L("預設思考強度"), selection: Binding(get: { p.defaultEffort ?? "" }, set: { p.defaultEffort = $0.isEmpty ? nil : $0 })) {
                    Text(L("跟 Claude 的設定")).tag("")
                    ForEach(Effort.order, id: \.self) { e in Text("\(Effort.name(e))（\(e)）").tag(e) }
                }
                Text(L("之後每段對話還是可以在輸入框右下角自己換。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("權限")) {
                Picker(L("Claude 動檔案、跑指令前"), selection: Binding(get: { p.permissionMode ?? "" }, set: { p.permissionMode = $0.isEmpty ? nil : $0 })) {
                    Text(L("跟 Claude 的設定（你沒設定，就是每次都問）")).tag("")
                    Text(L("每次都先問我（default）")).tag("default")
                    Text(L("改檔案不用問，跑指令要問（acceptEdits）")).tag("acceptEdits")
                    Text(L("Claude 自己判斷危險的才問（auto）")).tag("auto")
                    Text(L("只規劃、不動手（plan）")).tag("plan")
                }
                Text(L("這是新對話的起點；每段對話可以在輸入框按 ⇧ Tab（或點右下角的模式）自己換，馬上生效。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("輸入")) {
                Picker(L("送出"), selection: $p.sendWithEnter) {
                    Text(L("⌘ Enter 送出、Enter 換行（跟你在 Claude Code 的習慣一樣）")).tag(false)
                    Text(L("Enter 送出、Shift+Enter 換行")).tag(true)
                }
                .pickerStyle(.radioGroup)
                Text(L("ctrl+x ctrl+s 兩種都可以送出；⌃ C 停止（Esc 不會停止）；Claude 還在做的時候 ⌃ Enter 馬上插話（停下目前這一步，先讀你的訊息）。")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("回答完用灰字猜下一句（Tab 採用）"), isOn: $p.promptSuggestions)
                Toggle(L("模型清單列出全部（關著只列 Opus／Sonnet／Haiku 5.5、Gemini 3.8 Flash 和全部本機模型）"), isOn: $p.allModels)
                Toggle(L("讓 Claude 能操作 Chrome（Claude in Chrome，新開的對話生效）"), isOn: $p.claudeInChrome)
                Toggle(L("讓 Claude 能發布網頁（Artifact，claude.ai/artifact 網址，新開的對話生效）"), isOn: $p.artifacts)
                Toggle(L("記錄 Claude 的除錯紀錄（查 MCP 斷線等問題用；存在 ~/Library/Logs/codenv，3 天前的自動刪；新開的對話生效）"), isOn: $p.claudeDebugLog)
                HStack {
                    Text(L("記錄事件（回報問題用；3 天前的自動刪）"))
                    Spacer()
                    Button(L("打開事件紀錄…")) { EventConsoleWindowController.shared.present() }
                    Toggle(L("記錄事件（回報問題用；3 天前的自動刪）"), isOn: Binding(get: { eventLogOn }, set: { eventLogOn = $0; EventLog.enabled = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Toggle(L("打開 App 時接回版面裡每一格的 Claude（不用先送訊息，其他聊天室就聯絡得到；每格約 400 MB 記憶體）"), isOn: $p.reconnectOnLaunch)
            }
            Section(L("agy（Google Antigravity CLI）")) {
                Toggle(L("使用 agy：Gemini 聊天室、灰字建議、用量查詢、看板 @agy 自動做事"), isOn: Binding(
                    get: { p.agyEnabled },
                    set: { on in if !on { p.agyEnabled = false } else if Prefs.confirmEnableAgy() { p.agyEnabled = true } }))
                Text(L("呼叫官方 agy -p；Google 寫明個人方案不支援包進 App，風險自負。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("協作看板")) {
                Toggle(L("Claude 開的目標自動生效"), isOn: Binding(get: { board.autoApprove }, set: { board.setAutoApprove($0) }))
                Text(L("打開時，Claude 用 codenv-todo 開的目標直接是「進行中」，不用你在看板上按「同意」。「使用者驗收」那一步還是只有你本人能勾；agy 的每日件數上限、退回三次就卡住、來回太多次的警告都照舊。這個設定 Claude 不能用指令改。")).font(.caption).foregroundStyle(.secondary)
            }
            if Edition.updateRepo != nil {
                Section(L("更新與回報")) {
                    Toggle(L("自動檢查更新（開 App 30 秒後、之後每 24 小時看一次 GitHub）"), isOn: $p.autoCheckUpdates)
                    HStack {
                        Button(L("檢查更新")) { UpdateCheck.shared.check(manual: true) }
                        if Feedback.available { Button(L("回報問題…")) { Feedback.present() } }
                        Text(L("目前版本 \(Edition.version)")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L("檢查更新只會向 api.github.com 問最新版的版號，不送任何使用者資料；有新版也只會提醒，不會自己下載。")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if Edition.isPublic {
                Section(L("公版原始碼更新")) {
                    HStack {
                        Button(L("檢查官方原始碼")) { sourceUpdate.check() }
                            .disabled(sourceUpdate.busy)
                        if sourceUpdate.hasUpdate {
                            Button(L("按一下更新")) { sourceUpdate.update() }
                                .buttonStyle(.borderedProminent)
                        }
                        if sourceUpdate.busy { ProgressView().controlSize(.small) }
                    }
                    Text(sourceUpdate.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L("更新會在 Terminal 執行 public/update.command。它只會 fetch 和 merge；有未提交改動或衝突時會停下，不會自動下載或背景替換 App。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if PetSprites.available {
                Section(L("桌寵")) {
                    PetEmbedSettings()
                }
            }
            Section(L("闔蓋")) {
                Toggle(L("闔上螢幕時，讓正在做事的聊天室做完這一段"), isOn: $p.lidKeepWorking)
                Text(L("有聊天室正在做事時 Mac 不會睡（要 Battery 的小幫手 v6，電量低於 30% 且沒插電時除外）；闔上螢幕後，聊天室做完目前這一段就停。全部停下、撐滿 1 小時、電量低於 30% 或溫度太高就恢復正常睡眠。紀錄在 ~/Library/Logs/codenv-lid.log。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("瀏覽器格子")) {
                Toggle(L("網頁外掛功能"), isOn: $p.webFeaturesEnabled)
                if p.webFeaturesEnabled {
                    Picker(L("核心"), selection: $p.browserEngine) {
                        Text(L("WebKit（Safari 的核心，系統內建、最省記憶體）")).tag("webkit")
                        Text(L("Chromium（Chrome 的核心，還在做）")).tag("chromium")
                    }
                    Text(p.browserEngine == "chromium"
                         ? L("Chromium 版還沒做好，現在照樣用 WebKit 開；做好之後新開的瀏覽器格子才會換。")
                         : L("側欄「瀏覽器」或 ⌘ ⇧ B 開一格。登入資料只存在 codenv 自己的資料庫，不跟 Safari 共用。Claude 用 codenv-browser 指令讀得到網址、文字和截圖，不能點也不能打字。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Gemini 網頁換皮（codenv 聊天室的配色和字型）"), isOn: $p.geminiSkin)
                    Text(L("只改 gemini.google.com 的外觀（背景、字型、顏色、訊息、輸入框、模型選單），不動功能；NotebookLM 不受影響。關掉就是 Gemini 原樣，已經開著的頁立刻生效。Google 改版讓某一塊對不上時，那一塊會自己恢復原樣。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("NotebookLM 網頁換皮（codenv 的配色和字型）"), isOn: $p.notebookSkin)
                    Text(L("只改 NotebookLM（notebook.google.com）首頁和筆記本內頁的外觀（背景、卡片、文字、按鈕、選單的顏色和字型），不動功能。關掉就是原樣，已經開著的頁立刻生效。Google 改版讓某個地方沒換到時，那裡會維持原樣。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Gemini／NotebookLM 網頁：⌘ Enter 送出、Enter 換行"), isOn: $p.geminiCmdEnter)
                    Text(L("只對 gemini.google.com 和 NotebookLM（notebooklm.google.com、notebook.google.com）的輸入框有效；找不到送出鈕時不攔 Enter；輸入法選字時的 Enter 不受影響，⇧ Enter 照原樣。已經開著的頁立刻生效。瀏覽器格子右上角的圓形下載鈕（只在 Gemini 對話頁出現）可以把整段對話匯成 Markdown 和圖片。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("自動壓縮上下文")) {
                Stepper(value: $p.cloudCompactTokens, in: 100_000...1_000_000, step: 20_000) {
                    Text(L("雲端模型（Claude）：\(p.cloudCompactTokens / 1000)K token"))
                }
                Text(L("對話長到這裡，Claude 自己把前面整理成摘要。codenv 裡的 Claude 聊天室以這裡為準（蓋過 ~/.claude/settings.json 的 autoCompactWindow；iTerm 裡直接開的 claude 不受影響）。實際取這個值和模型上限的較小值；Gemini、Codex、Copilot 由它們自己的程式決定，這裡管不到。新開的對話生效。"))
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $p.localCompactTokens, in: 20_000...1_000_000, step: 20_000) {
                    Text(L("本機模型：\(p.localCompactTokens / 1000)K token"))
                }
                Text(L("本機模型的對話長到這裡，下一則送出前先請 Claude（Haiku）把前面整理成摘要，本機模型接著用摘要聊（會用到一點 Claude 額度）。實際取這個值和模型上限的 80% 的較小值，多數本機模型上限是 128K～262K。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("程式碼學習專區")) {
                Picker(L("版面"), selection: $p.codeLabLayout) {
                    ForEach(CodeLabView.Mode.allCases, id: \.rawValue) { m in Text(m.detail).tag(m.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Text(L("每個練習也可以在程式碼區上面的「版面」臨時換。執行完按任意鍵回到程式碼，按著 ⌘、⌥、⌃ 的不算（可以先 ⌘ C 複製）；換畫面和視窗版面會同時收起執行畫面。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("對話清單")) {
                Stepper(value: $p.archiveDays, in: 1...60) { Text(L("幾天沒碰收進封存：\(p.archiveDays) 天")) }
                Stepper(value: $p.historyLimit, in: 100...2000, step: 100) { Text(L("打開時先載入：\(p.historyLimit) 則（往上捲再載入更早的）")) }
                Toggle(L("自動加入正在 tmux／iTerm 裡進行的對話（每 30 秒檢查）"), isOn: $p.autoImportLive)
            }
            Section(L("每日交接")) {
                Toggle(L("每天自動交接有新對話的聊天室"), isOn: $p.dailyHandoffEnabled)
                Stepper(value: $p.dailyHandoffHour, in: 0...23) { Text(L("分界時間：每天 \(p.dailyHandoffHour) 點")) }.disabled(!p.dailyHandoffEnabled)
                Stepper(value: $p.dailyHandoffMax, in: 1...50) { Text(L("一天最多交接：\(p.dailyHandoffMax) 件")) }.disabled(!p.dailyHandoffEnabled)
                Text(L("過了分界時間，App 開著時會一件一件在背景交接：未封存的 Claude 聊天室、上次交接後有新對話、上下文超過 20K token 才做；總指揮優先，每件間隔 20 秒，Claude 5 小時或每週額度剩不到 15% 就暫停。正在回答或有權限詢問的聊天室延到下一輪。不會切換你正在看的畫面。")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: EventLog.changed)) { _ in
            eventLogOn = EventLog.enabled
        }
    }
}

struct PetPrefsPage: View {
    @ObservedObject var p = Prefs.shared
    @State private var on = PetSlot.enabled
    @State private var builtin = PetSlot.size(forKey: "builtin")
    @State private var external = PetSlot.size(forKey: "external")

    var body: some View {
        Form {
            Section(L("桌寵位置")) {
                Toggle(L("視窗最右邊留一條欄位給桌寵（Ctrl+A b）"), isOn: Binding(get: { on }, set: { on = $0; PetSlot.enabled = $0 }))
                sizeRow(L("筆電螢幕"), $builtin, key: "builtin")
                sizeRow(L("外接螢幕"), $external, key: "external")
                Text(L("也可以直接拖格子左上角的斜線調。桌寵本身工作台不會去動。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("用量剩餘（欄位上面）")) {
                Stepper(value: $p.usageMinutes, in: 1...60) { Text(L("每 \(p.usageMinutes) 分鐘查一次")) }
                Text(L("資料來自 Claude Code 的 /usage：本機查詢、不叫模型、不留對話紀錄。點一下面板會立刻重查。")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: PetSlot.changed)) { _ in
            on = PetSlot.enabled; builtin = PetSlot.size(forKey: "builtin"); external = PetSlot.size(forKey: "external")
        }
    }

    private func sizeRow(_ title: String, _ size: Binding<NSSize>, key: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: Binding(get: { Double(size.wrappedValue.width) }, set: { size.wrappedValue.width = $0; PetSlot.setSize(size.wrappedValue, forKey: key) }), in: 80...600, step: 2) {
                Text(L("寬 \(Int(size.wrappedValue.width))")).monospacedDigit()
            }
            .fixedSize()
            Stepper(value: Binding(get: { Double(size.wrappedValue.height) }, set: { size.wrappedValue.height = $0; PetSlot.setSize(size.wrappedValue, forKey: key) }), in: 60...500, step: 2) {
                Text(L("高 \(Int(size.wrappedValue.height))")).monospacedDigit()
            }
            .fixedSize()
        }
    }
}

struct KeysPage: View {
    private let rows: [(String, String)] = [
        ("Ctrl+A |", L("往右切開，開一段新對話")), ("Ctrl+A -", L("往下切開，開一段新對話")),
        ("Ctrl+A h j k l", L("換到左、下、上、右那格")), ("Ctrl+A Ctrl+h j k l", L("調大小（一秒內可以連按）")),
        ("Ctrl+A z", L("放大／還原目前那格")), ("Ctrl+A x", L("關掉這格（Enter 確定；對話留在側欄）")),
        ("Ctrl+A c", L("新 Window")), (L("Ctrl+A n／p"), L("下一個／上一個 Window")), (L("Ctrl+A 1～9"), L("第幾個 Window")),
        ("Ctrl+A ,", L("幫 Window 改名")), ("Ctrl+A &", L("關掉整個 Window（Enter 確定）")),
        (L("Ctrl+A s／w"), L("列出 Session 和 Window 來選")), ("Ctrl+A $", L("幫 Session 改名")), ("Ctrl+A ( )", L("上一個／下一個 Session")),
        ("Ctrl+A b", L("開／關右邊的桌寵欄位")), ("Ctrl+A a", L("把 Ctrl+A 本身送出（輸入框跳到行首）")), ("Ctrl+A Ctrl+A", L("中文指令選單")),
        ("⌘ N", L("新對話（資料夾選單）")), ("⌘ ⇧ I", L("從 Claude Code 匯入對話")), (L("⌘ =／⌘ -／⌘ 0"), L("放大／縮小／實際文字大小")),
        (L("⌘ Enter、ctrl+x ctrl+s"), L("送出訊息")), ("⌃ C", L("停止 Claude")), ("⇧ Tab", L("換權限模式（每次都問 → 改檔不問 → 只規劃 → 自動）")), ("⌘ ,", L("設定")),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("照你 ~/.tmux.conf 的 Ctrl+A 那一套。唯音開著中文也能直接按（工作台看的是實體按鍵位置）。")).font(.callout).foregroundStyle(.secondary)
            List(rows, id: \.0) { k, v in
                HStack {
                    Text(k).font(.system(.body, design: .monospaced)).frame(width: 220, alignment: .leading)
                    Text(v)
                }
            }
        }
        .padding()
    }
}

extension LocalModel {
    /// 伺服器位址不合規定的原因（nil＝可以用）：http 只准本機（localhost、127.0.0.1、::1），其他位址一律要 https；
    /// 不然金鑰和對話會明文送到別台機器、路上的人看得到
    var addressProblem: String? {
        guard let u = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased() else {
            return L("伺服器位址看不懂：要寫成 https://… 或 http://127.0.0.1:8080")
        }
        if scheme == "https" { return nil }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) { return nil }
        return L("只有本機（localhost、127.0.0.1、::1）可以用 http://，其他位址一律要 https://（不然金鑰和對話會明文傳送）")
    }
}

struct LocalModelsPage: View {
    @State private var list = LocalModel.all
    @State private var picked: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading) {
                List(selection: $picked) {
                    ForEach(list) { m in Text(m.name.isEmpty ? L("（沒有名字）") : m.name).tag(m.id) }
                }
                HStack {
                    Button(action: add) { Image(systemName: "plus") }
                    Button(action: remove) { Image(systemName: "minus") }.disabled(picked == nil)
                }
            }
            .frame(width: 220)
            VStack(alignment: .leading, spacing: 10) {
                if let id = picked, list.contains(where: { $0.id == id }) {
                    Form {
                        TextField(L("名字（選單上顯示的）"), text: binding(id, \.name))
                        TextField(L("伺服器位址"), text: binding(id, \.baseURL), prompt: Text("http://127.0.0.1:8080"))
                        TextField(L("模型名稱（傳給 --model）"), text: binding(id, \.model))
                        SecureField(L("金鑰（伺服器不需要就留空）"), text: binding(id, \.token))
                    }
                    .formStyle(.grouped)
                    if let why = list.first(where: { $0.id == id })?.addressProblem {
                        Text(why).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(L("左邊選一個，或按 ＋ 新增。")).foregroundStyle(.secondary)
                }
                Text(L("伺服器要講 Anthropic Messages API 的格式（例如 llama.cpp 的 llama-server，或用 LiteLLM 轉接 MLX／OpenAI 格式的伺服器）。選了本機模型的對話會改連這裡。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding()
    }

    /// 用 id 找（不要記索引：正在打字時按 − 刪掉，索引會超出範圍讓 App 當掉）
    private func binding(_ id: UUID, _ kp: WritableKeyPath<LocalModel, String>) -> Binding<String> {
        Binding(get: { list.first { $0.id == id }?[keyPath: kp] ?? "" },
                set: { v in guard let i = list.firstIndex(where: { $0.id == id }) else { return }; list[i][keyPath: kp] = v; LocalModel.all = list })
    }
    private func add() {
        let m = LocalModel(name: "本機模型", baseURL: "http://127.0.0.1:8080", model: "local")
        list.append(m); LocalModel.all = list; picked = m.id
    }
    private func remove() {
        NSApp.keyWindow?.makeFirstResponder(nil)   // 先結束編輯
        list.removeAll { $0.id == picked }; LocalModel.all = list; picked = nil
    }
}

struct DataPage: View {
    @ObservedObject var store: Store
    @State private var cliMessage: String?
    var body: some View {
        Form {
            Section(L("工作台的資料")) {
                row(L("專案、對話、版面、分類"), path: store.directory.path)
                Text(L("對話內容本身是 Claude Code 存的（~/.claude/projects），工作台只記清單和分類。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("跟 iTerm 共用")) {
                row(L("claude 資料夾選單的清單"), path: ClaudeEnvs.file.path)
            }
            if CLITools.bundleDir != nil {
                Section(L("命令列工具")) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(L("codenv-todo、codenv-browser、memory-check"))
                            Text(L("聊天室裡的 Claude 不用安裝就能用；想在自己的終端機也打得到，按右邊在 ~/.local/bin 建連結（已經有別的同名檔就不動）。")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("安裝到 ~/.local/bin")) { cliMessage = CLITools.install() }
                    }
                    if let m = cliMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section(L("匯入")) {
                Button(L("從 Claude Code 匯入對話…（⌘ ⇧ I）")) { NSApp.sendAction(#selector(AppDelegate.showImporter), to: nil, from: nil) }
                if !Edition.isPublic { Text(L("重新分類的程式是 codenv 的 repo 裡的 docs/classify.py。")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
    private func row(_ title: String, path: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(ClaudeEnvs.tilde(path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(L("在 Finder 中顯示")) { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
        }
    }
}

/// 外觀頁多的那幾項：介面文字大小、顏色
struct InterfacePrefs: View {
    @ObservedObject var scale = UIScale.shared
    @ObservedObject var p = Prefs.shared
    var body: some View {
        Section(L("介面")) {
            Picker(L("左欄"), selection: $p.sidebarMode) {
                Text(L("總指揮")).tag("commander")
                Text(L("原本的樹")).tag("tree")
            }
            Text(L("左欄可以切到「總指揮」模式：每個總指揮管一批分組，右欄會跟著出現專案、檔案、Git 等分頁。切過去之後按左欄「總指揮」旁的「＋」新增；用不到再切回「原本的樹」，聊天室都還在。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L("文字大小"))
                Slider(value: $scale.factor, in: 0.8...2.0, step: 0.05)
                Text("\(Int((scale.factor * 100).rounded()))%").monospacedDigit().frame(width: 48)
                Button(L("預設")) { scale.reset() }
            }
            Picker(L("對話文字"), selection: $p.chatFont) {
                Text(L("跟終端機一樣（字型、粗細、大小）")).tag("terminal")
                Text(L("系統字型")).tag("system")
            }
            Picker(L("語言"), selection: $p.language) {
                Text(L("跟系統")).tag("system")
                Text(L("繁體中文")).tag("zh")
                Text("English").tag("en")
            }
            if I18n.resolve(p.language) != I18n.lang {
                Text(L("重開 codenv 後生效")).font(.caption).foregroundStyle(.orange)
            }
            Picker(L("顏色"), selection: $p.colorScheme) {
                Text(L("跟系統")).tag("system")
                Text(L("深色")).tag("dark")
                Text(L("淺色")).tag("light")
            }
            .pickerStyle(.segmented)
            Text(L("對話內容、輸入框、側欄、用量欄都跟著這個大小（⌘ = 放大、⌘ - 縮小、⌘ 0 回預設）。下面是終端機（用終端機打開的對話）的字。")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
