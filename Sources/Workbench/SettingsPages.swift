import SwiftUI
import AppKit

// ⌘ , 設定視窗的其他頁：對話、桌寵與用量、按鍵、本機模型、資料。（視窗、外觀在 Settings.swift）

struct ChatPrefsPage: View {
    @ObservedObject var p = Prefs.shared

    private var models: [ModelChoice] { ModelChoice.known.filter { $0.value != "default" } }

    var body: some View {
        Form {
            Section("新對話") {
                Picker("預設模型", selection: Binding(get: { p.defaultModel ?? "" }, set: { p.defaultModel = $0.isEmpty ? nil : $0 })) {
                    Text("跟 Claude 的設定").tag("")
                    ForEach(models, id: \.value) { m in Text(m.name).tag(m.value) }
                }
                Picker("預設思考強度", selection: Binding(get: { p.defaultEffort ?? "" }, set: { p.defaultEffort = $0.isEmpty ? nil : $0 })) {
                    Text("跟 Claude 的設定").tag("")
                    ForEach(Effort.order, id: \.self) { e in Text("\(Effort.name(e))（\(e)）").tag(e) }
                }
                Text("之後每段對話還是可以在輸入框右下角自己換。").font(.caption).foregroundStyle(.secondary)
            }
            Section("權限") {
                Picker("Claude 動檔案、跑指令前", selection: Binding(get: { p.permissionMode ?? "" }, set: { p.permissionMode = $0.isEmpty ? nil : $0 })) {
                    Text("跟 Claude 的設定（你沒設定，就是每次都問）").tag("")
                    Text("每次都先問我（default）").tag("default")
                    Text("改檔案不用問，跑指令要問（acceptEdits）").tag("acceptEdits")
                    Text("Claude 自己判斷危險的才問（auto）").tag("auto")
                    Text("只規劃、不動手（plan）").tag("plan")
                }
                Text("這是新對話的起點；每段對話可以在輸入框按 ⇧ Tab（或點右下角的模式）自己換，馬上生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("輸入") {
                Picker("送出", selection: $p.sendWithEnter) {
                    Text("⌘ Enter 送出、Enter 換行（跟你在 Claude Code 的習慣一樣）").tag(false)
                    Text("Enter 送出、Shift+Enter 換行").tag(true)
                }
                .pickerStyle(.radioGroup)
                Text("ctrl+x ctrl+s 兩種都可以送出；Esc 停止；Claude 還在做的時候 ⌃ Enter 馬上插話（停下目前這一步，先讀你的訊息）。").font(.caption).foregroundStyle(.secondary)
                Toggle("回答完用灰字猜下一句（Tab 採用）", isOn: $p.promptSuggestions)
                Toggle("模型清單列出全部（關著只列 Opus／Sonnet／Haiku 5.5、Gemini 3.8 Flash 和全部本機模型）", isOn: $p.allModels)
                Toggle("讓 Claude 能操作 Chrome（Claude in Chrome，新開的對話生效）", isOn: $p.claudeInChrome)
                Toggle("讓 Claude 能發布網頁（Artifact，claude.ai/artifact 網址，新開的對話生效）", isOn: $p.artifacts)
                Toggle("記錄 Claude 的除錯紀錄（查 MCP 斷線等問題用；存在 ~/Library/Logs/codenv，3 天前的自動刪；新開的對話生效）", isOn: $p.claudeDebugLog)
                Toggle("打開 App 時接回版面裡每一格的 Claude（不用先送訊息，其他聊天室就聯絡得到；每格約 400 MB 記憶體）", isOn: $p.reconnectOnLaunch)
            }
            Section("agy（Google Antigravity CLI）") {
                Toggle("使用 agy：Gemini 聊天室、灰字建議、用量查詢、看板 @agy 自動做事", isOn: Binding(
                    get: { p.agyEnabled },
                    set: { on in if !on { p.agyEnabled = false } else if Prefs.confirmEnableAgy() { p.agyEnabled = true } }))
                Text("打開前會先請你看一段 Google 官方 FAQ 的說明：用別的程式去呼叫 agy，Google 說個人方案不支援、可能停權帳號。").font(.caption).foregroundStyle(.secondary)
            }
            if Edition.updateRepo != nil {
                Section("更新與回報") {
                    Toggle("自動檢查更新（開 App 30 秒後、之後每 24 小時看一次 GitHub）", isOn: $p.autoCheckUpdates)
                    HStack {
                        Button("檢查更新") { UpdateCheck.shared.check(manual: true) }
                        if Feedback.available { Button("回報問題…") { Feedback.present() } }
                        Text("目前版本 \(Edition.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("檢查更新只會向 api.github.com 問最新版的版號，不送任何使用者資料；有新版也只會提醒，不會自己下載。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("瀏覽器格子") {
                Picker("核心", selection: $p.browserEngine) {
                    Text("WebKit（Safari 的核心，系統內建、最省記憶體）").tag("webkit")
                    Text("Chromium（Chrome 的核心，還在做）").tag("chromium")
                }
                Text(p.browserEngine == "chromium"
                     ? "Chromium 版還沒做好，現在照樣用 WebKit 開；做好之後新開的瀏覽器格子才會換。"
                     : "側欄「瀏覽器」或 ⌘ ⇧ B 開一格。登入資料只存在 codenv 自己的資料庫，不跟 Safari 共用。Claude 用 codenv-browser 指令讀得到網址、文字和截圖，不能點也不能打字。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自動壓縮上下文") {
                Stepper(value: $p.cloudCompactTokens, in: 100_000...1_000_000, step: 20_000) {
                    Text("雲端模型（Claude）：\(p.cloudCompactTokens / 1000)K token")
                }
                Text("對話長到這裡，Claude 自己把前面整理成摘要。codenv 裡的 Claude 聊天室以這裡為準（蓋過 ~/.claude/settings.json 的 autoCompactWindow；iTerm 裡直接開的 claude 不受影響）。實際取這個值和模型上限的較小值；Gemini、Codex、Copilot 由它們自己的程式決定，這裡管不到。新開的對話生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $p.localCompactTokens, in: 20_000...1_000_000, step: 20_000) {
                    Text("本機模型：\(p.localCompactTokens / 1000)K token")
                }
                Text("本機模型的對話長到這裡，下一則送出前先請 Claude（Haiku）把前面整理成摘要，本機模型接著用摘要聊（會用到一點 Claude 額度）。實際取這個值和模型上限的 80% 的較小值，多數本機模型上限是 128K～262K。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("程式碼學習專區") {
                Picker("版面", selection: $p.codeLabLayout) {
                    ForEach(CodeLabView.Mode.allCases, id: \.rawValue) { m in Text(m.detail).tag(m.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Text("每個練習也可以在程式碼區上面的「版面」臨時換。執行完按任意鍵回到程式碼；按著 ⌘、⌥、⌃ 的鍵不算（可以先 ⌘ C 複製結果）。").font(.caption).foregroundStyle(.secondary)
            }
            Section("對話清單") {
                Stepper(value: $p.archiveDays, in: 1...60) { Text("幾天沒碰收進封存：\(p.archiveDays) 天") }
                Stepper(value: $p.historyLimit, in: 100...2000, step: 100) { Text("打開時先載入：\(p.historyLimit) 則（往上捲再載入更早的）") }
                Toggle("自動加入正在 tmux／iTerm 裡進行的對話（每 30 秒檢查）", isOn: $p.autoImportLive)
            }
        }
        .formStyle(.grouped)
    }
}

struct PetPrefsPage: View {
    @ObservedObject var p = Prefs.shared
    @State private var on = PetSlot.enabled
    @State private var builtin = PetSlot.size(forKey: "builtin")
    @State private var external = PetSlot.size(forKey: "external")

    var body: some View {
        Form {
            Section("桌寵位置") {
                Toggle("視窗最右邊留一條欄位給桌寵（Ctrl+A b）", isOn: Binding(get: { on }, set: { on = $0; PetSlot.enabled = $0 }))
                sizeRow("筆電螢幕", $builtin, key: "builtin")
                sizeRow("外接螢幕", $external, key: "external")
                Text("也可以直接拖格子左上角的斜線調。桌寵本身工作台不會去動。").font(.caption).foregroundStyle(.secondary)
            }
            Section("用量剩餘（欄位上面）") {
                Stepper(value: $p.usageMinutes, in: 1...60) { Text("每 \(p.usageMinutes) 分鐘查一次") }
                Text("資料來自 Claude Code 的 /usage：本機查詢、不叫模型、不留對話紀錄。點一下面板會立刻重查。").font(.caption).foregroundStyle(.secondary)
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
                Text("寬 \(Int(size.wrappedValue.width))").monospacedDigit()
            }
            .fixedSize()
            Stepper(value: Binding(get: { Double(size.wrappedValue.height) }, set: { size.wrappedValue.height = $0; PetSlot.setSize(size.wrappedValue, forKey: key) }), in: 60...500, step: 2) {
                Text("高 \(Int(size.wrappedValue.height))").monospacedDigit()
            }
            .fixedSize()
        }
    }
}

struct KeysPage: View {
    private let rows: [(String, String)] = [
        ("Ctrl+A |", "往右切開，開一段新對話"), ("Ctrl+A -", "往下切開，開一段新對話"),
        ("Ctrl+A h j k l", "換到左、下、上、右那格"), ("Ctrl+A Ctrl+h j k l", "調大小（一秒內可以連按）"),
        ("Ctrl+A z", "放大／還原目前那格"), ("Ctrl+A x", "關掉這格（Enter 確定；對話留在側欄）"),
        ("Ctrl+A c", "新 Window"), ("Ctrl+A n／p", "下一個／上一個 Window"), ("Ctrl+A 1～9", "第幾個 Window"),
        ("Ctrl+A ,", "幫 Window 改名"), ("Ctrl+A &", "關掉整個 Window（Enter 確定）"),
        ("Ctrl+A s／w", "列出 Session 和 Window 來選"), ("Ctrl+A $", "幫 Session 改名"), ("Ctrl+A ( )", "上一個／下一個 Session"),
        ("Ctrl+A b", "開／關右邊的桌寵欄位"), ("Ctrl+A a", "把 Ctrl+A 本身送出（輸入框跳到行首）"), ("Ctrl+A Ctrl+A", "中文指令選單"),
        ("⌘ N", "新對話（資料夾選單）"), ("⌘ ⇧ I", "從 Claude Code 匯入對話"), ("⌘ =／⌘ -／⌘ 0", "放大／縮小／實際文字大小"),
        ("⌘ Enter、ctrl+x ctrl+s", "送出訊息"), ("Esc", "停止 Claude"), ("⇧ Tab", "換權限模式（每次都問 → 改檔不問 → 只規劃 → 自動）"), ("⌘ ,", "設定"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("照你 ~/.tmux.conf 的 Ctrl+A 那一套。唯音開著中文也能直接按（工作台看的是實體按鍵位置）。").font(.callout).foregroundStyle(.secondary)
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

struct LocalModelsPage: View {
    @State private var list = LocalModel.all
    @State private var picked: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading) {
                List(selection: $picked) {
                    ForEach(list) { m in Text(m.name.isEmpty ? "（沒有名字）" : m.name).tag(m.id) }
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
                        TextField("名字（選單上顯示的）", text: binding(id, \.name))
                        TextField("伺服器位址", text: binding(id, \.baseURL), prompt: Text("http://127.0.0.1:8080"))
                        TextField("模型名稱（傳給 --model）", text: binding(id, \.model))
                        SecureField("金鑰（伺服器不需要就留空）", text: binding(id, \.token))
                    }
                    .formStyle(.grouped)
                } else {
                    Text("左邊選一個，或按 ＋ 新增。").foregroundStyle(.secondary)
                }
                Text("伺服器要講 Anthropic Messages API 的格式（例如 llama.cpp 的 llama-server，或用 LiteLLM 轉接 MLX／OpenAI 格式的伺服器）。選了本機模型的對話會改連這裡。")
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
    var body: some View {
        Form {
            Section("工作台的資料") {
                row("專案、對話、版面、分類", path: store.directory.path)
                Text("對話內容本身是 Claude Code 存的（~/.claude/projects），工作台只記清單和分類。").font(.caption).foregroundStyle(.secondary)
            }
            Section("跟 iTerm 共用") {
                row("claude 資料夾選單的清單", path: ClaudeEnvs.file.path)
            }
            Section("匯入") {
                Button("從 Claude Code 匯入對話…（⌘ ⇧ I）") { NSApp.sendAction(#selector(AppDelegate.showImporter), to: nil, from: nil) }
                if !Edition.isPublic { Text("重新分類的程式是 codenv 的 repo 裡的 docs/classify.py。").font(.caption).foregroundStyle(.secondary) }
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
            Button("在 Finder 中顯示") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
        }
    }
}

/// 外觀頁多的那幾項：介面文字大小、顏色
struct InterfacePrefs: View {
    @ObservedObject var scale = UIScale.shared
    @ObservedObject var p = Prefs.shared
    var body: some View {
        Section("介面") {
            HStack {
                Text("文字大小")
                Slider(value: $scale.factor, in: 0.8...2.0, step: 0.05)
                Text("\(Int((scale.factor * 100).rounded()))%").monospacedDigit().frame(width: 48)
                Button("預設") { scale.reset() }
            }
            Picker("對話文字", selection: $p.chatFont) {
                Text("跟終端機一樣（字型、粗細、大小）").tag("terminal")
                Text("系統字型").tag("system")
            }
            Picker("顏色", selection: $p.colorScheme) {
                Text("跟系統").tag("system")
                Text("深色").tag("dark")
                Text("淺色").tag("light")
            }
            .pickerStyle(.segmented)
            Text("對話內容、輸入框、側欄、用量欄都跟著這個大小（⌘ = 放大、⌘ - 縮小、⌘ 0 回預設）。下面是終端機（用終端機打開的對話）的字。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
